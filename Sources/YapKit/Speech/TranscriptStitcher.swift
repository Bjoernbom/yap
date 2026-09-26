/// Puts chunk transcripts back together into one dictation, including chunks
/// that overlap around a cut inside speech.
///
/// Parakeet is unreliable at a chunk edge that runs into speech: it drops or
/// garbles the words there, and a chunk that starts mid-sentence can skip
/// ahead to the next sentence start (2.5 s of speech in one measured case).
/// So around a cut at time `c` both chunks hear an overlap, and:
///
/// - each word comes from the chunk that heard it with context: the left
///   chunk up to `c`, the right chunk from `c` (by the middle of the word);
/// - if the right chunk skipped ahead, the left chunk's words from `c` up to
///   the right chunk's first word fill the gap: an edge guess beats a hole;
/// - one word timed a little differently by the two chunks ("den den") comes
///   out once: same text and overlapping in time means the same word.
struct TranscriptStitcher {
	private var pieces: [String] = []
	/// The previous chunk's words past its cut, in stream time: the gap
	/// filler in case the next chunk skipped them.
	private var carry: [TimedWord] = []
	/// The last word taken, in stream time, to catch a word heard twice.
	private var lastWord: TimedWord?

	/// Adds one chunk. `start` is where the chunk begins in the stream and
	/// `keep` the part whose words are its own, both in seconds. Returns the
	/// text this chunk contributed.
	mutating func add(_ transcript: Transcript, start: Double, keep: Range<Double>) -> String {
		guard !transcript.words.isEmpty else {
			// No timings (or nothing said): nothing to stitch by.
			flushCarry()
			lastWord = nil
			pieces.append(transcript.text)
			return transcript.text
		}
		let words = transcript.words.map {
			TimedWord(text: $0.text, start: $0.start + start, end: $0.end + start)
		}
		let from = start + keep.lowerBound
		let until = start + keep.upperBound
		var own = words.filter { (from..<until).contains(Self.middle(of: $0)) }
		let firstOwn = own.first?.start ?? .infinity
		let fill = carry.filter { Self.middle(of: $0) < firstOwn }
		carry = words.filter { Self.middle(of: $0) >= until }
		if let previous = fill.last ?? lastWord, let first = own.first, Self.isSameWord(previous, first) {
			own.removeFirst()
		}
		let taken = fill + own
		if let last = taken.last { lastWord = last }
		let text = taken.map(\.text).joined(separator: " ")
		pieces.append(text)
		return text
	}

	/// The whole dictation. A chunk cut inside speech is always followed by
	/// the tail, unless the tail was silent; then its overlap words go last.
	mutating func finish() -> String {
		flushCarry()
		return TranscriptJoiner.join(pieces)
	}

	private mutating func flushCarry() {
		guard !carry.isEmpty else { return }
		pieces.append(carry.map(\.text).joined(separator: " "))
		carry = []
	}

	private static func middle(of word: TimedWord) -> Double {
		(word.start + word.end) / 2
	}

	/// The same word from two chunks: equal apart from case and punctuation,
	/// and overlapping in time. A real repeat ("att att") follows the first
	/// one, so it doesn't overlap it.
	private static func isSameWord(_ earlier: TimedWord, _ later: TimedWord) -> Bool {
		later.start < earlier.end && normalized(earlier.text) == normalized(later.text)
	}

	private static func normalized(_ text: String) -> String {
		String(text.lowercased().filter { $0.isLetter || $0.isNumber })
	}
}
