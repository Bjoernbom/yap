import SwiftUI

/// Opens onboarding on first launch. Attached to the menu bar label, the one
/// view that is alive from launch, since a menu bar app has no main window.
struct OnboardingOpener: ViewModifier {
	let onboarding: OnboardingModel
	@Environment(\.openWindow) private var openWindow

	#if DEBUG
	/// `com.bjornbom.yap.debug.onboarding.<pid>`: what "Set up yap…" does,
	/// for one yap process, so a script can reopen it without the menu.
	static let reopenThisProcess = Notification.Name("com.bjornbom.yap.debug.onboarding.\(getpid())")
	static let grantAccessibilityThisProcess = Notification.Name("com.bjornbom.yap.debug.grantAccessibility.\(getpid())")
	#endif

	func body(content: Content) -> some View {
		content
			.task {
				guard onboarding.shouldShowAtLaunch else { return }
				// Let the status item settle first, or the window opens behind.
				try? await Task.sleep(for: .milliseconds(300))
				OnboardingOpener.open(onboarding, restart: false, with: openWindow)
			}
		#if DEBUG
			.onReceive(DistributedNotificationCenter.default().publisher(for: Self.reopenThisProcess)) { _ in
				OnboardingOpener.open(onboarding, restart: true, with: openWindow)
			}
			.onReceive(DistributedNotificationCenter.default().publisher(for: Self.grantAccessibilityThisProcess)) { _ in
				Permissions.simulatesNoAccessibility = false
				onboarding.dictation.checkPermissions()
			}
		#endif
	}

	/// Also the menu's "Set up yap…".
	@MainActor
	static func open(_ onboarding: OnboardingModel, restart: Bool, with openWindow: OpenWindowAction) {
		if restart {
			onboarding.restart()
		}
		// A menu bar app is never active on its own; the window would open behind.
		NSApp.activate()
		openWindow(id: WindowID.onboarding)
	}
}
