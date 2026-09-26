import Carbon.HIToolbox
import CoreGraphics

/// Finds which physical key types a character in the current keyboard layout.
///
/// ⌘V has to be posted as a key code, and key codes are physical positions: `kVK_ANSI_V`
/// is ⌘K on Dvorak. Layouts like "Dvorak – QWERTY ⌘" switch to QWERTY while ⌘ is down,
/// so the lookup translates with ⌘ held.
enum KeyboardLayout {
	/// Searches the 128 virtual key codes for the one `translate` maps to `character`,
	/// trying `preferred` first because it is right for most layouts.
	static func keyCode(
		for character: Character,
		preferred: CGKeyCode? = nil,
		translate: (CGKeyCode) -> String?
	) -> CGKeyCode? {
		let wanted = String(character).lowercased()
		if let preferred, translate(preferred)?.lowercased() == wanted { return preferred }
		return (0..<128).map(CGKeyCode.init).first { translate($0)?.lowercased() == wanted }
	}

	/// The key code that types `character` with ⌘ held in the current layout. Text Input
	/// Sources must be used on the main thread (HIToolbox asserts on it).
	@MainActor
	static func currentKeyCode(for character: Character) -> CGKeyCode? {
		guard let layout = currentLayoutData() else { return nil }
		let keyboardType = UInt32(LMGetKbdType())
		return keyCode(for: character, preferred: CGKeyCode(kVK_ANSI_V)) { code in
			translate(code, layout: layout, keyboardType: keyboardType)
		}
	}

	@MainActor
	static func currentLayoutData() -> Data? {
		// Input methods (Japanese, Chinese) have no layout data themselves; the ASCII-capable
		// layout underneath is what ⌘ shortcuts use.
		let sources = [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource]
		for copy in sources {
			guard let source = copy()?.takeRetainedValue(),
				let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
			else { continue }
			return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
		}
		return nil
	}

	static func translate(_ keyCode: CGKeyCode, layout: Data, keyboardType: UInt32) -> String? {
		layout.withUnsafeBytes { raw -> String? in
			guard let base = raw.baseAddress else { return nil }
			let keyboardLayout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
			var deadKeyState: UInt32 = 0
			var length = 0
			var chars = [UniChar](repeating: 0, count: 4)
			let status = UCKeyTranslate(
				keyboardLayout,
				keyCode,
				UInt16(kUCKeyActionDown),
				UInt32((cmdKey >> 8) & 0xFF),
				keyboardType,
				OptionBits(kUCKeyTranslateNoDeadKeysMask),
				&deadKeyState,
				chars.count,
				&length,
				&chars
			)
			guard status == noErr, length > 0 else { return nil }
			return String(utf16CodeUnits: chars, count: length)
		}
	}
}
