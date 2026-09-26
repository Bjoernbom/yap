#if DEBUG
import AppKit
import AVFoundation
import Observation
import os
import YapKit

/// Checks the notes plumbing from inside the app bundle, the only place
/// system audio capture works (a bare CLI inherits its terminal's TCC identity
/// and records zeros). DEBUG builds only.
///
/// Debug menu: "Record system audio (5 s)" writes a WAV and logs RMS/peak;
/// "Watch for calls" logs `CallDetector` events until chosen again.
///
/// Launch arguments:
/// - `-YapNotesProbe <dir>` runs every probe below, writes `<dir>/notes-probe.txt`
///   and the WAVs, then quits (unless `-YapNotesProbeStay YES`). Dictation is
///   not started, so the speech model stays unloaded.
///
/// Probes: 5 s with `afplay Glass.aiff` (WAV read back from disk), nothing
/// playing, stop/start 10×, and yap's own sound (excluded by the default
/// target, captured by a tap on yap's pid as the control). The first run asks
/// for System Audio Recording; without it the WAV is silent and
/// `looksBlocked` says so. Logs: subsystem `com.bjornbom.yap`, category `notes-probe`.
@MainActor
@Observable
final class NotesProbe {
	static let shared = NotesProbe()

	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "notes-probe")
	private static let sound = "/System/Library/Sounds/Glass.aiff"

	private var directory: URL
	private var report: [String] = []
	private var busy = false
	private var detector: CallDetector?
	private var watcher: Task<Void, Never>?

	private init() {
		let path = UserDefaults.standard.string(forKey: "YapNotesProbe")
		directory = path.map { URL(filePath: $0) } ?? FileManager.default.temporaryDirectory.appending(path: "yap-notes-probe")
	}

	/// True when `-YapNotesProbe` is set; the app then skips dictation.
	static var isRequested: Bool { UserDefaults.standard.string(forKey: "YapNotesProbe") != nil }

	func applyLaunchArguments() {
		guard Self.isRequested else { return }
		Task {
			// Let the menu bar item and the run loop settle first.
			try? await Task.sleep(for: .milliseconds(500))
			await runAll()
			if !UserDefaults.standard.bool(forKey: "YapNotesProbeStay") {
				NSApp.terminate(nil)
			}
		}
	}

	// MARK: Menu actions

	func recordFromMenu() {
		Task { await recordFive(playing: false) }
	}

	var isWatchingCalls: Bool { watcher != nil }

	func toggleCallWatch() {
		if watcher != nil {
			stopWatchingCalls()
		} else {
			startWatchingCalls()
		}
	}

	// MARK: Probes

	private func runAll() async {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		note("bundle \(Bundle.main.bundleIdentifier ?? "nil"), pid \(getpid()), dir \(directory.path)")
		startWatchingCalls()
		await recordFive(playing: true)
		await nothingPlaying()
		await stopStart()
		await selfExclusion()
		stopWatchingCalls()
		note("done")
	}

	/// 5 s of system audio to a WAV, optionally with afplay starting 0.5 s in.
	private func recordFive(playing: Bool) async {
		guard !busy else { return note("busy, skipped") }
		busy = true
		defer { busy = false }
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appending(path: "system-audio-\(Int(Date().timeIntervalSince1970)).wav")
		note("-- record 5 s of system audio\(playing ? " while afplay plays Glass" : "") -> \(url.lastPathComponent)")
		let tap = SystemAudioTap()
		do {
			let writer = try WAVWriter(url: url)
			let stream = try await tap.start()
			let consumer = Task.detached { await writer.consume(stream) }
			var player: Process?
			if playing {
				try? await Task.sleep(for: .milliseconds(500))
				player = Self.play(Self.sound)
			}
			try? await Task.sleep(for: .seconds(1.5))
			let blocked = await tap.looksBlocked
			try? await Task.sleep(for: .seconds(playing ? 3 : 3.5))
			let stats = await tap.statistics
			await tap.stop()
			player?.terminate()
			let written = await consumer.value
			note("stats: \(describe(stats)), looksBlocked=\(blocked), chunks \(written.chunks), gaps \(written.gaps)")
			note("read back: \(WAVWriter.levels(of: url))")
		} catch {
			note("failed: \(error)")
		}
	}

	private func nothingPlaying() async {
		note("-- nothing playing, 3 s (other apps' output: \(othersPlaying()))")
		let tap = SystemAudioTap()
		do {
			let stream = try await tap.start()
			let consumer = Task.detached { await stream.reduce(into: (0, Float(0))) { $0.0 += $1.samples.count; $0.1 = max($0.1, $1.samples.map(abs).max() ?? 0) } }
			try? await Task.sleep(for: .seconds(3))
			let stats = await tap.statistics
			await tap.stop()
			let (samples, peak) = await consumer.value
			note("stats: \(describe(stats)), samples \(samples), chunk peak \(peak)")
		} catch {
			note("failed: \(error)")
		}
	}

	private func stopStart() async {
		note("-- stop/start 10x, afplay playing")
		let tap = SystemAudioTap()
		let player = Self.play(Self.sound)
		var failures = 0
		var samples: [Int] = []
		let start = ContinuousClock.now
		for _ in 0..<10 {
			do {
				let stream = try await tap.start()
				let consumer = Task.detached { await stream.reduce(0) { $0 + $1.samples.count } }
				try? await Task.sleep(for: .milliseconds(100))
				await tap.stop()
				samples.append(await consumer.value)
			} catch {
				failures += 1
				note("cycle failed: \(error)")
			}
		}
		player?.terminate()
		note("10 cycles in \(start.duration(to: .now)), failures \(failures), samples per cycle \(samples), capturing after: \(await tap.isCapturing)")
	}

	/// yap plays Glass itself. The default tap excludes yap, so it should hear
	/// nothing; a tap on yap's own pid is the control and should hear it.
	private func selfExclusion() async {
		for (label, target) in [("default target (excludes yap)", SystemAudioTap.Target.systemOutput), ("control: only yap's pid", .processes([getpid()]))] {
			note("-- yap plays Glass itself, \(label)")
			let tap = SystemAudioTap(target: target)
			do {
				let stream = try await tap.start()
				let consumer = Task.detached { await stream.reduce(Float(0)) { max($0, $1.samples.map(abs).max() ?? 0) } }
				try? await Task.sleep(for: .milliseconds(300))
				let sound = NSSound(contentsOfFile: Self.sound, byReference: true)
				sound?.play()
				try? await Task.sleep(for: .seconds(2))
				sound?.stop()
				let stats = await tap.statistics
				await tap.stop()
				note("stats: \(describe(stats)), chunk peak \(await consumer.value)")
			} catch {
				note("failed: \(error)")
			}
		}
	}

	// MARK: Calls

	private func startWatchingCalls() {
		guard watcher == nil else { return }
		let detector = CallDetector()
		self.detector = detector
		note("-- watching for calls")
		watcher = Task { [weak self] in
			for await event in await detector.events() {
				switch event {
				case .started(let app): self?.note("call started: \(app.name) (call app: \(app.isCallApp), might be a call: \(app.mightBeCall))")
				case .ended: self?.note("call ended")
				}
			}
		}
	}

	private func stopWatchingCalls() {
		watcher?.cancel()
		watcher = nil
		let detector = self.detector
		self.detector = nil
		Task { await detector?.stop() }
		note("-- stopped watching for calls")
	}

	// MARK: Helpers

	private func note(_ line: String) {
		Self.log.notice("\(line, privacy: .public)")
		report.append(line)
		guard Self.isRequested else { return }
		try? (report.joined(separator: "\n") + "\n").write(to: directory.appending(path: "notes-probe.txt"), atomically: true, encoding: .utf8)
	}

	private func describe(_ s: SystemAudioTap.Statistics) -> String {
		let first = s.firstCallbackDelay.map { String(format: "%.0f ms", $0 * 1000) } ?? "none"
		return "callbacks \(s.callbacks), audible \(s.audibleCallbacks), peak \(s.peak), first callback \(first), rate \(s.sampleRate), dropped \(s.droppedFrames)"
	}

	private func othersPlaying() -> [String] {
		AudioProcess.all().filter { $0.isRunningOutput && $0.pid != getpid() }.map { $0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID }
	}

	private static func play(_ path: String) -> Process? {
		let process = Process()
		process.executableURL = URL(filePath: "/usr/bin/afplay")
		process.arguments = [path]
		do {
			try process.run()
			return process
		} catch {
			return nil
		}
	}
}

