import Foundation
import NaturalLanguage
import Synchronization

/// Notes on one section of a meeting: the map step's output. Small, so many
/// of them fit the reduce prompt.
public struct SectionDigest: Sendable, Equatable {
	public var keyPoints: [String]
	public var decisions: [String]
	/// Earlier decisions changed in this section; lets the reduce keep only
	/// the final version of a reversed decision.
	public var changedDecisions: [String]
	public var actionItems: [MeetingSummary.ActionItem]

	public init(
		keyPoints: [String] = [], decisions: [String] = [], changedDecisions: [String] = [],
		actionItems: [MeetingSummary.ActionItem] = []
	) {
		self.keyPoints = keyPoints
		self.decisions = decisions
		self.changedDecisions = changedDecisions
		self.actionItems = actionItems
	}
}

/// A stretch of transcript small enough for one model call.
public struct TranscriptSection: Sendable, Equatable {
	public var index: Int
	/// "label: text" per line.
	public var text: String
	/// Meeting time of the first line.
	public var start: Double
	public var end: Double
}

/// The language model behind `Summarizer`. Apple Foundation Models in the
/// app, a fake in tests.
public protocol SummaryModel: Sendable {
	/// Nil when summaries can run; otherwise the one line the note shows.
	func unavailableReason() async -> String?
	func supports(languageCode: String) async -> Bool
	func map(_ section: TranscriptSection, language: String) async throws -> SectionDigest
	func condense(_ digests: [SectionDigest], language: String) async throws -> SectionDigest
	func reduce(_ digests: [SectionDigest], language: String) async throws -> MeetingSummary
}

/// What a summary attempt produced: a summary, or the line saying why not.
public struct SummaryOutcome: Sendable, Equatable {
	public var summary: MeetingSummary?
	public var notice: String?
}

/// Cuts a transcript into sections at turn boundaries.
enum SectionSplitter {
	struct Line: Sendable, Equatable {
		var label: String
		var text: String
		var start: Double
		var end: Double

		/// What the line costs in the prompt: "label: text\n".
		var size: Int { label.count + text.count + 3 }
	}

	static func lines(from segments: [NoteSegment]) -> [Line] {
		TranscriptMerger.merge(segments).map {
			Line(label: $0.speaker.label, text: $0.text, start: $0.start, end: $0.end)
		}
	}

	/// Sections of at most `maxCharacters`, never splitting a line. Characters
	/// stand in for tokens: the SDK has no token counter, and for one
	/// language they are a stable proxy (see the M0 LLM spike). A single line
	/// longer than the limit gets a section of its own.
	static func split(_ lines: [Line], maxCharacters: Int, firstIndex: Int = 1) -> [TranscriptSection] {
		var sections: [TranscriptSection] = []
		var current: [Line] = []
		var size = 0
		func flush() {
			guard let first = current.first, let last = current.last else { return }
			sections.append(TranscriptSection(
				index: firstIndex + sections.count,
				text: current.map { "\($0.label): \($0.text)" }.joined(separator: "\n"),
				start: first.start, end: last.end))
			current = []
			size = 0
		}
		for line in lines {
			if size + line.size > maxCharacters, !current.isEmpty { flush() }
			current.append(line)
			size += line.size
		}
		flush()
		return sections
	}
}

