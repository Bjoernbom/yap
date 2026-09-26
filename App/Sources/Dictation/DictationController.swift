import AppKit
import Carbon.HIToolbox
import Observation
import OSLog
import YapKit

/// Wires YapKit's dictation pipeline into the app: builds the session, keeps
/// the model and mic ready, gates the hotkey on permissions and readiness, and
/// drives the notch from the session's states and levels.
@MainActor
@Observable
final class DictationController {
	enum ModelStatus: Equatable {
		/// `fraction` while downloading; nil while loading or compiling.
		case loading(fraction: Double?)
		case ready
		case failed
	}

	/// Notch lines in yap's voice (plan section 7): what happened, what to do.
	enum Message {
		static let emptyTranscript = "Didn't catch that."
		static let needsMicrophone = "yap can't hear you yet. Grant access in the menu."
		static let modelFailed = "Couldn't load the speech model. Trying again."
		static let nothingToPaste = "Nothing to paste yet."
		static let gettingReadyPrefix = "Getting ready…"

		static func gettingReady(_ fraction: Double?) -> String {
			guard let fraction else { return gettingReadyPrefix }
			return "\(gettingReadyPrefix) \(Int((fraction * 100).rounded()))%"
		}
	}

	private static let triggerKey = "trigger"

	let permissions = Permissions()
	let history: HistoryAccess
	private(set) var trigger: HotkeyTrigger
	private(set) var modelStatus = ModelStatus.loading(fraction: nil)
	/// The event tap couldn't be created even though Accessibility is on.
	private(set) var hotkeyFailed = false
	/// Bumped whenever history may have changed, so the window reloads.
	private(set) var historyRevision = 0

	@ObservationIgnored private let overlay: OverlayController
	@ObservationIgnored private let monitor: HotkeyMonitor
	@ObservationIgnored private let mic = MicCapture()
	@ObservationIgnored private let engine = ParakeetEngine()
	@ObservationIgnored private var session: DictationSession?
	@ObservationIgnored private var micPrepared = false
	@ObservationIgnored private var preparing: Task<Void, Never>?
	@ObservationIgnored private var permissionPoll: Task<Void, Never>?
	@ObservationIgnored private var loops: [Task<Void, Never>] = []
	@ObservationIgnored private var activationObserver: NSObjectProtocol?
	@ObservationIgnored private var pasteLastKey: GlobalHotKey?
	/// A start reached the session, so its stop, lock or cancel must too.
	/// Presses made before the model was ready never do.
	@ObservationIgnored private var forwarding = false
	@ObservationIgnored private var keyUpAt: ContinuousClock.Instant?
	/// Feeds the notch's waveform during one listening stretch.
	@ObservationIgnored private var levelSink: AsyncStream<Float>.Continuation?
	@ObservationIgnored private var lastLoggedStatus = ""

	init(overlay: OverlayController) {
		self.overlay = overlay
		let saved = UserDefaults.standard.string(forKey: Self.triggerKey).flatMap(HotkeyTrigger.init(rawValue:))
		let trigger = saved ?? .fn
		self.trigger = trigger
		monitor = HotkeyMonitor(trigger: trigger)
		var historyURL: URL?
		#if DEBUG
		// Verification runs against a scratch database, not the real history.
		historyURL = UserDefaults.standard.string(forKey: "YapHistoryPath").map { URL(filePath: $0) }
		#endif
		history = HistoryAccess(url: historyURL)
	}

