use crossbeam_channel::Receiver;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

#[derive(Debug, Clone)]
pub enum HotkeyEvent {
    Start,
    Stop,
    ToggleLock, // double-tap: lock dictation on/off
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct HotkeyConfig {
    pub key: String, // e.g. "AltRight" or "MetaRight+KeyR"
}

impl Default for HotkeyConfig {
    fn default() -> Self {
        Self {
            key: "AltRight".to_string(),
        }
    }
}

/// Parsed hotkey combo: required modifier flags + a primary key
#[derive(Debug, Clone)]
struct ParsedHotkey {
    /// Required CGEvent modifier flags (mask)
    required_flags: u64,
    /// The primary (non-modifier) keycode to detect, if any
    primary_keycode: Option<u16>,
    /// If the hotkey IS a lone modifier key (no primary key)
    lone_modifier_keycode: Option<u16>,
}

// macOS modifier flag masks
const FLAG_SHIFT: u64   = 0x00020000;
const FLAG_CONTROL: u64 = 0x00040000;
const FLAG_ALT: u64     = 0x00080000;
const FLAG_CMD: u64     = 0x00100000;

fn code_to_keycode(s: &str) -> Option<u16> {
    Some(match s {
        // Modifiers
        "AltRight" | "RightAlt" => 61,
        "AltLeft" | "LeftAlt" => 58,
        "ControlRight" | "RightControl" => 62,
        "ControlLeft" | "LeftControl" => 59,
        "ShiftRight" | "RightShift" => 60,
        "ShiftLeft" | "LeftShift" => 56,
        "MetaRight" | "RightMeta" | "RightCmd" => 54,
        "MetaLeft" | "LeftMeta" | "LeftCmd" => 55,

        // Function keys
        "F1" => 122, "F2" => 120, "F3" => 99, "F4" => 118,
        "F5" => 96, "F6" => 97, "F7" => 98, "F8" => 100,
        "F9" => 101, "F10" => 109, "F11" => 103, "F12" => 111,
        "F13" => 105, "F14" => 107, "F15" => 113,
        "F16" => 106, "F17" => 64, "F18" => 79, "F19" => 80, "F20" => 90,

        // Letters
        "KeyA" => 0, "KeyB" => 11, "KeyC" => 8, "KeyD" => 2,
        "KeyE" => 14, "KeyF" => 3, "KeyG" => 5, "KeyH" => 4,
        "KeyI" => 34, "KeyJ" => 38, "KeyK" => 40, "KeyL" => 37,
        "KeyM" => 46, "KeyN" => 45, "KeyO" => 31, "KeyP" => 35,
        "KeyQ" => 12, "KeyR" => 15, "KeyS" => 1, "KeyT" => 17,
        "KeyU" => 32, "KeyV" => 9, "KeyW" => 13, "KeyX" => 7,
        "KeyY" => 16, "KeyZ" => 6,

        // Digits
        "Digit0" => 29, "Digit1" => 18, "Digit2" => 19, "Digit3" => 20,
        "Digit4" => 21, "Digit5" => 23, "Digit6" => 22, "Digit7" => 26,
        "Digit8" => 28, "Digit9" => 25,

        // Special
        "Space" => 49,
        "Tab" => 48,
        "CapsLock" => 57,
        "Backquote" => 50,
        "Escape" => 53,

        _ => return None,
    })
}

fn is_modifier_code(s: &str) -> bool {
    matches!(s,
        "AltRight" | "AltLeft" | "RightAlt" | "LeftAlt" |
        "ControlRight" | "ControlLeft" | "RightControl" | "LeftControl" |
        "ShiftRight" | "ShiftLeft" | "RightShift" | "LeftShift" |
        "MetaRight" | "MetaLeft" | "RightMeta" | "LeftMeta" | "RightCmd" | "LeftCmd"
    )
}

fn modifier_flag(s: &str) -> u64 {
    match s {
        "AltRight" | "AltLeft" | "RightAlt" | "LeftAlt" => FLAG_ALT,
        "ControlRight" | "ControlLeft" | "RightControl" | "LeftControl" => FLAG_CONTROL,
        "ShiftRight" | "ShiftLeft" | "RightShift" | "LeftShift" => FLAG_SHIFT,
        "MetaRight" | "MetaLeft" | "RightMeta" | "LeftMeta" | "RightCmd" | "LeftCmd" => FLAG_CMD,
        _ => 0,
    }
}

fn is_modifier_keycode(keycode: u16) -> bool {
    matches!(keycode, 54 | 55 | 56 | 58 | 59 | 60 | 61 | 62)
}

/// Parse "MetaRight+KeyR" or "AltRight" into a ParsedHotkey
fn parse_hotkey(config: &str) -> ParsedHotkey {
    let parts: Vec<&str> = config.split('+').collect();
    let mut required_flags: u64 = 0;
    let mut primary_keycode: Option<u16> = None;
    let mut lone_modifier_keycode: Option<u16> = None;

    for part in &parts {
        if is_modifier_code(part) {
            required_flags |= modifier_flag(part);
        } else {
            primary_keycode = code_to_keycode(part);
        }
    }

    // If all parts are modifiers (e.g. "AltRight"), the last one is the "trigger"
    if primary_keycode.is_none() {
        if let Some(last) = parts.last() {
            lone_modifier_keycode = code_to_keycode(last);
            // For lone modifier, remove its flag from required (it IS the trigger)
            required_flags &= !modifier_flag(last);
        }
    }

    ParsedHotkey {
        required_flags,
        primary_keycode,
        lone_modifier_keycode,
    }
}

pub struct HotkeyListener {
    config: Arc<Mutex<HotkeyConfig>>,
    _thread: std::thread::JoinHandle<()>,
    pub rx: Receiver<HotkeyEvent>,
}

impl HotkeyListener {
    pub fn new(config: HotkeyConfig) -> Self {
        let (tx, rx) = crossbeam_channel::bounded::<HotkeyEvent>(64);
        let config = Arc::new(Mutex::new(config));
        let config_clone = config.clone();

        let _thread = std::thread::spawn(move || {
            eprintln!("[hotkey] starting CGEventTap listener");
            unsafe { run_event_tap(config_clone, tx) };
            eprintln!("[hotkey] CGEventTap listener exited");
        });

        Self {
            config,
            _thread,
            rx,
        }
    }

