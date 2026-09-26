import Foundation
import FoundationModels

@Generable
struct MeetingSummary: Codable {
	@Guide(description: "A short, specific title for the meeting, at most six words.")
	var title: String
	@Guide(description: "What the meeting was about and what came out of it, in two to four sentences.")
	var summary: String
	@Guide(description: "Final decisions the participants agreed on. Leave out ideas that were only discussed, and decisions that were later changed.", .maximumCount(10))
	var decisions: [String]
	@Guide(description: "Concrete tasks someone committed to do.", .maximumCount(15))
	var actionItems: [ActionItem]
}

@Generable
struct ActionItem: Codable {
	@Guide(description: "The task, starting with a verb.")
	var task: String
	@Guide(description: "Who will do it: a first name as said in the meeting, \"you\" for the note taker, or empty if nobody took it on.")
	var owner: String?
}

/// Map output: notes for one section. Kept small so many of them fit the reduce prompt.
@Generable
struct SectionNotes: Codable {
	@Guide(description: "The main points of this part, as short sentences.", .maximumCount(6))
	var keyPoints: [String]
	@Guide(description: "Decisions made in this part. Leave out ideas that were only discussed.", .maximumCount(6))
	var decisions: [String]
	@Guide(description: "Earlier decisions that were changed or reversed in this part, with the new outcome.", .maximumCount(4))
	var changedDecisions: [String]
	@Guide(description: "Concrete tasks someone committed to do in this part.", .maximumCount(8))
	var actionItems: [ActionItem]
}

struct TranscriptLine: Sendable {
	var time: String
	var speaker: String
	var text: String
	var raw: String
}

struct TranscriptSection: Sendable {
	var index: Int
	var start: String
	var end: String
	var text: String
	/// Spoken words only, without speaker labels.
	var words: Int
}

enum TranscriptSplitter {
	static func parse(_ transcript: String) -> [TranscriptLine] {
		transcript.split(separator: "\n").compactMap { line in
			let raw = String(line)
			guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { return nil }
			let time = String(raw[raw.index(after: raw.startIndex)..<close])
			let rest = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
			guard let colon = rest.firstIndex(of: ":") else { return nil }
			let speaker = String(rest[..<colon])
			let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			return TranscriptLine(time: time, speaker: speaker, text: text, raw: raw)
		}
	}

	/// Splits at turn boundaries so no sentence is cut. Size is in characters because the
	/// 26.1 SDK has no token counter; characters are a stable proxy for a given language.
	static func split(_ lines: [TranscriptLine], maxCharacters: Int) -> [TranscriptSection] {
		var sections: [TranscriptSection] = []
		var current: [TranscriptLine] = []
		var size = 0
		func flush() {
			guard let first = current.first, let last = current.last else { return }
			sections.append(TranscriptSection(
				index: sections.count + 1, start: first.time, end: last.time,
				text: current.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"),
				words: current.reduce(0) { $0 + $1.text.split(separator: " ").count }
			))
			current = []
			size = 0
		}
		for line in lines {
			let length = line.speaker.count + line.text.count + 3
			if size + length > maxCharacters, !current.isEmpty {
				flush()
			}
			current.append(line)
			size += length
		}
		flush()
		return sections
	}
}

/// Prototype of YapKit's `Notes/Summarizer`: map each section to `SectionNotes`, then
/// reduce all notes into one `MeetingSummary`. Every call gets a fresh session because
/// the 4k context can hold one section and nothing else.
struct Summarizer: Sendable {
	var language: DictationLanguage
	var permissiveGuardrails = true

	var model: SystemLanguageModel {
		SystemLanguageModel(
			useCase: .general,
			guardrails: permissiveGuardrails ? .permissiveContentTransformations : .default
		)
	}

	static let options = GenerationOptions(sampling: .greedy)

	func notes(for section: TranscriptSection, of total: Int) async throws -> SectionNotes {
		let session = LanguageModelSession(model: model, instructions: SummaryPrompts.mapInstructions(language: language))
		let prompt = SummaryPrompts.mapPrompt(section: section, total: total)
		return try await session.respond(to: prompt, generating: SectionNotes.self, options: Self.options).content
	}

