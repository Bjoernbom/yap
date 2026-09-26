import Foundation
import YapKit

struct TextReport: Codable {
	var input: String
	var app: String?
	var style: String
	var cleaned: String
	var dictionary: String
	var polish: String
	var output: String
	var milliseconds: Double
}

/// Runs one transcript through the text pipeline, stage by stage, the way
/// the app would for the given app (or every style with `--all-styles`).
func runText(_ options: Options) async throws {
	guard let input = options.file else { throw BenchError.usage("text needs the transcript as an argument") }
	var settings = TextSettings(polishEnabled: options.polish)
	if let path = options.dictionaryPath {
		settings.dictionary = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: URL(filePath: path)))
	}
	let pipeline = TextPipeline(settings: settings)
	if options.polish, case .unavailable(let reason) = pipeline.polishAvailability {
		log("polish unavailable, needs Apple Intelligence: \(reason)")
	}
	let styles: [WritingStyle?] = options.allStyles ? WritingStyle.allCases : [options.style]
	var reports: [TextReport] = []
	for style in styles {
		let target = options.app.map { FocusTarget(pid: 0, bundleID: $0) }
		await pipeline.prepare(for: target)
		let start = ContinuousClock.now
		let result = await pipeline.run(input, bundleID: options.app, style: style)
		reports.append(TextReport(
			input: input, app: options.app, style: result.style.rawValue,
			cleaned: result.cleaned, dictionary: result.dictionary,
			polish: describe(result.polish), output: result.text,
			milliseconds: milliseconds(ContinuousClock.now - start)
		))
	}
	if options.json { return try printJSON(reports) }
	print("in       \(input)")
	for report in reports {
		print("[\(report.style)] \(format(report.milliseconds, 2)) ms")
		if report.cleaned != input { print("  cleaned  \(report.cleaned)") }
		if report.dictionary != report.cleaned { print("  dict     \(report.dictionary)") }
		print("  polish   \(report.polish)")
		print("  out      \(report.output)")
	}
}

private func describe(_ outcome: PolishOutcome) -> String {
	switch outcome {
	case .polished: "polished"
	case .skipped(.disabled): "off"
	case .skipped(.unavailable): "skipped (unavailable)"
	case .skipped(.unsupportedLanguage(let language)): "skipped (unsupported language \(language ?? "unknown"))"
	case .skipped(.gate(let reason)): "skipped (\(reason))"
	case .skipped(.timeout): "skipped (timeout)"
	case .skipped(.failed(let error)): "skipped (failed: \(error))"
	case .skipped(.rejected(let flags)): "rejected (\(flags.joined(separator: ", ")))"
	}
}
