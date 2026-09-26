/// Something that records audio: the mic for dictation, and later the
/// system-audio tap for notes.
public protocol AudioSource: Sendable {
	/// Does the slow setup ahead of time so `start()` is fast (~50 ms).
	func prepare() async throws
	/// Starts capture. The stream finishes when `stop()` is called.
	func start() async throws -> AsyncStream<AudioChunk>
	func stop() async
}
