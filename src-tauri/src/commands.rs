use std::sync::{Arc, Mutex};
use tauri::Manager;

use crate::ai;
use crate::audio_capture;
use crate::model;
use crate::transcribe;

#[tauri::command]
pub async fn save_recording(
    app: tauri::AppHandle,
    samples_b64: String,
    session_id: String,
) -> Result<String, String> {
    use base64::Engine;
    use std::io::Write;

    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&samples_b64)
        .map_err(|e| format!("Base64 decode error: {}", e))?;

    let samples: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    let recordings_dir = data_dir.join("recordings");
    std::fs::create_dir_all(&recordings_dir)
        .map_err(|e| format!("Failed to create recordings dir: {}", e))?;

    let file_path = recordings_dir.join(format!("{}.wav", session_id));

    let sample_rate: u32 = 16000;
    let num_channels: u16 = 1;
    let bits_per_sample: u16 = 16;
    let byte_rate = sample_rate * num_channels as u32 * bits_per_sample as u32 / 8;
    let block_align = num_channels * bits_per_sample / 8;
    let data_size = (samples.len() * 2) as u32;

    let mut file = std::fs::File::create(&file_path)
        .map_err(|e| format!("Failed to create WAV file: {}", e))?;

    file.write_all(b"RIFF").map_err(|e| e.to_string())?;
    file.write_all(&(36 + data_size).to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(b"WAVE").map_err(|e| e.to_string())?;
    file.write_all(b"fmt ").map_err(|e| e.to_string())?;
    file.write_all(&16u32.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&1u16.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&num_channels.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&sample_rate.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&byte_rate.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&block_align.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(&bits_per_sample.to_le_bytes()).map_err(|e| e.to_string())?;
    file.write_all(b"data").map_err(|e| e.to_string())?;
    file.write_all(&data_size.to_le_bytes()).map_err(|e| e.to_string())?;

    for &sample in &samples {
        let s = sample.max(-1.0).min(1.0);
        let val = if s < 0.0 { (s * 32768.0) as i16 } else { (s * 32767.0) as i16 };
        file.write_all(&val.to_le_bytes()).map_err(|e| e.to_string())?;
    }

    file.flush().map_err(|e| e.to_string())?;

    Ok(file_path.to_string_lossy().to_string())
}

#[tauri::command]
pub async fn delete_recording(
    _app: tauri::AppHandle,
    audio_path: String,
) -> Result<(), String> {
    let path = std::path::Path::new(&audio_path);
    if path.exists() {
        std::fs::remove_file(path).map_err(|e| format!("Failed to delete: {}", e))?;
    }
    Ok(())
}

#[tauri::command]
pub async fn transcribe_cmd(
    app: tauri::AppHandle,
    audio_path: String,
    model_name: String,
    language: Option<String>,
) -> Result<String, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    let model_path = model::ensure_model_exists(&app, &data_dir, &model_name).await?;
    let model_path_str = model_path.to_string_lossy().to_string();

    tokio::task::spawn_blocking(move || {
        transcribe::transcribe_audio(&model_path_str, &audio_path, language.as_deref())
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[tauri::command]
pub async fn transcribe_chunk(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<Mutex<transcribe::WhisperState>>>,
    samples_b64: String,
    model_name: String,
    language: Option<String>,
) -> Result<String, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    let model_path = model::ensure_model_exists(&app, &data_dir, &model_name).await?;
    let model_path_str = model_path.to_string_lossy().to_string();

    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(&samples_b64)
        .map_err(|e| format!("Base64 decode error: {}", e))?;

    let samples: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    if samples.is_empty() {
        return Ok(String::new());
    }

    {
        let mut ws = state.lock().map_err(|e| format!("Lock error: {}", e))?;
        ws.ensure_loaded(&model_path_str)?;
    }

    let state_clone = Arc::clone(&state);
    tokio::task::spawn_blocking(move || {
        let ws = state_clone.lock().map_err(|e| format!("Lock error: {}", e))?;
        ws.transcribe_samples(&samples, language.as_deref())
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[tauri::command]
pub async fn structure_transcript(
    api_key: String,
    transcript: String,
) -> Result<ai::StructuredOutput, String> {
    ai::structure_transcript(&api_key, &transcript).await
}

#[tauri::command]
pub fn get_app_data_dir(app: tauri::AppHandle) -> Result<String, String> {
    let path = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    Ok(path.to_string_lossy().to_string())
}

#[tauri::command]
pub async fn check_model_status(
    app: tauri::AppHandle,
    model_name: String,
) -> Result<bool, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    Ok(model::get_model_path(&data_dir, &model_name).is_some())
}

#[tauri::command]
pub async fn download_model(
    app: tauri::AppHandle,
    model_name: String,
) -> Result<String, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    let path = model::ensure_model_exists(&app, &data_dir, &model_name).await?;
    Ok(path.to_string_lossy().to_string())
}

// ──────────────────────────────────────────────────────────────
// Meeting capture commands
// ──────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn start_meeting_capture(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<Mutex<audio_capture::MeetingCaptureState>>>,
    session_id: String,
) -> Result<(), String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    let recordings_dir = data_dir.join("recordings");
    std::fs::create_dir_all(&recordings_dir)
        .map_err(|e| format!("Failed to create recordings dir: {}", e))?;

    let mut capture = state.lock().map_err(|e| format!("Lock error: {}", e))?;
    capture.start(recordings_dir, &session_id)
}

#[derive(serde::Serialize)]
pub struct MeetingCaptureResultPayload {
    pub mic_path: String,
    pub system_path: String,
    pub mixed_path: String,
    pub duration: f64,
}

#[tauri::command]
pub async fn stop_meeting_capture(
    state: tauri::State<'_, Arc<Mutex<audio_capture::MeetingCaptureState>>>,
) -> Result<MeetingCaptureResultPayload, String> {
    let mut capture = state.lock().map_err(|e| format!("Lock error: {}", e))?;
    let result = capture.stop()?;
    Ok(MeetingCaptureResultPayload {
        mic_path: result.mic_path,
        system_path: result.system_path,
        mixed_path: result.mixed_path,
        duration: result.duration_secs,
    })
}

#[derive(serde::Serialize)]
pub struct AudioLevels {
    pub mic_level: f32,
    pub system_level: f32,
}

#[tauri::command]
pub fn get_meeting_audio_levels(
    state: tauri::State<'_, Arc<Mutex<audio_capture::MeetingCaptureState>>>,
) -> Result<AudioLevels, String> {
    let capture = state.lock().map_err(|e| format!("Lock error: {}", e))?;
    let (mic, sys) = capture.get_levels();
    Ok(AudioLevels {
        mic_level: mic,
        system_level: sys,
    })
}

#[tauri::command]
pub fn check_screen_recording_permission() -> bool {
    audio_capture::check_screen_recording_permission()
}

#[tauri::command]
pub fn request_screen_recording_permission() -> bool {
    audio_capture::request_screen_recording_permission()
}

// ──────────────────────────────────────────────────────────────
// Meeting transcription + structuring
// ──────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn transcribe_meeting_cmd(
    app: tauri::AppHandle,
    mic_path: String,
    system_path: String,
    model_name: String,
    language: Option<String>,
) -> Result<transcribe::SegmentedTranscript, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    let whisper_model_path = model::ensure_model_exists(&app, &data_dir, &model_name).await?;
    let whisper_path_str = whisper_model_path.to_string_lossy().to_string();

    let (seg_path, emb_path) = model::ensure_pyannote_models(&app, &data_dir).await?;
    let seg_path_str = seg_path.to_string_lossy().to_string();
    let emb_path_str = emb_path.to_string_lossy().to_string();

    tokio::task::spawn_blocking(move || {
        transcribe::transcribe_meeting(
            &whisper_path_str,
            &mic_path,
            &system_path,
            &seg_path_str,
            &emb_path_str,
            language.as_deref(),
        )
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
}

#[tauri::command]
pub async fn structure_meeting_cmd(
    api_key: String,
    segments: Vec<transcribe::TranscriptSegment>,
) -> Result<ai::MeetingStructuredOutput, String> {
    ai::structure_meeting(&api_key, &segments).await
}

#[tauri::command]
pub async fn check_pyannote_models(
    app: tauri::AppHandle,
) -> Result<bool, String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;
    Ok(model::pyannote_models_ready(&data_dir))
}

#[tauri::command]
pub async fn download_pyannote_models(
    app: tauri::AppHandle,
) -> Result<(), String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;
    model::ensure_pyannote_models(&app, &data_dir).await?;
    Ok(())
}
