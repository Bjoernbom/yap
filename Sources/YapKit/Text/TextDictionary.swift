import Foundation

/// One of the user's words.
///
/// With `spoken` empty it's a term: yap spells it exactly like `written`
/// ("kubernetes" → "Kubernetes") and fixes near misses. With `spoken` set
/// it's a replacement: "yap dot app" → "yap.app".
public struct DictionaryEntry: Codable, Sendable, Hashable, Identifiable {
	public var id: UUID
	public var spoken: String
	public var written: String

	public init(id: UUID = UUID(), spoken: String = "", written: String) {
		self.id = id
		self.spoken = spoken
		self.written = written
	}

	public var isTerm: Bool { spoken.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Applies the user's dictionary (plus yap's own entries) to a transcript.
///
/// Parakeet has no vocabulary biasing that doesn't break other words (ASR
/// spike), so the dictionary is post-processing. Every match is whole-word
/// and case-insensitive: "app" never matches inside "appen".
public struct TextDictionary: Sendable {
	/// Shipped with yap. Only rules that can't hit a normal sentence: Parakeet
	/// hears "yap" as "yapp", "i app" or "upp", but "i app" and "upp" are
	/// everyday Swedish, so only "yapp" is safe to rewrite.
	public static let builtIn: [DictionaryEntry] = [
		DictionaryEntry(spoken: "yapp", written: "yap"),
		DictionaryEntry(spoken: "yap dot app", written: "yap.app"),
	]

	public let entries: [DictionaryEntry]
	private let rules: [PhraseRule]
	/// Single-word terms, for near-miss matching.
	private let terms: [String]

	public init(entries: [DictionaryEntry], includeBuiltIn: Bool = true) {
		let usable = entries.filter { !$0.written.trimmingCharacters(in: .whitespaces).isEmpty }
		let all = usable + (includeBuiltIn ? Self.builtIn : [])
		self.entries = all
		// Longest phrase first, so "yap dot app" wins over a rule for "yap".
		rules = all
			.map { entry in (entry.isTerm ? entry.written : entry.spoken).trimmingCharacters(in: .whitespaces) }
			.enumerated()
			.sorted { $0.element.count > $1.element.count }
			.compactMap { index, phrase in Self.rule(phrase: phrase, written: all[index].written.trimmingCharacters(in: .whitespaces)) }
		terms = all
			.filter(\.isTerm)
			.map { $0.written.trimmingCharacters(in: .whitespaces) }
			.filter { $0.allSatisfy(WordBoundary.isWordCharacter) }
	}

	/// Words the polish model should spell exactly like this.
	public var vocabulary: [String] {
		var seen = Set<String>()
		return entries.map(\.written).filter { seen.insert($0).inserted }
	}

	public func apply(_ text: String) -> String {
		fixNearMisses(replacePhrases(text))
	}

	/// One pass over the original text, so one rule's output is never
	/// rewritten by another ("yap.app" must not become "YAP.app").
	private func replacePhrases(_ text: String) -> String {
		var claimed: [(range: Range<String.Index>, written: String)] = []
		for rule in rules {
			for range in rule.matchRanges(in: text)
			where !claimed.contains(where: { $0.range.overlaps(range) }) {
				claimed.append((range, rule.written))
			}
		}
		var result = text
		for (range, written) in claimed.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
			result.replaceSubrange(range, with: written)
		}
		return result
	}

	private struct PhraseRule: Sendable {
		let expression: NSRegularExpression
		let written: String

		func matchRanges(in text: String) -> [Range<String.Index>] {
			expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
				.compactMap { Range($0.range, in: text) }
		}
	}

	private static func rule(phrase: String, written: String) -> PhraseRule? {
		let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
		guard !words.isEmpty else { return nil }
		// Words may be split by any whitespace: "yap  dot app" still matches.
		let pattern = WordBoundary.before + words.joined(separator: #"\s+"#) + WordBoundary.after
		guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
		return PhraseRule(expression: expression, written: written)
	}

	// MARK: - Near misses

	/// Terms shorter than this never match fuzzily: short names sit one
	/// letter away from real words ("Kristin" / "kristen").
	static let fuzzyMinimumLength = 8
	/// Two edits only for long terms ("Kubernetes" / "kubernetis").
	static let twoEditMinimumLength = 11
	/// "Git Hub" → "GitHub" only for terms at least this long, so short
	/// names ("Isak") don't eat two real words ("i sak").
	static let joinMinimumLength = 6

	private func fixNearMisses(_ text: String) -> String {
		guard !terms.isEmpty else { return text }
		let words = WordBoundary.words(in: text)
		var edits: [(Range<String.Index>, String)] = []
		var index = 0
		while index < words.count {
			let word = String(text[words[index]])
			if index + 1 < words.count,
			   text[words[index].upperBound..<words[index + 1].lowerBound] == " ",
			   let term = joinedMatch(word, String(text[words[index + 1]])) {
				edits.append((words[index].lowerBound..<words[index + 1].upperBound, term))
				index += 2
				continue
			}
			if let term = nearMatch(word) {
				edits.append((words[index], term))
			}
			index += 1
		}
		var result = text
		for (range, replacement) in edits.reversed() {
			result.replaceSubrange(range, with: replacement)
		}
		return result
	}

	private func joinedMatch(_ first: String, _ second: String) -> String? {
		guard first.count >= 2, second.count >= 2 else { return nil }
		let joined = (first + second).lowercased()
		return terms.first { $0.count >= Self.joinMinimumLength && $0.lowercased() == joined }
	}

	private func nearMatch(_ word: String) -> String? {
		let lowered = word.lowercased()
		for term in terms {
			let target = term.lowercased()
			// Exact matches were handled by the rules; "Stefans" is Stefan's.
			if lowered == target || lowered.hasPrefix(target) || target.hasPrefix(lowered) { continue }
			guard term.count >= Self.fuzzyMinimumLength,
			      lowered.first == target.first,
			      word.allSatisfy(\.isLetter)
			else { continue }
			let allowed = term.count >= Self.twoEditMinimumLength ? 2 : 1
			guard abs(lowered.count - target.count) <= allowed else { continue }
			if Self.editDistance(lowered, target, limit: allowed) <= allowed {
				return term
			}
		}
		return nil
	}

	/// Optimal string alignment distance (Levenshtein plus adjacent swaps),
	/// stopping early once every path is over `limit`.
	static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
		let a = Array(a), b = Array(b)
		if a.isEmpty { return b.count }
		if b.isEmpty { return a.count }
		var previousPrevious = [Int](repeating: 0, count: b.count + 1)
		var previous = Array(0...b.count)
		var current = [Int](repeating: 0, count: b.count + 1)
		for i in 1...a.count {
			current[0] = i
			var rowMinimum = current[0]
			for j in 1...b.count {
				let cost = a[i - 1] == b[j - 1] ? 0 : 1
				var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
				if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
					value = min(value, previousPrevious[j - 2] + 1)
				}
				current[j] = value
				rowMinimum = min(rowMinimum, value)
			}
			if rowMinimum > limit { return rowMinimum }
			(previousPrevious, previous, current) = (previous, current, previousPrevious)
		}
		return previous[b.count]
	}
}
