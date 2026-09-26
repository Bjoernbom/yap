import Foundation

/// A regular expression with a fixed replacement template.
///
/// NSRegularExpression rather than Swift `Regex` for lookbehind, which the
/// word-boundary rules need (`\b` treats `_` and digits in ways that break
/// identifiers like `user_id`).
struct TextRule: Sendable {
	let expression: NSRegularExpression?
	let template: String

	init(_ pattern: String, _ template: String, caseInsensitive: Bool = false) {
		// A bad pattern is a programming error that the tests catch; at run
		// time the rule just does nothing rather than crash someone's dictation.
		expression = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
		self.template = template
	}

	func apply(_ text: String) -> String {
		guard let expression else { return text }
		return expression.stringByReplacingMatches(
			in: text,
			range: NSRange(text.startIndex..., in: text),
			withTemplate: template
		)
	}

	func matches(_ text: String) -> Bool {
		guard let expression else { return false }
		return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
	}
}

enum WordBoundary {
	/// Letters, digits and underscore are one word: `user_id` and `v2` never
	/// get split, and "app" never matches inside "appen".
	static let before = #"(?<![\p{L}\p{N}_])"#
	static let after = #"(?![\p{L}\p{N}_])"#

	static func isWordCharacter(_ character: Character) -> Bool {
		character.isLetter || character.isNumber || character == "_"
	}

	/// Ranges of every word in `text`.
	static func words(in text: String) -> [Range<String.Index>] {
		var ranges: [Range<String.Index>] = []
		var start: String.Index?
		var index = text.startIndex
		while index < text.endIndex {
			if isWordCharacter(text[index]) {
				if start == nil { start = index }
			} else if let begun = start {
				ranges.append(begun..<index)
				start = nil
			}
			index = text.index(after: index)
		}
		if let start { ranges.append(start..<text.endIndex) }
		return ranges
	}
}
