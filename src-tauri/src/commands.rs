use std::sync::{Arc, Mutex};
use tauri::Manager;

use crate::accessibility;
use crate::dictation::DictationManager;
use crate::hotkey::{HotkeyConfig, HotkeyListener};
use crate::model;
use crate::transcribe;

#[tauri::command]
pub fn get_app_data_dir(app: tauri::AppHandle) -> Result<String, String> {
    let path = app.path().app_data_dir().map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().to_string())
}

#[tauri::command]
pub async fn check_model_status(
    app: tauri::AppHandle,
    model_name: String,
) -> Result<bool, String> {
    let data_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    Ok(model::get_model_path(&data_dir, &model_name).is_some())
}

#[tauri::command]
pub async fn download_model(
    app: tauri::AppHandle,
    model_name: String,
) -> Result<String, String> {
    let data_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;

    let path = model::ensure_model_exists(&app, &data_dir, &model_name).await?;

    // Pre-load the model into WhisperState
    let whisper = app.state::<Arc<Mutex<transcribe::WhisperState>>>();
    let model_path_str = path.to_string_lossy().to_string();
    let ws = whisper.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let mut ws = ws.lock().map_err(|e| format!("Lock error: {}", e))?;
        ws.ensure_loaded(&model_path_str)
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))??;

    Ok(path.to_string_lossy().to_string())
}

#[tauri::command]
pub fn set_hotkey(
    app: tauri::AppHandle,
    key: String,
) -> Result<(), String> {
    let listener = app.state::<Arc<HotkeyListener>>();
    listener.set_config(HotkeyConfig { key });
    Ok(())
}

#[tauri::command]
pub fn set_language(
    app: tauri::AppHandle,
    language: String,
) -> Result<(), String> {
    let dictation = app.state::<Arc<DictationManager>>();
    dictation.set_language(language);
    Ok(())
}

#[tauri::command]
pub fn set_mic_device(
    app: tauri::AppHandle,
    device_name: Option<String>,
) -> Result<(), String> {
    let dictation = app.state::<Arc<DictationManager>>();
    dictation.set_mic_device(device_name);
    Ok(())
}

#[tauri::command]
pub fn get_hotkey(app: tauri::AppHandle) -> Result<String, String> {
    let listener = app.state::<Arc<HotkeyListener>>();
    Ok(listener.get_config().key)
}

#[tauri::command]
pub fn set_prompt(
    app: tauri::AppHandle,
    prompt: String,
) -> Result<(), String> {
    let dictation = app.state::<Arc<DictationManager>>();
    dictation.set_prompt(prompt);
    Ok(())
}

