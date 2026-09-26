/// Glues per-chunk texts into one dictation.
enum TranscriptJoiner {
	/// Single spaces between chunks, no empty pieces, and Parakeet's
	/// occasional double period ("grannar..") collapsed. Real ellipses
	/// (three or more periods) are left alone.
	static func join(_ pieces: [String]) -> String {
		let words = pieces
			.joined(separator: " ")
			.split(whereSeparator: \.isWhitespace)
		return collapseDoublePeriods(words.joined(separator: " "))
	}

	static func collapseDoublePeriods(_ text: String) -> String {
		var result = ""
		result.reserveCapacity(text.count)
		var run = 0
		func flush() {
			result += String(repeating: ".", count: run == 2 ? 1 : run)
			run = 0
		}
		for character in text {
			if character == "." {
				run += 1
			} else {
				flush()
				result.append(character)
			}
		}
		flush()
		return result
	}
}
