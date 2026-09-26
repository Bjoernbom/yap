/// Removes the other side of the call leaking into the microphone.
///
/// On speakers (no headphones) the mic hears the call too, so "you" repeats
/// what "them" said a moment later. Echo cancellation would fix it at the
/// source, but voice processing ducks all other audio (see the M0 spike), so
/// this works on text instead: a "you" segment is dropped when almost all of
/// its words appear, in order, in "them" speech around the same time.
///
/// Deliberately conservative, because dropping real words is worse than
/// keeping an echo:
/// - Only whole segments go. When the user talks over the other side, the
///   segment mixes both and is kept, echo included.
/// - Segments under `minimumWords` are kept even if they match: a short
///   "yes" or "okay" is as likely yours as an echo.
/// - Words must match exactly after lowercasing and dropping punctuation; an
///   echo transcribed very differently from the original is kept.
/// - Loud echo that the mic hears but the tap doesn't (another device in the
///   room) is not detected at all.
enum EchoFilter {
	/// How far apart in time the echo and the original may be, in seconds.
	static let tolerance = 2.0
	/// Share of the segment's words that must appear in order in "them".
	static let threshold = 0.7
	static let minimumWords = 3
	/// Longer than any chunk (10 s ceiling plus overlap), for the search.
	static let maxSegmentLength = 20.0

	static func removeEcho(from segments: [NoteSegment]) -> [NoteSegment] {
		let them = segments.filter { $0.speaker != .you }.sorted { $0.start < $1.start }
		guard !them.isEmpty else { return segments }
		return segments.filter { segment in
			guard segment.speaker == .you else { return true }
			return !isEcho(segment, of: them)
		}
	}

	static func isEcho(_ segment: NoteSegment, of them: [NoteSegment]) -> Bool {
		let words = normalizedWords(segment.text)
		guard words.count >= minimumWords else { return false }
		let window = (segment.start - tolerance)...(segment.end + tolerance)
		// `them` is sorted by start and its segments are chunk-sized, so only
		// a few around the window can overlap it; this runs on every live
		// update of a 3-hour transcript.
		var index = firstIndex(in: them, startingAtOrAfter: window.lowerBound - maxSegmentLength)
		var nearby: [String] = []
		while index < them.count, them[index].start <= window.upperBound {
			if them[index].end >= window.lowerBound { nearby += normalizedWords(them[index].text) }
			index += 1
		}
		guard !nearby.isEmpty else { return false }
		let common = longestCommonSubsequence(words, nearby)
		return Double(common) / Double(words.count) >= threshold
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
		text.lowercased()
			.split(whereSeparator: { $0.isWhitespace })
			.map { String($0.filter { $0.isLetter || $0.isNumber }) }
			.filter { !$0.isEmpty }
	}

	/// Classic dynamic programming, two rows. Segments are short (a chunk is
	/// at most ~10 s), so this stays cheap.
	static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
		guard !a.isEmpty, !b.isEmpty else { return 0 }
		var previous = [Int](repeating: 0, count: b.count + 1)
		var current = previous
		for i in 1...a.count {
			for j in 1...b.count {
				current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
			}
			swap(&previous, &current)
		}
		return previous[b.count]
	}
}