	/// Retries with halves when a section overflows the context, so one dense stretch of
	/// talk can't fail the whole note.
	func notesSplittingOnOverflow(for section: TranscriptSection, of total: Int) async throws -> [SectionNotes] {
		do {
			return [try await notes(for: section, of: total)]
		} catch LanguageModelSession.GenerationError.exceededContextWindowSize {
			let lines = section.text.split(separator: "\n").map(String.init)
			guard lines.count > 1 else { throw LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "single turn too long")) }
			let half = lines.count / 2
			var first = section
			first.text = lines[..<half].joined(separator: "\n")
			var second = section
			second.text = lines[half...].joined(separator: "\n")
			return try await notesSplittingOnOverflow(for: first, of: total) + notesSplittingOnOverflow(for: second, of: total)
		}
	}

	func merge(_ notes: [SectionNotes]) async throws -> MeetingSummary {
		let session = LanguageModelSession(model: model, instructions: SummaryPrompts.reduceInstructions(language: language))
		let prompt = SummaryPrompts.reducePrompt(notes: notes)
		return try await session.respond(to: prompt, generating: MeetingSummary.self, options: Self.options).content
	}

	/// Collapses notes pairwise until the reduce prompt fits, for very long meetings.
	func condense(_ notes: [SectionNotes], maxCharacters: Int) async throws -> [SectionNotes] {
		var notes = notes
		while SummaryPrompts.render(notes).count > maxCharacters, notes.count > 1 {
			var merged: [SectionNotes] = []
			for pair in stride(from: 0, to: notes.count, by: 2) {
				let group = Array(notes[pair..<min(pair + 2, notes.count)])
				if group.count == 1 {
					merged.append(group[0])
					continue
				}
				let session = LanguageModelSession(model: model, instructions: SummaryPrompts.condenseInstructions(language: language))
				let result = try await session.respond(to: SummaryPrompts.render(group), generating: SectionNotes.self, options: Self.options)
				merged.append(result.content)
			}
			notes = merged
		}
		return notes
	}
}

enum SummaryPrompts {
	static func mapInstructions(language: DictationLanguage) -> String {
		"""
		You take notes on one part of a meeting transcript. Each line is "speaker: what they said". "you" is the person taking the notes; other people are labelled "speaker 1", "speaker 2" and so on, and are often called by their first name in the conversation.
		Rules:
		- Use only what is said in this part. Never invent names, dates, numbers or tasks.
		- A decision is something the group agreed on. An idea that was only suggested or discussed is not a decision.
		- If people change or reverse something decided earlier, put it under changed decisions with the new outcome.
		- An action item is a task someone said they or someone else will do. Use the person's first name if it is said, "you" if the note taker takes it, and leave the owner empty if nobody took it.
		- Skip small talk.
		- Write everything in \(language.englishName).
		"""
	}

	static func mapPrompt(section: TranscriptSection, total: Int) -> String {
		"Part \(section.index) of \(total) (\(section.start) to \(section.end)):\n\(section.text)"
	}

	static func reduceInstructions(language: DictationLanguage) -> String {
		"""
		You write the final notes for a meeting from notes on each part of it. The parts are in the order they happened.
		Rules:
		- Use only what is in the notes. Never invent anything.
		- When a later part changes or reverses an earlier decision, keep only the final outcome.
		- Merge duplicates. Keep names, dates and numbers exactly as written.
		- Keep every action item with its owner. Leave the owner empty if none is given.
		- Write everything in \(language.englishName).
		"""
	}

	static func condenseInstructions(language: DictationLanguage) -> String {
		"""
		You combine notes from two consecutive parts of a meeting into one set of notes. Keep every decision, changed decision and action item with its owner; shorten only the key points. Never invent anything. Write in \(language.englishName).
		"""
	}

	static func reducePrompt(notes: [SectionNotes]) -> String {
		render(notes)
	}

	static func render(_ notes: [SectionNotes]) -> String {
		notes.enumerated().map { index, note in
			var text = "Part \(index + 1):\n"
			if !note.keyPoints.isEmpty {
				text += "Key points:\n" + note.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n"
			}
			if !note.decisions.isEmpty {
				text += "Decisions:\n" + note.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n"
			}
			if !note.changedDecisions.isEmpty {
				text += "Changed decisions:\n" + note.changedDecisions.map { "- \($0)" }.joined(separator: "\n") + "\n"
			}
			if !note.actionItems.isEmpty {
				text += "Action items:\n" + note.actionItems.map { item in
					let owner = item.owner.flatMap { $0.isEmpty ? nil : $0 } ?? "no owner"
					return "- \(item.task) (\(owner))"
				}.joined(separator: "\n") + "\n"
			}
			return text
		}.joined(separator: "\n")
	}
}
