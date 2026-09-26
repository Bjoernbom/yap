import CoreAudio
import Foundation
import os

/// Notices when another app starts a call, so the notch can offer notes.
/// Needs no permission: it only reads Core Audio's device and process state.
///
/// How: listen to `DeviceIsRunningSomewhere` on every input device. When it
/// changes, rescan Core Audio's process list for processes with
/// `IsRunningInput` (a listener on that property never fires, and the
/// process-list listener fires before the flag is set, hence the rescan).
/// While any input runs, rescan every `pollInterval` as well: a second app
/// joining a mic that is already running doesn't change the device flag.
/// Device list and default input changes re-register the listeners.
/// `CallDebouncer` turns the samples into `.started` / `.ended`.
public actor CallDetector {
	public nonisolated let pollInterval: Duration

	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "calls")

	private var debouncer: CallDebouncer
	private let excluded: Set<pid_t>
	private let queue = DispatchQueue(label: "com.bjornbom.yap.calls")
	private var systemListeners: [CoreAudioListener] = []
	private var deviceListeners: [AudioDeviceID: CoreAudioListener] = [:]
	private var continuation: AsyncStream<CallEvent>.Continuation?
	private var ticker: Task<Void, Never>?
	private var names: [pid_t: CallApp] = [:]

	/// Processes other than yap using the mic at the last scan.
	public private(set) var recorders: [(pid: pid_t, app: CallApp)] = []

	/// - Parameters:
	///   - minimumDuration: mic use shorter than this is not a call.
	///   - endGrace: how long the mic must stay free before the call ends.
	///   - excludedPIDs: processes to ignore besides yap itself.
	public init(
		minimumDuration: Duration = .seconds(3),
		endGrace: Duration = .seconds(1),
		pollInterval: Duration = .milliseconds(500),
		excludedPIDs: Set<pid_t> = []
	) {
		debouncer = CallDebouncer(minimumDuration: minimumDuration.seconds, endGrace: endGrace.seconds)
		excluded = excludedPIDs.union([getpid()])
		self.pollInterval = pollInterval
	}

	/// The call in progress, if any.
	public var activeCall: CallApp? { debouncer.activeCall }

	/// Starts watching and returns the events. A second call finishes the
	/// previous stream. Cancelling the consumer stops watching.
	public func events() -> AsyncStream<CallEvent> {
		continuation?.finish()
		let (stream, continuation) = AsyncStream.makeStream(of: CallEvent.self, bufferingPolicy: .unbounded)
		self.continuation = continuation
		continuation.onTermination = Self.stopWhenAbandoned(self)
		if systemListeners.isEmpty {
			systemListeners = Self.makeSystemListeners(owner: self, queue: queue)
			registerDevices()
		}
		// A call already running when we start counts from now.
		rescan()
		return stream
	}

	public func stop() {
		ticker?.cancel()
		ticker = nil
		systemListeners = []
		deviceListeners = [:]
		continuation?.finish()
		continuation = nil
	}

	// MARK: Scanning

	private func registerDevices() {
		let inputs = Set(DevicePolicy.inputDevices().map(\.id))
		for id in deviceListeners.keys where !inputs.contains(id) {
			deviceListeners[id] = nil
		}
		for id in inputs where deviceListeners[id] == nil {
			deviceListeners[id] = Self.makeDeviceListener(device: id, owner: self, queue: queue)
		}
	}

	private func devicesChanged() {
		guard continuation != nil else { return }
		registerDevices()
		rescan()
	}

	private func rescan() {
		guard let continuation else { return }
		let now = HostClock.seconds(HostClock.now())
		let processes = AudioProcess.all().filter { $0.isRunningInput && !excluded.contains($0.pid) }
		recorders = processes.map { ($0.pid, name(of: $0)) }
		names = names.filter { pid, _ in processes.contains { $0.pid == pid } }
		for event in debouncer.update(recorders: recorders.map(\.app), at: now) {
			switch event {
			case .started(let app): Self.log.notice("call started: \(app.name, privacy: .public)")
			case .ended: Self.log.notice("call ended")
			}
			continuation.yield(event)
		}
		scheduleTicker()
	}

	private func name(of process: AudioProcess) -> CallApp {
		if let known = names[process.pid] { return known }
		let app = CallApp.identify(bundleID: process.bundleID, executablePath: AudioProcess.executablePath(of: process.pid))
		names[process.pid] = app
		return app
	}

	/// Keeps sampling while the mic is in use or a deadline is pending, and
	/// has no task at all otherwise.
	private func scheduleTicker() {
		guard ticker == nil, needsTicker else { return }
		ticker = Task { [weak self] in
			while let wait = await self?.nextWait() {
				try? await Task.sleep(for: wait, tolerance: .milliseconds(20))
				if Task.isCancelled { return }
				await self?.rescan()
			}
		}
	}

	private var needsTicker: Bool {
		continuation != nil && (!recorders.isEmpty || debouncer.deadline != nil)
	}

	/// Called from the ticker task; nil ends it.
	private func nextWait() -> Duration? {
		// A cancelled ticker must not clear its replacement.
		guard !Task.isCancelled else { return nil }
		guard needsTicker else {
			ticker = nil
			return nil
		}
		var wait = pollInterval
		if let deadline = debouncer.deadline {
			let untilDeadline = deadline - HostClock.seconds(HostClock.now())
			wait = min(wait, .seconds(max(untilDeadline, 0)))
		}
		return wait
	}

	// MARK: Closures built outside the actor

	private nonisolated static func makeSystemListeners(owner: CallDetector, queue: DispatchQueue) -> [CoreAudioListener] {
		let system = CoreAudioProperty.systemObject
		let devices: @Sendable () -> Void = { [weak owner] in Task { await owner?.devicesChanged() } }
		let processes: @Sendable () -> Void = { [weak owner] in Task { await owner?.rescan() } }
		return [
			CoreAudioListener(object: system, selector: kAudioHardwarePropertyDevices, queue: queue, onChange: devices),
			CoreAudioListener(object: system, selector: kAudioHardwarePropertyDefaultInputDevice, queue: queue, onChange: devices),
			CoreAudioListener(object: system, selector: kAudioHardwarePropertyProcessObjectList, queue: queue, onChange: processes),
		].compactMap { $0 }
	}

	private nonisolated static func makeDeviceListener(device: AudioDeviceID, owner: CallDetector, queue: DispatchQueue) -> CoreAudioListener? {
		CoreAudioListener(object: device, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, queue: queue) { [weak owner] in
			Task { await owner?.rescan() }
		}
	}

	private nonisolated static func stopWhenAbandoned(_ owner: CallDetector) -> @Sendable (AsyncStream<CallEvent>.Continuation.Termination) -> Void {
		{ [weak owner] termination in
			guard case .cancelled = termination else { return }
			Task { await owner?.stop() }
		}
	}
}

private extension Duration {
	var seconds: Double {
		let parts = components
		return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
	}
}
