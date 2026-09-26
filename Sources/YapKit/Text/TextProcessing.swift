/// A step between the transcript and the text that gets inserted:
/// cleanup, dictionary, polish.
public protocol TextProcessing: Sendable {
	/// Key-down, before the user has said anything. Lets slow steps (the
	/// polish model) warm up while the user talks. Must return quickly.
	func prepare(for target: FocusTarget?) async
	func process(_ text: String, for target: FocusTarget?) async -> String
}

extension TextProcessing {
	public func prepare(for target: FocusTarget?) async {}
}

/// Passes text through untouched.
public struct NoTextProcessing: TextProcessing {
	public init() {}
	public func process(_ text: String, for target: FocusTarget?) async -> String { text }
}
