import AVFoundation
import CoreAudio
import Foundation

func processObject(for pid: pid_t) -> AudioObjectID? {
	var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
	var pid = pid
	var object = AudioObjectID(kAudioObjectUnknown)
	var size = UInt32(MemoryLayout<AudioObjectID>.size)
	let status = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
	return status == noErr && object != kAudioObjectUnknown ? object : nil
}

/// Writes tap buffers to a WAV on a serial queue and tracks the level.
final class TapRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private let file: AVAudioFile?
	private let format: AVAudioFormat
	private var lvl = Level()
	private var callbacks = 0
	private var firstNs: UInt64 = 0

	init(format: AVAudioFormat, url: URL) {
		self.format = format
		file = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
	}

	func receive(_ list: UnsafePointer<AudioBufferList>) {
		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
		let l = yapio.level(of: buffer)
		lock.withLock {
			if firstNs == 0 { firstNs = nowNs() }
			callbacks += 1
			lvl.sumSquares += l.sumSquares
			lvl.frames += l.frames
			lvl.peak = max(lvl.peak, l.peak)
		}
		try? file?.write(from: buffer)
	}

	var level: Level { lock.withLock { lvl } }
	var count: Int { lock.withLock { callbacks } }
	var first: UInt64 { lock.withLock { firstNs } }
}

enum TapTarget {
	case globalExcluding([AudioObjectID])
	case only([AudioObjectID])
	case bundleIDs([String])
}

struct TapResult {
	var created = false
	var level = Level()
	var callbacks = 0
	var firstCallbackMs: Double?
	var error: String?
}

/// Process tap → private aggregate device → IOProc. Returns the level of what was captured.
func captureTap(_ target: TapTarget, seconds: Double, url: URL, during: () -> Void = {}) -> TapResult {
	var result = TapResult()
	let description: CATapDescription
	switch target {
	case .globalExcluding(let objects): description = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
	case .only(let objects): description = CATapDescription(stereoMixdownOfProcesses: objects)
	case .bundleIDs(let ids):
		description = CATapDescription(stereoMixdownOfProcesses: [])
		description.bundleIDs = ids
	}
	description.name = "yapio-tap"
	description.isPrivate = true
	description.muteBehavior = .unmuted

	var tapID = AudioObjectID(kAudioObjectUnknown)
	var status = AudioHardwareCreateProcessTap(description, &tapID)
	guard status == noErr else {
		result.error = "AudioHardwareCreateProcessTap: \(osStatus(status))"
		return result
	}
	result.created = true
	defer { AudioHardwareDestroyProcessTap(tapID) }

	guard var asbd = getValue(tapID, address(kAudioTapPropertyFormat), AudioStreamBasicDescription()),
		let format = AVAudioFormat(streamDescription: &asbd)
	else {
		result.error = "could not read kAudioTapPropertyFormat"
		return result
	}
	print("    tap \(tapID) format: \(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved)")

	let outputUID = device(defaultDevice(input: false)).uid
	let aggregateUID = UUID().uuidString
	let aggregate: [String: Any] = [
		kAudioAggregateDeviceNameKey: "yapio-aggregate",
		kAudioAggregateDeviceUIDKey: aggregateUID,
		kAudioAggregateDeviceMainSubDeviceKey: outputUID,
		kAudioAggregateDeviceIsPrivateKey: true,
		kAudioAggregateDeviceIsStackedKey: false,
		kAudioAggregateDeviceTapAutoStartKey: true,
		kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
		kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
	]
	var aggregateID = AudioObjectID(kAudioObjectUnknown)
	status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
	guard status == noErr else {
		result.error = "AudioHardwareCreateAggregateDevice: \(osStatus(status))"
		return result
	}
	defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

	let recorder = TapRecorder(format: format, url: url)
	let queue = DispatchQueue(label: "yapio.tap", qos: .userInitiated)
	var procID: AudioDeviceIOProcID?
	status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
		recorder.receive(input)
	}
	guard status == noErr, let procID else {
		result.error = "AudioDeviceCreateIOProcIDWithBlock: \(osStatus(status))"
		return result
	}
	defer { AudioDeviceDestroyIOProcID(aggregateID, procID) }

	let startAt = nowNs()
	status = AudioDeviceStart(aggregateID, procID)
	guard status == noErr else {
		result.error = "AudioDeviceStart: \(osStatus(status))"
		return result
	}
	during()
	runLoop(for: seconds)
	AudioDeviceStop(aggregateID, procID)
	result.level = recorder.level
	result.callbacks = recorder.count
	if recorder.first != 0 { result.firstCallbackMs = msValue(recorder.first - startAt) }
	return result
}

