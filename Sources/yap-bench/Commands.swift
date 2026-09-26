import Foundation
import Synchronization
import YapKit

/// The plan's section 6 ceiling for idle with the model warm.
private let footprintCeilingMB = 120.0
private let neuralCeilingMB = 650.0

private let clock = ContinuousClock()

private func prepared(_ options: Options) async throws -> (ParakeetEngine, Double) {
	let engine = ParakeetEngine(model: options.model)
	let start = clock.now
	let progress = ProgressLogger()
	try await engine.prepare { progress($0) }
	return (engine, milliseconds(clock.now - start))
}

// MARK: - prepare

struct PrepareReport: Codable {
	var model: String
	var concurrent: Bool
	var callerMilliseconds: [Double]
	var loaded: Bool
}

/// Download (if needed), load and compile. `--concurrent` has two callers
/// race on one engine; they must share a single load.
func runPrepare(_ options: Options) async throws {
	let engine = ParakeetEngine(model: options.model)
	let callers = options.concurrent ? ["A", "B"] : [""]
	let start = clock.now
	let durations = try await withThrowingTaskGroup(of: Double.self) { group in
		for caller in callers {
			group.addTask {
				let progress = ProgressLogger(label: caller.isEmpty ? "" : "[\(caller)] ")
				try await engine.prepare { progress($0) }
				return milliseconds(clock.now - start)
			}
		}
		return try await group.reduce(into: []) { $0.append($1) }
	}
	let report = PrepareReport(
		model: options.model.rawValue, concurrent: options.concurrent,
		callerMilliseconds: durations.sorted(), loaded: await engine.isLoaded)
	if options.json { return try printJSON(report) }
	print("model \(report.model): prepared in \(report.callerMilliseconds.map { format($0, 0) + " ms" }.joined(separator: ", ")), loaded \(report.loaded)")
}

// MARK: - transcribe

struct TranscribeReport: Codable {
	var file: String
	var model: String
	var audioSeconds: Double
	var prepareMilliseconds: Double
	var warmUpMilliseconds: Double
	var latencyMilliseconds: Double
	var confidence: Float
	var text: String
}

/// One file in one engine call, after a warm-up.
func runTranscribe(_ options: Options) async throws {
	let path = try options.requireFile()
	let samples = try loadAudio(path)
	let (engine, prepareTime) = try await prepared(options)
	let warmStart = clock.now
	await engine.warmUp()
	let warmTime = milliseconds(clock.now - warmStart)
	// The Neural Engine clocks down within seconds of idle; this shows the
	// cost of a call that comes after a quiet stretch of dictation.
	if let idle = options.idle { try await clock.sleep(for: .seconds(idle)) }
	let start = clock.now
	let transcript = try await engine.transcribe(samples)
	let report = TranscribeReport(
		file: path, model: options.model.rawValue, audioSeconds: Double(samples.count) / AudioChunk.sampleRate,
		prepareMilliseconds: prepareTime, warmUpMilliseconds: warmTime,
		latencyMilliseconds: milliseconds(clock.now - start), confidence: transcript.confidence,
		text: transcript.text)
	if options.json { return try printJSON(report) }
	print("\(report.file): \(format(report.audioSeconds, 2)) s of audio, model \(report.model)")
	print("prepare \(format(report.prepareMilliseconds, 0)) ms, warm-up \(format(report.warmUpMilliseconds, 0)) ms")
	print("transcribe \(format(report.latencyMilliseconds, 0)) ms, confidence \(format(Double(report.confidence), 2))")
	print("text: \"\(report.text)\"")
}

// MARK: - stream

struct StreamReport: Codable {
	struct Chunk: Codable {
		var index: Int
		var reason: String
		/// Where the chunk begins in the file.
		var startSeconds: Double
		var audioSeconds: Double
		var latencyMilliseconds: Double
		/// Wall time since the first append when the chunk's text was ready.
		var readyAtSeconds: Double
		var text: String
	}

	var file: String
	var model: String
	var audioSeconds: Double
	var speed: Double
	var pieceMilliseconds: Int
	var feedSeconds: Double
	var chunks: [Chunk]
	var cancelled: Bool
	/// End of audio (the `finish` call) → joined text. The key-up number.
	var finalLatencyMilliseconds: Double
	var text: String
	var secondFinishMilliseconds: Double?
	var secondFinishMatches: Bool?
}

