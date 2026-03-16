use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::{AppHandle, Emitter};

use crate::hotkey::{HotkeyEvent, HotkeyListener};
use crate::mic_capture::MicCaptureState;
use crate::paste;
use crate::transcribe::WhisperState;

const MIN_RECORDING_DURATION_MS: u128 = 300;
const COOLDOWN_MS: u128 = 200;

#[derive(Debug, Clone, serde::Serialize)]
pub struct DictationEvent {
    pub state: String,
    pub text: Option<String>,
    pub error: Option<String>,
    pub duration_ms: Option<u64>,
}

fn emit_state(app: &AppHandle, state: &str, text: Option<String>, error: Option<String>, duration_ms: Option<u64>) {
    let _ = app.emit("dictation-state", DictationEvent {
        state: state.to_string(), text, error, duration_ms,
    });
}

pub struct DictationManager {
    mic: Arc<Mutex<MicCaptureState>>,
    whisper: Arc<Mutex<WhisperState>>,
    mic_device: Arc<Mutex<Option<String>>>,
    language: Arc<Mutex<String>>,
    prompt: Arc<Mutex<String>>,
}

impl DictationManager {
    pub fn new(whisper: Arc<Mutex<WhisperState>>) -> Self {
        Self {
            mic: Arc::new(Mutex::new(MicCaptureState::new())),
            whisper,
            mic_device: Arc::new(Mutex::new(None)),
            language: Arc::new(Mutex::new("sv".to_string())),
            prompt: Arc::new(Mutex::new(String::new())),
        }
    }

    pub fn set_mic_device(&self, device: Option<String>) {
        if let Ok(mut d) = self.mic_device.lock() { *d = device; }
    }
    pub fn set_language(&self, lang: String) {
        if let Ok(mut l) = self.language.lock() { *l = lang; }
    }
    pub fn set_prompt(&self, new_prompt: String) {
        if let Ok(mut p) = self.prompt.lock() { *p = new_prompt; }
    }

    pub fn start_listening(&self, hotkey_listener: &HotkeyListener, app: AppHandle) {
        let mic = self.mic.clone();
        let whisper = self.whisper.clone();
        let mic_device = self.mic_device.clone();
        let language = self.language.clone();
        let prompt = self.prompt.clone();
        let rx = hotkey_listener.rx.clone();

        std::thread::spawn(move || {
            eprintln!("[dictation] listener thread started");
            let mut last_dictation = Instant::now();
            let locked = Arc::new(AtomicBool::new(false));

            loop {
                match rx.recv() {
                    Ok(HotkeyEvent::Start) => {
                        if locked.load(Ordering::Relaxed) { continue; }
                        if last_dictation.elapsed().as_millis() < COOLDOWN_MS { continue; }

                        eprintln!("[dictation] hold-to-talk START");
                        let samples = record_session(&mic, &mic_device, &app, &rx, &locked, "listening");
                        last_dictation = Instant::now();
                        process_recording(&app, &whisper, &language, &prompt, samples);
                    }
                    Ok(HotkeyEvent::ToggleLock) => {
                        if locked.load(Ordering::Relaxed) {
                            // Already locked → turn off (record_session will detect)
                            eprintln!("[dictation] lock OFF (from main loop)");
                            locked.store(false, Ordering::Relaxed);
                        } else {
                            // Activate lock mode
                            eprintln!("[dictation] lock ON");
                            locked.store(true, Ordering::Relaxed);
                            let samples = record_session(&mic, &mic_device, &app, &rx, &locked, "locked");
                            locked.store(false, Ordering::Relaxed);
                            last_dictation = Instant::now();
                            process_recording(&app, &whisper, &language, &prompt, samples);
                        }
                    }
                    Ok(HotkeyEvent::Stop) => {
                        // Spurious stop — ignore
                    }
                    Err(_) => {
                        eprintln!("[dictation] channel closed");
                        return;
                    }
                }
            }
        });
    }
}

