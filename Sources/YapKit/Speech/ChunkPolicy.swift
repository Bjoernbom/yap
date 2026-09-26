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
	/// Hard ceiling for one chunk, in seconds, overlap included. Parakeet's
	/// encoder window is 15 s, but only speech without a single short pause
	/// gets here, and a lower ceiling keeps its key-up tail short (a 14 s
	/// chunk takes ~85 ms, 6–10 s ~65 ms).
	public var maxChunk: Double
	/// When the ceiling forces a cut, it lands at the quietest spot in this
	/// many seconds before the overlap.
	public var forceCutWindow: Double
	/// A tail shorter than this with no speech since the last cut is dropped.
	public var minTail: Double
	/// Chunks shorter than this are padded with silence: Parakeet rejects
	/// < 0.3 s and is more reliable on short words with some room around them.
	public var paddedMinimum: Double
	/// From this chunk length on, a hop that dips below `dipThreshold` is
	/// enough to cut. Silero needs ~0.8–1 s of real silence to report speech
	/// end, so a ramble with only short pauses would otherwise run into the
	/// ceiling every time and leave a long tail for key-up.
	public var softChunk: Double
	/// Speech probability under which a hop counts as a short pause.
	public var dipThreshold: Float
	/// Audio on each side of a cut inside speech that both chunks transcribe.
	/// Parakeet drops or garbles words at a chunk edge that runs into speech,
	/// so each word is taken from the chunk that heard it with at least this
	/// much context around it, by word timings.
	public var overlap: Double
	/// While the key is held and the engine has had nothing to do for this
	/// long, wake it with a warm-up call. The Neural Engine clocks down after
	/// about a second of idle, which costs key-up 25–50 ms. nil turns it off.
	public var keepWarmInterval: Double?

	public init(
		hopSamples: Int = 4096,
		speechThreshold: Float = 0.85,
		silenceThreshold: Float = 0.70,
		minSilence: Double = 0.5,
		maxChunk: Double = 10,
		forceCutWindow: Double = 3,
		minTail: Double = 0.3,
		paddedMinimum: Double = 1,
		softChunk: Double = 4,
		dipThreshold: Float = 0.5,
		overlap: Double = 1,
		keepWarmInterval: Double? = 0.75
	) {
		self.hopSamples = hopSamples
		self.speechThreshold = speechThreshold
		self.silenceThreshold = silenceThreshold
		self.minSilence = minSilence
		self.maxChunk = maxChunk
		self.forceCutWindow = forceCutWindow
		self.minTail = minTail
		self.paddedMinimum = paddedMinimum
		self.softChunk = softChunk
		self.dipThreshold = dipThreshold
		self.overlap = overlap
		self.keepWarmInterval = keepWarmInterval
	}

	/// Push-to-talk dictation: cut at every pause of 0.5 s, at a short dip
	/// once a chunk passes 4 s, and never exceed 10 s.
	public static let dictation = ChunkPolicy()

	func samples(_ seconds: Double) -> Int {
		Int((seconds * AudioChunk.sampleRate).rounded())
	}
}

/// Why a chunk ended where it did.
public enum ChunkCut: String, Sendable {
	/// VAD saw the end of speech.
	case pause
	/// A long chunk was cut at a short pause, with overlap.
	case dip
	/// The chunk hit the length ceiling and was cut inside speech, with overlap.
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
	/// The part of the chunk whose words belong to it, in seconds from its
	/// start. Words outside it sit in an overlap and come from the
	/// neighbouring chunk, which heard them with context on both sides.
	var keep: Range<Double> = 0..<Double.infinity
}

/// Decides where to cut, one VAD hop at a time. Pure and synchronous so the
/// policy can be tested with made-up probability sequences.
struct Chunker: Sendable {
	let policy: ChunkPolicy

	/// Audio since the last cut, including the overlap before it.
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
	/// Where `pending`'s own words begin. After a cut inside speech the audio
	/// before this is overlap whose words the previous chunk keeps.
	private(set) var keepFrom = 0
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
			return cut(at: pending.count, reason: .pause, overlap: 0)
		}
		let overlap = policy.samples(policy.overlap)
		// A cut inside speech needs `overlap` of audio after it, so the
		// candidate is the hop that ended that long ago.
		let candidateEnd = pending.count - overlap
		// Only after speech: cutting silence in pieces only costs engine calls.
		if heardSpeech, candidateEnd >= policy.samples(policy.softChunk),
			let dip = hops.last(where: { $0.end <= candidateEnd }),
			dip.end > candidateEnd - policy.hopSamples,
			dip.probability < policy.dipThreshold {
			let at = quietestPoint(in: max(keepFrom, dip.end - policy.hopSamples)..<dip.end)
			return cut(at: at, reason: .dip, overlap: overlap)
		}
		// Cut before the next hop would take us past the ceiling.
		if pending.count + policy.hopSamples > policy.samples(policy.maxChunk) {
			let windowStart = max(keepFrom, candidateEnd - policy.samples(policy.forceCutWindow))
			let at = quietestPoint(in: windowStart..<max(windowStart, candidateEnd))
			return cut(at: at, reason: .ceiling, overlap: overlap)
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
		let fresh = seconds(pending.count - keepFrom)
		defer { reset() }
		if pending.count <= keepFrom { return nil }
		if fresh < policy.minTail && !hasSpeech { return nil }
		return SpeechChunk(
			samples: padded(pending), duration: seconds(pending.count), reason: .tail,
			start: seconds(emitted), keep: seconds(keepFrom)..<Double.infinity)
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

	/// Where in `range` of `pending` the audio is quietest, by 20 ms frames:
	/// the gap between two words when the range holds one, so a word is
	/// rarely split and its timing sits clearly on one side of the cut.
	private func quietestPoint(in range: Range<Int>) -> Int {
		let frame = 320
		let step = 160
		guard range.count > frame else { return (range.lowerBound + range.upperBound) / 2 }
		var best = range.lowerBound + frame / 2
		var bestEnergy = Float.infinity
		var start = range.lowerBound
		while start + frame <= range.upperBound {
			var energy: Float = 0
			for sample in pending[start..<(start + frame)] { energy += sample * sample }
			if energy < bestEnergy {
				bestEnergy = energy
				best = start + frame / 2
			}
			start += step
		}
		return best
	}

	/// Cuts at `at` in `pending`. With an overlap the chunk runs `overlap`
	/// past the cut and the next one starts `overlap` before it; each keeps
	/// only the words on its own side.
	private mutating func cut(at: Int, reason: ChunkCut, overlap: Int) -> SpeechChunk {
		let end = min(pending.count, at + overlap)
		let audio = Array(pending[..<end])
		let keepUntil = overlap > 0 ? seconds(at) : Double.infinity
		let chunk = SpeechChunk(
			samples: padded(audio), duration: seconds(audio.count), reason: reason,
			start: seconds(emitted), keep: seconds(keepFrom)..<keepUntil)
		let next = max(0, at - overlap)
		pending.removeFirst(next)
		emitted += next
		keepFrom = at - next
		hops = hops.filter { $0.end > next }.map { ($0.end - next, $0.probability) }
		// Whatever stays behind a cut inside speech may already hold speech.
		heardSpeech = triggered || hops.contains { $0.end > keepFrom && $0.probability >= policy.speechThreshold }
		return chunk
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
