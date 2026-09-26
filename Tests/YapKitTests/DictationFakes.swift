import Foundation
import Synchronization
@testable import YapKit

/// Records calls across fakes so tests can assert on ordering.
final class EventLog: Sendable {
	private let events = Mutex<[String]>([])

	func append(_ event: String) {
		events.withLock { $0.append(event) }
	}

	var all: [String] { events.withLock { $0 } }

	func index(of event: String) -> Int? { all.firstIndex(of: event) }
	func count(of event: String) -> Int { all.filter { $0 == event }.count }
}

struct FakeError: Error {}

final class ScriptedHotkey: HotkeySource {
	let stream: AsyncStream<HotkeyAction>
	let continuation: AsyncStream<HotkeyAction>.Continuation

	init() {
		(stream, continuation) = AsyncStream.makeStream()
	}

	func actions() -> AsyncStream<HotkeyAction> { stream }
	func send(_ action: HotkeyAction) { continuation.yield(action) }
}

/// 0.1 s of a quiet tone.
func chunk(_ amplitude: Float = 0.1) -> AudioChunk {
	AudioChunk(samples: [Float](repeating: amplitude, count: 1_600), hostTime: 0)
}

actor FakeAudio: AudioSource {
	let log: EventLog
	/// Delivered as soon as `start()` returns.
	var initialChunks: [AudioChunk]
	var startError: (any Error)?
	/// End the stream on its own after the initial chunks, like an unplugged mic.
	var endsOnItsOwn = false
	private var continuation: AsyncStream<AudioChunk>.Continuation?
	private(set) var startCount = 0

	init(log: EventLog, chunks: [AudioChunk] = Array(repeating: chunk(), count: 10)) {
		self.log = log
		self.initialChunks = chunks
	}

	func configure(chunks: [AudioChunk]? = nil, startError: (any Error)? = nil, endsOnItsOwn: Bool = false) {
		if let chunks { initialChunks = chunks }
		self.startError = startError
		self.endsOnItsOwn = endsOnItsOwn
	}

	func prepare() async throws {}

	func start() async throws -> AsyncStream<AudioChunk> {
		log.append("audio.start")
		startCount += 1
		if let startError { throw startError }
		let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
		for chunk in initialChunks {
			continuation.yield(chunk)
		}
		if endsOnItsOwn {
			continuation.finish()
		}
		self.continuation = continuation
		return stream
	}

	func push(_ chunk: AudioChunk) {
		continuation?.yield(chunk)
	}

	func stop() async {
		log.append("audio.stop")
		continuation?.finish()
		continuation = nil
	}
}

actor FakeEngine: SpeechEngine {
	let log: EventLog
	private(set) var warmUps = 0

	init(log: EventLog) { self.log = log }

	func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
	func warmUp() async {
		warmUps += 1
		log.append("engine.warmUp")
	}
	func transcribe(_ samples: [Float]) async throws -> Transcript { Transcript(text: "", confidence: 0) }
	func unload() async {}
}

actor FakeTranscription: StreamingTranscription {
	let log: EventLog
	var result: Result<String, any Error> = .success("hello from yap")
	/// When set, `finish()` suspends until `releaseFinish()` or `cancel()`.
	var holdsFinish = false
	private var held: CheckedContinuation<Void, any Error>?
	private(set) var appended = 0
	private(set) var finishCalls = 0
	private(set) var cancelCalls = 0

	init(log: EventLog) { self.log = log }

	func configure(result: Result<String, any Error>? = nil, holdsFinish: Bool = false) {
		if let result { self.result = result }
		self.holdsFinish = holdsFinish
	}

	func begin() async {
		log.append("transcription.begin")
		appended = 0
	}

	func append(_ chunk: AudioChunk) async {
		appended += 1
	}

	func finish() async throws -> String {
		log.append("transcription.finish")
		finishCalls += 1
		if holdsFinish {
			try await withCheckedThrowingContinuation { held = $0 }
		}
		return try result.get()
	}

	var isHoldingFinish: Bool { held != nil }

	func releaseFinish() {
		held?.resume()
		held = nil
	}

	func cancel() async {
		log.append("transcription.cancel")
		cancelCalls += 1
		held?.resume(throwing: CancellationError())
		held = nil
	}
}

