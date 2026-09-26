/// Decides when the notch offers notes for a call, and when it asks to stop
/// them after the call ended.
///
/// - A call app (or a browser that might host a call) starts: offer
///   "on a call? take notes" once per call, never while dictating or while
///   notes run. A call that starts mid-dictation is offered when dictation
///   ends. The offer goes away after `offerDuration`, when the call ends,
///   when dictation starts or when notes start.
/// - Notes run and the call ends: after `stopGrace` ask "call ended — stop
///   notes?". It stays until answered, the call comes back or notes stop:
///   notes never stop on their own.
///
/// Pure and clock-free like `CallDebouncer`: the caller passes the time and
/// asks for `deadline` to know when to call `update` again.
public struct CallPrompter: Sendable {
	public enum Prompt: Sendable, Equatable {
		case takeNotes(CallApp)
		case stopNotes
	}

	public enum Input: Sendable, Equatable {
		case call(CallEvent)
		case dictationStarted
		case dictationEnded
		case notesStarted
		case notesStopped
		/// The user clicked the prompt on screen.
		case clicked
		/// The "offer to take notes on calls" setting changed.
		case enabled(Bool)
		/// Nothing happened; time passed (a deadline came due).
		case tick
	}

	public enum Effect: Sendable, Equatable {
		case show(Prompt)
		/// Take the prompt off the notch, if the notch still shows it.
		case hide
		case startNotes
		case stopNotes
	}

	public let offerDuration: Double
	public let stopGrace: Double

	public private(set) var prompt: Prompt?
	public private(set) var isEnabled: Bool
	/// The call in progress, if it might be one worth notes.
	public private(set) var call: CallApp?
	private var offeredThisCall = false
	private var isDictating = false
	private var notesRunning = false
	private var offerEnds: Double?
	private var stopPromptAt: Double?

	public init(offerDuration: Double = 8, stopGrace: Double = 10, isEnabled: Bool = true) {
		self.offerDuration = offerDuration
		self.stopGrace = stopGrace
		self.isEnabled = isEnabled
	}

	/// When to call `update(.tick, at:)` even if nothing else happens, or nil.
	public var deadline: Double? {
		switch (offerEnds, stopPromptAt) {
		case let (offer?, stop?): min(offer, stop)
		case let (offer?, nil): offer
		case let (nil, stop?): stop
		case (nil, nil): nil
		}
	}

	/// Feeds one input at `now` (seconds, any monotonic clock) and returns
	/// what the app should do.
	public mutating func update(_ input: Input, at now: Double) -> [Effect] {
		var effects: [Effect] = []
		switch input {
		case .call(.started(let app)):
			let wasCall = call != nil
			call = app.mightBeCall ? app : nil
			if !wasCall { offeredThisCall = false }
			if notesRunning {
				// The call came back (or a new one began) before the question.
				stopPromptAt = nil
				if prompt == .stopNotes { effects += dismiss() }
			} else {
				effects += offerIfDue(at: now)
			}

		case .call(.ended):
			let wasCall = call != nil
			call = nil
			offeredThisCall = false
			if case .takeNotes = prompt { effects += dismiss() }
			if notesRunning, wasCall, prompt == nil, stopPromptAt == nil {
				stopPromptAt = now + stopGrace
			}

		case .dictationStarted:
			isDictating = true
			if case .takeNotes = prompt { effects += dismiss() }

		case .dictationEnded:
			isDictating = false
			effects += offerIfDue(at: now)

		case .notesStarted:
			notesRunning = true
			// Notes for this call are on, however they started.
			offeredThisCall = true
			if case .takeNotes = prompt { effects += dismiss() }

		case .notesStopped:
			notesRunning = false
			stopPromptAt = nil
			if prompt == .stopNotes { effects += dismiss() }

		case .clicked:
			switch prompt {
			case .takeNotes:
				prompt = nil
				offerEnds = nil
				effects.append(.startNotes)
			case .stopNotes:
				// Stays until notes report they stopped.
				effects.append(.stopNotes)
			case nil:
				break
			}

		case .enabled(let enabled):
			isEnabled = enabled
			if !enabled, case .takeNotes = prompt { effects += dismiss() }

		case .tick:
			break
		}

		// Time-based transitions, also reached when nothing else changed.
		if let offerEnds, now >= offerEnds, case .takeNotes = prompt {
			effects += dismiss()
		}
		if let stopPromptAt, now >= stopPromptAt {
			self.stopPromptAt = nil
			if notesRunning, call == nil {
				prompt = .stopNotes
				effects.append(.show(.stopNotes))
			}
		}
		return effects
	}

	private mutating func offerIfDue(at now: Double) -> [Effect] {
		guard isEnabled, let call, !offeredThisCall, !isDictating, !notesRunning, prompt == nil else { return [] }
		offeredThisCall = true
		prompt = .takeNotes(call)
		offerEnds = now + offerDuration
		return [.show(.takeNotes(call))]
	}

	private mutating func dismiss() -> [Effect] {
		guard prompt != nil else { return [] }
		prompt = nil
		offerEnds = nil
		return [.hide]
	}
}
