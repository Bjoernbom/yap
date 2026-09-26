import Testing
@testable import YapKit

private func segment(_ speaker: Speaker, _ start: Double, _ end: Double, _ text: String) -> NoteSegment {
	NoteSegment(speaker: speaker, start: start, end: end, text: text)
}

@Suite("Merging segments into paragraphs")
struct TranscriptMergerTests {
	@Test func consecutiveSegmentsFromOneSpeakerBecomeOneParagraph() {
		let merged = TranscriptMerger.merge([
			segment(.you, 0, 3, "Hi, thanks for joining."),
			segment(.you, 3.5, 6, "Let's start with the budget."),
			segment(.them(1), 6.2, 9, "Sure."),
			segment(.them(1), 9.5, 12, "Numbers are in."),
			segment(.you, 12.5, 14, "Great."),
		])
		#expect(merged.map(\.speaker) == [.you, .them(1), .you])
		#expect(merged[0].text == "Hi, thanks for joining. Let's start with the budget.")
		#expect(merged[0].start == 0 && merged[0].end == 6)
		#expect(merged[1].text == "Sure. Numbers are in.")
	}

	@Test func segmentsAreOrderedByStartAcrossTracks() {
		// The mic track reports later than "them", but the transcript follows the clock.
		let merged = TranscriptMerger.merge([
			segment(.them(nil), 5, 7, "Second."),
			segment(.you, 1, 3, "First."),
			segment(.you, 8, 9, "Third."),
		])
		#expect(merged.map(\.text) == ["First.", "Second.", "Third."])
	}

	@Test func differentThemSpeakersStayApart() {
		let merged = TranscriptMerger.merge([
			segment(.them(1), 0, 2, "One."),
			segment(.them(2), 2, 4, "Two."),
		])
		#expect(merged.count == 2)
	}

	@Test func aLongPauseOrALongStretchStartsANewParagraph() {
		let paused = TranscriptMerger.merge([
			segment(.you, 0, 2, "Before."),
			segment(.you, 40, 42, "After a coffee."),
		])
		#expect(paused.count == 2)

		let long = (0..<20).map { segment(.you, Double($0) * 10, Double($0) * 10 + 9, "Part \($0).") }
		let merged = TranscriptMerger.merge(long)
		#expect(merged.count == 2)
		#expect(merged.allSatisfy { $0.end - $0.start <= TranscriptMerger.maxLength })
	}

	@Test func emptySegmentsDisappear() {
		let merged = TranscriptMerger.merge([segment(.you, 0, 1, "  "), segment(.you, 1, 2, "Hello.")])
		#expect(merged == [segment(.you, 1, 2, "Hello.")])
	}
}

@Suite("Mic echo removal")
struct EchoFilterTests {
	@Test func aYouSegmentRepeatingThemAtTheSameTimeIsDropped() {
		let segments = [
			segment(.them(nil), 10, 14, "We should ship the release on Friday."),
			// The mic heard the speakers, slightly later and a word off.
			segment(.you, 10.4, 14.3, "We should ship the release Friday."),
			segment(.you, 15, 17, "Friday works for me."),
		]
		let kept = EchoFilter.removeEcho(from: segments)
		#expect(kept.map(\.text) == ["We should ship the release on Friday.", "Friday works for me."])
	}

	@Test func theSameWordsAtAnotherTimeAreKept() {
		let segments = [
			segment(.them(nil), 10, 14, "We should ship the release on Friday."),
			segment(.you, 60, 64, "We should ship the release on Friday."),
		]
		#expect(EchoFilter.removeEcho(from: segments).count == 2)
	}

	@Test func shortSegmentsAreNeverDropped() {
		// "Yes." is as likely the user agreeing as an echo.
		let segments = [
			segment(.them(nil), 10, 11, "Okay, yes."),
			segment(.you, 10.2, 11, "Okay, yes."),
		]
		#expect(EchoFilter.removeEcho(from: segments).count == 2)
	}