/// Writes 16 kHz mono chunks to a Float32 WAV off the main actor.
private final class WAVWriter: @unchecked Sendable {
	// Only used from the one detached consumer task.
	private let file: AVAudioFile

	init(url: URL) throws {
		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: AudioChunk.sampleRate,
			AVNumberOfChannelsKey: 1,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
		]
		file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
	}

	/// Counts gaps (host-time jumps over 50 ms) too: silence without callbacks.
	func consume(_ stream: AsyncStream<AudioChunk>) async -> (chunks: Int, gaps: Int) {
		var chunks = 0
		var gaps = 0
		var expected: UInt64?
		for await chunk in stream {
			chunks += 1
			if let expected, HostClock.milliseconds(from: expected, to: chunk.hostTime) > 50 { gaps += 1 }
			expected = chunk.hostTime &+ HostClock.ticks(seconds: chunk.duration)
			guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
				let channel = buffer.floatChannelData?[0]
			else { continue }
			chunk.samples.withUnsafeBufferPointer { if let base = $0.baseAddress { channel.update(from: base, count: $0.count) } }
			buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
			try? file.write(from: buffer)
		}
		// Finalizes the WAV header, so the file can be read back right away.
		file.close()
		return (chunks, gaps)
	}

	/// Reads the WAV back from disk, so a non-silent result is about the file.
	static func levels(of url: URL) -> String {
		guard let file = try? AVAudioFile(forReading: url),
			let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1))),
			(try? file.read(into: buffer)) != nil,
			let data = buffer.floatChannelData?[0]
		else { return "unreadable" }
		let samples = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
		let seconds = Double(samples.count) / file.processingFormat.sampleRate
		func dbfs(_ slice: UnsafeBufferPointer<Float>.SubSequence) -> String {
			guard !slice.isEmpty else { return "-inf" }
			let rms = (slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
			return rms > 0 ? String(format: "%.1f", 20 * log10(rms)) : "-inf"
		}
		let peak = samples.map(abs).max() ?? 0
		let window = Int(file.processingFormat.sampleRate / 2)
		let windows = stride(from: 0, to: samples.count, by: window).map { dbfs(samples[$0..<min($0 + window, samples.count)]) }
		return String(format: "%.2f s at %.0f Hz, RMS %@ dBFS, peak %.4f (%@ dBFS); per 0.5 s: %@",
			seconds, file.processingFormat.sampleRate, dbfs(samples[...]), peak, peak > 0 ? String(format: "%.1f", 20 * log10(peak)) : "-inf", windows.joined(separator: " "))
	}
}
#endif
