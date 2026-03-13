use futures_util::StreamExt;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Emitter};

use crate::diarize;

const BASE_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";

pub fn model_filename(model_name: &str) -> String {
    format!("ggml-{}.bin", model_name)
}

pub fn get_model_path(app_data_dir: &Path, model_name: &str) -> Option<PathBuf> {
    let path = app_data_dir.join("models").join(model_filename(model_name));
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

/// Get path to a pyannote model if it exists
pub fn get_pyannote_model_path(app_data_dir: &Path, filename: &str) -> Option<PathBuf> {
    let path = app_data_dir.join("models").join(filename);
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

/// Check if both pyannote models are downloaded
pub fn pyannote_models_ready(app_data_dir: &Path) -> bool {
    get_pyannote_model_path(app_data_dir, diarize::SEGMENTATION_MODEL).is_some()
        && get_pyannote_model_path(app_data_dir, diarize::EMBEDDING_MODEL).is_some()
}

/// List which models are downloaded
pub fn list_downloaded_models(app_data_dir: &Path) -> Vec<String> {
    let models = ["tiny", "base", "small", "medium", "large-v3", "large-v3-turbo"];
    models
        .iter()
        .filter(|m| get_model_path(app_data_dir, m).is_some())
        .map(|m| m.to_string())
        .collect()
}

pub async fn ensure_model_exists(
    app: &AppHandle,
    app_data_dir: &Path,
    model_name: &str,
) -> Result<PathBuf, String> {
    if let Some(path) = get_model_path(app_data_dir, model_name) {
        return Ok(path);
    }

    let models_dir = app_data_dir.join("models");
    std::fs::create_dir_all(&models_dir)
        .map_err(|e| format!("Failed to create models dir: {}", e))?;

    let filename = model_filename(model_name);
    let model_path = models_dir.join(&filename);
    let tmp_path = models_dir.join(format!("{}.tmp", filename));

    let url = format!("{}/{}", BASE_URL, filename);

    let response = reqwest::get(&url)
        .await
        .map_err(|e| format!("Failed to download model: {}", e))?;

    if !response.status().is_success() {
        return Err(format!("Download failed with status: {}", response.status()));
    }

    let total_size = response.content_length().unwrap_or(0);

    let _ = app.emit("model-download-progress", serde_json::json!({
        "downloaded": 0u64,
        "total": total_size,
    }));

    let mut stream = response.bytes_stream();
    let mut file = std::fs::File::create(&tmp_path)
        .map_err(|e| format!("Failed to create temp file: {}", e))?;

    let mut downloaded: u64 = 0;
    use std::io::Write;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Download error: {}", e))?;
        file.write_all(&chunk)
            .map_err(|e| format!("Write error: {}", e))?;
        downloaded += chunk.len() as u64;

        let _ = app.emit("model-download-progress", serde_json::json!({
            "downloaded": downloaded,
            "total": total_size,
        }));
    }

    file.flush().map_err(|e| format!("Flush error: {}", e))?;
    drop(file);

    std::fs::rename(&tmp_path, &model_path)
        .map_err(|e| format!("Failed to move model file: {}", e))?;

    Ok(model_path)
}

/// Download a file from URL to the models directory with progress events
async fn download_file(
    app: &AppHandle,
    models_dir: &Path,
    filename: &str,
    url: &str,
    event_name: &str,
) -> Result<PathBuf, String> {
    let file_path = models_dir.join(filename);
    if file_path.exists() {
        return Ok(file_path);
    }

    let tmp_path = models_dir.join(format!("{}.tmp", filename));

    let response = reqwest::get(url)
        .await
        .map_err(|e| format!("Failed to download {}: {}", filename, e))?;

    if !response.status().is_success() {
        return Err(format!("Download failed with status: {}", response.status()));
    }

    let total_size = response.content_length().unwrap_or(0);
    let _ = app.emit(event_name, serde_json::json!({ "downloaded": 0u64, "total": total_size, "model": filename }));

    let mut stream = response.bytes_stream();
    let mut file = std::fs::File::create(&tmp_path)
        .map_err(|e| format!("Failed to create temp file: {}", e))?;

    let mut downloaded: u64 = 0;
    use std::io::Write;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Download error: {}", e))?;
        file.write_all(&chunk)
            .map_err(|e| format!("Write error: {}", e))?;
        downloaded += chunk.len() as u64;

        let _ = app.emit(event_name, serde_json::json!({ "downloaded": downloaded, "total": total_size, "model": filename }));
    }

    file.flush().map_err(|e| format!("Flush error: {}", e))?;
    drop(file);

    std::fs::rename(&tmp_path, &file_path)
        .map_err(|e| format!("Failed to move file: {}", e))?;

    Ok(file_path)
}

/// Ensure both pyannote models are downloaded, returns (segmentation_path, embedding_path)
pub async fn ensure_pyannote_models(
    app: &AppHandle,
    app_data_dir: &Path,
) -> Result<(PathBuf, PathBuf), String> {
    let models_dir = app_data_dir.join("models");
    std::fs::create_dir_all(&models_dir)
        .map_err(|e| format!("Failed to create models dir: {}", e))?;

    let seg_path = download_file(
        app,
        &models_dir,
        diarize::SEGMENTATION_MODEL,
        diarize::SEGMENTATION_MODEL_URL,
        "model-download-progress",
    )
    .await?;

    let emb_path = download_file(
        app,
        &models_dir,
        diarize::EMBEDDING_MODEL,
        diarize::EMBEDDING_MODEL_URL,
        "model-download-progress",
    )
    .await?;

    Ok((seg_path, emb_path))
}
