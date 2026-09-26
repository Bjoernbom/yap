import Foundation

/// Decides before any model call whether polish is worth trying. Runs without the model.
enum PolishGate {
	enum Decision: Equatable, Sendable, CustomStringConvertible {
		case polish
		case skip(String)

		var description: String {
			switch self {
			case .polish: "polish"
			case .skip(let reason): "skip (\(reason))"
			}
		}
	}

	/// Below this there is nothing a model adds over the deterministic cleanup.
	static let minimumWords = 3
	/// Output is about as long as the input and decoding dominates latency, so long
	/// dictations can't finish inside the timeout anyway. It also keeps instructions, input
	/// and output well inside the 4096-token context. Provisional until tokens/s is measured.
	static let maximumWords = 150

	static let fillers: Set<String> = [
		"um", "uh", "eh", "öh", "hmm", "mm", "ah", "like", "liksom", "typ", "alltså", "ba", "you", "know",
	]

	static func decide(_ text: String) -> Decision {
		let words = PolishGuard.words(text)
		if words.isEmpty {
			return .skip("empty")
		}
		if words.allSatisfy({ fillers.contains($0) }) {
			return .skip("only fillers")
		}
		if words.count < minimumWords {
			return .skip("too short, \(words.count) words")
		}
		if words.count > maximumWords {
			return .skip("too long, \(words.count) words > \(maximumWords)")
		}
		return .polish
	}
}
