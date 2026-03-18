use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::{AppHandle, Emitter};

use crate::hotkey::{HotkeyEvent, HotkeyListener};
use crate::mic_capture::MicCaptureState;
use crate::paste;
use crate::refine;
use crate::transcribe::WhisperState;

const MIN_RECORDING_DURATION_MS: u128 = 300;
const MAX_RECORDING_DURATION_MS: u128 = 300_000; // 5 minutes
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
    api_key: Arc<Mutex<Option<String>>>,
}

impl DictationManager {
    pub fn new(whisper: Arc<Mutex<WhisperState>>) -> Self {
        Self {
            mic: Arc::new(Mutex::new(MicCaptureState::new())),
            whisper,
            mic_device: Arc::new(Mutex::new(None)),
            language: Arc::new(Mutex::new("en".to_string())),
            prompt: Arc::new(Mutex::new(String::new())),
            api_key: Arc::new(Mutex::new(None)),
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
    pub fn set_api_key(&self, key: Option<String>) {
        if let Ok(mut k) = self.api_key.lock() { *k = key; }
    }

    pub fn start_listening(&self, hotkey_listener: &HotkeyListener, app: AppHandle) {
        let mic = self.mic.clone();
        let whisper = self.whisper.clone();
        let mic_device = self.mic_device.clone();
        let language = self.language.clone();
        let prompt = self.prompt.clone();
        let api_key = self.api_key.clone();
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
                        process_recording(&app, &whisper, &language, &prompt, &api_key, samples);
                    }
                    Ok(HotkeyEvent::ToggleLock) => {
                        if locked.load(Ordering::Relaxed) {
                            eprintln!("[dictation] lock OFF (from main loop)");
                            locked.store(false, Ordering::Relaxed);
                        } else {
                            eprintln!("[dictation] lock ON");
                            locked.store(true, Ordering::Relaxed);
                            let samples = record_session(&mic, &mic_device, &app, &rx, &locked, "locked");
                            locked.store(false, Ordering::Relaxed);
                            last_dictation = Instant::now();
                            process_recording(&app, &whisper, &language, &prompt, &api_key, samples);
                        }
                    }
                    Ok(HotkeyEvent::Stop) => {}
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
            Err(_) => { emit_state(app, "error", None, Some("mic busy — try again".to_string()), None); return Vec::new(); }
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
                if !locked.load(Ordering::Relaxed) { break; }
            }
            Ok(HotkeyEvent::ToggleLock) => {
                if locked.load(Ordering::Relaxed) {
                    eprintln!("[dictation] lock OFF (from record loop)");
                    locked.store(false, Ordering::Relaxed);
                    break;
                } else {
                    eprintln!("[dictation] upgrading hold → locked");
                    locked.store(true, Ordering::Relaxed);
                    emit_state(app, "locked", None, None, None);
                }
            }
            Ok(HotkeyEvent::Start) => {}
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                if state_name == "locked" && !locked.load(Ordering::Relaxed) { break; }
                if record_start.elapsed().as_millis() > MAX_RECORDING_DURATION_MS {
                    eprintln!("[dictation] max duration reached, auto-stopping");
                    break;
                }
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
    api_key: &Arc<Mutex<Option<String>>>,
    samples: Vec<f32>,
) {
    if samples.is_empty() { return; }

    let duration_ms = (samples.len() as f64 / 16000.0 * 1000.0) as u64;
    emit_state(app, "transcribing", None, None, Some(duration_ms));

    let lang = language.lock().ok().map(|l| l.clone()).unwrap_or_else(|| "en".to_string());
    let lang_opt = if lang.is_empty() { None } else { Some(lang) };
    let prompt_str = prompt.lock().ok().map(|p| p.clone()).unwrap_or_default();
    let prompt_opt = if prompt_str.is_empty() { None } else { Some(prompt_str.clone()) };

    let text = {
        let ws = match whisper.lock() {
            Ok(ws) => ws,
            Err(_) => { emit_state(app, "error", None, Some("transcription busy — try again".to_string()), Some(duration_ms)); return; }
        };
        if ws.is_loaded() {
            ws.transcribe_samples(&samples, lang_opt.as_deref(), prompt_opt.as_deref())
        } else {
            Err("no model loaded — check settings".to_string())
        }
    };

    let raw_text = match text {
        Ok(ref t) if !t.trim().is_empty() => t.trim().to_string(),
        Ok(_) => { emit_state(app, "complete", None, Some("Nothing detected".to_string()), Some(duration_ms)); return; }
        Err(e) => { emit_state(app, "error", None, Some(e), Some(duration_ms)); return; }
    };

    eprintln!("[dictation] transcribed: {}", raw_text);

    // Refine with Claude if API key is set
    let key = api_key.lock().ok().and_then(|k| k.clone());
    let final_text = if let Some(ref key) = key {
        emit_state(app, "polishing", Some(raw_text.clone()), None, Some(duration_ms));

        let key = key.clone();
        let style = prompt_str;
        let lang_code = lang_opt.as_deref().unwrap_or("en").to_string();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build();

        match rt {
            Ok(rt) => {
                match rt.block_on(refine::refine_text(&key, &raw_text, &style, &lang_code)) {
                    Ok(refined) => {
                        eprintln!("[dictation] refined: {}", refined);
                        refined
                    }
                    Err(e) => {
                        eprintln!("[dictation] refine failed, using raw: {}", e);
                        raw_text // fall back to raw on error
                    }
                }
            }
            Err(_) => raw_text,
        }
    } else {
        raw_text
    };

    if let Err(_e) = paste::paste_text(&final_text) {
        emit_state(app, "error", Some(final_text), Some("couldn't paste — check accessibility".to_string()), Some(duration_ms));
    } else {
        emit_state(app, "complete", Some(final_text), None, Some(duration_ms));
    }

    let app_idle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(2000));
        emit_state(&app_idle, "idle", None, None, None);
    });
}
