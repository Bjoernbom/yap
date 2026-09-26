import Foundation
import FoundationModels

struct PolishCase: Codable, Sendable {
	var id: String
	var language: DictationLanguage
	var style: PolishStyle
	var kind: String
	var vocabulary: [String]?
	var input: String
	var reference: String
}

struct PolishRun: Codable, Sendable {
	var id: String
	var language: DictationLanguage
	var style: PolishStyle
	var kind: String
	var output: Polisher.Output
	var permissiveGuardrails: Bool
	var prewarmed: Bool
	var cold: Bool
	var latencyMs: Double
	var input: String
	var reference: String
	var result: String?
	var error: String?
	var verdict: PolishGuard.Verdict?
}

/// `llm-bench polish [--outputs plain,guided] [--guardrails permissive|default]
///  [--prewarm on,off] [--speak-ms 800] [--all-styles] [--only sv-05-question]`
enum PolishBench {
	static func run(_ options: Options) async throws {
		guard Bench.requireModel() else { throw BenchError.modelUnavailable }

		let data = try Data(contentsOf: try Bench.fixtureURL("polish-corpus.json"))
		var cases = try JSONDecoder().decode([PolishCase].self, from: data)
		let only = options.list("only", default: [])
		if !only.isEmpty {
			cases = cases.filter { only.contains($0.id) }
		}
		let outputs = try options.list("outputs", default: ["plain", "guided"]).map(parseOutput)
		let permissive = options.string("guardrails", default: "permissive") == "permissive"
		let prewarmModes = options.list("prewarm", default: ["on", "off"]).map { $0 == "on" }
		// Time between key-down (prepare + prewarm) and key-up (polish): a short dictation.
		let speakMs = options.int("speak-ms", default: 800)
		let allStyles = options.flag("all-styles")

		var runs: [PolishRun] = []
		let clock = ContinuousClock()

		// Cold: the very first request in a fresh process, no prewarm.
		if let first = cases.first, let output = outputs.first {
			let polisher = Polisher(output: output, permissiveGuardrails: permissive)
			let prepared = polisher.prepare(style: first.style, language: first.language, prewarm: false)
			let run = await measure(first, prepared: prepared, polisher: polisher, prewarmed: false, cold: true, clock: clock)
			print(line(run))
			runs.append(run)
		}

		for output in outputs {
			let polisher = Polisher(output: output, permissiveGuardrails: permissive)
			for prewarm in prewarmModes {
				for testCase in cases {
					let styles = allStyles ? PolishStyle.allCases : [testCase.style]
					for style in styles {
						var styled = testCase
						styled.style = style
						let prepared = polisher.prepare(style: style, language: testCase.language, prewarm: prewarm)
						try await Task.sleep(for: .milliseconds(speakMs))
						let run = await measure(styled, prepared: prepared, polisher: polisher, prewarmed: prewarm, cold: false, clock: clock)
						print(line(run))
						runs.append(run)
					}
				}
			}
		}

		let stamp = Bench.timestamp()
		let json = try Bench.writeJSON(runs, to: "polish-\(stamp).json")
		let report = report(runs, speakMs: speakMs)
		let markdown = try Bench.write(report, to: "polish-\(stamp).md")
		print("\n" + report)
		print("wrote \(json.path) and \(markdown.path)")
	}

	static func parseOutput(_ value: String) throws -> Polisher.Output {
		guard let output = Polisher.Output(rawValue: value) else { throw BenchError.badArgument(value) }
		return output
	}

	static func measure(
		_ testCase: PolishCase,
		prepared: PreparedPolish,
		polisher: Polisher,
		prewarmed: Bool,
		cold: Bool,
		clock: ContinuousClock
	) async -> PolishRun {
		var run = PolishRun(
			id: testCase.id, language: testCase.language, style: testCase.style, kind: testCase.kind,
			output: polisher.output, permissiveGuardrails: polisher.permissiveGuardrails,
			prewarmed: prewarmed, cold: cold, latencyMs: 0,
			input: testCase.input, reference: testCase.reference
		)
		let start = clock.now
		do {
			let text = try await prepared.polish(testCase.input, vocabulary: testCase.vocabulary ?? [])
			run.latencyMs = Bench.milliseconds(clock.now - start)
			run.result = text
			run.verdict = PolishGuard.check(input: testCase.input, output: text, language: testCase.language, vocabulary: testCase.vocabulary ?? [])
		} catch {
			run.latencyMs = Bench.milliseconds(clock.now - start)
			run.error = await Bench.describe(error)
		}
		return run
	}

	static func line(_ run: PolishRun) -> String {
		let tag = "\(run.output.rawValue)/\(run.prewarmed ? "warm" : "nowarm")\(run.cold ? "/COLD" : "")"
		let body = run.result ?? run.error ?? ""
		let flags = run.verdict?.flags.joined(separator: ",") ?? ""
		return String(format: "%@ %@ %@ %6.0f ms [%@] %@", run.id, run.style.rawValue, tag, run.latencyMs, flags, body)
	}

	static func report(_ runs: [PolishRun], speakMs: Int) -> String {
		var text = "# Polish run\n\n"
		text += "Device: \(ProcessInfo.processInfo.hostName), macOS \(ProcessInfo.processInfo.operatingSystemVersionString). Simulated speaking time between prewarm and request: \(speakMs) ms.\n\n"
		if let cold = runs.first(where: \.cold) {
			text += String(format: "Cold first request (no prewarm, fresh process): **%.0f ms**\n\n", cold.latencyMs)
		}
		text += "| output | prewarm | n | p50 ms | p95 ms | max ms | errors | guard flags |\n|---|---|---|---|---|---|---|---|\n"
		let warm = runs.filter { !$0.cold }
		let groups = Dictionary(grouping: warm) { "\($0.output.rawValue)|\($0.prewarmed)" }
		for key in groups.keys.sorted() {
			guard let group = groups[key], let first = group.first else { continue }
			let latencies = group.filter { $0.error == nil }.map(\.latencyMs)
			let errors = group.filter { $0.error != nil }.count
			let flagged = group.filter { !($0.verdict?.accepted ?? true) }.count
			text += String(
				format: "| %@ | %@ | %d | %.0f | %.0f | %.0f | %d | %d |\n",
				first.output.rawValue, first.prewarmed ? "on" : "off", group.count,
				Bench.percentile(latencies, 50), Bench.percentile(latencies, 95), latencies.max() ?? .nan,
				errors, flagged
			)
		}
		text += "\n## Outputs (score by hand: ok / changed meaning / answered / translated / refused)\n\n"
		text += "| id | style | output | prewarm | ms | result | guard | score |\n|---|---|---|---|---|---|---|---|\n"
		for run in warm {
			let result = run.result.map { Bench.markdownCell($0) } ?? "**\(Bench.markdownCell(run.error ?? ""))**"
			let flags = run.verdict?.flags.joined(separator: ", ") ?? ""
			text += "| \(run.id) | \(run.style.rawValue) | \(run.output.rawValue) | \(run.prewarmed ? "on" : "off") | \(Int(run.latencyMs)) | \(result) | \(flags) | |\n"
		}
		return text
	}
}
