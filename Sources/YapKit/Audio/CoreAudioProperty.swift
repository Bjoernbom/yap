import CoreAudio
import Foundation

/// Thin wrappers over `AudioObjectGetPropertyData`. Every read can fail (a device
/// can disappear between listing and reading), so they all return optionals.
enum CoreAudioProperty {
	static let systemObject = AudioObjectID(kAudioObjectSystemObject)

	static func address(
		_ selector: AudioObjectPropertySelector,
		scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
	) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
	}

	static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
		var addr = address(selector)
		var value = initial
		var size = UInt32(MemoryLayout<T>.size)
		let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
		return status == noErr ? value : nil
	}

	static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, zero: T) -> [T] {
		var addr = address(selector)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
		var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
		guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &values) == noErr else { return [] }
		return values
	}

	static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
		var addr = address(selector)
		var value: Unmanaged<CFString>?
		var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
		guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
		return value.takeRetainedValue() as String
	}

	/// Total channels across all streams in one direction. Input-only devices report
	/// zero output channels, which is how we tell mics from speakers.
	static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
		var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
		let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
		defer { raw.deallocate() }
		guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
		let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
		return list.reduce(0) { $0 + Int($1.mNumberChannels) }
	}
}
