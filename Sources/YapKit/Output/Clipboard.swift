import AppKit

/// Where text goes when it couldn't be typed, so the user can paste it by hand.
public protocol ClipboardWriter: Sendable {
	func write(_ text: String) async
}

/// The general pasteboard. Unlike the inserter's paste fallback, this is not
/// restored afterwards: leaving the text there is the point.
public struct SystemClipboard: ClipboardWriter {
	public init() {}

	public func write(_ text: String) async {
		await MainActor.run {
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			pasteboard.setString(text, forType: .string)
		}
	}
}

extension InsertOutcome {
	/// The text landed in the target app.
	public var didInsert: Bool {
		switch self {
		case .ax, .paste: true
		case .secureField, .noTarget, .focusChanged, .failed: false
		}
	}

	/// What to tell the user when the text didn't land, in yap's voice:
	/// one line, what happened and where the text is. Nil when it landed.
	public var message: String? {
		switch self {
		case .ax, .paste: nil
		case .secureField: "That's a password field. It's on your clipboard."
		case .focusChanged: "You switched apps. It's on your clipboard."
		case .noTarget, .failed: "Couldn't type here. It's on your clipboard."
		}
	}
}
