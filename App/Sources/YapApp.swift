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
			HistoryView(dictation: model.dictation)
		}
		.defaultSize(width: 640, height: 480)
		.defaultLaunchBehavior(.suppressed)
		.restorationBehavior(.disabled)

		#if DEBUG
		Window("Try it", id: WindowID.tryIt) {
			TryItView()
		}
		.defaultSize(width: 420, height: 240)
		.defaultLaunchBehavior(.suppressed)
		.restorationBehavior(.disabled)
		#endif

		Settings {
			SettingsView(dictation: model.dictation, text: model.text)
		}
	}
}
