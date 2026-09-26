import AppKit
import OSLog
import YapKit

/// Wires call detection to the notch: "on a call? take notes" when a call
/// starts, and "call ended — stop notes?" a while after it ends. The rules
/// live in YapKit's `CallPrompter`; this feeds it detector events, dictation
/// and notes changes, clicks and the setting, and carries out its effects.
///
/// Costs nothing while idle: the detector only listens to Core Audio, and
/// the only timer is the prompter's next deadline.
@MainActor
final class CallPrompt {
	/// The "Offer to take notes on calls" setting (default on).
	static let enabledKey = "offerNotesOnCalls"

	static var isEnabled: Bool {
		AppDefaults.store.object(forKey: enabledKey) as? Bool ?? true
	}

	private let overlay: OverlayController
	private let notes: NotesController
	private let dictation: DictationController
	private var prompter = CallPrompter(isEnabled: CallPrompt.isEnabled)
	private var detector: CallDetector?
	private var watch: Task<Void, Never>?
	private var timer: Task<Void, Never>?
	private var defaultsObserver: NSObjectProtocol?
	#if DEBUG
	private var debugObservers: [NSObjectProtocol] = []
	#endif
	private let clock = ContinuousClock()
	private let origin: ContinuousClock.Instant

	init(overlay: OverlayController, notes: NotesController, dictation: DictationController) {
		self.overlay = overlay
		self.notes = notes
		self.dictation = dictation
		origin = clock.now
	}

	/// Called once at launch.
	func start() {
		overlay.onPromptClick = { [weak self] _ in self?.send(.clicked) }
		dictation.onDictatingChange = { [weak self] dictating in
			self?.send(dictating ? .dictationStarted : .dictationEnded)
		}
		notes.onPhaseChange = { [weak self] phase in
			guard let self else { return }
			// Finishing still counts as running: no offer while the note is
			// being written, since a click couldn't start new notes yet.
			switch phase {
			case .recording: self.send(.notesStarted)
			case .idle: self.send(.notesStopped)
			case .finishing: break
			}
			self.updateDetector()
		}
		notes.overlayWhileRecording = { [weak self] in
			self?.prompter.prompt == .stopNotes ? .prompt(.stopNotes) : nil
		}
		// The Settings toggle writes to the same defaults; any change posts this.
		defaultsObserver = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.settingMayHaveChanged() }
		}
		updateDetector()
		#if DEBUG
		observeFakeCalls()
		#endif
	}

	#if DEBUG
	/// `com.bjornbom.yap.debug.call.started.<pid>` / `.ended.<pid>` feed a
	/// call event straight to the prompter, skipping Core Audio (and the
	/// detector's 3 s minimum), for when no recorder can hold the mic.
	private func observeFakeCalls() {
		let center = DistributedNotificationCenter.default()
		let events: [(String, CallEvent)] = [
			("started", .started(app: .browser("fake call"))),
			("ended", .ended),
		]
		for (name, event) in events {
			debugObservers.append(center.addObserver(
				forName: Notification.Name("com.bjornbom.yap.debug.call.\(name).\(getpid())"), object: nil, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated {
					Logger.notes.notice("Fake call \(name, privacy: .public)")
					self?.send(.call(event))
				}
			})
		}
	}
	#endif

	// MARK: - Inputs

	private func settingMayHaveChanged() {
		let enabled = Self.isEnabled
		guard enabled != prompter.isEnabled else { return }
		Logger.notes.notice("Call prompt \(enabled ? "on" : "off", privacy: .public)")
		send(.enabled(enabled))
		updateDetector()
	}

	/// Listens for calls while offers are on, and while notes run (for the
	/// "call ended" question, whatever the setting).
	private func updateDetector() {
		let wanted = prompter.isEnabled || notes.phase != .idle
		if wanted, detector == nil {
			let detector = CallDetector()
			self.detector = detector
			watch = Task { [weak self] in
				let events = await detector.events()
				for await event in events {
					self?.send(.call(Self.debugRemapped(event)))
				}
			}
		} else if !wanted, let detector {
			watch?.cancel()
			watch = nil
			self.detector = nil
			Task { await detector.stop() }
			// Unheard from now on: a call still running later counts as new.
			if prompter.call != nil { send(.call(.ended)) }
		}
	}

	/// `-YapDebugCallApp <executable>` (Debug only): a recorder with this
	/// name counts as a call app, so verification can fake a call with a CLI
	/// that holds the mic. Real call apps can't be driven headless.
	private nonisolated static func debugRemapped(_ event: CallEvent) -> CallEvent {
		#if DEBUG
		if case .started(.other(let name)) = event,
		   name == UserDefaults.standard.string(forKey: "YapDebugCallApp") {
			return .started(app: .browser(name))
		}
		#endif
		return event
	}

	private func send(_ input: CallPrompter.Input) {
		let effects = prompter.update(input, at: now)
		for effect in effects {
			perform(effect)
		}
		scheduleDeadline()
	}

	private var now: Double {
		let elapsed = (clock.now - origin).components
		return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
	}

	private func scheduleDeadline() {
		timer?.cancel()
		timer = nil
		guard let deadline = prompter.deadline else { return }
		let wake = origin + .milliseconds(Int64((deadline * 1000).rounded(.up)))
		timer = Task { [weak self, clock] in
			try? await Task.sleep(until: wake, tolerance: .milliseconds(50), clock: clock)
			guard !Task.isCancelled else { return }
			self?.send(.tick)
		}
	}

	// MARK: - Effects

	private func perform(_ effect: CallPrompter.Effect) {
		switch effect {
		case .show(.takeNotes(let app)):
			Logger.notes.notice("Call prompt: take notes (\(app.name, privacy: .public))")
			overlay.show(.prompt(.takeNotes))
		case .show(.stopNotes):
			Logger.notes.notice("Call prompt: call ended, stop notes?")
			overlay.show(.prompt(.stopNotes))
		case .hide:
			Logger.notes.notice("Call prompt: dismissed")
			// Something else may own the notch by now (listening, a message).
			guard case .prompt = overlay.state else { return }
			if case .recording(let since) = notes.phase {
				overlay.show(.recording(since: since))
			} else {
				overlay.hide()
			}
		case .startNotes:
			Logger.notes.notice("Call prompt: clicked, starting notes")
			#if DEBUG
			logFocus()
			#endif
			if notes.phase == .idle { notes.toggle() }
		case .stopNotes:
			Logger.notes.notice("Call prompt: clicked, stopping notes")
			#if DEBUG
			logFocus()
			#endif
			if notes.isRecording { notes.toggle() }
		}
	}

	#if DEBUG
	/// A click on the prompt must leave focus where it was.
	private func logFocus() {
		let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
		let key = overlay.debugPanel?.isKeyWindow ?? false
		Logger.notes.notice("Call prompt click: key=\(key, privacy: .public) front=\(front, privacy: .public) yapActive=\(NSApp.isActive, privacy: .public)")
	}
	#endif
}
