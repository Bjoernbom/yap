import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let options = Options(Array(arguments.dropFirst()))

do {
	switch command {
	case "availability":
		await AvailabilityProbe.run()
	case "context":
		await AvailabilityProbe.probeContext()
	case "polish":
		try await PolishBench.run(options)
	case "summary":
		try await SummaryBench.run(options)
	case "guard":
		try GuardSelfTest.run()
	case "probe":
		try await Probes.run(options)
	default:
		print("""
		usage: llm-bench <command> [options]
		  availability   model availability, languages, locales
		  context        empirically find the context window size
		  polish         run the polish corpus
		                 [--outputs plain,guided] [--guardrails permissive|default]
		                 [--prewarm on,off] [--speak-ms 800] [--all-styles] [--only id,id]
		  summary        map-reduce the meeting fixtures
		                 [--meetings sv,en] [--section-chars 4000,6000,8000] [--reduce-chars 7000]
		                 [--parallel 1] [--dry-run]
		  guard          self-test the output guard against references and known-bad outputs (no model needed)
		  probe          off-happy-path inputs through gate, model (1.5 s timeout) and guard
		                 [--text "..." --lang sv|en --style casual|proper|dev] [--force] [--timeout-ms 1500]
		""")
	}
} catch {
	print("failed: \(error)")
	exit(1)
}
