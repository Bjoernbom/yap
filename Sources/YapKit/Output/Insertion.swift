import Darwin

/// The app that had focus when the user pressed the key.
public struct FocusTarget: Sendable, Equatable {
	public var pid: pid_t
	public var bundleID: String?

	public init(pid: pid_t, bundleID: String?) {
		self.pid = pid
		self.bundleID = bundleID
	}
}

public enum InsertOutcome: Sendable, Equatable {
	/// Set directly through Accessibility and read back.
	case ax
	/// Typed straight into one of yap's own windows through AppKit.
	case direct
	/// Pasted; the user's clipboard was restored.
	case paste
	/// Password field: nothing typed.
	case secureField
	/// No text field to type into.
	case noTarget
	/// Focus moved to another app since key-down: nothing typed.
	case focusChanged
	case failed
}

public protocol TextInserter: Sendable {
	/// Call on key-down.
	func captureTarget() async -> FocusTarget?
	/// Never types into anything but `target`.
	func insert(_ text: String, into target: FocusTarget) async -> InsertOutcome
}
