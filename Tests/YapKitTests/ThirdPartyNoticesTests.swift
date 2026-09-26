import Foundation
import Testing
@testable import YapKit

@Suite struct ThirdPartyNoticesTests {
	@Test func parsesSectionsTablesAndParagraphs() {
		let notices = ThirdPartyNotices(markdown: """
			# Third-party notices

			yap is MIT-licensed (see [LICENSE](LICENSE)).
			It builds on the work below.

			## Libraries (compiled into yap)

			| Project | License | Copyright |
			| --- | --- | --- |
			| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Gwendal Roué |

			## Models

			| Model | Used for | License | Credit |
			| --- | --- | --- | --- |
			| [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | Speech-to-text | CC BY 4.0 | NVIDIA |
			| Plain | | MIT | Someone |

			Apple's framework is covered by Apple's own terms.
			""")

		#expect(notices.intro == ["yap is MIT-licensed (see [LICENSE](LICENSE)). It builds on the work below."])
		#expect(notices.sections.map(\.title) == ["Libraries", "Models"])
		#expect(notices.sections[0].caption == "compiled into yap")
		#expect(notices.sections[1].caption == nil)
		#expect(notices.sections[0].entries == [
			.init(name: "GRDB.swift", url: URL(string: "https://github.com/groue/GRDB.swift"), license: "MIT", credit: "Gwendal Roué", usedFor: nil),
		])
		#expect(notices.sections[1].entries == [
			.init(name: "Parakeet", url: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"), license: "CC BY 4.0", credit: "NVIDIA", usedFor: "Speech-to-text"),
			.init(name: "Plain", url: nil, license: "MIT", credit: "Someone", usedFor: nil),
		])
		#expect(notices.sections[1].paragraphs == ["Apple's framework is covered by Apple's own terms."])
	}

	/// The app renders the repository's file; every row in it must come
	/// through with a link, a license and a credit.
	@Test func readsTheRepositoryFile() throws {
		let url = URL(filePath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appending(path: "THIRD_PARTY_NOTICES.md")
		let markdown = try String(contentsOf: url, encoding: .utf8)
		let rows = markdown.components(separatedBy: .newlines)
			.filter { $0.hasPrefix("| [") }
		let notices = ThirdPartyNotices(markdown: markdown)

		#expect(!rows.isEmpty)
		#expect(notices.entries.count == rows.count)
		for entry in notices.entries {
			#expect(entry.url != nil, "\(entry.name) has no link")
			#expect(!entry.license.isEmpty, "\(entry.name) has no license")
			#expect(!entry.credit.isEmpty, "\(entry.name) has no credit")
		}
	}
}
