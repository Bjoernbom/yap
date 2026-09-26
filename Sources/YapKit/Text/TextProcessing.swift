/// A step between the transcript and the text that gets inserted:
/// cleanup, dictionary, polish.
public protocol TextProcessing: Sendable {
	func process(_ text: String, for target: FocusTarget?) async -> String
}

/// Passes text through untouched.
public struct NoTextProcessing: TextProcessing {
	public init() {}
	public func process(_ text: String, for target: FocusTarget?) async -> String { text }
}
