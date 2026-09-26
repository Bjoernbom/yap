import Foundation
import Observation
import Sparkle

/// Sparkle 2. The schedule lives in Info.plist (project.yml): a daily check,
/// silent download, install when yap quits. Downloads made by Sparkle carry no
/// quarantine flag, so an update never meets Gatekeeper.
@MainActor
@Observable
final class AppUpdater {
	/// Off in Debug builds, whose build number is 1: any release would replace
	/// the dev build in `build/`. Off without an EdDSA public key too (local
	/// dry-run builds), where Sparkle would greet the user with a fatal-error alert.
	let isEnabled: Bool
	private(set) var canCheckForUpdates = false

	@ObservationIgnored private let controller: SPUStandardUpdaterController
	@ObservationIgnored private let reminders: GentleReminders
	@ObservationIgnored private var observation: NSKeyValueObservation?

	init() {
		#if DEBUG
		isEnabled = false
		#else
		let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
		isEnabled = !key.isEmpty
		#endif
		let reminders = GentleReminders()
		self.reminders = reminders
		controller = SPUStandardUpdaterController(
			startingUpdater: isEnabled,
			updaterDelegate: nil,
			userDriverDelegate: reminders
		)
		// SPUUpdater lives on the main actor and changes this property there,
		// so KVO calls back on the main thread.
		observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
			MainActor.assumeIsolated {
				self?.canCheckForUpdates = updater.canCheckForUpdates
			}
		}
	}

	func checkForUpdates() {
		controller.checkForUpdates(nil)
	}
}

/// yap is a menu bar app with no Dock icon. When a scheduled update can't
/// install silently, Sparkle then shows its alert behind the user's work
/// instead of pulling a background app to the front.
private final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {
	var supportsGentleScheduledUpdateReminders: Bool { true }
}
