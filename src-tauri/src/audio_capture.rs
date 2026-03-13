use crossbeam_channel::{Receiver, Sender};
use screencapturekit::prelude::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

const CAPTURE_SAMPLE_RATE: u32 = 48000;
const WHISPER_SAMPLE_RATE: u32 = 16000;
const HIGH_PASS_CUTOFF_HZ: f32 = 80.0;
const NLMS_FILTER_LEN: usize = 4800; // 100ms at 48kHz
const NLMS_MU: f32 = 0.3;
const NLMS_EPSILON: f32 = 1e-6;
const AGC_TARGET_RMS: f32 = 0.15;
const AGC_ATTACK: f32 = 0.01;
const AGC_RELEASE: f32 = 0.001;

// ──────────────────────────────────────────────────────────────
// Audio DSP helpers
// ──────────────────────────────────────────────────────────────

struct HighPassFilter {
    prev_input: f32,
    prev_output: f32,
    alpha: f32,
}

impl HighPassFilter {
    fn new(cutoff_hz: f32, sample_rate: f32) -> Self {
        let rc = 1.0 / (2.0 * std::f32::consts::PI * cutoff_hz);
        let dt = 1.0 / sample_rate;
        Self {
            prev_input: 0.0,
            prev_output: 0.0,
            alpha: rc / (rc + dt),
        }
    }

    fn process(&mut self, input: f32) -> f32 {
        let output = self.alpha * (self.prev_output + input - self.prev_input);
        self.prev_input = input;
        self.prev_output = output;
        output
    }
}

struct NlmsFilter {
    weights: Vec<f32>,
    ref_buffer: Vec<f32>,
    pos: usize,
}

impl NlmsFilter {
    fn new() -> Self {
        Self {
            weights: vec![0.0; NLMS_FILTER_LEN],
            ref_buffer: vec![0.0; NLMS_FILTER_LEN],
            pos: 0,
        }
    }

    fn process(&mut self, mic_sample: f32, ref_sample: f32) -> f32 {
        self.ref_buffer[self.pos] = ref_sample;

        let mut y = 0.0f32;
        let mut power = 0.0f32;
        for i in 0..NLMS_FILTER_LEN {
            let idx = (self.pos + NLMS_FILTER_LEN - i) % NLMS_FILTER_LEN;
            let r = self.ref_buffer[idx];
            y += self.weights[i] * r;
            power += r * r;
        }

        let error = mic_sample - y;
        let norm = NLMS_MU / (power + NLMS_EPSILON);

        for i in 0..NLMS_FILTER_LEN {
            let idx = (self.pos + NLMS_FILTER_LEN - i) % NLMS_FILTER_LEN;
            self.weights[i] += norm * error * self.ref_buffer[idx];
        }

        self.pos = (self.pos + 1) % NLMS_FILTER_LEN;
        error
    }
}

struct Agc {
    current_gain: f32,
}

impl Agc {
    fn new() -> Self {
        Self { current_gain: 1.0 }
    }

    fn process(&mut self, sample: f32) -> f32 {
        let abs = sample.abs().max(1e-10);
        let desired_gain = AGC_TARGET_RMS / abs;
        let desired_gain = desired_gain.clamp(0.1, 10.0);

        let rate = if desired_gain < self.current_gain {
            AGC_ATTACK
        } else {
            AGC_RELEASE
        };
        self.current_gain += rate * (desired_gain - self.current_gain);

        (sample * self.current_gain).clamp(-1.0, 1.0)
    }
}

fn resample(input: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if from_rate == to_rate {
        return input.to_vec();
    }
    let ratio = from_rate as f64 / to_rate as f64;
    let out_len = (input.len() as f64 / ratio).round() as usize;
    let mut output = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src_idx = i as f64 * ratio;
        let low = src_idx.floor() as usize;
        let high = (low + 1).min(input.len().saturating_sub(1));
        let frac = (src_idx - low as f64) as f32;
        output.push(input[low] * (1.0 - frac) + input[high] * frac);
    }
    output
}

