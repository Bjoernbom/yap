import AVFoundation
import CoreAudio
import Foundation

/// Device policy from PLAN.md §5: prefer the built-in mic over Bluetooth headsets so the
/// headset stays in A2DP (music quality) instead of dropping to HFP when yap records.
func preferredInputDevice(_ devices: [AudioDevice], systemDefault: AudioDeviceID) -> AudioDevice? {
	let inputs = devices.filter { $0.inputChannels > 0 && $0.transport != kAudioDeviceTransportTypeAggregate }
	let isBluetooth: (AudioDevice) -> Bool = {
		$0.transport == kAudioDeviceTransportTypeBluetooth || $0.transport == kAudioDeviceTransportTypeBluetoothLE
	}
	if let def = inputs.first(where: { $0.id == systemDefault }), !isBluetooth(def) { return def }
	return inputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn } ?? inputs.first { $0.id == systemDefault }
}

@MainActor
func runDevices(_ args: Args) {
	print("== Devices")
	let defIn = defaultDevice(input: true)
	let defOut = defaultDevice(input: false)
	let devices = allDevices()
	for d in devices {
		var tags: [String] = []
		if d.id == defIn { tags.append("default-input") }
		if d.id == defOut { tags.append("default-output") }
		print(String(format: "  %4u  %-34@ %-12@ in %d out %d  %6.0f Hz  %@", d.id, d.name as NSString, d.transportName as NSString, d.inputChannels, d.outputChannels, d.sampleRate, tags.joined(separator: ",") as NSString))
		print("        uid \(d.uid)")
	}
	if let preferred = preferredInputDevice(devices, systemDefault: defIn) {
		print("  policy -> capture from \(preferred.id) '\(preferred.name)' (\(preferred.transportName))")
	}

	if args.flag("pin-test") {
		// Pin AVAudioEngine's input to the built-in mic via kAudioOutputUnitProperty_CurrentDevice
		// on the input node's AUHAL. This does not touch the system default device.
		let wanted = args.value("device").flatMap(UInt32.init)
		let target: AudioDevice? = if let wanted {
			devices.first { $0.id == wanted }
		} else {
			devices.first { $0.transport == kAudioDeviceTransportTypeBuiltIn && $0.inputChannels > 0 }
		}
		guard let builtIn = target else {
			print("  no matching input"); return
		}
		print("  pin target: \(builtIn.id) '\(builtIn.name)' (\(builtIn.transportName)); default input \(defIn)")
		for vp in [false, true] {
			let engine = AVAudioEngine()
			if vp { try? engine.inputNode.setVoiceProcessingEnabled(true) }
			let status = pinInput(engine, to: builtIn.id)
			let current = currentInputDevice(engine)
			let format = engine.inputNode.outputFormat(forBus: 0)
			engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock(nil))
			var startError = ""
			do { try engine.start() } catch { startError = " start error: \(error)" }
			runLoop(for: 0.5)
			let runningBuiltIn = isRunningSomewhere(builtIn.id)
			let runningDefault = isRunningSomewhere(defIn)
			print("  vp=\(vp): set CurrentDevice -> \(osStatus(status)); AU reports \(current.map(String.init) ?? "?"); target running=\(runningBuiltIn), default-input running=\(runningDefault); default input still \(defaultDevice(input: true)) (unchanged: \(defaultDevice(input: true) == defIn))\(startError)")
			engine.stop()
		}
	}
}
