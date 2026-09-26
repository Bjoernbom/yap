import Carbon.HIToolbox

extension HotkeyTrigger {
	/// Virtual key code of the trigger's `flagsChanged` event.
	var keyCode: Int64 {
		switch self {
		case .fn: Int64(kVK_Function)
		case .rightOption: Int64(kVK_RightOption)
		}
	}

	/// Whether the trigger is down, judging by an event's modifier flags.
	func isDown(flags: UInt64) -> Bool {
		switch self {
		// Fn/Globe sets `.maskSecondaryFn`.
		case .fn: flags & 0x80_0000 != 0
		// `.maskAlternate` is set for either ⌥; only the device bit NX_DEVICERALTKEYMASK
		// tells the right one apart.
		case .rightOption: flags & 0x40 != 0
		}
	}
}

/// Tags keyboard events yap posts itself (in `eventSourceUserData`), so our own event tap
/// can let them pass without reading them as the user's keys.
enum SyntheticEventTag {
	static let paste: Int64 = 0x7961_7076 // "yapv"
}

/// Turns raw keyboard events from the event tap into state-machine inputs. Kept pure so the
/// flag decoding and the swallow bookkeeping are testable without a tap.
struct HotkeyEventInterpreter: Sendable {
	enum Kind: Sendable {
		case flagsChanged
		case keyDown
		case keyUp
	}

	let trigger: HotkeyTrigger
	private(set) var machine: HotkeyStateMachine
	private var triggerHeld = false
	/// Keys whose `keyDown` we swallowed. Their repeats and `keyUp` must be swallowed too,
	/// or the app sees a release (or repeats) for a press it never got.
	private var swallowedKeys: Set<Int64> = []

	init(trigger: HotkeyTrigger, machine: HotkeyStateMachine = HotkeyStateMachine()) {
		self.trigger = trigger
		self.machine = machine
	}

	mutating func handle(_ kind: Kind, keyCode: Int64, flags: UInt64, at now: Duration) -> HotkeyStateMachine.Output {
		switch kind {
		case .flagsChanged:
			let down = trigger.isDown(flags: flags)
			if keyCode == trigger.keyCode {
				if down, !triggerHeld {
					triggerHeld = true
					return machine.handle(.triggerDown, at: now)
				}
				if !down, triggerHeld {
					triggerHeld = false
					return machine.handle(.triggerUp, at: now)
				}
			} else if triggerHeld, !down {
				// Another modifier changed and the trigger's bit is gone: we missed its release
				// (for example while the tap was disabled). Treat it as released now.
				triggerHeld = false
				return machine.handle(.triggerUp, at: now)
			}
			// Other modifiers are not chords: Fn+⇧ or ⌥+⌘ are still on the way to a key.
			return .init()

		case .keyDown:
			if swallowedKeys.contains(keyCode) { return .init(swallow: true) }
			let input: HotkeyStateMachine.Input = keyCode == Int64(kVK_Escape) ? .escape : .otherKey
			let out = machine.handle(input, at: now)
			if out.swallow { swallowedKeys.insert(keyCode) }
			return out

		case .keyUp:
			return .init(swallow: swallowedKeys.remove(keyCode) != nil)
		}
	}

	mutating func tick(at now: Duration) -> HotkeyStateMachine.Output {
		machine.handle(.tick, at: now)
	}
}
