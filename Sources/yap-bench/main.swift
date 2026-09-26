import Foundation

let usage = """
	usage: yap-bench <command> [options]

	  prepare [--concurrent]      download, load and compile the model
	  transcribe <audio>          one file in one engine call
	  stream <audio>              feed a file through StreamingTranscriber like a live mic
	      --speed <x>             playback speed, 1 = real time (default), 0 = as fast as possible
	      --piece-ms <ms>         size of each append (default 100)
	      --cancel-after <s>      cancel after this much audio (probe)
	      --finish-twice          call finish() twice (probe)
	  memory                      idle footprint + Neural Engine memory with the model warm

	  --model ultra|v3            default ultra
	  --json                      machine-readable output on stdout
	"""

do {
	let options = try Options(Array(CommandLine.arguments.dropFirst()))
	switch options.command {
	case "prepare": try await runPrepare(options)
	case "transcribe": try await runTranscribe(options)
	case "stream": try await runStream(options)
	case "memory": try await runMemory(options)
	default: throw BenchError.usage(nil)
	}
} catch BenchError.usage(let message) {
	if let message { log("error: \(message)") }
	log(usage)
	exit(2)
} catch {
	log("error: \(error)")
	exit(1)
}