/// Feeds a file through `StreamingTranscriber` as if it came from the mic,
/// in `--piece-ms` appends paced at `--speed` × real time.
func runStream(_ options: Options) async throws {
	let path = try options.requireFile()
	let samples = try loadAudio(path)
	let (engine, _) = try await prepared(options)
	let vad = try await SileroVAD.load()

	let chunks = Mutex<[StreamReport.Chunk]>([])
	let feedStart = Mutex<ContinuousClock.Instant?>(nil)
	var policy = ChunkPolicy.dictation
	if let maxChunk = options.maxChunk { policy.maxChunk = maxChunk }
	let transcriber = StreamingTranscriber(engine: engine, vad: vad, policy: policy) { report in
		let readyAt = feedStart.withLock { $0.map { clock.now - $0 } } ?? .zero
		chunks.withLock {
			$0.append(StreamReport.Chunk(
				index: report.index, reason: report.reason.rawValue, startSeconds: report.start,
				audioSeconds: report.duration,
				latencyMilliseconds: milliseconds(report.latency),
				readyAtSeconds: milliseconds(readyAt) / 1000, text: report.text))
		}
	}

	// Key-down: wake the ANE, then start listening.
	await engine.warmUp()
	await transcriber.begin()
	let piece = Int(AudioChunk.sampleRate) * options.pieceMilliseconds / 1000
	let start = clock.now
	feedStart.withLock { $0 = start }
	var cancelled = false
	var offset = 0
	while offset < samples.count {
		let end = min(offset + piece, samples.count)
		if options.speed > 0 {
			// A mic buffer is available once its last sample has been captured.
			let due = Double(end) / AudioChunk.sampleRate / options.speed
			try await clock.sleep(until: start + .seconds(due))
		}
		await transcriber.append(AudioChunk(samples: Array(samples[offset..<end]), hostTime: 0))
		offset = end
		if let cancelAfter = options.cancelAfter, Double(offset) / AudioChunk.sampleRate >= cancelAfter {
			await transcriber.cancel()
			cancelled = true
			break
		}
	}
	let feedSeconds = milliseconds(clock.now - start) / 1000

	// Key-up.
	let finishStart = clock.now
	let text = try await transcriber.finish()
	let finalLatency = milliseconds(clock.now - finishStart)

	var secondLatency: Double?
	var secondMatches: Bool?
	if options.finishTwice {
		let secondStart = clock.now
		let again = try await transcriber.finish()
		secondLatency = milliseconds(clock.now - secondStart)
		secondMatches = again == text
	}

	let report = StreamReport(
		file: path, model: options.model.rawValue, audioSeconds: Double(samples.count) / AudioChunk.sampleRate,
		speed: options.speed, pieceMilliseconds: options.pieceMilliseconds, feedSeconds: feedSeconds,
		chunks: chunks.withLock { $0 }, cancelled: cancelled, finalLatencyMilliseconds: finalLatency, text: text,
		secondFinishMilliseconds: secondLatency, secondFinishMatches: secondMatches)
	if options.json { return try printJSON(report) }
	print("\(report.file): \(format(report.audioSeconds, 1)) s of audio, model \(report.model), speed \(report.speed == 0 ? "max" : format(report.speed, 1) + "×"), \(report.pieceMilliseconds) ms appends, fed in \(format(report.feedSeconds, 2)) s")
	for chunk in report.chunks {
		print("  #\(chunk.index) \(chunk.reason.padding(toLength: 7, withPad: " ", startingAt: 0)) at \(format(chunk.startSeconds, 2)) s  \(format(chunk.audioSeconds, 2)) s audio  \(format(chunk.latencyMilliseconds, 0)) ms  ready at \(format(chunk.readyAtSeconds, 2)) s  \"\(chunk.text)\"")
	}
	if report.cancelled { print("cancelled after \(format(options.cancelAfter ?? 0, 1)) s") }
	print("end of audio -> final text: \(format(report.finalLatencyMilliseconds, 1)) ms")
	if let secondLatency, let secondMatches {
		print("second finish: \(format(secondLatency, 1)) ms, same text: \(secondMatches)")
	}
	print("text: \"\(report.text)\"")
}

// MARK: - memory

struct MemoryReport: Codable {
	var model: String
	var beforeLoad: MemorySnapshot
	var idleWarm: MemorySnapshot
	var afterUnload: MemorySnapshot
	var footprintCeilingMB: Double
	var neuralCeilingMB: Double
	var withinCeiling: Bool
}

/// Idle memory with the model loaded and warm, against the plan's ceiling,
/// and what `unload()` gives back.
func runMemory(_ options: Options) async throws {
	let settle = Duration.seconds(2)
	let before = MemorySnapshot.now()
	let (engine, _) = try await prepared(options)
	for _ in 0..<3 { await engine.warmUp() }
	try await clock.sleep(for: settle)
	let idle = MemorySnapshot.now()
	await engine.unload()
	try await clock.sleep(for: settle)
	let unloaded = MemorySnapshot.now()
	let report = MemoryReport(
		model: options.model.rawValue, beforeLoad: before, idleWarm: idle, afterUnload: unloaded,
		footprintCeilingMB: footprintCeilingMB, neuralCeilingMB: neuralCeilingMB,
		withinCeiling: idle.footprintMB <= footprintCeilingMB && idle.neuralMB <= neuralCeilingMB)
	if options.json { return try printJSON(report) }
	print("model \(report.model)")
	print("before load:       \(before.summary)")
	print("idle, model warm:  \(idle.summary)")
	print("after unload:      \(unloaded.summary)")
	print("ceiling \(format(footprintCeilingMB, 0)) MB footprint + \(format(neuralCeilingMB, 0)) MB neural: \(report.withinCeiling ? "PASS" : "FAIL")")
}
