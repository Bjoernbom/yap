#if DEBUG
import AVFoundation
import YapKit

/// Plays an audio file into notes instead of a live track, for
/// verification: a 10-minute meeting in a minute or two, and a "them"
/// track without a call. DEBUG builds only.
///
/// - `-YapNotesMicFile <file>` / `-YapNotesThemFile <file>` pick the files.
/// - `-YapNotesFileSpeed <n>` plays n× real time (default 1).
/// - `-YapNotesFileLoops <n>` plays the file n times back to back.
///
/// Chunks are stamped with host times at the file's own pace, so the notes
/// timeline sees a real meeting's timing even when it plays faster. The
/// stream ends at the end of the file; stopping notes early cuts it off.
actor DebugAudioFile: AudioSource {
	private let url: URL
	private let speed: Double
	private let loops: Int
	private var pump: Task<Void, Never>?
	private var continuation: AsyncStream<AudioChunk>.Continuation?

	static func source(forKey key: String) -> DebugAudioFile? {
		let defaults = UserDefaults.standard
		guard let path = defaults.string(forKey: key) else { return nil }
		let speed = defaults.double(forKey: "YapNotesFileSpeed")
		return DebugAudioFile(
			url: URL(filePath: path),
			speed: speed > 0 ? speed : 1,
			loops: max(defaults.integer(forKey: "YapNotesFileLoops"), 1))
	}

	init(url: URL, speed: Double, loops: Int) {
		self.url = url
		self.speed = speed
		self.loops = loops
	}

	func prepare() async throws {}

	func start() async throws -> AsyncStream<AudioChunk> {
		// Fails here, not silently in the pump, when the file is unreadable.
		_ = try AVAudioFile(forReading: url)
		let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
		self.continuation = continuation
		let origin = HostClock.now()
		pump = Task.detached { [url, speed, loops] in
			var played = 0.0
			for _ in 0..<loops {
				guard !Task.isCancelled else { break }
				guard let source = try? AVAudioFile(forReading: url) else { break }
				played = await Self.play(source, from: played, origin: origin, speed: speed, into: continuation)
			}
			continuation.finish()
		}
		return stream
	}

	func stop() async {
		pump?.cancel()
		continuation?.finish()
		continuation = nil
		pump = nil
	}

	/// Converts to 16 kHz mono in 100 ms chunks and paces them. Returns the
	/// seconds played so far, for the next loop's host times.
	private static func play(
		_ file: AVAudioFile, from offset: Double, origin: UInt64, speed: Double,
		into continuation: AsyncStream<AudioChunk>.Continuation
	) async -> Double {
		guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: false),
		      let converter = AVAudioConverter(from: file.processingFormat, to: target)
		else { return offset }
		let readFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
		let clock = ContinuousClock()
		let start = clock.now
		var played = offset
		var produced = 0.0
		var finished = false
		while !finished, !Task.isCancelled {
			guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1_600) else { break }
			var error: NSError?
			let status = converter.convert(to: output, error: &error) { _, inputStatus in
				guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readFrames),
				      (try? file.read(into: input, frameCount: readFrames)) != nil, input.frameLength > 0
				else {
					inputStatus.pointee = .endOfStream
					return nil
				}
				inputStatus.pointee = .haveData
				return input
			}
			if status == .endOfStream || status == .error { finished = true }
			guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { continue }
			let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
			continuation.yield(AudioChunk(samples: samples, hostTime: origin + HostClock.ticks(seconds: played)))
			let seconds = Double(samples.count) / AudioChunk.sampleRate
			played += seconds
			produced += seconds
			// Pace at `speed`× real time.
			try? await clock.sleep(until: start + .seconds(produced / speed))
		}
		return played
	}
}
#endif