fn stereo_to_mono(stereo: &[f32]) -> Vec<f32> {
    stereo
        .chunks_exact(2)
        .map(|pair| (pair[0] + pair[1]) * 0.5)
        .collect()
}

fn write_wav(path: &PathBuf, samples: &[f32], sample_rate: u32) -> Result<(), String> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer =
        hound::WavWriter::create(path, spec).map_err(|e| format!("WAV create error: {}", e))?;
    for &s in samples {
        let clamped = s.clamp(-1.0, 1.0);
        let val = if clamped < 0.0 {
            (clamped * 32768.0) as i16
        } else {
            (clamped * 32767.0) as i16
        };
        writer
            .write_sample(val)
            .map_err(|e| format!("WAV write error: {}", e))?;
    }
    writer
        .finalize()
        .map_err(|e| format!("WAV finalize error: {}", e))?;
    Ok(())
}

// ──────────────────────────────────────────────────────────────
// Permission checks
// ──────────────────────────────────────────────────────────────

extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

pub fn check_screen_recording_permission() -> bool {
    unsafe { CGPreflightScreenCaptureAccess() }
}

pub fn request_screen_recording_permission() -> bool {
    unsafe { CGRequestScreenCaptureAccess() }
}

// ──────────────────────────────────────────────────────────────
// Meeting capture state (managed by Tauri)
// ──────────────────────────────────────────────────────────────

enum AudioMessage {
    SystemSamples(Vec<f32>), // stereo interleaved at CAPTURE_SAMPLE_RATE
    MicSamples(Vec<f32>),    // mono at CAPTURE_SAMPLE_RATE
    Stop,
}

pub struct MeetingCaptureResult {
    pub mic_path: String,
    pub system_path: String,
    pub mixed_path: String,
    pub duration_secs: f64,
}

pub struct MeetingCaptureState {
    running: Arc<AtomicBool>,
    audio_tx: Option<Sender<AudioMessage>>,
    writer_handle: Option<std::thread::JoinHandle<Result<MeetingCaptureResult, String>>>,
    sc_stream: Option<SCStream>,
    cpal_stream: Option<cpal::Stream>,
    // Live levels for UI
    mic_level: Arc<Mutex<f32>>,
    system_level: Arc<Mutex<f32>>,
}

