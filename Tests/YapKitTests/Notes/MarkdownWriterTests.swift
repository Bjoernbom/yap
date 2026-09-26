import Foundation
import Testing
@testable import YapKit

private let stockholm = TimeZone(identifier: "Europe/Stockholm")!

/// 2026-10-02 14:05:09 in Stockholm.
private let meetingStart = Date(timeIntervalSince1970: 1_790_942_709)

private func sampleNote(summary: MeetingSummary?, notices: [String] = []) -> Note {
	Note(
		startedAt: meetingStart,
		duration: 754,
		segments: [
			NoteSegment(speaker: .you, start: 0.4, end: 3, text: "Okay, let's get going."),
			NoteSegment(speaker: .you, start: 3.2, end: 5, text: "First the release date."),
			NoteSegment(speaker: .them(1), start: 5.5, end: 9, text: "I think Friday is realistic."),
			NoteSegment(speaker: .them(2), start: 9.4, end: 12, text: "Friday works if QA signs off Thursday."),
			NoteSegment(speaker: .you, start: 12.5, end: 14, text: "Deal, Friday it is."),
			NoteSegment(speaker: .them(1), start: 65, end: 70, text: "I'll write the release notes."),
		],
		summary: summary,
		apps: ["Zoom", "Slack \"huddle\""],
		notices: notices)
}

private let sampleSummary = MeetingSummary(
	title: "Release: Friday / QA",
	summary: "The team picked a release date. QA signs off on Thursday.",
	decisions: ["Release on Friday."],
	actionItems: [
		.init(task: "Write the release notes", owner: "speaker 1"),
		.init(task: "Book the QA slot"),
	])

@Suite("Markdown notes")
struct MarkdownWriterTests {
	private let writer = MarkdownWriter(folder: URL(filePath: "/unused"), timeZone: stockholm)

	/// The golden file is the spec for the note format; update it on purpose.
	@Test func rendersTheGoldenNote() throws {
		let golden = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/note.golden.md")
		let expected = try String(contentsOf: golden, encoding: .utf8)
		#expect(writer.render(sampleNote(summary: sampleSummary)) == expected)
	}

	@Test func withoutASummaryTheNoteIsTranscriptOnlyAndSaysWhy() {
		let notice = "No summary: Apple Intelligence is off. Turn it on in System Settings → Apple Intelligence & Siri."
		let markdown = writer.render(sampleNote(summary: nil, notices: [notice]))
		#expect(markdown.contains("# Meeting 14.05\n"))
		#expect(markdown.contains("> \(notice)\n"))
		#expect(!markdown.contains("## Summary"))
		#expect(!markdown.contains("## Action items"))
		#expect(markdown.contains("## Transcript\n\n**you** [00:00] Okay, let's get going. First the release date.\n"))
	}

	@Test func timestampsPastAnHourShowHours() {
		#expect(MarkdownWriter.clock(0) == "00:00")
		#expect(MarkdownWriter.clock(754.9) == "12:34")
		#expect(MarkdownWriter.clock(3_725) == "1:02:05")
	}

	@Test func fileNameIsDateAndTitle() {
		#expect(writer.baseName(for: sampleNote(summary: sampleSummary)) == "2026-10-02 Release Friday QA")
		#expect(writer.baseName(for: sampleNote(summary: nil)) == "2026-10-02 Meeting 14.05")
	}
}

@Suite("File names")
struct SafeFileNameTests {
	@Test(arguments: [
		("Design sync", "Design sync"),
		("Q4: roadmap / budget", "Q4 roadmap budget"),
		("../../etc/passwd", "etc passwd"),
		(".hidden", "hidden"),
		("Line\nbreak\ttab", "Line break tab"),
		("What? <Why> \"quoted\" a|b *star* #tag [link]^", "What Why quoted a b star tag link"),
		("trailing dots...", "trailing dots"),
		("   ", "Meeting"),
		("", "Meeting"),
		("Möte om lönerevision 😀", "Möte om lönerevision 😀"),
	])
	func titlesBecomeSafeNames(title: String, expected: String) {
		#expect(MarkdownWriter.safeFileName(title) == expected)
	}

	@Test func longTitlesAreCut() {
		let name = MarkdownWriter.safeFileName(String(repeating: "word ", count: 60))
		#expect(name.count <= MarkdownWriter.maxTitleLength)
		#expect(!name.hasSuffix(" "))
	}
}

@Suite("Writing note files")
struct NoteFileTests {
	private func scratch() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appending(path: "yap-notes-test-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	@Test func neverOverwritesAnExistingNote() throws {
		let folder = try scratch()
		defer { try? FileManager.default.removeItem(at: folder) }
		let writer = MarkdownWriter(folder: folder, fallbackFolder: folder, timeZone: stockholm)
		let note = sampleNote(summary: sampleSummary)
		let first = try writer.write(note)
		let second = try writer.write(note)
		let third = try writer.write(note)
		#expect(first.url.lastPathComponent == "2026-10-02 Release Friday QA.md")
		#expect(second.url.lastPathComponent == "2026-10-02 Release Friday QA 2.md")
		#expect(third.url.lastPathComponent == "2026-10-02 Release Friday QA 3.md")
		#expect(first.fallbackNotice == nil)
		#expect(try String(contentsOf: first.url, encoding: .utf8) == first.markdown)
	}

	@Test func anUnwritableFolderFallsBackAndSaysSo() throws {
		let root = try scratch()
		defer { try? FileManager.default.removeItem(at: root) }
		let locked = root.appending(path: "locked")
		try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
		let fallback = root.appending(path: "fallback")
		let writer = MarkdownWriter(folder: locked, fallbackFolder: fallback, timeZone: stockholm)
		let written = try writer.write(sampleNote(summary: nil))
		#expect(written.url.deletingLastPathComponent().lastPathComponent == "fallback")
		#expect(written.fallbackNotice?.contains("Couldn't write to locked") == true)
	}
}
