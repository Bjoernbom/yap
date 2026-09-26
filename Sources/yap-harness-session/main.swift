// Drives DictationSession through YapKit's public API, the way the app will:
// scripted hotkey, fake mic and speech, a printing inserter and clipboard, and
// the real SQLite history.
//
//   yap-harness-session session <db-path>          three dictations + paste last
//   yap-harness-session bulk <db-path> [count]     bulk insert, search latency, prune

import Foundation
import YapKit

let started = ContinuousClock.now

func stamp() -> String {
	let elapsed = ContinuousClock.now - started
	let ms = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
	return String(format: "%6.3fs", Double(ms) / 1_000)
}

func say(_ line: String) {
	print("[\(stamp())] \(line)")
}

// MARK: - Fakes

/// Plays a script of hotkey actions with pauses in between.
struct ScriptedHotkey: HotkeySource {
	enum Step: Sendable {
		case send(HotkeyAction)
		case wait(Duration)
	}

	let script: [Step]

	func actions() -> AsyncStream<HotkeyAction> {
		let script = self.script
		return AsyncStream { continuation in
			let task = Task {
				for step in script {
					switch step {
					case .send(let action):
						say("hotkey  \(action)")
						continuation.yield(action)
					case .wait(let duration):
						try? await Task.sleep(for: duration)
					}
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}

/// A 220 Hz tone that swells and fades, delivered in real time, 100 ms per chunk.
actor ToneMic: AudioSource {
	private var continuation: AsyncStream<AudioChunk>.Continuation?
	private var feeder: Task<Void, Never>?

	func prepare() async throws {}

	func start() async throws -> AsyncStream<AudioChunk> {
		let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
		self.continuation = continuation
		feeder = Task {
			var n = 0
			while !Task.isCancelled {
				let amplitude = Float(0.02 + 0.3 * abs(sin(Double(n) / 4)))
				let samples = (0..<1_600).map { i in
					amplitude * Float(sin(2 * Double.pi * 220 * Double(n * 1_600 + i) / AudioChunk.sampleRate))
				}
				continuation.yield(AudioChunk(samples: samples, hostTime: UInt64(n)))
				n += 1
				try? await Task.sleep(for: .milliseconds(100))
			}
		}
		say("mic     start")
		return stream
	}

	func stop() async {
		feeder?.cancel()
		continuation?.finish()
		continuation = nil
		say("mic     stop")
	}
}

actor QuietEngine: SpeechEngine {
	func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {}
	func warmUp() async { say("engine  warmUp") }
	func transcribe(_ samples: [Float]) async throws -> Transcript { Transcript(text: "", confidence: 1) }
	func unload() async {}
}

/// Hands out canned transcripts, one per finished dictation.
actor CannedTranscription: StreamingTranscription {
	private var texts: [String]
	private var seconds: Double = 0

	init(texts: [String]) { self.texts = texts }

	func begin() async { seconds = 0 }
	func append(_ chunk: AudioChunk) async { seconds += chunk.duration }

	func finish() async throws -> String {
		try await Task.sleep(for: .milliseconds(40)) // the tail chunk
		let text = texts.isEmpty ? "" : texts.removeFirst()
		say(String(format: "speech  finish after %.1f s of audio", seconds))
		return text
	}

	func cancel() async { say(String(format: "speech  cancel after %.1f s of audio", seconds)) }
}

actor PrintingInserter: TextInserter {
	var target: FocusTarget?
	var outcomes: [InsertOutcome]

	init(target: FocusTarget?, outcomes: [InsertOutcome]) {
		self.target = target
		self.outcomes = outcomes
	}

	func focus(_ target: FocusTarget?, outcomes: [InsertOutcome]) {
		self.target = target
		self.outcomes = outcomes
	}

	func captureTarget() async -> FocusTarget? {
		say("insert  captureTarget → \(target?.bundleID ?? "none")")
		return target
	}

	func insert(_ text: String, into target: FocusTarget) async -> InsertOutcome {
		let outcome = outcomes.isEmpty ? .ax : outcomes.removeFirst()
		say("insert  \"\(text)\" into \(target.bundleID ?? "?") → \(outcome)")
		return outcome
	}
}

struct PrintingClipboard: ClipboardWriter {
	func write(_ text: String) async { say("clip    \"\(text)\"") }
}

func printHistory(_ store: SQLiteHistoryStore) async throws {
	let entries = try await store.recent(limit: 20)
	print("history (\(entries.count) rows, newest first):")
	for entry in entries {
		print("  #\(entry.id ?? -1)  \(entry.createdAt.formatted(.iso8601))  \(entry.appBundleID ?? "-")  \(String(format: "%.1f s", entry.duration))  \"\(entry.text)\"")
	}
}

// MARK: - Modes

func runSession(dbPath: String) async throws {
	let store = try SQLiteHistoryStore(url: URL(filePath: dbPath))
	let textEdit = FocusTarget(pid: 501, bundleID: "com.apple.TextEdit")
	let inserter = PrintingInserter(target: textEdit, outcomes: [.ax, .focusChanged])
	let hotkey = ScriptedHotkey(script: [
		// 1. Hold for 2 s, release.
		.send(.start), .wait(.seconds(2)), .send(.stop), .wait(.milliseconds(400)),
		// 2. Hold, then Esc.
		.send(.start), .wait(.seconds(1)), .send(.cancel), .wait(.milliseconds(400)),
		// 3. Hold and release, but focus moved (the inserter reports it).
		.send(.start), .wait(.milliseconds(1_500)), .send(.stop), .wait(.milliseconds(400)),
	])
	let session = DictationSession(
		hotkey: hotkey,
		audio: ToneMic(),
		engine: QuietEngine(),
		transcription: CannedTranscription(texts: [
			"Hej! Vi ses på mötet i morgon klockan tio.",
			"Remember to send the budget to Åsa before Friday.",
		]),
		inserter: inserter,
		history: store,
		clipboard: PrintingClipboard()
	)

	let stateLog = Task {
		for await state in session.states {
			say("state   \(state)")
		}
	}
	let levelLog = Task {
		var levels: [Float] = []
		for await level in session.levels {
			levels.append(level)
		}
		return levels
	}

	await session.run()

	let outcome = await session.lastOutcome
	say("lastOutcome \(outcome.map { "\($0)" } ?? "nil"), message: \(outcome?.message ?? "nil")")
	try await printHistory(store)

	say("-- paste last into Notes")
	await inserter.focus(FocusTarget(pid: 777, bundleID: "com.apple.Notes"), outcomes: [.paste])
	let pasted = await session.pasteLast()
	say("pasteLast → \(pasted.map { "\($0)" } ?? "nil")")

	try await Task.sleep(for: .milliseconds(50))
	stateLog.cancel()
	levelLog.cancel()
	let levels = await levelLog.value
	let bars = " ▁▂▃▄▅▆▇█"
	let waveform = levels.prefix(40).map { level in
		bars[bars.index(bars.startIndex, offsetBy: Int((level * 8).rounded()))]
	}
	print("levels: \(levels.count) received, first 40: \(String(waveform))")
}

func runBulk(dbPath: String, count: Int) async throws {
	let store = try SQLiteHistoryStore(url: URL(filePath: dbPath))
	let phrases = [
		"Vi ses på mötet i morgon klockan tio",
		"Glöm inte att köpa äpplen och smör",
		"Återkommer om budgeten efter lunch",
		"Let's move the budget meeting to Thursday",
		"Remember to call the dentist",
		"Ship the release notes before Friday",
		"Kan du skicka presentationen till Åsa",
		"The quick brown fox jumps over the lazy dog",
	]
	let now = Date.now
	let clock = ContinuousClock()
	let insertTime = try await clock.measure {
		for i in 0..<count {
			// Spread over the last 60 days so prune has work to do.
			let age = Double(i) / Double(count) * 60 * 86_400
			try await store.save(HistoryEntry(
				text: "\(phrases[i % phrases.count]) #\(i)",
				createdAt: now.addingTimeInterval(-age),
				appBundleID: i.isMultiple(of: 2) ? "com.tinyspeck.slackmacgap" : "com.apple.mail",
				duration: 3.2
			))
		}
	}
	print("inserted \(count) entries one save() at a time in \(insertTime) (\(insertTime / count) each)")

	for query in ["möte", "mote", "MÖTET", "äpp", "återkom", "aterkommer", "budg", "budget thurs", "åsa", "fox lazy", "nomatch"] {
		var hits = 0
		var times: [Duration] = []
		for _ in 0..<20 {
			let elapsed = try await clock.measure {
				hits = try await store.search(query, limit: 50).count
			}
			times.append(elapsed)
		}
		times.sort()
		print("search \(query.padding(toLength: 13, withPad: " ", startingAt: 0)) hits(limit 50)=\(String(hits).padding(toLength: 3, withPad: " ", startingAt: 0)) p50=\(times[10]) max=\(times[19])")
	}

	let before = try await store.recent(limit: count * 2).count
	let pruneTime = try await clock.measure {
		try await store.prune(before: now.addingTimeInterval(-30 * 86_400))
	}
	let after = try await store.recent(limit: count * 2).count
	let staleHits = try await store.search("möte", limit: count).filter { $0.createdAt < now.addingTimeInterval(-30 * 86_400) }.count
	print("prune(before: 30 days ago): \(before) → \(after) rows in \(pruneTime); stale search hits after prune: \(staleHits)")
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
	print("usage: yap-harness-session session <db-path> | bulk <db-path> [count]")
	exit(2)
}
do {
	switch arguments[1] {
	case "session":
		try await runSession(dbPath: arguments[2])
	case "bulk":
		try await runBulk(dbPath: arguments[2], count: arguments.count > 3 ? Int(arguments[3]) ?? 10_000 : 10_000)
	default:
		print("unknown mode \(arguments[1])")
		exit(2)
	}
} catch {
	print("error: \(error)")
	exit(1)
}
