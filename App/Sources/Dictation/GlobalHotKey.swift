import Carbon.HIToolbox
import OSLog

/// A system-wide key combo (⌃⌘V for paste last) that works while another app
/// is frontmost, which a menu item's key equivalent does not.
///
/// Carbon's `RegisterEventHotKey` rather than the dictation event tap: it
/// needs no permission, the system swallows the combo for us, and the tap
/// stays focused on the push-to-talk key. The key code is a physical
/// position (ANSI V), which is V on the layouts yap targets.
@MainActor
final class GlobalHotKey {
	private var hotKey: EventHotKeyRef?
	private var handler: EventHandlerRef?
	private let action: @MainActor () -> Void

	init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
		self.action = action
		var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		let target = GetApplicationEventTarget()
		let userData = Unmanaged.passUnretained(self).toOpaque()
		let installed = InstallEventHandler(target, Self.callback(), 1, &spec, userData, &handler)
		let id = EventHotKeyID(signature: OSType(0x7961_7070), id: 1) // "yapp"
		let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, target, 0, &hotKey)
		if installed != noErr || registered != noErr {
			// Another app owns the combo; the menu item still works.
			Logger.dictation.error("Global hot key unavailable (handler \(installed, privacy: .public), register \(registered, privacy: .public))")
		}
	}

	isolated deinit {
		if let hotKey { UnregisterEventHotKey(hotKey) }
		if let handler { RemoveEventHandler(handler) }
	}

	private func fire() {
		action()
	}

	/// Built outside the main actor on purpose: a C callback written inside
	/// actor-isolated code inherits that isolation (see `HotkeyMonitor`).
	/// Carbon delivers hot key events on the main thread.
	private nonisolated static func callback() -> EventHandlerUPP {
		{ _, _, userData in
			// An address is Sendable, a raw pointer isn't.
			let address = Int(bitPattern: userData)
			MainActor.assumeIsolated {
				guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
				Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().fire()
			}
			return noErr
		}
	}
}