    pub fn set_config(&self, new_config: HotkeyConfig) {
        if let Ok(mut c) = self.config.lock() {
            *c = new_config;
        }
    }

    pub fn get_config(&self) -> HotkeyConfig {
        self.config.lock().unwrap().clone()
    }
}

// Raw macOS CGEventTap implementation
mod ffi {
    #![allow(non_upper_case_globals, non_camel_case_types)]

    pub type CGEventRef = *mut std::ffi::c_void;
    pub type CGEventTapProxy = *mut std::ffi::c_void;
    pub type CFMachPortRef = *mut std::ffi::c_void;
    pub type CFRunLoopSourceRef = *mut std::ffi::c_void;
    pub type CFRunLoopRef = *mut std::ffi::c_void;
    pub type CFStringRef = *const std::ffi::c_void;

    pub type CGEventMask = u64;
    pub type CGEventType = u32;
    pub type CGEventField = u32;

    pub const kCGEventKeyDown: CGEventType = 10;
    pub const kCGEventKeyUp: CGEventType = 11;
    pub const kCGEventFlagsChanged: CGEventType = 12;
    pub const kCGKeyboardEventKeycode: CGEventField = 9;

    pub const kCGEventTapOptionListenOnly: u32 = 1;

    pub type CGEventTapCallBack = unsafe extern "C" fn(
        proxy: CGEventTapProxy,
        event_type: CGEventType,
        event: CGEventRef,
        user_info: *mut std::ffi::c_void,
    ) -> CGEventRef;

