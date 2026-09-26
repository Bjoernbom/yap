import Carbon.HIToolbox
import OSLog

/// A system-wide key combo (⌃⌘V for paste last, ⌥⌘N for notes) that works
/// while another app is frontmost, which a menu item's key equivalent does not.
///
/// Carbon's `RegisterEventHotKey` rather than the dictation event tap: it
/// needs no permission, the system swallows the combo for us, and the tap
/// stays focused on the push-to-talk key. The key code is a physical
/// position (ANSI V), which is V on the layouts yap targets.
@MainActor
final class GlobalHotKey {
	private var hotKey: EventHotKeyRef?
	private var handler: EventHandlerRef?
	private let id: UInt32
	private let action: @MainActor () -> Void

	/// - Parameter id: unique per combo. Every instance's handler sees every
	///   yap hot key, so each one only acts on its own id.
	init(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
		self.id = id
		self.action = action
		var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		let target = GetApplicationEventTarget()
		let userData = Unmanaged.passUnretained(self).toOpaque()
		let installed = InstallEventHandler(target, Self.callback(), 1, &spec, userData, &handler)
		let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
		let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, target, 0, &hotKey)
		if installed != noErr || registered != noErr {
			// Another app owns the combo; the menu item still works.
			Logger.dictation.error("Global hot key unavailable (handler \(installed, privacy: .public), register \(registered, privacy: .public))")
		}
	}

	isolated deinit {
		if let hotKey { UnregisterEventHotKey(hotKey) }
		if let handler { RemoveEventHandler(handler) }
	}

	private nonisolated static let signature = OSType(0x7961_7070) // "yapp"

	private func fire() {
		action()
	}

	/// Built outside the main actor on purpose: a C callback written inside
	/// actor-isolated code inherits that isolation (see `HotkeyMonitor`).
	/// Carbon delivers hot key events on the main thread.
	private nonisolated static func callback() -> EventHandlerUPP {
		{ _, event, userData in
			var pressed = EventHotKeyID()
			let status = GetEventParameter(
				event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
				nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
			guard status == noErr, pressed.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
			// An address is Sendable, a raw pointer isn't.
			let address = Int(bitPattern: userData)
			let handled = MainActor.assumeIsolated { () -> Bool in
				guard let pointer = UnsafeRawPointer(bitPattern: address) else { return false }
				let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
				guard hotKey.id == pressed.id else { return false }
				hotKey.fire()
				return true
			}
			// Not ours: let the next handler (another GlobalHotKey) have it.
			return handled ? noErr : OSStatus(eventNotHandledErr)
		}
	}
}
