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
			.onReceive(DistributedNotificationCenter.default().publisher(for: Self.captureNotification)) { _ in
				captureWindows()
			}
	}

	/// Writes every visible titled window to `-YapCaptureDir`, since
	/// `screencapture` needs Screen Recording permission.
	static let captureNotification = Notification.Name("com.bjornbom.yap.debug.captureWindows")

	private func captureWindows() {
		guard let directory = UserDefaults.standard.string(forKey: "YapCaptureDir").map({ URL(filePath: $0) }) else { return }
		for window in NSApp.windows where window.isVisible && !window.title.isEmpty {
			// The frame view includes the title bar and toolbar.
			guard let view = window.contentView?.superview ?? window.contentView else { continue }
			let slug = window.title.lowercased().replacingOccurrences(of: " ", with: "-")
			PanelCapture.write(view, to: directory.appending(path: "window-\(slug).png"))
		}
	}
}
#endif
