/// Transcribes while the user talks: VAD cuts the live audio at pauses, and
/// each chunk goes to the engine as soon as it's cut, so key-up only waits for
/// the tail (35–55 ms for a 2-minute dictation in the spike).
///
/// A cut that has to fall inside speech (a long chunk with only short pauses)
/// overlaps its neighbours and keeps each word from the side that heard it
/// with context, because Parakeet drops words at a chunk edge that runs into
/// speech. See `ChunkPolicy`.
///
/// Two stages run behind `append`, which only hands audio over and returns:
/// the segmenter scores 256 ms hops and cuts chunks, and the transcriber runs
/// them through the engine one at a time (chunks are 20–100× faster than real
/// time, so there's never a backlog, and one engine never runs two at once).
public actor StreamingTranscriber: StreamingTranscription {
	/// What happened to one chunk, for diagnostics and `yap-bench`.
	public struct ChunkReport: Sendable {
		public var index: Int
		/// Seconds of real audio, before padding.
		public var duration: Double
		public var reason: ChunkCut
		/// Where the chunk begins, in seconds since `begin`.
		public var start: Double
		/// Wall time of the engine call.
		public var latency: Duration
		public var text: String
	}

	private struct Session {
		var input: AsyncStream<[Float]>.Continuation
		var pipeline: Task<String, Error>
	}

	private let engine: any SpeechEngine
	private let vad: any VoiceActivityDetector
	private let policy: ChunkPolicy
	private let onChunk: (@Sendable (ChunkReport) -> Void)?

	private var session: Session?
	/// Set by `finish`; a second `finish` returns the same text.
	private var finished: Task<String, Error>?

	public init(
		engine: any SpeechEngine,
		vad: any VoiceActivityDetector,
		policy: ChunkPolicy = .dictation,
		onChunk: (@Sendable (ChunkReport) -> Void)? = nil
	) {
		self.engine = engine
		self.vad = vad
		self.policy = policy
		self.onChunk = onChunk
	}

	/// Starts a new dictation, dropping any previous one.
	public func begin() async {
		await cancel()
		let (input, continuation) = AsyncStream<[Float]>.makeStream()
		let pipeline = Task { [engine, vad, policy, onChunk] in
			try await Self.run(input: input, engine: engine, vad: vad, policy: policy, onChunk: onChunk)
		}
		session = Session(input: continuation, pipeline: pipeline)
	}

	/// Never waits for VAD or the engine. Audio outside `begin` … `finish`
	/// (a late mic buffer after key-up, or after Esc) is ignored.
	public func append(_ chunk: AudioChunk) async {
		session?.input.yield(chunk.samples)
	}

	/// Flushes the tail, waits for every chunk, and returns the joined text.
	/// Empty when nothing was said; the caller treats that as "didn't catch
	/// that", not as an error.
	public func finish() async throws -> String {
		if let finished { return try await finished.value }
		guard let session else { return "" }
		self.session = nil
		finished = session.pipeline
		session.input.finish()
		return try await session.pipeline.value
	}

	/// Drops everything, including a chunk the engine is working on (its text
	/// is thrown away when it returns).
	public func cancel() async {
		session?.input.finish()
		session?.pipeline.cancel()
		session = nil
		finished?.cancel()
		finished = nil
	}

	private static func run(
		input: AsyncStream<[Float]>,
		engine: any SpeechEngine,
		vad: any VoiceActivityDetector,
		policy: ChunkPolicy,
		onChunk: (@Sendable (ChunkReport) -> Void)?
	) async throws -> String {
		let (chunks, chunkSink) = AsyncStream<SpeechChunk>.makeStream()
		async let text = transcribe(chunks, engine: engine, onChunk: onChunk)
		await segment(input, vad: vad, policy: policy, into: chunkSink)
		let joined = try await text
		try Task.checkCancellation()
		return joined
	}

	/// Stage 1: cut the audio into chunks.
	private static func segment(
		_ input: AsyncStream<[Float]>,
		vad: any VoiceActivityDetector,
		policy: ChunkPolicy,
		into sink: AsyncStream<SpeechChunk>.Continuation
	) async {
		defer { sink.finish() }
		let stream = await vad.makeStream()
		var chunker = Chunker(policy: policy)
		var buffer: [Float] = []
		var offset = 0
		for await samples in input {
			buffer += samples
			while buffer.count - offset >= policy.hopSamples {
				let hop = Array(buffer[offset..<(offset + policy.hopSamples)])
				offset += policy.hopSamples
				let probability = await score(hop, with: stream)
				if let chunk = chunker.push(hop, probability: probability) { sink.yield(chunk) }
			}
			// Drop consumed samples now and then, not on every hop.
			if offset >= 16 * policy.hopSamples {
				buffer.removeFirst(offset)
				offset = 0
			}
		}
		if Task.isCancelled { return }
		let remainder = Array(buffer[offset...])
		var probability: Float?
		if !remainder.isEmpty {
			// Silero needs a full hop; pad the leftover with silence.
			let hop = remainder + [Float](repeating: 0, count: policy.hopSamples - remainder.count)
			probability = await score(hop, with: stream)
		}
		if let tail = chunker.finish(remainder: remainder, probability: probability) { sink.yield(tail) }
	}

	/// A VAD failure must not lose audio: treat the hop as speech, which only
	/// means no cut here (the ceiling still applies).
	private static func score(_ hop: [Float], with stream: any VoiceActivityStream) async -> Float {
		(try? await stream.speechProbability(of: hop)) ?? 1
	}

	/// Stage 2: run chunks through the engine, strictly one at a time.
	private static func transcribe(
		_ chunks: AsyncStream<SpeechChunk>,
		engine: any SpeechEngine,
		onChunk: (@Sendable (ChunkReport) -> Void)?
	) async throws -> String {
		var stitcher = TranscriptStitcher()
		var index = 0
		let clock = ContinuousClock()
		for await chunk in chunks {
			try Task.checkCancellation()
			let start = clock.now
			let transcript = try await engine.transcribe(chunk.samples)
			try Task.checkCancellation()
			let text = stitcher.add(transcript, start: chunk.start, keep: chunk.keep)
			onChunk?(ChunkReport(
				index: index, duration: chunk.duration,
				reason: chunk.reason, start: chunk.start,
				latency: clock.now - start, text: text))
			index += 1
		}
		try Task.checkCancellation()
		return stitcher.finish()
	}
}
