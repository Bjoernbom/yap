import CoreML
import FluidAudio
import Foundation

struct Options {
	var model: ModelChoice = .v3
	var dataset = "sv_se"
	var hint: Language?
	var file: String?
	var terms: [String] = []

	init(_ arguments: ArraySlice<String>) throws {
		var iterator = arguments.makeIterator()
		while let flag = iterator.next() {
			guard let value = iterator.next() else { throw BenchError.usage("missing value for \(flag)") }
			switch flag {
			case "--model":
				guard let choice = ModelChoice(rawValue: value) else { throw BenchError.usage("unknown model \(value)") }
				model = choice
			case "--lang": dataset = value
			case "--hint":
				guard let language = Language(rawValue: value) else { throw BenchError.usage("unknown language \(value)") }
				hint = language
			case "--file": file = value
			case "--terms": terms = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
			default: throw BenchError.usage("unknown flag \(flag)")
			}
		}
	}
}

enum BenchError: Error, CustomStringConvertible {
	case usage(String)

	var description: String {
		switch self {
		case .usage(let message): message
		}
	}
}

// MARK: - download

func runDownload(_ options: Options) async throws {
	let paths = Paths.current
	let directory = paths.modelDirectory(for: options.model.version)
	print("model: \(options.model.rawValue) -> \(directory.path)")
	let start = ContinuousClock.now
	try await ModelHub.download(options.model.repo, to: paths.models, variant: options.model.downloadVariant)
	if !AsrModels.modelsExist(at: directory, version: options.model.version) {
		// Falls back to the library path (also fetches the vocabulary JSON).
		try await AsrModels.download(to: directory, version: options.model.version)
	}
	print("download: \(fmt(seconds(since: start), 1)) s, on disk: \(mb(directorySize(directory)))")
	let vadStart = ContinuousClock.now
	_ = try await VadManager(config: .default, modelDirectory: paths.local)
	let vadDirectory = paths.models.appendingPathComponent(Repo.vad.folderName)
	print("vad download+load: \(fmt(seconds(since: vadStart), 1)) s, on disk: \(mb(directorySize(vadDirectory)))")
}

// MARK: - load

func runLoad(_ options: Options) async throws {
	let clip = try Dataset.load(options.dataset)[0]
	print("before load: \(MemorySnapshot.now().summary)")

	// Scoped so the engine (and its MLModels) is released before the last measurement.
	do {
		let sampler = PeakMemorySampler()
		sampler.start()
		let (engine, loadTime) = try await Engine.load(options.model)
		let loadPeak = sampler.stop()
		print("load (AsrModels.load + AsrManager): \(fmt(loadTime, 2)) s")
		print("after load: \(MemorySnapshot.now().summary); peak during load: \(loadPeak.summary)")

		for attempt in 1...3 {
			let start = ContinuousClock.now
			let result = try await engine.transcribe(clip.samples)
			print("transcription #\(attempt) (\(fmt(clip.duration, 1)) s audio): \(fmt(seconds(since: start) * 1000, 0)) ms  \(result.text)")
		}
		try await Task.sleep(for: .seconds(2))
		print("idle, model loaded: \(MemorySnapshot.now().summary)")
		if let hold = ProcessInfo.processInfo.environment["ASR_BENCH_HOLD"].flatMap(Int.init) {
			// Lets `footprint <pid>` inspect the loaded process from outside.
			print("holding \(hold) s, pid \(getpid())")
			try await Task.sleep(for: .seconds(hold))
		}
		await engine.manager.cleanup()
	}
	try await Task.sleep(for: .seconds(2))
	let unloaded = MemorySnapshot.now()
	print("after cleanup + release: \(unloaded.summary)")
	print("lifetime peak: footprint \(mb(unloaded.lifetimePeakFootprint)), neural \(mb(unloaded.lifetimePeakNeural))")
}

// MARK: - bench