	@Test func talkingOverTheOtherSideKeepsTheMixedSegment() {
		let segments = [
			segment(.them(nil), 10, 14, "Can everyone see my screen now?"),
			segment(.you, 10, 16, "Can everyone see yes I can see it and the numbers look right"),
		]
		#expect(EchoFilter.removeEcho(from: segments).count == 2)
	}

	@Test func withoutThemNothingIsDropped() {
		let segments = [segment(.you, 0, 3, "Just me talking here today.")]
		#expect(EchoFilter.removeEcho(from: segments) == segments)
	}

	@Test func theUsersLastWordsSurviveWhenEchoFollowsInTheSameChunk() {
		// The VAD didn't cut in the short pause, so one chunk holds the end of
		// the user's question and the start of the answer leaking in.
		let segments = [
			segment(.them(nil), 33, 38, "I will fix the Swedish characters in the export before Tuesday."),
			segment(.you, 30, 37, "What about the CSV export bug? I will fix the Swedish characters in the"),
		]
		let kept = EchoFilter.removeEcho(from: segments)
		#expect(kept.map(\.text) == ["I will fix the Swedish characters in the export before Tuesday.", "What about the CSV export bug?"])
	}

	/// Words at 0.3 s each from `start`, for timed segments.
	private func timed(_ text: String, from start: Double) -> [TimedWord] {
		text.split(separator: " ").enumerated().map { index, word in
			TimedWord(text: String(word), start: start + Double(index) * 0.3, end: start + Double(index + 1) * 0.3)
		}
	}

	private func timedSegment(_ speaker: Speaker, _ text: String, from start: Double) -> NoteSegment {
		let words = timed(text, from: start)
		return NoteSegment(speaker: speaker, start: start, end: words.last?.end ?? start, text: text, words: words)
	}

	@Test func withTimingsTheUsersOwnWordsAroundTheEchoStay() {
		// One chunk: the end of the user's question, the answer leaking in
		// (one word misheard), and the user again. The VAD didn't cut in the
		// short pauses.
		let them = timedSegment(.them(nil), "I will fix the Swedish characters.", from: 33)
		var words = timed("export bug?", from: 32.2)
		words += timed("I will fix those Swedish characters.", from: 33.05)
		words += timed("Great, thanks.", from: 35.5)
		let you = NoteSegment(speaker: .you, start: 32.2, end: 36.1, text: words.map(\.text).joined(separator: " "), words: words)
		let kept = EchoFilter.removeEcho(from: [them, you])
		#expect(kept.map(\.text) == ["I will fix the Swedish characters.", "export bug? Great, thanks."])
	}

	@Test func withTimingsTheSameWordsAtAnotherMomentStay() {
		let them = timedSegment(.them(nil), "Ship on Friday then.", from: 10)
		// The user repeats it after a pause: agreement, not echo.
		let you = timedSegment(.you, "Ship on Friday then.", from: 11.8)
		#expect(EchoFilter.removeEcho(from: [them, you]).count == 2)
	}

	@Test func withTimingsAnEchoOnlySegmentGoes() {
		let them = timedSegment(.them(nil), "Can everyone see my screen now?", from: 4)
		let you = timedSegment(.you, "Can everyone see my screen now?", from: 4.08)
		#expect(EchoFilter.removeEcho(from: [them, you]).map(\.speaker) == [.them(nil)])
	}

	@Test func matchesFindTheCommonSubsequence() {
		#expect(EchoFilter.matches(["a", "b", "c", "d"], ["a", "c", "d", "e"]) == [0, 2, 3])
		#expect(EchoFilter.matches([], ["a"]).isEmpty)
	}
}

@Suite("Track timeline")
struct TrackTimelineTests {
	private let ticks = HostClock.ticksPerSecond

	private func chunk(at seconds: Double, length: Double = 0.1) -> AudioChunk {
		AudioChunk(samples: [Float](repeating: 0.1, count: Int(length * 16_000)), hostTime: UInt64(seconds * ticks) + 1_000_000)
	}

