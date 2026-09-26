import Foundation
import Synchronization
import Testing
@testable import YapKit

/// Plays scripted audio at given meeting offsets (host time relative to
/// `start()`), then stays open until `stop()`, like a live source.
private actor ScriptedSource: AudioSource {
	struct Burst {
		var at: Double
		var seconds: Double
		var amplitude: Float
	}

	let bursts: [Burst]
	var fails = false
	private var continuation: AsyncStream<AudioChunk>.Continuation?
	private(set) var stops = 0

	init(_ bursts: [Burst], fails: Bool = false) {
		self.bursts = bursts
		self.fails = fails
	}

	func prepare() async throws {}

	func start() async throws -> AsyncStream<AudioChunk> {
		if fails { throw FakeError() }
		let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
		let origin = HostClock.now()
		for burst in bursts {
			// 100 ms chunks, stamped where they'd be in a real meeting.
			let count = Int(burst.seconds * 10)
			for index in 0..<count {
				let time = burst.at + Double(index) * 0.1
				continuation.yield(AudioChunk(
					samples: [Float](repeating: burst.amplitude, count: 1_600),
					hostTime: origin + HostClock.ticks(seconds: time)))
			}
		}
		self.continuation = continuation
		return stream
	}

	func stop() async {
		stops += 1
		continuation?.finish()
		continuation = nil
	}
}

/// Loud is speech.
private struct LevelVAD: VoiceActivityDetector {
	func makeStream() async -> any VoiceActivityStream { Stream() }

	actor Stream: VoiceActivityStream {
		func speechProbability(of hop: [Float]) async throws -> Float {
			(hop.map(abs).max() ?? 0) > 0.05 ? 0.95 : 0.01
		}
	}
}

/// Says a sentence picked by the loudness of the chunk, with word timings
/// spread over its loud part. Tracks how many calls overlap.
private actor SentenceEngine: SpeechEngine {
	let sentences: [Float: String]
	private(set) var maxConcurrent = 0
	private var running = 0

	init(_ sentences: [Float: String]) {
		self.sentences = sentences
	}

	func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
	func warmUp() async {}
	func unload() async {}

	func transcribe(_ samples: [Float]) async throws -> Transcript {
		running += 1
		maxConcurrent = max(maxConcurrent, running)
		try? await Task.sleep(for: .milliseconds(5))
		running -= 1
		guard let first = samples.firstIndex(where: { $0 > 0.05 }),
		      let last = samples.lastIndex(where: { $0 > 0.05 }),
		      let level = sentences.keys.min(by: { abs($0 - samples[first]) < abs($1 - samples[first]) }),
		      let sentence = sentences[level]
		else { return Transcript(text: "", confidence: 1) }
		let words = sentence.split(separator: " ").map(String.init)
		let start = Double(first) / 16_000
		let step = (Double(last - first) / 16_000) / Double(words.count)
		let timed = words.enumerated().map { index, word in
			TimedWord(text: word, start: start + Double(index) * step, end: start + Double(index + 1) * step)
		}
		return Transcript(text: sentence, confidence: 1, words: timed)
	}
}

private final class FakeDiarizer: SpeakerDiarizing {
	let turns: @Sendable (TrackRecording) -> [SpeakerTurn]
	let seen = Mutex<[TrackRecording]>([])

	init(turns: @escaping @Sendable (TrackRecording) -> [SpeakerTurn]) {
		self.turns = turns
	}

	func prepare() async throws {}

	func diarize(_ recording: TrackRecording) async throws -> [SpeakerTurn] {
		#expect(FileManager.default.fileExists(atPath: recording.url.path))
		seen.withLock { $0.append(recording) }
		return turns(recording)
	}
}

