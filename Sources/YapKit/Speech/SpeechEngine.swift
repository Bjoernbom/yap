/// Text for one chunk of audio.
public struct Transcript: Sendable, Equatable {
	public var text: String
	public var confidence: Float
	/// The words of `text` with where they were heard, when the engine knows.
	/// Streaming needs them to stitch chunks that overlap.
	public var words: [TimedWord]

	public init(text: String, confidence: Float, words: [TimedWord] = []) {
		self.text = text
		self.confidence = confidence
		self.words = words
	}
}

/// One word and when it was spoken, in seconds from the start of the chunk.
public struct TimedWord: Sendable, Equatable {
	public var text: String
	public var start: Double
	public var end: Double

	public init(text: String, start: Double, end: Double) {
		self.text = text
		self.start = start
		self.end = end
	}
}

/// Where a model is on its way to being usable.
public enum ModelProgress: Sendable, Equatable {
	case downloading(fraction: Double)
	/// One-time Neural Engine compile; 17–21 s on first run.
	case compiling
	case ready
}

/// A speech-to-text model.
public protocol SpeechEngine: Actor {
	/// Downloads, loads and compiles as needed. Idempotent.
	func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws
	/// Wakes the Neural Engine; call on key-down.
	func warmUp() async
	/// 16 kHz mono, 0.3–14 s.
	func transcribe(_ samples: [Float]) async throws -> Transcript
	func unload() async
}

/// Turns a live stream of audio into text while the user is still talking,
/// so key-up only has to wait for the last chunk.
public protocol StreamingTranscription: Actor {
	func begin() async
	func append(_ chunk: AudioChunk) async
	/// Flushes the tail and returns the joined text.
	func finish() async throws -> String
	/// Drops everything; nothing is returned.
	func cancel() async
}
