import Foundation

/// `THIRD_PARTY_NOTICES.md`, read into sections and entries so the About
/// window can show it without a hand-kept copy of the list in Swift.
///
/// Understands the subset the file uses: `##` section headings, one Markdown
/// table per section whose first column is `[Name](url)`, and plain
/// paragraphs. Columns are found by their header, so reordering them or adding
/// one doesn't break the parse.
public struct ThirdPartyNotices: Sendable, Equatable {
	public struct Section: Sendable, Equatable, Identifiable {
		/// The heading before any parenthesis, e.g. "Libraries".
		public var title: String
		/// The parenthesised rest of the heading, e.g. "compiled into yap".
		public var caption: String?
		public var entries: [Entry]
		/// Paragraphs in the section outside its table, as inline Markdown.
		public var paragraphs: [String]

		public var id: String { title }
	}

	public struct Entry: Sendable, Equatable, Identifiable {
		public var name: String
		public var url: URL?
		public var license: String
		/// Copyright holder or credit line, as inline Markdown.
		public var credit: String
		/// What yap uses it for, when the table says.
		public var usedFor: String?

		public var id: String { name }
	}

	/// Paragraphs before the first section, as inline Markdown.
	public var intro: [String]
	public var sections: [Section]

	public var entries: [Entry] { sections.flatMap(\.entries) }

	public init(markdown: String) {
		var intro: [String] = []
		var sections: [Section] = []
		var paragraph: [String] = []
		var table: [[String]] = []

		func flushParagraph() {
			guard !paragraph.isEmpty else { return }
			let text = paragraph.joined(separator: " ")
			paragraph = []
			if sections.isEmpty {
				intro.append(text)
			} else {
				sections[sections.count - 1].paragraphs.append(text)
			}
		}

		func flushTable() {
			guard !table.isEmpty else { return }
			let rows = table
			table = []
			guard !sections.isEmpty else { return }
			sections[sections.count - 1].entries += Self.entries(fromTable: rows)
		}

		for rawLine in markdown.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("|") {
				flushParagraph()
				table.append(Self.cells(of: line))
				continue
			}
			flushTable()
			if line.isEmpty {
				flushParagraph()
			} else if line.hasPrefix("## ") {
				flushParagraph()
				sections.append(Self.section(heading: String(line.dropFirst(3))))
			} else if line.hasPrefix("#") {
				// The document title; the window has its own.
				flushParagraph()
			} else {
				paragraph.append(line)
			}
		}
		flushTable()
		flushParagraph()

		self.intro = intro
		self.sections = sections
	}

	// MARK: - Parsing

	private static func section(heading: String) -> Section {
		let heading = heading.trimmingCharacters(in: .whitespaces)
		guard let open = heading.firstIndex(of: "("), heading.hasSuffix(")") else {
			return Section(title: heading, caption: nil, entries: [], paragraphs: [])
		}
		let title = heading[..<open].trimmingCharacters(in: .whitespaces)
		let caption = heading[heading.index(after: open)..<heading.index(before: heading.endIndex)]
		return Section(title: title, caption: String(caption), entries: [], paragraphs: [])
	}

	private static func cells(of row: String) -> [String] {
		var cells = row.split(separator: "|", omittingEmptySubsequences: false)
			.map { $0.trimmingCharacters(in: .whitespaces) }
		// A row starts and ends with a pipe: drop the empty edges.
		if cells.first?.isEmpty == true { cells.removeFirst() }
		if cells.last?.isEmpty == true { cells.removeLast() }
		return cells
	}

	private static func entries(fromTable rows: [[String]]) -> [Entry] {
		guard let header = rows.first?.map({ $0.lowercased() }) else { return [] }
		func column(_ names: String...) -> Int? {
			header.firstIndex { cell in names.contains { cell.contains($0) } }
		}
		let license = column("license")
		let credit = column("copyright", "credit")
		let usedFor = column("used for")

		return rows.dropFirst().compactMap { row -> Entry? in
			// The `| --- |` separator under the header.
			if row.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { return nil }
			guard let first = row.first, !first.isEmpty else { return nil }
			func value(_ index: Int?) -> String? {
				guard let index, index < row.count, !row[index].isEmpty else { return nil }
				return row[index]
			}
			let (name, url) = link(in: first)
			return Entry(
				name: name,
				url: url,
				license: value(license) ?? "",
				credit: value(credit) ?? "",
				usedFor: value(usedFor)
			)
		}
	}

	/// `[Name](https://…)` to its parts; anything else is a plain name.
	private static func link(in cell: String) -> (String, URL?) {
		guard cell.hasPrefix("["),
			let close = cell.range(of: "]("),
			cell.hasSuffix(")")
		else { return (cell, nil) }
		let name = String(cell[cell.index(after: cell.startIndex)..<close.lowerBound])
		let target = String(cell[close.upperBound..<cell.index(before: cell.endIndex)])
		return (name, URL(string: target))
	}
}
