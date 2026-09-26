import Foundation
import FoundationModels

enum Bench {
	static func fixtureURL(_ name: String) throws -> URL {
		guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
			throw BenchError.missingFixture(name)
		}
		return url
	}

	/// Results go to `spikes/llm/.local/` (gitignored), next to the package.
	static func resultsDirectory() throws -> URL {
		let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".local")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	static func timestamp() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		return formatter.string(from: Date())
	}

	static func write(_ text: String, to name: String) throws -> URL {
		let url = try resultsDirectory().appending(path: name)
		try text.write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	static func writeJSON(_ value: some Encodable, to name: String) throws -> URL {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let data = try encoder.encode(value)
		let url = try resultsDirectory().appending(path: name)
		try data.write(to: url)
		return url
	}

	/// Returns `false` and explains why when the model can't run, so benches stop early.
	static func requireModel() -> Bool {
		let availability = SystemLanguageModel.default.availability
		guard case .unavailable(let reason) = availability else { return true }
		print("model unavailable: \(reason)")
		switch reason {
		case .appleIntelligenceNotEnabled:
			print("Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri, wait for the model download, then rerun.")
		case .modelNotReady:
			print("The model is still downloading or being prepared. Rerun later.")
		case .deviceNotEligible:
			print("This Mac can't run Apple Intelligence.")
		@unknown default:
			break
		}
		return false
	}

	static func milliseconds(_ duration: Duration) -> Double {
		let (seconds, attoseconds) = duration.components
		return Double(seconds) * 1000 + Double(attoseconds) / 1e15
	}

	static func percentile(_ values: [Double], _ p: Double) -> Double {
		guard !values.isEmpty else { return .nan }
		let sorted = values.sorted()
		let rank = p / 100 * Double(sorted.count - 1)
		let low = Int(rank.rounded(.down))
		let high = Int(rank.rounded(.up))
		let fraction = rank - Double(low)
		return sorted[low] + (sorted[high] - sorted[low]) * fraction
	}

	/// Turns model errors into one readable line. Refusals get their explanation fetched,
	/// because that text is the only way to see why the model declined.
	static func describe(_ error: any Error) async -> String {
		guard let error = error as? LanguageModelSession.GenerationError else {
			return "error: \(error)"
		}
		switch error {
		case .refusal(let refusal, _):
			let explanation = (try? await refusal.explanation.content) ?? "?"
			return "refusal: \(explanation)"
		case .guardrailViolation(let context):
			return "guardrailViolation: \(context.debugDescription)"
		case .exceededContextWindowSize(let context):
			return "exceededContextWindowSize: \(context.debugDescription)"
		case .unsupportedLanguageOrLocale(let context):
			return "unsupportedLanguageOrLocale: \(context.debugDescription)"
		case .assetsUnavailable(let context):
			return "assetsUnavailable: \(context.debugDescription)"
		case .decodingFailure(let context):
			return "decodingFailure: \(context.debugDescription)"
		case .rateLimited(let context):
			return "rateLimited: \(context.debugDescription)"
		case .concurrentRequests(let context):
			return "concurrentRequests: \(context.debugDescription)"
		case .unsupportedGuide(let context):
			return "unsupportedGuide: \(context.debugDescription)"
		@unknown default:
			return "error: \(error)"
		}
	}

	static func markdownCell(_ text: String) -> String {
		text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
	}
}

enum BenchError: Error, CustomStringConvertible {
	case missingFixture(String)
	case badArgument(String)

	var description: String {
		switch self {
		case .missingFixture(let name): "missing fixture \(name)"
		case .badArgument(let text): "bad argument: \(text)"
		}
	}
}

/// Tiny `--key value` parser; the spike doesn't need ArgumentParser.
struct Options {
	private var values: [String: String] = [:]
	private var flags: Set<String> = []

	init(_ arguments: [String]) {
		var index = 0
		while index < arguments.count {
			let argument = arguments[index]
			guard argument.hasPrefix("--") else { index += 1; continue }
			let key = String(argument.dropFirst(2))
			if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
				values[key] = arguments[index + 1]
				index += 2
			} else {
				flags.insert(key)
				index += 1
			}
		}
	}

	func string(_ key: String, default value: String) -> String {
		values[key] ?? value
	}

	func int(_ key: String, default value: Int) -> Int {
		values[key].flatMap(Int.init) ?? value
	}

	func list(_ key: String, default value: [String]) -> [String] {
		values[key].map { $0.split(separator: ",").map(String.init) } ?? value
	}

	func flag(_ key: String) -> Bool {
		flags.contains(key)
	}
}
