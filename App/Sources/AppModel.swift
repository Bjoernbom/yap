import Foundation
import Observation

/// App-wide state the menu and windows read.
@MainActor
@Observable
final class AppModel {
	let overlay: OverlayController
	let dictation: DictationController
	let text = TextSettingsStore()
	let onboarding: OnboardingModel
	let notes: NotesController

	#if DEBUG
	let demo: OverlayDemo
	#endif

	init() {
		let overlay = OverlayController()
		self.overlay = overlay
		let dictation = DictationController(overlay: overlay)
		self.dictation = dictation
		onboarding = OnboardingModel(dictation: dictation)
		notes = NotesController(overlay: overlay, dictation: dictation)
		overlay.onMeetingClick = { [notes] in notes.showLiveTranscript() }
		var startsDictation = true
		#if DEBUG
		demo = OverlayDemo(overlay: overlay)
		demo.applyLaunchArguments()
		let defaults = UserDefaults.standard
		overlay.captureDirectory = defaults.string(forKey: "YapCaptureDir").map { URL(filePath: $0) }
		// The overlay probe and snapshots drive the notch themselves and quit;
		// loading the speech model for them would only cost memory.
		startsDictation = defaults.string(forKey: "YapProbe") == nil && defaults.string(forKey: "YapSnapshots") == nil
		startsDictation = startsDictation && !NotesProbe.isRequested
		NotesProbe.shared.applyLaunchArguments()
		#endif
		dictation.processor = text.pipeline
		if startsDictation {
			dictation.start()
			notes.start()
		}
	}

	var statusLine: String {
		notes.statusLine ?? dictation.statusLine
	}
}