    extern "C" {
        pub static kCFRunLoopCommonModes: CFStringRef;

        pub fn CGEventTapCreate(
            tap: u32,
            place: u32,
            options: u32,
            events_of_interest: CGEventMask,
            callback: CGEventTapCallBack,
            user_info: *mut std::ffi::c_void,
        ) -> CFMachPortRef;

        pub fn CGEventGetIntegerValueField(event: CGEventRef, field: CGEventField) -> i64;
        pub fn CGEventGetFlags(event: CGEventRef) -> u64;

        pub fn CFMachPortCreateRunLoopSource(
            allocator: *const std::ffi::c_void,
            port: CFMachPortRef,
            order: i64,
        ) -> CFRunLoopSourceRef;

        pub fn CFRunLoopGetCurrent() -> CFRunLoopRef;

        pub fn CFRunLoopAddSource(
            rl: CFRunLoopRef,
            source: CFRunLoopSourceRef,
            mode: CFStringRef,
        );

        pub fn CFRunLoopRun();

        pub fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);
    }
}

struct TapContext {
    config: Arc<Mutex<HotkeyConfig>>,
    tx: crossbeam_channel::Sender<HotkeyEvent>,
    is_held: AtomicBool,
    // Double-tap detection
    last_press: Mutex<Instant>,
    last_release: Mutex<Instant>,
}

const DOUBLE_TAP_MS: u128 = 350;

unsafe extern "C" fn tap_callback(
    _proxy: ffi::CGEventTapProxy,
    event_type: ffi::CGEventType,
    event: ffi::CGEventRef,
    user_info: *mut std::ffi::c_void,
) -> ffi::CGEventRef {
    if user_info.is_null() || event.is_null() {
        return event;
    }

    if event_type == 0xFFFFFFFF {
        return event;
    }

    let ctx = &*(user_info as *const TapContext);

    let hotkey = {
        match ctx.config.lock() {
            Ok(c) => parse_hotkey(&c.key),
            Err(_) => return event,
        }
    };

    let keycode = ffi::CGEventGetIntegerValueField(event, ffi::kCGKeyboardEventKeycode) as u16;
    let flags = ffi::CGEventGetFlags(event);

    // Check if required modifier flags are active (mask out device-specific bits)
    let modifier_flags = flags & (FLAG_SHIFT | FLAG_CONTROL | FLAG_ALT | FLAG_CMD);
    let modifiers_match = (modifier_flags & hotkey.required_flags) == hotkey.required_flags;

    if let Some(primary) = hotkey.primary_keycode {
        // Combo hotkey: modifiers + primary key (e.g. Cmd+R)
        if keycode != primary {
            return event;
        }
        if !modifiers_match {
            return event;
        }

        match event_type {
            ffi::kCGEventKeyDown => {
                if ctx.is_held.load(Ordering::Relaxed) {
                    return event; // key repeat
                }
                ctx.is_held.store(true, Ordering::Relaxed);

                let is_double = check_double_tap(&ctx.last_press);
                if is_double {
                    eprintln!("[hotkey] DOUBLE-TAP combo (keycode={})", keycode);
                    let _ = ctx.tx.try_send(HotkeyEvent::ToggleLock);
                } else {
                    eprintln!("[hotkey] combo press (keycode={})", keycode);
                    let _ = ctx.tx.try_send(HotkeyEvent::Start);
                }
            }
            ffi::kCGEventKeyUp => {
                if !ctx.is_held.load(Ordering::Relaxed) {
                    return event;
                }
                ctx.is_held.store(false, Ordering::Relaxed);
                if let Ok(mut last) = ctx.last_release.lock() {
                    *last = Instant::now();
                }
                eprintln!("[hotkey] combo release (keycode={})", keycode);
                let _ = ctx.tx.try_send(HotkeyEvent::Stop);
            }
            _ => {}
        }
    } else if let Some(mod_key) = hotkey.lone_modifier_keycode {
        // Lone modifier hotkey (e.g. just AltRight, or Cmd+ShiftRight)
        if keycode != mod_key {
            return event;
        }
        if !modifiers_match {
            return event;
        }

        // Detect press/release via flags
        let flag_active = match keycode {
            58 | 61 => (flags & FLAG_ALT) != 0,
            59 | 62 => (flags & FLAG_CONTROL) != 0,
            56 | 60 => (flags & FLAG_SHIFT) != 0,
            54 | 55 => (flags & FLAG_CMD) != 0,
            _ => false,
        };
        let was_held = ctx.is_held.load(Ordering::Relaxed);

        if flag_active && !was_held {
            ctx.is_held.store(true, Ordering::Relaxed);

            let is_double = check_double_tap(&ctx.last_press);
            if is_double {
                eprintln!("[hotkey] DOUBLE-TAP modifier (keycode={})", keycode);
                let _ = ctx.tx.try_send(HotkeyEvent::ToggleLock);
            } else {
                eprintln!("[hotkey] modifier press (keycode={})", keycode);
                let _ = ctx.tx.try_send(HotkeyEvent::Start);
            }
        } else if !flag_active && was_held {
            ctx.is_held.store(false, Ordering::Relaxed);
            if let Ok(mut last) = ctx.last_release.lock() {
                *last = Instant::now();
            }
            eprintln!("[hotkey] modifier release (keycode={})", keycode);
            let _ = ctx.tx.try_send(HotkeyEvent::Stop);
        }
    }

    event
}