private struct Unavailable: SummaryModel {
	func unavailableReason() async -> String? { "No summary: Apple Intelligence is off." }
	func supports(languageCode: String) async -> Bool { true }
	func map(_ section: TranscriptSection, language: String) async throws -> SectionDigest { SectionDigest() }
	func condense(_ digests: [SectionDigest], language: String) async throws -> SectionDigest { SectionDigest() }
	func reduce(_ digests: [SectionDigest], language: String) async throws -> MeetingSummary { MeetingSummary(title: "", summary: "") }
}

private func scratchDirectory() -> URL {
	FileManager.default.temporaryDirectory.appending(path: "yap-notes-session-\(UUID().uuidString)")
}

/// Waits until the source's scripted chunks went through the pipeline.
private func settle() async {
	try? await Task.sleep(for: .milliseconds(300))
}

@Suite("Notes session")
struct NotesSessionTests {
	@Test func twoTracksLineUpOnHostTimeAcrossASystemAudioGap() async throws {
		let you = ScriptedSource([.init(at: 0, seconds: 2, amplitude: 0.5), .init(at: 2, seconds: 38, amplitude: 0)])
		// Nothing plays for 30 s: the tap sends nothing at all in between.
		let them = ScriptedSource([.init(at: 30, seconds: 2, amplitude: 0.3)])
		let engine = SentenceEngine([0.5: "Hello, can you hear me?", 0.3: "Loud and clear, thanks."])
		let directory = scratchDirectory()
		let session = NotesSession(
			you: you, them: them, engine: engine, vad: LevelVAD(),
			configuration: NotesConfiguration(audioDirectory: directory))
		try await session.start()
		await settle()
		let note = try await session.stop()

		#expect(note.segments.map(\.text) == ["Hello, can you hear me?", "Loud and clear, thanks."])
		#expect(note.segments.map(\.speaker) == [.you, .them(nil)])
		#expect(abs(note.segments[0].start) < 0.5)
		#expect(abs(note.segments[1].start - 30) < 0.5)
		#expect(note.notices.isEmpty)
		#expect(await session.hasSystemAudio)
		// One model, never two calls at once.
		#expect(await engine.maxConcurrent == 1)
	}

	@Test func micEchoOfThemIsDropped() async throws {
		let you = ScriptedSource([.init(at: 5, seconds: 2, amplitude: 0.5), .init(at: 7, seconds: 3, amplitude: 0)])
		let them = ScriptedSource([.init(at: 5, seconds: 2, amplitude: 0.3)])
		// The mic heard exactly what the call played.
		let engine = SentenceEngine([0.5: "We ship on Friday then.", 0.3: "We ship on Friday then."])
		let session = NotesSession(
			you: you, them: them, engine: engine, vad: LevelVAD(),
			configuration: NotesConfiguration(audioDirectory: scratchDirectory()))
		try await session.start()
		await settle()
		let note = try await session.stop()
		#expect(note.segments.map(\.speaker) == [.them(nil)])
	}

	@Test func themIsDiarizedSplitAndTheAudioDeleted() async throws {
		let you = ScriptedSource([.init(at: 0, seconds: 1, amplitude: 0)])
		let them = ScriptedSource([.init(at: 1, seconds: 4, amplitude: 0.3)])
		let engine = SentenceEngine([0.3: "one two three four five six seven eight"])
		// First speaker for the first half of the burst, then another.
		let diarizer = FakeDiarizer { (recording: TrackRecording) in
			[SpeakerTurn(speaker: "B", start: 0, end: 2), SpeakerTurn(speaker: "A", start: 2, end: recording.duration)]
		}
		let directory = scratchDirectory()
		let session = NotesSession(
			you: you, them: them, engine: engine, vad: LevelVAD(), diarizer: diarizer,
			configuration: NotesConfiguration(audioDirectory: directory))
		try await session.start()
		await settle()
		let note = try await session.stop()

		#expect(note.segments.map(\.speaker) == [.them(1), .them(2)])
		#expect(note.segments.map(\.text).joined(separator: " ") == "one two three four five six seven eight")
		let recording = try #require(diarizer.seen.withLock { $0.first })
		#expect(abs(recording.duration - 4) < 0.2)
		#expect(!FileManager.default.fileExists(atPath: recording.url.path))
		#expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
	}

