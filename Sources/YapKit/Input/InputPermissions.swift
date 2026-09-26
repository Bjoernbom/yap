import ApplicationServices
import CoreFoundation
import CoreGraphics

/// Accessibility covers everything yap does with keys and text: the active event tap, AX
/// insertion and posting ⌘V.
public enum AccessibilityPermission {
	/// Live check; poll it while onboarding waits for the user to flip the switch.
	public static var isGranted: Bool { AXIsProcessTrusted() }

	/// Shows the system prompt (once per app identity) and returns the current state.
	@discardableResult
	public static func request() -> Bool {
		// The string literal avoids touching the imported `kAXTrustedCheckOptionPrompt`
		// global, which Swift 6 flags as not concurrency-safe.
		AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
	}

	/// Input Monitoring. yap should not need it when the active tap runs with Accessibility
	/// alone (open question from spike M0-IO); exposed for the Health row and diagnostics.
	public static var canListenToEvents: Bool { CGPreflightListenEventAccess() }
}

/// System Settings → Keyboard → "Press 🌐 key to". Anything but "Do Nothing" also fires
/// when the user releases Fn after dictating, so onboarding shows the fix.
public enum FnKeyUsage: Int, Sendable, CaseIterable {
	// Only 0 was observed in the spike; 1–3 follow the order in System Settings and still
	// need a manual check (spikes/io/MANUAL.md step 4).
	case doNothing = 0
	case changeInputSource = 1
	case showEmojiAndSymbols = 2
	case startDictation = 3

	/// The current setting, or nil when it is unset or a value we don't know.
	public static var current: FnKeyUsage? {
		let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
		return (value as? Int).flatMap(FnKeyUsage.init(rawValue:))
	}

	public var conflictsWithPushToTalk: Bool { self != .doNothing }
}
