#if DEBUG
import SwiftUI

/// Opens About and Acknowledgements on distributed notifications, so a
/// verification script can reach them without clicking the menu bar menu:
/// `com.bjornbom.yap.debug.about.<pid>` and
/// `com.bjornbom.yap.debug.acknowledgements.<pid>`. Per process only, so the
/// user's own yap never reacts. Attached to the menu bar label.
struct AboutDebugOpener: ViewModifier {
	static let aboutThisProcess = Notification.Name("com.bjornbom.yap.debug.about.\(getpid())")
	static let acknowledgementsThisProcess = Notification.Name("com.bjornbom.yap.debug.acknowledgements.\(getpid())")
	/// Renders the whole acknowledgements list, not just what the window
	/// scrolls to, into `-YapCaptureDir` as `acknowledgements-full-<scheme>.png`.
	static let renderAcknowledgementsThisProcess = Notification.Name("com.bjornbom.yap.debug.acknowledgements.render.\(getpid())")

	@Environment(\.openWindow) private var openWindow

	func body(content: Content) -> some View {
		content
			.onReceive(DistributedNotificationCenter.default().publisher(for: Self.aboutThisProcess)) { _ in
				NSApp.activate()
				openWindow(id: WindowID.about)
			}
			.onReceive(DistributedNotificationCenter.default().publisher(for: Self.acknowledgementsThisProcess)) { _ in
				NSApp.activate()
				openWindow(id: WindowID.acknowledgements)
			}
			.onReceive(DistributedNotificationCenter.default().publisher(for: Self.renderAcknowledgementsThisProcess)) { _ in
				renderAcknowledgements()
			}
	}

	private func renderAcknowledgements() {
		guard let directory = UserDefaults.standard.string(forKey: "YapCaptureDir").map({ URL(filePath: $0) }) else { return }
		let notices = AcknowledgementsView.loadNotices()
		for scheme in [ColorScheme.light, .dark] {
			let content = Group {
				if let notices {
					AcknowledgementsContent(notices: notices)
				} else {
					Text("Notices missing")
				}
			}
			.frame(width: 540)
			.background(Color(nsColor: .windowBackgroundColor))
			.environment(\.colorScheme, scheme)
			let renderer = ImageRenderer(content: content)
			renderer.scale = 2
			guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
				let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
			else { continue }
			try? png.write(to: directory.appending(path: "acknowledgements-full-\(scheme == .light ? "light" : "dark").png"))
		}
	}
}

extension View {
	/// `-YapAppearance light|dark`, to capture both without touching the system.
	func debugAppearance() -> some View {
		let scheme: ColorScheme? = switch UserDefaults.standard.string(forKey: "YapAppearance") {
		case "light": .light
		case "dark": .dark
		default: nil
		}
		return preferredColorScheme(scheme)
	}
}
#endif
