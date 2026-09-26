import SwiftUI
import YapKit

/// Every library and model yap builds on, read from the bundled
/// `THIRD_PARTY_NOTICES.md`, then the full license texts. The file is the one
/// source of truth: nothing here names a dependency.
struct AcknowledgementsView: View {
	@State private var notices: ThirdPartyNotices? = Self.loadNotices()

	var body: some View {
		Group {
			if let notices {
				ScrollView {
					VStack(alignment: .leading, spacing: 28) {
						ForEach(notices.intro, id: \.self) { paragraph in
							InlineMarkdown(paragraph)
								.foregroundStyle(.secondary)
						}
						ForEach(notices.sections) { section in
							NoticesSection(section: section)
						}
						LicenseTexts()
					}
					.padding(28)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
			} else {
				MissingDocument(document: .notices, title: "Acknowledgements aren't here")
			}
		}
		.frame(minWidth: 460, idealWidth: 540, minHeight: 360, idealHeight: 620)
		// Relative links in the notices point into the repository.
		.environment(\.openURL, OpenURLAction { url in .systemAction(url.absoluteURL) })
		#if DEBUG
		.debugAppearance()
		#endif
	}

	private static func loadNotices() -> ThirdPartyNotices? {
		guard let markdown = BundledDocument.notices.load() else { return nil }
		let notices = ThirdPartyNotices(markdown: markdown)
		return notices.entries.isEmpty ? nil : notices
	}
}

private struct NoticesSection: View {
	let section: ThirdPartyNotices.Section

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text(section.title)
					.font(.headline)
					.accessibilityAddTraits(.isHeader)
				if let caption = section.caption {
					Text(caption.prefix(1).uppercased() + caption.dropFirst())
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
			}

			VStack(spacing: 0) {
				ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
					if index > 0 { Divider() }
					EntryRow(entry: entry)
				}
			}
			.padding(.horizontal, 14)
			.background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))

			ForEach(section.paragraphs, id: \.self) { paragraph in
				InlineMarkdown(paragraph)
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
	}
}

private struct EntryRow: View {
	let entry: ThirdPartyNotices.Entry

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				if let url = entry.url {
					Link(entry.name, destination: url)
						.fontWeight(.semibold)
						.help(url.absoluteString)
				} else {
					Text(entry.name).fontWeight(.semibold)
				}
				Spacer(minLength: 0)
				Text(entry.license)
					.font(.caption)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.trailing)
					.accessibilityLabel("License: \(entry.license)")
			}
			if let usedFor = entry.usedFor {
				Text(usedFor)
					.font(.callout)
			}
			InlineMarkdown(entry.credit)
				.font(.callout)
				.foregroundStyle(.secondary)
		}
		.padding(.vertical, 11)
		.frame(maxWidth: .infinity, alignment: .leading)
		.accessibilityElement(children: .contain)
	}
}

/// yap's own license and the bundled font's, in full.
private struct LicenseTexts: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("License texts")
				.font(.headline)
				.accessibilityAddTraits(.isHeader)
			LicenseText(title: "yap (MIT)", document: .license)
			LicenseText(title: "Pixelify Sans (SIL Open Font License 1.1)", document: .fontLicense)
		}
	}
}

private struct LicenseText: View {
	let title: String
	let document: BundledDocument
	@State private var isExpanded = false

	var body: some View {
		DisclosureGroup(title, isExpanded: $isExpanded) {
			Group {
				if let text = document.load() {
					Text(text)
						.font(.system(.caption, design: .monospaced))
						.textSelection(.enabled)
				} else {
					HStack(spacing: 4) {
						Text("Couldn't find \(document.rawValue) in this copy of yap.")
						Link("Read it on GitHub", destination: document.onlineURL)
					}
					.font(.callout)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.top, 6)
		}
	}
}

/// What shows when a bundled file is gone: say so, and where to read it.
private struct MissingDocument: View {
	let document: BundledDocument
	let title: String

	var body: some View {
		ContentUnavailableView {
			Label(title, systemImage: "doc.questionmark")
		} description: {
			Text("This copy of yap is missing \(document.rawValue). The same list is on GitHub.")
		} actions: {
			Link("Open on GitHub", destination: document.onlineURL)
		}
	}
}

/// One paragraph of inline Markdown (links, code), as in the notices file.
private struct InlineMarkdown: View {
	let markdown: String

	init(_ markdown: String) {
		self.markdown = markdown
	}

	var body: some View {
		Text(attributed)
			.fixedSize(horizontal: false, vertical: true)
			.textSelection(.enabled)
	}

	private var attributed: AttributedString {
		let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
		return (try? AttributedString(markdown: markdown, options: options, baseURL: AboutLinks.repositoryFiles))
			?? AttributedString(markdown)
	}
}
