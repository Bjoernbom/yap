import Dispatch
import FluidAudio
import Foundation
import os
import Synchronization

public enum SpeechError: Error, Equatable, Sendable {
	/// Parakeet refuses anything under 0.3 s.
	case audioTooShort(seconds: Double)
	/// `prepare` has never succeeded. Transcription never starts a 600 MB
	/// download on its own; that belongs to onboarding.
	case modelNotPrepared
}

/// Which Parakeet weights to run.
public enum ParakeetModel: String, Sendable, CaseIterable {
	/// Same speed and API as v3, 2.3 pp lower WER on Swedish (603 MB).
	case ultra
	/// The fallback (461 MB).
	case v3

	/// The one place the model is chosen.
	public static let preferred: ParakeetModel = .ultra

	var version: AsrModelVersion {
		switch self {
		case .ultra: .ultra
		case .v3: .v3
		}
	}
}

/// Parakeet TDT on the Neural Engine via FluidAudio.
///
/// The ANE holds ~0.6 GB of weights on our behalf that Activity Monitor
/// doesn't show, so the engine gives them back on a memory-pressure warning
/// and loads again (0.4 s from the compile cache) the next time it's needed.
public actor ParakeetEngine: SpeechEngine {
	public static let minimumDuration = 0.3
	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "speech")

	public let model: ParakeetModel
	private let modelDirectory: URL?
	private var manager: AsrManager?
	private var loading: Task<AsrManager, Error>?
	private let progressRelay = ProgressRelay()
	/// Set once `prepare` succeeds; after that a lazy reload is allowed.
	private var prepared = false
	private var activeCalls = 0
	private var unloadWhenIdle = false
	private let pressureSource: any DispatchSourceMemoryPressure

	/// - Parameter modelDirectory: where the model lives; nil uses
	///   FluidAudio's cache in Application Support.
	public init(model: ParakeetModel = .preferred, modelDirectory: URL? = nil) {
		self.model = model
		self.modelDirectory = modelDirectory
		// Critical only. On a Mac that lives at the warning level (a busy 18 GB
		// machine with VMs) unloading on warnings meant a reload, and a stall
		// while ~600 MB came back from swap, on nearly every dictation.
		let source = DispatchSource.makeMemoryPressureSource(
			eventMask: .critical, queue: .global(qos: .utility))
		pressureSource = source
		source.setEventHandler { [weak self] in
			guard let self else { return }
			Task { await self.handleMemoryPressure() }
		}
		source.activate()
	}

	deinit {
		pressureSource.cancel()
	}

	public var isLoaded: Bool { manager != nil }

	public func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
		if manager == nil {
			let id = progressRelay.add(progress)
			defer { progressRelay.remove(id) }
			_ = try await loadedManager(allowDownload: true)
		}
		progress(.ready)
	}

	public func warmUp() async {
		// Best effort: this only wakes the ANE (it naps after ~1 min idle and
		// the first call then costs 2–4×). Real problems surface in `transcribe`.
		_ = try? await transcribe([Float](repeating: 0, count: Int(AudioChunk.sampleRate)))
	}

	public func transcribe(_ samples: [Float]) async throws -> Transcript {
		let seconds = Double(samples.count) / AudioChunk.sampleRate
		guard seconds >= Self.minimumDuration else { throw SpeechError.audioTooShort(seconds: seconds) }
		let manager = try await loadedManager(allowDownload: false)
		activeCalls += 1
		// A fresh decoder state per call: carrying it across chunks made no
		// consistent difference in the spike, and fresh is simpler.
		var state = TdtDecoderState.make(decoderLayers: model.version.decoderLayers)
		let result: ASRResult
		do {
			result = try await manager.transcribe(samples, decoderState: &state)
		} catch {
			await endCall()
			throw error
		}
		await endCall()
		let words = buildWordTimings(from: result.tokenTimings ?? []).map {
			TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
		}
		return Transcript(
			text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
			confidence: result.confidence, words: words)
	}

	/// Frees the Neural Engine memory. Waits for running transcriptions to
	/// finish first; a load already in flight still completes.
	public func unload() async {
		guard activeCalls == 0 else {
			unloadWhenIdle = true
			return
		}
		unloadWhenIdle = false
		guard let manager else { return }
		self.manager = nil
		await manager.cleanup()
	}

	private func endCall() async {
		activeCalls -= 1
		if activeCalls == 0 && unloadWhenIdle { await unload() }
	}

	private func handleMemoryPressure() async {
		guard manager != nil else { return }
		Self.log.notice("Memory pressure: unloading the speech model")
		await unload()
	}

	/// One load at a time: concurrent callers share the task in flight.
	private func loadedManager(allowDownload: Bool) async throws -> AsrManager {
		if let manager { return manager }
		let task: Task<AsrManager, Error>
		if let loading {
			task = loading
		} else {
			guard allowDownload || prepared else { throw SpeechError.modelNotPrepared }
			task = Task { [model, modelDirectory, progressRelay] in
				try await Self.load(model: model, directory: modelDirectory, progress: progressRelay)
			}
			loading = task
		}
		do {
			let loaded = try await task.value
			if loading == task { loading = nil }
			// Another caller may have finished (or unloaded) meanwhile; the
			// first result to land wins, the rest reuse it.
			if manager == nil { manager = loaded }
			prepared = true
			return loaded
		} catch {
			if loading == task { loading = nil }
			throw error
		}
	}

	private static func load(
		model: ParakeetModel, directory: URL?, progress: ProgressRelay
	) async throws -> AsrManager {
		let version = model.version
		let target = directory ?? AsrModels.defaultCacheDirectory(for: version)
		progress.restart()
		if !AsrModels.modelsExist(at: target, version: version) {
			progress.send(.downloading(fraction: 0))
			try await AsrModels.download(to: target, version: version, progressHandler: progress.handle)
		}
		// From the cache this is a 0.4 s load; right after a download it's the
		// one-time 17–21 s ANE compile.
		progress.send(.compiling)
		let models = try await AsrModels.load(from: target, version: version)
		let manager = AsrManager(config: .default)
		try await manager.loadModels(models)
		return manager
	}
}

