import SwiftUI

@main
struct YapApp: App {
	@State private var model = AppModel()

	init() {
		BrandFont.register()
	}

	var body: some Scene {
		MenuBarExtra {
			MenuContent(model: model)
		} label: {
			Image(nsImage: MenuBarIcon.image)
			#if DEBUG
				.modifier(DebugWindowOpener())
			#endif
		}
		.menuBarExtraStyle(.menu)

		Window("History", id: WindowID.history) {
			HistoryView()
		}
		.defaultSize(width: 640, height: 480)
		.defaultLaunchBehavior(.suppressed)
		.restorationBehavior(.disabled)

		Settings {
			SettingsView()
		}
	}
}
