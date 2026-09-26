import Foundation

let usage = """
	usage: yap-bench <command> [options]

	  prepare [--concurrent]      download, load and compile the model
	  transcribe <audio>          one file in one engine call
	      --idle <s>              wait this long after the warm-up before the call
	  stream <audio>              feed a file through StreamingTranscriber like a live mic
	      --speed <x>             playback speed, 1 = real time (default), 0 = as fast as possible
	      --piece-ms <ms>         size of each append (default 100)
	      --max-chunk <s>         chunk ceiling (default 10), to force cuts inside sentences
	      --soft-chunk <s>        cut at a short dip from this length (default 4)
	      --overlap <s>           overlap around a cut inside speech (default 1, 0 = none)
	      --keep-warm <s>         warm-up interval while no chunk runs (default 0.75, 0 = off)
	      --cancel-after <s>      cancel after this much audio (probe)
	      --finish-twice          call finish() twice (probe)
	  memory                      idle footprint + Neural Engine memory with the model warm
	  text "<transcript>"         run the text pipeline: cleanup, dictionary, polish, style
	      --app <bundle-id>       the focused app, which picks the style
	      --style <name>          natural|casual|proper|dev, instead of the app's
	      --all-styles            one run per style
	      --polish                turn polish on (needs Apple Intelligence)
	      --dictionary <json>     dictionary entries: [{"id","spoken","written"}]
	  diarize <audio>             run the notes diarizer on a file, as after a meeting
	      --loops <n>             repeat the file n times, to time long meetings (default 1)

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
	case "text": try await runText(options)
	case "diarize": try await runDiarize(options)
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
