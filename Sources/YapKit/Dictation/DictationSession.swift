import Foundation
import os

private let logger = Logger(subsystem: "com.bjornbom.yap", category: "dictation")

/// Push-to-talk dictation, one at a time: hotkey → mic → streaming
/// transcription → text processing → history → insertion.
///
/// How it behaves at the edges:
/// - **Never lose words.** Text is saved to history before it is inserted. If
///   it can't be typed (password field, focus moved, no text field), it goes on
///   the clipboard and `lastOutcome` says why. If saving fails, insertion still
///   happens and `pasteLast()` still has the text.
/// - **Overlapping presses are ignored.** A `start` while the previous
///   dictation is still transcribing or inserting is dropped, and so is its
///   `stop`. Queueing it instead would start the mic late and clip the first
///   words, which is worse than a press that visibly does nothing: the notch is
///   still showing the shimmer.
/// - **Cancel** works while listening and while transcribing. Once the text is
///   being saved it is committed, and a late cancel is ignored.
/// - **Max length.** Recording stops by itself after
///   `Configuration.maxRecordingDuration` and is transcribed as if released.
/// - **Too short.** Less than `Configuration.minimumSpeechDuration` of audio
///   never reaches the engine and ends as `.empty`.
/// - Every dictation ends in `.done`, `.empty` or `.failed`, immediately
///   followed by `.idle`. How long to show the result is up to the UI.
public actor DictationSession {
	public struct Configuration: Sendable {
		/// Safety cap for a forgotten lock or a stuck key.
		public var maxRecordingDuration: Duration
		/// Shorter presses are treated as accidental.
		public var minimumSpeechDuration: TimeInterval

		public init(maxRecordingDuration: Duration = .seconds(600), minimumSpeechDuration: TimeInterval = 0.3) {
			self.maxRecordingDuration = maxRecordingDuration
			self.minimumSpeechDuration = minimumSpeechDuration
		}
	}

	/// Errors in yap's voice: one line, what happened and what to do.
	enum Message {
		static let micFailed = "Couldn't start the mic. Check that yap has Microphone access."
		static let transcriptionFailed = "Couldn't turn that into text. Try again."
		static let historyUnreadable = "Couldn't read your history. Try again."
	}

	/// State changes for the notch. Single consumer.
	public nonisolated let states: AsyncStream<DictationState>
	/// Loudness in 0...1, one per audio chunk, for the waveform. Single
	/// consumer; only the newest few are kept if nobody is reading.
	public nonisolated let levels: AsyncStream<Float>

	public private(set) var state: DictationState = .idle
	/// How the last insertion (dictation or paste last) went. Use
	/// `InsertOutcome.message` to tell the user when it didn't land.
	public private(set) var lastOutcome: InsertOutcome?

	private let hotkey: any HotkeySource
	private let audio: any AudioSource
	private let engine: any SpeechEngine
	private let transcription: any StreamingTranscription
	private let processor: any TextProcessing
	private let inserter: any TextInserter
	private let history: any HistoryStore
	private let clipboard: any ClipboardWriter
	private let configuration: Configuration
	private let stateContinuation: AsyncStream<DictationState>.Continuation
	private let levelContinuation: AsyncStream<Float>.Continuation

	private struct Recording {
		let id: UInt64
		var locked = false
		var target: FocusTarget?
		/// Feeds audio to the transcriber; returns the seconds recorded.
		var pump: Task<TimeInterval, Never>?
		var cap: Task<Void, Never>?
	}

	private enum Phase {
		case idle
		case listening(Recording)
		/// Key is up, waiting for the transcript. Cancel still applies.
		case finishing(Recording)
		/// Saving and inserting. Too late to cancel.
		case committing
	}

	private var phase = Phase.idle
	private var nextID: UInt64 = 0
	/// The previous recording's finish or cancel work. A new recording waits
	/// for it so two recordings never share the mic or the transcriber.
	private var teardown: Task<Void, Never>?
	/// Serializes `handle` and `pasteLast` so each sees the state the previous
	/// one left, even though they suspend in the middle.
	private var tail: Task<Void, Never>?
	/// Set when the last dictation couldn't be saved, so paste last still has it.
	private var unsavedText: String?

	public init(
		hotkey: any HotkeySource,
		audio: any AudioSource,
		engine: any SpeechEngine,
		transcription: any StreamingTranscription,
		processor: any TextProcessing = NoTextProcessing(),
		inserter: any TextInserter,
		history: any HistoryStore,
		clipboard: any ClipboardWriter = SystemClipboard(),
		configuration: Configuration = Configuration()
	) {
		self.hotkey = hotkey
		self.audio = audio
		self.engine = engine
		self.transcription = transcription
		self.processor = processor
		self.inserter = inserter
		self.history = history
		self.clipboard = clipboard
		self.configuration = configuration
		(states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
		(levels, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
	}

	deinit {
		stateContinuation.finish()
		levelContinuation.finish()
	}

	/// Follows the hotkey until its stream ends.
	public func run() async {
		for await action in hotkey.actions() {
			await handle(action)
		}
	}

	/// Applies one hotkey action. `run()` calls this; the app may too (e.g. a
	/// menu item). Calls are applied in the order they arrive.
	public func handle(_ action: HotkeyAction) async {
		await inOrder { await self.apply(action) }
	}

	/// Types the last dictation into the app that has focus now (⌃⌘V), with
	/// the same clipboard fallback. Nil when there is nothing to paste or a
	/// dictation is in progress.
	@discardableResult
	public func pasteLast() async -> InsertOutcome? {
		await inOrder { await self.pasteLastNow() }
	}

	// MARK: - State machine

	private func apply(_ action: HotkeyAction) async {
		switch (action, phase) {
		case (.start, .idle):
			await begin()
		case (.lock, .listening(var recording)):
			recording.locked = true
			phase = .listening(recording)
			publish(.listening(locked: true))
		case (.stop, .listening(let recording)):
			stop(recording)
		case (.cancel, .listening(let recording)):
			cancelListening(recording)
		case (.cancel, .finishing):
			await cancelFinishing()
		default:
			logger.debug("Ignored \(String(describing: action), privacy: .public) in \(String(describing: self.state), privacy: .public)")
		}
	}

	private func begin() async {
		nextID &+= 1
		let id = nextID
		phase = .listening(Recording(id: id))
		publish(.listening(locked: false))

		// The Neural Engine naps after a minute; waking it overlaps with talking.
		let engine = self.engine
		Task { await engine.warmUp() }

		// Record focus at key-down: the text only ever goes to this app.
		let target = await inserter.captureTarget()
		await teardown?.value
		teardown = nil
		guard case .listening(var recording) = phase, recording.id == id else { return }
		recording.target = target

		await transcription.begin()
		let stream: AsyncStream<AudioChunk>
		do {
			stream = try await audio.start()
		} catch {
			logger.error("Mic failed to start: \(error, privacy: .public)")
			await transcription.cancel()
			end(.failed(Message.micFailed))
			return
		}
		recording.pump = pump(stream, id: id)
		recording.cap = capTimer(id: id)
		phase = .listening(recording)
	}

	private func pump(_ stream: AsyncStream<AudioChunk>, id: UInt64) -> Task<TimeInterval, Never> {
		let transcription = self.transcription
		let levels = levelContinuation
		return Task {
			var seconds: TimeInterval = 0
			for await chunk in stream {
				// Level first: the waveform shouldn't wait on the transcriber.
				levels.yield(chunk.level)
				seconds += chunk.duration
				await transcription.append(chunk)
			}
			self.audioEnded(id: id)
			return seconds
		}
	}

	private func capTimer(id: UInt64) -> Task<Void, Never> {
		let limit = configuration.maxRecordingDuration
		return Task {
			do {
				try await Task.sleep(for: limit)
			} catch {
				return // Released in time.
			}
			if case .listening(let recording) = self.phase, recording.id == id {
				logger.info("Hit the \(String(describing: limit), privacy: .public) cap; stopping")
				self.stop(recording)
			}
		}
	}

	/// The mic stream ended without us stopping it (device gone): finish with
	/// what we have rather than sit there listening to nothing.
	private func audioEnded(id: UInt64) {
		if case .listening(let recording) = phase, recording.id == id {
			logger.info("Audio ended while listening; stopping")
			stop(recording)
		}
	}

	private func stop(_ recording: Recording) {
		recording.cap?.cancel()
		phase = .finishing(recording)
		publish(.transcribing)
		// Runs outside the handle queue so a cancel can still get in.
		teardown = Task { await self.finish(recording) }
	}

	private func finish(_ recording: Recording) async {
		await audio.stop()
		// The stream has ended, so every chunk has been appended before finish().
		let seconds = await recording.pump?.value ?? 0
		guard isFinishing(recording.id) else { return }

		guard seconds >= configuration.minimumSpeechDuration else {
			await transcription.cancel()
			guard isFinishing(recording.id) else { return }
			end(.empty)
			return
		}

		let raw: String
		do {
			raw = try await transcription.finish()
		} catch {
			guard isFinishing(recording.id) else { return }
			logger.error("Transcription failed: \(error, privacy: .public)")
			end(.failed(Message.transcriptionFailed))
			return
		}
		guard isFinishing(recording.id) else { return }

		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		let text = trimmed.isEmpty
			? ""
			: await processor.process(trimmed, for: recording.target).trimmingCharacters(in: .whitespacesAndNewlines)
		guard isFinishing(recording.id) else { return }
		guard !text.isEmpty else {
			end(.empty)
			return
		}

		phase = .committing
		await save(HistoryEntry(text: text, appBundleID: recording.target?.bundleID, duration: seconds))
		let outcome = await deliver(text, to: recording.target)
		end(.done(outcome))
	}

	private func cancelListening(_ recording: Recording) {
		recording.cap?.cancel()
		phase = .idle
		publish(.idle)
		let audio = self.audio
		let transcription = self.transcription
		teardown = Task {
			await audio.stop()
			_ = await recording.pump?.value
			await transcription.cancel()
		}
	}

	private func cancelFinishing() async {
		// `finish` sees the phase change after its next await and drops the result.
		phase = .idle
		publish(.idle)
		await transcription.cancel()
	}

	private func isFinishing(_ id: UInt64) -> Bool {
		if case .finishing(let recording) = phase { recording.id == id } else { false }
	}

	// MARK: - Output

	private func save(_ entry: HistoryEntry) async {
		do {
			try await history.save(entry)
			unsavedText = nil
		} catch {
			// Don't hold the text hostage to the database: insert anyway.
			logger.error("History save failed: \(error, privacy: .public)")
			unsavedText = entry.text
		}
	}

	private func deliver(_ text: String, to target: FocusTarget?) async -> InsertOutcome {
		let outcome = if let target {
			await inserter.insert(text, into: target)
		} else {
			InsertOutcome.noTarget
		}
		if !outcome.didInsert {
			await clipboard.write(text)
		}
		lastOutcome = outcome
		return outcome
	}

	private func pasteLastNow() async -> InsertOutcome? {
		guard case .idle = phase else { return nil }
		let text: String
		if let unsavedText {
			text = unsavedText
		} else {
			do {
				guard let entry = try await history.last() else { return nil }
				text = entry.text
			} catch {
				logger.error("History read failed: \(error, privacy: .public)")
				publish(.failed(Message.historyUnreadable))
				publish(.idle)
				return nil
			}
		}
		let outcome = await deliver(text, to: await inserter.captureTarget())
		publish(.done(outcome))
		publish(.idle)
		return outcome
	}

	// MARK: - Plumbing

	private func end(_ result: DictationState) {
		phase = .idle
		publish(result)
		publish(.idle)
	}

	private func publish(_ newState: DictationState) {
		state = newState
		stateContinuation.yield(newState)
	}

	private func inOrder<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
		let previous = tail
		let task = Task {
			await previous?.value
			return await work()
		}
		tail = Task { _ = await task.value }
		return await task.value
	}
}
