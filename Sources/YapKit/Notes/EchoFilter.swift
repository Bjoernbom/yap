/// Removes the other side of the call leaking into the microphone.
///
/// On speakers (no headphones) the mic hears the call too, so "you" repeats
/// what "them" said at the same moment. Echo cancellation would fix it at
/// the source, but voice processing ducks all other audio (see the M0
/// spike), so this works on text and word timings instead:
///
/// - Only words spoken while "them" was talking can be echo; the user's own
///   words before or after (a question the answer's echo follows within one
///   pause) always stay.
/// - Of those, when almost all appear in order in the "them" speech, they
///   all go (the ones that don't match are the echo transcribed a little
///   differently). Otherwise only runs of `minimumRun` or more matching
///   words in a row go.
/// - Without word timings the same rules run on whole segments with a time
///   window instead.
///
/// Deliberately conservative, because dropping real words is worse than
/// keeping an echo:
/// - Fewer than `minimumWords` candidate words are kept even if they match:
///   a short "yes" or "okay" is as likely yours as an echo.
/// - Repeating four or more words someone says while they are still saying
///   them gets cut too; that is the price.
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
	/// Slack for "while them was talking": word timings are off by a few
	/// hundred milliseconds, and the echo arrives a few tens late.
	static let overlapSlack = 0.3
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
		guard !segment.words.isEmpty else { return withoutEchoByText(segment, of: them) }
		let words = segment.words
		let window = (segment.start - tolerance)...(segment.end + tolerance)
		let talking = themSegments(of: them, in: window)
		guard !talking.isEmpty else { return segment }
		// Words heard while "them" spoke, with their place in `words`.
		let candidates = words.indices.filter { index in
			let middle = (words[index].start + words[index].end) / 2
			return !normalized(words[index].text).isEmpty
				&& talking.contains { middle >= $0.start - overlapSlack && middle <= $0.end + overlapSlack }
		}
		guard candidates.count >= minimumWords else { return segment }
		let matched = matches(candidates.map { normalized(words[$0].text) }, talking.flatMap { normalizedWords($0.text) })
		let drop: Set<Int>
		if Double(matched.count) / Double(candidates.count) >= threshold {
			drop = Set(candidates)
		} else {
			drop = Set(runs(of: matched, count: candidates.count).flatMap { $0 }.map { candidates[$0] })
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
