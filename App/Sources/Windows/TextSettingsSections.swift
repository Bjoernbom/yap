import AppKit
import SwiftUI
import YapKit

/// Polish on/off. Off by default; greyed out with the reason when Apple
/// Intelligence isn't there.
struct PolishSection: View {
	let text: TextSettingsStore

	var body: some View {
		Section {
			Toggle("Polish with Apple Intelligence", isOn: enabled)
				.disabled(!text.polishAvailability.isAvailable)
		} footer: {
			Group {
				switch text.polishAvailability {
				case .available:
					Text("Smooths false starts and grammar on your Mac. Takes at most a second, or you get the plain text.")
				case .unavailable(let reason):
					Text("Needs Apple Intelligence. \(reason)")
				}
			}
			.foregroundStyle(.secondary)
		}
	}

	private var enabled: Binding<Bool> {
		Binding {
			text.settings.polishEnabled && text.polishAvailability.isAvailable
		} set: {
			text.setPolish($0)
		}
	}
}

/// One row per app you've dictated into lately, plus any app you picked.
struct StylesSection: View {
	let text: TextSettingsStore
	let history: HistoryAccess
	let historyRevision: Int

	/// Enough to cover the apps someone actually talks into.
	private static let recentLimit = 6

	@State private var recent: [String] = []

	var body: some View {
		Section {
			ForEach(bundleIDs, id: \.self) { bundleID in
				StyleRow(text: text, app: AppInfo(bundleID: bundleID))
			}
			addAppMenu
		} header: {
			Text("Styles")
		} footer: {
			Text("yap writes casual in chat, proper in mail and docs, and leaves code alone in editors.")
				.foregroundStyle(.secondary)
		}
		.task(id: historyRevision) { await loadRecent() }
	}

	private var bundleIDs: [String] {
		let chosen = text.settings.styleOverrides.keys.sorted { AppInfo.name(for: $0) < AppInfo.name(for: $1) }
		return recent + chosen.filter { !recent.contains($0) }
	}

	private var addAppMenu: some View {
		let listed = Set(bundleIDs)
		let running = NSWorkspace.shared.runningApplications
			.filter { $0.activationPolicy == .regular }
			.compactMap(\.bundleIdentifier)
			.filter { !listed.contains($0) && $0 != Bundle.main.bundleIdentifier }
		let apps = Set(running).map(AppInfo.init).sorted { $0.name < $1.name }
		return Menu("Set a style for another app") {
			ForEach(apps, id: \.bundleID) { app in
				Menu(app.name) {
					ForEach(WritingStyle.allCases, id: \.self) { style in
						Button(style.displayName) { text.setStyle(style, for: app.bundleID) }
					}
				}
			}
		}
		.disabled(apps.isEmpty)
	}

	private func loadRecent() async {
		guard let entries = try? await history.recent(limit: 200) else { return }
		var seen = Set<String>()
		recent = entries
			.compactMap(\.appBundleID)
			.filter { $0 != Bundle.main.bundleIdentifier && seen.insert($0).inserted }
			.prefix(Self.recentLimit)
			.map { $0 }
	}
}

private struct StyleRow: View {
	let text: TextSettingsStore
	let app: AppInfo

	var body: some View {
		Picker(selection: style) {
			Text("Auto (\(AppContext.automaticStyle(for: app.bundleID).displayName))").tag(WritingStyle?.none)
			Divider()
			ForEach(WritingStyle.allCases, id: \.self) { style in
				Text(style.displayName).tag(WritingStyle?.some(style))
			}
		} label: {
			Label {
				Text(app.name)
			} icon: {
				Image(nsImage: app.icon)
			}
		}
	}

	private var style: Binding<WritingStyle?> {
		Binding { text.style(for: app.bundleID) } set: { text.setStyle($0, for: app.bundleID) }
	}
}

/// Your words: terms yap spells your way, and replacements.
struct DictionarySection: View {
	let text: TextSettingsStore

	@State private var written = ""
	@State private var spoken = ""
	@FocusState private var focusedField: Field?

	private enum Field { case written, spoken }

	var body: some View {
		Section {
			ForEach(text.settings.dictionary) { entry in
				HStack {
					if entry.isTerm {
						Text(entry.written)
					} else {
						Text(entry.spoken).foregroundStyle(.secondary)
						Image(systemName: "arrow.right")
							.foregroundStyle(.tertiary)
							.accessibilityLabel("becomes")
						Text(entry.written)
					}
					Spacer()
					Button {
						text.removeEntry(entry.id)
					} label: {
						Image(systemName: "minus.circle")
					}
					.buttonStyle(.borderless)
					.accessibilityLabel("Remove \(entry.written)")
				}
			}
			HStack {
				TextField("Word", text: $written, prompt: Text("Word, like Kubernetes"))
					.focused($focusedField, equals: .written)
				TextField("Said as", text: $spoken, prompt: Text("Said as (optional)"))
					.focused($focusedField, equals: .spoken)
				Button("Add", action: add)
					.disabled(written.trimmingCharacters(in: .whitespaces).isEmpty)
			}
			.labelsHidden()
			.onSubmit(add)
		} header: {
			Text("Dictionary")
		} footer: {
			Text("yap spells these your way. Add how you say it to replace it, like “yap dot app” → yap.app.")
				.foregroundStyle(.secondary)
		}
	}

	private func add() {
		guard !written.trimmingCharacters(in: .whitespaces).isEmpty else { return }
		text.addEntry(written: written, spoken: spoken)
		written = ""
		spoken = ""
		focusedField = .written
	}
}

/// Name and icon for a bundle id, even when the app isn't running.
private struct AppInfo {
	let bundleID: String
	let name: String
	let icon: NSImage

	init(bundleID: String) {
		self.bundleID = bundleID
		let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
		name = Self.name(for: bundleID)
		let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
		icon.size = NSSize(width: 16, height: 16)
		self.icon = icon
	}

	static func name(for bundleID: String) -> String {
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
		let name = FileManager.default.displayName(atPath: url.path)
		return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
	}
}
