import CoreAudio
import Foundation

/// How an audio device is attached. Only the kinds the policy or Settings care
/// about get their own case.
public enum AudioTransport: Sendable, Hashable {
	case builtIn
	case bluetooth
	case bluetoothLE
	case usb
	case virtual
	case aggregate
	case continuity
	case displayPort
	case hdmi
	case airPlay
	case thunderbolt
	case unknown
	case other(UInt32)

	public init(coreAudio value: UInt32) {
		self = switch value {
		case kAudioDeviceTransportTypeBuiltIn: .builtIn
		case kAudioDeviceTransportTypeBluetooth: .bluetooth
		case kAudioDeviceTransportTypeBluetoothLE: .bluetoothLE
		case kAudioDeviceTransportTypeUSB: .usb
		case kAudioDeviceTransportTypeVirtual: .virtual
		case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
		case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity
		case kAudioDeviceTransportTypeDisplayPort: .displayPort
		case kAudioDeviceTransportTypeHDMI: .hdmi
		case kAudioDeviceTransportTypeAirPlay: .airPlay
		case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
		case kAudioDeviceTransportTypeUnknown: .unknown
		default: .other(value)
		}
	}

	/// Classic (`blue`) and LE (`blea`) Bluetooth. Recording from these forces
	/// headsets from A2DP into the low-quality call profile.
	public var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
}

/// A device that can record.
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
	/// Core Audio object id. Valid only while the device is attached, and may be
	/// reused after replugging; persist `uid` instead.
	public var id: AudioDeviceID
	/// Stable across reboots and replugging. What Settings stores.
	public var uid: String
	public var name: String
	public var transport: AudioTransport
	public var inputChannels: Int
	public var nominalSampleRate: Double

	public init(id: AudioDeviceID, uid: String, name: String, transport: AudioTransport, inputChannels: Int, nominalSampleRate: Double) {
		self.id = id
		self.uid = uid
		self.name = name
		self.transport = transport
		self.inputChannels = inputChannels
		self.nominalSampleRate = nominalSampleRate
	}
}

/// Decides which microphone yap records from.
///
/// Rule (PLAN.md §5, "Smart mic choice"): if the system default input is
/// Bluetooth, record from the built-in mic instead, so AirPods stay in A2DP and
/// the user's music keeps its quality. An explicit choice from Settings wins
/// over everything while that device is attached. The system default is never
/// changed; the choice is applied by pinning the capture unit only.
public enum DevicePolicy {
	/// Pure selection logic, separate from Core Audio so it can be tested with
	/// fake device lists. Returns nil only when there is no input device at all.
	public static func choose(
		from devices: [AudioInputDevice],
		systemDefault: AudioDeviceID?,
		preferredUID: String?
	) -> AudioInputDevice? {
		let inputs = devices.filter { $0.inputChannels > 0 }
		if let preferredUID, let preferred = inputs.first(where: { $0.uid == preferredUID }) {
			return preferred
		}
		let defaultDevice = systemDefault.flatMap { id in inputs.first { $0.id == id } }
		if let defaultDevice, !defaultDevice.transport.isBluetooth {
			return defaultDevice
		}
		// Default is Bluetooth (or unknown): the built-in mic if this Mac has one.
		// Desktop Macs without a mic fall back to the default, Bluetooth or not,
		// because recording something beats recording nothing.
		if let builtIn = inputs.first(where: { $0.transport == .builtIn }) {
			return builtIn
		}
		return defaultDevice ?? inputs.first { !$0.transport.isBluetooth } ?? inputs.first
	}

	/// Applies `choose` to the devices attached right now.
	public static func resolve(preferredUID: String?) -> AudioInputDevice? {
		choose(from: inputDevices(), systemDefault: defaultInputDeviceID(), preferredUID: preferredUID)
	}

	/// Every attached device with at least one input channel.
	public static func inputDevices() -> [AudioInputDevice] {
		CoreAudioProperty.array(CoreAudioProperty.systemObject, kAudioHardwarePropertyDevices, zero: AudioDeviceID(0))
			.compactMap(inputDevice)
	}

	public static func defaultInputDeviceID() -> AudioDeviceID? {
		let id = CoreAudioProperty.value(CoreAudioProperty.systemObject, kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))
		return id == 0 ? nil : id
	}

	/// True while any process has IO running on the device. This is what drives
	/// "mic in use" for other apps (call detection, the orange indicator).
	public static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
		(CoreAudioProperty.value(id, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) ?? 0) != 0
	}

	static func inputDevice(_ id: AudioDeviceID) -> AudioInputDevice? {
		let channels = CoreAudioProperty.channelCount(id, scope: kAudioObjectPropertyScopeInput)
		guard channels > 0 else { return nil }
		return AudioInputDevice(
			id: id,
			uid: CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID) ?? "",
			name: CoreAudioProperty.string(id, kAudioObjectPropertyName) ?? "",
			transport: AudioTransport(coreAudio: CoreAudioProperty.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0),
			inputChannels: channels,
			nominalSampleRate: CoreAudioProperty.value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
		)
	}
}
