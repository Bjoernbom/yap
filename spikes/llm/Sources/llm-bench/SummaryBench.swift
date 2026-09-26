import Foundation
import FoundationModels

struct ExpectedMeeting: Codable, Sendable {
	struct Item: Codable, Sendable {
		var task: String
		var owner: String?
	}

	struct Reversal: Codable, Sendable {
		var initial: String
		var final: String
	}

	var language: DictationLanguage
	var durationMinutes: Int
	var title: String
	var decisions: [String]
	var actionItems: [Item]
	var notDecided: [String]
	var reversed: Reversal
}

struct SummaryRun: Codable, Sendable {
	var meeting: String
	var sectionCharacters: Int
	var sections: Int
	var averageSectionWords: Int
	var averageSectionMinutes: Double
	var mapLatenciesMs: [Double]
	var condenseMs: Double
	var reduceMs: Double
	var totalMs: Double
	/// Time left after the user presses stop if sections are mapped live during the
	/// meeting: the last section plus the reduce.
	var afterStopMs: Double
	var reducePromptCharacters: Int
	var summary: MeetingSummary?
	var error: String?
}

/// `llm-bench summary [--meetings sv,en] [--section-chars 4000,6000,8000] [--reduce-chars 7000] [--parallel 1]`
enum SummaryBench {
	static func run(_ options: Options) async throws {
		let meetings = options.list("meetings", default: ["sv", "en"])
		let sizes = options.list("section-chars", default: ["4000", "6000", "8000"]).compactMap(Int.init)
		let reduceCharacters = options.int("reduce-chars", default: 7000)
		let parallel = max(options.int("parallel", default: 1), 1)
		let dryRun = options.flag("dry-run")

		if !dryRun, !Bench.requireModel() { return }

		var runs: [SummaryRun] = []
		var expectations: [String: ExpectedMeeting] = [:]
		for meeting in meetings {
			let transcript = try String(contentsOf: try Bench.fixtureURL("meeting-\(meeting).txt"), encoding: .utf8)
			let expectedData = try Data(contentsOf: try Bench.fixtureURL("meeting-\(meeting).expected.json"))
			let expected = try JSONDecoder().decode(ExpectedMeeting.self, from: expectedData)
			expectations[meeting] = expected
			let lines = TranscriptSplitter.parse(transcript)
			let words = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
			print("meeting \(meeting): \(lines.count) turns, \(words) words, \(transcript.count) chars, ends \(lines.last?.time ?? "?")")

			for size in sizes {
				let sections = TranscriptSplitter.split(lines, maxCharacters: size)
				let minutes = sections.map { minutesBetween($0.start, $0.end) }
				let sectionWords = sections.map { $0.text.split(separator: " ").count }
				print(String(format: "  section-chars %d: %d sections, avg %d words, avg %.1f min", size, sections.count, sectionWords.reduce(0, +) / max(sections.count, 1), minutes.reduce(0, +) / Double(max(minutes.count, 1))))
				if dryRun { continue }

				let run = await summarize(
					meeting: meeting, sections: sections, size: size, language: expected.language,
					reduceCharacters: reduceCharacters, parallel: parallel,
					averageWords: sectionWords.reduce(0, +) / max(sections.count, 1),
					averageMinutes: minutes.reduce(0, +) / Double(max(minutes.count, 1))
				)
				print(String(format: "    total %.1f s, after stop %.1f s, reduce %.1f s %@", run.totalMs / 1000, run.afterStopMs / 1000, run.reduceMs / 1000, run.error ?? ""))
				runs.append(run)
			}
		}
		if dryRun { return }

		let stamp = Bench.timestamp()
		let json = try Bench.writeJSON(runs, to: "summary-\(stamp).json")
		let markdown = try Bench.write(report(runs, expectations: expectations, parallel: parallel), to: "summary-\(stamp).md")
		print("wrote \(json.path) and \(markdown.path)")
	}

