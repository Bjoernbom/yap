import Foundation

/// Where a note ended up.
public struct WrittenNote: Sendable, Equatable {
	public var url: URL
	public var markdown: String
	/// Set when the notes folder couldn't be written and the note went to
	/// the fallback folder instead; the line to show the user.
	public var fallbackNotice: String?
}

/// Writes a note as a plain Markdown file that works in Obsidian, iCloud or
/// git: `<folder>/<yyyy-MM-dd> <Title>.md`.
public struct MarkdownWriter: Sendable {
	/// `~/Documents/yap`, the plan's default.
	public static var defaultFolder: URL {
		URL.documentsDirectory.appending(path: "yap", directoryHint: .isDirectory)
	}

	/// Where notes go when the chosen folder can't be written (deleted
	/// volume, no permission). Always writable, never the user's pick.
	public static var defaultFallbackFolder: URL {
		URL.applicationSupportDirectory.appending(path: "yap/Notes", directoryHint: .isDirectory)
	}

	/// Keeps titles readable in Finder and inside every file system's limit.
	static let maxTitleLength = 80

	public var folder: URL
	public var fallbackFolder: URL
	public var timeZone: TimeZone

	public init(folder: URL = defaultFolder, fallbackFolder: URL = defaultFallbackFolder, timeZone: TimeZone = .current) {
		self.folder = folder
		self.fallbackFolder = fallbackFolder
		self.timeZone = timeZone
	}

	/// Writes the note, never replacing an existing file ("… 2.md" instead).
	public func write(_ note: Note) throws -> WrittenNote {
		let markdown = render(note)
		let name = baseName(for: note)
		do {
			return WrittenNote(url: try Self.writeNew(markdown, named: name, in: folder), markdown: markdown)
		} catch {
			let url = try Self.writeNew(markdown, named: name, in: fallbackFolder)
			return WrittenNote(
				url: url, markdown: markdown,
				fallbackNotice: "Couldn't write to \(folder.lastPathComponent). Saved in \(fallbackFolder.path) instead.")
		}
	}

	/// The note's title: the summary's, or "Meeting 14.05" without one.
	public func title(for note: Note) -> String {
		if let title = note.summary?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
			return title
		}
		return "Meeting \(format(note.startedAt, "HH.mm"))"
	}

	public func baseName(for note: Note) -> String {
		"\(format(note.startedAt, "yyyy-MM-dd")) \(Self.safeFileName(title(for: note)))"
	}

	public func render(_ note: Note) -> String {
		var lines: [String] = []
		lines.append("---")
		lines.append("date: \(format(note.startedAt, "yyyy-MM-dd'T'HH:mm:ssxxx"))")
		lines.append("duration: \(Self.clock(note.duration))")
		lines.append("apps: [\(note.apps.map(Self.yamlString).joined(separator: ", "))]")
		lines.append("---")
		lines.append("")
		lines.append("# \(title(for: note))")
		lines.append("")
		for notice in note.notices {
			lines.append("> \(notice)")
		}
		if !note.notices.isEmpty { lines.append("") }

		if let summary = note.summary {
			lines.append("## Summary")
			lines.append("")
			lines.append(summary.summary.trimmingCharacters(in: .whitespacesAndNewlines))
			lines.append("")
			if !summary.decisions.isEmpty {
				lines.append("## Decisions")
				lines.append("")
				lines += summary.decisions.map { "- \($0)" }
				lines.append("")
			}
			if !summary.actionItems.isEmpty {
				lines.append("## Action items")
				lines.append("")
				lines += summary.actionItems.map { item in
					"- [ ] \(item.task)" + (item.owner.map { " (\($0))" } ?? "")
				}
				lines.append("")
			}
		}

		lines.append("## Transcript")
		lines.append("")
		for paragraph in TranscriptMerger.merge(note.segments) {
			lines.append("**\(paragraph.speaker.label)** [\(Self.clock(paragraph.start))] \(paragraph.text)")
			lines.append("")
		}
		return lines.joined(separator: "\n")
	}

	// MARK: - Helpers

	/// `mm:ss`, or `h:mm:ss` from an hour on.
	static func clock(_ seconds: Double) -> String {
		let total = max(0, Int(seconds.rounded(.down)))
		let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
		let two = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
		return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(two(minutes)):\(two(rest))"
	}

	/// A title made safe as a file name on APFS, exFAT/SMB shares and in
	/// Obsidian links: no path separators, no characters Windows or
	/// Obsidian reject, no leading dot (hidden file), bounded length.
	static func safeFileName(_ title: String) -> String {
		let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters).union(.newlines)
		let replaced = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
		var cleaned = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
		while let first = cleaned.first, first == "." || first == " " { cleaned.removeFirst() }
		while let last = cleaned.last, last == "." || last == " " { cleaned.removeLast() }
		if cleaned.count > maxTitleLength {
			cleaned = String(cleaned.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
		}
		return cleaned.isEmpty ? "Meeting" : cleaned
	}

	private static func yamlString(_ value: String) -> String {
		let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
		return "\"\(escaped)\""
	}

	/// Creates `<name>.md`, or `<name> 2.md`, `<name> 3.md`… Atomic and
	/// exclusive: `.withoutOverwriting` fails instead of replacing a file
	/// that appeared a moment ago (another yap, iCloud sync).
	static func writeNew(_ markdown: String, named name: String, in folder: URL) throws -> URL {
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let data = Data(markdown.utf8)
		for attempt in 1...1_000 {
			let file = attempt == 1 ? "\(name).md" : "\(name) \(attempt).md"
			let url = folder.appending(path: file, directoryHint: .notDirectory)
			do {
				try data.write(to: url, options: .withoutOverwriting)
				return url
			} catch CocoaError.fileWriteFileExists {
				continue
			}
		}
		throw CocoaError(.fileWriteFileExists)
	}

	private func format(_ date: Date, _ pattern: String) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = timeZone
		formatter.dateFormat = pattern
		return formatter.string(from: date)
	}
}
