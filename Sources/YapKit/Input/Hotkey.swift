/// The key the user holds to talk.
public enum HotkeyTrigger: String, Sendable, Codable, CaseIterable {
	case fn
	case rightOption
}

/// What the hotkey means, after hold / double-tap / Esc handling.
public enum HotkeyAction: Sendable, Equatable {
	/// Key went down: start listening.
	case start
	/// Key released (or tapped while locked): finish and insert.
	case stop
	/// Double-tap: keep listening hands-free until the next tap.
	case lock
	/// Esc, or a chord with another key: throw the recording away.
	case cancel
}

public protocol HotkeySource: Sendable {
	func actions() -> AsyncStream<HotkeyAction>
}
