import Testing
@testable import YapKit

/// Drives the machine through a script of (input, milliseconds) steps and collects the output.
private func run(
	_ steps: [(HotkeyStateMachine.Input, Int)],
	machine: inout HotkeyStateMachine
) -> (actions: [HotkeyAction], swallowed: [Bool]) {
	var actions: [HotkeyAction] = []
	var swallowed: [Bool] = []
	for (input, ms) in steps {
		let out = machine.handle(input, at: .milliseconds(ms))
		actions += out.actions
		swallowed.append(out.swallow)
	}
	return (actions, swallowed)
}

private func actions(_ steps: [(HotkeyStateMachine.Input, Int)]) -> [HotkeyAction] {
	var machine = HotkeyStateMachine()
	return run(steps, machine: &machine).actions
}

@Suite struct HotkeyStateMachineTests {
	@Test func holdStartsAndReleaseStops() {
		var m = HotkeyStateMachine()
		#expect(m.handle(.triggerDown, at: .zero).actions == [.start])
		#expect(m.isListening)
		#expect(m.handle(.triggerUp, at: .milliseconds(600)).actions == [.stop])
		#expect(m.state == .idle)
	}

	@Test func holdExactlyAtThresholdIsADictation() {
		#expect(actions([(.triggerDown, 0), (.triggerUp, 300)]) == [.start, .stop])
	}

	@Test func loneShortTapIsCancelledAtTheDeadline() {
		var m = HotkeyStateMachine()
		_ = m.handle(.triggerDown, at: .zero)
		#expect(m.handle(.triggerUp, at: .milliseconds(80)).actions.isEmpty)
		#expect(m.deadline == .milliseconds(380))
		// A tick before the deadline changes nothing.
		#expect(m.handle(.tick, at: .milliseconds(379)).actions.isEmpty)
		#expect(m.handle(.tick, at: .milliseconds(380)).actions == [.cancel])
		#expect(m.state == .idle)
		#expect(m.deadline == nil)
	}

	@Test func doubleTapLocksAndNextTapStops() {
		let got = actions([
			(.triggerDown, 0), (.triggerUp, 80),
			(.triggerDown, 200), (.triggerUp, 260),
			(.tick, 2_000),
			(.triggerDown, 5_000), (.triggerUp, 5_080),
		])
		#expect(got == [.start, .lock, .stop])
	}

	@Test func lockedStopWithAHold() {
		// Stopping hands-free mode with a long press must not start a new dictation.
		let got = actions([
			(.triggerDown, 0), (.triggerUp, 80),
			(.triggerDown, 150), (.triggerUp, 900),
			(.triggerDown, 3_000), (.triggerUp, 4_000),
		])
		#expect(got == [.start, .lock, .stop])
	}

	@Test func secondPressAfterTheWindowWithoutTickStartsOver() {
		let got = actions([(.triggerDown, 0), (.triggerUp, 80), (.triggerDown, 500), (.triggerUp, 1_200)])
		#expect(got == [.start, .cancel, .start, .stop])
	}

	@Test func rapidTapsAlternateLockAndStop() {
		var steps: [(HotkeyStateMachine.Input, Int)] = []
		for i in 0..<6 {
			steps += [(.triggerDown, i * 100), (.triggerUp, i * 100 + 40)]
		}
		#expect(actions(steps) == [.start, .lock, .stop, .start, .lock, .stop])
	}

	@Test func escapeWhileHoldingCancelsAndIsSwallowed() {
		var m = HotkeyStateMachine()
		let out = run([(.triggerDown, 0), (.escape, 200), (.triggerUp, 900)], machine: &m)
		#expect(out.actions == [.start, .cancel])
		#expect(out.swallowed == [false, true, false])
		#expect(m.state == .idle)
	}

	@Test func escapeWhileLockedCancelsAndIsSwallowed() {
		var m = HotkeyStateMachine()
		let out = run([
			(.triggerDown, 0), (.triggerUp, 50), (.triggerDown, 100), (.triggerUp, 150),
			(.escape, 3_000),
			// The next press is a fresh dictation, not a "stop".
			(.triggerDown, 4_000), (.triggerUp, 5_000),
		], machine: &m)
		#expect(out.actions == [.start, .lock, .cancel, .start, .stop])
		#expect(out.swallowed[4])
	}

	@Test func escapeDuringPendingTapCancels() {
		var m = HotkeyStateMachine()
		let out = run([(.triggerDown, 0), (.triggerUp, 50), (.escape, 100), (.tick, 400)], machine: &m)
		#expect(out.actions == [.start, .cancel])
		#expect(out.swallowed == [false, false, true, false])
	}

	@Test func escapeWhenIdlePassesThrough() {
		var m = HotkeyStateMachine()
		let out = m.handle(.escape, at: .zero)
		#expect(out == .init())
	}

	@Test func chordCancelsAndLetsTheKeyThrough() {
		var m = HotkeyStateMachine()
		let out = run([(.triggerDown, 0), (.otherKey, 200), (.otherKey, 250), (.triggerUp, 900)], machine: &m)
		#expect(out.actions == [.start, .cancel])
		#expect(out.swallowed == [false, false, false, false])
		#expect(m.state == .idle)
	}

	@Test func typingAfterAShortTapCancelsIt() {
		#expect(actions([(.triggerDown, 0), (.triggerUp, 60), (.otherKey, 120), (.tick, 400)]) == [.start, .cancel])
	}

	@Test func typingWhileLockedKeepsListening() {
		var m = HotkeyStateMachine()
		let out = run([(.triggerDown, 0), (.triggerUp, 50), (.triggerDown, 100), (.triggerUp, 150), (.otherKey, 1_000)], machine: &m)
		#expect(out.actions == [.start, .lock])
		#expect(m.state == .locked)
	}

	@Test func keyRepeatAndStrayReleasesAreIgnored() {
		#expect(actions([(.triggerUp, 0), (.triggerDown, 10), (.triggerDown, 20), (.triggerUp, 800)]) == [.start, .stop])
	}

	@Test func customTimings() {
		var m = HotkeyStateMachine(tapThreshold: .milliseconds(100), doubleTapWindow: .milliseconds(200))
		let out = run([(.triggerDown, 0), (.triggerUp, 150)], machine: &m)
		#expect(out.actions == [.start, .stop])
	}
}
