import ApplicationServices
import Carbon
import Foundation

// MARK: - Pure state machine (no permissions, unit-testable)

/// Push-to-talk semantics from PLAN.md §5:
/// hold → talk → release; double-tap → hands-free lock, one more tap stops; Esc cancels.
/// Recording starts on the first press so no audio is lost while we wait to see whether
/// it is a tap. A lone quick tap that is not followed by a second one is discarded.
struct HotkeyStateMachine {
	enum Action: Equatable, CustomStringConvertible {
		case start, stop, lock, cancel
		var description: String {
			switch self {
			case .start: "start"
			case .stop: "stop"
			case .lock: "lock"
			case .cancel: "cancel"
			}
		}
	}

	enum State: Equatable {
		case idle
		case holding(downAt: UInt64)
		case tapped(upAt: UInt64)
		case lockedHeld // second press of the double-tap is still down
		case locked
		case ignoringRelease // stop/cancel happened while the key is down
	}

	var tapMaxNs: UInt64 = 250_000_000
	var doubleTapWindowNs: UInt64 = 350_000_000
	private(set) var state: State = .idle

	var isActive: Bool {
		switch state {
		case .idle, .ignoringRelease: false
		default: true
		}
	}

	mutating func triggerDown(at t: UInt64) -> [Action] {
		switch state {
		case .idle:
			state = .holding(downAt: t)
			return [.start]
		case .tapped(let upAt) where t - upAt <= doubleTapWindowNs:
			state = .lockedHeld
			return [.lock]
		case .tapped:
			state = .holding(downAt: t)
			return [.cancel, .start]
		case .locked:
			state = .ignoringRelease
			return [.stop]
		case .holding, .lockedHeld, .ignoringRelease:
			return [] // key repeat or missed release
		}
	}

	mutating func triggerUp(at t: UInt64) -> [Action] {
		switch state {
		case .holding(let downAt):
			if t - downAt < tapMaxNs {
				state = .tapped(upAt: t)
				return []
			}
			state = .idle
			return [.stop]
		case .lockedHeld:
			state = .locked
			return []
		case .ignoringRelease:
			state = .idle
			return []
		case .idle, .tapped, .locked:
			return []
		}
	}

	/// Call periodically (or from a timer armed at release) to expire a lone tap.
	mutating func tick(at t: UInt64) -> [Action] {
		if case .tapped(let upAt) = state, t - upAt > doubleTapWindowNs {
			state = .idle
			return [.cancel]
		}
		return []
	}

	mutating func escape(triggerHeld: Bool) -> [Action] {
		guard isActive else { return [] }
		state = triggerHeld ? .ignoringRelease : .idle
		return [.cancel]
	}

	/// Another key pressed while holding means the trigger is being used as a modifier
	/// (⌥-characters, Fn-arrows), so this was not push-to-talk.
	mutating func otherKey() -> [Action] {
		if case .holding = state {
			state = .ignoringRelease
			return [.cancel]
		}
		return []
	}
}

func runStateMachineTests() -> Bool {
	let ms: UInt64 = 1_000_000
	var ok = true
	func check(_ name: String, _ got: [HotkeyStateMachine.Action], _ want: [HotkeyStateMachine.Action]) {
		let pass = got == want
		ok = ok && pass
		print("  \(pass ? "PASS" : "FAIL") \(name): \(got)\(pass ? "" : " (want \(want))")")
	}
	var m = HotkeyStateMachine()
	var out = m.triggerDown(at: 0) + m.triggerUp(at: 600 * ms)
	check("hold 600 ms", out, [.start, .stop])

	m = HotkeyStateMachine()
	out = m.triggerDown(at: 0) + m.triggerUp(at: 80 * ms) + m.tick(at: 200 * ms)
	out += m.triggerDown(at: 230 * ms) + m.triggerUp(at: 300 * ms) + m.tick(at: 2000 * ms)
	out += m.triggerDown(at: 5000 * ms) + m.triggerUp(at: 5080 * ms)
	check("double-tap lock then tap stop", out, [.start, .lock, .stop])

	m = HotkeyStateMachine()
	out = m.triggerDown(at: 0) + m.triggerUp(at: 80 * ms) + m.tick(at: 500 * ms)
	check("lone tap discarded", out, [.start, .cancel])

	m = HotkeyStateMachine()
	out = m.triggerDown(at: 0) + m.escape(triggerHeld: true) + m.triggerUp(at: 900 * ms)
	check("esc while holding", out, [.start, .cancel])

	m = HotkeyStateMachine()
	out = m.triggerDown(at: 0) + m.otherKey() + m.triggerUp(at: 900 * ms)
	check("chord (trigger used as modifier)", out, [.start, .cancel])
	return ok
}