#[tauri::command]
pub fn configure_overlay_window(app: tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        if let Some(overlay) = app.get_webview_window("overlay") {
            if let Ok(ns_win) = overlay.ns_window() {
                extern "C" {
                    fn objc_msgSend(obj: *mut std::ffi::c_void, sel: *const std::ffi::c_void, ...);
                    fn sel_registerName(name: *const u8) -> *const std::ffi::c_void;
                    fn object_setClass(obj: *mut std::ffi::c_void, cls: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
                    fn objc_getClass(name: *const u8) -> *mut std::ffi::c_void;
                }
                unsafe {
                    let win = ns_win as *mut std::ffi::c_void;

                    // Convert NSWindow → NSPanel (NSPanel is a subclass of NSWindow)
                    let panel_class = objc_getClass(b"NSPanel\0".as_ptr());
                    if !panel_class.is_null() {
                        object_setClass(win, panel_class);
                        eprintln!("[overlay] converted to NSPanel");
                    }

                    // setFloatingPanel: YES — stays above other windows
                    let sel = sel_registerName(b"setFloatingPanel:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 1);

                    // setWorksWhenModal: YES — visible even during modal dialogs
                    let sel = sel_registerName(b"setWorksWhenModal:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 1);

                    // setHidesOnDeactivate: NO — don't hide when app loses focus
                    let sel = sel_registerName(b"setHidesOnDeactivate:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 0);

                    // setLevel: NSStatusWindowLevel (25) — above all normal windows
                    let sel = sel_registerName(b"setLevel:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i64) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 25);

                    // setCollectionBehavior:
                    //   canJoinAllSpaces(1) | fullScreenAuxiliary(256) | stationary(16) | ignoresCycle(64)
                    let sel = sel_registerName(b"setCollectionBehavior:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, u64) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 1 | 16 | 64 | 256);

                    // setMovableByWindowBackground: YES — drag from anywhere
                    let sel = sel_registerName(b"setMovableByWindowBackground:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 1);

                    // setBecomesKeyOnlyIfNeeded: YES — don't steal focus
                    let sel = sel_registerName(b"setBecomesKeyOnlyIfNeeded:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 1);

                    // setStyleMask: add NSNonactivatingPanelMask (1 << 7 = 128)
                    let sel = sel_registerName(b"styleMask\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> u64 =
                        std::mem::transmute(objc_msgSend as *const ());
                    let current_mask = f(win, sel);

                    let sel = sel_registerName(b"setStyleMask:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, u64) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, current_mask | 128); // NSNonactivatingPanelMask

                    // setOpaque: NO — allow transparency
                    let sel = sel_registerName(b"setOpaque:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 0);

                    // setHasShadow: NO — remove grey border/shadow
                    let sel = sel_registerName(b"setHasShadow:\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                        std::mem::transmute(objc_msgSend as *const ());
                    f(win, sel, 0);

                    // setBackgroundColor: [NSColor clearColor]
                    let ns_color_class = objc_getClass(b"NSColor\0".as_ptr());
                    if !ns_color_class.is_null() {
                        let sel = sel_registerName(b"clearColor\0".as_ptr());
                        let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> *mut std::ffi::c_void =
                            std::mem::transmute(objc_msgSend as *const ());
                        let clear_color = f(ns_color_class, sel);

                        let sel = sel_registerName(b"setBackgroundColor:\0".as_ptr());
                        let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, *mut std::ffi::c_void) =
                            std::mem::transmute(objc_msgSend as *const ());
                        f(win, sel, clear_color);
                    }

                    // Make contentView transparent too
                    let sel = sel_registerName(b"contentView\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> *mut std::ffi::c_void =
                        std::mem::transmute(objc_msgSend as *const ());
                    let content_view = f(win, sel);

                    if !content_view.is_null() {
                        // contentView.wantsLayer = YES
                        let sel = sel_registerName(b"setWantsLayer:\0".as_ptr());
                        let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) =
                            std::mem::transmute(objc_msgSend as *const ());
                        f(content_view, sel, 1);

                        // contentView.layer.backgroundColor = nil (transparent)
                        let sel = sel_registerName(b"layer\0".as_ptr());
                        let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> *mut std::ffi::c_void =
                            std::mem::transmute(objc_msgSend as *const ());
                        let layer = f(content_view, sel);

                        if !layer.is_null() {
                            // CGColorCreateGenericRGB(0,0,0,0) for transparent
                            extern "C" {
                                fn CGColorCreateGenericRGB(r: f64, g: f64, b: f64, a: f64) -> *mut std::ffi::c_void;
                            }
                            let transparent_cg = CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.0);
                            let sel = sel_registerName(b"setBackgroundColor:\0".as_ptr());
                            let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, *mut std::ffi::c_void) =
                                std::mem::transmute(objc_msgSend as *const ());
                            f(layer, sel, transparent_cg);
                        }

                        // Find WKWebView in subviews and disable its background
                        let sel = sel_registerName(b"subviews\0".as_ptr());
                        let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> *mut std::ffi::c_void =
                            std::mem::transmute(objc_msgSend as *const ());
                        let subviews = f(content_view, sel);

                        if !subviews.is_null() {
                            let sel = sel_registerName(b"count\0".as_ptr());
                            let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> u64 =
                                std::mem::transmute(objc_msgSend as *const ());
                            let count = f(subviews, sel);

                            for i in 0..count {
                                let sel = sel_registerName(b"objectAtIndex:\0".as_ptr());
                                let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, u64) -> *mut std::ffi::c_void =
                                    std::mem::transmute(objc_msgSend as *const ());
                                let subview = f(subviews, sel, i);

                                if !subview.is_null() {
                                    // Try setValue:NO forKey:drawsBackground on each subview
                                    let key_class = objc_getClass(b"NSString\0".as_ptr());
                                    if !key_class.is_null() {
                                        let sel = sel_registerName(b"stringWithUTF8String:\0".as_ptr());
                                        let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, *const u8) -> *mut std::ffi::c_void =
                                            std::mem::transmute(objc_msgSend as *const ());
                                        let key = f(key_class, sel, b"drawsBackground\0".as_ptr());

                                        let ns_number_class = objc_getClass(b"NSNumber\0".as_ptr());
                                        if !ns_number_class.is_null() {
                                            let sel = sel_registerName(b"numberWithBool:\0".as_ptr());
                                            let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, i8) -> *mut std::ffi::c_void =
                                                std::mem::transmute(objc_msgSend as *const ());
                                            let no_val = f(ns_number_class, sel, 0);

                                            let sel = sel_registerName(b"setValue:forKey:\0".as_ptr());
                                            let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void, *mut std::ffi::c_void, *mut std::ffi::c_void) =
                                                std::mem::transmute(objc_msgSend as *const ());
                                            f(subview, sel, no_val, key);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    eprintln!("[overlay] set fully transparent background");

                    // Verify
                    let sel = sel_registerName(b"level\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> i64 =
                        std::mem::transmute(objc_msgSend as *const ());
                    let level = f(win, sel);

                    let sel = sel_registerName(b"isFloatingPanel\0".as_ptr());
                    let f: unsafe extern "C" fn(*mut std::ffi::c_void, *const std::ffi::c_void) -> i8 =
                        std::mem::transmute(objc_msgSend as *const ());
                    let floating = f(win, sel);

                    eprintln!("[overlay] NSPanel configured — level={}, floating={}", level, floating);
                }
            } else {
                return Err("Failed to get NSWindow".to_string());
            }
        } else {
            return Err("Overlay window not found".to_string());
        }
    }
    Ok(())
}

#[tauri::command]
pub fn set_api_key(
    app: tauri::AppHandle,
    key: Option<String>,
) -> Result<(), String> {
    let dictation = app.state::<Arc<DictationManager>>();
    dictation.set_api_key(key);
    Ok(())
}

#[tauri::command]
pub fn get_autostart(app: tauri::AppHandle) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn set_autostart(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    use tauri_plugin_autostart::ManagerExt;
    if enabled {
        app.autolaunch().enable().map_err(|e| e.to_string())
    } else {
        app.autolaunch().disable().map_err(|e| e.to_string())
    }
}

#[tauri::command]
pub fn check_accessibility() -> bool {
    accessibility::is_trusted()
}

#[tauri::command]
pub fn request_accessibility() -> bool {
    accessibility::is_trusted_with_prompt()
}

#[tauri::command]
pub fn open_accessibility_settings() -> Result<(), String> {
    accessibility::open_accessibility_settings()
}