impl MeetingCaptureState {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            audio_tx: None,
            writer_handle: None,
            sc_stream: None,
            cpal_stream: None,
            mic_level: Arc::new(Mutex::new(0.0)),
            system_level: Arc::new(Mutex::new(0.0)),
        }
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Relaxed)
    }

    pub fn get_levels(&self) -> (f32, f32) {
        let mic = *self.mic_level.lock().unwrap_or_else(|e| e.into_inner());
        let sys = *self.system_level.lock().unwrap_or_else(|e| e.into_inner());
        (mic, sys)
    }

    pub fn start(&mut self, recordings_dir: PathBuf, session_id: &str) -> Result<(), String> {
        if self.is_running() {
            return Err("Already recording".to_string());
        }

        let (tx, rx) = crossbeam_channel::bounded::<AudioMessage>(1024);
        self.audio_tx = Some(tx.clone());
        self.running.store(true, Ordering::Relaxed);

        let mic_path = recordings_dir.join(format!("{}_mic.wav", session_id));
        let system_path = recordings_dir.join(format!("{}_system.wav", session_id));
        let mixed_path = recordings_dir.join(format!("{}.wav", session_id));

        // Start writer thread
        let mic_p = mic_path.clone();
        let sys_p = system_path.clone();
        let mix_p = mixed_path.clone();
        let running = self.running.clone();
        let mic_level = self.mic_level.clone();
        let system_level = self.system_level.clone();

        self.writer_handle = Some(std::thread::spawn(move || {
            writer_thread(rx, running, mic_level, system_level, mic_p, sys_p, mix_p)
        }));

        // Start system audio capture via ScreenCaptureKit
        if let Err(e) = self.start_system_audio(tx.clone()) {
            self.cleanup_on_error();
            return Err(format!("System audio capture failed: {}", e));
        }

        // Start mic capture via cpal
        if let Err(e) = self.start_mic_capture(tx) {
            self.cleanup_on_error();
            return Err(format!("Mic capture failed: {}", e));
        }

        Ok(())
    }

    fn cleanup_on_error(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        if let Some(stream) = self.sc_stream.take() {
            let _ = stream.stop_capture();
        }
        drop(self.cpal_stream.take());
        if let Some(tx) = self.audio_tx.take() {
            let _ = tx.send(AudioMessage::Stop);
        }
        if let Some(handle) = self.writer_handle.take() {
            let _ = handle.join();
        }
    }

    pub fn stop(&mut self) -> Result<MeetingCaptureResult, String> {
        if !self.is_running() {
            return Err("Not recording".to_string());
        }

        self.running.store(false, Ordering::Relaxed);

        // Stop ScreenCaptureKit stream
        if let Some(stream) = self.sc_stream.take() {
            let _ = stream.stop_capture();
        }

        // Stop cpal stream
        drop(self.cpal_stream.take());

        // Send stop signal
        if let Some(tx) = self.audio_tx.take() {
            let _ = tx.send(AudioMessage::Stop);
        }

        // Wait for writer thread
        if let Some(handle) = self.writer_handle.take() {
            handle
                .join()
                .map_err(|_| "Writer thread panicked".to_string())?
        } else {
            Err("No writer thread".to_string())
        }
    }

    fn start_system_audio(&mut self, tx: Sender<AudioMessage>) -> Result<(), String> {
        let content = SCShareableContent::get().map_err(|e| format!("SCShareableContent: {}", e))?;
        let displays = content.displays();
        let display = displays
            .first()
            .ok_or("No display found for audio capture")?;

        let filter = SCContentFilter::create()
            .with_display(display)
            .with_excluding_windows(&[])
            .build();

        let config = SCStreamConfiguration::new()
            .with_width(1)
            .with_height(1)
            .with_captures_audio(true)
            .with_excludes_current_process_audio(true)
            .with_sample_rate(CAPTURE_SAMPLE_RATE as i32)
            .with_channel_count(2);

        let mut stream = SCStream::new(&filter, &config);

        stream.add_output_handler(
            move |sample_buffer: CMSampleBuffer, output_type: SCStreamOutputType| {
                if output_type != SCStreamOutputType::Audio {
                    return;
                }
                if let Some(audio_buffer_list) = sample_buffer.audio_buffer_list() {
                    for buffer in audio_buffer_list.iter() {
                        let data = buffer.data();
                        if data.is_empty() {
                            continue;
                        }
                        // Audio is 32-bit float PCM
                        let samples: Vec<f32> = data
                            .chunks_exact(4)
                            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                            .collect();

                        let _ = tx.try_send(AudioMessage::SystemSamples(samples));
                    }
                }
            },
            SCStreamOutputType::Audio,
        );

        stream
            .start_capture()
            .map_err(|e| format!("Failed to start system audio capture: {}", e))?;

        self.sc_stream = Some(stream);
        Ok(())
    }

    fn start_mic_capture(&mut self, tx: Sender<AudioMessage>) -> Result<(), String> {
        use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or("No input device found")?;

        let default_config = device
            .default_input_config()
            .map_err(|e| format!("Input config error: {}", e))?;

        let native_rate = default_config.sample_rate();
        let channels = default_config.channels() as usize;

        let config = cpal::StreamConfig {
            channels: default_config.channels(),
            sample_rate: default_config.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        };

        let stream = device
            .build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    // Convert to mono if stereo
                    let mono: Vec<f32> = if channels > 1 {
                        data.chunks(channels)
                            .map(|frame| frame.iter().sum::<f32>() / channels as f32)
                            .collect()
                    } else {
                        data.to_vec()
                    };

                    // Resample to capture rate
                    let resampled = resample(&mono, native_rate, CAPTURE_SAMPLE_RATE);

                    let _ = tx.try_send(AudioMessage::MicSamples(resampled));
                },
                move |err| {
                    eprintln!("cpal input error: {}", err);
                },
                None,
            )
            .map_err(|e| format!("Failed to build input stream: {}", e))?;

        stream
            .play()
            .map_err(|e| format!("Failed to start mic stream: {}", e))?;

        self.cpal_stream = Some(stream);
        Ok(())
    }
}

