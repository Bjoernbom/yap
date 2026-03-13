mod ai;
mod audio_capture;
mod commands;
mod diarize;
mod model;
mod transcribe;

use std::sync::{Arc, Mutex};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_sql::Builder::new().build())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(Arc::new(Mutex::new(transcribe::WhisperState::new())))
        .manage(Arc::new(Mutex::new(audio_capture::MeetingCaptureState::new())))
        .invoke_handler(tauri::generate_handler![
            commands::save_recording,
            commands::delete_recording,
            commands::transcribe_cmd,
            commands::transcribe_chunk,
            commands::structure_transcript,
            commands::get_app_data_dir,
            commands::check_model_status,
            commands::download_model,
            commands::start_meeting_capture,
            commands::stop_meeting_capture,
            commands::get_meeting_audio_levels,
            commands::check_screen_recording_permission,
            commands::request_screen_recording_permission,
            commands::transcribe_meeting_cmd,
            commands::structure_meeting_cmd,
            commands::check_pyannote_models,
            commands::download_pyannote_models,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