/// Summarizes a meeting map-reduce style while it is still going.
///
/// The on-device model has a ~4k-token context, so the transcript is cut into
/// ~6,000-character sections (about 7 minutes of talk), each mapped to a
/// `SectionDigest` as soon as it is full. After stop only the last section,
/// an occasional condense and the final reduce remain, which is what keeps
/// "60-minute meeting → note in under 60 s" realistic.
///
/// Never fails the note: every problem ends as a `SummaryOutcome` with a
/// notice instead of a summary.
public actor Summarizer {
	public static let sectionCharacters = 6_000
	/// Digests are condensed pairwise until their rendering fits this.
	static let reduceCharacters = 7_000
	/// A segment is only summarized live once it started this long before
	/// the newest audio: both tracks report within a chunk (≤ 10 s) plus the
	/// engine call, so later segments can't land in front of it any more.
	static let settleDelay = 30.0
	/// After stop, the summary gets this long before the note goes without.
	static let finishTimeout: Duration = .seconds(90)

	private struct Progress: Sendable {
		var digests: [SectionDigest] = []
		var failures = 0
	}

	private let model: any SummaryModel
	private let sectionCharacters: Int
	/// Segments starting before this (meeting time) are in a section already.
	private var consumedUntil = -Double.infinity
	private var sectionCount = 0
	/// English name of the meeting's language, fixed by the first section.
	private var language: String?
	private var unsupportedLanguage: String?
	/// Map calls run one after another, in section order.
	private var chain = Task<Progress, Never> { Progress() }

	public init(model: any SummaryModel, sectionCharacters: Int = Summarizer.sectionCharacters) {
		self.model = model
		self.sectionCharacters = sectionCharacters
	}

	/// Maps every section that is full and settled. `segments` is the whole
	/// transcript so far; `now` the meeting time of the newest audio.
	public func observe(_ segments: [NoteSegment], now: Double) async {
		guard unsupportedLanguage == nil else { return }
		let pending = segments.filter { $0.start >= consumedUntil && $0.start < now - Self.settleDelay }
		let lines = SectionSplitter.lines(from: pending)
		guard lines.reduce(0, { $0 + $1.size }) > sectionCharacters else { return }
		let sections = SectionSplitter.split(lines, maxCharacters: sectionCharacters, firstIndex: sectionCount + 1)
		// The last section may still grow; it waits for more talk.
		guard sections.count >= 2, let last = sections.last else { return }
		consumedUntil = last.start
		for section in sections.dropLast() {
			await enqueue(section)
		}
	}

	/// Summarizes what is left and merges everything. Waits at most
	/// `finishTimeout`.
	public func finish(_ segments: [NoteSegment]) async -> SummaryOutcome {
		let rest = SectionSplitter.lines(from: segments.filter { $0.start >= consumedUntil })
		consumedUntil = .infinity
		for section in SectionSplitter.split(rest, maxCharacters: sectionCharacters, firstIndex: sectionCount + 1) {
			await enqueue(section)
		}
		if let unsupportedLanguage {
			return SummaryOutcome(notice: "No summary: summaries don't cover \(unsupportedLanguage) yet.")
		}
		guard sectionCount > 0, let language else { return SummaryOutcome() }
		let chain = self.chain
		let model = self.model
		let outcome = await Deadline.run(within: Self.finishTimeout) {
			let progress = await chain.value
			guard !progress.digests.isEmpty else {
				return SummaryOutcome(notice: "No summary: the model couldn't summarize this meeting.")
			}
			do {
				let digests = try await Self.condense(progress.digests, model: model, language: language)
				return SummaryOutcome(summary: try await model.reduce(digests, language: language))
			} catch {
				return SummaryOutcome(notice: "No summary: the model couldn't summarize this meeting.")
			}
		}
		return outcome ?? SummaryOutcome(notice: "No summary: it took too long. The transcript is complete.")
	}

	/// Returns once every section queued so far is mapped. For tests: the map
	/// calls run in unstructured tasks, so nothing else says when they ran.
	func mappedQueuedSections() async {
		_ = await chain.value
	}

	private func enqueue(_ section: TranscriptSection) async {
		if language == nil {
			let code = Self.languageCode(of: section.text)
			if await model.supports(languageCode: code) {
				language = Self.englishName(of: code)
			} else {
				unsupportedLanguage = Self.englishName(of: code)
			}
		}
		guard unsupportedLanguage == nil, let language else { return }
		sectionCount += 1
		let previous = chain
		chain = Task { [model] in
			var progress = await previous.value
			do {
				progress.digests.append(try await model.map(section, language: language))
			} catch {
				// One refused or failed section shouldn't cost the rest.
				progress.failures += 1
			}
			return progress
		}
	}

	/// Merges digests pairwise until the reduce prompt fits.
	static func condense(_ digests: [SectionDigest], model: any SummaryModel, language: String) async throws -> [SectionDigest] {
		var digests = digests
		while SummaryPrompts.render(digests).count > reduceCharacters, digests.count > 1 {
			var merged: [SectionDigest] = []
			for pair in stride(from: 0, to: digests.count, by: 2) {
				let group = Array(digests[pair..<min(pair + 2, digests.count)])
				merged.append(group.count == 1 ? group[0] : try await model.condense(group, language: language))
			}
			digests = merged
		}
		return digests
	}

	static func languageCode(of text: String) -> String {
		let recognizer = NLLanguageRecognizer()
		recognizer.processString(text)
		return recognizer.dominantLanguage?.rawValue ?? "en"
	}

	static func englishName(of code: String) -> String {
		Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
	}
}

