import FluidAudio
import Foundation

/// How the simulated live dictation cuts audio into chunks.
struct ChunkStrategy {
	let label: String
	/// Cut on VAD speech-end events (false = blind fixed windows).
	let useVad: Bool
	/// Silence needed before VAD reports speech end.
	let minSilence: Double
	/// Only cut on a pause once the pending chunk is at least this long.
	let minChunk: Double
	/// Hard ceiling; Parakeet's encoder window is 15 s.
	let maxChunk: Double
	/// Carry the TDT decoder LSTM state from one chunk into the next.
	let carryState: Bool
}

private let sampleRate = 16_000
private let hop = VadManager.chunkSize

func runLong(_ options: Options) async throws {
	let clips = try Dataset.load("sv_se")
	var samples: [Float] = []
	var references: [String] = []
	for clip in clips {
		samples += clip.samples
		references.append(clip.reference)
		if samples.count >= 120 * sampleRate { break }
	}
	let reference = references.joined(separator: " ")
	let audioSeconds = Double(samples.count) / Double(sampleRate)
	print("long clip: \(references.count) FLEURS sv utterances, \(fmt(audioSeconds, 1)) s, \(TextNormalizer.words(reference, normalized: true).count) words")

	let (engine, _) = try await Engine.load(options.model)
	_ = try await engine.transcribe(clips[0].samples)
	let vad = try await VadManager(config: .default, modelDirectory: Paths.current.local)

	// (a) Transcribe the whole clip after it ends.
	let sampler = PeakMemorySampler()
	sampler.start()
	let wholeStart = ContinuousClock.now
	let whole = try await engine.transcribe(samples)
	let wholeLatency = seconds(since: wholeStart)
	let wholePeak = sampler.stop()
	let wholeErrors = wordErrors(reference: reference, hypothesis: whole.text, normalized: true)
	print("")
	print("(a) whole clip after release: latency \(fmt(wholeLatency * 1000, 0)) ms, WER \(fmt(wholeErrors.rate * 100, 2)) %, peak \(wholePeak.summary)")
	print("  HYP: \(whole.text)")

	let strategies = [
		ChunkStrategy(label: "vad-every-pause", useVad: true, minSilence: 0.5, minChunk: 0, maxChunk: 14, carryState: false),
		ChunkStrategy(label: "vad-min5s", useVad: true, minSilence: 0.5, minChunk: 5, maxChunk: 14, carryState: false),
		ChunkStrategy(label: "vad-min5s-carry", useVad: true, minSilence: 0.5, minChunk: 5, maxChunk: 14, carryState: true),
		ChunkStrategy(label: "vad-every-pause-0.3s", useVad: true, minSilence: 0.3, minChunk: 0, maxChunk: 14, carryState: false),
		ChunkStrategy(label: "fixed-10s", useVad: false, minSilence: 0, minChunk: 0, maxChunk: 10, carryState: false),
	]
	var summary: [String] = []
	for strategy in strategies {
		let run = try await simulateStreaming(samples, strategy: strategy, engine: engine, vad: vad)
		let errors = wordErrors(reference: reference, hypothesis: run.text, normalized: true)
		print("")
		print("(b) \(strategy.label): \(run.chunkSeconds.count) chunks, lengths s \(run.chunkSeconds.map { fmt($0, 1) }.joined(separator: ","))")
		print("  per-chunk transcribe ms: \(run.chunkLatencies.map { fmt($0 * 1000, 0) }.joined(separator: ","))")
		print("  end-of-audio -> final text: \(fmt(run.finalLatency * 1000, 0)) ms (tail \(fmt(run.chunkSeconds.last ?? 0, 1)) s), WER \(fmt(errors.rate * 100, 2)) %, VAD total \(fmt(run.vadSeconds * 1000, 0)) ms")
		print("  HYP: \(run.text)")
		summary.append("  \(strategy.label.padding(toLength: 22, withPad: " ", startingAt: 0)) chunks \(run.chunkSeconds.count)  final \(fmt(run.finalLatency * 1000, 0)) ms  max chunk \(fmt((run.chunkLatencies.max() ?? 0) * 1000, 0)) ms  WER \(fmt(errors.rate * 100, 2)) %")
	}
	print("")
	print("SUMMARY long clip \(fmt(audioSeconds, 1)) s, model \(options.model.rawValue)")
	print("  whole-after-release         final \(fmt(wholeLatency * 1000, 0)) ms  WER \(fmt(wholeErrors.rate * 100, 2)) %")
	summary.forEach { print($0) }
	print("  REF: \(reference)")
}

