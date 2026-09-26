// Dev harness for MicCapture. Runs the real capture on this Mac and prints
// latency, levels, cadence, mic-in-use state and probe results.
//
//   swift run yap-harness-mic            # everything
//   swift run yap-harness-mic --no-say   # don't play speech from the speakers
//
// The WAV goes to .build/yap-harness-mic/ (gitignored).

import AVFoundation
import CoreAudio
import Foundation
import YapKit

let args = CommandLine.arguments
let playSpeech = !args.contains("--no-say")
let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/yap-harness-mic")

// MARK: Helpers

func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }

func stats(_ values: [Double]) -> String {
	guard !values.isEmpty else { return "n/a" }
	let sorted = values.sorted()
	let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
	return String(format: "min %.1f / median %.1f / p95 %.1f / max %.1f ms (n=%d)", sorted[0], sorted[sorted.count / 2], p95, sorted[sorted.count - 1], sorted.count)
}

func nap(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

/// Whether this process has input IO running, per Core Audio's process object.
/// This is what the menu bar's orange mic indicator reflects.
func processIsRunningInput() -> Bool? {
	var pid = getpid()
	var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
	var object = AudioObjectID(0)
	var size = UInt32(MemoryLayout<AudioObjectID>.size)
	guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr, object != 0 else { return nil }
	address.mSelector = kAudioProcessPropertyIsRunningInput
	var running = UInt32(0)
	size = UInt32(MemoryLayout<UInt32>.size)
	guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else { return nil }
	return running != 0
}

func micState(_ device: AudioInputDevice?) -> String {
	let deviceRunning = device.map { DevicePolicy.isRunningSomewhere($0.id) }
	let process = processIsRunningInput()
	return "device running somewhere=\(deviceRunning.map(String.init) ?? "?"), this process running input=\(process.map(String.init) ?? "?")"
}

func footprintMB() -> Double {
	var info = task_vm_info_data_t()
	var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
	let status = withUnsafeMutablePointer(to: &info) {
		$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
	}
	return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

struct Take {
	var chunks: [AudioChunk] = []
	var arrivals: [UInt64] = []
	var finished = false
	var samples: [Float] { chunks.flatMap(\.samples) }
}

/// Collects a stream in the background; `finished` flips when the stream ends.
final class Collector: @unchecked Sendable {
	private let lock = NSLock()
	private var take = Take()
	private var task: Task<Void, Never>?

	init(_ stream: AsyncStream<AudioChunk>) {
		task = Task.detached { [self] in
			for await chunk in stream {
				let now = HostClock.now()
				lock.withLock {
					take.chunks.append(chunk)
					take.arrivals.append(now)
				}
			}
			lock.withLock { take.finished = true }
		}
	}

	var snapshot: Take { lock.withLock { take } }

	/// Waits for the stream to end, up to `timeout` seconds.
	func finish(timeout: Double = 2) async -> Take {
		let deadline = Date().addingTimeInterval(timeout)
		while !snapshot.finished, Date() < deadline { await nap(0.005) }
		return snapshot
	}
}

func writeWav(_ samples: [Float], to url: URL) throws {
	guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
		let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
		let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
	buffer.frameLength = AVAudioFrameCount(samples.count)
	samples.withUnsafeBufferPointer { src in
		if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
	}
	try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
	let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
	try file.write(from: buffer)
}

func readWav(_ url: URL) throws -> (samples: [Float], rate: Double) {
	let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
	guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return ([], 0) }
	try file.read(into: buffer)
	guard let channel = buffer.floatChannelData?[0] else { return ([], 0) }
	return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
}

func level(_ samples: [Float]) -> String {
	let l = AudioLevel(samples)
	return String(format: "RMS %.1f dBFS, peak %.1f dBFS", l.rmsDBFS, l.peakDBFS)
}

// MARK: Setup

print("== yap-harness-mic")
let harnessStart = HostClock.now()
// Log every engine configuration change, so restarts in the output can be
// traced to what caused them.
let configLog = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { note in
	let engine = note.object.map { String(UInt(bitPattern: ObjectIdentifier($0 as AnyObject).hashValue), radix: 16) } ?? "nil"
	print(String(format: "    [config change at %.3f s, engine %@]", HostClock.milliseconds(from: harnessStart, to: HostClock.now()) / 1000, engine))
}
let permission: String = switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized: "authorized"
case .denied: "denied"
case .restricted: "restricted"
case .notDetermined: "not determined"
@unknown default: "unknown"
}
print("mic permission: \(permission)")
let devices = DevicePolicy.inputDevices()
let defaultID = DevicePolicy.defaultInputDeviceID()
for d in devices {
	print("  input \(d.id) '\(d.name)' \(d.transport) ch=\(d.inputChannels) \(Int(d.nominalSampleRate)) Hz uid=\(d.uid)\(d.id == defaultID ? " [default]" : "")")
}
let policyChoice = DevicePolicy.resolve(preferredUID: nil)
print("policy picks: \(policyChoice.map { "\($0.id) '\($0.name)'" } ?? "none")")

