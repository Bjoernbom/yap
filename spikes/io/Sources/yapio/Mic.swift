import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Collects converted 16 kHz mono samples from the audio thread.
final class MicSink: @unchecked Sendable {
	private let lock = NSLock()
	private var firstBufferNs: UInt64 = 0
	private var firstSampleNs: UInt64 = 0
	private(set) var firstFrames: AVAudioFrameCount = 0
	private var samples: [Float] = []
	private var inputLevel = Level()
	private(set) var tapFormat = ""
	private let converter: AVAudioConverter?
	private let target: AVAudioFormat
	var keepSamples = false

	init(from: AVAudioFormat, to target: AVAudioFormat) {
		self.target = target
		self.converter = AVAudioConverter(from: from, to: target)
		// With voice processing the input node has several channels; channel 0 is the processed
		// voice, the rest are references. Take channel 0 instead of letting the converter mix.
		if from.channelCount > 1 { converter?.channelMap = [0] }
		tapFormat = "\(from.sampleRate) Hz, \(from.channelCount) ch, \(from.commonFormat == .pcmFormatFloat32 ? "f32" : "\(from.commonFormat.rawValue)"), interleaved=\(from.isInterleaved)"
	}

	var first: UInt64 { lock.withLock { firstBufferNs } }
	/// Host time of the first captured sample: when the mic was actually live.
	var firstSample: UInt64 { lock.withLock { firstSampleNs } }
	var collected: [Float] { lock.withLock { samples } }
	var rawLevel: Level { lock.withLock { inputLevel } }

	func receive(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
		let t = nowNs()
		let sampleNs = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) * 1e9 : 0
		lock.withLock {
			if firstBufferNs == 0 {
				firstBufferNs = t
				firstSampleNs = UInt64(sampleNs)
				firstFrames = buffer.frameLength
			}
		}
		let raw = level(of: buffer)
		guard let converter else { return }
		let ratio = target.sampleRate / buffer.format.sampleRate
		let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
		guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
		nonisolated(unsafe) var fed = false
		nonisolated(unsafe) let input = buffer
		var error: NSError?
		converter.convert(to: out, error: &error) { _, status in
			if fed { status.pointee = .noDataNow; return nil }
			fed = true
			status.pointee = .haveData
			return input
		}
		lock.withLock {
			inputLevel.sumSquares += raw.sumSquares
			inputLevel.frames += raw.frames
			inputLevel.peak = max(inputLevel.peak, raw.peak)
			if keepSamples, let data = out.floatChannelData {
				samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
			}
		}
	}
}

let target16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

enum MicMode: String, CaseIterable {
	case cold // new engine, configure, start
	case prepared // engine configured + prepare() earlier; measure start() only
	case restart // same engine: start, stop, start again; measure second start
}

struct MicResult {
	var startCallMs: Double = 0 // time spent inside engine.start()
	var firstBufferMs: Double? // start() called -> first tap buffer delivered
	var firstSampleMs: Double? // start() called -> host time of the first captured sample
	var firstFrames: AVAudioFrameCount = 0
	var setupMs: Double = 0 // engine creation + VP + tap install (+ prepare)
	var format = ""
	var error: String?
}

extension MicResult {
	mutating func fill(_ sink: MicSink, _ startAt: UInt64) {
		guard sink.first != 0 else { return }
		firstBufferMs = msValue(sink.first - startAt)
		firstFrames = sink.firstFrames
		if sink.firstSample != 0 { firstSampleMs = (Double(sink.firstSample) - Double(startAt)) / 1e6 }
	}
}

/// How the engine's output side is wired when voice processing is on (spike variable).
nonisolated(unsafe) var vpVariant = "none"

func pinInput(_ engine: AVAudioEngine, to deviceID: AudioDeviceID) -> OSStatus {
	guard let unit = engine.inputNode.audioUnit else { return -1 }
	var id = deviceID
	return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
}

func currentInputDevice(_ engine: AVAudioEngine) -> AudioDeviceID? {
	guard let unit = engine.inputNode.audioUnit else { return nil }
	var id = AudioDeviceID(0)
	var size = UInt32(MemoryLayout<AudioDeviceID>.size)
	let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
	return status == noErr ? id : nil
}

