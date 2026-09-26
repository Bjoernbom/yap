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
				.modifier(OnboardingOpener(onboarding: model.onboarding))
				.modifier(NotesWindowOpener(notes: model.notes))
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

		Window("Set up yap", id: WindowID.onboarding) {
			OnboardingView(model: model.onboarding)
		}
		.windowStyle(.hiddenTitleBar)
		.windowResizability(.contentSize)
		.defaultWindowPlacement { _, _ in WindowPlacement(.center) }
		.defaultLaunchBehavior(.suppressed)
		.restorationBehavior(.disabled)

		Window("Live transcript", id: WindowID.liveTranscript) {
			LiveTranscriptView(notes: model.notes)
		}
		.defaultSize(width: 480, height: 520)
		.defaultLaunchBehavior(.suppressed)
		.restorationBehavior(.disabled)

		Window("Note", id: WindowID.note) {
			NoteView(notes: model.notes)
		}
		.defaultSize(width: 620, height: 680)
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
