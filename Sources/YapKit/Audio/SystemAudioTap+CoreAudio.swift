import CoreAudio
import Darwin
import Foundation

/// A process that Core Audio knows as a client, i.e. one that has opened
/// audio IO at some point. Used by the system tap (who is playing?) and by
/// call detection (who is recording?).
public struct AudioProcess: Sendable, Hashable {
	public var object: AudioObjectID
	public var pid: pid_t
	/// Empty for command-line tools without an embedded Info.plist.
	public var bundleID: String
	public var isRunningInput: Bool
	public var isRunningOutput: Bool

	public init(object: AudioObjectID, pid: pid_t, bundleID: String, isRunningInput: Bool, isRunningOutput: Bool) {
		self.object = object
		self.pid = pid
		self.bundleID = bundleID
		self.isRunningInput = isRunningInput
		self.isRunningOutput = isRunningOutput
	}

	/// Every audio client right now. Reads a handful of properties per process,
	/// well under a millisecond in total, so it is fine to rescan on every change.
	public static func all() -> [AudioProcess] {
		CoreAudioProperty.array(CoreAudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0))
			.compactMap { object in
				guard let pid = CoreAudioProperty.value(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0 else { return nil }
				return AudioProcess(
					object: object,
					pid: pid,
					bundleID: CoreAudioProperty.string(object, kAudioProcessPropertyBundleID) ?? "",
					isRunningInput: (CoreAudioProperty.value(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0,
					isRunningOutput: (CoreAudioProperty.value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
				)
			}
	}

	/// The process object for `pid`, or nil if that process has never touched
	/// audio (Core Audio creates the object lazily on first use).
	public static func object(for pid: pid_t) -> AudioObjectID? {
		var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
		var pid = pid
		var object = AudioObjectID(kAudioObjectUnknown)
		var size = UInt32(MemoryLayout<AudioObjectID>.size)
		let status = AudioObjectGetPropertyData(CoreAudioProperty.systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
		return status == noErr && object != kAudioObjectUnknown ? object : nil
	}

	/// Path of the executable, used to name processes that report no bundle id.
	public static func executablePath(of pid: pid_t) -> String? {
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
		guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
		let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
		return path.isEmpty ? nil : path
	}
}

/// Keeps one Core Audio property listener alive and removes it when released.
///
/// The listener block is built here, outside any actor, because Core Audio
/// calls it on its own queue; a closure written inside an isolated method
/// would inherit that isolation and trap.
final class CoreAudioListener: @unchecked Sendable {
	// All stored properties are immutable after init.
	private let object: AudioObjectID
	private let selector: AudioObjectPropertySelector
	private let queue: DispatchQueue
	private let block: AudioObjectPropertyListenerBlock
	private let registered: Bool

	init?(object: AudioObjectID, selector: AudioObjectPropertySelector, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
		self.object = object
		self.selector = selector
		self.queue = queue
		block = { _, _ in onChange() }
		var address = CoreAudioProperty.address(selector)
		registered = AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr
		if !registered { return nil }
	}

	deinit {
		guard registered else { return }
		var address = CoreAudioProperty.address(selector)
		AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
	}
}
