import Foundation
import OSLog

/// The text files copied from the repository root into the app's Resources
/// (see `project.yml`), so About shows exactly what the repository says.
enum BundledDocument: String, CaseIterable {
	case license = "LICENSE"
	case notices = "THIRD_PARTY_NOTICES.md"
	case fontLicense = "OFL.txt"

	/// Where the same file lives online, for when this copy of yap lacks it.
	var onlineURL: URL {
		switch self {
		case .license, .notices: AboutLinks.repository.appending(path: "blob/main/\(rawValue)")
		case .fontLicense: AboutLinks.repository.appending(path: "blob/main/App/Resources/Fonts/OFL.txt")
		}
	}

	/// The file's text, or nil if it's missing or unreadable.
	func load(from bundle: Bundle = .main) -> String? {
		let name = (rawValue as NSString).deletingPathExtension
		let ext = (rawValue as NSString).pathExtension
		guard let url = bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) else {
			Logger.about.error("\(rawValue, privacy: .public) is missing from the bundle")
			return nil
		}
		do {
			return try String(contentsOf: url, encoding: .utf8)
		} catch {
			Logger.about.error("Could not read \(rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}
}

enum AboutLinks {
	static let repository = URL(literal: "https://github.com/Bjoernbom/yap")
	static let author = URL(literal: "https://github.com/Bjoernbom")
	/// Relative links in the notices (`[LICENSE](LICENSE)`) resolve against this.
	static let repositoryFiles = repository.appending(path: "blob/main/")
}

private extension URL {
	/// A URL written out in source. `URL(string:)` fails only on malformed
	/// text, which is a typo to catch in the first run, not a runtime state.
	init(literal: StaticString) {
		guard let url = URL(string: "\(literal)") else { preconditionFailure("Malformed URL literal: \(literal)") }
		self = url
	}
}

extension Logger {
	static let about = Logger(subsystem: "com.bjornbom.yap", category: "about")
}
