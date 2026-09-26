import Foundation

/// The app behind a process that is recording from the mic, as far as call
/// detection can tell from its bundle id and executable path.
public enum CallApp: Sendable, Hashable {
	case zoom
	case teams
	case slack
	case faceTime
	case webex
	case discord
	case around
	case whereby
	/// A browser is using the mic: maybe Google Meet, Whereby or another web
	/// call, maybe just a dictation site. The associated value is its name.
	case browser(String)
	/// Something else is recording (a voice recorder, a dev tool). Reported so
	/// callers can decide; the notch only offers notes for call apps.
	case other(String)

	public var name: String {
		switch self {
		case .zoom: "Zoom"
		case .teams: "Microsoft Teams"
		case .slack: "Slack"
		case .faceTime: "FaceTime"
		case .webex: "Webex"
		case .discord: "Discord"
		case .around: "Around"
		case .whereby: "Whereby"
		case .browser(let name), .other(let name): name
		}
	}

	/// A dedicated call app: using the mic almost certainly means a call.
	public var isCallApp: Bool {
		switch self {
		case .browser, .other: false
		default: true
		}
	}

	/// Worth offering notes for: a call app, or a browser that might host one.
	public var mightBeCall: Bool {
		if case .other = self { return false }
		return true
	}

	/// Which app to name when several record at once: a call app beats a
	/// browser beats anything else.
	var rank: Int {
		switch self {
		case .other: 0
		case .browser: 1
		default: 2
		}
	}

	// MARK: Identification

	/// Bundle id prefixes, matched on dot boundaries so helpers
	/// (`com.google.Chrome.helper`, `us.zoom.CptHost`) map to their app.
	static let known: [(prefix: String, app: CallApp)] = [
		("us.zoom", .zoom),
		("com.microsoft.teams", .teams),
		("com.microsoft.teams2", .teams),
		("com.tinyspeck.slackmacgap", .slack),
		("com.apple.FaceTime", .faceTime),
		// FaceTime's audio runs in this daemon, not in the FaceTime app.
		("com.apple.avconferenced", .faceTime),
		("com.cisco.webexmeetingsapp", .webex),
		("com.webex.meetingmanager", .webex),
		("Cisco-Systems.Spark", .webex),
		("com.hnc.Discord", .discord),
		("co.teamport.around", .around),
		("com.whereby", .whereby),
		("com.google.Chrome", .browser("Chrome")),
		("com.apple.Safari", .browser("Safari")),
		// Safari's WebRTC audio runs in the shared WebKit GPU process.
		("com.apple.WebKit.GPU", .browser("Safari")),
		("company.thebrowser.Browser", .browser("Arc")),
		("com.microsoft.edgemac", .browser("Edge")),
		("com.brave.Browser", .browser("Brave")),
		("org.mozilla.firefox", .browser("Firefox")),
		("com.vivaldi.Vivaldi", .browser("Vivaldi")),
		("com.operasoftware.Opera", .browser("Opera")),
	]

	/// Maps a bundle id to a known app, or nil. Bundle ids are case-insensitive.
	public static func known(bundleID: String) -> CallApp? {
		let id = bundleID.lowercased()
		guard !id.isEmpty else { return nil }
		var best: (length: Int, app: CallApp)?
		for (prefix, app) in known {
			let p = prefix.lowercased()
			guard id == p || id.hasPrefix(p + "."), p.count > (best?.length ?? 0) else { continue }
			best = (p.count, app)
		}
		return best?.app
	}

	/// Identifies a recording process. Tries its own bundle id, then the
	/// outermost `.app` in its path (helpers live inside their app's bundle),
	/// whose bundle id `bundleIDOfApp` looks up. Falls back to `.other` named
	/// after that app or the executable.
	public static func identify(
		bundleID: String,
		executablePath: String?,
		bundleIDOfApp: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }
	) -> CallApp {
		if let app = known(bundleID: bundleID) { return app }
		let outer = executablePath.flatMap(outermostAppPath)
		if let outer, let outerID = bundleIDOfApp(outer), let app = known(bundleID: outerID) { return app }
		if let outer { return .other((outer as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) }
		if let executablePath { return .other((executablePath as NSString).lastPathComponent) }
		return .other(bundleID.isEmpty ? "Unknown app" : bundleID)
	}

	/// `/Applications/Foo.app/Contents/Frameworks/Bar Helper.app/…` → `/Applications/Foo.app`.
	static func outermostAppPath(in path: String) -> String? {
		var components: [String] = []
		for component in path.split(separator: "/", omittingEmptySubsequences: false) {
			components.append(String(component))
			if component.hasSuffix(".app") { return components.joined(separator: "/") }
		}
		return nil
	}
}
