import Foundation
import FoundationModels

/// `SummaryModel` on Apple Foundation Models, on-device. Every call gets a
/// fresh session: one section plus instructions, schema and output is all a
/// 4k context holds.
public struct FoundationSummaryModel: SummaryModel {
	public init() {}

	/// Permissive guardrails: meetings talk about health, money and people,
	/// and a refusal on a summary is worse than useless.
	private var model: SystemLanguageModel {
		SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
	}

	private static let options = GenerationOptions(sampling: .greedy)

	/// Read the API rather than inferring it: the M0 spike found an opt-in
	/// preference reading 1 while the model was off.
	public func unavailableReason() async -> String? {
		switch SystemLanguageModel.default.availability {
		case .available:
			return nil
		case .unavailable(.appleIntelligenceNotEnabled):
			return "No summary: Apple Intelligence is off. Turn it on in System Settings → Apple Intelligence & Siri."
		case .unavailable(.modelNotReady):
			return "No summary: Apple Intelligence is still downloading its model."
		case .unavailable(.deviceNotEligible):
			return "No summary: this Mac can't run Apple Intelligence."
		case .unavailable:
			return "No summary: Apple Intelligence isn't available right now."
		}
	}

	public func supports(languageCode: String) async -> Bool {
		SystemLanguageModel.default.supportsLocale(Locale(identifier: languageCode))
	}

	public func map(_ section: TranscriptSection, language: String) async throws -> SectionDigest {
		do {
			let session = LanguageModelSession(model: model, instructions: SummaryPrompts.mapInstructions(language: language))
			let response = try await session.respond(
				to: SummaryPrompts.mapPrompt(section), generating: GeneratedSectionNotes.self, options: Self.options)
			return response.content.digest
		} catch LanguageModelSession.GenerationError.exceededContextWindowSize(let context) {
			// A dense stretch of talk overflowed: halve it at a line and retry,
			// so one section can't cost the whole summary.
			let lines = section.text.split(separator: "\n").map(String.init)
			guard lines.count > 1 else {
				throw LanguageModelSession.GenerationError.exceededContextWindowSize(context)
			}
			var first = section
			first.text = lines[..<(lines.count / 2)].joined(separator: "\n")
			var second = section
			second.text = lines[(lines.count / 2)...].joined(separator: "\n")
			let left = try await map(first, language: language)
			let right = try await map(second, language: language)
			return SectionDigest(
				keyPoints: left.keyPoints + right.keyPoints,
				decisions: left.decisions + right.decisions,
				changedDecisions: left.changedDecisions + right.changedDecisions,
				actionItems: left.actionItems + right.actionItems)
		}
	}

	public func condense(_ digests: [SectionDigest], language: String) async throws -> SectionDigest {
		let session = LanguageModelSession(model: model, instructions: SummaryPrompts.condenseInstructions(language: language))
		let response = try await session.respond(
			to: SummaryPrompts.render(digests), generating: GeneratedSectionNotes.self, options: Self.options)
		return response.content.digest
	}

	public func reduce(_ digests: [SectionDigest], language: String) async throws -> MeetingSummary {
		let session = LanguageModelSession(model: model, instructions: SummaryPrompts.reduceInstructions(language: language))
		let response = try await session.respond(
			to: SummaryPrompts.render(digests), generating: GeneratedMeetingSummary.self, options: Self.options)
		return response.content.meetingSummary
	}
}

@Generable
struct GeneratedMeetingSummary {
	@Guide(description: "A short, specific title for the meeting, at most six words.")
	var title: String
	@Guide(description: "What the meeting was about and what came out of it, in two to four sentences.")
	var summary: String
	@Guide(description: "Final decisions the participants agreed on. Leave out ideas that were only discussed, and decisions that were later changed.", .maximumCount(10))
	var decisions: [String]
	@Guide(description: "Concrete tasks someone committed to do.", .maximumCount(15))
	var actionItems: [GeneratedActionItem]

	var meetingSummary: MeetingSummary {
		MeetingSummary(title: title, summary: summary, decisions: decisions, actionItems: actionItems.map(\.item))
	}
}

@Generable
struct GeneratedActionItem {
	@Guide(description: "The task, starting with a verb.")
	var task: String
	@Guide(description: "Who will do it: a first name as said in the meeting, \"you\" for the note taker, or empty if nobody took it on.")
	var owner: String?

	var item: MeetingSummary.ActionItem {
		let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
		return MeetingSummary.ActionItem(task: task, owner: owner?.isEmpty == false ? owner : nil)
	}
}

@Generable
struct GeneratedSectionNotes {
	@Guide(description: "The main points of this part, as short sentences.", .maximumCount(6))
	var keyPoints: [String]
	@Guide(description: "Decisions made in this part. Leave out ideas that were only discussed.", .maximumCount(6))
	var decisions: [String]
	@Guide(description: "Earlier decisions that were changed or reversed in this part, with the new outcome.", .maximumCount(4))
	var changedDecisions: [String]
	@Guide(description: "Concrete tasks someone committed to do in this part.", .maximumCount(8))
	var actionItems: [GeneratedActionItem]

	var digest: SectionDigest {
		SectionDigest(
			keyPoints: keyPoints, decisions: decisions, changedDecisions: changedDecisions,
			actionItems: actionItems.map(\.item))
	}
}