@MainActor
func micTrial(mode: MicMode, vp: Bool, pin: AudioDeviceID?, record: Double = 0, label: String? = nil) -> MicResult {
	var result = MicResult()
	let setupStart = nowNs()
	let engine = AVAudioEngine()
	let input = engine.inputNode
	if let pin {
		let status = pinInput(engine, to: pin)
		if status != noErr { result.error = "pin device failed: \(osStatus(status))" }
	}
	if vp {
		do {
			try input.setVoiceProcessingEnabled(true)
			if !vpVariant.contains("noduck") {
				// Keep other apps' audio as loud as possible while VP is on (default ducks it).
				input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
			}
		} catch {
			result.error = "setVoiceProcessingEnabled: \(error)"
			return result
		}
		switch vpVariant.split(separator: "+").first.map(String.init) ?? "" {
		case "mixer": engine.mainMixerNode.outputVolume = 0 // wires mixer -> output implicitly
		case "connect": // input -> muted mixer -> output
			engine.connect(input, to: engine.mainMixerNode, format: nil)
			engine.mainMixerNode.outputVolume = 0
		case "output": _ = engine.outputNode // only instantiate output
		case "match", "match1": // mixer -> output at the input's sample rate
			let rate = input.outputFormat(forBus: 0).sampleRate
			let channels: AVAudioChannelCount = vpVariant.hasPrefix("match1") ? 1 : 2
			engine.connect(engine.mainMixerNode, to: engine.outputNode, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
			engine.mainMixerNode.outputVolume = 0
		case "diag":
			print("    VP diag: input.out \(input.outputFormat(forBus: 0)) input.in \(input.inputFormat(forBus: 0))")
			print("    VP diag: output.in \(engine.outputNode.inputFormat(forBus: 0)) output.out \(engine.outputNode.outputFormat(forBus: 0))")
			print("    VP diag: mixer.out \(engine.mainMixerNode.outputFormat(forBus: 0))")
		default: break // "none": input only
		}
	}
	let format = input.outputFormat(forBus: 0)
	guard format.sampleRate > 0, format.channelCount > 0 else {
		result.error = "input format invalid: \(format)"
		return result
	}
	let sink = MicSink(from: format, to: target16k)
	sink.keepSamples = record > 0
	input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock(sink))
	result.format = sink.tapFormat

	if mode == .prepared {
		engine.prepare()
		runLoop(for: 0.3) // "earlier": prepare happened while idle, e.g. at app launch
	}
	result.setupMs = msValue(nowNs() - setupStart)

	var startAt = nowNs()
	do {
		if mode == .restart {
			try engine.start()
			runLoop(for: 0.3) { sink.first != 0 }
			engine.stop()
			runLoop(for: 0.1)
			let s2 = MicSink(from: format, to: target16k)
			input.removeTap(onBus: 0)
			input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock(s2))
			startAt = nowNs()
			try engine.start()
			result.startCallMs = msValue(nowNs() - startAt)
			runLoop(for: 3) { s2.first != 0 }
			result.fill(s2, startAt)
		} else {
			try engine.start()
			result.startCallMs = msValue(nowNs() - startAt)
			if vp, vpVariant.contains("lateduck") {
				input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
			}
			runLoop(for: 3) { sink.first != 0 }
			result.fill(sink, startAt)
		}
	} catch {
		result.error = "engine.start: \(error)"
	}

	if record > 0, result.error == nil {
		if let current = currentInputDevice(engine) {
			let d = device(current)
			print("    capturing from device \(d.id) '\(d.name)' (\(d.transportName)); default input is \(defaultDevice(input: true))")
		}
		let out = defaultDevice(input: false)
		print("    during capture: default output '\(device(out).name)' nominal rate \(device(out).sampleRate) Hz")
		runLoop(for: record)
		let samples = sink.collected
		var lvl = Level()
		samples.withUnsafeBufferPointer { lvl.add($0) }
		let name = label ?? "mic-\(vp ? "vp" : "raw")"
		let url = localDir.appendingPathComponent("\(name).wav")
		writeWav(samples, sampleRate: 16_000, to: url)
		print("    recorded \(String(format: "%.1f", Double(samples.count) / 16_000)) s @16 kHz -> \(url.path)")
		print("    16 kHz level: \(lvl.summary); raw tap level: \(sink.rawLevel.summary)")
	}
	engine.stop()
	input.removeTap(onBus: 0)
	if vp { try? input.setVoiceProcessingEnabled(false) }
	return result
}

