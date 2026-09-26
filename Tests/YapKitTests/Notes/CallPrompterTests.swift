import Testing
@testable import YapKit

@Suite struct CallPrompterTests {
	/// Drives a prompter with a fake clock: inputs at given times, and ticks
	/// at every deadline that comes due in between, like the app does.
	private struct Harness {
		var prompter = CallPrompter()
		var now = 0.0
		var effects: [(Double, CallPrompter.Effect)] = []

		mutating func at(_ time: Double, _ input: CallPrompter.Input) {
			advance(to: time)
			record(prompter.update(input, at: time))
		}

		mutating func advance(to time: Double) {
			while let deadline = prompter.deadline, deadline <= time {
				now = deadline
				record(prompter.update(.tick, at: deadline))
			}
			now = time
		}

		private mutating func record(_ new: [CallPrompter.Effect]) {
			effects += new.map { (now, $0) }
		}

		var list: [CallPrompter.Effect] { effects.map(\.1) }
	}

	@Test func offersNotesWhenACallStartsAndDismissesAfterEightSeconds() {
		var h = Harness()
		h.at(10, .call(.started(app: .zoom)))
		h.advance(to: 30)
		#expect(h.effects.map(\.0) == [10, 18])
		#expect(h.list == [.show(.takeNotes(.zoom)), .hide])
		#expect(h.prompter.prompt == nil)
	}

	@Test func aBrowserMightBeACallButOtherRecordersAreNot() {
		var h = Harness()
		h.at(0, .call(.started(app: .browser("Chrome"))))
		#expect(h.list == [.show(.takeNotes(.browser("Chrome")))])

		var other = Harness()
		other.at(0, .call(.started(app: .other("Voice Memos"))))
		other.advance(to: 20)
		#expect(other.list.isEmpty)
	}

	@Test func clickStartsNotes() {
		var h = Harness()
		h.at(0, .call(.started(app: .teams)))
		h.at(2, .clicked)
		h.at(2.5, .notesStarted)
		h.advance(to: 20)
		#expect(h.list == [.show(.takeNotes(.teams)), .startNotes])
	}

	@Test func theCallEndingTakesTheOfferAway() {
		var h = Harness()
		h.at(0, .call(.started(app: .faceTime)))
		h.at(3, .call(.ended))
		h.advance(to: 20)
		#expect(h.list == [.show(.takeNotes(.faceTime)), .hide])
	}

	@Test func dictatingTakesTheOfferAwayAndItDoesNotComeBack() {
		var h = Harness()
		h.at(0, .call(.started(app: .slack)))
		h.at(2, .dictationStarted)
		h.at(4, .dictationEnded)
		h.advance(to: 20)
		#expect(h.list == [.show(.takeNotes(.slack)), .hide])
	}

	@Test func aCallThatStartsWhileDictatingIsOfferedAfterwards() {
		var h = Harness()
		h.at(0, .dictationStarted)
		h.at(1, .call(.started(app: .zoom)))
		#expect(h.list.isEmpty)
		h.at(5, .dictationEnded)
		h.advance(to: 20)
		#expect(h.effects.map(\.0) == [5, 13])
		#expect(h.list == [.show(.takeNotes(.zoom)), .hide])
	}

	@Test func offersOncePerCall() {
		var h = Harness()
		h.at(0, .call(.started(app: .zoom)))
		h.advance(to: 20)
		// Dictation in the middle of the call doesn't bring the offer back.
		h.at(21, .dictationStarted)
		h.at(23, .dictationEnded)
		// A new call does.
		h.at(30, .call(.ended))
		h.at(40, .call(.started(app: .discord)))
		#expect(h.list == [.show(.takeNotes(.zoom)), .hide, .show(.takeNotes(.discord))])
	}

	@Test func noOfferWhileNotesRunOrAfterTheyStopForTheSameCall() {
		var h = Harness()
		h.at(0, .notesStarted)
		h.at(1, .call(.started(app: .zoom)))
		h.at(60, .notesStopped)
		h.advance(to: 90)
		#expect(h.list.isEmpty)
	}

	@Test func noOfferWhenTurnedOff() {
		var h = Harness()
		h.at(0, .enabled(false))
		h.at(1, .call(.started(app: .zoom)))
		h.advance(to: 20)
		#expect(h.list.isEmpty)
		// Turning it off while offering takes the offer away.
		var shown = Harness()
		shown.at(0, .call(.started(app: .zoom)))
		shown.at(2, .enabled(false))
		#expect(shown.list == [.show(.takeNotes(.zoom)), .hide])
	}

	@Test func asksToStopNotesTenSecondsAfterTheCallEnds() {
		var h = Harness()
		h.at(0, .call(.started(app: .zoom)))
		h.at(1, .clicked)
		h.at(1.5, .notesStarted)
		h.at(600, .call(.ended))
		h.advance(to: 700)
		#expect(h.effects.map(\.0) == [0, 1, 610])
		#expect(h.list == [.show(.takeNotes(.zoom)), .startNotes, .show(.stopNotes)])
		// It stays: notes never stop on their own.
		#expect(h.prompter.prompt == .stopNotes)
		#expect(h.prompter.deadline == nil)

		h.at(701, .clicked)
		h.at(701.2, .notesStopped)
		#expect(h.list.suffix(2) == [.stopNotes, .hide])
		#expect(h.prompter.prompt == nil)
	}

	@Test func aCallThatComesBackWithinTheGraceIsNotAnEnd() {
		var h = Harness()
		h.at(0, .notesStarted)
		h.at(5, .call(.started(app: .teams)))
		h.at(100, .call(.ended))
		h.at(106, .call(.started(app: .teams)))
		h.advance(to: 200)
		#expect(h.list.isEmpty)
	}

	@Test func theCallComingBackTakesTheStopQuestionAway() {
		var h = Harness()
		h.at(0, .notesStarted)
		h.at(5, .call(.started(app: .zoom)))
		h.at(100, .call(.ended))
		h.advance(to: 120)
		h.at(130, .call(.started(app: .zoom)))
		#expect(h.list == [.show(.stopNotes), .hide])
	}

	@Test func stoppingNotesByHandCancelsTheStopQuestion() {
		var h = Harness()
		h.at(0, .notesStarted)
		h.at(5, .call(.started(app: .zoom)))
		h.at(100, .call(.ended))
		h.at(104, .notesStopped)
		h.advance(to: 200)
		#expect(h.list.isEmpty)
	}

	@Test func noStopQuestionWithoutACall() {
		var h = Harness()
		h.at(0, .notesStarted)
		h.at(5, .call(.started(app: .other("Voice Memos"))))
		h.at(100, .call(.ended))
		h.advance(to: 200)
		#expect(h.list.isEmpty)
	}
}
