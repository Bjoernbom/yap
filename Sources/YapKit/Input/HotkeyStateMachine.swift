/// Push-to-talk semantics (PLAN.md §5) as a pure value: hold → talk → release,
/// double-tap → hands-free until the next tap, Esc cancels.
///
/// Recording starts on the first press, so no audio is lost while we find out whether the
/// press is a hold, a stray tap or the first half of a double-tap. Time is passed in as a
/// `Duration` since any fixed origin on a monotonic clock, which keeps this testable.
public struct HotkeyStateMachine: Sendable, Equatable {
	public enum Input: Sendable, Equatable {
		case triggerDown
		case triggerUp
		case escape
		/// Any other key went down.
		case otherKey
		/// Time passed. Feed this at `deadline` to expire a pending tap.
		case tick
	}

	public struct Output: Sendable, Equatable {
		public var actions: [HotkeyAction]
		/// The key event that caused this should not reach the focused app.
		public var swallow: Bool

		public init(_ actions: [HotkeyAction] = [], swallow: Bool = false) {
			self.actions = actions
			self.swallow = swallow
		}
	}

	public enum State: Sendable, Equatable {
		case idle
		/// Trigger is down and we are recording.
		case holding(since: Duration)
		/// A short press ended; either a second press (lock) or the deadline (cancel) follows.
		case tapped(at: Duration)
		/// Second press of a double-tap, still down.
		case lockHeld
		/// Hands-free: recording until the next press.
		case locked
		/// The dictation already ended; swallow the rest of this press.
		case waitingForRelease
	}

	/// Presses shorter than this are taps, not dictations. PLAN.md §12: presses under
	/// 0.3 s never reach the speech engine.
	public var tapThreshold: Duration
	/// How long after a tap's release a second press still counts as a double-tap.
	public var doubleTapWindow: Duration
	public private(set) var state: State = .idle

	public init(tapThreshold: Duration = .milliseconds(300), doubleTapWindow: Duration = .milliseconds(300)) {
		self.tapThreshold = tapThreshold
		self.doubleTapWindow = doubleTapWindow
	}

	/// A dictation is running (a `.start` was emitted and no `.stop` / `.cancel` yet).
	public var isListening: Bool {
		switch state {
		case .holding, .tapped, .lockHeld, .locked: true
		case .idle, .waitingForRelease: false
		}
	}

	/// When a `.tick` is due, if one is.
	public var deadline: Duration? {
		if case .tapped(let at) = state { at + doubleTapWindow } else { nil }
	}

	public mutating func handle(_ input: Input, at now: Duration) -> Output {
		switch (state, input) {
		case (.idle, .triggerDown):
			state = .holding(since: now)
			return Output([.start])

		case (.holding(let since), .triggerUp):
			if now - since < tapThreshold {
				state = .tapped(at: now)
				return Output()
			}
			state = .idle
			return Output([.stop])

		case (.tapped(let at), .triggerDown):
			if now < at + doubleTapWindow {
				state = .lockHeld
				return Output([.lock])
			}
			// The deadline passed without a tick: finish the stray tap, then start fresh.
			state = .holding(since: now)
			return Output([.cancel, .start])

		case (.tapped(let at), .tick):
			guard now >= at + doubleTapWindow else { return Output() }
			state = .idle
			return Output([.cancel])

		case (.lockHeld, .triggerUp):
			state = .locked
			return Output()

		case (.locked, .triggerDown):
			state = .waitingForRelease
			return Output([.stop])

		case (.waitingForRelease, .triggerUp):
			state = .idle
			return Output()

		// Esc only means "cancel" while we listen; otherwise it belongs to the app.
		case (.holding, .escape), (.lockHeld, .escape):
			state = .waitingForRelease
			return Output([.cancel], swallow: true)
		case (.tapped, .escape), (.locked, .escape):
			state = .idle
			return Output([.cancel], swallow: true)

		// Another key while the trigger is down means it is being used as a modifier
		// (Fn-arrows, right ⌥ as AltGr for @ [ ] on European layouts). That was never
		// push-to-talk, so cancel, but let the key through: swallowing it would break typing.
		case (.holding, .otherKey), (.lockHeld, .otherKey):
			state = .waitingForRelease
			return Output([.cancel])
		// Typing right after a short tap: the tap was a stray one.
		case (.tapped, .otherKey):
			state = .idle
			return Output([.cancel])

		// Key repeat, a release we never saw the press of, typing while hands-free, and
		// ticks with nothing pending: nothing to do.
		default:
			return Output()
		}
	}
}