actor FakeInserter: TextInserter {
	let log: EventLog
	var target: FocusTarget? = FocusTarget(pid: 42, bundleID: "com.apple.TextEdit")
	var outcome: InsertOutcome = .ax
	private(set) var inserted: [(text: String, target: FocusTarget)] = []
	private(set) var captures = 0

	init(log: EventLog) { self.log = log }

	func configure(target: FocusTarget?, outcome: InsertOutcome = .ax) {
		self.target = target
		self.outcome = outcome
	}

	func captureTarget() async -> FocusTarget? {
		log.append("inserter.captureTarget")
		captures += 1
		return target
	}

	func insert(_ text: String, into target: FocusTarget) async -> InsertOutcome {
		log.append("inserter.insert")
		inserted.append((text, target))
		return outcome
	}
}

actor FakeHistory: HistoryStore {
	let log: EventLog
	var failsSaves = false
	var failsReads = false
	private(set) var entries: [HistoryEntry] = []

	init(log: EventLog) { self.log = log }

	func configure(failsSaves: Bool = false, failsReads: Bool = false) {
		self.failsSaves = failsSaves
		self.failsReads = failsReads
	}

	@discardableResult
	func save(_ entry: HistoryEntry) async throws -> HistoryEntry {
		log.append("history.save")
		if failsSaves { throw FakeError() }
		var saved = entry
		saved.id = Int64(entries.count + 1)
		entries.append(saved)
		return saved
	}

	func recent(limit: Int) async throws -> [HistoryEntry] { Array(entries.reversed().prefix(limit)) }
	func search(_ query: String, limit: Int) async throws -> [HistoryEntry] { [] }
	func last() async throws -> HistoryEntry? {
		if failsReads { throw FakeError() }
		return entries.last
	}
	func prune(before date: Date) async throws {}
}

actor FakeClipboard: ClipboardWriter {
	let log: EventLog
	private(set) var writes: [String] = []

	init(log: EventLog) { self.log = log }

	func write(_ text: String) async {
		log.append("clipboard.write")
		writes.append(text)
	}
}

/// Marks processed text and remembers the target it was processed for.
struct ShoutingProcessor: TextProcessing {
	func process(_ text: String, for target: FocusTarget?) async -> String {
		"\(text.uppercased()) [\(target?.bundleID ?? "none")]"
	}
}

/// Collects the state stream so tests can wait for it.
final class StateRecorder: Sendable {
	private final class Box: Sendable {
		let states = Mutex<[DictationState]>([])
	}

	private let box = Box()
	private let task: Task<Void, Never>

	init(_ stream: AsyncStream<DictationState>) {
		task = Task { [box] in
			for await state in stream {
				box.states.withLock { $0.append(state) }
			}
		}
	}

	deinit {
		task.cancel()
	}

	var all: [DictationState] { box.states.withLock { $0 } }

	/// Waits until `count` states have arrived (or two seconds pass).
	@discardableResult
	func wait(forCount count: Int) async -> [DictationState] {
		await waitUntil { $0.count >= count }
		return all
	}

	func waitUntil(_ condition: @Sendable ([DictationState]) -> Bool) async {
		let deadline = ContinuousClock.now + .seconds(2)
		while !condition(all), ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(5))
		}
	}
}

/// Polls an async condition for up to two seconds.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
	let deadline = ContinuousClock.now + .seconds(2)
	while ContinuousClock.now < deadline {
		if await condition() { return true }
		try? await Task.sleep(for: .milliseconds(5))
	}
	return await condition()
}

/// A session wired to fakes.
struct Rig {
	let log = EventLog()
	let hotkey = ScriptedHotkey()
	let audio: FakeAudio
	let engine: FakeEngine
	let transcription: FakeTranscription
	let inserter: FakeInserter
	let history: FakeHistory
	let clipboard: FakeClipboard
	let session: DictationSession
	let states: StateRecorder

	init(
		processor: any TextProcessing = NoTextProcessing(),
		configuration: DictationSession.Configuration = .init()
	) {
		audio = FakeAudio(log: log)
		engine = FakeEngine(log: log)
		transcription = FakeTranscription(log: log)
		inserter = FakeInserter(log: log)
		history = FakeHistory(log: log)
		clipboard = FakeClipboard(log: log)
		session = DictationSession(
			hotkey: hotkey,
			audio: audio,
			engine: engine,
			transcription: transcription,
			processor: processor,
			inserter: inserter,
			history: history,
			clipboard: clipboard,
			configuration: configuration
		)
		states = StateRecorder(session.states)
	}

	/// Starts and waits until all initial audio reached the transcriber.
	func startListening(expectingChunks chunks: Int = 10) async {
		await session.handle(.start)
		_ = await eventually { [transcription] in await transcription.appended >= chunks }
	}
}
