import FluidAudio

/// Scores audio for speech. Silero is recurrent, so each dictation gets its
/// own stream; a cancelled dictation still finishing a hop can't disturb the
/// next one.
public protocol VoiceActivityDetector: Sendable {
	func makeStream() async -> any VoiceActivityStream
}

public protocol VoiceActivityStream: Actor {
	/// Speech probability in 0...1 for one hop of 16 kHz mono audio.
	func speechProbability(of hop: [Float]) async throws -> Float
}

/// Silero VAD v6 through FluidAudio (1 MB, runs in well under a millisecond
/// per 256 ms hop).
public struct SileroVAD: VoiceActivityDetector {
	private let manager: VadManager

	/// Downloads the model on first use (~1 MB), then loads it from the
	/// FluidAudio cache.
	public static func load() async throws -> SileroVAD {
		SileroVAD(manager: try await VadManager(config: .default))
	}

	private init(manager: VadManager) {
		self.manager = manager
	}

	public func makeStream() async -> any VoiceActivityStream {
		SileroStream(manager: manager, state: await manager.makeStreamState())
	}
}

private actor SileroStream: VoiceActivityStream {
	let manager: VadManager
	var state: VadStreamState

	init(manager: VadManager, state: VadStreamState) {
		self.manager = manager
		self.state = state
	}

	func speechProbability(of hop: [Float]) async throws -> Float {
		// Only the probability and the model's recurrent state are used; cut
		// decisions live in `Chunker` so they can be tested without the model.
		let result = try await manager.processStreamingChunk(hop, state: state)
		state = result.state
		return result.probability
	}
}