struct StreamingRun {
	var text: String
	var chunkSeconds: [Double]
	var chunkLatencies: [Double]
	var finalLatency: Double
	var vadSeconds: Double
}

/// Feeds audio hop by hop as if it were arriving from the mic. Chunks are
/// transcribed as soon as they are cut; after the last hop only the tail is left.
func simulateStreaming(
	_ samples: [Float], strategy: ChunkStrategy, engine: Engine, vad: VadManager
) async throws -> StreamingRun {
	let segmentation = VadSegmentationConfig(minSilenceDuration: strategy.minSilence)
	var vadState = await vad.makeStreamState()
	var decoderState = TdtDecoderState.make(decoderLayers: engine.version.decoderLayers)
	var texts: [String] = []
	var chunkSeconds: [Double] = []
	var chunkLatencies: [Double] = []
	var vadSeconds = 0.0
	var segmentStart = 0
	var position = 0
	// (end sample, speech probability) of each hop in the pending chunk.
	var hops: [(end: Int, probability: Float)] = []

	func transcribe(_ range: Range<Int>) async throws {
		var chunk = Array(samples[range])
		// Parakeet rejects < 0.3 s; pad very short tails with silence.
		if chunk.count < sampleRate { chunk += [Float](repeating: 0, count: sampleRate - chunk.count) }
		let start = ContinuousClock.now
		let result: ASRResult
		if strategy.carryState {
			result = try await engine.transcribe(chunk, state: &decoderState)
		} else {
			result = try await engine.transcribe(chunk)
		}
		chunkLatencies.append(seconds(since: start))
		chunkSeconds.append(Double(range.count) / Double(sampleRate))
		let text = result.text.trimmingCharacters(in: .whitespaces)
		if !text.isEmpty { texts.append(text) }
	}

	var lastHopVad = 0.0
	while position < samples.count {
		let end = min(position + hop, samples.count)
		var probability: Float = 1
		if strategy.useVad {
			var chunk = Array(samples[position..<end])
			if chunk.count < hop { chunk += [Float](repeating: 0, count: hop - chunk.count) }
			let start = ContinuousClock.now
			let result = try await vad.processStreamingChunk(chunk, state: vadState, config: segmentation)
			lastHopVad = seconds(since: start)
			vadSeconds += lastHopVad
			vadState = result.state
			probability = result.probability
			position = end
			hops.append((end, probability))
			let pending = Double(position - segmentStart) / Double(sampleRate)
			if let event = result.event, event.isEnd, pending >= strategy.minChunk {
				try await transcribe(segmentStart..<position)
				segmentStart = position
				hops.removeAll()
				continue
			}
		} else {
			position = end
		}
		let pending = Double(position - segmentStart) / Double(sampleRate)
		if pending >= strategy.maxChunk && position < samples.count {
			// Force a cut at the quietest hop in the last 4 s (or right here for fixed windows).
			var cut = position
			if strategy.useVad {
				let window = hops.filter { $0.end >= position - 4 * sampleRate }
				if let quietest = window.min(by: { $0.probability < $1.probability }) { cut = quietest.end }
			}
			try await transcribe(segmentStart..<cut)
			segmentStart = cut
			hops.removeAll { $0.end <= cut }
		}
	}

	// Key released: only the tail is left.
	let finalStart = ContinuousClock.now
	if segmentStart < samples.count {
		try await transcribe(segmentStart..<samples.count)
	}
	let text = texts.joined(separator: " ")
	let finalLatency = seconds(since: finalStart) + lastHopVad
	return StreamingRun(
		text: text, chunkSeconds: chunkSeconds, chunkLatencies: chunkLatencies,
		finalLatency: finalLatency, vadSeconds: vadSeconds)
}
