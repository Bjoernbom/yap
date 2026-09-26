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
		static let gettingReadyPrefix = "Almost ready…"

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
	/// Bumped when a dictation is typed into one of yap's own windows, so
	/// onboarding's "try it" box knows its text came from the voice.
	private(set) var ownWindowInsertions = 0
	/// The last model failure looked like no network: the first download
	/// needs one, so onboarding says so instead of a generic line.
	private(set) var modelFailedOffline = false

	@ObservationIgnored private let overlay: OverlayController
	@ObservationIgnored private let monitor: HotkeyMonitor
	@ObservationIgnored private let mic = MicCapture()
	@ObservationIgnored private let engine = ParakeetEngine()
	@ObservationIgnored private var session: DictationSession?
	/// Cleanup, dictionary and polish; set by AppModel before `start()`.
	@ObservationIgnored var processor: any TextProcessing = NoTextProcessing()
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
	@ObservationIgnored private var keyDownAt: ContinuousClock.Instant?
	/// Feeds the notch's waveform during one listening stretch.
	@ObservationIgnored private var levelSink: AsyncStream<Float>.Continuation?
	/// Listening started but the notch isn't showing it yet: a stray tap of
	/// the key (common with Fn) must not flash the notch.
	@ObservationIgnored private var awaitingReveal = false
	@ObservationIgnored private var revealTask: Task<Void, Never>?
	@ObservationIgnored private var lastLoggedStatus = ""

	init(overlay: OverlayController) {
		self.overlay = overlay
		let saved = AppDefaults.store.string(forKey: Self.triggerKey).flatMap(HotkeyTrigger.init(rawValue:))
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
		AppDefaults.store.set(trigger.rawValue, forKey: Self.triggerKey)
		monitor.setTrigger(trigger)
		logStatus()
	}

	/// Tries the model again after a failed download or load.
	func retryModel() {
		prepareModel()
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
	func checkPermissions() {
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
		modelFailedOffline = false
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
				try await Self.debugHoldModel(progress: relay)
				#endif
				try await engine.prepare(progress: relay)
				self?.setModelStatus(.ready)
			} catch {
				Logger.dictation.error("Model prepare failed: \(String(describing: error), privacy: .public)")
				self?.modelFailedOffline = Self.isOffline(error)
				self?.setModelStatus(.failed)
			}
			self?.preparing = nil
		}
	}

	private static func isOffline(_ error: any Error) -> Bool {
		var current: NSError? = error as NSError
		// FluidAudio may wrap the URL error; walk the underlying chain.
		while let nsError = current {
			if nsError.domain == NSURLErrorDomain { return true }
			current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
		}
		return false
	}

	#if DEBUG
	/// `-YapModelDelay <s>` holds the model back, reporting a fake download
	/// for the first 80 % of the delay and compiling for the rest, so the
	/// onboarding progress and "not ready yet" paths can be seen with a
	/// cached model. `-YapModelFailOnce YES` fails the first attempt as if
	/// offline, to exercise the retry.
	private static var debugFailedOnce = false

	private static func debugHoldModel(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
		if UserDefaults.standard.bool(forKey: "YapModelFailOnce"), !debugFailedOnce {
			debugFailedOnce = true
			try? await Task.sleep(for: .seconds(1.5))
			throw URLError(.notConnectedToInternet)
		}
		let delay = UserDefaults.standard.double(forKey: "YapModelDelay")
		guard delay > 0 else { return }
		let start = ContinuousClock.now
		let total = Duration.seconds(delay)
		while ContinuousClock.now - start < total {
			let elapsed = ContinuousClock.now - start
			let fraction = elapsed / total
			progress(fraction < 0.8 ? .downloading(fraction: fraction / 0.8) : .compiling)
			try? await Task.sleep(for: .milliseconds(250))
		}
	}
	#endif

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
			processor: processor,
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
				self?.levelArrived(level)
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
			keyDownAt = .now
			// Lets polish prewarm its model while the user talks.
			let app = NSWorkspace.shared.frontmostApplication
			let processor = self.processor
			Task { await processor.prepare(for: app.map { FocusTarget(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }) }
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

	/// How long the key must be held before the notch shows listening. Long
	/// enough to swallow a stray tap (~100 ms), short enough that a real hold
	/// still sees the notch right away (budget: 200 ms).
	private static let revealDelay: Duration = .milliseconds(150)
	/// A level this loud (about -39 dBFS) while the key is held is speech,
	/// not room noise: show the notch without waiting out the delay.
	private static let audibleLevel: Float = 0.35
	/// A press that ended, as a tap or as too little audio, within this long
	/// of key-down was an accident: close without a shrink or a message. It
	/// covers the 300 ms tap threshold plus the 300 ms double-tap window.
	private static let strayPress: Duration = .milliseconds(700)

	private func apply(_ state: DictationState) {
		let pressWasStray = keyDownAt.map { (keyUpAt ?? .now) - $0 < Self.strayPress } ?? false
		if state != .listening(locked: false) {
			cancelReveal()
		}
		switch state {
		case .idle:
			keyDownAt = nil
			endLevels()
			// After a result the notch closes by itself; after a cancel, now.
			if [.listening, .working].contains(overlay.state) {
				overlay.hide(animated: !pressWasStray)
			}
		case .listening(let locked):
			guard overlay.state != .listening else { break }
			// Hands-free was chosen on purpose (double-tap): show it right away.
			if locked {
				revealListening()
			} else if !awaitingReveal {
				deferReveal()
			}
		case .transcribing:
			endLevels()
			overlay.show(.working)
		case .done(let outcome):
			logInsertion(outcome)
			historyChanged()
			if outcome == .direct {
				ownWindowInsertions &+= 1
			}
			if let message = outcome.message {
				overlay.show(.message(message))
			} else {
				overlay.show(.done)
			}
		case .empty:
			keyUpAt = nil
			if pressWasStray {
				overlay.hide(animated: false)
			} else {
				overlay.show(.message(Message.emptyTranscript))
			}
		case .failed(let message):
			keyUpAt = nil
			overlay.show(.message(message))
		}
	}

	/// Shows listening once the key has been held for `revealDelay`. A tap
	/// has already been released by then (it emits no action on release, as
	/// it may turn into a double-tap), so ask the monitor for the key itself.
	private func deferReveal() {
		awaitingReveal = true
		revealTask = Task { [weak self] in
			try? await Task.sleep(for: Self.revealDelay)
			guard !Task.isCancelled, let self, self.awaitingReveal, self.monitor.isTriggerHeld else { return }
			self.revealListening()
		}
	}

	private func revealListening() {
		cancelReveal()
		startLevels()
		overlay.show(.listening)
		if let keyDownAt {
			Logger.dictation.notice("Key-down to listening shown: \(Self.milliseconds(since: keyDownAt), format: .fixed(precision: 1), privacy: .public) ms")
		}
	}

	private func cancelReveal() {
		awaitingReveal = false
		revealTask?.cancel()
		revealTask = nil
	}

	private func levelArrived(_ level: Float) {
		if awaitingReveal, level >= Self.audibleLevel, monitor.isTriggerHeld {
			revealListening()
		}
		levelSink?.yield(level)
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
		let milliseconds = Self.milliseconds(since: keyUpAt)
		Logger.dictation.notice("Key-up to \(String(describing: outcome), privacy: .public): \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
	}

	private static func milliseconds(since instant: ContinuousClock.Instant) -> Double {
		let elapsed = ContinuousClock.now - instant
		return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
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