// MARK: - CGEventTap

enum Trigger: String {
	case fn, rightOption

	var keyCode: Int64 { self == .fn ? Int64(kVK_Function) : Int64(kVK_RightOption) }

	/// Fn/Globe sets .maskSecondaryFn. Right ⌥ is distinguished from left ⌥ by the device-dependent
	/// bit NX_DEVICERALTKEYMASK (0x40); .maskAlternate alone is set for either side.
	func isDown(_ flags: CGEventFlags) -> Bool {
		switch self {
		case .fn: flags.contains(.maskSecondaryFn)
		case .rightOption: flags.rawValue & 0x40 != 0
		}
	}
}

let syntheticTag: Int64 = 0x7961_7069 // "yapi", stored in eventSourceUserData

final class HotkeyTap {
	let triggers: [Trigger]
	let active: Bool
	var machine = HotkeyStateMachine()
	var held: Trigger?
	var tap: CFMachPort?
	var actions: [HotkeyStateMachine.Action] = []
	var callbackLatenciesMs: [Double] = []
	var swallowed = 0
	var disabledByTimeout = 0
	let timebase: mach_timebase_info_data_t = {
		var info = mach_timebase_info_data_t()
		mach_timebase_info(&info)
		return info
	}()

	init(triggers: [Trigger], active: Bool) {
		self.triggers = triggers
		self.active = active
	}

	func install() -> Bool {
		let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
		let callback: CGEventTapCallBack = { _, type, event, userInfo in
			let me = Unmanaged<HotkeyTap>.fromOpaque(userInfo!).takeUnretainedValue()
			return me.handle(type, event)
		}
		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: active ? .defaultTap : .listenOnly,
			eventsOfInterest: CGEventMask(mask),
			callback: callback,
			userInfo: Unmanaged.passUnretained(self).toOpaque()
		) else { return false }
		self.tap = tap
		let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
		CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)
		return true
	}

	func uninstall() {
		if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
		tap = nil
	}

	private func emit(_ out: [HotkeyStateMachine.Action], _ why: String) {
		for a in out {
			actions.append(a)
			print("  [\(why)] -> \(a)")
		}
	}

	func tick() { emit(machine.tick(at: nowNs()), "tick") }

	func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
			// The system disables a tap whose callback is slow; re-enable or the hotkey silently dies.
			disabledByTimeout += 1
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
			return Unmanaged.passUnretained(event)
		}
		let now = nowNs()
		// CGEvent timestamps are mach_absolute_time ticks on Apple Silicon; convert to ns.
		let tsNs = event.timestamp * UInt64(timebase.numer) / UInt64(timebase.denom)
		if now > tsNs, now - tsNs < 1_000_000_000 { callbackLatenciesMs.append(msValue(now - tsNs)) }

		let synthetic = event.getIntegerValueField(.eventSourceUserData) == syntheticTag
		let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
		var consume = false

		switch type {
		case .flagsChanged:
			if let trigger = triggers.first(where: { $0.keyCode == keyCode }) {
				let down = trigger.isDown(event.flags)
				print("  flagsChanged \(trigger) \(down ? "down" : "up") flags=0x\(String(event.flags.rawValue, radix: 16))\(synthetic ? " (synthetic)" : "")")
				if down, held == nil {
					held = trigger
					emit(machine.triggerDown(at: now), "\(trigger) down")
				} else if !down, held == trigger {
					held = nil
					emit(machine.triggerUp(at: now), "\(trigger) up")
				}
			}
		case .keyDown:
			if keyCode == Int64(kVK_Escape) {
				let wasActive = machine.isActive
				emit(machine.escape(triggerHeld: held != nil), "esc")
				// Swallow Esc only when it cancelled a dictation, so it never reaches the app.
				consume = wasActive
			} else if held != nil {
				emit(machine.otherKey(), "key \(keyCode)")
			}
		default:
			break
		}
		if active, consume || synthetic {
			swallowed += 1
			return nil
		}
		return Unmanaged.passUnretained(event)
	}
}

// MARK: - Synthetic events for the self-test

func postFlags(_ keyCode: Int, _ flags: CGEventFlags) {
	let src = CGEventSource(stateID: .privateState)
	guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return }
	e.type = .flagsChanged
	e.flags = flags
	e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
	e.post(tap: .cghidEventTap)
}