// MARK: 1. Prepare and the mic indicator

print("\n-- 1. prepare() and mic-in-use")
print("before prepare: \(micState(policyChoice))")
let mic = MicCapture()
var t = HostClock.now()
do {
	try await mic.prepare()
} catch {
	print("prepare failed: \(error)")
	exit(1)
}
print("prepare(): \(ms(HostClock.milliseconds(from: t, to: HostClock.now()))), pinned to \(await mic.device.map { "\($0.id) '\($0.name)'" } ?? "system default")")
await nap(0.5)
print("prepared, not started: \(micState(policyChoice))")

// MARK: 2. Key-down latency, prepared

print("\n-- 2. key-down -> first sample, 5 presses (prepared)")
var live: [Double] = []
var returned: [Double] = []
var delivered: [Double] = []
for press in 1...5 {
	let t0 = HostClock.now()
	let stream = try await mic.start()
	let tReturn = HostClock.now()
	let collector = Collector(stream)
	await nap(0.2)
	let during = micState(policyChoice)
	await nap(0.3)
	await mic.stop()
	let take = await collector.finish()
	guard let first = take.chunks.first, let firstArrival = take.arrivals.first else {
		print("  press \(press): no audio (finished=\(take.finished))")
		continue
	}
	let l = HostClock.milliseconds(from: t0, to: first.hostTime)
	let r = HostClock.milliseconds(from: t0, to: tReturn)
	let d = HostClock.milliseconds(from: t0, to: firstArrival)
	live.append(l)
	returned.append(r)
	delivered.append(d)
	await nap(0.3)
	print("  press \(press): start() returned \(ms(r)), mic live \(ms(l)), first chunk delivered \(ms(d)), \(take.chunks.count) chunks, finished=\(take.finished)")
	if press == 1 { print("    while capturing: \(during)") }
	if press == 1 { print("    after stop: \(micState(policyChoice))") }
}
print("  mic live (first sample host time - key down): \(stats(live))")
print("  start() returned:                           \(stats(returned))")
print("  first chunk delivered:                      \(stats(delivered))")

// MARK: 3. Record 3 s, WAV round trip, cadence

print("\n-- 3. record 3 s\(playSpeech ? " (say playing from the speakers)" : "")")
var say: Process?
if playSpeech {
	let p = Process()
	p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
	p.arguments = ["Testing the yap microphone. One, two, three, four, five, six, seven."]
	try? p.run()
	say = p
	await nap(0.3)
}
let recordStream = try await mic.start()
let recorder = Collector(recordStream)
await nap(3)
await mic.stop()
let take = await recorder.finish()
say?.terminate()
let samples = take.samples
let wav = outputDir.appendingPathComponent("mic-3s.wav")
do {
	try writeWav(samples, to: wav)
	let (back, rate) = try readWav(wav)
	print("  wrote \(wav.path): \(String(format: "%.2f", Double(samples.count) / 16_000)) s")
	print("  read back: \(back.count) samples @ \(Int(rate)) Hz, \(level(back))\(AudioLevel(back).rmsDBFS < -70 ? "  <-- SILENT" : "")")
} catch {
	print("  WAV round trip failed: \(error)")
}
let gaps = zip(take.arrivals.dropFirst(), take.arrivals).map { HostClock.milliseconds(from: $1, to: $0) }
let durations = take.chunks.map { $0.duration * 1000 }
print("  chunk cadence (arrival to arrival): \(stats(gaps))")
print("  chunk duration:                     \(stats(durations))")
// Host-time continuity: each chunk should start where the previous one ended.
let jitter = zip(take.chunks.dropFirst(), take.chunks).map { next, prev in
	HostClock.milliseconds(from: prev.hostTime, to: next.hostTime) - prev.duration * 1000
}
print("  host-time continuity error: max |\(ms(jitter.map(abs).max() ?? 0))|")
print("  stream finished: \(take.finished)")

