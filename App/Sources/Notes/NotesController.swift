import AppKit
import Carbon.HIToolbox
import Observation
import OSLog
import YapKit

/// Wires YapKit's `NotesSession` into the app: start and stop from the menu
/// or ⌥⌘N, the red dot and timer in the notch, the live transcript, and the
/// finished note on disk and in its window.
@MainActor
@Observable
final class NotesController {
	enum Phase: Equatable {
		case idle
		case recording(since: Date)
		/// Stopped; tails, diarization and the summary are being finished.
		case finishing
	}

	/// Notch lines in yap's voice.
	enum Message {
		static let consent = "Let people know you're taking notes."
		static let nothingToWrite = "Nothing to write down."
		static let couldNotStart = "Couldn't start notes. Try again."
		static let couldNotSave = "Couldn't save the note. It's on your clipboard."
		static let micBusy = "Finish dictating first."
		/// The note window has the full line with the path.
		static let savedElsewhere = "Couldn't use your notes folder. Saved elsewhere."
		/// A note line: the tap delivered only zeros, which is what missing
		/// permission looks like.
		static let systemAudioBlocked = "The other side of the call wasn't recorded. Allow yap under System Settings → Privacy & Security → Screen & System Audio Recording."
	}

	/// Which window the menu bar label should open next (it owns
	/// `openWindow`); the counter makes a repeat request observable.
	struct WindowRequest: Equatable {
		var id: String
		var serial: Int
	}

	private static let consentKey = "notesConsentShown"
	/// The notes folder setting (a path). Also settable with the launch
	/// argument `-notesFolder <dir>`, which verification uses.
	static let folderKey = "notesFolder"

	private(set) var phase = Phase.idle {
		didSet {
			if phase != oldValue { onPhaseChange?(phase) }
		}
	}
	/// Called when `phase` changes, for the call prompt.
	@ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
	/// What the notch goes back to after a flash while recording, when it
	/// isn't the plain red dot and timer (a "call ended" prompt).
	@ObservationIgnored var overlayWhileRecording: (() -> OverlayState?)?
	private(set) var liveSegments: [NoteSegment] = []
	/// Recording without the system-audio track.
	private(set) var isMicOnly = false
	/// The tap runs but hears only zeros while something plays: System
	/// Audio Recording isn't allowed.
	private(set) var isSystemAudioBlocked = false
	/// The last finished note, for the note window.
	private(set) var lastNote: FinishedNote?
	private(set) var windowRequest: WindowRequest?

	@ObservationIgnored private let overlay: OverlayController
	@ObservationIgnored private let dictation: DictationController
	@ObservationIgnored private var session: NotesSession?
	/// The "them" track while recording, to ask it about permission at stop.
	@ObservationIgnored private var tap: SystemAudioTap?
	@ObservationIgnored private var callDetector: CallDetector?
	@ObservationIgnored private var callWatch: Task<Void, Never>?
	/// Call apps seen while recording, for the note's front matter.
	@ObservationIgnored private var callApps: [String] = []
	@ObservationIgnored private var blockedWatch: Task<Void, Never>?
	@ObservationIgnored private var transcriptTask: Task<Void, Never>?
	@ObservationIgnored private var hotKey: GlobalHotKey?
	@ObservationIgnored private var restoreTask: Task<Void, Never>?

	init(overlay: OverlayController, dictation: DictationController) {
		self.overlay = overlay
		self.dictation = dictation
		dictation.onPausedPress = { [weak self] in
			self?.flash(DictationController.Message.pausedForNotes)
		}
	}

	/// Called once at launch.
	func start() {
		hotKey = GlobalHotKey(id: 2, keyCode: kVK_ANSI_N, modifiers: optionKey | cmdKey) { [weak self] in
			self?.toggle()
		}
	}

	var isRecording: Bool {
		if case .recording = phase { return true }
		return false
	}

	var menuTitle: String {
		switch phase {
		case .idle: "Start notes"
		case .recording: "Stop notes"
		case .finishing: "Finishing notes…"
		}
	}

