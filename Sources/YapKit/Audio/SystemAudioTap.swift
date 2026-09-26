import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os
import Synchronization

public enum SystemAudioTapError: Error, Equatable, Sendable {
	/// `start()` while a capture is running. Call `stop()` first.
	case alreadyCapturing
	/// There is no default output device to clock the aggregate device from.
	case noOutputDevice
	case tapCreationFailed(OSStatus)
	case unreadableTapFormat
	case aggregateCreationFailed(OSStatus)
	case ioProcCreationFailed(OSStatus)
	case startFailed(OSStatus)
}

/// Records what the Mac plays (the "them" track of a note) through a Core
/// Audio process tap, resampled to 16 kHz mono Float32.
///
/// Graph, built in `prepare()` or `start()` and torn down in reverse order
/// by `stop()`: mono process tap (`CATapDescription`) → private aggregate
/// device clocked by the default output → IOProc on Core Audio's realtime
/// thread → lock-free `RingBuffer` → pump task → `ChunkAssembler` → stream.
///
/// Things that behave differently from a microphone:
/// - **Silence has no callbacks.** When nothing the tap covers is playing,
///   the IOProc does not run at all. No samples are invented for the gap;
///   chunks carry host times, so the notes timeline stays on host time and the
///   gap is visible there.
/// - **Missing permission looks like silence.** Without "System Audio
///   Recording" the tap delivers all-zero buffers, not an error. `looksBlocked`
///   is the heuristic for it. The first `start()` triggers the system prompt.
/// - **Only from an app bundle.** A bare command-line tool inherits its
///   terminal's TCC identity and captures zeros.
/// - **Output device changes** (headphones plugged in) rebuild the aggregate
///   on the new default output and keep the same stream; the discontinuity
///   makes the assembler start a new segment instead of splicing.
public actor SystemAudioTap: AudioSource {
	public enum Target: Sendable, Hashable {
		/// Everything the Mac plays except yap itself and these processes.
		case allExcept(pids: [pid_t])
		/// Only these processes (e.g. the call app once it is known).
		case processes([pid_t])
		/// Only apps with these bundle ids, including ones not running yet.
		case bundleIDs([String])

		/// All system output except yap. The default.
		public static var systemOutput: Target { .allExcept(pids: []) }
	}

	public struct Statistics: Sendable, Equatable {
		/// IO callbacks since the last `start()`.
		public var callbacks: Int
		/// Callbacks that carried at least one non-zero sample.
		public var audibleCallbacks: Int
		/// Largest absolute sample value since the last `start()`.
		public var peak: Float
		/// Seconds from `start()` to the first callback; nil if none arrived.
		public var firstCallbackDelay: Double?
		/// Frames lost because the pump fell behind.
		public var droppedFrames: Int
		/// Graph rebuilds after output device changes in this capture.
		public var rebuilds: Int
		/// Rate of the aggregate device, before resampling to 16 kHz.
		public var sampleRate: Double
	}

	/// Callbacks with nothing but zeros before `looksBlocked` may say yes:
	/// about a second of IO, so a quiet intro is not mistaken for a block.
	public static let blockedAfterCallbacks = 50

	public nonisolated let target: Target
	public nonisolated let chunkInterval: Duration

	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "system-audio")

	/// ~10 s of 512-frame IO buffers at 48 kHz: the pump can stall that long.
	private let ring = RingBuffer(slotCount: 1024, slotFrames: 1024)
	private let meter = TapMeter()
	private let listenerQueue = DispatchQueue(label: "com.bjornbom.yap.system-audio")
	private var graph: TapGraph?
	private var description: CATapDescription?
	private var listeners: [CoreAudioListener] = []
	private var capture: Capture?
	private var stopping: Task<Void, Never>?
	private var startedAt: UInt64 = 0
	private var rebuilds = 0

	public var isCapturing: Bool { capture != nil }

	private struct Capture {
		let continuation: AsyncStream<AudioChunk>.Continuation
		let pump: Task<Void, Never>
	}

	/// - Parameters:
	///   - target: what to record. Yap itself is always excluded from `allExcept`.
	///   - chunkInterval: how often chunks are yielded. Notes don't draw a
	///     60 fps waveform from this track, so 100 ms keeps wakeups low.
	public init(target: Target = .systemOutput, chunkInterval: Duration = .milliseconds(100)) {
		self.target = target
		self.chunkInterval = chunkInterval
	}

	deinit {
		capture?.pump.cancel()
		capture?.continuation.finish()
		graph?.teardown()
	}

	// MARK: AudioSource

	/// Creates the tap and aggregate device ahead of time. Nothing is recorded
	/// (and no permission prompt appears) until `start()`.
	public func prepare() async throws {
		try buildGraph()
	}

	public func start() async throws -> AsyncStream<AudioChunk> {
		if let stopping { await stopping.value }
		guard capture == nil else { throw SystemAudioTapError.alreadyCapturing }
		try buildGraph()
		guard let graph else { throw SystemAudioTapError.noOutputDevice }

		ring.reset()
		meter.reset()
		rebuilds = 0
		startedAt = HostClock.now()
		let status = graph.start()
		guard status == noErr else {
			teardownGraph()
			throw SystemAudioTapError.startFailed(status)
		}
		let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
		let pump = Self.makePump(ring: ring, continuation: continuation, interval: chunkInterval)
		capture = Capture(continuation: continuation, pump: pump)
		continuation.onTermination = Self.stopWhenAbandoned(self)
		Self.log.info("system audio capture started at \(graph.sampleRate) Hz")
		return stream
	}

	/// Stops IO, delivers the last chunk, finishes the stream and releases the
	/// tap and aggregate device, so nothing stays registered with Core Audio
	/// between notes.
	public func stop() async {
		guard let capture else {
			await stopping?.value
			if self.capture == nil { teardownGraph() }
			return
		}
		self.capture = nil
		graph?.stop()
		capture.pump.cancel()
		stopping = capture.pump
		await capture.pump.value
		if stopping == capture.pump { stopping = nil }
		if self.capture == nil { teardownGraph() }
	}

	// MARK: Health

	public var statistics: Statistics {
		let snapshot = meter.snapshot()
		return Statistics(
			callbacks: snapshot.callbacks,
			audibleCallbacks: snapshot.audibleCallbacks,
			peak: snapshot.peak,
			firstCallbackDelay: snapshot.firstHostTime == 0 ? nil : HostClock.seconds(snapshot.firstHostTime &- min(startedAt, snapshot.firstHostTime)),
			droppedFrames: ring.dropped,
			rebuilds: rebuilds,
			sampleRate: graph?.sampleRate ?? 0
		)
	}

	/// True when the tap has only delivered zeros although some process it
	/// covers is playing: the signature of a missing System Audio Recording
	/// permission. A heuristic: an app playing digital silence looks the same.
	public var looksBlocked: Bool {
		let snapshot = meter.snapshot()
		let playing = AudioProcess.all().contains { $0.isRunningOutput && covers($0) }
		return Self.looksBlocked(callbacks: snapshot.callbacks, audibleCallbacks: snapshot.audibleCallbacks, coveredProcessIsPlaying: playing)
	}

	package static func looksBlocked(callbacks: Int, audibleCallbacks: Int, coveredProcessIsPlaying: Bool) -> Bool {
		callbacks >= blockedAfterCallbacks && audibleCallbacks == 0 && coveredProcessIsPlaying
	}

	private func covers(_ process: AudioProcess) -> Bool {
		switch target {
		case .allExcept(let pids):
			return process.pid != getpid() && !pids.contains(process.pid) && !(ownBundleID.map { $0 == process.bundleID } ?? false)
		case .processes(let pids):
			return pids.contains(process.pid)
		case .bundleIDs(let ids):
			return ids.contains(process.bundleID)
		}
	}

	private nonisolated var ownBundleID: String? { Bundle.main.bundleIdentifier }

	// MARK: Graph

	private func buildGraph() throws {
		if graph != nil { return }
		let description = makeDescription()
		let graph = try TapGraph.make(description: description, ring: ring, meter: meter)
		self.description = description
		self.graph = graph
		if listeners.isEmpty { listeners = Self.makeListeners(owner: self, queue: listenerQueue) }
	}

	private func teardownGraph() {
		listeners = []
		graph?.teardown()
		graph = nil
		description = nil
	}

	private func makeDescription() -> CATapDescription {
		let description: CATapDescription
		switch target {
		case .allExcept:
			description = CATapDescription(monoGlobalTapButExcludeProcesses: processObjects())
			// Excluding by bundle id also covers yap before it has ever played
			// a sound, when it has no process object yet.
			if let ownBundleID { description.bundleIDs = [ownBundleID] }
		case .processes:
			description = CATapDescription(monoMixdownOfProcesses: processObjects())
		case .bundleIDs(let ids):
			description = CATapDescription(monoMixdownOfProcesses: [])
			description.bundleIDs = ids
			// Keeps an app in the tap across a quit and relaunch mid-call.
			description.isProcessRestoreEnabled = true
		}
		description.name = "yap system audio"
		description.isPrivate = true
		description.muteBehavior = .unmuted
		return description
	}

	/// Process objects for the pids in the target. Pids that have not touched
	/// audio yet have none; `processesChanged()` adds them when they appear.
	private func processObjects() -> [AudioObjectID] {
		switch target {
		case .allExcept(let pids): (pids + [getpid()]).compactMap(AudioProcess.object(for:))
		case .processes(let pids): pids.compactMap(AudioProcess.object(for:))
		case .bundleIDs: []
		}
	}

	/// A process became (or stopped being) an audio client. Update the tap's
	/// process list in place, so e.g. yap's own first sound stays excluded.
	private func processesChanged() {
		guard let graph, let description else { return }
		if case .bundleIDs = target { return }
		let objects = processObjects()
		guard objects != description.processes else { return }
		description.processes = objects
		let status = graph.update(description)
		if status != noErr { Self.log.error("updating the tap's process list failed: \(status)") }
	}

	/// The default output changed. The aggregate is clocked by the old device,
	/// which may be gone, so rebuild on the new one and keep the same stream.
	private func outputDeviceChanged() {
		guard graph != nil else { return }
		guard capture != nil else {
			// Idle: rebuild lazily on the next prepare() or start().
			teardownGraph()
			return
		}
		graph?.stop()
		graph?.teardown()
		graph = nil
		ring.markDiscontinuity()
		rebuilds += 1
		do {
			try buildGraph()
			let status = graph?.start() ?? kAudioHardwareUnspecifiedError
			guard status == noErr else { throw SystemAudioTapError.startFailed(status) }
			Self.log.notice("output device changed; system audio graph rebuilt (\(self.rebuilds))")
		} catch {
			Self.log.error("rebuilding after an output device change failed: \(String(describing: error), privacy: .public)")
			Task { await self.stop() }
		}
	}

	// MARK: Closures built outside the actor
	//
	// Core Audio calls these on its own threads. A closure written inside an
	// actor method inherits the actor's isolation and traps there, so they are
	// all created in nonisolated functions.

	private nonisolated static func makeListeners(owner: SystemAudioTap, queue: DispatchQueue) -> [CoreAudioListener] {
		[
			CoreAudioListener(object: CoreAudioProperty.systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak owner] in
				Task { await owner?.outputDeviceChanged() }
			},
			CoreAudioListener(object: CoreAudioProperty.systemObject, selector: kAudioHardwarePropertyProcessObjectList, queue: queue) { [weak owner] in
				Task { await owner?.processesChanged() }
			},
		].compactMap { $0 }
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
				try? await Task.sleep(for: interval, tolerance: .milliseconds(10))
			}
			// stop() stopped IO before cancelling, so this drains everything.
			for chunk in assembler.consume(ring, endOfStream: true) { continuation.yield(chunk) }
			continuation.finish()
		}
	}

	private nonisolated static func stopWhenAbandoned(_ owner: SystemAudioTap) -> @Sendable (AsyncStream<AudioChunk>.Continuation.Termination) -> Void {
		{ [weak owner] termination in
			guard case .cancelled = termination else { return }
			Task { await owner?.stop() }
		}
	}

	/// The IOProc body: meters one buffer and copies channel 0 into the ring.
	/// Realtime thread: no allocation, no locks, no logging.
	package nonisolated static func ingest(
		_ list: UnsafePointer<AudioBufferList>,
		inputTime: AudioTimeStamp,
		sampleRate: Double,
		ticksPerSecond: Double,
		ring: RingBuffer,
		meter: TapMeter
	) {
		let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
		guard let first = buffers.first, let data = first.mData else { return }
		let channels = max(Int(first.mNumberChannels), 1)
		let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
		guard frames > 0 else { return }
		let samples = data.assumingMemoryBound(to: Float.self)
		var peak: Float = 0
		vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frames * channels))
		let duration = UInt64(Double(frames) / sampleRate * ticksPerSecond)
		let hostTime = inputTime.mFlags.contains(.hostTimeValid) ? inputTime.mHostTime : mach_absolute_time() &- duration
		meter.record(peak: peak, hostTime: hostTime)
		ring.write(samples, frameCount: frames, stride: channels, hostTime: hostTime, sampleRate: sampleRate, ticksPerSecond: ticksPerSecond)
	}

	fileprivate nonisolated static func makeIOBlock(ring: RingBuffer, meter: TapMeter, sampleRate: Double) -> AudioDeviceIOBlock {
		let ticksPerSecond = HostClock.ticksPerSecond
		return { _, input, inputTime, _, _ in
			ingest(input, inputTime: inputTime.pointee, sampleRate: sampleRate, ticksPerSecond: ticksPerSecond, ring: ring, meter: meter)
		}
	}
}

