import AppKit
import SwiftUI

/// "About yap": icon, wordmark, version, who made it, and the way to the
/// licenses. Small and still, like the system's own About panels.
struct AboutView: View {
	@Environment(\.openURL) private var openURL
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		VStack(spacing: 0) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.interpolation(.high)
				.frame(width: 112, height: 112)
				.accessibilityHidden(true)

			Text("yap")
				.font(BrandFont.pixel(48))
				.padding(.top, 6)
				.accessibilityLabel("yap")
				.accessibilityAddTraits(.isHeader)

			Text(Self.version.display)
				.font(BrandFont.pixel(14, weight: .regular))
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
				.accessibilityLabel(Self.version.spoken)

			Text("talk. it types.")
				.font(.title3.weight(.semibold))
				.padding(.top, 14)

			Text(Self.madeBy)
				.foregroundStyle(.secondary)
				.padding(.top, 2)

			HStack(spacing: 8) {
				Button("Source code") { openURL(AboutLinks.repository) }
				Button("MIT license") { openURL(BundledDocument.license.onlineURL) }
			}
			.controlSize(.small)
			.padding(.top, 20)

			Button("Acknowledgements") {
				NSApp.activate()
				openWindow(id: WindowID.acknowledgements)
			}
			.buttonStyle(.link)
			.padding(.top, 12)
		}
		.padding(.horizontal, 40)
		.padding(.top, 28)
		.padding(.bottom, 24)
		.frame(width: 320)
		.fixedSize(horizontal: false, vertical: true)
		#if DEBUG
		.debugAppearance()
		#endif
	}

	private static var madeBy: AttributedString {
		var name = AttributedString("bjornbom")
		name.link = AboutLinks.author
		return AttributedString("made by ") + name
	}

	private struct Version {
		var display: String
		var spoken: String
	}

	private static var version: Version {
		let info = Bundle.main.infoDictionary ?? [:]
		let short = info["CFBundleShortVersionString"] as? String ?? "?"
		let build = info["CFBundleVersion"] as? String ?? "?"
		return Version(display: "\(short) (\(build))", spoken: "Version \(short), build \(build)")
	}
}
