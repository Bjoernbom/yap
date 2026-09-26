import Foundation
import Synchronization
import Testing
@testable import YapKit

/// Records what the summarizer asked for; each digest's key point is the
/// section's first line, so tests can see what went where.
private actor FakeSummaryModel: SummaryModel {
	var unavailable: String?
	var supported = true
	var failingSections: Set<Int> = []
	private(set) var mapped: [TranscriptSection] = []
	private(set) var condenseCalls = 0
	private(set) var reduced: [SectionDigest] = []
	private(set) var languages: [String] = []

	init(unavailable: String? = nil, supported: Bool = true, failingSections: Set<Int> = []) {
		self.unavailable = unavailable
		self.supported = supported
		self.failingSections = failingSections
	}

	func unavailableReason() async -> String? { unavailable }
	func supports(languageCode: String) async -> Bool { supported }

	func map(_ section: TranscriptSection, language: String) async throws -> SectionDigest {
		mapped.append(section)
		languages.append(language)
		if failingSections.contains(section.index) { throw FakeError() }
		let first = section.text.split(separator: "\n").first.map(String.init) ?? ""
		return SectionDigest(keyPoints: [first], decisions: ["decision \(section.index)"])
	}

	func condense(_ digests: [SectionDigest], language: String) async throws -> SectionDigest {
		condenseCalls += 1
		return SectionDigest(keyPoints: digests.flatMap(\.keyPoints).map { String($0.prefix(20)) }, decisions: digests.flatMap(\.decisions))
	}

	func reduce(_ digests: [SectionDigest], language: String) async throws -> MeetingSummary {
		reduced = digests
		return MeetingSummary(title: "Fake", summary: "\(digests.count) parts", decisions: digests.flatMap(\.decisions))
	}
}

/// ~100 characters of English per segment, one every 5 s, alternating speakers.
private func meeting(minutes: Double) -> [NoteSegment] {
	let sentence = "We went through the release plan again and agreed that the numbers for the budget look fine now."
	return stride(from: 0.0, to: minutes * 60, by: 5).enumerated().map { index, start in
		NoteSegment(speaker: index.isMultiple(of: 2) ? .you : .them(nil), start: start, end: start + 4.5, text: "\(index): \(sentence)")
	}
}

@Suite("Section splitting")
struct SectionSplitterTests {
	private func line(_ text: String, at start: Double) -> SectionSplitter.Line {
		SectionSplitter.Line(label: "you", text: text, start: start, end: start + 1)
	}

	@Test func splitsAtLineBoundariesUnderTheLimit() {
		let lines = (0..<10).map { line(String(repeating: "x", count: 94), at: Double($0)) }
		let sections = SectionSplitter.split(lines, maxCharacters: 300)
		// 100 characters per line ("you: " + 94 + newline), three fit per section.
		#expect(sections.map { $0.text.split(separator: "\n").count } == [3, 3, 3, 1])
		#expect(sections.allSatisfy { $0.text.count <= 300 })
		#expect(sections.map(\.index) == [1, 2, 3, 4])
		#expect(sections[1].start == 3 && sections[1].end == 6)
	}

	@Test func anOversizedLineGetsASectionOfItsOwn() {
		let sections = SectionSplitter.split(
			[line("short", at: 0), line(String(repeating: "y", count: 500), at: 1), line("after", at: 2)],
			maxCharacters: 300)
		#expect(sections.count == 3)
	}

	@Test func linesMergeConsecutiveSpeakerSegmentsAndCarryLabels() {
		let lines = SectionSplitter.lines(from: [
			NoteSegment(speaker: .you, start: 0, end: 1, text: "Hi."),
			NoteSegment(speaker: .you, start: 1, end: 2, text: "Ready?"),
			NoteSegment(speaker: .them(2), start: 2, end: 3, text: "Yes."),
		])
		#expect(lines.map { "\($0.label): \($0.text)" } == ["you: Hi. Ready?", "speaker 2: Yes."])
	}

	@Test func emptyInputHasNoSections() {
		#expect(SectionSplitter.split([], maxCharacters: 100).isEmpty)
	}
}

@Suite("Live map-reduce summaries")
struct SummarizerTests {
	@Test func fullSectionsAreSummarizedDuringTheMeeting() async {
		let model = FakeSummaryModel()
		let summarizer = Summarizer(model: model)
		let segments = meeting(minutes: 30)
		// Feed the transcript as it would grow, one minute at a time.
		for minute in 1...30 {
			let now = Double(minute) * 60
			await summarizer.observe(segments.filter { $0.end <= now }, now: now)
		}
		// Let the queued map calls run.
		try? await Task.sleep(for: .milliseconds(100))
		let mappedLive = await model.mapped.count
		#expect(mappedLive >= 4)

		let outcome = await summarizer.finish(segments)
		let mapped = await model.mapped
		// After stop only what was left: at most the settle window plus one section.
		#expect(mapped.count - mappedLive <= 2)
		#expect(outcome.summary?.title == "Fake")
		#expect(outcome.notice == nil)
		// Every line landed in exactly one section, in order.
		let lines = mapped.flatMap { $0.text.split(separator: "\n") }
		#expect(lines.count == SectionSplitter.lines(from: segments).count)
		#expect(mapped.map(\.index) == Array(1...mapped.count))
		#expect(mapped.allSatisfy { $0.text.count <= Summarizer.sectionCharacters })
		#expect(await model.languages.allSatisfy { $0 == "English" })
	}

	@Test func aFailedSectionIsSkippedNotFatal() async {
		let model = FakeSummaryModel(failingSections: [2])
		let summarizer = Summarizer(model: model)
		let outcome = await summarizer.finish(meeting(minutes: 20))
		#expect(outcome.summary != nil)
		#expect(await model.reduced.contains { $0.decisions == ["decision 2"] } == false)
	}

	@Test func everySectionFailingGivesANoticeInsteadOfASummary() async {
		let model = FakeSummaryModel(failingSections: Set(1...50))
		let outcome = await Summarizer(model: model).finish(meeting(minutes: 10))
		#expect(outcome.summary == nil)
		#expect(outcome.notice?.hasPrefix("No summary") == true)
	}

	@Test func anUnsupportedLanguageSaysSo() async {
		let model = FakeSummaryModel(supported: false)
		let outcome = await Summarizer(model: model).finish(meeting(minutes: 2))
		#expect(outcome.summary == nil)
		#expect(outcome.notice == "No summary: summaries don't cover English yet.")
		#expect(await model.mapped.isEmpty)
	}

	@Test func anEmptyMeetingHasNoSummaryAndNoNotice() async {
		let outcome = await Summarizer(model: FakeSummaryModel()).finish([])
		#expect(outcome == SummaryOutcome())
	}

	@Test func longMeetingsAreCondensedBeforeTheReduce() async {
		let model = FakeSummaryModel()
		// Small sections make many digests, whose rendering overflows the reduce budget.
		let summarizer = Summarizer(model: model, sectionCharacters: 400)
		_ = await summarizer.finish(meeting(minutes: 40))
		#expect(await model.condenseCalls > 0)
		#expect(SummaryPrompts.render(await model.reduced).count <= Summarizer.reduceCharacters)
	}

	@Test func theDeadlineStopsWaiting() async {
		let result = await Deadline.run(within: .milliseconds(50)) { () -> Int in
			try? await Task.sleep(for: .seconds(5))
			return 1
		}
		#expect(result == nil)
		#expect(await Deadline.run(within: .seconds(5)) { 2 } == 2)
	}
}