	/// Called once at launch.
	func start() {
		let hotkeyActions = monitor.actions()
		loops.append(Task { [weak self] in
			for await action in hotkeyActions {
				await self?.handle(action)
			}
		})
		activationObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.checkPermissions() }
		}
		pasteLastKey = GlobalHotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | cmdKey) { [weak self] in
			self?.pasteLast()
		}
		Task { [history] in
			await history.open { [weak self] in
				await self?.historyChanged()
			}
		}
		checkPermissions()
		prepareModel()
	}

	var statusLine: String {
		if let missing = permissions.missingSummary { return missing }
		if hotkeyFailed { return "Can't see the \(trigger.displayName) key. Quit and reopen yap." }
		switch modelStatus {
		case .loading(let fraction?): return "Downloading model… \(Int((fraction * 100).rounded()))%"
		case .loading(nil): return "Loading model…"
		case .failed: return "Couldn't load the speech model"
		case .ready: return "Ready — hold \(trigger.displayName) to talk"
		}
	}

	var needsPermissions: Bool { !permissions.allGranted }

	func setTrigger(_ trigger: HotkeyTrigger) {
		guard trigger != self.trigger else { return }
		self.trigger = trigger
		UserDefaults.standard.set(trigger.rawValue, forKey: Self.triggerKey)
		monitor.setTrigger(trigger)
		logStatus()
	}

	func grantAccess() async {
		await permissions.request()
		checkPermissions()
	}

	func pasteLast() {
		guard let session else {
			overlay.show(.message(Message.nothingToPaste))
			return
		}
		Task {
			let outcome = await session.pasteLast()
			// Nil also means a dictation is running; its notch stays untouched.
			if outcome == nil, ![.listening, .working].contains(overlay.state) {
				overlay.show(.message(Message.nothingToPaste))
			}
		}
	}

	// MARK: - Permissions

	/// Re-reads permissions and starts whatever they unlock. Polls while
	/// something is missing: the user flips the switch in System Settings,
	/// which activates nothing of ours.
	private func checkPermissions() {
		permissions.refresh()
		if permissions.accessibility, !monitor.isRunning {
			do {
				try monitor.start()
				hotkeyFailed = false
			} catch {
				Logger.dictation.error("Hotkey tap failed: \(String(describing: error), privacy: .public)")
				hotkeyFailed = true
			}
		}
		// Only once granted: touching the input unit earlier would pop the
		// Microphone prompt at launch instead of when the user asks for it.
		if permissions.hasMicrophone, !micPrepared {
			micPrepared = true
			Task { [mic] in
				do {
					try await mic.prepare()
				} catch {
					// `start()` prepares again and reports a real failure then.
					Logger.dictation.error("Mic prepare failed: \(String(describing: error), privacy: .public)")
				}
			}
		}
		if permissions.allGranted, monitor.isRunning || hotkeyFailed {
			permissionPoll?.cancel()
			permissionPoll = nil
		} else if permissionPoll == nil {
			permissionPoll = Task { [weak self] in
				while !Task.isCancelled {
					try? await Task.sleep(for: .seconds(2))
					self?.checkPermissions()
				}
			}
		}
		logStatus()
	}

	// MARK: - Model

	private func prepareModel() {
		guard preparing == nil, modelStatus != .ready else { return }
		setModelStatus(.loading(fraction: nil))
		// FluidAudio reports from its own queue; hop to the main actor.
		let relay: @Sendable (ModelProgress) -> Void = { [weak self] progress in
			guard let self else { return }
			Task { @MainActor in self.modelProgressed(progress) }
		}
		preparing = Task { [weak self, engine] in
			do {
				// The VAD is ~1 MB and loads in milliseconds from the cache. The
				// session exists from here on, so paste last works while the
				// speech model is still on its way.
				if self?.session == nil {
					let vad = try await SileroVAD.load()
					self?.makeSession(vad: vad)
				}
				#if DEBUG
				let delay = UserDefaults.standard.double(forKey: "YapModelDelay")
				if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
				#endif
				try await engine.prepare(progress: relay)
				self?.setModelStatus(.ready)
			} catch {
				Logger.dictation.error("Model prepare failed: \(String(describing: error), privacy: .public)")
				self?.setModelStatus(.failed)
			}
			self?.preparing = nil
		}
	}

	private func modelProgressed(_ progress: ModelProgress) {
		// Progress hops here in its own task and can land after `.ready`.
		guard modelStatus != .ready else { return }
		switch progress {
		case .downloading(let fraction): setModelStatus(.loading(fraction: fraction))
		case .compiling: setModelStatus(.loading(fraction: nil))
		case .ready: break // The session is ready once `prepare` returns.
		}
	}

	private func setModelStatus(_ status: ModelStatus) {
		guard status != modelStatus else { return }
		modelStatus = status
		if status == .ready {
			Logger.dictation.notice("Speech model ready")
		}
		// Someone is holding the key and watching the percentage.
		if case .message(let text) = overlay.state, text.hasPrefix(Message.gettingReadyPrefix),
		   case .loading(let fraction) = status {
			overlay.show(.message(Message.gettingReady(fraction)))
		}
		logStatus()
	}

	private func makeSession(vad: SileroVAD) {
		let session = DictationSession(
			hotkey: monitor,
			audio: mic,
			engine: engine,
			transcription: StreamingTranscriber(engine: engine, vad: vad),
			processor: NoTextProcessing(),
			inserter: Inserter(),
			history: history
		)
		self.session = session
		let states = session.states
		loops.append(Task { [weak self] in
			for await state in states {
				self?.apply(state)
			}
		})
		let levels = session.levels
		loops.append(Task { [weak self] in
			for await level in levels {
				self?.levelSink?.yield(level)
			}
		})
	}

	// MARK: - Hotkey

	/// Only presses made while everything is ready reach the session; the rest
	/// get a notch line instead of silently doing nothing.
	private func handle(_ action: HotkeyAction) async {
		Logger.dictation.debug("Hotkey \(String(describing: action), privacy: .public)")
		switch action {
		case .start:
			if let blocker = startBlocker() {
				overlay.show(.message(blocker))
				return
			}
			guard let session else { return }
			forwarding = true
			await session.handle(.start)
		case .stop, .cancel, .lock:
			guard forwarding, let session else { return }
			if action == .stop {
				keyUpAt = .now
			}
			if action != .lock {
				forwarding = false
			}
			await session.handle(action)
		}
	}

	private func startBlocker() -> String? {
		if !permissions.hasMicrophone { return Message.needsMicrophone }
		switch modelStatus {
		case .ready:
			return session == nil ? Message.gettingReady(nil) : nil
		case .loading(let fraction):
			return Message.gettingReady(fraction)
		case .failed:
			prepareModel()
			return Message.modelFailed
		}
	}

	// MARK: - Notch

	private func apply(_ state: DictationState) {
		switch state {
		case .idle:
			endLevels()
			// After a result the notch closes by itself; after a cancel, now.
			if [.listening, .working].contains(overlay.state) {
				overlay.hide()
			}
		case .listening:
			if overlay.state != .listening {
				startLevels()
				overlay.show(.listening)
			}
		case .transcribing:
			endLevels()
			overlay.show(.working)
		case .done(let outcome):
			logInsertion(outcome)
			historyChanged()
			if let message = outcome.message {
				overlay.show(.message(message))
			} else {
				overlay.show(.done)
			}
		case .empty:
			keyUpAt = nil
			overlay.show(.message(Message.emptyTranscript))
		case .failed(let message):
			keyUpAt = nil
			overlay.show(.message(message))
		}
	}

	private func startLevels() {
		endLevels()
		let (stream, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(8))
		levelSink = continuation
		overlay.follow(levels: stream)
	}

	private func endLevels() {
		levelSink?.finish()
		levelSink = nil
	}

	private func historyChanged() {
		historyRevision &+= 1
	}

	// MARK: - Diagnostics

	/// Key-up → inserted, the plan's headline latency budget (< 300 ms).
	private func logInsertion(_ outcome: InsertOutcome) {
		guard let keyUpAt else {
			Logger.dictation.notice("Paste last: \(String(describing: outcome), privacy: .public)")
			return
		}
		self.keyUpAt = nil
		let elapsed = ContinuousClock.now - keyUpAt
		let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
		Logger.dictation.notice("Key-up to \(String(describing: outcome), privacy: .public): \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
	}

	private func logStatus() {
		let status = statusLine
		guard status != lastLoggedStatus else { return }
		lastLoggedStatus = status
		Logger.dictation.notice("Status: \(status, privacy: .public)")
	}
}

extension HotkeyTrigger {
	/// How the key is named in the menu and settings.
	var displayName: String {
		switch self {
		case .fn: "fn"
		case .rightOption: "right ⌥"
		}
	}
}

extension Logger {
	static let dictation = Logger(subsystem: "com.bjornbom.yap", category: "app")
}
