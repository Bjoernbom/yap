import AudioToolbox
import AVFoundation
import CoreAudio
import os

public enum MicCaptureError: Error, Equatable, Sendable {
	/// Microphone access is denied or restricted in System Settings.
	case permissionDenied
	case noInputDevice
	/// The input unit reported a zero rate or no channels (device vanished mid-setup).
	case invalidInputFormat
	/// `start()` while a capture is running. Call `stop()` first.
	case alreadyCapturing
	case engineStartFailed(String)
}

/// Push-to-talk microphone capture: raw `AVAudioEngine` input (never voice
/// processing, which ducks the user's music), resampled to 16 kHz mono Float32.
///
/// Lifecycle:
/// - `prepare()` builds the engine, pins it to the device `DevicePolicy`
///   picks, attaches the sink and calls `engine.prepare()`. This does not start
///   IO, so the mic is not "in use" and the orange indicator stays off.
/// - `start()` only starts IO and a small pump task, so key-down to mic-live
///   stays well under the 50 ms budget.
/// - `stop()` pauses IO, flushes the resampler, finishes the stream and returns
///   once the last chunk is yielded. The engine stays prepared for the next press.
///
/// Audio path: an `AVAudioSinkNode` gets the device's IO buffers (~10 ms)
/// on the realtime thread and copies channel 0 into a lock-free `RingBuffer`.
/// The pump drains it every `chunkInterval`, resamples with `AVAudioConverter`
/// and yields chunks stamped with the host time of their first sample. A tap
/// would be simpler but always delivers 100 ms buffers, too coarse for the waveform.
///
/// Device changes: if the engine reports `AVAudioEngineConfigurationChange`
/// while capturing (device unplugged, format change), the engine is rebuilt on
/// the device the policy picks now and capture continues in the same stream;
/// chunks already yielded are kept and the gap shows up in the host times. If
/// the rebuild fails, or the engine keeps changing, the stream finishes cleanly.
/// Default-device changes while idle re-prepare in the background; during a
/// capture they wait until it ends.
public actor MicCapture: AudioSource {
	/// Restarts allowed within one capture before giving up, so a flapping
	/// device cannot spin the engine forever.
	public static let maxRestartsPerCapture = 3

	public nonisolated let chunkInterval: Duration

	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "audio")

	/// ~2.7 s of 10 ms IO buffers: the pump can stall that long without loss.
	private let ring = RingBuffer(slotCount: 256, slotFrames: 1024)
	private var preferredDeviceUID: String?
	private var engine: AVAudioEngine?
	private var configObserver: ObserverToken?
	private var deviceWatcher: DeviceWatcher?
	private var capture: Capture?
	private var stopping: Task<Void, Never>?
	/// The device choice changed during a capture; rebuild once it ends.
	private var stale = false
	/// `prepare()` was called, so keep the engine prepared across device changes.
	private var keepPrepared = false
	/// Hardware input format the engine was built for, to tell real
	/// configuration changes from the ones the engine posts about itself.
	private var preparedFormat: (sampleRate: Double, channels: AVAudioChannelCount)?

	/// The device the engine is pinned to, or nil if not prepared (or pinning
	/// failed and capture follows the system default).
	public private(set) var device: AudioInputDevice?
	/// Engine restarts caused by configuration changes during the current or
	/// last capture.
	public private(set) var restartsInLastCapture = 0

	public var isCapturing: Bool { capture != nil }

	private struct Capture {
		let continuation: AsyncStream<AudioChunk>.Continuation
		let pump: Task<Void, Never>
	}

	/// - Parameters:
	///   - preferredDeviceUID: explicit choice from Settings; nil follows `DevicePolicy`.
	///   - chunkInterval: how often chunks are yielded. 20 ms feeds a 50 fps waveform.
	public init(preferredDeviceUID: String? = nil, chunkInterval: Duration = .milliseconds(20)) {
		self.preferredDeviceUID = preferredDeviceUID
		self.chunkInterval = chunkInterval
	}

	deinit {
		// The pump only holds the ring and continuation, not self, so it would
		// otherwise keep polling forever.
		capture?.pump.cancel()
		capture?.continuation.finish()
	}

	// MARK: AudioSource

	public func prepare() async throws {
		keepPrepared = true
		try prepareEngine()
	}

	public func start() async throws -> AsyncStream<AudioChunk> {
		if let stopping { await stopping.value }
		guard capture == nil else { throw MicCaptureError.alreadyCapturing }
		try prepareEngine()
		guard let engine else { throw MicCaptureError.noInputDevice }

		ring.reset()
		restartsInLastCapture = 0
		let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
		do {
			try engine.start()
		} catch {
			continuation.finish()
			// A failed start can leave the unit half-initialized; rebuild next time.
			teardownEngine()
			throw MicCaptureError.engineStartFailed(String(describing: error))
		}
		let pump = Self.makePump(ring: ring, continuation: continuation, interval: chunkInterval)
		capture = Capture(continuation: continuation, pump: pump)
		continuation.onTermination = Self.stopWhenAbandoned(self)
		return stream
	}

	public func stop() async {
		guard let capture else {
			// A stop racing another stop still waits for the stream to finish.
			await stopping?.value
			return
		}
		self.capture = nil
		// pause() stops IO but keeps what prepare() allocated, so the next
		// start() is as fast as the first.
		engine?.pause()
		capture.pump.cancel()
		stopping = capture.pump
		await capture.pump.value
		if stopping == capture.pump { stopping = nil }
		if stale, self.capture == nil { rebuildIfIdle() }
	}

	// MARK: Device choice

	/// Records from the device with this UID when attached; nil follows `DevicePolicy`.
	public func setPreferredDevice(uid: String?) {
		guard uid != preferredDeviceUID else { return }
		preferredDeviceUID = uid
		invalidate()
	}

	// MARK: Engine

	private func prepareEngine() throws {
		if engine != nil, !stale { return }
		teardownEngine()
		stale = false
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .denied, .restricted: throw MicCaptureError.permissionDenied
		default: break // notDetermined: the first start() shows the prompt.
		}
		if deviceWatcher == nil { deviceWatcher = Self.makeDeviceWatcher(self) }

		let chosen = DevicePolicy.resolve(preferredUID: preferredDeviceUID)
		guard chosen != nil || DevicePolicy.defaultInputDeviceID() != nil else { throw MicCaptureError.noInputDevice }
		let engine = AVAudioEngine()
		let input = engine.inputNode
		var pinned = chosen
		if let chosen {
			// Pin even when the choice is the system default: the unpinned unit
			// runs on a private aggregate that silently follows default changes
			// mid-capture, and we want to know exactly what we record from.
			let status = Self.pin(input, to: chosen.id)
			if status != noErr {
				Self.log.error("pinning input to \(chosen.name, privacy: .public) failed (\(status)); using the system default")
				pinned = nil
			}
		}
		let format = input.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0 else { throw MicCaptureError.invalidInputFormat }
		let sink = Self.makeSink(ring: ring, sampleRate: format.sampleRate)
		engine.attach(sink)
		engine.connect(input, to: sink, format: format)
		engine.prepare()

		configObserver = Self.observeConfigurationChange(of: engine, owner: self)
		let hardware = input.inputFormat(forBus: 0)
		preparedFormat = (hardware.sampleRate, hardware.channelCount)
		self.engine = engine
		device = pinned
	}

	private func teardownEngine() {
		configObserver = nil
		engine?.stop()
		engine = nil
		device = nil
		preparedFormat = nil
	}

	/// The device choice may have changed. Rebuild now if idle, else after stop.
	private func invalidate() {
		guard engine != nil else { return }
		stale = true
		if capture == nil { rebuildIfIdle() }
	}

	private func rebuildIfIdle() {
		teardownEngine()
		stale = false
		guard keepPrepared else { return }
		do {
			try prepareEngine()
		} catch {
			Self.log.error("re-prepare after device change failed: \(String(describing: error), privacy: .public)")
		}
	}

	private func devicesChanged() {
		guard engine != nil else { return }
		let wanted = DevicePolicy.resolve(preferredUID: preferredDeviceUID)
		guard wanted?.id != device?.id else { return }
		invalidate()
	}

	private func configurationChanged(engine changed: ObjectIdentifier) async {
		guard let engine, ObjectIdentifier(engine) == changed else { return }
		// The engine posts this notification by itself ~200 ms after the input
		// unit is pinned, with nothing actually changed. Rebuilding on that would
		// loop forever (each new engine posts one again), so only act when the
		// device, its format, or the running state really changed.
		guard !engineStillValid(engine) else { return }
		guard capture != nil else {
			stale = true
			rebuildIfIdle()
			return
		}
		restartsInLastCapture += 1
		Self.log.notice("audio configuration changed during capture (restart \(self.restartsInLastCapture))")
		// The engine has stopped itself. Build a new one on whatever the policy
		// picks now; the sink writes into the same ring, and the discontinuity
		// makes the assembler flush and re-anchor instead of splicing two devices.
		teardownEngine()
		ring.markDiscontinuity()
		if restartsInLastCapture <= Self.maxRestartsPerCapture {
			do {
				try prepareEngine()
				try self.engine?.start()
				return
			} catch {
				Self.log.error("restart after configuration change failed: \(String(describing: error), privacy: .public)")
				teardownEngine()
			}
		}
		await stop()
	}

	private func engineStillValid(_ engine: AVAudioEngine) -> Bool {
		let input = engine.inputNode
		let hardware = input.inputFormat(forBus: 0)
		guard let preparedFormat, hardware.sampleRate == preparedFormat.sampleRate, hardware.channelCount == preparedFormat.channels else { return false }
		if let device {
			guard Self.currentDevice(of: input) == device.id,
				CoreAudioProperty.value(device.id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1
			else { return false }
		}
		// A real change stops a running engine; while idle there is nothing to lose.
		return capture == nil || engine.isRunning
	}

	/// Takes the same path a real device change does: the engine stops, then
	/// the notification arrives. For the harness only.
	package func simulateConfigurationChange() {
		guard let engine else { return }
		engine.stop()
		NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
	}

	// MARK: Closures built outside the actor
	//
	// Swift 6 trap: a closure written inside an isolated method inherits that
	// isolation, and Core Audio calls these on its own threads, which crashes
	// with dispatch_assert_queue_fail. Everything handed to audio or
	// notification APIs is created in these nonisolated functions.

	private nonisolated static func makeSink(ring: RingBuffer, sampleRate: Double) -> AVAudioSinkNode {
		let ticksPerSecond = HostClock.ticksPerSecond
		return AVAudioSinkNode { timestamp, frameCount, bufferList in
			// Realtime thread: no allocation, no locks, no logging.
			let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
			guard frameCount > 0, let first = buffers.first, let data = first.mData else { return noErr }
			let stamp = timestamp.pointee
			let duration = UInt64(Double(frameCount) / sampleRate * ticksPerSecond)
			let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time() &- duration
			ring.write(
				data.assumingMemoryBound(to: Float.self),
				frameCount: Int(frameCount),
				// Deinterleaved buffers hold one channel each; interleaved ones
				// need striding to pick channel 0.
				stride: max(Int(first.mNumberChannels), 1),
				hostTime: hostTime,
				sampleRate: sampleRate,
				ticksPerSecond: ticksPerSecond
			)
			return noErr
		}
	}

	private nonisolated static func makePump(
		ring: RingBuffer,
		continuation: AsyncStream<AudioChunk>.Continuation,
		interval: Duration
	) -> Task<Void, Never> {
		Task.detached(priority: .userInitiated) {
			let assembler = ChunkAssembler()
			while !Task.isCancelled {
				for chunk in assembler.consume(ring) { continuation.yield(chunk) }
				try? await Task.sleep(for: interval, tolerance: .milliseconds(2))
			}
			// stop() paused IO before cancelling, so this drains everything.
			for chunk in assembler.consume(ring, endOfStream: true) { continuation.yield(chunk) }
			continuation.finish()
		}
	}

	/// If the consumer stops listening, stop the mic too rather than leave it on.
	private nonisolated static func stopWhenAbandoned(_ owner: MicCapture) -> @Sendable (AsyncStream<AudioChunk>.Continuation.Termination) -> Void {
		{ [weak owner] termination in
			guard case .cancelled = termination else { return }
			Task { await owner?.stop() }
		}
	}

	private nonisolated static func observeConfigurationChange(of engine: AVAudioEngine, owner: MicCapture) -> ObserverToken {
		let id = ObjectIdentifier(engine)
		let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak owner] _ in
			Task { await owner?.configurationChanged(engine: id) }
		}
		return ObserverToken(token)
	}

	private nonisolated static func makeDeviceWatcher(_ owner: MicCapture) -> DeviceWatcher {
		DeviceWatcher { [weak owner] in
			Task { await owner?.devicesChanged() }
		}
	}

	private nonisolated static func currentDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
		guard let unit = input.audioUnit else { return nil }
		var id = AudioDeviceID(0)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
		return status == noErr ? id : nil
	}

	private nonisolated static func pin(_ input: AVAudioInputNode, to id: AudioDeviceID) -> OSStatus {
		guard let unit = input.audioUnit else { return kAudioUnitErr_Uninitialized }
		var id = id
		return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
	}
}

/// Removes a block-based NotificationCenter observer when released.
private final class ObserverToken: @unchecked Sendable {
	// NSObjectProtocol tokens are immutable and only passed back to removeObserver.
	private let token: any NSObjectProtocol
	init(_ token: any NSObjectProtocol) { self.token = token }
	deinit { NotificationCenter.default.removeObserver(token) }
}

/// Calls `onChange` when devices are added or removed or the default input
/// changes. Listeners are removed when released.
private final class DeviceWatcher: @unchecked Sendable {
	// All stored properties are immutable after init.
	private let queue = DispatchQueue(label: "com.bjornbom.yap.audio-devices")
	private let block: AudioObjectPropertyListenerBlock
	private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

	init(onChange: @escaping @Sendable () -> Void) {
		block = { _, _ in onChange() }
		for selector in Self.selectors {
			var address = CoreAudioProperty.address(selector)
			AudioObjectAddPropertyListenerBlock(CoreAudioProperty.systemObject, &address, queue, block)
		}
	}

	deinit {
		for selector in Self.selectors {
			var address = CoreAudioProperty.address(selector)
			AudioObjectRemovePropertyListenerBlock(CoreAudioProperty.systemObject, &address, queue, block)
		}
	}
}
