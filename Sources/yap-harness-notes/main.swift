// Dev harness for the notes plumbing: CallDetector and SystemAudioTap on
// this Mac, through the public YapKit API.
//
//   swift run yap-harness-notes calls        # call detection with a child recorder
//   swift run yap-harness-notes watch 30     # print call events for 30 s (start a call)
//   swift run yap-harness-notes tap          # system tap from the CLI (see below)
//   swift run yap-harness-notes record-mic 4 # child mode: hold the mic for 4 s
//   swift run yap-harness-notes processes    # audio clients running input or output
//
// Call detection needs no permission. System audio does, and a bare CLI
// inherits its terminal's TCC identity, so `tap` here captures zeros; that is
// what `looksBlocked` is for. The real capture check runs in the Debug app
// (`-YapNotesProbe`, App/Sources/Debug/NotesProbe.swift).

import AVFoundation
import Foundation
import YapKit

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "calls"
let harnessStart = HostClock.now()

func elapsed(_ hostTime: UInt64 = HostClock.now()) -> String {
	String(format: "+%7.0f ms", HostClock.milliseconds(from: harnessStart, to: hostTime))
}

func say(_ line: String) {
	print("\(elapsed())  \(line)")
	fflush(stdout)
}

func nap(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

// MARK: record-mic (child)

/// Holds the mic for `seconds`, printing the host times of mic live and mic
/// off so the parent can measure detection latency on the same clock.
func recordMic(seconds: Double) async {
	let mic = MicCapture()
	do {
		try await mic.prepare()
		let stream = try await mic.start()
		let consumer = Task { () -> (UInt64?, Int) in
			var first: UInt64?
			var samples = 0
			for await chunk in stream {
				if first == nil { first = chunk.hostTime }
				samples += chunk.samples.count
			}
			return (first, samples)
		}
		await nap(seconds)
		await mic.stop()
		let off = HostClock.now()
		let (first, samples) = await consumer.value
		print("MIC_LIVE \(first ?? 0)")
		print("MIC_OFF \(off)")
		print("SAMPLES \(samples)")
	} catch {
		print("MIC_ERROR \(error)")
	}
}

// MARK: calls

struct ChildRun {
	var live: UInt64?
	var off: UInt64?
	var samples = 0
}

func runChild(seconds: Double) async -> ChildRun {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
	process.arguments = ["record-mic", String(seconds)]
	let pipe = Pipe()
	process.standardOutput = pipe
	do { try process.run() } catch {
		say("could not launch child: \(error)")
		return ChildRun()
	}
	say("child pid \(process.processIdentifier) launched, records \(seconds) s")
	while process.isRunning { await nap(0.05) }
	var run = ChildRun()
	let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
	for line in output.split(separator: "\n") {
		let parts = line.split(separator: " ")
		guard parts.count == 2 else { continue }
		switch parts[0] {
		case "MIC_LIVE": run.live = UInt64(parts[1])
		case "MIC_OFF": run.off = UInt64(parts[1])
		case "SAMPLES": run.samples = Int(parts[1]) ?? 0
		default: say("child: \(line)")
		}
	}
	if let live = run.live, let off = run.off {
		say("child mic live at \(elapsed(live)), off at \(elapsed(off)) (\(run.samples) samples)")
	}
	return run
}

final class EventLog: @unchecked Sendable {
	private let lock = NSLock()
	private var events: [(UInt64, CallEvent)] = []
	func add(_ event: CallEvent) { lock.withLock { events.append((HostClock.now(), event)) } }
	func take() -> [(UInt64, CallEvent)] { lock.withLock { defer { events = [] }; return events } }
}

func describe(_ event: CallEvent) -> String {
	switch event {
	case .started(let app): "started(\(app.name), callApp=\(app.isCallApp), mightBeCall=\(app.mightBeCall))"
	case .ended: "ended"
	}
}

func runCalls() async {
	let detector = CallDetector()
	let log = EventLog()
	let stream = await detector.events()
	let listener = Task {
		for await event in stream {
			log.add(event)
			say("EVENT \(describe(event))")
		}
	}
	await nap(0.5)
	let before = log.take()
	if !before.isEmpty { say("note: \(before.count) event(s) before the test (another app is recording)") }
	let others = await detector.recorders
	say("recorders at start: \(others.map { "\($0.pid) \($0.app.name)" })")

	var pass = true
	for (seconds, expectCall) in [(4.5, true), (1.5, false), (5.0, true)] {
		say("--- child records \(seconds) s, expect \(expectCall ? "a call" : "no event")")
		let run = await runChild(seconds: seconds)
		// Wait out the end grace plus a margin.
		await nap(2.0)
		let events = log.take()
		let started = events.first { if case .started = $0.1 { true } else { false } }
		let ended = events.first { $0.1 == .ended }
		if expectCall {
			guard let started, let ended, let live = run.live, let off = run.off else {
				say("FAIL: expected started + ended, got \(events.map { describe($0.1) })")
				pass = false
				continue
			}
			say(String(format: "started %.0f ms after mic live (minimum 3000), ended %.0f ms after mic off (grace 1000)",
				HostClock.milliseconds(from: live, to: started.0), HostClock.milliseconds(from: off, to: ended.0)))
		} else if !events.isEmpty {
			say("FAIL: expected no event, got \(events.map { describe($0.1) })")
			pass = false
		} else {
			say("no event, as expected")
		}
	}
	await detector.stop()
	listener.cancel()
	say(pass ? "RESULT: pass" : "RESULT: FAIL")
}

func runWatch(seconds: Double) async {
	let detector = CallDetector()
	let stream = await detector.events()
	let listener = Task {
		for await event in stream { say("EVENT \(describe(event))") }
	}
	say("watching \(Int(seconds)) s: start a call or any recorder")
	await nap(seconds)
	await detector.stop()
	listener.cancel()
}

// MARK: tap

/// From a bare CLI the tap captures zeros (no TCC identity of its own), so
/// this checks the plumbing and the looksBlocked heuristic, not the audio.
func runTap() async {
	let tap = SystemAudioTap()
	say("-- nothing playing (unless something else is): 2 s")
	do {
		let stream = try await tap.start()
		let consumer = Task { await stream.reduce(0) { $0 + $1.samples.count } }
		await nap(2)
		let quiet = await tap.statistics
		await tap.stop()
		say("callbacks \(quiet.callbacks), samples \(await consumer.value), rate \(quiet.sampleRate)")
	} catch {
		say("start failed: \(error)")
		return
	}

	say("-- afplay Glass.aiff during 3 s")
	do {
		let stream = try await tap.start()
		let consumer = Task { await stream.reduce(0) { $0 + $1.samples.count } }
		await nap(0.2)
		let player = Process()
		player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
		player.arguments = ["/System/Library/Sounds/Glass.aiff"]
		try? player.run()
		await nap(1.0)
		let blocked = await tap.looksBlocked
		await nap(1.8)
		let stats = await tap.statistics
		await tap.stop()
		if player.isRunning { player.terminate() }
		say("callbacks \(stats.callbacks), audible \(stats.audibleCallbacks), peak \(stats.peak), first callback \(stats.firstCallbackDelay.map { String(format: "%.0f ms", $0 * 1000) } ?? "none"), samples \(await consumer.value), looksBlocked \(blocked)")
	} catch {
		say("start failed: \(error)")
	}

	say("-- stop/start 10x")
	var failures = 0
	let t0 = HostClock.now()
	for _ in 0..<10 {
		do {
			let stream = try await tap.start()
			let consumer = Task { await stream.reduce(0) { $0 + $1.samples.count } }
			await nap(0.1)
			await tap.stop()
			_ = await consumer.value
		} catch {
			failures += 1
		}
	}
	say(String(format: "10 cycles in %.0f ms, %d failures, capturing after: %@", HostClock.milliseconds(from: t0, to: HostClock.now()), failures, String(await tap.isCapturing)))
}

switch command {
case "processes":
	for process in AudioProcess.all() where process.isRunningInput || process.isRunningOutput {
		print("pid \(process.pid) \(process.bundleID.isEmpty ? AudioProcess.executablePath(of: process.pid) ?? "?" : process.bundleID) input=\(process.isRunningInput) output=\(process.isRunningOutput)")
	}
case "record-mic":
	await recordMic(seconds: args.dropFirst().first.flatMap(Double.init) ?? 3)
case "watch":
	await runWatch(seconds: args.dropFirst().first.flatMap(Double.init) ?? 30)
case "tap":
	await runTap()
default:
	await runCalls()
}
