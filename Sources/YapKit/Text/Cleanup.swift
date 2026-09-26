import Foundation

/// Deterministic, instant cleanup of a raw transcript. Always on.
///
/// It only removes: hesitations, stuttered repeats and stray spacing. It
/// never rewrites, reorders or translates, so it can't change what was
/// said. Anything ambiguous is left alone; polish (when on) handles the rest.
public enum Cleanup {
	public static func apply(_ text: String, style: WritingStyle = .natural) -> String {
		var tokens = text.split(whereSeparator: \.isWhitespace).map(Token.init)
		tokens = removeFillers(tokens, style: style)
		tokens = collapseRepeats(tokens)
		return fixSpacing(tokens.map(\.text).joined(separator: " "))
	}

	/// Pure hesitations in Swedish and English. Deliberately short: words
	/// that are fillers only sometimes ("like", "liksom", "typ", "alltså")
	/// stay, and so do "mm" (Swedish for yes) and "er" (Swedish for you).
	static let fillers: Set<String> = [
		"um", "umm", "uh", "uhh", "uhm", "erm",
		"eh", "ehm", "äh", "öh", "öhm", "hmm", "hm",
	]

	/// Words people do say twice on purpose: grammar ("had had", "that
	/// that", "det det", "på på fredag"), emphasis ("very very", "nej nej")
	/// and numbers read out digit by digit ("två två fyra").
	static let intentionalRepeats: Set<String> = [
		// English
		"had", "that", "is", "do", "bye", "very", "really", "no", "yes", "so",
		"ha", "now", "well", "okay", "ok", "please", "go", "in", "on", "to",
		// Swedish
		"det", "den", "på", "i", "till", "om", "med", "av", "för",
		"ja", "nej", "hej", "tack", "bra", "mycket", "jätte", "okej", "kom", "nu",
		// Numbers
		"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
		"noll", "ett", "en", "två", "tre", "fyra", "fem", "sex", "sju", "åtta", "nio", "tio",
	]

	struct Token {
		var lead: Substring
		var core: Substring
		var trail: Substring

		init(_ raw: Substring) {
			let start = raw.firstIndex(where: WordBoundary.isWordCharacter) ?? raw.endIndex
			let end = raw.lastIndex(where: WordBoundary.isWordCharacter).map { raw.index(after: $0) } ?? start
			lead = raw[raw.startIndex..<start]
			core = raw[start..<end]
			trail = raw[end..<raw.endIndex]
		}

		var text: String { String(lead) + String(core) + String(trail) }

		var endsSentence: Bool {
			trail.contains(where: { ".!?".contains($0) })
		}

		/// A plain lowercase word ("so", "what's"), safe to capitalize.
		/// Identifiers (fetchUser, user_id, v2) are not.
		var isPlainLowercaseWord: Bool {
			core.first?.isLowercase == true && core.allSatisfy { ($0.isLetter && $0.isLowercase) || "'’-".contains($0) }
		}
	}

	static func removeFillers(_ tokens: [Token], style: WritingStyle) -> [Token] {
		var kept: [Token] = []
		var capitalizeNext = false
		for token in tokens {
			if isFiller(token) {
				let atSentenceStart = kept.last.map(\.endsSentence) ?? true
				if atSentenceStart, token.core.first?.isUppercase == true {
					capitalizeNext = true
				}
				// "we should, uh." keeps its period: it ends the sentence.
				let terminator = token.trail.filter { $0 != "," }
				if terminator == "." || terminator == "!", let last = kept.indices.last, !kept[last].endsSentence {
					kept[last].trail = Substring(kept[last].trail.filter { $0 != "," } + terminator)
				} else if token.trail.hasPrefix(","), let last = kept.indices.last, kept[last].trail == ",",
				          last > 0, !kept[last - 1].endsSentence {
					// The recognizer brackets a hesitation in commas: "vi, eh, borde"
					// reads "vi borde". A comma after a sentence's first word
					// ("Hej, eh, …", "So, um, …") is real and stays.
					kept[last].trail = ""
				}
				continue
			}
			var token = token
			// "Um, so we…" → "So we…", but never touch identifiers or code.
			if capitalizeNext, style != .dev, token.lead.isEmpty, token.isPlainLowercaseWord {
				token.core = Substring(token.core.prefix(1).uppercased() + token.core.dropFirst())
			}
			capitalizeNext = false
			kept.append(token)
		}
		return kept
	}

	/// Only a bare filler, maybe followed by a comma, period or dots. "Eh?"
	/// is a question tag and stays; "uh-huh" means yes and stays.
	static func isFiller(_ token: Token) -> Bool {
		token.lead.isEmpty
			&& fillers.contains(token.core.lowercased())
			&& token.trail.allSatisfy { ",.…!".contains($0) }
	}

	/// "the the report" → "the report", "vi vi ses" → "vi ses".
	static func collapseRepeats(_ tokens: [Token]) -> [Token] {
		var kept: [Token] = []
		for token in tokens {
			if let last = kept.last,
			   last.trail.isEmpty || last.trail == ",",
			   token.lead.isEmpty,
			   !token.core.isEmpty,
			   token.core.allSatisfy(\.isLetter),
			   last.core.lowercased() == token.core.lowercased(),
			   !intentionalRepeats.contains(token.core.lowercased()) {
				kept[kept.count - 1].trail = token.trail
				continue
			}
			kept.append(token)
		}
		return kept
	}

	static let spacingRules = [
		// "word , next" or "word ." → "word, next", "word."
		TextRule(#" +([,.;:!?])(?=\s|$)"#, "$1"),
		TextRule(#",{2,}"#, ","),
		TextRule(#",+(?=[.!?])"#, ""),
		// Parakeet sometimes ends a window with "grannar..". Ellipses, "cd .."
		// and "a..b" are left alone.
		TextRule(#"(?<=[\p{L}\p{N}])\.\.(?![.\p{L}\p{N}/])"#, "."),
		TextRule(#"^[\s,;]+"#, ""),
		TextRule(#"[\s,]+$"#, ""),
	]

	static func fixSpacing(_ text: String) -> String {
		spacingRules.reduce(text) { $1.apply($0) }
	}
}

/// Last touches that depend on where the text goes. Runs after polish, so
/// the model can't undo them.
public enum StyleFinisher {
	/// A chat line this short reads as a message, not a sentence.
	static let casualMaximumWords = 12

	public static func finish(_ text: String, style: WritingStyle) -> String {
		switch style {
		case .natural, .proper:
			return text
		case .dev:
			return isSingleSentence(text) ? droppingTrailingPeriod(text) : text
		case .casual:
			let words = text.split(whereSeparator: \.isWhitespace).count
			return isSingleSentence(text) && words <= casualMaximumWords ? droppingTrailingPeriod(text) : text
		}
	}

	static let sentenceBreak = TextRule(#"[.!?]+["”')\]]*\s+\S"#, "")

	static func isSingleSentence(_ text: String) -> Bool {
		!text.contains("\n") && !sentenceBreak.matches(text)
	}

	/// Only a lone period after a word: "Ship it." → "Ship it". "Wait...",
	/// "cd .." and "ls ." keep theirs; so do "?" and "!".
	static func droppingTrailingPeriod(_ text: String) -> String {
		guard text.hasSuffix("."), text.count >= 2 else { return text }
		let before = text[text.index(text.endIndex, offsetBy: -2)]
		guard WordBoundary.isWordCharacter(before) || ")\"”'".contains(before) else { return text }
		return String(text.dropLast())
	}
}