/// The tap block must be created outside any actor. A closure written inside a @MainActor
/// function inherits MainActor isolation, and Swift 6 traps at runtime
/// (dispatch_assert_queue_fail) when AVAudioEngine calls it on its realtime messenger queue.
nonisolated func tapBlock(_ sink: MicSink?) -> AVAudioNodeTapBlock {
	{ @Sendable buffer, when in sink?.receive(buffer, when) }
}

func writeWav(_ samples: [Float], sampleRate: Double, to url: URL) {
	let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
	guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return }
	buffer.frameLength = AVAudioFrameCount(samples.count)
	samples.withUnsafeBufferPointer { src in
		buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
	}
	do {
		let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
		try file.write(from: buffer)
	} catch {
		print("    wav write failed: \(error)")
	}
}

@MainActor
func runMic(_ args: Args) {
	print("== Microphone (AVAudioEngine -> 16 kHz mono Float32)")
	print("  mic permission: \(micStatusName(AVCaptureDevice.authorizationStatus(for: .audio)))")
	let defIn = device(defaultDevice(input: true))
	let defOut = device(defaultDevice(input: false))
	print("  default input: '\(defIn.name)' \(defIn.transportName) \(defIn.sampleRate) Hz; default output: '\(defOut.name)' \(defOut.sampleRate) Hz")

	var pin: AudioDeviceID?
	if args.flag("builtin") {
		pin = allDevices().first { $0.transport == kAudioDeviceTransportTypeBuiltIn && $0.inputChannels > 0 }?.id
		print("  pinning capture to built-in mic: \(pin.map { "\($0) '\(device($0).name)'" } ?? "none found")")
	}

	if let seconds = args.value("record").flatMap(Double.init) {
		let vp = args.flag("vp")
		let r = micTrial(mode: .cold, vp: vp, pin: pin, record: seconds, label: args.value("name"))
		print("  vp=\(vp) format: \(r.format) first buffer: \(r.firstBufferMs.map { String(format: "%.1f ms", $0) } ?? "none") \(r.error ?? "")")
		return
	}

	vpVariant = args.value("vp-variant") ?? "none"
	let firstEver = micTrial(mode: .cold, vp: args.flag("only-vp"), pin: pin)
	print("  first engine in this process (HAL cold): setup \(String(format: "%.1f", firstEver.setupMs)) ms, start() \(String(format: "%.1f", firstEver.startCallMs)) ms, start->1st buf \(firstEver.firstBufferMs.map { String(format: "%.1f ms", $0) } ?? "none") \(firstEver.error ?? "")")

	let runs = args.int("runs", 5)
	for vp in args.flag("only-vp") ? [true] : [false, true] {
		for mode in MicMode.allCases {
			var first: [Double] = []
			var firstSample: [Double] = []
			var frames: Set<AVAudioFrameCount> = []
			var startCall: [Double] = []
			var setup: [Double] = []
			var format = ""
			var errors: [String] = []
			for _ in 0..<runs {
				let r = micTrial(mode: mode, vp: vp, pin: pin)
				if let f = r.firstBufferMs { first.append(f) }
				if let f = r.firstSampleMs { firstSample.append(f) }
				if r.firstFrames > 0 { frames.insert(r.firstFrames) }
				startCall.append(r.startCallMs)
				setup.append(r.setupMs)
				format = r.format
				if let e = r.error { errors.append(e) }
				runLoop(for: 0.2)
			}
			print("  vp=\(vp) \(mode.rawValue): format [\(format)]")
			print("    setup           \(stats(setup))")
			print("    start() call    \(stats(startCall))")
			print("    start->1st buf  \(stats(first)) (first buffer frames \(frames.sorted()))")
			print("    start->1st sample captured (host time) \(stats(firstSample))")
			if !errors.isEmpty { print("    errors: \(Set(errors))") }
		}
	}
	print("  after VP: default output '\(device(defaultDevice(input: false)).name)' \(device(defaultDevice(input: false)).sampleRate) Hz; input \(device(defaultDevice(input: true)).sampleRate) Hz")
}