/// The Core Audio objects behind one capture. Plain ids, so it can be built
/// outside the actor and handed in.
private struct TapGraph: Sendable {
	let tap: AudioObjectID
	let aggregate: AudioObjectID
	let ioProc: AudioDeviceIOProcID
	let sampleRate: Double

	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "system-audio")

	/// Tap → private aggregate on the default output → IOProc. On failure,
	/// whatever was already created is destroyed again.
	static func make(description: CATapDescription, ring: RingBuffer, meter: TapMeter) throws -> TapGraph {
		var tap = AudioObjectID(kAudioObjectUnknown)
		var status = AudioHardwareCreateProcessTap(description, &tap)
		guard status == noErr else { throw SystemAudioTapError.tapCreationFailed(status) }

		guard let tapFormat = CoreAudioProperty.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()), tapFormat.mSampleRate > 0 else {
			AudioHardwareDestroyProcessTap(tap)
			throw SystemAudioTapError.unreadableTapFormat
		}
		guard let output = CoreAudioProperty.value(CoreAudioProperty.systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0)),
			output != 0,
			let outputUID = CoreAudioProperty.string(output, kAudioDevicePropertyDeviceUID)
		else {
			AudioHardwareDestroyProcessTap(tap)
			throw SystemAudioTapError.noOutputDevice
		}

		let settings: [String: Any] = [
			kAudioAggregateDeviceNameKey: "yap system audio",
			kAudioAggregateDeviceUIDKey: "com.bjornbom.yap.system-audio.\(UUID().uuidString)",
			kAudioAggregateDeviceMainSubDeviceKey: outputUID,
			// Private: other apps never see it in their device lists.
			kAudioAggregateDeviceIsPrivateKey: true,
			kAudioAggregateDeviceIsStackedKey: false,
			kAudioAggregateDeviceTapAutoStartKey: true,
			kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
			kAudioAggregateDeviceTapListKey: [[
				kAudioSubTapDriftCompensationKey: true,
				kAudioSubTapUIDKey: description.uuid.uuidString,
			]],
		]
		var aggregate = AudioObjectID(kAudioObjectUnknown)
		status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
		guard status == noErr else {
			AudioHardwareDestroyProcessTap(tap)
			throw SystemAudioTapError.aggregateCreationFailed(status)
		}

		// With drift compensation the tap is resampled to the aggregate's clock,
		// so buffers arrive at the aggregate's rate, not necessarily the tap's.
		let aggregateRate = CoreAudioProperty.value(aggregate, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
		let sampleRate = aggregateRate > 0 ? aggregateRate : tapFormat.mSampleRate
		if aggregateRate > 0, aggregateRate != tapFormat.mSampleRate {
			log.notice("tap runs at \(tapFormat.mSampleRate) Hz, aggregate at \(aggregateRate) Hz")
		}

		var ioProc: AudioDeviceIOProcID?
		// No dispatch queue: the block runs on the IO thread itself, and only
		// touches the lock-free ring and atomics.
		status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil, SystemAudioTap.makeIOBlock(ring: ring, meter: meter, sampleRate: sampleRate))
		guard status == noErr, let ioProc else {
			AudioHardwareDestroyAggregateDevice(aggregate)
			AudioHardwareDestroyProcessTap(tap)
			throw SystemAudioTapError.ioProcCreationFailed(status)
		}
		return TapGraph(tap: tap, aggregate: aggregate, ioProc: ioProc, sampleRate: sampleRate)
	}

	func start() -> OSStatus {
		AudioDeviceStart(aggregate, ioProc)
	}

	/// Returns once the IOProc can no longer run, so the ring has one producer.
	func stop() {
		AudioDeviceStop(aggregate, ioProc)
	}

	/// Reverse order of creation. Stopping first is harmless if already stopped.
	func teardown() {
		AudioDeviceStop(aggregate, ioProc)
		AudioDeviceDestroyIOProcID(aggregate, ioProc)
		AudioHardwareDestroyAggregateDevice(aggregate)
		AudioHardwareDestroyProcessTap(tap)
	}

	/// Replaces the tap's description (process list) while it runs.
	func update(_ description: CATapDescription) -> OSStatus {
		var address = CoreAudioProperty.address(kAudioTapPropertyDescription)
		var reference = Unmanaged.passUnretained(description)
		return withUnsafeMutablePointer(to: &reference) {
			AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), $0)
		}
	}
}

