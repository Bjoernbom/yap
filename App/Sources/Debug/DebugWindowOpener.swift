#if DEBUG
import SwiftUI

/// Opens History and Settings at launch when `-YapOpenWindows YES` is set,
/// so they can be checked without clicking the menu, and the Try it window
/// on the distributed notification `com.bjornbom.yap.debug.tryIt`, so a
/// verification script can move focus into yap. Attached to the menu bar
/// label, the one view that is always alive.
struct DebugWindowOpener: ViewModifier {
	static let tryItNotification = Notification.Name("com.bjornbom.yap.debug.tryIt")

	@Environment(\.openWindow) private var openWindow
	@Environment(\.openSettings) private var openSettings

	func body(content: Content) -> some View {
		content
			.task {
				guard UserDefaults.standard.bool(forKey: "YapOpenWindows") else { return }
				try? await Task.sleep(for: .milliseconds(500))
				NSApp.activate()
				openWindow(id: WindowID.history)
				openSettings()
			}
			.onReceive(DistributedNotificationCenter.default().publisher(for: Self.tryItNotification)) { _ in
				NSApp.activate()
				openWindow(id: WindowID.tryIt)
			}
	}
}
#endif
