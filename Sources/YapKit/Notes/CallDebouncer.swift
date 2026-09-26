/// What call detection reports.
public enum CallEvent: Sendable, Equatable {
	/// Some app has used the mic for at least the minimum duration.
	case started(app: CallApp)
	/// Nothing has used the mic for the grace period.
	case ended
}

/// Turns "who is recording right now" samples into call events.
///
/// A call is at least `minimumDuration` of continuous mic use by someone
/// other than yap: a voice message or a quick dictation in another app must
/// not make the notch offer notes. The end waits `endGrace`, so a call app
/// that briefly releases the mic (switching devices, reconnecting) doesn't
/// end the call and start a new one.
///
/// Pure and clock-free: the caller passes the time and asks for `deadline`
/// to know when to sample again even if nothing changes.
public struct CallDebouncer: Sendable {
	public let minimumDuration: Double
	public let endGrace: Double

	private enum State: Sendable, Equatable {
		case idle
		case pending(since: Double)
		case active(CallApp)
		case ending(CallApp, since: Double)
	}

	private var state: State = .idle
	private var recorders: [CallApp] = []

	public init(minimumDuration: Double = 3, endGrace: Double = 1) {
		self.minimumDuration = minimumDuration
		self.endGrace = endGrace
	}

	/// The call in progress, if any.
	public var activeCall: CallApp? {
		switch state {
		case .active(let app), .ending(let app, _): app
		default: nil
		}
	}

	/// When to call `update` again even without a change, or nil.
	public var deadline: Double? {
		switch state {
		case .pending(let since): since + minimumDuration
		case .ending(_, let since): since + endGrace
		default: nil
		}
	}

	/// Records who is using the mic at `now` (seconds, any monotonic clock)
	/// and returns the events that became due.
	public mutating func update(recorders: [CallApp], at now: Double) -> [CallEvent] {
		self.recorders = recorders
		let recording = !recorders.isEmpty
		var events: [CallEvent] = []
		switch state {
		case .idle:
			if recording { state = .pending(since: now) }
		case .pending:
			if !recording { state = .idle }
		case .active(let app):
			if !recording { state = .ending(app, since: now) }
		case .ending(let app, _):
			if recording { state = .active(app) }
		}
		// Time-based transitions, also reached when nothing changed.
		switch state {
		case .pending(let since) where now - since >= minimumDuration:
			let app = Self.mostLikelyCall(recorders)
			state = .active(app)
			events.append(.started(app: app))
		case .ending(_, let since) where now - since >= endGrace:
			state = .idle
			events.append(.ended)
		default:
			break
		}
		return events
	}

	/// The app to name for the call when several record at once.
	static func mostLikelyCall(_ recorders: [CallApp]) -> CallApp {
		// max(by:) keeps the first of equal elements: the earliest recorder.
		recorders.max { $0.rank < $1.rank } ?? .other("Unknown app")
	}
}
