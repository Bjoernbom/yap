use futures_util::StreamExt;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Emitter};

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

    let _ = app.emit(
        "model-download-progress",
        serde_json::json!({
            "downloaded": 0u64,
            "total": total_size,
        }),
    );

    let mut stream = response.bytes_stream();
    let mut file = std::fs::File::create(&tmp_path)
        .map_err(|e| format!("Failed to create temp file: {}", e))?;

    let mut downloaded: u64 = 0;
    use std::io::Write;

    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(c) => c,
            Err(e) => {
                drop(file);
                let _ = std::fs::remove_file(&tmp_path);
                return Err(format!("Download error: {}", e));
            }
        };
        if let Err(e) = file.write_all(&chunk) {
            drop(file);
            let _ = std::fs::remove_file(&tmp_path);
            return Err(format!("Write error: {}", e));
        }
        downloaded += chunk.len() as u64;

        let _ = app.emit(
            "model-download-progress",
            serde_json::json!({
                "downloaded": downloaded,
                "total": total_size,
            }),
        );
    }

    if let Err(e) = file.flush() {
        drop(file);
        let _ = std::fs::remove_file(&tmp_path);
        return Err(format!("Flush error: {}", e));
    }
    drop(file);

    if let Err(e) = std::fs::rename(&tmp_path, &model_path) {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(format!("Failed to move model file: {}", e));
    }

    Ok(model_path)
}
