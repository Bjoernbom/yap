import Foundation
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
	}

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
					self?.send(.call(event))
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
			if notes.phase == .idle { notes.toggle() }
		case .stopNotes:
			Logger.notes.notice("Call prompt: clicked, stopping notes")
			if notes.isRecording { notes.toggle() }
		}
	}
}