/// Runs work with a time limit. The work isn't cancelled (a model call may
/// not notice), the caller just stops waiting for it.
enum Deadline {
	static func run<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
		let resumed = Mutex(false)
		return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
			let finish: @Sendable (T?) -> Void = { value in
				let first = resumed.withLock { done in
					defer { done = true }
					return !done
				}
				if first { continuation.resume(returning: value) }
			}
			Task { finish(await work()) }
			Task {
				try? await Task.sleep(for: limit)
				finish(nil)
			}
		}
	}
}

/// Prompts from the M0 spike (`spikes/llm`), where they were written against
/// the meeting fixtures.
enum SummaryPrompts {
	static func mapInstructions(language: String) -> String {
		"""
		You take notes on one part of a meeting transcript. Each line is "speaker: what they said". "you" is the person taking the notes; other people are labelled "them" or "speaker 1", "speaker 2" and so on, and are often called by their first name in the conversation.
		Rules:
		- Use only what is said in this part. Never invent names, dates, numbers or tasks.
		- A decision is something the group agreed on. An idea that was only suggested or discussed is not a decision.
		- If people change or reverse something decided earlier, put it under changed decisions with the new outcome.
		- An action item is a task someone said they or someone else will do. Use the person's first name if it is said, "you" if the note taker takes it, and leave the owner empty if nobody took it.
		- Skip small talk.
		- Write everything in \(language).
		"""
	}

	static func mapPrompt(_ section: TranscriptSection) -> String {
		"Part \(section.index):\n\(section.text)"
	}

	static func reduceInstructions(language: String) -> String {
		"""
		You write the final notes for a meeting from notes on each part of it. The parts are in the order they happened.
		Rules:
		- Use only what is in the notes. Never invent anything.
		- When a later part changes or reverses an earlier decision, keep only the final outcome.
		- Merge duplicates. Keep names, dates and numbers exactly as written.
		- Keep every action item with its owner. Leave the owner empty if none is given.
		- Write everything in \(language).
		"""
	}

	static func condenseInstructions(language: String) -> String {
		"""
		You combine notes from two consecutive parts of a meeting into one set of notes. Keep every decision, changed decision and action item with its owner; shorten only the key points. Never invent anything. Write in \(language).
		"""
	}

	static func render(_ digests: [SectionDigest]) -> String {
		digests.enumerated().map { index, digest in
			var text = "Part \(index + 1):\n"
			func list(_ title: String, _ items: [String]) {
				guard !items.isEmpty else { return }
				text += "\(title):\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n"
			}
			list("Key points", digest.keyPoints)
			list("Decisions", digest.decisions)
			list("Changed decisions", digest.changedDecisions)
			list("Action items", digest.actionItems.map { "\($0.task) (\($0.owner ?? "no owner"))" })
			return text
		}.joined(separator: "\n")
	}
}