func report(_ name: String, _ r: TapResult, url: URL) {
	if let e = r.error { print("  \(name): ERROR \(e)"); return }
	let first = r.firstCallbackMs.map { String(format: "%.1f ms", $0) } ?? "none"
	print("  \(name): callbacks \(r.callbacks), first after \(first), \(r.level.summary) -> \(url.lastPathComponent)")
}

/// Reads a WAV back from disk and prints overall and windowed levels, proving the file itself
/// is (or is not) silent.
func runWavStat(_ args: Args) {
	let window = args.double("window", 0.5)
	for path in args.raw.dropFirst() where !path.hasPrefix("--") && path.hasSuffix(".wav") {
		let url = URL(fileURLWithPath: path)
		guard let file = try? AVAudioFile(forReading: url),
			let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
			(try? file.read(into: buffer)) != nil
		else { print("\(path): unreadable"); continue }
		let rate = file.processingFormat.sampleRate
		print("\(url.lastPathComponent): \(String(format: "%.2f", Double(file.length) / rate)) s, \(rate) Hz, \(file.processingFormat.channelCount) ch, \(level(of: buffer).summary)")
		guard window > 0, let data = buffer.floatChannelData else { continue }
		let step = Int(rate * window)
		var line: [String] = []
		var start = 0
		while start < Int(buffer.frameLength) {
			let n = min(step, Int(buffer.frameLength) - start)
			var l = Level()
			for c in 0..<Int(buffer.format.channelCount) { l.add(UnsafeBufferPointer(start: data[c] + start, count: n)) }
			line.append(l.rms > 0 ? String(format: "%.0f", 20 * log10(l.rms)) : "-inf")
			start += step
		}
		print("  dBFS per \(window) s: \(line.joined(separator: " "))")
	}
}

@MainActor
func runSystemTap(_ args: Args) {
	print("== System audio (Core Audio process tap)")
	print("  bundle id: \(Bundle.main.bundleIdentifier ?? "nil"), NSAudioCaptureUsageDescription present: \(Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") != nil)")
	print("  TCCAccessPreflight(kTCCServiceAudioCapture) [SPI]: \(tccPreflight("kTCCServiceAudioCapture").map(String.init) ?? "unavailable") (0 granted, 1 denied, 2 unknown)")
	let seconds = args.double("seconds", 2.5)
	let sound = args.value("sound") ?? "/System/Library/Sounds/Glass.aiff"
	let selfObject = processObject(for: getpid())
	print("  own process object: \(selfObject.map(String.init) ?? "none (not an audio client yet)")")

	// 1. Global tap excluding ourselves, while afplay plays.
	let url1 = localDir.appendingPathComponent("\(args.value("name") ?? "tap-global").wav")
	var player: Process?
	let r1 = captureTap(.globalExcluding(selfObject.map { [$0] } ?? []), seconds: seconds, url: url1) {
		runLoop(for: 0.2)
		player = Children.shared.launch("/usr/bin/afplay", [sound])
	}
	player?.terminate()
	report("global tap (exclude self) + afplay", r1, url: url1)
	let globalSilent = r1.level.peak == 0
	if r1.error != nil || globalSilent {
		print("  RESULT: global capture \(r1.error != nil ? "failed" : "is silent") -> System Audio Recording permission missing or denied")
		if !args.flag("all") { return }
	}
	if args.flag("global-only") { return }

	// 2. Tap only afplay's process object (needs afplay to be an audio client first).
	let afplay = Children.shared.launch("/usr/bin/afplay", [sound, "-v", "1"])
	var afObject: AudioObjectID?
	runLoop(for: 1) {
		afObject = afplay.flatMap { processObject(for: $0.processIdentifier) }
		return afObject != nil
	}
	if let afObject {
		let url2 = localDir.appendingPathComponent("tap-only-afplay.wav")
		let r2 = captureTap(.only([afObject]), seconds: 1.0, url: url2)
		report("tap only afplay (object \(afObject))", r2, url: url2)
	} else {
		print("  afplay never showed up as an audio process object")
	}
	afplay?.terminate()

	// 3. Tap only our own (silent) process while afplay plays: should be silent.
	if let selfObject {
		let url3 = localDir.appendingPathComponent("tap-only-self.wav")
		var p: Process?
		let r3 = captureTap(.only([selfObject]), seconds: 1.5, url: url3) {
			p = Children.shared.launch("/usr/bin/afplay", [sound])
		}
		p?.terminate()
		report("tap only self while afplay plays (expect silent)", r3, url: url3)
	}

	// 4. macOS 26: tap by bundle id (e.g. us.zoom.xos). afplay has no bundle id, so use a
	// bundle id that is not running to show the tap can be created ahead of time.
	let url4 = localDir.appendingPathComponent("tap-bundle.wav")
	let r4 = captureTap(.bundleIDs(["us.zoom.xos"]), seconds: 0.5, url: url4)
	report("tap by bundle id us.zoom.xos (not running)", r4, url: url4)
	Children.shared.killAll()
}
