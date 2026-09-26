/// Removes the other side of the call leaking into the microphone.
///
/// On speakers (no headphones) the mic hears the call too, so "you" repeats
/// what "them" said at the same moment. Echo cancellation would fix it at
/// the source, but voice processing ducks all other audio (see the M0
/// spike), so this works on the transcripts instead.
///
/// With word timings (the normal case): a "you" word is echo when "them"
/// said the same word within `wordSlack` of it. Up to `maxMisheard` words
/// between echo words count as echo too (the echo transcribed a little
/// differently), and only runs of at least `minimumWords` go. So the user's
/// own words right before or after the echo, even in the same chunk (the VAD
/// needs ~0.8 s of silence to cut), stay.
///
/// Without timings the same idea runs on whole segments: a "you" segment is
/// dropped when almost all its words appear in order in "them" around the
/// same time, and runs of `minimumRun` matching words are cut.
///
/// Deliberately conservative, because dropping real words is worse than
/// keeping an echo:
/// - Short matches stay: a "yes" or "okay" as the other side says it is as
///   likely the user's as an echo.
/// - Saying three or more of the same words at the same moment as the other
///   side gets them cut too; that is the price.
/// - Words must match exactly after lowercasing and dropping punctuation; an
///   echo transcribed very differently from the original is kept.
/// - Echo the mic hears but the tap doesn't (another device in the room) is
///   not detected at all.
enum EchoFilter {
	/// How far apart in time the echo and the original may be, in seconds.
	static let tolerance = 2.0
	/// Share of the segment's words that must appear in order in "them".
	static let threshold = 0.7
	static let minimumWords = 3
	static let minimumRun = 4
	/// How far apart an echo word and the original may be: word timings are
	/// off by a few hundred milliseconds, and the echo arrives tens late.
	static let wordSlack = 0.6
	/// Misheard words tolerated inside a run of echo.
	static let maxMisheard = 2
	/// Longer than any chunk (10 s ceiling plus overlap), for the search.
	static let maxSegmentLength = 20.0

	static func removeEcho(from segments: [NoteSegment]) -> [NoteSegment] {
		let them = segments.filter { $0.speaker != .you }.sorted { $0.start < $1.start }
		guard !them.isEmpty else { return segments }
		return segments.compactMap { segment in
			segment.speaker == .you ? withoutEcho(segment, of: them) : segment
		}
	}

	/// The segment with echo removed, or nil when it was all echo.
	static func withoutEcho(_ segment: NoteSegment, of them: [NoteSegment]) -> NoteSegment? {
		let talking = themSegments(of: them, in: (segment.start - tolerance)...(segment.end + tolerance))
		guard !talking.isEmpty else { return segment }
		let themWords = talking.flatMap(\.words)
		guard !segment.words.isEmpty, !themWords.isEmpty else { return withoutEchoByText(segment, of: them) }
		let words = segment.words

		// Where each "them" word was said, by its normalized text.
		var heard: [String: [Double]] = [:]
		for word in themWords {
			heard[normalized(word.text), default: []].append(middle(of: word))
		}
		// An echo word is the same word as "them" said at the same moment.
		var echo = words.map { word in
			heard[normalized(word.text)]?.contains { abs($0 - middle(of: word)) <= wordSlack } ?? false
		}
		// A few misheard words between echo words are echo too.
		var index = 0
		while index < words.count {
			guard !echo[index], index > 0, echo[index - 1] else {
				index += 1
				continue
			}
			var next = index
			while next < words.count, !echo[next] { next += 1 }
			if next < words.count, next - index <= maxMisheard {
				for gap in index..<next { echo[gap] = true }
			}
			index = next
		}
		// Only runs long enough to be sure: a lone "yes" as "them" says "yes"
		// may well be the user.
		var drop = Set<Int>()
		var run: [Int] = []
		for position in 0...words.count {
			if position < words.count, echo[position] {
				run.append(position)
			} else {
				if run.count >= minimumWords { drop.formUnion(run) }
				run = []
			}
		}
		guard !drop.isEmpty else { return segment }
		let kept = words.indices.filter { !drop.contains($0) }.map { words[$0] }
		guard let first = kept.first, let last = kept.last,
		      kept.contains(where: { !normalized($0.text).isEmpty })
		else { return nil }
		var trimmed = segment
		trimmed.words = kept
		trimmed.text = TranscriptJoiner.join(kept.map(\.text))
		trimmed.start = first.start
		trimmed.end = last.end
		return trimmed
	}

