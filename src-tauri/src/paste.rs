use arboard::Clipboard;
use std::process::Command;
use std::thread;
use std::time::Duration;

pub fn paste_text(text: &str) -> Result<(), String> {
    let mut clipboard =
        Clipboard::new().map_err(|e| format!("Failed to access clipboard: {}", e))?;

    // Save previous clipboard text (best-effort)
    let previous = clipboard.get_text().ok();

    // Set new text
    clipboard
        .set_text(text.to_string())
        .map_err(|e| format!("Failed to set clipboard: {}", e))?;

    // Small delay to let clipboard settle
    thread::sleep(Duration::from_millis(50));

    // Simulate Cmd+V using osascript (macOS)
    Command::new("osascript")
        .args([
            "-e",
            r#"tell application "System Events" to keystroke "v" using command down"#,
        ])
        .output()
        .map_err(|e| format!("Failed to simulate paste: {}", e))?;

    // Small delay before restoring
    thread::sleep(Duration::from_millis(100));

    // Restore previous clipboard (best-effort)
    if let Some(prev) = previous {
        let _ = clipboard.set_text(prev);
    }

    Ok(())
}
