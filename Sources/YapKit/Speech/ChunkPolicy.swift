/// How live audio is cut into chunks for the speech engine while the user is
/// still talking. The numbers come from the M0 ASR spike (`docs/spikes/asr.md`).
public struct ChunkPolicy: Sendable, Equatable {
	/// Samples per VAD step. Silero v6 takes exactly 4096 new samples (256 ms).
	public var hopSamples: Int
	/// A hop at or above this speech probability counts as speech. 0.85 is
	/// FluidAudio's Silero default, which the spike measured with.
	public var speechThreshold: Float
	/// Below this a hop counts as silence; between the two thresholds the
	/// previous state holds (hysteresis, so a breathy word doesn't split).
	public var silenceThreshold: Float
	/// Silence needed after speech before we cut, in seconds.
	public var minSilence: Double
	/// Hard ceiling for one chunk, in seconds. Parakeet's encoder window is
	/// 15 s; longer input costs a second window and smears across the seam.
	public var maxChunk: Double
	/// When the ceiling forces a cut, it lands at the quietest hop in this
	/// many trailing seconds, so we rarely cut through a word.
	public var forceCutWindow: Double
	/// A tail shorter than this with no speech since the last cut is dropped.
	public var minTail: Double
	/// Chunks shorter than this are padded with silence: Parakeet rejects
	/// < 0.3 s and is more reliable on short words with some room around them.
	public var paddedMinimum: Double

	public init(
		hopSamples: Int = 4096,
		speechThreshold: Float = 0.85,
		silenceThreshold: Float = 0.70,
		minSilence: Double = 0.5,
		maxChunk: Double = 14,
		forceCutWindow: Double = 4,
		minTail: Double = 0.3,
		paddedMinimum: Double = 1
	) {
		self.hopSamples = hopSamples
		self.speechThreshold = speechThreshold
		self.silenceThreshold = silenceThreshold
		self.minSilence = minSilence
		self.maxChunk = maxChunk
		self.forceCutWindow = forceCutWindow
		self.minTail = minTail
		self.paddedMinimum = paddedMinimum
	}

	/// Push-to-talk dictation: cut at every pause of 0.5 s, never exceed 14 s.
	public static let dictation = ChunkPolicy()

	func samples(_ seconds: Double) -> Int {
		Int((seconds * AudioChunk.sampleRate).rounded())
	}
}

/// Why a chunk ended where it did.
public enum ChunkCut: String, Sendable {
	/// VAD saw the end of speech.
	case pause
	/// The chunk hit the length ceiling.
	case ceiling
	/// Key-up: whatever was left.
	case tail
}

/// A piece of audio ready for the engine.
struct SpeechChunk: Sendable, Equatable {
	/// Padded to at least `ChunkPolicy.paddedMinimum`.
	var samples: [Float]
	/// Length of the real audio before padding, in seconds.
	var duration: Double
	var reason: ChunkCut
	/// Where the chunk's audio begins, in seconds since the stream began.
	var start: Double = 0
}

/// Decides where to cut, one VAD hop at a time. Pure and synchronous so the
/// policy can be tested with made-up probability sequences.
struct Chunker: Sendable {
	let policy: ChunkPolicy

	/// Audio since the last cut.
	private(set) var pending: [Float] = []
	/// Speech probability of each hop in `pending`, keyed by where it ends.
	private var hops: [(end: Int, probability: Float)] = []
	/// Inside speech, per the hysteresis.
	private var triggered = false
	/// Sample count (since the stream began) when the current silence began.
	private var silenceStart: Int?
	private var processed = 0
	/// Samples handed out in earlier chunks; where `pending` begins.
	private var emitted = 0
	/// Any hop at or above the speech threshold since the last cut.
	private var heardSpeech = false

	init(policy: ChunkPolicy) {
		self.policy = policy
	}

	/// Feeds one hop and its speech probability. Returns a chunk when this hop
	/// completes one.
	mutating func push(_ hop: [Float], probability: Float) -> SpeechChunk? {
		pending += hop
		processed += hop.count
		hops.append((pending.count, probability))

		if updateSpeechState(probability) {
			return cut(at: pending.count, reason: .pause)
		}
		// Cut before the next hop would take us past the ceiling.
		if pending.count + policy.hopSamples > policy.samples(policy.maxChunk) {
			let windowStart = pending.count - policy.samples(policy.forceCutWindow)
			let quietest = hops.filter { $0.end >= windowStart }.min { $0.probability < $1.probability }
			return cut(at: quietest?.end ?? pending.count, reason: .ceiling)
		}
		return nil
	}

	/// Key-up. `remainder` is the audio that didn't fill a whole hop, and
	/// `probability` its VAD score (if it was scored). Returns the tail, or
	/// nil when it's too short to hold anything.
	mutating func finish(remainder: [Float], probability: Float?) -> SpeechChunk? {
		pending += remainder
		if let probability, probability >= policy.speechThreshold { heardSpeech = true }
		let hasSpeech = heardSpeech || triggered
		let duration = Double(pending.count) / AudioChunk.sampleRate
		defer { reset() }
		if pending.isEmpty { return nil }
		if duration < policy.minTail && !hasSpeech { return nil }
		return SpeechChunk(samples: padded(pending), duration: duration, reason: .tail, start: seconds(emitted))
	}

	/// Mirrors FluidAudio's Silero streaming state machine, which the spike's
	/// numbers were measured with: the silence clock starts at the end of the
	/// first silent hop, so a 0.5 s pause cuts after the third silent hop.
	/// Returns true on a speech end.
	private mutating func updateSpeechState(_ probability: Float) -> Bool {
		if probability >= policy.speechThreshold {
			heardSpeech = true
			triggered = true
			silenceStart = nil
			return false
		}
		guard triggered, probability < policy.silenceThreshold else { return false }
		let start = silenceStart ?? processed
		silenceStart = start
		guard processed - start >= policy.samples(policy.minSilence) else { return false }
		triggered = false
		silenceStart = nil
		return true
	}

	private mutating func cut(at end: Int, reason: ChunkCut) -> SpeechChunk {
		let audio = Array(pending[..<end])
		pending.removeFirst(end)
		hops = hops.filter { $0.end > end }.map { ($0.end - end, $0.probability) }
		// Whatever stays behind a forced cut may already hold speech.
		heardSpeech = triggered || hops.contains { $0.probability >= policy.speechThreshold }
		let duration = Double(audio.count) / AudioChunk.sampleRate
		let start = seconds(emitted)
		emitted += audio.count
		return SpeechChunk(samples: padded(audio), duration: duration, reason: reason, start: start)
	}

	private func seconds(_ samples: Int) -> Double {
		Double(samples) / AudioChunk.sampleRate
	}

	private func padded(_ audio: [Float]) -> [Float] {
		let minimum = policy.samples(policy.paddedMinimum)
		guard audio.count < minimum else { return audio }
		return audio + [Float](repeating: 0, count: minimum - audio.count)
	}

	private mutating func reset() {
		self = Chunker(policy: policy)
	}
}
