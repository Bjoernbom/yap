import Foundation

// yapio: M0-IO spike. One CLI, one subcommand per topic. See docs/spikes/io.md.

let usage = """
usage: yapio <command> [options]
  perms     [--request]                         permission status (+ one-shot prompts)
  hotkey    [--active] [--selftest] [--seconds N]   CGEventTap for Fn / right ⌥, double-tap, Esc
  mic       [--runs N] [--only-vp] [--vp-variant none|mixer|match|...+noduck+lateduck]
            [--builtin | --device ID] [--record S --vp --name X]   AVAudioEngine latency / recording
  systap    [--seconds S] [--sound path] [--all] [--global-only --name X]   process tap -> .local/*.wav
  calls     [--demo | --seconds N] [--poll] [--verbose]   who uses the mic (call detection)
  insert    [--runs N] [--secure-demo] [--pasteboard-only] [--focused --delay S]   AX / ⌘V insertion
  devices   [--pin-test [--device ID]]          input devices, transport, pinning
  wavstat   <file.wav>... [--window S]          levels read back from a WAV file
"""

setvbuf(stdout, nil, _IOLBF, 0)

signal(SIGINT) { _ in
	Children.shared.killAll()
	exit(130)
}

let argv = Array(CommandLine.arguments.dropFirst())
let args = Args(raw: argv)
MainActor.assumeIsolated {
	switch argv.first {
	case "perms": runPerms(args)
	case "hotkey": runHotkey(args)
	case "mic": runMic(args)
	case "systap": runSystemTap(args)
	case "calls": runCalls(args)
	case "insert": runInsert(args)
	case "devices": runDevices(args)
	case "wavstat": runWavStat(args)
	default: print(usage)
	}
}
Children.shared.killAll()