	static func summarize(
		meeting: String,
		sections: [TranscriptSection],
		size: Int,
		language: DictationLanguage,
		reduceCharacters: Int,
		parallel: Int,
		averageWords: Int,
		averageMinutes: Double
	) async -> SummaryRun {
		let summarizer = Summarizer(language: language)
		let clock = ContinuousClock()
		var run = SummaryRun(
			meeting: meeting, sectionCharacters: size, sections: sections.count,
			averageSectionWords: averageWords, averageSectionMinutes: averageMinutes,
			mapLatenciesMs: [], condenseMs: 0, reduceMs: 0, totalMs: 0, afterStopMs: 0,
			reducePromptCharacters: 0
		)
		let start = clock.now
		do {
			let mapped = try await map(sections, with: summarizer, parallel: parallel, clock: clock)
			run.mapLatenciesMs = mapped.map(\.1)
			let notes = mapped.flatMap(\.0)

			let condenseStart = clock.now
			let condensed = try await summarizer.condense(notes, maxCharacters: reduceCharacters)
			run.condenseMs = Bench.milliseconds(clock.now - condenseStart)
			run.reducePromptCharacters = SummaryPrompts.render(condensed).count

			let reduceStart = clock.now
			run.summary = try await summarizer.merge(condensed)
			run.reduceMs = Bench.milliseconds(clock.now - reduceStart)
		} catch {
			run.error = await Bench.describe(error)
		}
		run.totalMs = Bench.milliseconds(clock.now - start)
		run.afterStopMs = (run.mapLatenciesMs.last ?? 0) + run.condenseMs + run.reduceMs
		return run
	}

	/// Returns notes and latency per section, in order.
	static func map(
		_ sections: [TranscriptSection],
		with summarizer: Summarizer,
		parallel: Int,
		clock: ContinuousClock
	) async throws -> [([SectionNotes], Double)] {
		try await withThrowingTaskGroup(of: (Int, [SectionNotes], Double).self) { group in
			var results: [(Int, [SectionNotes], Double)] = []
			var next = 0
			func enqueue() {
				guard next < sections.count else { return }
				let section = sections[next]
				next += 1
				group.addTask {
					let start = clock.now
					let notes = try await summarizer.notesSplittingOnOverflow(for: section, of: sections.count)
					return (section.index, notes, Bench.milliseconds(clock.now - start))
				}
			}
			for _ in 0..<parallel { enqueue() }
			while let result = try await group.next() {
				print(String(format: "    section %d: %.1f s", result.0, result.2 / 1000))
				results.append(result)
				enqueue()
			}
			return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
		}
	}

	static func minutesBetween(_ start: String, _ end: String) -> Double {
		func seconds(_ time: String) -> Double {
			time.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
		}
		return (seconds(end) - seconds(start)) / 60
	}

	static func report(_ runs: [SummaryRun], expectations: [String: ExpectedMeeting], parallel: Int) -> String {
		var text = "# Summary run\n\nParallel map requests: \(parallel).\n\n"
		text += "| meeting | section chars | sections | avg words | avg min | map p50 s | map max s | reduce s | total s | after stop s | error |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
		for run in runs {
			text += String(
				format: "| %@ | %d | %d | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %@ |\n",
				run.meeting, run.sectionCharacters, run.sections, run.averageSectionWords, run.averageSectionMinutes,
				Bench.percentile(run.mapLatenciesMs, 50) / 1000, (run.mapLatenciesMs.max() ?? 0) / 1000,
				run.reduceMs / 1000, run.totalMs / 1000, run.afterStopMs / 1000, Bench.markdownCell(run.error ?? "")
			)
		}
		for run in runs {
			text += "\n## \(run.meeting), \(run.sectionCharacters) chars\n\n"
			if let expected = expectations[run.meeting] {
				text += "Expected title: \(expected.title)\n\nExpected decisions:\n"
				text += expected.decisions.map { "- \($0)" }.joined(separator: "\n")
				text += "\n\nExpected action items:\n"
				text += expected.actionItems.map { "- \($0.task) (\($0.owner ?? "no owner"))" }.joined(separator: "\n")
				text += "\n\nReversed: \(expected.reversed.initial) → \(expected.reversed.final)\n"
				text += "Not decided: \(expected.notDecided.joined(separator: "; "))\n\n"
			}
			guard let summary = run.summary else { continue }
			text += "**Got title:** \(summary.title)\n\n**Summary:** \(summary.summary)\n\n**Decisions:**\n"
			text += summary.decisions.map { "- \($0)" }.joined(separator: "\n")
			text += "\n\n**Action items:**\n"
			text += summary.actionItems.map { "- \($0.task) (\($0.owner ?? "no owner"))" }.joined(separator: "\n")
			text += "\n"
		}
		return text
	}
}
