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
	case "guard":
		try GuardSelfTest.run()
	default:
		print("""
		usage: llm-bench <command> [options]
		  availability   model availability, languages, locales
		  context        empirically find the context window size
		  polish         run the polish corpus
		                 [--outputs plain,guided] [--guardrails permissive|default]
		                 [--prewarm on,off] [--speak-ms 800] [--all-styles] [--only id,id]
		  guard          self-test the output guard against references and known-bad outputs (no model needed)
		""")
	}
} catch {
	print("failed: \(error)")
	exit(1)
}