	private static func middle(of word: TimedWord) -> Double {
		(word.start + word.end) / 2
	}

	/// The same rules on text alone, for segments without word timings: the
	/// whole segment against "them" around it in time.
	static func withoutEchoByText(_ segment: NoteSegment, of them: [NoteSegment]) -> NoteSegment? {
		let tokens = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
		// Tokens that are words, with their place in `tokens`.
		let words = tokens.indices.compactMap { index -> (index: Int, word: String)? in
			let word = normalized(tokens[index])
			return word.isEmpty ? nil : (index, word)
		}
		guard words.count >= minimumWords else { return segment }
		let window = (segment.start - tolerance)...(segment.end + tolerance)
		let around = themSegments(of: them, in: window).flatMap { normalizedWords($0.text) }
		guard !around.isEmpty else { return segment }
		let matched = matches(words.map(\.word), around)
		if Double(matched.count) / Double(words.count) >= threshold { return nil }
		let drop = Set(runs(of: matched, count: words.count).flatMap { $0 }.map { words[$0].index })
		guard !drop.isEmpty else { return segment }
		let kept = tokens.indices.filter { !drop.contains($0) }.map { tokens[$0] }
		guard kept.contains(where: { !normalized($0).isEmpty }) else { return nil }
		var trimmed = segment
		trimmed.text = kept.joined(separator: " ")
		return trimmed
	}

	/// Runs of at least `minimumRun` consecutive positions in `0..<count`
	/// that are all in `matched`.
	private static func runs(of matched: Set<Int>, count: Int) -> [[Int]] {
		var runs: [[Int]] = []
		var run: [Int] = []
		for position in 0...count {
			if position < count, matched.contains(position) {
				run.append(position)
			} else {
				if run.count >= minimumRun { runs.append(run) }
				run = []
			}
		}
		return runs
	}

	/// The "them" segments overlapping `window`, in order.
	private static func themSegments(of them: [NoteSegment], in window: ClosedRange<Double>) -> [NoteSegment] {
		// `them` is sorted by start and its segments are chunk-sized, so only
		// a few around the window can overlap it; this runs on every live
		// update of a 3-hour transcript.
		var index = firstIndex(in: them, startingAtOrAfter: window.lowerBound - maxSegmentLength)
		var found: [NoteSegment] = []
		while index < them.count, them[index].start <= window.upperBound {
			if them[index].end >= window.lowerBound { found.append(them[index]) }
			index += 1
		}
		return found
	}

	private static func firstIndex(in sorted: [NoteSegment], startingAtOrAfter time: Double) -> Int {
		var low = 0
		var high = sorted.count
		while low < high {
			let middle = (low + high) / 2
			if sorted[middle].start < time { low = middle + 1 } else { high = middle }
		}
		return low
	}

	static func normalizedWords(_ text: String) -> [String] {
		text.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }.filter { !$0.isEmpty }
	}

	private static func normalized(_ token: String) -> String {
		String(token.lowercased().filter { $0.isLetter || $0.isNumber })
	}

	/// Positions in `a` that a longest common subsequence with `b` uses.
	/// Full table plus backtracking; segments are short (a chunk is at most
	/// ~10 s), so this stays cheap.
	static func matches(_ a: [String], _ b: [String]) -> Set<Int> {
		guard !a.isEmpty, !b.isEmpty else { return [] }
		var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
		for i in 1...a.count {
			for j in 1...b.count {
				table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
			}
		}
		var positions = Set<Int>()
		var (i, j) = (a.count, b.count)
		while i > 0, j > 0 {
			if a[i - 1] == b[j - 1] {
				positions.insert(i - 1)
				i -= 1
				j -= 1
			} else if table[i - 1][j] >= table[i][j - 1] {
				i -= 1
			} else {
				j -= 1
			}
		}
		return positions
	}
}
