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
	/// Taking meeting notes: red dot and a timer.
	case recording(since: Date)

	/// States that share a view, so switching between them animates in
	/// place instead of cross-fading.
	enum Content: Equatable {
		case none, waveform, tick, meeting
	}

	var content: Content {
		switch self {
		case .hidden: .none
		case .listening, .working: .waveform
		case .done: .tick
		case .recording: .meeting
		}
	}
}
