/// How dictated text should read in the app it lands in.
public enum WritingStyle: String, Codable, Sendable, CaseIterable {
	/// Anything yap doesn't know: keep what was said, normal punctuation.
	case natural
	/// Chat: short, relaxed, no trailing period on a one-liner.
	case casual
	/// Mail and documents: full sentences, full punctuation.
	case proper
	/// Editors and terminals: identifiers intact, no trailing period.
	case dev
}

/// Picks the writing style from the app that had focus at key-down, so the
/// user never has to (plan section 5: zero configuration, override per app).
public struct AppContext: Sendable, Equatable {
	/// Per-app choices by bundle id; they win over the built-in guess.
	public var overrides: [String: WritingStyle]

	public init(overrides: [String: WritingStyle] = [:]) {
		self.overrides = overrides
	}

	public func style(for bundleID: String?) -> WritingStyle {
		guard let bundleID else { return .natural }
		return overrides[bundleID] ?? Self.automaticStyle(for: bundleID)
	}

	/// The built-in guess. Web apps (Google Docs, Slack in a browser) share
	/// the browser's bundle id and can't be told apart, so browsers stay natural.
	public static func automaticStyle(for bundleID: String?) -> WritingStyle {
		guard let bundleID else { return .natural }
		if let style = known[bundleID] { return style }
		// Every JetBrains IDE has its own id under one prefix.
		if bundleID.hasPrefix("com.jetbrains.") { return .dev }
		return .natural
	}

	static let known: [String: WritingStyle] = {
		var styles: [String: WritingStyle] = [:]
		for id in casualApps { styles[id] = .casual }
		for id in properApps { styles[id] = .proper }
		for id in devApps { styles[id] = .dev }
		return styles
	}()

	static let casualApps = [
		"com.tinyspeck.slackmacgap",
		"com.apple.MobileSMS",
		"net.whatsapp.WhatsApp",
		"desktop.WhatsApp",
		"com.hnc.Discord",
		"com.microsoft.teams2",
		"com.microsoft.teams",
		"ru.keepcoder.Telegram",
		"org.telegram.desktop",
		"org.whispersystems.signal-desktop",
		"com.facebook.archon",
	]

	static let properApps = [
		"com.apple.mail",
		"com.microsoft.Outlook",
		"com.apple.Notes",
		"com.apple.iWork.Pages",
		"com.microsoft.Word",
		"com.readdle.smartemail-Mac",
		"notion.id",
	]

	static let devApps = [
		"com.apple.dt.Xcode",
		"com.microsoft.VSCode",
		"com.microsoft.VSCodeInsiders",
		"com.todesktop.230313mzl4w4u92", // Cursor
		"com.exafunction.windsurf",
		"dev.zed.Zed",
		"dev.zed.Zed-Preview",
		"com.google.android.studio",
		"com.sublimetext.4",
		"com.panic.Nova",
		"com.apple.Terminal",
		"com.googlecode.iterm2",
		"com.mitchellh.ghostty",
		"dev.warp.Warp-Stable",
	]
}
