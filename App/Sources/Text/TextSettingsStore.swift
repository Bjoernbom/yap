import Foundation
import Observation
import OSLog
import YapKit

/// The user's text settings (polish, styles per app, dictionary), saved as
/// JSON next to the history and pushed into the pipeline on every change.
@MainActor
@Observable
final class TextSettingsStore {
	let pipeline: TextPipeline
	private(set) var settings: TextSettings
	private(set) var polishAvailability: PolishAvailability

	@ObservationIgnored private let url: URL?
	/// The file on disk didn't decode. It is set aside before the first save
	/// so a bug can't silently wipe someone's dictionary.
	@ObservationIgnored private var unreadableFile = false

	init() {
		var url = Self.defaultURL()
		#if DEBUG
		// Verification runs against a scratch file, not the user's settings.
		if let path = UserDefaults.standard.string(forKey: "YapTextSettingsPath") {
			url = URL(filePath: path)
		}
		#endif
		self.url = url
		var settings = TextSettings()
		if let url, FileManager.default.fileExists(atPath: url.path) {
			do {
				settings = try JSONDecoder().decode(TextSettings.self, from: Data(contentsOf: url))
			} catch {
				unreadableFile = true
				Logger.text.error("Couldn't read text settings: \(error, privacy: .public)")
			}
		}
		self.settings = settings
		pipeline = TextPipeline(settings: settings)
		polishAvailability = pipeline.polishAvailability
	}

	/// `~/Library/Application Support/yap/text-settings.json`.
	private static func defaultURL() -> URL? {
		guard let support = try? FileManager.default.url(
			for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
		) else { return nil }
		return support.appending(path: "yap/text-settings.json", directoryHint: .notDirectory)
	}

	/// Apple Intelligence can be turned on or finish downloading while yap runs.
	func refreshAvailability() {
		polishAvailability = pipeline.polishAvailability
	}

	func setPolish(_ enabled: Bool) {
		change { $0.polishEnabled = enabled }
	}

	func style(for bundleID: String) -> WritingStyle? {
		settings.styleOverrides[bundleID]
	}

	/// nil goes back to yap's own guess.
	func setStyle(_ style: WritingStyle?, for bundleID: String) {
		change { $0.styleOverrides[bundleID] = style }
	}

	func addEntry(written: String, spoken: String) {
		let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
		let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !written.isEmpty else { return }
		change { settings in
			settings.dictionary.removeAll { $0.written == written && $0.spoken.caseInsensitiveCompare(spoken) == .orderedSame }
			settings.dictionary.append(DictionaryEntry(spoken: spoken, written: written))
		}
	}

	func removeEntry(_ id: DictionaryEntry.ID) {
		change { $0.dictionary.removeAll { $0.id == id } }
	}

	private func change(_ edit: (inout TextSettings) -> Void) {
		var updated = settings
		edit(&updated)
		guard updated != settings else { return }
		settings = updated
		pipeline.update(updated)
		save()
	}

	private func save() {
		guard let url else { return }
		do {
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			if unreadableFile {
				let aside = url.appendingPathExtension("unreadable")
				try? FileManager.default.removeItem(at: aside)
				try? FileManager.default.moveItem(at: url, to: aside)
				unreadableFile = false
			}
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			try encoder.encode(settings).write(to: url, options: .atomic)
		} catch {
			Logger.text.error("Couldn't save text settings: \(error, privacy: .public)")
		}
	}
}

extension WritingStyle {
	/// How the style is named in Settings.
	var displayName: String {
		switch self {
		case .natural: "Natural"
		case .casual: "Casual"
		case .proper: "Proper"
		case .dev: "Code"
		}
	}
}

extension Logger {
	static let text = Logger(subsystem: "com.bjornbom.yap", category: "text")
}
