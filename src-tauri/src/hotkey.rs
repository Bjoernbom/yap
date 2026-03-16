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
    pub key: String,
}

impl Default for HotkeyConfig {
    fn default() -> Self {
        Self {
            key: "RightAlt".to_string(),
        }
    }
}

// macOS keycodes
pub fn config_to_keycode(s: &str) -> u16 {
    match s {
        "RightAlt" => 61,
        "LeftAlt" => 58,
        "RightControl" => 62,
        "LeftControl" => 59,
        "RightShift" => 60,
        "LeftShift" => 56,
        "RightMeta" | "RightCmd" => 54,
        "F5" => 96,
        "F6" => 97,
        "F7" => 98,
        "F8" => 100,
        "F9" => 101,
        "F10" => 109,
        "F11" => 103,
        "F12" => 111,
        "F13" => 105,
        "F14" => 107,
        "F15" => 113,
        "F16" => 106,
        "F17" => 64,
        "F18" => 79,
        "F19" => 80,
        _ => 61,
    }
}

fn is_modifier_key(keycode: u16) -> bool {
    matches!(keycode, 54 | 55 | 56 | 58 | 59 | 60 | 61 | 62)
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

    let target_keycode = {
        match ctx.config.lock() {
            Ok(c) => config_to_keycode(&c.key),
            Err(_) => return event,
        }
    };

    let keycode = ffi::CGEventGetIntegerValueField(event, ffi::kCGKeyboardEventKeycode) as u16;

    if keycode != target_keycode {
        return event;
    }

    let is_modifier = is_modifier_key(keycode);

    // Determine press/release
    let (is_press, is_release) = if is_modifier {
        let flags = ffi::CGEventGetFlags(event);
        let flag_active = match keycode {
            58 | 61 => (flags & 0x00080000) != 0,
            59 | 62 => (flags & 0x00040000) != 0,
            56 | 60 => (flags & 0x00020000) != 0,
            54 | 55 => (flags & 0x00100000) != 0,
            _ => false,
        };
        let was_held = ctx.is_held.load(Ordering::Relaxed);
        (flag_active && !was_held, !flag_active && was_held)
    } else {
        match event_type {
            ffi::kCGEventKeyDown => (!ctx.is_held.load(Ordering::Relaxed), false),
            ffi::kCGEventKeyUp => (false, ctx.is_held.load(Ordering::Relaxed)),
            _ => (false, false),
        }
    };

    if is_press {
        ctx.is_held.store(true, Ordering::Relaxed);

        // Check for double-tap
        let is_double = {
            if let Ok(mut last) = ctx.last_press.lock() {
                let now = Instant::now();
                let elapsed = now.duration_since(*last).as_millis();
                *last = now;
                elapsed < DOUBLE_TAP_MS
            } else {
                false
            }
        };

        if is_double {
            eprintln!("[hotkey] DOUBLE-TAP (keycode={})", keycode);
            let _ = ctx.tx.try_send(HotkeyEvent::ToggleLock);
        } else {
            eprintln!("[hotkey] press (keycode={})", keycode);
            let _ = ctx.tx.try_send(HotkeyEvent::Start);
        }
    } else if is_release {
        ctx.is_held.store(false, Ordering::Relaxed);

        if let Ok(mut last) = ctx.last_release.lock() {
            *last = Instant::now();
        }

        eprintln!("[hotkey] release (keycode={})", keycode);
        let _ = ctx.tx.try_send(HotkeyEvent::Stop);
    }

    event
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
