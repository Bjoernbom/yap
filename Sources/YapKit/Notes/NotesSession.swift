import Foundation
import os

public struct NotesConfiguration: Sendable {
	/// Recording stops by itself after this long.
	public var maxDuration: Duration
	/// Where the "them" audio waits for the diarizer. Deleted after stop.
	public var audioDirectory: URL
	/// Call apps in use, for the note's front matter.
	public var apps: [String]
	/// Diarization gets this long after stop before the note goes without.
	public var diarizationTimeout: Duration

	public init(
		maxDuration: Duration = .seconds(3 * 3600),
		audioDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "yap-notes"),
		apps: [String] = [],
		diarizationTimeout: Duration = .seconds(120)
	) {
		self.maxDuration = maxDuration
		self.audioDirectory = audioDirectory
		self.apps = apps
		self.diarizationTimeout = diarizationTimeout
	}
}

public enum NotesSessionError: Error, Equatable, Sendable {
	/// `start()` on a session that already started. A session records once.
	case alreadyStarted
	/// `stop()` before `start()`, or a second `stop()`.
	case notRecording
}

/// Lines the note shows when something limited it. Plan voice: what
/// happened, one line.
public enum NotesNotice {
	public static let micOnly = "Recorded from the microphone only, so the other side of the call may be missing."
	public static let limitReached = "Recording stopped at the 3-hour limit."
	public static let speakersUnknown = "Couldn't tell the other speakers apart, so they're all \"them\"."
}

/// How long the steps after stop took, for logs and `yap-bench`.
public struct NotesStopTimings: Sendable, Equatable {
	/// Stop → both tails transcribed.
	public var flush: Duration = .zero
	public var diarization: Duration = .zero
	public var summary: Duration = .zero
	public var total: Duration = .zero
}