func postKey(_ keyCode: Int) {
	let src = CGEventSource(stateID: .privateState)
	for down in [true, false] {
		guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
		e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
		e.post(tap: .cghidEventTap)
	}
}

@MainActor
func runHotkey(_ args: Args) {
	print("== Hotkey state machine (pure)")
	let pureOK = runStateMachineTests()
	print("  state machine: \(pureOK ? "all pass" : "FAILURES")")

	let active = args.flag("active")
	let fn = FnUsage.current()
	print("== CGEventTap (\(active ? "active .defaultTap" : "listen-only"))")
	print("  AppleFnUsageType = \(fn.raw.map(String.init) ?? "unset") (\(fn.usage.map { "\($0)" } ?? "?"))")
	print("  preflight: listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess()) ax=\(AXIsProcessTrusted())")

	let tap = HotkeyTap(triggers: [.fn, .rightOption], active: active)
	let t0 = nowNs()
	guard tap.install() else {
		print("  RESULT: CGEvent.tapCreate returned nil after \(ms(nowNs() - t0)) -> permission missing (\(active ? "Accessibility" : "Input Monitoring"))")
		return
	}
	print("  tap created in \(ms(nowNs() - t0))")
	let timer = Timer(timeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { tap.tick() } }
	RunLoop.current.add(timer, forMode: .common)
	defer { timer.invalidate(); tap.uninstall() }

	if args.flag("selftest") {
		guard CGPreflightPostEventAccess() else {
			print("  RESULT: tap created but cannot post synthetic events (no Accessibility); run interactively instead")
			return
		}
		func wait(_ s: Double) { runLoop(for: s) }
		print("-- synthetic: hold Fn 600 ms")
		postFlags(kVK_Function, .maskSecondaryFn); wait(0.6); postFlags(kVK_Function, []); wait(0.1)
		print("-- synthetic: double-tap Fn, then tap to stop")
		postFlags(kVK_Function, .maskSecondaryFn); wait(0.08); postFlags(kVK_Function, []); wait(0.12)
		postFlags(kVK_Function, .maskSecondaryFn); wait(0.08); postFlags(kVK_Function, []); wait(0.8)
		postFlags(kVK_Function, .maskSecondaryFn); wait(0.08); postFlags(kVK_Function, []); wait(0.5)
		print("-- synthetic: hold right option 400 ms")
		postFlags(kVK_RightOption, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)); wait(0.4)
		postFlags(kVK_RightOption, []); wait(0.1)
		print("-- synthetic: lone tap (expect start, cancel)")
		postFlags(kVK_Function, .maskSecondaryFn); wait(0.08); postFlags(kVK_Function, []); wait(0.6)
		if active {
			print("-- synthetic: hold Fn + Esc (swallowed by the active tap)")
			postFlags(kVK_Function, .maskSecondaryFn); wait(0.2); postKey(kVK_Escape); wait(0.1)
			postFlags(kVK_Function, []); wait(0.1)
			print("-- synthetic: hold Fn + press A (chord, swallowed by the active tap)")
			postFlags(kVK_Function, .maskSecondaryFn); wait(0.2); postKey(kVK_ANSI_A); wait(0.1)
			postFlags(kVK_Function, []); wait(0.1)
			print("-- synthetic: triple-tap within the window (lock, then stop)")
			for _ in 0..<3 { postFlags(kVK_Function, .maskSecondaryFn); wait(0.05); postFlags(kVK_Function, []); wait(0.08) }
			wait(0.5)
		}
		let want: [HotkeyStateMachine.Action] = [.start, .stop, .start, .lock, .stop, .start, .stop, .start, .cancel]
			+ (active ? [.start, .cancel, .start, .cancel, .start, .lock, .stop] : [])
		print("  actions: \(tap.actions)")
		print("  RESULT: \(tap.actions == want ? "PASS" : "MISMATCH (want \(want))")")
	} else {
		let seconds = args.double("seconds", 20)
		print("  listening \(Int(seconds)) s: hold Fn or right ⌥, double-tap, press Esc ...")
		runLoop(for: seconds)
		print("  actions: \(tap.actions)")
	}
	print("  callback latency (event timestamp -> callback): \(stats(tap.callbackLatenciesMs))")
	print("  swallowed events: \(tap.swallowed), tap disabled/re-enabled: \(tap.disabledByTimeout)")
}