func runBench(_ options: Options) async throws {
	let clips = try Dataset.load(options.dataset)
	let (engine, loadTime) = try await Engine.load(options.model)
	print("model \(options.model.rawValue), set \(options.dataset), hint \(options.hint?.rawValue ?? "none"), load \(fmt(loadTime, 2)) s")

	let warmStart = ContinuousClock.now
	_ = try await engine.transcribe(clips[0].samples, language: options.hint)
	print("first (warm-up) transcription: \(fmt(seconds(since: warmStart) * 1000, 0)) ms")

	let sampler = PeakMemorySampler()
	sampler.start()
	var latencies: [Double] = []
	var audio = 0.0
	var processing = 0.0
	var raw = WordErrors.zero
	var normalized = WordErrors.zero
	var lines: [String] = []
	for clip in clips {
		let start = ContinuousClock.now
		let result = try await engine.transcribe(clip.samples, language: options.hint)
		let latency = seconds(since: start)
		latencies.append(latency)
		audio += clip.duration
		processing += latency
		let clipRaw = wordErrors(reference: clip.reference, hypothesis: result.text, normalized: false)
		let clipNorm = wordErrors(reference: clip.reference, hypothesis: result.text, normalized: true)
		raw = raw + clipRaw
		normalized = normalized + clipNorm
		print("\(clip.name)  \(fmt(clip.duration, 1)) s  \(fmt(latency * 1000, 0)) ms  WER \(fmt(clipNorm.rate, 2))")
		print("  REF: \(clip.reference)")
		print("  HYP: \(result.text)")
		lines.append("\(clip.name)\t\(fmt(clip.duration, 2))\t\(fmt(latency, 4))\t\(clip.reference)\t\(result.text)")
	}
	let peak = sampler.stop()
	try await Task.sleep(for: .seconds(2))
	let idle = MemorySnapshot.now()

	try FileManager.default.createDirectory(at: Paths.current.results, withIntermediateDirectories: true)
	let output = Paths.current.results.appendingPathComponent(
		"\(options.model.rawValue)-\(options.dataset)-\(options.hint?.rawValue ?? "nohint").tsv")
	try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)

	print("")
	print("SUMMARY model=\(options.model.rawValue) set=\(options.dataset) hint=\(options.hint?.rawValue ?? "none") clips=\(clips.count) audio=\(fmt(audio, 1))s")
	print("  WER normalized: \(fmt(normalized.rate * 100, 2)) %  (\(normalized.edits)/\(normalized.referenceWords))")
	print("  WER raw (case+punct): \(fmt(raw.rate * 100, 2)) %")
	print("  latency ms: median \(fmt(percentile(latencies, 50) * 1000, 0)), p95 \(fmt(percentile(latencies, 95) * 1000, 0)), max \(fmt((latencies.max() ?? 0) * 1000, 0))")
	print("  RTFx (total audio / total processing): \(fmt(audio / processing, 1))")
	print("  memory peak during transcription: \(peak.summary)")
	print("  memory idle after run: \(idle.summary)")
	print("  hypotheses: \(output.path)")
}

// MARK: - idle

func runIdle(_ options: Options) async throws {
	let clip = try Dataset.load(options.dataset)[0]
	let (engine, _) = try await Engine.load(options.model)
	_ = try await engine.transcribe(clip.samples)
	for delay in [0, 5, 30, 90] {
		try await Task.sleep(for: .seconds(delay))
		let start = ContinuousClock.now
		_ = try await engine.transcribe(clip.samples)
		print("after \(delay) s idle: \(fmt(seconds(since: start) * 1000, 0)) ms (\(fmt(clip.duration, 1)) s clip)")
	}
}

// MARK: - transcribe (single file, used for edge-case probes)

func runTranscribe(_ options: Options) async throws {
	guard let path = options.file else { throw BenchError.usage("transcribe needs --file") }
	let (engine, _) = try await Engine.load(options.model)
	let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
	print("samples: \(samples.count) (\(fmt(Double(samples.count) / 16_000, 2)) s)")
	let start = ContinuousClock.now
	let result = try await engine.transcribe(samples, language: options.hint)
	print("latency: \(fmt(seconds(since: start) * 1000, 0)) ms, confidence \(fmt(Double(result.confidence), 2))")
	print("text: \"\(result.text)\"")
}