fn check_double_tap(last_press: &Mutex<Instant>) -> bool {
    if let Ok(mut last) = last_press.lock() {
        let now = Instant::now();
        let elapsed = now.duration_since(*last).as_millis();
        *last = now;
        elapsed < DOUBLE_TAP_MS
    } else {
        false
    }
}

unsafe fn run_event_tap(
    config: Arc<Mutex<HotkeyConfig>>,
    tx: crossbeam_channel::Sender<HotkeyEvent>,
) {
    let ctx = Box::new(TapContext {
        config,
        tx,
        is_held: AtomicBool::new(false),
        last_press: Mutex::new(Instant::now() - std::time::Duration::from_secs(10)),
        last_release: Mutex::new(Instant::now() - std::time::Duration::from_secs(10)),
    });
    let ctx_ptr = Box::into_raw(ctx) as *mut std::ffi::c_void;

    let event_mask: ffi::CGEventMask = (1 << ffi::kCGEventKeyDown)
        | (1 << ffi::kCGEventKeyUp)
        | (1 << ffi::kCGEventFlagsChanged);

    let tap = ffi::CGEventTapCreate(
        1, // kCGSessionEventTap
        0, // kCGHeadInsertEventTap
        ffi::kCGEventTapOptionListenOnly,
        event_mask,
        tap_callback,
        ctx_ptr,
    );

    if tap.is_null() {
        eprintln!("[hotkey] Failed to create CGEventTap — need Accessibility permission");
        let _ = Box::from_raw(ctx_ptr as *mut TapContext);
        return;
    }

    let source = ffi::CFMachPortCreateRunLoopSource(std::ptr::null(), tap, 0);
    if source.is_null() {
        eprintln!("[hotkey] Failed to create run loop source");
        let _ = Box::from_raw(ctx_ptr as *mut TapContext);
        return;
    }

    let run_loop = ffi::CFRunLoopGetCurrent();
    ffi::CFRunLoopAddSource(run_loop, source, ffi::kCFRunLoopCommonModes);
    ffi::CGEventTapEnable(tap, true);

    eprintln!("[hotkey] CGEventTap active, listening for keys");
    ffi::CFRunLoopRun();

    let _ = Box::from_raw(ctx_ptr as *mut TapContext);
}
