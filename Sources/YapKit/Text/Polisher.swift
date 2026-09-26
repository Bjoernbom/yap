import Foundation
import Synchronization

/// Whether polish can run on this Mac.
public enum PolishAvailability: Sendable, Equatable {
	case available
	/// With a one-line reason and fix, for Settings.
	case unavailable(String)

	public var isAvailable: Bool { self == .available }
}

/// What polish did with one dictation.
public enum PolishOutcome: Sendable, Equatable {
	case polished(String)
	case skipped(Reason)

	public enum Reason: Sendable, Equatable {
		case disabled
		case unavailable
		case unsupportedLanguage(String?)
		case gate(String)
		case timeout
		case failed(String)
		/// The output guard's flags.
		case rejected([String])
	}

	/// What gets inserted: the polish, or the deterministic cleanup. Every
	/// skip ends the same way, so polish can never lose or invent words.
	public func text(fallback cleaned: String) -> String {
		if case .polished(let text) = self { return text }
		return cleaned
	}
}

/// The language model behind polish. The real one is Apple Foundation
/// Models; tests use fakes so gate, timeout and guard run without it.
public protocol PolishModel: Sendable {
	var availability: PolishAvailability { get }
	func supports(language: String) -> Bool
	/// Key-down. Creates a single-use session and starts warming it.
	func prepare(style: WritingStyle, language: String) -> any PolishModelSession
}

public protocol PolishModelSession: Sendable {
	func respond(to text: String, language: String, vocabulary: [String]) async throws -> String
}

/// Opt-in polish: gate → model (with a hard timeout) → output guard.
public struct Polisher: Sendable {
	/// From key-up, not the plan's 1.5 s: the budget is p95 < 1.2 s for
	/// key-up → inserted, and the path without polish already takes up to
	/// 300 ms (LLM spike).
	public static let timeout: Duration = .seconds(1)

	let model: any PolishModel

	public init(model: any PolishModel = FoundationModelsPolishModel()) {
		self.model = model
	}

	public var availability: PolishAvailability { model.availability }

	public func prepare(style: WritingStyle, language: String) -> PreparedPolish {
		PreparedPolish(model: model, session: model.prepare(style: style, language: language))
	}
}

/// A session prepared at key-down, used once at key-up.
public struct PreparedPolish: Sendable {
	let model: any PolishModel
	let session: any PolishModelSession

	/// Never throws and never takes much longer than `timeout`.
	public func polish(_ text: String, vocabulary: [String] = [], timeout: Duration = Polisher.timeout) async -> PolishOutcome {
		if case .skip(let reason) = PolishGate.decide(text) {
			return .skipped(.gate(reason))
		}
		guard let language = LanguageDetection.dominantLanguage(of: text), model.supports(language: language) else {
			return .skipped(.unsupportedLanguage(LanguageDetection.dominantLanguage(of: text)))
		}
		let session = self.session
		let result = await withTimeout(timeout) {
			try await session.respond(to: text, language: language, vocabulary: vocabulary)
		}
		switch result {
		case nil:
			return .skipped(.timeout)
		case .failure(let error)?:
			return .skipped(.failed(String(describing: error)))
		case .success(let raw)?:
			let output = PolishGuard.unwrap(raw)
			let flags = PolishGuard.check(input: text, output: output, language: language, vocabulary: vocabulary)
			return flags.isEmpty ? .polished(output) : .skipped(.rejected(flags))
		}
	}
}

/// Decides before any model call whether polish is worth trying.
enum PolishGate {
	enum Decision: Equatable, Sendable {
		case polish
		case skip(String)
	}

	/// Below this there is nothing a model adds over the deterministic cleanup.
	static let minimumWords = 3
	/// Output is about as long as the input and decoding dominates latency,
	/// so long dictations can't finish inside the timeout anyway.
	/// Provisional until tokens/s is measured (LLM spike).
	static let maximumWords = 150

	static let fillers: Set<String> = Cleanup.fillers.union(["mm", "ah", "like", "liksom", "typ", "alltså", "ba", "you", "know"])

	static func decide(_ text: String) -> Decision {
		let words = PolishGuard.words(text)
		if words.isEmpty { return .skip("empty") }
		if words.allSatisfy(fillers.contains) { return .skip("only fillers") }
		if words.count < minimumWords { return .skip("too short, \(words.count) words") }
		if words.count > maximumWords { return .skip("too long, \(words.count) words") }
		return .polish
	}
}

