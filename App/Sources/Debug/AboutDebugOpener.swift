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
