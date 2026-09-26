import Foundation

/// One finished dictation. Text only; audio is never stored.
public struct HistoryEntry: Sendable, Equatable, Identifiable {
	public var id: Int64?
	public var text: String
	public var createdAt: Date
	public var appBundleID: String?
	/// Seconds of speech.
	public var duration: Double

	public init(id: Int64? = nil, text: String, createdAt: Date = .now, appBundleID: String?, duration: Double) {
		self.id = id
		self.text = text
		self.createdAt = createdAt
		self.appBundleID = appBundleID
		self.duration = duration
	}
}

public protocol HistoryStore: Sendable {
	/// Saves before anything else happens, so no words are ever lost.
	@discardableResult
	func save(_ entry: HistoryEntry) async throws -> HistoryEntry
	func recent(limit: Int) async throws -> [HistoryEntry]
	func search(_ query: String, limit: Int) async throws -> [HistoryEntry]
	func last() async throws -> HistoryEntry?
	/// Removes entries older than `date`.
	func prune(before date: Date) async throws
}
