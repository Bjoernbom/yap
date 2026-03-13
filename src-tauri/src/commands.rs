use tauri::Manager;

/// Process an audio file: transcribe and generate structured output.
/// This is the core pipeline that will integrate whisper.cpp and AI APIs.
#[tauri::command]
pub async fn process_audio(app: tauri::AppHandle, audio_path: String) -> Result<String, String> {
    // TODO: Phase 1 - integrate whisper-rs for local transcription
    // TODO: Phase 2 - send transcript to Claude API for structuring
    Ok(format!("Processing: {}", audio_path))
}

/// Get the app data directory for storing recordings and database.
#[tauri::command]
pub fn get_app_data_dir(app: tauri::AppHandle) -> Result<String, String> {
    let path = app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?;

    Ok(path.to_string_lossy().to_string())
}
