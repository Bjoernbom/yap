import Testing
@testable import YapKit

/// Returns "c0", "c1", … in call order. Can hold calls at a gate to model a
/// slow engine, and tracks how many calls overlap.
private actor ChunkEngine: SpeechEngine {
	private(set) var receivedSampleCounts: [Int] = []
	private(set) var started = 0
	private(set) var maxConcurrent = 0
	private var running = 0
	private var gated: Bool
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private let texts: [String]?

	init(gated: Bool = false, texts: [String]? = nil) {
		self.gated = gated
		self.texts = texts
	}

	func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
	func warmUp() async {}
	func unload() async {}

	func transcribe(_ samples: [Float]) async throws -> Transcript {
		let index = started
		started += 1
		running += 1
		maxConcurrent = max(maxConcurrent, running)
		if gated { await withCheckedContinuation { waiters.append($0) } }
		running -= 1
		receivedSampleCounts.append(samples.count)
		let text = texts.map { index < $0.count ? $0[index] : "" } ?? "c\(index)"
		return Transcript(text: text, confidence: 1)
	}

	func open() {
		gated = false
		waiters.forEach { $0.resume() }
		waiters.removeAll()
	}
}

/// Speech probability per hop, by hop index; silence after the script ends.
private struct ScriptedVAD: VoiceActivityDetector {
	let script: [Float]

	func makeStream() async -> any VoiceActivityStream {
		Stream(script: script)
	}

	actor Stream: VoiceActivityStream {
		let script: [Float]
		var index = 0

		init(script: [Float]) {
			self.script = script
		}

		func speechProbability(of hop: [Float]) async throws -> Float {
			defer { index += 1 }
			return index < script.count ? script[index] : 0
		}
	}
}

private let hop = ChunkPolicy.dictation.hopSamples
private let s: Float = 0.95
private let q: Float = 0.05

/// Feeds `hops` hops of audio in mic-sized 1600-sample pieces.
private func feed(_ transcriber: StreamingTranscriber, hops: Int, extra: Int = 0) async {
	var remaining = hops * hop + extra
	while remaining > 0 {
		let count = min(1600, remaining)
		await transcriber.append(AudioChunk(samples: [Float](repeating: 0.1, count: count), hostTime: 0))
		remaining -= count
	}
}

/// Polls until `condition` holds; fails instead of hanging.
private func untilTrue(_ condition: @Sendable () async -> Bool) async throws {
	for _ in 0..<2000 {
		if await condition() { return }
		try await Task.sleep(for: .milliseconds(1))
	}
	Issue.record("condition never became true")
}

@Suite("Streaming transcription")
struct StreamingTranscriberTests {
	@Test func transcribesEachPauseAndTheTail() async throws {
		let engine = ChunkEngine()
		let vad = ScriptedVAD(script: [s, s, q, q, q, s, s, q, q, q, s, s])
		let transcriber = StreamingTranscriber(engine: engine, vad: vad)
		await transcriber.begin()
		await feed(transcriber, hops: 12, extra: 500)
		let text = try await transcriber.finish()
		#expect(text == "c0 c1 c2")
		// The 0.54 s tail is padded to 1 s.
		#expect(await engine.receivedSampleCounts == [5 * hop, 5 * hop, 16_000])
		#expect(await engine.maxConcurrent == 1)
	}

	@Test func appendNeverWaitsForTheEngine() async throws {
		let engine = ChunkEngine(gated: true)
		let vad = ScriptedVAD(script: [s, s, q, q, q, s, s, q, q, q, s])
		let transcriber = StreamingTranscriber(engine: engine, vad: vad)
		await transcriber.begin()
		await feed(transcriber, hops: 6)
		try await untilTrue { await engine.started == 1 }
		// The engine is stuck on chunk 1; more audio still goes straight in.
		await feed(transcriber, hops: 30)
		#expect(await engine.started == 1)
		await engine.open()
		let text = try await transcriber.finish()
		// Two pauses, one more after hop 10, and the 5.6 s silent tail.
		#expect(text == "c0 c1 c2 c3")
		#expect(await engine.maxConcurrent == 1)
	}

	@Test func shortSilentPressNeverReachesTheEngine() async throws {
		let engine = ChunkEngine()
		let transcriber = StreamingTranscriber(engine: engine, vad: ScriptedVAD(script: []))
		await transcriber.begin()
		await feed(transcriber, hops: 0, extra: 3200)
		#expect(try await transcriber.finish() == "")
		#expect(await engine.started == 0)
	}

	@Test func finishWithoutAudioIsEmpty() async throws {
		let engine = ChunkEngine()
		let transcriber = StreamingTranscriber(engine: engine, vad: ScriptedVAD(script: []))
		#expect(try await transcriber.finish() == "")
		await transcriber.begin()
		#expect(try await transcriber.finish() == "")
		#expect(await engine.started == 0)
	}

	@Test func emptyEngineTextsGiveAnEmptyResult() async throws {
		let engine = ChunkEngine(texts: ["", " "])
		let vad = ScriptedVAD(script: [s, s, q, q, q, s])
		let transcriber = StreamingTranscriber(engine: engine, vad: vad)
		await transcriber.begin()
		await feed(transcriber, hops: 6)
		#expect(try await transcriber.finish() == "")
		#expect(await engine.started == 2)
	}

	@Test func finishTwiceReturnsTheSameTextWithoutRetranscribing() async throws {
		let engine = ChunkEngine()
		let transcriber = StreamingTranscriber(engine: engine, vad: ScriptedVAD(script: [s, s, s]))
		await transcriber.begin()
		await feed(transcriber, hops: 3)
		let first = try await transcriber.finish()
		let second = try await transcriber.finish()
		#expect(first == "c0")
		#expect(second == first)
		#expect(await engine.started == 1)
	}

	@Test func cancelDropsInFlightWork() async throws {
		let engine = ChunkEngine(gated: true)
		let vad = ScriptedVAD(script: [s, s, q, q, q, s, s])
		let transcriber = StreamingTranscriber(engine: engine, vad: vad)
		await transcriber.begin()
		await feed(transcriber, hops: 7)
		try await untilTrue { await engine.started == 1 }
		await transcriber.cancel()
		await engine.open()
		#expect(try await transcriber.finish() == "")
		// Audio after Esc is ignored, and the next dictation starts clean.
		await feed(transcriber, hops: 3)
		await transcriber.begin()
		await feed(transcriber, hops: 2, extra: 100)
		#expect(try await transcriber.finish() == "c1")
		#expect(await engine.started == 2)
	}

	@Test func appendBeforeBeginIsIgnored() async throws {
		let engine = ChunkEngine()
		let transcriber = StreamingTranscriber(engine: engine, vad: ScriptedVAD(script: [s, s, s]))
		await feed(transcriber, hops: 3)
		#expect(try await transcriber.finish() == "")
		#expect(await engine.started == 0)
	}

	@Test func engineErrorsSurfaceFromFinish() async throws {
		let transcriber = StreamingTranscriber(engine: BrokenChunkEngine(), vad: ScriptedVAD(script: [s, s, s]))
		await transcriber.begin()
		await feed(transcriber, hops: 3)
		await #expect(throws: SpeechError.modelNotPrepared) { try await transcriber.finish() }
	}
}

private actor BrokenChunkEngine: SpeechEngine {
	func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
	func warmUp() async {}
	func unload() async {}
	func transcribe(_ samples: [Float]) async throws -> Transcript { throw SpeechError.modelNotPrepared }
}