/// Cheap checks on the model's output. Any flag throws the polish away:
/// these catch answers, drafted emails, translations and preambles.
enum PolishGuard {
	static let preambles = [
		"here is", "here's", "sure", "certainly", "cleaned:", "the cleaned", "transcript:",
		"här är", "självklart", "visst", "absolut,",
	]

	static func check(input: String, output: String, language: String, vocabulary: [String] = []) -> [String] {
		let inputWords = max(wordCount(input), 1)
		let outputWords = wordCount(output)
		let ratio = Double(outputWords) / Double(inputWords)
		var flags: [String] = []
		if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			flags.append("empty")
		}
		// Cleanup only ever removes words; more words than the input means added content.
		if ratio > 1.15 { flags.append("longer") }
		if ratio < 0.45 { flags.append("much-shorter") }
		// Cleanup reuses the speaker's words; an answer or an email brings its own.
		if novelWordRatio(input: input + " " + vocabulary.joined(separator: " "), output: output) > 0.2 {
			flags.append("new-words")
		}
		if input.contains("?"), !output.contains("?") {
			flags.append("question-lost")
		}
		let lowered = output.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if preambles.contains(where: lowered.hasPrefix) {
			flags.append("preamble")
		}
		// Language ID is noisy on very short text; only trust it past a few words.
		let candidates = Array(Set([language, "sv", "en", "nb", "da", "de"]))
		if outputWords >= 6, let detected = LanguageDetection.dominantLanguage(of: output, among: candidates), detected != language {
			flags.append("language:\(detected)")
		}
		return flags
	}

	/// The prompt quotes the transcript, so the model may echo the quotes.
	static func unwrap(_ text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		for (open, close) in [("\"", "\""), ("“", "”"), ("”", "”")]
		where trimmed.count > 1 && trimmed.hasPrefix(open) && trimmed.hasSuffix(close) {
			return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
		}
		return trimmed
	}

	static func words(_ text: String) -> [String] {
		text.lowercased()
			.split(whereSeparator: { !WordBoundary.isWordCharacter($0) })
			.map(String.init)
	}

	static func novelWordRatio(input: String, output: String) -> Double {
		let known = Set(words(input))
		let produced = words(output)
		guard !produced.isEmpty else { return 0 }
		return Double(produced.filter { !known.contains($0) }.count) / Double(produced.count)
	}

	static func wordCount(_ text: String) -> Int {
		text.split(whereSeparator: \.isWhitespace).count
	}
}

/// Runs `operation`, but returns nil after `timeout` without waiting for it.
///
/// A task group would wait for the model call to notice cancellation before
/// returning; this hands control back on time and cancels the call behind it.
func withTimeout<T: Sendable>(
	_ timeout: Duration,
	operation: @escaping @Sendable () async throws -> T
) async -> Result<T, any Error>? {
	let race = Race<Result<T, any Error>?>()
	return await withTaskCancellationHandler {
		await withCheckedContinuation { continuation in
			race.start(continuation)
			let work = Task {
				do {
					race.finish(.success(try await operation()))
				} catch {
					race.finish(.failure(error))
				}
			}
			let timer = Task {
				try? await Task.sleep(for: timeout)
				race.finish(nil)
			}
			race.onFinish {
				work.cancel()
				timer.cancel()
			}
		}
	} onCancel: {
		race.finish(nil)
	}
}

/// Resumes a continuation exactly once, whoever gets there first.
private final class Race<Value: Sendable>: Sendable {
	private struct State {
		var continuation: CheckedContinuation<Value, Never>?
		var result: Value?
		var finished = false
		var cleanup: (@Sendable () -> Void)?
	}

	private let state = Mutex(State())

	func start(_ continuation: CheckedContinuation<Value, Never>) {
		// Cancelled before we got here: resume right away.
		let early: Value? = state.withLock { state in
			if state.finished { return state.result }
			state.continuation = continuation
			return nil
		}
		if let early {
			continuation.resume(returning: early)
		}
	}

	func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
		let runNow = state.withLock { state in
			if state.finished { return true }
			state.cleanup = cleanup
			return false
		}
		if runNow { cleanup() }
	}

	func finish(_ value: Value) {
		let (continuation, cleanup) = state.withLock { state -> (CheckedContinuation<Value, Never>?, (@Sendable () -> Void)?) in
			guard !state.finished else { return (nil, nil) }
			state.finished = true
			state.result = value
			defer {
				state.continuation = nil
				state.cleanup = nil
			}
			return (state.continuation, state.cleanup)
		}
		continuation?.resume(returning: value)
		cleanup?()
	}
}