	/// Replaces the dictation status while notes own the mic.
	var statusLine: String? {
		switch phase {
		case .idle: nil
		case .recording: isMicOnly ? "Taking notes, mic only — dictation is off" : "Taking notes — dictation is off"
		case .finishing: "Writing the note…"
		}
	}

	func toggle() {
		switch phase {
		case .idle: Task { await begin() }
		case .recording: Task { await finish() }
		case .finishing: break
		}
	}

	func showLiveTranscript() {
		requestWindow(WindowID.liveTranscript)
	}

	func showLastNote() {
		guard lastNote != nil else { return }
		requestWindow(WindowID.note)
	}

	// MARK: - Start

	private func begin() async {
		guard phase == .idle else { return }
		if !dictation.permissions.hasMicrophone {
			overlay.show(.message(DictationController.Message.needsMicrophone))
			return
		}
		guard dictation.isModelReady else {
			overlay.show(.message(DictationController.Message.gettingReady(nil)))
			return
		}
		let since = Date.now
		phase = .recording(since: since)
		liveSegments = []
		dictation.isPausedForNotes = true
		let session: NotesSession
		do {
			session = try await makeSession()
			try await session.start()
		} catch {
			Logger.notes.error("Notes start failed: \(String(describing: error), privacy: .public)")
			phase = .idle
			dictation.isPausedForNotes = false
			let busy = (error as? MicCaptureError) == .alreadyCapturing
			overlay.show(.message(busy ? Message.micBusy : Message.couldNotStart))
			return
		}
		self.session = session
		isMicOnly = await !session.hasSystemAudio
		isSystemAudioBlocked = false
		await watchCalls()
		watchForBlockedSystemAudio()
		let transcript = session.transcript
		transcriptTask = Task { [weak self] in
			for await segments in transcript {
				self?.liveSegments = segments
			}
		}
		if AppDefaults.store.bool(forKey: Self.consentKey) {
			// A slow start can finish after the call already ended.
			overlay.show(overlayWhileRecording?() ?? .recording(since: since))
		} else {
			AppDefaults.store.set(true, forKey: Self.consentKey)
			flash(Message.consent)
		}
	}

	private func makeSession() async throws -> NotesSession {
		let vad = try await SileroVAD.load()
		var you: any AudioSource = dictation.mic
		// Everything the Mac plays except yap. The first start asks for
		// System Audio Recording; if the tap can't start, notes are mic-only
		// and the note and menu say so.
		let tap = SystemAudioTap()
		self.tap = tap
		var them: (any AudioSource)? = tap
		#if DEBUG
		// File-fed tracks for verification (`-YapNotesMicFile`,
		// `-YapNotesThemFile`): long meetings in minutes, and two tracks
		// without a call.
		if let file = DebugAudioFile.source(forKey: "YapNotesMicFile") { you = file }
		if let file = DebugAudioFile.source(forKey: "YapNotesThemFile") {
			them = file
			self.tap = nil
		}
		#endif
		return NotesSession(
			you: you,
			them: them,
			engine: dictation.engine,
			vad: vad,
			diarizer: them == nil ? nil : FluidSpeakerDiarizer(),
			summaryModel: FoundationSummaryModel(),
			onLimitReached: { [weak self] in
				Task { @MainActor in await self?.finish() }
			})
	}

	// MARK: - Stop

