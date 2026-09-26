import AppKit
import SwiftUI
import YapKit

/// The last 30 days of dictations, newest first. Search matches word
/// prefixes; clicking an entry copies it.
struct HistoryView: View {
	let dictation: DictationController

	private static let limit = 300

	@State private var query = ""
	@State private var entries: [HistoryEntry] = []
	@State private var unavailable = false
	@State private var copiedID: Int64?

	var body: some View {
		content
			.frame(minWidth: 520, minHeight: 360)
			.searchable(text: $query, placement: .toolbar, prompt: "Search")
			.task(id: Reload(query: query, revision: dictation.historyRevision)) {
				// Typing fires this per keystroke; the previous task is cancelled.
				if !query.isEmpty {
					try? await Task.sleep(for: .milliseconds(120))
					if Task.isCancelled { return }
				}
				await load()
			}
	}

	@ViewBuilder
	private var content: some View {
		if unavailable {
			ContentUnavailableView {
				Label("Couldn't open your history", systemImage: "exclamationmark.triangle")
			} description: {
				Text("yap keeps trying. Dictation works in the meantime.")
			}
		} else if entries.isEmpty, !query.isEmpty {
			ContentUnavailableView.search(text: query)
		} else if entries.isEmpty {
			ContentUnavailableView {
				Label("Nothing yet", systemImage: "text.bubble")
			} description: {
				Text("Everything you dictate shows up here for 30 days.")
			}
		} else {
			List(entries) { entry in
				Button {
					copy(entry)
				} label: {
					HistoryRow(entry: entry, copied: copiedID != nil && copiedID == entry.id)
				}
				.buttonStyle(.plain)
			}
		}
	}

	private func load() async {
		do {
			let found = try await dictation.history.search(query, limit: Self.limit)
			if Task.isCancelled { return }
			entries = found
			unavailable = false
		} catch {
			if Task.isCancelled { return }
			entries = []
			unavailable = true
		}
	}

	private func copy(_ entry: HistoryEntry) {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(entry.text, forType: .string)
		copiedID = entry.id
		Task {
			try? await Task.sleep(for: .seconds(1.5))
			if copiedID == entry.id { copiedID = nil }
		}
	}

	private struct Reload: Equatable {
		var query: String
		var revision: Int
	}
}

private struct HistoryRow: View {
	let entry: HistoryEntry
	let copied: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(entry.text)
				.lineLimit(4)
				.frame(maxWidth: .infinity, alignment: .leading)
			HStack(spacing: 6) {
				Text(entry.createdAt, format: .relative(presentation: .named))
				if let app = appName {
					Text("·")
					Text(app)
				}
				Spacer()
				if copied {
					Text("Copied")
						.transition(.opacity)
				}
			}
			.font(.caption)
			.foregroundStyle(.secondary)
		}
		.padding(.vertical, 4)
		// The whole row is the click target, not just the glyphs.
		.contentShape(Rectangle())
		.animation(.easeOut(duration: 0.15), value: copied)
	}

	private var appName: String? {
		guard let bundleID = entry.appBundleID,
		      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
		else { return nil }
		return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
			.replacingOccurrences(of: ".app", with: "")
	}
}