	@Test func continuousAudioMapsStraightThrough() {
		var timeline = TrackTimeline(origin: 1_000_000)
		for index in 0..<50 {
			#expect(timeline.place(chunk(at: 2 + Double(index) * 0.1)).count == 1_600)
		}
		#expect(timeline.anchors.count == 1)
		#expect(abs(timeline.meetingTime(stream: 0) - 2) < 0.001)
		#expect(abs(timeline.meetingTime(stream: 3) - 5) < 0.001)
	}

	@Test func aGapInsertsASecondOfSilenceAndKeepsHostTime() {
		var timeline = TrackTimeline(origin: 1_000_000)
		_ = timeline.place(chunk(at: 0, length: 1))
		// Nothing played for a minute: no callbacks at all.
		let samples = timeline.place(chunk(at: 61, length: 1))
		#expect(samples.count == 16_000 + 16_000)
		#expect(samples.prefix(16_000).allSatisfy { $0 == 0 })
		// The chunk after the gap starts 2 s into the stream (1 s audio + 1 s fill).
		#expect(abs(timeline.meetingTime(stream: 2.5) - 61.5) < 0.001)
		// Audio before the gap keeps its own times.
		#expect(abs(timeline.meetingTime(stream: 0.5) - 0.5) < 0.001)
	}

	@Test func smallJitterDoesNotAddAnchors() {
		var timeline = TrackTimeline(origin: 1_000_000)
		_ = timeline.place(chunk(at: 0))
		_ = timeline.place(chunk(at: 0.15))
		_ = timeline.place(chunk(at: 0.2))
		#expect(timeline.anchors.count == 1)
	}
}

@Suite("Speaker assignment")
struct SpeakerAssignmentTests {
	private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
		TimedWord(text: text, start: start, end: end)
	}

	@Test func aChunkSpanningATurnChangeIsSplitAndNumberedInOrder() {
		var assignment = SpeakerAssignment(turns: [
			SpeakerTurn(speaker: "S7", start: 0, end: 2.5),
			SpeakerTurn(speaker: "S3", start: 2.6, end: 6),
		])
		let runs = assignment.split([
			word("Hello", 0.1, 0.8), word("there,", 0.8, 1.5), word("everyone.", 1.5, 2.3),
			word("Hi", 2.8, 3.3), word("Anna,", 3.3, 4.0), word("welcome.", 4.0, 4.8),
		])
		#expect(runs.map(\.speaker) == [1, 2])
		#expect(runs.map { $0.words.map(\.text) } == [["Hello", "there,", "everyone."], ["Hi", "Anna,", "welcome."]])
	}

	@Test func aShortStretchAtATurnEdgeJoinsItsNeighbour() {
		// The diarizer starts speaker B's turn a word early.
		var assignment = SpeakerAssignment(turns: [
			SpeakerTurn(speaker: "A", start: 0, end: 0.9),
			SpeakerTurn(speaker: "B", start: 0.9, end: 6),
		])
		let runs = assignment.split([
			word("Morning,", 0.2, 0.8), word("the", 1.0, 1.2), word("beta", 1.2, 1.6),
			word("has", 1.6, 1.9), word("been", 1.9, 2.2), word("stable.", 2.2, 3.0),
		])
		#expect(runs.count == 1)
		#expect(runs.first?.speaker == 1)
		#expect(runs.first?.words.count == 6)
		// A was never shown, so B is speaker 1.
		#expect(assignment.numbers == ["B": 1])
	}

	@Test func aWordBetweenTurnsTakesTheNearestOne() {
		var assignment = SpeakerAssignment(turns: [SpeakerTurn(speaker: "A", start: 0, end: 1)])
		let runs = assignment.split([word("late", 1.3, 1.6)])
		#expect(runs.first?.speaker == 1)
	}

	@Test func wordsFarFromAnyTurnKeepThePreviousSpeaker() {
		var assignment = SpeakerAssignment(turns: [SpeakerTurn(speaker: "A", start: 0, end: 1)])
		let runs = assignment.split([word("in", 0.2, 0.5), word("far", 9, 9.5)])
		#expect(runs.count == 1)
		#expect(runs.first?.speaker == 1)
	}
}
