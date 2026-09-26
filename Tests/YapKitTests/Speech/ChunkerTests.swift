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
		#expect(feed([Float](repeating: silence, count: 38), into: &chunker).isEmpty)
	}

	@Test func cutsEveryPause() {
		var chunker = Chunker(policy: .dictation)
		let sentence: [Float] = [speech, speech, silence, silence, silence]
		let chunks = feed(sentence + sentence + sentence, into: &chunker)
		#expect(chunks.map(\.reason) == [.pause, .pause, .pause])
		#expect(chunks.map { hops(in: $0) } == [5, 5, 5])
		#expect(chunker.pending.isEmpty)
	}

	@Test func ceilingCutsAtTheQuietestSpotBeforeTheOverlap() throws {
		var chunker = Chunker(policy: .dictation)
		// 39 hops reach the 10 s ceiling; the search window is the 3 s
		// before the last second.
		var audio = [Float](repeating: 0.5, count: 39 * hop)
		// A 40 ms word gap inside the window…
		audio.replaceSubrange(120_000..<120_640, with: repeatElement(0, count: 640))
		// …and an equally quiet one outside it, which must not win.
		audio.replaceSubrange(60_000..<60_640, with: repeatElement(0, count: 640))
		let chunks = (0..<39).compactMap { index in
			chunker.push(Array(audio[(index * hop)..<((index + 1) * hop)]), probability: speech)
		}
		let chunk = try #require(chunks.first)
		#expect(chunks.count == 1)
		#expect(chunk.reason == .ceiling)
		let cut = chunk.keep.upperBound * AudioChunk.sampleRate
		#expect(cut >= 120_000 && cut <= 120_640)
		// The chunk runs a second past the cut, and the next one starts a
		// second before it and keeps only what follows the cut.
		#expect(abs(chunk.duration - (chunk.keep.upperBound + 1)) < 0.001)
		#expect(chunk.duration <= ChunkPolicy.dictation.maxChunk)
		#expect(chunker.keepFrom == 16_000)
		#expect(chunker.pending.count == 39 * hop - (Int(cut) - 16_000))
	}

	@Test func cutsInsideSpeechCoverEverySampleExactlyOnce() throws {
		var chunker = Chunker(policy: .dictation)
		var chunks = feed([Float](repeating: speech, count: 400), into: &chunker)
		let result = chunker.finish(remainder: [Float](repeating: 1, count: 100), probability: speech)
		let tail = try #require(result)
		chunks.append(tail)
		#expect(chunks.count > 2)
		// In stream time, each chunk's own part starts where the previous ended.
		var covered = 0.0
		for chunk in chunks {
			#expect(chunk.duration <= ChunkPolicy.dictation.maxChunk)
			#expect(abs(chunk.start + chunk.keep.lowerBound - covered) < 0.0001)
			covered = chunk.start + min(chunk.keep.upperBound, chunk.duration)
		}
		#expect(abs(covered - Double(400 * hop + 100) / AudioChunk.sampleRate) < 0.0001)
		// The samples themselves line up with the stream: hop `i` holds `i`.
		for chunk in chunks.dropLast() {
			let first = Int((chunk.start * AudioChunk.sampleRate).rounded())
			#expect(chunk.samples.first == Float(first / hop))
		}
	}

	@Test func longChunkCutsAtAShortDipWithOverlap() throws {
		var chunker = Chunker(policy: .dictation)
		var probabilities = [Float](repeating: speech, count: 30)
		// A dip at 2.3 s is too early; the one ending at 5.4 s cuts once a
		// second of audio has followed it.
		probabilities[8] = 0.3
		probabilities[20] = 0.3
		var chunks: [SpeechChunk] = []
		var cutAt: Int?
		for (index, probability) in probabilities.enumerated() {
			if let chunk = chunker.push([Float](repeating: 1, count: hop), probability: probability) {
				chunks.append(chunk)
				cutAt = index
			}
		}
		let chunk = try #require(chunks.first)
		#expect(chunks.count == 1)
		#expect(chunk.reason == .dip)
		#expect(cutAt == 24)
		let cut = chunk.keep.upperBound * AudioChunk.sampleRate
		#expect(cut >= Double(20 * hop) && cut < Double(21 * hop))
		#expect(chunker.keepFrom == 16_000)
	}

	@Test func dipsNeverCutSilence() {
		var chunker = Chunker(policy: .dictation)
		#expect(feed([Float](repeating: 0.3, count: 38), into: &chunker).isEmpty)
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

	@Test func tailAfterACutInsideSpeechKeepsOnlyWhatFollowsTheCut() throws {
		var chunker = Chunker(policy: .dictation)
		let chunks = feed([Float](repeating: speech, count: 39), into: &chunker)
		let cut = try #require(chunks.first)
		#expect(cut.reason == .ceiling)
		let result = chunker.finish(remainder: [Float](repeating: 1, count: 1000), probability: silence)
		let tail = try #require(result)
		#expect(tail.reason == .tail)
		#expect(tail.keep.lowerBound == 1)
		#expect(abs(tail.start + tail.keep.lowerBound - cut.start - cut.keep.upperBound) < 0.0001)
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
