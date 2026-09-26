import FluidAudio
import Foundation

/// Runs a dataset with and without FluidAudio's CTC vocabulary boosting
/// (the only custom-vocabulary mechanism that works with Parakeet 0.6B v3).
func runVocab(_ options: Options) async throws {
	guard !options.terms.isEmpty else { throw BenchError.usage("vocab needs --terms a,b,c") }
	let paths = Paths.current
	let clips = try Dataset.load(options.dataset)
	let (engine, _) = try await Engine.load(options.model)

	// VocabularyBoostingSession reads the CTC tokenizer from the library's default
	// cache directory, so point that at our local copy for the duration of the run.
	let ctcDirectory = paths.models.appendingPathComponent(Repo.parakeetCtc110m.folderName, isDirectory: true)
	let defaultDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
	let downloadStart = ContinuousClock.now
	try await CtcModels.download(to: ctcDirectory, variant: .ctc110m)
	print("ctc110m download+compile: \(fmt(seconds(since: downloadStart), 1)) s, on disk \(mb(directorySize(ctcDirectory)))")
	var createdLink = false
	if !FileManager.default.fileExists(atPath: defaultDirectory.path) {
		try FileManager.default.createDirectory(
			at: defaultDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: defaultDirectory, withDestinationURL: ctcDirectory)
		createdLink = true
	}
	defer {
		if createdLink { try? FileManager.default.removeItem(at: defaultDirectory) }
	}

	let before = MemorySnapshot.now()
	let loadStart = ContinuousClock.now
	let ctcModels = try await CtcModels.load(from: ctcDirectory, variant: .ctc110m)
	let vocabulary = CustomVocabularyContext(terms: options.terms.map { CustomVocabularyTerm(text: $0) })
	let session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctcModels)
	let after = MemorySnapshot.now()
	print("ctc load + session: \(fmt(seconds(since: loadStart), 2)) s, footprint +\(mb(after.footprint &- before.footprint)), resident +\(mb(after.resident &- before.resident))")
	print("terms: \(options.terms.joined(separator: ", "))")

	var baseErrors = WordErrors.zero
	var boostedErrors = WordErrors.zero
	var rescoreTimes: [Double] = []
	for clip in clips {
		let result = try await engine.transcribe(clip.samples, language: options.hint)
		let start = ContinuousClock.now
		let output = await session.rescore(
			text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: clip.samples)
		rescoreTimes.append(seconds(since: start))
		let boosted = output?.text ?? result.text
		baseErrors = baseErrors + wordErrors(reference: clip.reference, hypothesis: result.text, normalized: true)
		boostedErrors = boostedErrors + wordErrors(reference: clip.reference, hypothesis: boosted, normalized: true)
		print("\(clip.name)  rescore \(fmt(rescoreTimes.last! * 1000, 0)) ms  detected [\(output?.detectedTerms.joined(separator: ", ") ?? "")]")
		print("  REF:   \(clip.reference)")
		print("  BASE:  \(result.text)")
		if boosted != result.text { print("  BOOST: \(boosted)") }
	}
	print("")
	print("SUMMARY vocab set=\(options.dataset) WER base \(fmt(baseErrors.rate * 100, 2)) % -> boosted \(fmt(boostedErrors.rate * 100, 2)) %, rescore median \(fmt(percentile(rescoreTimes, 50) * 1000, 0)) ms")
}