await nap(0.3)
print("\n-- 4. prepared but stopped: \(micState(policyChoice))")

// MARK: 5. Probes

print("\n-- 5. probes")
let before = footprintMB()
var unfinished = 0
var rapidChunks = 0
for i in 0..<20 {
	let stream = try await mic.start()
	let collector = Collector(stream)
	await nap(Double(i % 4) * 0.01)
	await mic.stop()
	let take = await collector.finish()
	if !take.finished { unfinished += 1 }
	rapidChunks += take.chunks.count
}
await nap(0.3)
print(String(format: "  20x rapid start/stop: unfinished streams %d, chunks %d, footprint %.1f -> %.1f MB, capturing=%@", unfinished, rapidChunks, before, footprintMB(), String(await mic.isCapturing)))

let fresh = MicCapture()
await fresh.stop()
print("  stop without start: returned, capturing=\(await fresh.isCapturing)")

let first = try await mic.start()
let firstCollector = Collector(first)
do {
	_ = try await mic.start()
	print("  start twice: second start succeeded (unexpected)")
} catch {
	print("  start twice: second start threw \(error)")
}
await mic.stop()
print("  start twice: first stream finished=\(await firstCollector.finish().finished)")

// Abandoning the stream should turn the mic off too.
do {
	let stream = try await mic.start()
	let task = Task { for await _ in stream {} }
	await nap(0.2)
	task.cancel()
	await nap(0.3)
	print("  consumer cancelled: capturing=\(await mic.isCapturing), \(micState(policyChoice))")
}

// Device change mid-capture, through the same path a real notification takes.
do {
	let stream = try await mic.start()
	let collector = Collector(stream)
	await nap(0.5)
	await mic.simulateConfigurationChange()
	await nap(1)
	let mid = await mic.isCapturing
	await mic.stop()
	let take = await collector.finish()
	let hostGaps = zip(take.chunks.dropFirst(), take.chunks).map { next, prev in
		HostClock.milliseconds(from: prev.hostTime, to: next.hostTime) - prev.duration * 1000
	}
	print(String(format: "  config change mid-capture: restarts %d, still capturing after %@, %.2f s of audio in 1.5 s, largest host-time gap %.1f ms, finished=%@",
		await mic.restartsInLastCapture, String(mid), Double(take.samples.count) / 16_000, hostGaps.max() ?? 0, String(take.finished)))
}

// Pin to a non-built-in input if one exists (virtual devices are safe to open;
// iPhone Continuity would wake the phone, so it is skipped).
if let external = devices.first(where: { $0.transport != .builtIn && $0.transport != .continuity && $0.transport != .unknown && !$0.transport.isBluetooth }) {
	let pinned = MicCapture(preferredDeviceUID: external.uid)
	do {
		try await pinned.prepare()
		let stream = try await pinned.start()
		let collector = Collector(stream)
		await nap(0.5)
		let targetRunning = DevicePolicy.isRunningSomewhere(external.id)
		let builtInRunning = policyChoice.map { DevicePolicy.isRunningSomewhere($0.id) }
		await pinned.stop()
		let take = await collector.finish()
		print("  pinned to \(external.id) '\(external.name)' (\(external.transport)): engine device \(await pinned.device.map { "\($0.id)" } ?? "?"), target running=\(targetRunning), built-in running=\(builtInRunning.map(String.init) ?? "?"), \(take.chunks.count) chunks, \(level(take.samples)), default unchanged=\(DevicePolicy.defaultInputDeviceID() == defaultID)")
	} catch {
		print("  pin to '\(external.name)' failed: \(error)")
	}
} else {
	print("  no external/virtual input to pin to")
}

print("\ndone")
