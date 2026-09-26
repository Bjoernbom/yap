import AVFoundation
import CoreAudio
import Foundation

// MARK: - Time

/// Monotonic nanoseconds (same clock as `DispatchTime` / `mach_absolute_time`, converted).
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func ms(_ ns: UInt64) -> String { String(format: "%.1f ms", Double(ns) / 1_000_000) }
func msValue(_ ns: UInt64) -> Double { Double(ns) / 1_000_000 }

/// Spins the current run loop (so taps, listeners and pasteboard providers fire) until
/// `condition` returns true or `timeout` seconds pass. Returns whether the condition was met.
@discardableResult
func runLoop(for timeout: Double, until condition: () -> Bool = { false }) -> Bool {
	let deadline = Date().addingTimeInterval(timeout)
	while Date() < deadline {
		if condition() { return true }
		RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
	}
	return condition()
}

func stats(_ values: [Double]) -> String {
	guard !values.isEmpty else { return "n/a" }
	let sorted = values.sorted()
	let median = sorted[sorted.count / 2]
	return String(format: "min %.1f / median %.1f / max %.1f ms (n=%d)", sorted.first!, median, sorted.last!, values.count)
}

// MARK: - Paths

let localDir: URL = {
	let url = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent(".local")
	try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}()

// MARK: - Args

struct Args {
	let raw: [String]
	func flag(_ name: String) -> Bool { raw.contains("--\(name)") }
	func value(_ name: String) -> String? {
		guard let i = raw.firstIndex(of: "--\(name)"), i + 1 < raw.count else { return nil }
		return raw[i + 1]
	}
	func double(_ name: String, _ fallback: Double) -> Double { value(name).flatMap(Double.init) ?? fallback }
	func int(_ name: String, _ fallback: Int) -> Int { value(name).flatMap(Int.init) ?? fallback }
}

// MARK: - Core Audio property helpers

func address(
	_ selector: AudioObjectPropertySelector,
	_ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
	_ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
	AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func getValue<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
	var addr = addr
	var value = initial
	var size = UInt32(MemoryLayout<T>.size)
	let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
	return status == noErr ? value : nil
}

func getArray<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) -> [T] {
	var addr = addr
	var size: UInt32 = 0
	guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
	var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
	guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &values) == noErr else { return [] }
	return values
}

func getString(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
	var addr = addr
	var value: Unmanaged<CFString>?
	var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
	guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
	return value.takeRetainedValue() as String
}

func fourCC(_ value: UInt32) -> String {
	let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
	if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
	return String(value)
}

func osStatus(_ status: OSStatus) -> String {
	status == noErr ? "noErr" : "\(status) ('\(fourCC(UInt32(bitPattern: status)))')"
}

// MARK: - Devices

struct AudioDevice {
	let id: AudioDeviceID
	let name: String
	let uid: String
	let transport: UInt32
	let inputChannels: Int
	let outputChannels: Int
	let sampleRate: Double

	var transportName: String {
		switch transport {
		case kAudioDeviceTransportTypeBuiltIn: "built-in"
		case kAudioDeviceTransportTypeBluetooth: "bluetooth"
		case kAudioDeviceTransportTypeBluetoothLE: "bluetooth-le"
		case kAudioDeviceTransportTypeUSB: "usb"
		case kAudioDeviceTransportTypeVirtual: "virtual"
		case kAudioDeviceTransportTypeAggregate: "aggregate"
		case kAudioDeviceTransportTypeAirPlay: "airplay"
		case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "continuity"
		case kAudioDeviceTransportTypeDisplayPort: "displayport"
		case kAudioDeviceTransportTypeHDMI: "hdmi"
		case kAudioDeviceTransportTypeUnknown: "unknown"
		default: fourCC(transport)
		}
	}
}

func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
	var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
	var size: UInt32 = 0
	guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
	let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
	defer { raw.deallocate() }
	guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
	let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
	return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func device(_ id: AudioDeviceID) -> AudioDevice {
	AudioDevice(
		id: id,
		name: getString(id, address(kAudioObjectPropertyName)) ?? "?",
		uid: getString(id, address(kAudioDevicePropertyDeviceUID)) ?? "?",
		transport: getValue(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0,
		inputChannels: channelCount(id, kAudioObjectPropertyScopeInput),
		outputChannels: channelCount(id, kAudioObjectPropertyScopeOutput),
		sampleRate: getValue(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
	)
}

func allDevices() -> [AudioDevice] {
	getArray(systemObject, address(kAudioHardwarePropertyDevices), AudioDeviceID(0)).map(device)
}

func defaultDevice(input: Bool) -> AudioDeviceID {
	let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
	return getValue(systemObject, address(selector), AudioDeviceID(0)) ?? 0
}

func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
	(getValue(id, address(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 0) != 0
}

// MARK: - Signal level

struct Level {
	var sumSquares: Double = 0
	var peak: Float = 0
	var frames: Int = 0

	mutating func add(_ samples: UnsafeBufferPointer<Float>) {
		for s in samples {
			sumSquares += Double(s * s)
			peak = max(peak, abs(s))
		}
		frames += samples.count
	}

	var rms: Double { frames == 0 ? 0 : (sumSquares / Double(frames)).squareRoot() }
	var dbfs: String { rms > 0 ? String(format: "%.1f dBFS", 20 * log10(rms)) : "-inf dBFS (silent)" }
	var summary: String { "frames \(frames), rms \(dbfs), peak \(String(format: "%.4f", peak))" }
}

func level(of buffer: AVAudioPCMBuffer) -> Level {
	var level = Level()
	guard let channels = buffer.floatChannelData else { return level }
	let n = Int(buffer.frameLength)
	for c in 0..<Int(buffer.format.channelCount) {
		level.add(UnsafeBufferPointer(start: channels[c], count: n))
	}
	return level
}

// MARK: - Child processes we start (killed on exit)

final class Children: @unchecked Sendable {
	static let shared = Children()
	private var processes: [Process] = []
	private let lock = NSLock()

	func launch(_ path: String, _ args: [String]) -> Process? {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: path)
		p.arguments = args
		p.standardOutput = FileHandle.nullDevice
		p.standardError = FileHandle.nullDevice
		do { try p.run() } catch { print("  failed to launch \(path): \(error)"); return nil }
		lock.withLock { processes.append(p) }
		return p
	}

	func killAll() {
		lock.withLock {
			for p in processes where p.isRunning { p.terminate() }
			processes.removeAll()
		}
	}
}