fn writer_thread(
    rx: Receiver<AudioMessage>,
    running: Arc<AtomicBool>,
    mic_level: Arc<Mutex<f32>>,
    system_level: Arc<Mutex<f32>>,
    mic_path: PathBuf,
    system_path: PathBuf,
    mixed_path: PathBuf,
) -> Result<MeetingCaptureResult, String> {
    let mut mic_buffer: Vec<f32> = Vec::new();
    let mut system_buffer: Vec<f32> = Vec::new(); // mono at CAPTURE_SAMPLE_RATE

    let mut hpf = HighPassFilter::new(HIGH_PASS_CUTOFF_HZ, CAPTURE_SAMPLE_RATE as f32);
    let mut nlms = NlmsFilter::new();
    let mut agc = Agc::new();

    let start_time = Instant::now();

    loop {
        match rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(AudioMessage::SystemSamples(stereo_samples)) => {
                let mono = stereo_to_mono(&stereo_samples);

                // Update level meter
                if let Ok(mut lvl) = system_level.lock() {
                    let rms = (mono.iter().map(|s| s * s).sum::<f32>()
                        / mono.len().max(1) as f32)
                        .sqrt();
                    *lvl = rms;
                }

                system_buffer.extend_from_slice(&mono);
            }
            Ok(AudioMessage::MicSamples(mono_samples)) => {
                // Apply high-pass filter
                let filtered: Vec<f32> =
                    mono_samples.iter().map(|&s| hpf.process(s)).collect();

                // Apply echo cancellation using system audio as reference
                let processed: Vec<f32> = filtered
                    .iter()
                    .enumerate()
                    .map(|(i, &s)| {
                        // Use latest system audio as reference
                        let ref_idx = system_buffer
                            .len()
                            .saturating_sub(filtered.len())
                            + i;
                        let ref_sample = system_buffer.get(ref_idx).copied().unwrap_or(0.0);
                        nlms.process(s, ref_sample)
                    })
                    .collect();

                // Apply AGC
                let gained: Vec<f32> = processed.iter().map(|&s| agc.process(s)).collect();

                // Update level meter
                if let Ok(mut lvl) = mic_level.lock() {
                    let rms = (gained.iter().map(|s| s * s).sum::<f32>()
                        / gained.len().max(1) as f32)
                        .sqrt();
                    *lvl = rms;
                }

                mic_buffer.extend_from_slice(&gained);
            }
            Ok(AudioMessage::Stop) => break,
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                if !running.load(Ordering::Relaxed) {
                    break;
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }
    }

    let duration_secs = start_time.elapsed().as_secs_f64();

    // Resample to 16kHz for whisper
    let mic_16k = resample(&mic_buffer, CAPTURE_SAMPLE_RATE, WHISPER_SAMPLE_RATE);
    let system_16k = resample(&system_buffer, CAPTURE_SAMPLE_RATE, WHISPER_SAMPLE_RATE);

    // Create mixed audio (equal mix of mic + system)
    let mix_len = mic_16k.len().max(system_16k.len());
    let mut mixed = Vec::with_capacity(mix_len);
    for i in 0..mix_len {
        let m = mic_16k.get(i).copied().unwrap_or(0.0);
        let s = system_16k.get(i).copied().unwrap_or(0.0);
        mixed.push(((m + s) * 0.5).clamp(-1.0, 1.0));
    }

    // Write WAV files
    write_wav(&mic_path, &mic_16k, WHISPER_SAMPLE_RATE)?;
    write_wav(&system_path, &system_16k, WHISPER_SAMPLE_RATE)?;
    write_wav(&mixed_path, &mixed, WHISPER_SAMPLE_RATE)?;

    Ok(MeetingCaptureResult {
        mic_path: mic_path.to_string_lossy().to_string(),
        system_path: system_path.to_string_lossy().to_string(),
        mixed_path: mixed_path.to_string_lossy().to_string(),
        duration_secs,
    })
}
