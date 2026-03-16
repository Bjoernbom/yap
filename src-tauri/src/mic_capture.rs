use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

const WHISPER_SAMPLE_RATE: u32 = 16000;

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

pub struct MicCaptureState {
    recording: Arc<AtomicBool>,
    samples: Arc<Mutex<Vec<f32>>>,
    stream: Option<cpal::Stream>,
}

impl MicCaptureState {
    pub fn new() -> Self {
        Self {
            recording: Arc::new(AtomicBool::new(false)),
            samples: Arc::new(Mutex::new(Vec::new())),
            stream: None,
        }
    }

    pub fn start(&mut self, device_name: Option<&str>) -> Result<(), String> {
        if self.recording.load(Ordering::Relaxed) {
            return Err("Already recording".to_string());
        }

        // Clear previous samples
        if let Ok(mut s) = self.samples.lock() {
            s.clear();
        }

        let host = cpal::default_host();
        let device = if let Some(name) = device_name {
            host.input_devices()
                .map_err(|e| format!("Failed to list devices: {}", e))?
                .find(|d| d.name().map(|n| n == name).unwrap_or(false))
                .unwrap_or_else(|| host.default_input_device().expect("No input device"))
        } else {
            host.default_input_device()
                .ok_or("No input device found")?
        };

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

        let samples = self.samples.clone();
        let recording = self.recording.clone();

        let stream = device
            .build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    if !recording.load(Ordering::Relaxed) {
                        return;
                    }

                    // Convert to mono if stereo
                    let mono: Vec<f32> = if channels > 1 {
                        data.chunks(channels)
                            .map(|frame| frame.iter().sum::<f32>() / channels as f32)
                            .collect()
                    } else {
                        data.to_vec()
                    };

                    // Resample to 16kHz
                    let resampled = resample(&mono, native_rate, WHISPER_SAMPLE_RATE);

                    if let Ok(mut s) = samples.lock() {
                        s.extend_from_slice(&resampled);
                    }
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

        self.recording.store(true, Ordering::Relaxed);
        self.stream = Some(stream);
        Ok(())
    }

    pub fn stop(&mut self) -> Vec<f32> {
        self.recording.store(false, Ordering::Relaxed);
        drop(self.stream.take());

        let samples = if let Ok(mut s) = self.samples.lock() {
            std::mem::take(&mut *s)
        } else {
            Vec::new()
        };

        samples
    }

    pub fn is_recording(&self) -> bool {
        self.recording.load(Ordering::Relaxed)
    }
}
