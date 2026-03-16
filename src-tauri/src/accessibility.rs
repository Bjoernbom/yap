use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::CFString;

extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: *const core_foundation::base::CFTypeRef) -> bool;
    static kAXTrustedCheckOptionPrompt: core_foundation::string::CFStringRef;
}

/// Check if the app has accessibility permission (no prompt)
pub fn is_trusted() -> bool {
    unsafe { AXIsProcessTrusted() }
}

/// Check if the app has accessibility permission, showing system prompt if not
pub fn is_trusted_with_prompt() -> bool {
    unsafe {
        let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
        let value = CFBoolean::true_value();
        let dict = CFDictionary::from_CFType_pairs(&[(key, value)]);
        AXIsProcessTrustedWithOptions(dict.as_concrete_TypeRef() as *const _)
    }
}

/// Open System Settings to the Accessibility pane
pub fn open_accessibility_settings() -> Result<(), String> {
    std::process::Command::new("open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        .output()
        .map_err(|e| format!("Failed to open settings: {}", e))?;
    Ok(())
}
