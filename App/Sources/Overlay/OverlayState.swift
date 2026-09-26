import Foundation

/// Everything the notch can show. The dictation and notes engines drive the
/// overlay only through this.
enum OverlayState: Equatable, Sendable {
	/// Tucked into the hardware notch, panel off screen.
	case hidden
	/// Holding the key: a pixel waveform driven by the level stream.
	case listening
	/// Key released, transcribing: the waveform folds into a shimmer.
	case working
	/// Text inserted: a tick, then gone.
	case done
	/// One short line in yap's voice (the text didn't land, the model isn't
	/// ready yet), then gone.
	case message(String)
	/// Taking meeting notes: red dot and a timer.
	case recording(since: Date)
	/// A one-click question about notes and a call. The only state besides
	/// the meeting that takes clicks.
	case prompt(NotchPrompt)

	/// States that share a view, so switching between them animates in
	/// place instead of cross-fading.
	enum Content: Equatable {
		case none, waveform, tick, message, meeting, prompt
	}

	var content: Content {
		switch self {
		case .hidden: .none
		case .listening, .working: .waveform
		case .done: .tick
		case .message: .message
		case .recording: .meeting
		case .prompt: .prompt
		}
	}
}

/// What the notch asks about a call.
enum NotchPrompt: Equatable, Sendable {
	/// A call started: "on a call? take notes".
	case takeNotes
	/// Notes run and the call ended a while ago: "call ended — stop notes?".
	case stopNotes

	/// The line before the button.
	var question: String {
		switch self {
		case .takeNotes: "on a call?"
		case .stopNotes: "call ended —"
		}
	}

	/// The button.
	var action: String {
		switch self {
		case .takeNotes: "take notes"
		case .stopNotes: "stop notes?"
		}
	}
}