fn record_session(
    mic: &Arc<Mutex<MicCaptureState>>,
    mic_device: &Arc<Mutex<Option<String>>>,
    app: &AppHandle,
    rx: &crossbeam_channel::Receiver<HotkeyEvent>,
    locked: &Arc<AtomicBool>,
    state_name: &str,
) -> Vec<f32> {
    emit_state(app, state_name, None, None, None);

    let device_name = mic_device.lock().ok().and_then(|d| d.clone());

    {
        let mut m = match mic.lock() {
            Ok(m) => m,
            Err(_) => { emit_state(app, "error", None, Some("Mic lock error".to_string()), None); return Vec::new(); }
        };
        if let Err(e) = m.start(device_name.as_deref()) {
            emit_state(app, "error", None, Some(e), None);
            return Vec::new();
        }
    }

    let record_start = Instant::now();

    loop {
        match rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(HotkeyEvent::Stop) => {
                if !locked.load(Ordering::Relaxed) {
                    // Hold-to-talk: release stops
                    break;
                }
                // Locked: ignore key release
            }
            Ok(HotkeyEvent::ToggleLock) => {
                if locked.load(Ordering::Relaxed) {
                    // Double-tap while locked → stop
                    eprintln!("[dictation] lock OFF (from record loop)");
                    locked.store(false, Ordering::Relaxed);
                    break;
                } else {
                    // Double-tap during hold-to-talk → switch to locked mode
                    eprintln!("[dictation] upgrading hold → locked");
                    locked.store(true, Ordering::Relaxed);
                    emit_state(app, "locked", None, None, None);
                    // Continue recording — don't break
                }
            }
            Ok(HotkeyEvent::Start) => {}
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                if state_name == "locked" && !locked.load(Ordering::Relaxed) { break; }
            }
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }
    }

    let duration_ms = record_start.elapsed().as_millis();
    eprintln!("[dictation] stopped, duration={}ms", duration_ms);

    let samples = {
        let mut m = match mic.lock() { Ok(m) => m, Err(_) => return Vec::new() };
        m.stop()
    };

    if duration_ms < MIN_RECORDING_DURATION_MS || samples.is_empty() {
        emit_state(app, "idle", None, None, None);
        return Vec::new();
    }

    samples
}

fn process_recording(
    app: &AppHandle,
    whisper: &Arc<Mutex<WhisperState>>,
    language: &Arc<Mutex<String>>,
    prompt: &Arc<Mutex<String>>,
    samples: Vec<f32>,
) {
    if samples.is_empty() { return; }

    let duration_ms = (samples.len() as f64 / 16000.0 * 1000.0) as u64;
    emit_state(app, "transcribing", None, None, Some(duration_ms));

    let lang = language.lock().ok().map(|l| l.clone()).unwrap_or_else(|| "sv".to_string());
    let lang_opt = if lang.is_empty() { None } else { Some(lang) };
    let prompt_str = prompt.lock().ok().map(|p| p.clone()).unwrap_or_default();
    let prompt_opt = if prompt_str.is_empty() { None } else { Some(prompt_str) };

    let text = {
        let ws = match whisper.lock() {
            Ok(ws) => ws,
            Err(_) => { emit_state(app, "error", None, Some("Whisper lock error".to_string()), Some(duration_ms)); return; }
        };
        if ws.is_loaded() {
            ws.transcribe_samples(&samples, lang_opt.as_deref(), prompt_opt.as_deref())
        } else {
            Err("Model not loaded".to_string())
        }
    };

    match text {
        Ok(ref t) if !t.trim().is_empty() => {
            eprintln!("[dictation] transcribed: {}", t.trim());
            if let Err(e) = paste::paste_text(t.trim()) {
                emit_state(app, "error", Some(t.trim().to_string()), Some(format!("Paste failed: {}", e)), Some(duration_ms));
            } else {
                emit_state(app, "complete", Some(t.trim().to_string()), None, Some(duration_ms));
            }
        }
        Ok(_) => { emit_state(app, "complete", None, Some("Nothing detected".to_string()), Some(duration_ms)); }
        Err(e) => { emit_state(app, "error", None, Some(e), Some(duration_ms)); }
    }

    let app_idle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(2000));
        emit_state(&app_idle, "idle", None, None, None);
    });
}
