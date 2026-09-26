import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let rest = Array(arguments.dropFirst())

switch command {
case "availability":
	await AvailabilityProbe.run()
case "context":
	await AvailabilityProbe.probeContext()
default:
	print("""
	usage: llm-bench <command>
	  availability   model availability, languages, locales
	  context        empirically find the context window size
	""")
}