/// Fans FluidAudio's download progress out to every `prepare` caller, mapped
/// to `ModelProgress`. FluidAudio calls from its own queue, hence the lock.
private final class ProgressRelay: Sendable {
	private struct State {
		var observers: [Int: @Sendable (ModelProgress) -> Void] = [:]
		var nextID = 0
		/// Once compiling, later download ticks (FluidAudio reports each
		/// model file as its own operation) would make the UI jump backwards.
		var compiling = false
	}

	private let state = Mutex(State())

	func add(_ observer: @escaping @Sendable (ModelProgress) -> Void) -> Int {
		state.withLock {
			let id = $0.nextID
			$0.nextID += 1
			$0.observers[id] = observer
			return id
		}
	}

	func remove(_ id: Int) {
		state.withLock { _ = $0.observers.removeValue(forKey: id) }
	}

	func restart() {
		state.withLock { $0.compiling = false }
	}

	func send(_ progress: ModelProgress) {
		let observers = state.withLock { state -> [@Sendable (ModelProgress) -> Void] in
			if case .compiling = progress { state.compiling = true }
			if case .downloading = progress, state.compiling { return [] }
			return Array(state.observers.values)
		}
		observers.forEach { $0(progress) }
	}

	func handle(_ progress: DownloadProgress) {
		switch progress.phase {
		case .listing, .downloading:
			// FluidAudio spends the first half of the fraction on the download
			// and the second half on compiling.
			send(.downloading(fraction: min(progress.fractionCompleted / 0.5, 1)))
		case .compiling:
			send(.compiling)
		}
	}
}

