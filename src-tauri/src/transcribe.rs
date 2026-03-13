use serde::{Deserialize, Serialize};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use crate::diarize;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptSegment {
    pub text: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub source: Option<String>,
    pub speaker_label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SegmentedTranscript {
    pub text: String,
    pub segments: Vec<TranscriptSegment>,
}

pub struct WhisperState {
    ctx: Option<WhisperContext>,
}

impl WhisperState {
    pub fn new() -> Self {
        Self { ctx: None }
    }

    pub fn ensure_loaded(&mut self, model_path: &str) -> Result<(), String> {
        if self.ctx.is_none() {
            let ctx = WhisperContext::new_with_params(
                model_path,
                WhisperContextParameters::default(),
            )
            .map_err(|e| format!("Failed to load whisper model: {}", e))?;
            self.ctx = Some(ctx);
        }
        Ok(())
    }

    pub fn transcribe_samples(&self, samples: &[f32], language: Option<&str>) -> Result<String, String> {
        let ctx = self.ctx.as_ref().ok_or("Whisper model not loaded")?;
        let mut state = ctx.create_state().map_err(|e| format!("Failed to create state: {}", e))?;

        let mut params = FullParams::new(SamplingStrategy::BeamSearch { beam_size: 5, patience: -1.0 });
        params.set_language(language);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_single_segment(false);

        state
            .full(params, samples)
            .map_err(|e| format!("Transcription failed: {}", e))?;

        let num_segments = state.full_n_segments().map_err(|e| format!("Failed to get segments: {}", e))?;
        let mut transcript = String::new();

        for i in 0..num_segments {
            let text = state
                .full_get_segment_text(i)
                .map_err(|e| format!("Failed to get segment {}: {}", i, e))?;
            transcript.push_str(text.trim());
            if i < num_segments - 1 {
                transcript.push(' ');
            }
        }

        Ok(transcript)
    }
}

/// Original transcribe_audio — unchanged, returns flat text
pub fn transcribe_audio(model_path: &str, audio_path: &str, language: Option<&str>) -> Result<String, String> {
    let samples = read_wav_samples(audio_path)?;
    let ctx = WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
        .map_err(|e| format!("Failed to load whisper model: {}", e))?;
    transcribe_flat(&ctx, &samples, language)
}

/// Transcribe a WAV and return segments with timestamps
fn transcribe_with_segments(
    model_path: &str,
    audio_path: &str,
    language: Option<&str>,
    source: &str,
    default_speaker: Option<&str>,
) -> Result<Vec<TranscriptSegment>, String> {
    let samples = read_wav_samples(audio_path)?;
    if samples.is_empty() {
        return Ok(vec![]);
    }

    let ctx = WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
        .map_err(|e| format!("Failed to load whisper model: {}", e))?;

    let mut state = ctx.create_state().map_err(|e| format!("Failed to create state: {}", e))?;

    let mut params = FullParams::new(SamplingStrategy::BeamSearch { beam_size: 5, patience: -1.0 });
    params.set_language(language);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(true);
    params.set_single_segment(false);

    state
        .full(params, &samples)
        .map_err(|e| format!("Transcription failed: {}", e))?;

    let num_segments = state.full_n_segments().map_err(|e| format!("Failed to get segments: {}", e))?;
    let mut segments = Vec::new();

    for i in 0..num_segments {
        let text = state
            .full_get_segment_text(i)
            .map_err(|e| format!("Failed to get segment text {}: {}", i, e))?;

        let start_ts = state
            .full_get_segment_t0(i)
            .map_err(|e| format!("Failed to get segment t0 {}: {}", i, e))?;

        let end_ts = state
            .full_get_segment_t1(i)
            .map_err(|e| format!("Failed to get segment t1 {}: {}", i, e))?;

        let trimmed = text.trim().to_string();
        if trimmed.is_empty() {
            continue;
        }

        segments.push(TranscriptSegment {
            text: trimmed,
            start_ms: start_ts * 10, // whisper timestamps are in centiseconds
            end_ms: end_ts * 10,
            source: Some(source.to_string()),
            speaker_label: default_speaker.map(|s| s.to_string()),
        });
    }

    Ok(segments)
}

/// Full meeting transcription pipeline:
/// 1. Transcribe mic audio (tagged as "Du")
/// 2. Transcribe system audio
/// 3. Run diarization on system audio to get speaker labels
/// 4. Merge and sort all segments by start time
pub fn transcribe_meeting(
    whisper_model_path: &str,
    mic_path: &str,
    system_path: &str,
    segmentation_model_path: &str,
    embedding_model_path: &str,
    language: Option<&str>,
) -> Result<SegmentedTranscript, String> {
    // 1. Transcribe mic audio — always "Du"
    let mut mic_segments =
        transcribe_with_segments(whisper_model_path, mic_path, language, "mic", Some("Du"))?;

    // 2. Transcribe system audio — no speaker label yet
    let mut system_segments =
        transcribe_with_segments(whisper_model_path, system_path, language, "system", None)?;

    // 3. Diarize system audio
    let diarize_result =
        diarize::diarize_audio(system_path, segmentation_model_path, embedding_model_path)?;

    // 4. Assign speaker labels to system segments based on diarization
    for seg in &mut system_segments {
        let mut best_label = String::from("Unknown");
        let mut best_overlap = 0.0f64;

        for diar_seg in &diarize_result.segments {
            let overlap_start = (seg.start_ms as f64 / 1000.0).max(diar_seg.start_s);
            let overlap_end = (seg.end_ms as f64 / 1000.0).min(diar_seg.end_s);
            let overlap = (overlap_end - overlap_start).max(0.0);

            if overlap > best_overlap {
                best_overlap = overlap;
                best_label = diar_seg.speaker_label.clone();
            }
        }

        seg.speaker_label = Some(best_label);
    }

    // 5. Merge all segments and sort by start time
    let mut all_segments = Vec::new();
    all_segments.append(&mut mic_segments);
    all_segments.append(&mut system_segments);
    all_segments.sort_by_key(|s| s.start_ms);

    // Build flat text
    let text = all_segments
        .iter()
        .map(|s| {
            let label = s.speaker_label.as_deref().unwrap_or("Unknown");
            format!("[{}] {}", label, s.text)
        })
        .collect::<Vec<_>>()
        .join("\n");

    Ok(SegmentedTranscript {
        text,
        segments: all_segments,
    })
}

fn read_wav_samples(audio_path: &str) -> Result<Vec<f32>, String> {
    let reader = hound::WavReader::open(audio_path).map_err(|e| format!("Failed to open WAV: {}", e))?;
    let spec = reader.spec();

    if spec.channels != 1 {
        return Err("Expected mono audio".to_string());
    }

    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Int => {
            let max_val = (1 << (spec.bits_per_sample - 1)) as f32;
            reader
                .into_samples::<i32>()
                .filter_map(|s| s.ok())
                .map(|s| s as f32 / max_val)
                .collect()
        }
        hound::SampleFormat::Float => reader
            .into_samples::<f32>()
            .filter_map(|s| s.ok())
            .collect(),
    };

    if samples.is_empty() {
        return Err("Audio file contains no samples".to_string());
    }

    Ok(samples)
}

fn transcribe_flat(ctx: &WhisperContext, samples: &[f32], language: Option<&str>) -> Result<String, String> {
    let mut state = ctx.create_state().map_err(|e| format!("Failed to create state: {}", e))?;

    let mut params = FullParams::new(SamplingStrategy::BeamSearch { beam_size: 5, patience: -1.0 });
    params.set_language(language);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_single_segment(false);

    state
        .full(params, samples)
        .map_err(|e| format!("Transcription failed: {}", e))?;

    let num_segments = state.full_n_segments().map_err(|e| format!("Failed to get segments: {}", e))?;
    let mut transcript = String::new();

    for i in 0..num_segments {
        let text = state
            .full_get_segment_text(i)
            .map_err(|e| format!("Failed to get segment {}: {}", i, e))?;
        transcript.push_str(text.trim());
        if i < num_segments - 1 {
            transcript.push(' ');
        }
    }

    Ok(transcript)
}
