import Foundation
import SQLite3
import Testing
@testable import YapKit

@Suite struct SQLiteHistoryStoreTests {
	let store: SQLiteHistoryStore
	let base = Date(timeIntervalSince1970: 1_790_000_000)

	init() throws {
		store = try SQLiteHistoryStore.inMemory()
	}

	@discardableResult
	func add(_ text: String, minutesAgo: Double = 0, app: String? = nil) async throws -> HistoryEntry {
		try await store.save(HistoryEntry(
			text: text,
			createdAt: base.addingTimeInterval(-minutesAgo * 60),
			appBundleID: app,
			duration: 1.5
		))
	}

	@Test func saveAssignsIDAndRoundTrips() async throws {
		let saved = try await add("Hej världen", app: "com.apple.mail")
		#expect(saved.id != nil)
		let last = try #require(try await store.last())
		#expect(last == saved)
	}

	@Test func lastIsNewestAndNilWhenEmpty() async throws {
		#expect(try await store.last() == nil)
		try await add("older", minutesAgo: 10)
		try await add("newest", minutesAgo: 1)
		try await add("middle", minutesAgo: 5)
		#expect(try await store.last()?.text == "newest")
	}

	@Test func recentIsNewestFirstAndLimited() async throws {
		for i in 0..<5 {
			try await add("entry \(i)", minutesAgo: Double(i))
		}
		let recent = try await store.recent(limit: 3)
		#expect(recent.map(\.text) == ["entry 0", "entry 1", "entry 2"])
	}

	@Test func saveWithExistingIDUpdatesInPlace() async throws {
		var entry = try await add("draft text")
		entry.text = "final text"
		try await store.save(entry)
		#expect(try await store.recent(limit: 10).map(\.text) == ["final text"])
		#expect(try await store.search("draft", limit: 10).isEmpty)
		#expect(try await store.search("final", limit: 10).count == 1)
	}

	@Test func searchEnglishByPrefixAndCase() async throws {
		try await add("Let's move the budget meeting to Thursday")
		try await add("Remember to buy milk")
		#expect(try await store.search("budg", limit: 10).map(\.text) == ["Let's move the budget meeting to Thursday"])
		#expect(try await store.search("THURS meet", limit: 10).count == 1)
		#expect(try await store.search("budget milk", limit: 10).isEmpty, "every word has to match")
	}

	@Test func searchSwedish() async throws {
		try await add("Vi ses på mötet i morgon")
		try await add("Glöm inte att köpa äpplen och smör")
		try await add("Återkommer om budgeten")

		// Exact Swedish letters, any case, as prefixes.
		#expect(try await store.search("möte", limit: 10).map(\.text) == ["Vi ses på mötet i morgon"])
		#expect(try await store.search("MÖTET", limit: 10).count == 1)
		#expect(try await store.search("äppl", limit: 10).map(\.text) == ["Glöm inte att köpa äpplen och smör"])
		#expect(try await store.search("återkom", limit: 10).count == 1)
		#expect(try await store.search("Återkommer", limit: 10).count == 1)

		// Diacritics-insensitive both ways: typed without ring/dots finds them.
		#expect(try await store.search("mote", limit: 10).count == 1)
		#expect(try await store.search("kopa smor", limit: 10).count == 1)
		#expect(try await store.search("aterkommer", limit: 10).count == 1)
	}

	@Test func searchIgnoresFTSSyntaxInInput() async throws {
		try await add("AND or NEAR \"quoted\" col:on")
		#expect(try await store.search("\"quot", limit: 10).count == 1)
		#expect(try await store.search("col:", limit: 10).count == 1)
		#expect(try await store.search("NEAR(", limit: 10).count == 1)
		#expect(try await store.search("*", limit: 10).count == 1, "no words falls back to recent")
	}

	@Test func emptySearchReturnsRecent() async throws {
		try await add("one", minutesAgo: 2)
		try await add("two", minutesAgo: 1)
		#expect(try await store.search("  ", limit: 10).map(\.text) == ["two", "one"])
	}

	@Test func pruneRemovesOldEntriesFromTableAndIndex() async throws {
		try await add("gammal anteckning", minutesAgo: 60 * 24 * 31)
		try await add("färsk anteckning", minutesAgo: 1)
		try await store.prune(before: base.addingTimeInterval(-30 * 24 * 3600))
		#expect(try await store.recent(limit: 10).map(\.text) == ["färsk anteckning"])
		#expect(try await store.search("gammal", limit: 10).isEmpty)
		#expect(try await store.search("anteckning", limit: 10).count == 1)
	}

	@Test func fileStoreReopensWithData() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "yap-history-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let url = dir.appending(path: "nested/history.sqlite")
		do {
			let first = try SQLiteHistoryStore(url: url)
			try await first.save(HistoryEntry(text: "sparad på disk", appBundleID: nil, duration: 2))
		}
		let second = try SQLiteHistoryStore(url: url)
		#expect(try await second.search("sparad", limit: 10).count == 1)
	}

	@Test func opensAndReadsWhileAnotherProcessHoldsTheWriteLock() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "yap-history-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: dir) }
		let url = dir.appending(path: "history.sqlite")
		let running = try SQLiteHistoryStore(url: url)
		try await running.save(HistoryEntry(text: "före låset", appBundleID: nil, duration: 1))

		// A second connection, like a DB browser, takes the write lock.
		var locker: OpaquePointer?
		#expect(sqlite3_open(url.path(percentEncoded: false), &locker) == SQLITE_OK)
		defer { sqlite3_close(locker) }
		#expect(sqlite3_exec(locker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

		let reopened = try SQLiteHistoryStore(url: url, busyTimeout: 0.1)
		#expect(try await reopened.search("lase", limit: 10).count == 1)
		await #expect(throws: (any Error).self) {
			try await reopened.save(HistoryEntry(text: "under låset", appBundleID: nil, duration: 1))
		}

		#expect(sqlite3_exec(locker, "COMMIT", nil, nil, nil) == SQLITE_OK)
		try await reopened.save(HistoryEntry(text: "efter låset", appBundleID: nil, duration: 1))
		#expect(try await running.search("låset", limit: 10).map(\.text).sorted() == ["efter låset", "före låset"])
	}

	@Test func prefixPattern() {
		#expect(SQLiteHistoryStore.prefixPattern(for: "hej då") == "\"hej\"* \"då\"*")
		#expect(SQLiteHistoryStore.prefixPattern(for: "\"x\" OR y") == "\"x\"* \"OR\"* \"y\"*")
		#expect(SQLiteHistoryStore.prefixPattern(for: " - ") == nil)
	}
}
