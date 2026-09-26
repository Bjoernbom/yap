import Foundation
import Testing
@testable import YapKit

@Suite struct DictationSessionTests {
	static let textEdit = FocusTarget(pid: 42, bundleID: "com.apple.TextEdit")
	static let listening = DictationState.listening(locked: false)

	@Test func happyPath() async throws {
		let rig = Rig(processor: ShoutingProcessor())
		await rig.startListening()
		await rig.session.handle(.stop)
		let states = await rig.states.wait(forCount: 4)

		#expect(states == [Self.listening, .transcribing, .done(.ax), .idle])
		let inserted = await rig.inserter.inserted
		#expect(inserted.map(\.text) == ["HELLO FROM YAP [com.apple.TextEdit]"])
		#expect(inserted.map(\.target) == [Self.textEdit])
		let entry = try #require(await rig.history.entries.first)
		#expect(entry.text == "HELLO FROM YAP [com.apple.TextEdit]")
		#expect(entry.appBundleID == "com.apple.TextEdit")
		#expect(abs(entry.duration - 1.0) < 0.001)
		#expect(await rig.clipboard.writes.isEmpty)
		#expect(await rig.session.lastOutcome == .ax)
		#expect(await rig.session.state == .idle)
		#expect(await rig.engine.warmUps == 1)
	}