	@Test func withoutSystemAudioTheNoteIsMicOnlyAndSaysSo() async throws {
		let you = ScriptedSource([.init(at: 0, seconds: 2, amplitude: 0.5)])
		let failing = ScriptedSource([], fails: true)
		for them in [failing, nil] as [ScriptedSource?] {
			let session = NotesSession(
				you: you, them: them, engine: SentenceEngine([0.5: "Just me."]), vad: LevelVAD(),
				summaryModel: Unavailable(), configuration: NotesConfiguration(audioDirectory: scratchDirectory()))
			try await session.start()
			await settle()
			let note = try await session.stop()
			#expect(note.segments.map(\.text) == ["Just me."])
			#expect(note.notices.contains(NotesNotice.micOnly))
			#expect(note.notices.contains("No summary: Apple Intelligence is off."))
			#expect(note.summary == nil)
		}
	}

	@Test func stoppingRightAwayGivesAnEmptyNote() async throws {
		let session = NotesSession(
			you: ScriptedSource([]), them: ScriptedSource([]), engine: SentenceEngine([:]), vad: LevelVAD(),
			configuration: NotesConfiguration(audioDirectory: scratchDirectory()))
		try await session.start()
		let note = try await session.stop()
		#expect(note.isEmpty)
	}

	@Test func aSessionStartsAndStopsOnce() async throws {
		let session = NotesSession(
			you: ScriptedSource([]), them: nil, engine: SentenceEngine([:]), vad: LevelVAD(),
			configuration: NotesConfiguration(audioDirectory: scratchDirectory()))
		await #expect(throws: NotesSessionError.notRecording) { try await session.stop() }
		try await session.start()
		await #expect(throws: NotesSessionError.alreadyStarted) { try await session.start() }
		_ = try await session.stop()
		await #expect(throws: NotesSessionError.notRecording) { try await session.stop() }
	}

	@Test func aMicThatWontStartFailsTheStart() async {
		let session = NotesSession(
			you: ScriptedSource([], fails: true), them: nil, engine: SentenceEngine([:]), vad: LevelVAD())
		await #expect(throws: FakeError.self) { try await session.start() }
		#expect(await !session.isRecording)
	}

	@Test func theTimeLimitStopsTheAudioAndTellsTheOwner() async throws {
		let you = ScriptedSource([.init(at: 0, seconds: 1, amplitude: 0.5)])
		let reached = Mutex(false)
		let session = NotesSession(
			you: you, them: nil, engine: SentenceEngine([0.5: "Short one."]), vad: LevelVAD(),
			configuration: NotesConfiguration(maxDuration: .milliseconds(200), audioDirectory: scratchDirectory()),
			onLimitReached: { reached.withLock { $0 = true } })
		try await session.start()
		try await Task.sleep(for: .milliseconds(500))
		#expect(reached.withLock { $0 })
		#expect(await you.stops == 1)
		let note = try await session.stop()
		#expect(note.notices.contains(NotesNotice.limitReached))
		#expect(note.segments.map(\.text) == ["Short one."])
	}

	@Test func theLiveTranscriptGrowsAsTracksReport() async throws {
		let you = ScriptedSource([.init(at: 0, seconds: 2, amplitude: 0.5), .init(at: 2, seconds: 2, amplitude: 0)])
		let session = NotesSession(
			you: you, them: nil, engine: SentenceEngine([0.5: "Live words."]), vad: LevelVAD(),
			configuration: NotesConfiguration(audioDirectory: scratchDirectory()))
		try await session.start()
		var iterator = session.transcript.makeAsyncIterator()
		let first = await iterator.next()
		#expect(first?.map(\.text) == ["Live words."])
		_ = try await session.stop()
	}
}