	private func finish() async {
		guard case .recording = phase, let session else { return }
		phase = .finishing
		restoreTask?.cancel()
		overlay.show(.working)
		let clock = ContinuousClock()
		let started = clock.now
		blockedWatch?.cancel()
		if let tap {
			// Asked before stop: the counters are for the current capture.
			let stats = await tap.statistics
			Logger.notes.notice("System audio: \(stats.callbacks, privacy: .public) callbacks, \(stats.audibleCallbacks, privacy: .public) audible, peak \(stats.peak, privacy: .public)")
			if await tap.looksBlocked { isSystemAudioBlocked = true }
		}
		let blocked = isSystemAudioBlocked
		var note: Note
		do {
			note = try await session.stop()
		} catch {
			// Only a stop without a recording throws; nothing to write.
			phase = .idle
			return
		}
		transcriptTask?.cancel()
		self.session = nil
		tap = nil
		dictation.isPausedForNotes = false
		defer { phase = .idle }
		note.apps = await stopWatchingCalls()
		if blocked { note.notices.append(Message.systemAudioBlocked) }

		guard !note.isEmpty else {
			overlay.show(.message(Message.nothingToWrite))
			return
		}
		let writer = MarkdownWriter(folder: Self.folder, fallbackFolder: Self.fallbackFolder)
		do {
			let written = try writer.write(note)
			let elapsed = clock.now - started
			let timings = await session.lastStopTimings
			Logger.notes.notice("Stop to note written: \(elapsed, privacy: .public) (flush \(timings.flush, privacy: .public), diarization \(timings.diarization, privacy: .public), summary \(timings.summary, privacy: .public)) at \(written.url.path, privacy: .public)")
			lastNote = FinishedNote(note: note, title: writer.title(for: note), written: written)
			if written.fallbackNotice != nil {
				overlay.show(.message(Message.savedElsewhere))
			} else {
				overlay.show(.done)
			}
			requestWindow(WindowID.note)
		} catch {
			Logger.notes.error("Note write failed: \(String(describing: error), privacy: .public)")
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			pasteboard.setString(writer.render(note), forType: .string)
			overlay.show(.message(Message.couldNotSave))
		}
	}

	// MARK: - System audio permission

	/// Missing permission looks like silence, and `looksBlocked` can only
	/// tell while something plays, so ask now and then instead of at stop.
	private func watchForBlockedSystemAudio() {
		blockedWatch?.cancel()
		guard let tap else { return }
		blockedWatch = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(3))
				guard !Task.isCancelled else { return }
				if await tap.looksBlocked {
					Logger.notes.notice("System audio looks blocked")
					self?.isSystemAudioBlocked = true
					return
				}
			}
		}
	}

	// MARK: - Calls

	/// Collects the call apps in use while notes run. Apps already in a
	/// call at start count too: the detector reports them after its
	/// minimum duration.
	private func watchCalls() async {
		callApps = []
		let detector = CallDetector()
		callDetector = detector
		let events = await detector.events()
		callWatch = Task { [weak self] in
			for await event in events {
				guard case .started(let app) = event, app.mightBeCall else { continue }
				self?.noteCallApp(app.name)
			}
		}
	}

	private func noteCallApp(_ name: String) {
		if !callApps.contains(name) { callApps.append(name) }
	}

	private func stopWatchingCalls() async -> [String] {
		callWatch?.cancel()
		callWatch = nil
		if let callDetector {
			for recorder in await callDetector.recorders where recorder.app.mightBeCall {
				noteCallApp(recorder.app.name)
			}
			await callDetector.stop()
		}
		callDetector = nil
		return callApps
	}

	// MARK: - Helpers

	/// A one-line notch message, then back to the red dot while recording.
	private func flash(_ text: String) {
		restoreTask?.cancel()
		overlay.show(.message(text))
		restoreTask = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(2400))
			guard !Task.isCancelled, let self, case .recording(let since) = self.phase else { return }
			self.overlay.show(self.overlayWhileRecording?() ?? .recording(since: since))
		}
	}

	private func requestWindow(_ id: String) {
		windowRequest = WindowRequest(id: id, serial: (windowRequest?.serial ?? 0) + 1)
	}

	static var folder: URL {
		AppDefaults.store.string(forKey: folderKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
			?? MarkdownWriter.defaultFolder
	}

	private static var fallbackFolder: URL {
		#if DEBUG
		// Verification must not write into the real Application Support.
		if let path = UserDefaults.standard.string(forKey: "YapNotesFallbackFolder") {
			return URL(filePath: path, directoryHint: .isDirectory)
		}
		#endif
		return MarkdownWriter.defaultFallbackFolder
	}
}

/// A note as the note window shows it.
struct FinishedNote: Equatable {
	var note: Note
	var title: String
	var written: WrittenNote
}

extension Logger {
	static let notes = Logger(subsystem: "com.bjornbom.yap", category: "notes-app")
}
