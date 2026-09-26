import CoreAudio
import Testing
@testable import YapKit

@Suite struct DevicePolicyTests {
	let builtIn = AudioInputDevice(id: 80, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn, inputChannels: 1, nominalSampleRate: 48_000)
	let airPods = AudioInputDevice(id: 91, uid: "AA-BB:input", name: "AirPods Pro", transport: .bluetooth, inputChannels: 1, nominalSampleRate: 24_000)
	let airPodsLE = AudioInputDevice(id: 92, uid: "CC-DD:input", name: "LE Headset", transport: .bluetoothLE, inputChannels: 1, nominalSampleRate: 16_000)
	let usb = AudioInputDevice(id: 60, uid: "USB-Mic", name: "Yeti", transport: .usb, inputChannels: 2, nominalSampleRate: 48_000)
	let teams = AudioInputDevice(id: 73, uid: "MSTeams", name: "Microsoft Teams Audio", transport: .virtual, inputChannels: 1, nominalSampleRate: 48_000)
	let speakers = AudioInputDevice(id: 81, uid: "BuiltInSpeakerDevice", name: "Speakers", transport: .builtIn, inputChannels: 0, nominalSampleRate: 48_000)

	@Test func keepsNonBluetoothDefault() {
		let chosen = DevicePolicy.choose(from: [builtIn, usb, teams], systemDefault: usb.id, preferredUID: nil)
		#expect(chosen == usb)
	}

	@Test func bluetoothDefaultFallsBackToBuiltIn() {
		for headset in [airPods, airPodsLE] {
			let chosen = DevicePolicy.choose(from: [headset, builtIn, usb], systemDefault: headset.id, preferredUID: nil)
			#expect(chosen == builtIn)
		}
	}

	@Test func bluetoothDefaultWithoutBuiltInKeepsDefault() {
		// A Mac mini with AirPods and no other mic: record from the AirPods.
		let chosen = DevicePolicy.choose(from: [airPods], systemDefault: airPods.id, preferredUID: nil)
		#expect(chosen == airPods)
	}

	@Test func explicitChoiceWins() {
		let chosen = DevicePolicy.choose(from: [builtIn, airPods, teams], systemDefault: builtIn.id, preferredUID: teams.uid)
		#expect(chosen == teams)
		// Even a Bluetooth device, when the user picks it on purpose.
		let bt = DevicePolicy.choose(from: [builtIn, airPods], systemDefault: builtIn.id, preferredUID: airPods.uid)
		#expect(bt == airPods)
	}

	@Test func missingExplicitChoiceFallsBackToPolicy() {
		let chosen = DevicePolicy.choose(from: [builtIn, airPods], systemDefault: airPods.id, preferredUID: "unplugged-mic")
		#expect(chosen == builtIn)
	}

	@Test func ignoresOutputOnlyDevices() {
		let chosen = DevicePolicy.choose(from: [speakers, usb], systemDefault: speakers.id, preferredUID: speakers.uid)
		#expect(chosen == usb)
	}

	@Test func unknownDefaultPrefersBuiltIn() {
		#expect(DevicePolicy.choose(from: [usb, builtIn], systemDefault: nil, preferredUID: nil) == builtIn)
		#expect(DevicePolicy.choose(from: [airPods, usb], systemDefault: 999, preferredUID: nil) == usb)
	}

	@Test func noInputsMeansNoDevice() {
		#expect(DevicePolicy.choose(from: [], systemDefault: nil, preferredUID: nil) == nil)
		#expect(DevicePolicy.choose(from: [speakers], systemDefault: speakers.id, preferredUID: nil) == nil)
	}

	@Test func transportMapping() {
		#expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeBluetooth).isBluetooth)
		#expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeBluetoothLE).isBluetooth)
		#expect(AudioTransport(coreAudio: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
		#expect(!AudioTransport(coreAudio: kAudioDeviceTransportTypeUSB).isBluetooth)
		#expect(AudioTransport(coreAudio: 0x7A7A7A7A) == .other(0x7A7A7A7A))
	}
}
