import Foundation
import OSLog
import YapKit

/// The history database, opened in the background and retried with backoff
/// when it can't be opened (another process holds the lock, disk hiccup).
///
/// Until it is open every call throws `HistoryAccess.Unavailable`. The
/// dictation session treats a failed save as "insert anyway and keep the text
/// for paste last", so dictation never waits on the database.
actor HistoryAccess: HistoryStore {
	struct Unavailable: Error {}

	/// History keeps 30 days (plan section 5).
	static let retention: TimeInterval = 30 * 24 * 60 * 60
	private static let firstRetry: Duration = .milliseconds(500)
	private static let longestRetry: Duration = .seconds(60)

	private let url: URL?
	private var store: SQLiteHistoryStore?
	private var opening: Task<Void, Never>?

	/// - Parameter url: nil opens the default location.
	init(url: URL? = nil) {
		self.url = url
	}

	var isOpen: Bool { store != nil }

	/// Starts opening the database in the background, retrying until it works,
	/// then prunes old entries and calls `onOpen`. Calling it again while it is
	/// trying (or once open) does nothing.
	func open(onOpen: @escaping @Sendable () async -> Void) {
		guard store == nil, opening == nil else { return }
		opening = Task {
			var delay = Self.firstRetry
			var attempt = 1
			while !Task.isCancelled {
				do {
					let store = try url.map { try SQLiteHistoryStore(url: $0) } ?? SQLiteHistoryStore()
					await self.didOpen(store)
					await onOpen()
					return
				} catch {
					Logger.history.error("Opening history failed (attempt \(attempt, privacy: .public)): \(error, privacy: .public); retrying in \(String(describing: delay), privacy: .public)")
				}
				try? await Task.sleep(for: delay)
				delay = min(delay * 2, Self.longestRetry)
				attempt += 1
			}
		}
	}

	private func didOpen(_ store: SQLiteHistoryStore) async {
		self.store = store
		opening = nil
		do {
			try await store.prune(before: Date.now.addingTimeInterval(-Self.retention))
		} catch {
			// Old entries stay one more launch; not worth bothering anyone.
			Logger.history.error("Pruning history failed: \(error, privacy: .public)")
		}
		Logger.history.notice("History open")
	}

	private func opened() throws -> SQLiteHistoryStore {
		guard let store else { throw Unavailable() }
		return store
	}

	// MARK: HistoryStore

	@discardableResult
	func save(_ entry: HistoryEntry) async throws -> HistoryEntry {
		try await opened().save(entry)
	}

	func recent(limit: Int) async throws -> [HistoryEntry] {
		try await opened().recent(limit: limit)
	}

	func search(_ query: String, limit: Int) async throws -> [HistoryEntry] {
		try await opened().search(query, limit: limit)
	}

	func last() async throws -> HistoryEntry? {
		try await opened().last()
	}

	func prune(before date: Date) async throws {
		try await opened().prune(before: date)
	}
}

extension Logger {
	static let history = Logger(subsystem: "com.bjornbom.yap", category: "history")
}
