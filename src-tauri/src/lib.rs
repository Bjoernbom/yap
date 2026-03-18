mod accessibility;
mod commands;
mod dictation;
mod hotkey;
mod mic_capture;
mod model;
mod paste;
mod refine;
mod transcribe;

use std::sync::{Arc, Mutex};
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let whisper = Arc::new(Mutex::new(transcribe::WhisperState::new()));
    let hotkey_config = hotkey::HotkeyConfig::default();
    let hotkey_listener = Arc::new(hotkey::HotkeyListener::new(hotkey_config));
    let dictation_manager = Arc::new(dictation::DictationManager::new(whisper.clone()));

    tauri::Builder::default()
        .plugin(tauri_plugin_sql::Builder::new().build())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(whisper)
        .manage(hotkey_listener.clone())
        .manage(dictation_manager.clone())
        .setup(move |app| {
            // Create overlay badge — always-on-top floating panel, separate from main window
            let overlay = tauri::WebviewWindowBuilder::new(
                app,
                "overlay",
                tauri::WebviewUrl::App("/overlay".into()),
            )
            .title("")
            .inner_size(160.0, 38.0)
            .decorations(false)
            .always_on_top(true)
            .focused(false)
            .visible(true)
            .resizable(false)
            .skip_taskbar(true)
            .build()
            .map_err(|e| {
                eprintln!("Failed to create overlay window: {}", e);
                e
            })
            .ok();

            eprintln!("[overlay] window created: {}", overlay.is_some());

            // Position overlay top-center, below menu bar
            if let Some(ref overlay) = overlay {
                if let Ok(Some(monitor)) = overlay.primary_monitor() {
                    let scale = monitor.scale_factor();
                    let screen_w = monitor.size().width as f64 / scale;
                    let x = (screen_w - 160.0) / 2.0;
                    // Flush with top — extends from notch
                    let _ = overlay.set_position(tauri::LogicalPosition::new(x, 0.0));
                    eprintln!("[overlay] positioned at ({}, 38), screen_w={}", x, screen_w);
                } else {
                    eprintln!("[overlay] no primary monitor found, centering");
                    let _ = overlay.center();
                }

            }

            // Check accessibility and prompt if needed
            if !accessibility::is_trusted() {
                eprintln!("[setup] Accessibility not granted, prompting...");
                accessibility::is_trusted_with_prompt();
            } else {
                eprintln!("[setup] Accessibility permission granted");
            }

            // Pre-load whisper model and start dictation in background
            let app_handle = app.handle().clone();
            let dm = dictation_manager.clone();
            let hl = hotkey_listener.clone();

            tauri::async_runtime::spawn(async move {
                let data_dir = match app_handle.path().app_data_dir() {
                    Ok(d) => d,
                    Err(_) => return,
                };

                // Try to load best available model
                for model_name in &["large-v3-turbo", "large-v3", "medium", "small", "base", "tiny"] {
                    if let Some(path) = model::get_model_path(&data_dir, model_name) {
                        let path_str = path.to_string_lossy().to_string();
                        let whisper = app_handle
                            .state::<Arc<Mutex<transcribe::WhisperState>>>();
                        let ws = whisper.inner().clone();
                        let _ = tauri::async_runtime::spawn_blocking(move || {
                            let mut ws = ws.lock().unwrap();
                            ws.ensure_loaded(&path_str)
                        })
                        .await;
                        break;
                    }
                }

                // Wait for accessibility permission before starting hotkey listener
                loop {
                    if accessibility::is_trusted() {
                        break;
                    }
                    eprintln!("[setup] Waiting for accessibility permission...");
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }

                eprintln!("[setup] Starting dictation listener");
                dm.start_listening(&hl, app_handle);
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_app_data_dir,
            commands::check_model_status,
            commands::download_model,
            commands::set_hotkey,
            commands::get_hotkey,
            commands::set_language,
            commands::set_mic_device,
            commands::set_prompt,
            commands::configure_overlay_window,
            commands::check_accessibility,
            commands::request_accessibility,
            commands::open_accessibility_settings,
            commands::set_api_key,
            commands::get_autostart,
            commands::set_autostart,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
