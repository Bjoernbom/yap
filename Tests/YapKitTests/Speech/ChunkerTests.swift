import Testing
@testable import YapKit

private let hop = ChunkPolicy.dictation.hopSamples
private let speech: Float = 0.95
private let silence: Float = 0.05

/// Pushes one hop per probability. Hop `i` is filled with `Float(i)` so a
/// chunk's content shows exactly which hops it holds.
private func feed(_ probabilities: [Float], into chunker: inout Chunker, from first: Int = 0) -> [SpeechChunk] {
	probabilities.enumerated().compactMap { offset, probability in
		chunker.push([Float](repeating: Float(first + offset), count: hop), probability: probability)
	}
}

private func hops(in chunk: SpeechChunk) -> Int {
	Int((chunk.duration * AudioChunk.sampleRate).rounded()) / hop
}

@Suite("Chunk cuts")
struct ChunkerTests {
	@Test func cutsAfterHalfASecondOfSilence() throws {
		var chunker = Chunker(policy: .dictation)
		// The silence clock starts at the end of the first silent hop, so the
		// third silent hop (0.512 s later) is the cut.
		let chunks = feed([speech, speech, speech, silence, silence, silence, speech], into: &chunker)
		#expect(chunks.count == 1)
		let chunk = try #require(chunks.first)
		#expect(chunk.reason == .pause)
		#expect(hops(in: chunk) == 6)
		#expect(chunk.samples.last == 5)
		#expect(chunker.pending.count == hop)
	}

	@Test func shortPauseDoesNotCut() {
		var chunker = Chunker(policy: .dictation)
		#expect(feed([speech, silence, silence, speech, silence, silence, speech], into: &chunker).isEmpty)
	}

	@Test func uncertainHopsNeitherStartNorResetTheSilenceClock() {
		var chunker = Chunker(policy: .dictation)
		// 0.75 sits between the silence (0.70) and speech (0.85) thresholds.
		#expect(feed([speech, 0.75, 0.75, 0.75, 0.75], into: &chunker).isEmpty)
		var paused = Chunker(policy: .dictation)
		let chunks = feed([speech, silence, 0.75, silence], into: &paused)
		#expect(chunks.map(\.reason) == [.pause])
	}

	@Test func silenceWithoutSpeechNeverCutsAtAPause() {
		var chunker = Chunker(policy: .dictation)
		#expect(feed([Float](repeating: silence, count: 40), into: &chunker).isEmpty)
	}

	@Test func cutsEveryPause() {
		var chunker = Chunker(policy: .dictation)
		let sentence: [Float] = [speech, speech, silence, silence, silence]
		let chunks = feed(sentence + sentence + sentence, into: &chunker)
		#expect(chunks.map(\.reason) == [.pause, .pause, .pause])
		#expect(chunks.map { hops(in: $0) } == [5, 5, 5])
		#expect(chunker.pending.isEmpty)
	}

	@Test func ceilingCutsAtTheQuietestHopInTheLastFourSeconds() throws {
		var chunker = Chunker(policy: .dictation)
		var probabilities = [Float](repeating: speech, count: 60)
		probabilities[50] = 0.3
		probabilities[20] = 0.0 // quieter, but outside the 4 s window
		let chunks = feed(probabilities, into: &chunker)
		let chunk = try #require(chunks.first)
		#expect(chunk.reason == .ceiling)
		#expect(hops(in: chunk) == 51)
		#expect(chunk.samples.last == 50)
		// The hops after the cut stay pending for the next chunk.
		#expect(chunker.pending.first == 51)
	}

	@Test func chunksNeverExceedTheCeiling() {
		var chunker = Chunker(policy: .dictation)
		let chunks = feed([Float](repeating: speech, count: 400), into: &chunker)
		#expect(!chunks.isEmpty)
		for chunk in chunks {
			#expect(chunk.duration <= ChunkPolicy.dictation.maxChunk)
			#expect(chunk.reason == .ceiling)
		}
		// Nothing is lost or duplicated across forced cuts.
		let total = chunks.reduce(0) { $0 + $1.samples.count } + chunker.pending.count
		#expect(total == 400 * hop)
	}

	@Test func shortChunksArePaddedToOneSecond() throws {
		var policy = ChunkPolicy.dictation
		policy.minSilence = 0.2
		var chunker = Chunker(policy: policy)
		let chunks = feed([speech, silence, silence], into: &chunker)
		let chunk = try #require(chunks.first)
		#expect(chunk.samples.count == 16_000)
		#expect(abs(chunk.duration - 0.768) < 0.001)
		#expect(chunk.samples[(3 * hop)...].allSatisfy { $0 == 0 })
	}
}

@Suite("Tail at key-up")
struct TailTests {
	@Test func emptyTailIsSkipped() {
		var chunker = Chunker(policy: .dictation)
		_ = feed([speech, silence, silence, silence], into: &chunker)
		#expect(chunker.finish(remainder: [], probability: nil) == nil)
	}

	@Test func shortSilentTailIsSkipped() {
		var chunker = Chunker(policy: .dictation)
		_ = feed([speech, silence, silence, silence], into: &chunker)
		#expect(chunker.finish(remainder: [Float](repeating: 0, count: 3000), probability: silence) == nil)
	}

	@Test func shortTailWithSpeechIsPadded() throws {
		var chunker = Chunker(policy: .dictation)
		let result = chunker.finish(remainder: [Float](repeating: 1, count: 3000), probability: speech)
		let tail = try #require(result)
		#expect(tail.reason == .tail)
		#expect(tail.samples.count == 16_000)
		#expect(abs(tail.duration - 3000.0 / 16_000) < 0.0001)
	}

	@Test func shortTailStillInsideSpeechIsKept() throws {
		var chunker = Chunker(policy: .dictation)
		// A forced cut mid-word leaves VAD triggered; the tail continues that word.
		// The last hop is the quietest (but not silent), so the cut takes everything.
		let chunks = feed([Float](repeating: speech, count: 53) + [0.75], into: &chunker)
		#expect(chunks.map(\.reason) == [.ceiling])
		#expect(chunker.pending.isEmpty)
		let result = chunker.finish(remainder: [Float](repeating: 1, count: 1000), probability: silence)
		let tail = try #require(result)
		#expect(tail.samples.count >= 16_000)
	}

	@Test func silentTailOfAtLeastMinTailIsTranscribed() throws {
		var chunker = Chunker(policy: .dictation)
		_ = feed([silence], into: &chunker)
		let result = chunker.finish(remainder: [Float](repeating: 0, count: 1000), probability: silence)
		let tail = try #require(result)
		#expect(tail.duration >= 0.3)
		#expect(tail.samples.count == 16_000)
	}

	@Test func longTailIsNotPadded() throws {
		var chunker = Chunker(policy: .dictation)
		_ = feed([speech, speech, speech, speech, speech], into: &chunker)
		let result = chunker.finish(remainder: [Float](repeating: 1, count: 100), probability: speech)
		let tail = try #require(result)
		#expect(tail.samples.count == 5 * hop + 100)
	}

	@Test func finishResetsForTheNextDictation() {
		var chunker = Chunker(policy: .dictation)
		_ = feed([speech, speech], into: &chunker)
		_ = chunker.finish(remainder: [], probability: nil)
		#expect(chunker.pending.isEmpty)
		#expect(chunker.finish(remainder: [Float](repeating: 0, count: 100), probability: silence) == nil)
	}
}
