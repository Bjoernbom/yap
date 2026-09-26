/// Lines one track's audio up with the meeting clock.
///
/// A transcriber only knows "seconds of audio since it began", but the tracks
/// don't deliver audio continuously: the system-audio tap has no callbacks at
/// all while nothing plays, and the mic can pause across a device change.
/// Each chunk carries the host time of its first sample, so the timeline keeps
/// anchors (stream offset ↔ meeting time) and maps any stream time back to
/// the meeting clock. Clock drift between a device and host time is caught
/// the same way.
///
/// At a gap it also inserts a little silence into the stream, so the VAD cuts
/// there instead of gluing the words on both sides of a long pause into one
/// chunk. Only up to `maxGapFill`: filling the whole gap would mean feeding
/// an hour of zeros through the VAD after a silent hour.
struct TrackTimeline: Sendable {
	struct Anchor: Sendable, Equatable {
		/// Seconds of audio fed to the transcriber before this point.
		var stream: Double
		/// Seconds since the meeting started.
		var meeting: Double
	}

	/// A jump larger than this, either way, starts a new anchor.
	static let tolerance = 0.25
	static let maxGapFill = 1.0

	/// Host time the meeting started.
	let origin: UInt64
	let sampleRate: Double
	private(set) var anchors: [Anchor] = []
	/// Samples handed out by `place`, silence included.
	private(set) var fedSamples = 0

	init(origin: UInt64, sampleRate: Double = AudioChunk.sampleRate) {
		self.origin = origin
		self.sampleRate = sampleRate
	}

	/// Where the stream is now, in seconds of audio.
	var streamSeconds: Double { Double(fedSamples) / sampleRate }

	/// Registers a chunk and returns the samples to feed the transcriber: the
	/// chunk's own, after some silence when a gap came before it.
	mutating func place(_ chunk: AudioChunk) -> [Float] {
		let arrival = (Double(chunk.hostTime) - Double(origin)) / HostClock.ticksPerSecond
		guard !anchors.isEmpty else {
			anchors.append(Anchor(stream: 0, meeting: arrival))
			fedSamples += chunk.samples.count
			return chunk.samples
		}
		let drift = arrival - meetingTime(stream: streamSeconds)
		var samples = chunk.samples
		if drift > Self.tolerance {
			let fill = Int((min(drift, Self.maxGapFill) * sampleRate).rounded())
			samples = [Float](repeating: 0, count: fill) + samples
			fedSamples += fill
		}
		if abs(drift) > Self.tolerance {
			anchors.append(Anchor(stream: streamSeconds, meeting: arrival))
		}
		fedSamples += chunk.samples.count
		return samples
	}

	/// The meeting time of a point in the stream.
	func meetingTime(stream seconds: Double) -> Double {
		guard let first = anchors.first else { return seconds }
		// Anchors are appended in stream order: binary search for the last
		// one at or before `seconds`.
		var low = 0
		var high = anchors.count - 1
		while low < high {
			let middle = (low + high + 1) / 2
			if anchors[middle].stream <= seconds {
				low = middle
			} else {
				high = middle - 1
			}
		}
		let anchor = anchors[low].stream <= seconds ? anchors[low] : first
		return max(0, anchor.meeting + (seconds - anchor.stream))
	}
}