/// Counters the IOProc updates without locks, read by `statistics` and
/// `looksBlocked` from the actor.
package final class TapMeter: Sendable {
	private let callbacks = Atomic<Int>(0)
	private let audibleCallbacks = Atomic<Int>(0)
	/// Peak as Float bits: for non-negative floats, integer order matches
	/// float order, so a max can be kept with compare-exchange.
	private let peakBits = Atomic<UInt32>(0)
	private let firstHostTime = Atomic<UInt64>(0)

	package init() {}

	package func record(peak: Float, hostTime: UInt64) {
		if callbacks.add(1, ordering: .relaxed).newValue == 1 {
			firstHostTime.store(hostTime, ordering: .relaxed)
		}
		guard peak > 0 else { return }
		audibleCallbacks.add(1, ordering: .relaxed)
		var current = peakBits.load(ordering: .relaxed)
		while Float(bitPattern: current) < peak {
			let (exchanged, original) = peakBits.compareExchange(expected: current, desired: peak.bitPattern, ordering: .relaxed)
			if exchanged { break }
			current = original
		}
	}

	/// Only while no IO callback can run.
	package func reset() {
		callbacks.store(0, ordering: .relaxed)
		audibleCallbacks.store(0, ordering: .relaxed)
		peakBits.store(0, ordering: .relaxed)
		firstHostTime.store(0, ordering: .relaxed)
	}

	package func snapshot() -> (callbacks: Int, audibleCallbacks: Int, peak: Float, firstHostTime: UInt64) {
		(
			callbacks.load(ordering: .relaxed),
			audibleCallbacks.load(ordering: .relaxed),
			Float(bitPattern: peakBits.load(ordering: .relaxed)),
			firstHostTime.load(ordering: .relaxed)
		)
	}
}
