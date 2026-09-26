import Foundation

let usage = """
	usage: asr-bench <command> [--model v3|ultra] [--lang sv_se|en_us|codeswitch] [--hint sv|en] [--file path] [--terms a,b] [--offset n]

	  download    fetch the ASR model and the Silero VAD into .local/Models
	  load        load time, first-call latency, memory idle/after unload
	  bench       per-utterance latency, RTFx, WER, memory over a dataset
	  idle        latency after 0/5/30/90 s of idle
	  long        ~2 min sv clip: whole-after-release vs VAD-chunked streaming
	  vocab       dataset with and without CTC vocabulary boosting (--terms)
	  transcribe  one file (--file), for edge-case probes
	"""

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
	print(usage)
	exit(2)
}

do {
	let options = try Options(arguments.dropFirst(2))
	switch arguments[1] {
	case "download": try await runDownload(options)
	case "load": try await runLoad(options)
	case "bench": try await runBench(options)
	case "idle": try await runIdle(options)
	case "long": try await runLong(options)
	case "vocab": try await runVocab(options)
	case "transcribe": try await runTranscribe(options)
	default:
		print(usage)
		exit(2)
	}
} catch {
	print("error: \(error)")
	exit(1)
}
