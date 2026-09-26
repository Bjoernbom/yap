import CoreFoundation
import CoreGraphics
import Dispatch
import Foundation
import Synchronization

public enum HotkeyMonitorError: Error, Sendable, Equatable {
	/// The active tap needs Accessibility.
	case accessibilityNotGranted
	/// `CGEvent.tapCreate` returned nil even though Accessibility looked granted.
	case tapUnavailable
}

/// Watches the push-to-talk key system-wide with an active `CGEventTap` on its own thread.
///
/// The tap is active (not listen-only) so it can swallow Esc when Esc cancels a dictation.
/// Call `start()` once; `actions()` streams can be taken before or after.
public final class HotkeyMonitor: HotkeySource {
	/// CF handles are not `Sendable`, but the calls made on them across threads here
	/// (enable, invalidate, stop) are documented as thread-safe.
	private struct Handle<Value>: @unchecked Sendable {
		let value: Value
	}

	private struct Shared {
		var interpreter: HotkeyEventInterpreter
		var continuations: [Int: AsyncStream<HotkeyAction>.Continuation] = [:]
		var nextID = 0
		var tap: Handle<CFMachPort>?
		var runLoop: Handle<CFRunLoop>?
		var tickTimer: Handle<CFRunLoopTimer>?
	}

	private let shared: Mutex<Shared>

	public init(trigger: HotkeyTrigger) {
		shared = Mutex(Shared(interpreter: HotkeyEventInterpreter(trigger: trigger)))
	}

	public var trigger: HotkeyTrigger {
		shared.withLock { $0.interpreter.trigger }
	}

	public var isRunning: Bool {
		shared.withLock { $0.tap != nil }
	}

	public func actions() -> AsyncStream<HotkeyAction> {
		let (stream, continuation) = AsyncStream.makeStream(of: HotkeyAction.self, bufferingPolicy: .bufferingNewest(32))
		let id = shared.withLock { state in
			let id = state.nextID
			state.nextID += 1
			state.continuations[id] = continuation
			return id
		}
		continuation.onTermination = { [weak self] _ in
			self?.shared.withLock { _ = $0.continuations.removeValue(forKey: id) }
		}
		return stream
	}

	/// Switches the key. A dictation in progress is cancelled.
	public func setTrigger(_ trigger: HotkeyTrigger) {
		let (wasListening, continuations) = shared.withLock { state in
			let wasListening = state.interpreter.machine.isListening
			state.interpreter = HotkeyEventInterpreter(trigger: trigger)
			return (wasListening, Array(state.continuations.values))
		}
		if wasListening { continuations.forEach { $0.yield(.cancel) } }
	}

	/// Creates the tap on a dedicated thread and returns once it is live (~30 ms).
	public func start() throws(HotkeyMonitorError) {
		if isRunning { return }
		guard AccessibilityPermission.isGranted else { throw .accessibilityNotGranted }
		let ready = DispatchSemaphore(value: 0)
		let thread = Thread { [self] in
			runTapThread(ready: ready)
		}
		thread.name = "com.bjornbom.yap.hotkey"
		// The tap sits in front of every key event on the system: never let it wait for CPU.
		thread.qualityOfService = .userInteractive
		thread.start()
		ready.wait()
		guard isRunning else { throw .tapUnavailable }
	}

	/// Removes the tap. A dictation in progress is cancelled; open streams stay open.
	public func stop() {
		let (tap, runLoop, timer, wasListening, continuations) = shared.withLock { state in
			let result = (
				state.tap, state.runLoop, state.tickTimer,
				state.interpreter.machine.isListening, Array(state.continuations.values)
			)
			state.tap = nil
			state.runLoop = nil
			state.tickTimer = nil
			state.interpreter = HotkeyEventInterpreter(trigger: state.interpreter.trigger)
			return result
		}
		if let timer { CFRunLoopTimerInvalidate(timer.value) }
		if let tap {
			CGEvent.tapEnable(tap: tap.value, enable: false)
			// Invalidating the port also removes its source, so the run loop has nothing left and
			// returns even if `CFRunLoopStop` lands before the thread entered `CFRunLoopRun`.
			CFMachPortInvalidate(tap.value)
		}
		if let runLoop { CFRunLoopStop(runLoop.value) }
		if wasListening { continuations.forEach { $0.yield(.cancel) } }
	}