	@Test func pipelineRunsInOrderAndSavesBeforeInserting() async throws {
		let rig = Rig()
		await rig.startListening()
		await rig.session.handle(.stop)
		await rig.states.wait(forCount: 4)

		let events = rig.log.all.filter { $0 != "engine.warmUp" }
		#expect(events == [
			"inserter.captureTarget",
			"transcription.begin",
			"audio.start",
			"audio.stop",
			"transcription.finish",
			"history.save",
			"inserter.insert",
		])
	}

	@Test func levelsFollowTheAudio() async throws {
		let rig = Rig()
		await rig.audio.configure(chunks: [chunk(0.001), chunk(0.1), chunk(1)])
		await rig.startListening(expectingChunks: 3)
		var levels: [Float] = []
		for await level in rig.session.levels {
			levels.append(level)
			if levels.count == 3 { break }
		}
		#expect(levels == [chunk(0.001).level, chunk(0.1).level, chunk(1).level])
		#expect(levels[0] < levels[1] && levels[1] < levels[2])
	}

	@Test func lockKeepsListeningUntilStop() async throws {
		let rig = Rig()
		await rig.startListening()
		await rig.session.handle(.lock)
		#expect(await rig.session.state == .listening(locked: true))
		await rig.audio.push(chunk())
		#expect(await eventually { await rig.transcription.appended == 11 })
		await rig.session.handle(.stop)
		let states = await rig.states.wait(forCount: 5)

		#expect(states == [Self.listening, .listening(locked: true), .transcribing, .done(.ax), .idle])
		#expect(abs((await rig.history.entries.first?.duration ?? 0) - 1.1) < 0.001)
	}

	@Test func cancelWhileListeningDropsEverything() async throws {
		let rig = Rig()
		await rig.startListening()
		await rig.session.handle(.cancel)
		#expect(await rig.states.wait(forCount: 2) == [Self.listening, .idle])
		#expect(await eventually { await rig.transcription.cancelCalls == 1 })
		#expect(rig.log.count(of: "audio.stop") == 1)
		#expect(await rig.transcription.finishCalls == 0)
		#expect(await rig.history.entries.isEmpty)
		#expect(await rig.inserter.inserted.isEmpty)
		#expect(await rig.clipboard.writes.isEmpty)

		// The next press works normally.
		await rig.startListening()
		await rig.session.handle(.stop)
		let states = await rig.states.wait(forCount: 6)
		#expect(Array(states.suffix(4)) == [Self.listening, .transcribing, .done(.ax), .idle])
	}

	@Test func cancelWhileTranscribingDropsEverything() async throws {
		let rig = Rig()
		await rig.transcription.configure(holdsFinish: true)
		await rig.startListening()
		await rig.session.handle(.stop)
		#expect(await eventually { await rig.transcription.isHoldingFinish })
		await rig.session.handle(.cancel)
		let states = await rig.states.wait(forCount: 3)
		try await Task.sleep(for: .milliseconds(50))

		#expect(rig.states.all == [Self.listening, .transcribing, .idle])
		#expect(states == [Self.listening, .transcribing, .idle])
		#expect(await rig.transcription.cancelCalls == 1)
		#expect(await rig.history.entries.isEmpty)
		#expect(await rig.inserter.inserted.isEmpty)
		#expect(await rig.clipboard.writes.isEmpty)
		#expect(await rig.session.lastOutcome == nil)
	}

	@Test func cancelThenImmediateStartRecordsAgain() async throws {
		// The hotkey sends cancel+start back to back when a lone tap expires
		// just as the key goes down again.
		let rig = Rig()
		await rig.startListening()
		await rig.session.handle(.cancel)
		await rig.session.handle(.start)
		await rig.session.handle(.stop)
		let states = await rig.states.wait(forCount: 6)
		#expect(states == [Self.listening, .idle, Self.listening, .transcribing, .done(.ax), .idle])
		#expect(await rig.audio.startCount == 2)
	}

	@Test func emptyTranscriptEndsEmpty() async throws {
		let rig = Rig()
		await rig.transcription.configure(result: .success("  \n"))
		await rig.startListening()
		await rig.session.handle(.stop)
		#expect(await rig.states.wait(forCount: 4) == [Self.listening, .transcribing, .empty, .idle])
		#expect(await rig.history.entries.isEmpty)
		#expect(await rig.inserter.inserted.isEmpty)
	}

	@Test func tooShortNeverReachesTheEngine() async throws {
		let rig = Rig()
		await rig.audio.configure(chunks: [chunk()])
		await rig.startListening(expectingChunks: 1)
		await rig.session.handle(.stop)
		#expect(await rig.states.wait(forCount: 4) == [Self.listening, .transcribing, .empty, .idle])
		#expect(await rig.transcription.finishCalls == 0)
		#expect(await rig.transcription.cancelCalls == 1)
		#expect(await rig.history.entries.isEmpty)
	}

	@Test func engineErrorFailsWithAMessage() async throws {
		let rig = Rig()
		await rig.transcription.configure(result: .failure(FakeError()))
		await rig.startListening()
		await rig.session.handle(.stop)
		let states = await rig.states.wait(forCount: 4)
		#expect(states == [Self.listening, .transcribing, .failed("Couldn't turn that into text. Try again."), .idle])
		#expect(await rig.history.entries.isEmpty)
		#expect(await rig.inserter.inserted.isEmpty)
	}

	@Test func micErrorFailsWithAMessage() async throws {
		let rig = Rig()
		await rig.audio.configure(startError: FakeError())
		await rig.session.handle(.start)
		let states = await rig.states.wait(forCount: 3)
		#expect(states == [Self.listening, .failed("Couldn't start the mic. Check that yap has Microphone access."), .idle])
		#expect(await rig.transcription.cancelCalls == 1)

		// A stop for that press is ignored; the next press works.
		await rig.session.handle(.stop)
		await rig.audio.configure(startError: nil)
		await rig.startListening()
		await rig.session.handle(.stop)
		#expect(Array(await rig.states.wait(forCount: 7).suffix(4)) == [Self.listening, .transcribing, .done(.ax), .idle])
	}

	@Test(arguments: [InsertOutcome.focusChanged, .secureField, .noTarget, .failed])
	func failedInsertKeepsTextAndUsesClipboard(outcome: InsertOutcome) async throws {
		let rig = Rig()
		await rig.inserter.configure(target: Self.textEdit, outcome: outcome)
		await rig.startListening()
		await rig.session.handle(.stop)
		#expect(await rig.states.wait(forCount: 4) == [Self.listening, .transcribing, .done(outcome), .idle])
		#expect(await rig.history.entries.map(\.text) == ["hello from yap"])
		#expect(await rig.clipboard.writes == ["hello from yap"])
		#expect(await rig.session.lastOutcome == outcome)
		#expect(outcome.message?.hasSuffix("It's on your clipboard.") == true)
		#expect(rig.log.index(of: "history.save")! < rig.log.index(of: "inserter.insert")!)
		#expect(rig.log.index(of: "inserter.insert")! < rig.log.index(of: "clipboard.write")!)
	}

	@Test func noFocusedAppAtKeyDownGoesToClipboard() async throws {
		let rig = Rig()
		await rig.inserter.configure(target: nil)
		await rig.startListening()
		await rig.session.handle(.stop)
		#expect(await rig.states.wait(forCount: 4) == [Self.listening, .transcribing, .done(.noTarget), .idle])
		#expect(await rig.inserter.inserted.isEmpty)
		#expect(await rig.history.entries.first?.appBundleID == nil)
		#expect(await rig.clipboard.writes == ["hello from yap"])
	}

	@Test func startWhileTranscribingIsIgnored() async throws {
		let rig = Rig()
		await rig.transcription.configure(holdsFinish: true)
		await rig.startListening()
		await rig.session.handle(.stop)
		#expect(await eventually { await rig.transcription.isHoldingFinish })

		// A second press lands while the first is still transcribing.
		await rig.session.handle(.start)
		await rig.session.handle(.lock)
		await rig.session.handle(.stop)
		#expect(await rig.session.state == .transcribing)
		#expect(await rig.inserter.captures == 1)
		#expect(await rig.audio.startCount == 1)

		await rig.transcription.releaseFinish()
		let states = await rig.states.wait(forCount: 4)
		try await Task.sleep(for: .milliseconds(50))
		#expect(states == [Self.listening, .transcribing, .done(.ax), .idle])
		#expect(rig.states.all.count == 4)
		#expect(await rig.inserter.inserted.count == 1)
		#expect(await rig.history.entries.count == 1)
	}

	@Test func maxLengthStopsAndInsertsOnItsOwn() async throws {
		let rig = Rig(configuration: .init(maxRecordingDuration: .milliseconds(150)))
		await rig.startListening()
		let states = await rig.states.wait(forCount: 4)
		#expect(states == [Self.listening, .transcribing, .done(.ax), .idle])
		#expect(await rig.inserter.inserted.count == 1)

		// The key-up that eventually follows is harmless.
		await rig.session.handle(.stop)
		#expect(rig.states.all.count == 4)
	}

	@Test func micEndingOnItsOwnFinishesTheDictation() async throws {
		let rig = Rig()
		await rig.audio.configure(endsOnItsOwn: true)
		await rig.session.handle(.start)
		let states = await rig.states.wait(forCount: 4)
		#expect(states == [Self.listening, .transcribing, .done(.ax), .idle])
	}

	@Test func historyFailureStillInsertsAndPasteLastHasTheText() async throws {
		let rig = Rig()
		await rig.history.configure(failsSaves: true)
		await rig.startListening()
		await rig.session.handle(.stop)
		#expect(await rig.states.wait(forCount: 4) == [Self.listening, .transcribing, .done(.ax), .idle])
		#expect(await rig.inserter.inserted.map(\.text) == ["hello from yap"])

		#expect(await rig.session.pasteLast() == .ax)
		#expect(await rig.inserter.inserted.map(\.text) == ["hello from yap", "hello from yap"])
	}

	@Test func pasteLastReinsertsIntoTheAppFocusedNow() async throws {
		let rig = Rig()
		await rig.inserter.configure(target: Self.textEdit, outcome: .focusChanged)
		await rig.startListening()
		await rig.session.handle(.stop)
		await rig.states.wait(forCount: 4)

		let notes = FocusTarget(pid: 7, bundleID: "com.apple.Notes")
		await rig.inserter.configure(target: notes, outcome: .paste)
		#expect(await rig.session.pasteLast() == .paste)
		let last = try #require(await rig.inserter.inserted.last)
		#expect(last.text == "hello from yap")
		#expect(last.target == notes)
		#expect(await rig.session.lastOutcome == .paste)
		#expect(Array(await rig.states.wait(forCount: 6).suffix(2)) == [.done(.paste), .idle])
	}

	@Test func pasteLastFallsBackToClipboard() async throws {
		let rig = Rig()
		try await rig.history.save(HistoryEntry(text: "från igår", appBundleID: nil, duration: 1))
		await rig.inserter.configure(target: Self.textEdit, outcome: .secureField)
		#expect(await rig.session.pasteLast() == .secureField)
		#expect(await rig.clipboard.writes == ["från igår"])
	}

	@Test func pasteLastWithNothingToPaste() async throws {
		let rig = Rig()
		#expect(await rig.session.pasteLast() == nil)
		#expect(await rig.inserter.captures == 0)

		await rig.history.configure(failsReads: true)
		#expect(await rig.session.pasteLast() == nil)
		#expect(await rig.states.wait(forCount: 2) == [.failed("Couldn't read your history. Try again."), .idle])
	}

	@Test func pasteLastIsIgnoredWhileListening() async throws {
		let rig = Rig()
		try await rig.history.save(HistoryEntry(text: "old", appBundleID: nil, duration: 1))
		await rig.startListening()
		#expect(await rig.session.pasteLast() == nil)
		#expect(await rig.inserter.inserted.isEmpty)
	}

	@Test func runFollowsTheHotkey() async throws {
		let rig = Rig()
		let running = Task { await rig.session.run() }
		defer { running.cancel() }

		rig.hotkey.send(.start)
		#expect(await eventually { await rig.transcription.appended == 10 })
		rig.hotkey.send(.lock)
		rig.hotkey.send(.stop)
		let states = await rig.states.wait(forCount: 5)
		#expect(states == [Self.listening, .listening(locked: true), .transcribing, .done(.ax), .idle])

		// A lone tap: start, then cancel.
		rig.hotkey.send(.start)
		rig.hotkey.send(.cancel)
		#expect(Array(await rig.states.wait(forCount: 7).suffix(2)) == [Self.listening, .idle])
		#expect(await rig.inserter.inserted.count == 1)

		rig.hotkey.continuation.finish()
		await running.value
	}

	@Test func realStoreEndToEnd() async throws {
		let rig = Rig()
		let store = try SQLiteHistoryStore.inMemory()
		let session = DictationSession(
			hotkey: rig.hotkey,
			audio: rig.audio,
			engine: rig.engine,
			transcription: rig.transcription,
			inserter: rig.inserter,
			history: store,
			clipboard: rig.clipboard
		)
		await rig.transcription.configure(result: .success("Boka mötet på fredag"))
		await session.handle(.start)
		#expect(await eventually { await rig.transcription.appended == 10 })
		await session.handle(.stop)
		#expect(await eventually { await session.lastOutcome == .ax })
		#expect(try await store.search("mote freda", limit: 5).map(\.text) == ["Boka mötet på fredag"])
	}
}
