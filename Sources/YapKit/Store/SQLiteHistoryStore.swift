import Foundation
import GRDB

/// Dictation history in SQLite, searchable with FTS5.
///
/// Search is by word prefix ("bud" finds "budget"), case- and
/// diacritics-insensitive ("mote" and "MÖTE" both find "möte"), newest first.
public final class SQLiteHistoryStore: HistoryStore {
	private let db: any DatabaseWriter

	/// `~/Library/Application Support/yap/history.sqlite`.
	public static func defaultURL() throws -> URL {
		let support = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		return support.appending(path: "yap", directoryHint: .isDirectory)
			.appending(path: "history.sqlite", directoryHint: .notDirectory)
	}

	/// Opens (or creates) the history at the default location.
	public convenience init() throws {
		try self.init(url: Self.defaultURL())
	}

	/// Opens (or creates) the history at `url`.
	///
	/// - Parameter busyTimeout: How long a write waits for another process
	///   holding the database lock before it throws. Short, because a save sits
	///   between key-up and the text appearing.
	public init(url: URL, busyTimeout: TimeInterval = 1) throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		var configuration = Configuration()
		configuration.busyMode = .timeout(busyTimeout)
		// A pool (WAL) lets the history window read while a dictation saves.
		db = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
		try Self.migrator.migrate(db)
	}

	private init(writer: any DatabaseWriter) throws {
		db = writer
		try Self.migrator.migrate(db)
	}

	/// A throwaway history that lives in memory, for tests and previews.
	public static func inMemory() throws -> SQLiteHistoryStore {
		try SQLiteHistoryStore(writer: DatabaseQueue())
	}

	private static var migrator: DatabaseMigrator {
		var migrator = DatabaseMigrator()
		migrator.registerMigration("v1") { db in
			try db.create(table: "history") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("text", .text).notNull()
				t.column("createdAt", .datetime).notNull().indexed()
				t.column("appBundleID", .text)
				t.column("duration", .double).notNull()
			}
			try db.create(virtualTable: "history_fts", using: FTS5()) { t in
				// External content: the text is stored once, triggers keep the index in sync.
				t.synchronize(withTable: "history")
				// remove_diacritics=2 also folds letters with several marks; the
				// legacy mode (1) misses some of them.
				t.tokenizer = .unicode61(diacritics: .remove)
				t.column("text")
			}
		}
		return migrator
	}

	@discardableResult
	public func save(_ entry: HistoryEntry) async throws -> HistoryEntry {
		try await db.write { db in
			var saved = entry
			let arguments: StatementArguments = [entry.id, entry.text, entry.createdAt, entry.appBundleID, entry.duration]
			// Upsert rather than INSERT OR REPLACE: REPLACE deletes without
			// firing the delete trigger, which would leave stale FTS rows.
			try db.execute(
				sql: """
					INSERT INTO history (id, text, createdAt, appBundleID, duration)
					VALUES (?, ?, ?, ?, ?)
					ON CONFLICT(id) DO UPDATE SET
						text = excluded.text,
						createdAt = excluded.createdAt,
						appBundleID = excluded.appBundleID,
						duration = excluded.duration
					""",
				arguments: arguments
			)
			if saved.id == nil {
				saved.id = db.lastInsertedRowID
			}
			return saved
		}
	}

	public func recent(limit: Int) async throws -> [HistoryEntry] {
		try await db.read { db in
			try Row.fetchAll(
				db,
				sql: "SELECT * FROM history ORDER BY createdAt DESC, id DESC LIMIT ?",
				arguments: [limit]
			).map(Self.entry)
		}
	}

	/// An empty query (or one with no letters or digits) returns `recent(limit:)`,
	/// so a cleared search box shows the latest entries.
	public func search(_ query: String, limit: Int) async throws -> [HistoryEntry] {
		guard let pattern = Self.prefixPattern(for: query) else {
			return try await recent(limit: limit)
		}
		return try await db.read { db in
			try Row.fetchAll(
				db,
				sql: """
					SELECT history.* FROM history
					JOIN history_fts ON history_fts.rowid = history.id
					WHERE history_fts MATCH ?
					ORDER BY history.createdAt DESC, history.id DESC
					LIMIT ?
					""",
				arguments: [pattern, limit]
			).map(Self.entry)
		}
	}

	public func last() async throws -> HistoryEntry? {
		try await recent(limit: 1).first
	}

	public func prune(before date: Date) async throws {
		try await db.write { db in
			try db.execute(sql: "DELETE FROM history WHERE createdAt < ?", arguments: [date])
		}
	}

	/// Builds `"word1"* "word2"*`: every word must match as a prefix.
	///
	/// Words are split on anything that isn't a letter or digit and quoted, so
	/// user input can never be read as FTS5 syntax (AND, NEAR, quotes, colons).
	/// The table's tokenizer folds case and diacritics of each quoted word.
	static func prefixPattern(for query: String) -> String? {
		let words = query
			.split { !($0.isLetter || $0.isNumber) }
			.map { "\"\($0)\"*" }
		return words.isEmpty ? nil : words.joined(separator: " ")
	}

	private static func entry(_ row: Row) -> HistoryEntry {
		HistoryEntry(
			id: row["id"],
			text: row["text"],
			createdAt: row["createdAt"],
			appBundleID: row["appBundleID"],
			duration: row["duration"]
		)
	}
}