	// MARK: - Tap thread

	private func runTapThread(ready: DispatchSemaphore) {
		guard let tap = Self.makeTap(userInfo: Unmanaged.passUnretained(self).toOpaque()),
			let runLoop = CFRunLoopGetCurrent()
		else {
			ready.signal()
			return
		}
		let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
		CFRunLoopAddSource(runLoop, source, .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)
		let handles = (Handle(value: tap), Handle(value: runLoop))
		shared.withLock { state in
			state.tap = handles.0
			state.runLoop = handles.1
		}
		ready.signal()
		CFRunLoopRun()
	}

	/// Built in a `nonisolated` static function on purpose: a callback closure written inside
	/// actor-isolated code inherits that isolation and traps when the tap thread calls it
	/// (the Swift 6 trap from spike M0-IO).
	private nonisolated static func makeTap(userInfo: UnsafeMutableRawPointer) -> CFMachPort? {
		let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
			| (1 << CGEventType.keyDown.rawValue)
			// keyUp too: swallowing a keyDown without its keyUp leaks a stray release to the app.
			| (1 << CGEventType.keyUp.rawValue)
		let callback: CGEventTapCallBack = { _, type, event, userInfo in
			guard let userInfo else { return Unmanaged.passUnretained(event) }
			let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
			return monitor.handle(type, event)
		}
		return CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: mask,
			callback: callback,
			userInfo: userInfo
		)
	}

	/// Runs on the tap thread for every key event on the system, so it does the minimum:
	/// one lock, a few comparisons, and yields.
	private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
		let pass = Unmanaged.passUnretained(event)
		let kind: HotkeyEventInterpreter.Kind
		switch type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			// The system turns off a tap it thinks is slow. Without this the hotkey dies silently.
			if let tap = shared.withLock({ $0.tap }) { CGEvent.tapEnable(tap: tap.value, enable: true) }
			return pass
		case .flagsChanged: kind = .flagsChanged
		case .keyDown: kind = .keyDown
		case .keyUp: kind = .keyUp
		default: return pass
		}
		if event.getIntegerValueField(.eventSourceUserData) == SyntheticEventTag.paste { return pass }

		let now = Self.now()
		let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
		let flags = event.flags.rawValue
		let (output, deadline, continuations) = shared.withLock { state in
			let output = state.interpreter.handle(kind, keyCode: keyCode, flags: flags, at: now)
			return (output, state.interpreter.machine.deadline, output.actions.isEmpty ? [] : Array(state.continuations.values))
		}
		scheduleTick(at: deadline, now: now)
		for action in output.actions {
			continuations.forEach { $0.yield(action) }
		}
		return output.swallow ? nil : pass
	}

	/// A stray tap only turns into `.cancel` when its double-tap window runs out, which no key
	/// event marks, so arm a one-shot timer on the tap's run loop for that moment.
	private func scheduleTick(at deadline: Duration?, now: Duration) {
		let old = shared.withLock { state in
			let old = state.tickTimer
			state.tickTimer = nil
			return old
		}
		if let old { CFRunLoopTimerInvalidate(old.value) }
		guard let deadline else { return }
		let delta = (deadline - now).components
		let seconds = max(0, Double(delta.seconds) + Double(delta.attoseconds) / 1e18)
		let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + seconds, 0, 0, 0) { [weak self] _ in
			self?.tick()
		}
		let handle = timer.map { Handle(value: $0) }
		shared.withLock { $0.tickTimer = handle }
		if let timer { CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes) }
	}

	private func tick() {
		let now = Self.now()
		let (output, deadline, continuations) = shared.withLock { state in
			state.tickTimer = nil
			let output = state.interpreter.tick(at: now)
			return (output, state.interpreter.machine.deadline, Array(state.continuations.values))
		}
		// The run-loop timer uses wall-clock time and may fire a hair before the monotonic
		// deadline; re-arm so a pending tap can never get stuck.
		scheduleTick(at: deadline, now: now)
		for action in output.actions {
			continuations.forEach { $0.yield(action) }
		}
	}

	private static func now() -> Duration {
		.nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
	}
}