/// Records a meeting as two tracks and turns it into a `Note`.
///
/// "You" is the microphone, "them" the system audio (optional: without it
/// the note is mic-only and says so). Each track runs its own
/// `StreamingTranscriber`, so text arrives while the meeting is going and
/// `stop()` only waits for the tails; both share one engine through
/// `SerialSpeechEngine`, because there is one model on the Neural Engine.
///
/// Memory stays flat over a long meeting: audio is transcribed and dropped.
/// The only audio kept is the "them" track, on disk as 16 kHz Int16, for the
/// diarizer after stop; it is deleted as soon as the note is built.
///
/// Time: every segment is placed on host time relative to the start (see
/// `TrackTimeline`), because the system tap delivers nothing while nothing
/// plays, so its sample count says nothing about when words were spoken.
public actor NotesSession {
	private enum TrackID: Sendable, Hashable {
		case you, them
	}

	private struct Track {
		var timeline: TrackTimeline
		let transcriber: StreamingTranscriber
		let pump: Task<Void, Never>
		let reportSink: AsyncStream<StreamingTranscriber.ChunkReport>.Continuation
		let consumer: Task<Void, Never>
	}

	/// A "them" segment before diarization, with its words in the track's
	/// stream time (the diarizer's time).
	private struct ThemPiece {
		var segment: NoteSegment
		var words: [TimedWord]
		var streamRange: ClosedRange<Double>
	}

	private enum Phase {
		case idle, recording, stopping, done
	}

	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "notes")

	/// The live transcript, whole, after every change. Newest value only: a
	/// view that falls behind skips to the latest.
	public nonisolated let transcript: AsyncStream<[NoteSegment]>
	private let transcriptSink: AsyncStream<[NoteSegment]>.Continuation

	private let you: any AudioSource
	private let them: (any AudioSource)?
	private let engine: SerialSpeechEngine
	private let vad: any VoiceActivityDetector
	private let diarizer: (any SpeakerDiarizing)?
	private let summaryModel: (any SummaryModel)?
	private let configuration: NotesConfiguration
	private let onLimitReached: @Sendable () -> Void

	private var phase = Phase.idle
	private var startedAt = Date.now
	private var origin: UInt64 = 0
	private var tracks: [TrackID: Track] = [:]
	private var youSegments: [NoteSegment] = []
	private var themPieces: [ThemPiece] = []
	private var recorder: TrackRecorder?
	private var summarizer: Summarizer?
	private var notices: [String] = []
	private var limitTask: Task<Void, Never>?
	private var diarizerPreparation: Task<Void, Never>?
	/// Meeting time of the newest audio from either track.
	private var latestAudio = 0.0

	/// True once the system-audio track is running.
	public private(set) var hasSystemAudio = false
	public private(set) var lastStopTimings = NotesStopTimings()

	/// - Parameters:
	///   - you: the microphone.
	///   - them: system audio; nil records the microphone only.
	///   - engine: shared with dictation; notes serialize their own calls.
	///   - diarizer: tells "them" voices apart after stop; nil skips it.
	///   - summaryModel: nil, or unavailable at start, gives a transcript-only note.
	///   - onLimitReached: called when `maxDuration` stopped the recording;
	///     the owner should call `stop()` to get the note.
	public init(
		you: any AudioSource,
		them: (any AudioSource)?,
		engine: any SpeechEngine,
		vad: any VoiceActivityDetector,
		diarizer: (any SpeakerDiarizing)? = nil,
		summaryModel: (any SummaryModel)? = nil,
		configuration: NotesConfiguration = NotesConfiguration(),
		onLimitReached: @escaping @Sendable () -> Void = {}
	) {
		self.you = you
		self.them = them
		self.engine = SerialSpeechEngine(engine)
		self.vad = vad
		self.diarizer = diarizer
		self.summaryModel = summaryModel
		self.configuration = configuration
		self.onLimitReached = onLimitReached
		(transcript, transcriptSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
	}

	public var isRecording: Bool { phase == .recording }

	/// When recording began, for the timer.
	public var startDate: Date { startedAt }

	/// Starts both tracks. Throws if the microphone can't start (nothing is
	/// recorded then); a system-audio failure only makes the note mic-only.
	public func start() async throws {
		guard phase == .idle else { throw NotesSessionError.alreadyStarted }
		phase = .recording
		startedAt = .now
		origin = HostClock.now()

		if let summaryModel {
			if let reason = await summaryModel.unavailableReason() {
				notices.append(reason)
			} else {
				summarizer = Summarizer(model: summaryModel)
			}
		}

		do {
			let stream = try await you.start()
			tracks[.you] = await makeTrack(.you, audio: stream)
		} catch {
			phase = .done
			transcriptSink.finish()
			throw error
		}

		if let them {
			do {
				recorder = diarizer == nil ? nil : try TrackRecorder(directory: configuration.audioDirectory)
				let stream = try await them.start()
				tracks[.them] = await makeTrack(.them, audio: stream)
				hasSystemAudio = true
			} catch {
				Self.log.error("System audio unavailable: \(String(describing: error), privacy: .public)")
				recorder?.delete()
				recorder = nil
			}
		}
		if !hasSystemAudio {
			notices.append(NotesNotice.micOnly)
		}
		if hasSystemAudio, let diarizer {
			// Downloads the models during the meeting, not after it.
			diarizerPreparation = Task {
				do {
					try await diarizer.prepare()
				} catch {
					Self.log.error("Diarizer prepare failed: \(String(describing: error), privacy: .public)")
				}
			}
		}
		let limit = configuration.maxDuration
		limitTask = Task { [weak self] in
			try? await Task.sleep(for: limit)
			guard !Task.isCancelled else { return }
			await self?.reachLimit()
		}
		Self.log.notice("Notes started (system audio: \(self.hasSystemAudio, privacy: .public))")
	}

	/// Stops recording, flushes both tails, diarizes "them", finishes the
	/// summary and returns the note. Never fails because of a model: every
	/// optional step that goes wrong leaves a notice instead.
	public func stop() async throws -> Note {
		guard phase == .recording else { throw NotesSessionError.notRecording }
		phase = .stopping
		limitTask?.cancel()
		let clock = ContinuousClock()
		let stopStarted = clock.now
		let duration = HostClock.seconds(HostClock.now() - origin)

		await stopSources()
		for id in [TrackID.you, .them] {
			guard let track = tracks[id] else { continue }
			// The source's stream has ended, so the pump is done after the
			// last chunk it had.
			await track.pump.value
			do {
				_ = try await track.transcriber.finish()
			} catch {
				Self.log.error("Transcriber tail failed: \(String(describing: error), privacy: .public)")
			}
			track.reportSink.finish()
			await track.consumer.value
		}
		var timings = NotesStopTimings()
		timings.flush = clock.now - stopStarted
		recorder?.close()

		// The summary's last section doesn't need speaker numbers ("them" is
		// enough to summarize), so it runs alongside diarization.
		let undiarized = liveSegments()
		let summaryStarted = clock.now
		let summarizer = self.summarizer
		async let summaryOutcome: (SummaryOutcome?, Duration) = {
			guard let summarizer else { return (nil, .zero) }
			let outcome = await summarizer.finish(undiarized)
			return (outcome, clock.now - summaryStarted)
		}()

		let diarizationStarted = clock.now
		let themSegments = await diarizedThemSegments()
		timings.diarization = clock.now - diarizationStarted
		recorder?.delete()
		recorder = nil

		let (outcome, summaryTime) = await summaryOutcome
		timings.summary = summaryTime
		if let notice = outcome?.notice { notices.append(notice) }
		timings.total = clock.now - stopStarted
		lastStopTimings = timings

		let segments = EchoFilter.removeEcho(from: TranscriptMerger.sortedByStart(youSegments + themSegments))
		phase = .done
		transcriptSink.finish()
		Self.log.notice("Notes stopped: \(segments.count, privacy: .public) segments, flush \(timings.flush, privacy: .public), diarization \(timings.diarization, privacy: .public), summary \(timings.summary, privacy: .public)")
		return Note(
			startedAt: startedAt, duration: duration, segments: segments,
			summary: outcome?.summary, apps: configuration.apps, notices: notices)
	}

	/// Drops the meeting: nothing is returned and the audio file is deleted.
	public func cancel() async {
		guard phase == .recording || phase == .idle else { return }
		phase = .done
		limitTask?.cancel()
		await stopSources()
		for track in tracks.values {
			await track.transcriber.cancel()
			track.reportSink.finish()
			track.pump.cancel()
		}
		recorder?.delete()
		recorder = nil
		transcriptSink.finish()
	}

	// MARK: - Recording

	private func makeTrack(_ id: TrackID, audio: AsyncStream<AudioChunk>) async -> Track {
		let (reports, reportSink) = AsyncStream.makeStream(of: StreamingTranscriber.ChunkReport.self)
		let transcriber = StreamingTranscriber(engine: engine, vad: vad, policy: .notes) { report in
			reportSink.yield(report)
		}
		await transcriber.begin()
		// One consumer per track keeps its reports in order; separate tasks
		// per report could land out of order.
		let consumer = Task {
			for await report in reports {
				await self.receive(report, from: id)
			}
		}
		let pump = Task {
			for await chunk in audio {
				await self.feed(chunk, to: id)
			}
		}
		return Track(
			timeline: TrackTimeline(origin: origin), transcriber: transcriber,
			pump: pump, reportSink: reportSink, consumer: consumer)
	}

	private func feed(_ chunk: AudioChunk, to id: TrackID) async {
		guard phase == .recording || phase == .stopping, var track = tracks[id] else { return }
		let samples = track.timeline.place(chunk)
		tracks[id] = track
		if id == .them { recorder?.append(samples) }
		latestAudio = max(latestAudio, track.timeline.meetingTime(stream: track.timeline.streamSeconds))
		await track.transcriber.append(AudioChunk(samples: samples, hostTime: chunk.hostTime))
	}

	private func receive(_ report: StreamingTranscriber.ChunkReport, from id: TrackID) async {
		guard let timeline = tracks[id]?.timeline else { return }
		let text = report.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		let streamStart = report.words.first?.start ?? report.start
		let streamEnd = max(report.words.last?.end ?? (report.start + report.duration), streamStart)
		let start = timeline.meetingTime(stream: streamStart)
		let end = max(timeline.meetingTime(stream: streamEnd), start)
		switch id {
		case .you:
			let words = report.words.map {
				TimedWord(text: $0.text, start: timeline.meetingTime(stream: $0.start), end: timeline.meetingTime(stream: $0.end))
			}
			youSegments.append(NoteSegment(speaker: .you, start: start, end: end, text: text, words: words))
		case .them:
			themPieces.append(ThemPiece(
				segment: NoteSegment(speaker: .them(nil), start: start, end: end, text: text),
				words: report.words, streamRange: streamStart...streamEnd))
		}
		let live = liveSegments()
		transcriptSink.yield(live)
		if phase == .recording, let summarizer {
			await summarizer.observe(live, now: latestAudio)
		}
	}

	private func liveSegments() -> [NoteSegment] {
		EchoFilter.removeEcho(from: TranscriptMerger.sortedByStart(youSegments + themPieces.map(\.segment)))
	}

	private func stopSources() async {
		await you.stop()
		await them?.stop()
	}

	private func reachLimit() async {
		guard phase == .recording else { return }
		Self.log.notice("Notes reached the time limit")
		notices.append(NotesNotice.limitReached)
		// Stop the audio now; the owner calls stop() for the note.
		await stopSources()
		onLimitReached()
	}

	// MARK: - Diarization

	/// "Them" segments with speaker numbers, split where the speaker changes.
	/// Unnumbered when diarization is off, fails or takes too long.
	private func diarizedThemSegments() async -> [NoteSegment] {
		let plain = themPieces.map(\.segment)
		guard let diarizer, let recorder, !recorder.failed, !themPieces.isEmpty,
		      recorder.sampleCount >= Int(AudioChunk.sampleRate) * 2
		else { return plain }
		await diarizerPreparation?.value
		let recording = recorder.recording
		let turns = await Deadline.run(within: configuration.diarizationTimeout) { () -> [SpeakerTurn]? in
			do {
				return try await diarizer.diarize(recording)
			} catch {
				Self.log.error("Diarization failed: \(String(describing: error), privacy: .public)")
				return nil
			}
		}
		guard let turns = turns ?? nil, !turns.isEmpty else {
			notices.append(NotesNotice.speakersUnknown)
			return plain
		}
		guard let timeline = tracks[.them]?.timeline else { return plain }
		var assignment = SpeakerAssignment(turns: turns)
		var segments: [NoteSegment] = []
		for piece in themPieces {
			guard !piece.words.isEmpty else {
				var segment = piece.segment
				segment.speaker = .them(assignment.dominantSpeaker(in: piece.streamRange))
				segments.append(segment)
				continue
			}
			for run in assignment.split(piece.words) {
				guard let first = run.words.first, let last = run.words.last else { continue }
				let start = timeline.meetingTime(stream: first.start)
				segments.append(NoteSegment(
					speaker: .them(run.speaker), start: start,
					end: max(timeline.meetingTime(stream: last.end), start),
					text: TranscriptJoiner.join(run.words.map(\.text))))
			}
		}
		Self.log.notice("Diarization: \(assignment.numbers.count, privacy: .public) speakers")
		return segments
	}
}
