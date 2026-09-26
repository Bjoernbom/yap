import Foundation

// yapio: M0-IO spike. One CLI, one subcommand per topic. See docs/spikes/io.md.

let usage = """
usage: yapio <command> [options]
  perms     [--request]                         permission status (+ one-shot prompts)
  hotkey    [--active] [--selftest] [--seconds N]   CGEventTap for Fn / right ⌥, double-tap, Esc
  mic       [--runs N] [--builtin] [--record S --vp --name X]   AVAudioEngine latency / recording
  systap    [--seconds S] [--sound path] [--all]   Core Audio process tap -> .local/*.wav
  calls     [--demo | --seconds N] [--verbose]  who uses the mic (call detection)
  insert    [--runs N] [--secure-demo] [--pasteboard-only]   AX / ⌘V insertion into TextEdit
  devices   [--pin-test]                        input devices, transport, pinning
"""

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
	default: print(usage)
	}
}
Children.shared.killAll()
