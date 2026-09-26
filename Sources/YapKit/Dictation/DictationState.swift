/// Where a dictation is. Drives the notch.
public enum DictationState: Sendable, Equatable {
	case idle
	case listening(locked: Bool)
	case transcribing
	case done(InsertOutcome)
	/// Nothing was heard, or it was too short.
	case empty
	case failed(String)
}
