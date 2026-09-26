/// Lets several transcribers share one engine without overlapping calls.
///
/// Notes run a transcriber per track against the one Parakeet model on the
/// Neural Engine. Actor isolation alone doesn't serialize `ParakeetEngine`:
/// it suspends inside `transcribe`, so a second call can start before the
/// first returns. This wrapper queues calls in arrival order instead.
public actor SerialSpeechEngine: SpeechEngine {
	private let engine: any SpeechEngine
	private var busy = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	public init(_ engine: any SpeechEngine) {
		self.engine = engine
	}

	public func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
		try await engine.prepare(progress: progress)
	}

	public func warmUp() async {
		await acquire()
		defer { release() }
		await engine.warmUp()
	}

	public func transcribe(_ samples: [Float]) async throws -> Transcript {
		await acquire()
		defer { release() }
		return try await engine.transcribe(samples)
	}

	public func unload() async {
		await engine.unload()
	}

	private func acquire() async {
		guard busy else {
			busy = true
			return
		}
		await withCheckedContinuation { waiters.append($0) }
	}

	/// Hands the engine straight to the next waiter, so `busy` never flips
	/// false in between and a newcomer can't jump the queue.
	private func release() {
		if waiters.isEmpty {
			busy = false
		} else {
			waiters.removeFirst().resume()
		}
	}
}
