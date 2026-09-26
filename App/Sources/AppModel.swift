import Foundation
import Observation

/// App-wide state the menu and windows read.
@MainActor
@Observable
final class AppModel {
	let overlay: OverlayController
	let dictation: DictationController
	private(set) var isTakingNotes = false

	#if DEBUG
	let demo: OverlayDemo
	#endif

	init() {
		let overlay = OverlayController()
		self.overlay = overlay
		dictation = DictationController(overlay: overlay)
		var startsDictation = true
		#if DEBUG
		demo = OverlayDemo(overlay: overlay)
		demo.applyLaunchArguments()
		let defaults = UserDefaults.standard
		overlay.captureDirectory = defaults.string(forKey: "YapCaptureDir").map { URL(filePath: $0) }
		// The overlay probe and snapshots drive the notch themselves and quit;
		// loading the speech model for them would only cost memory.
		startsDictation = defaults.string(forKey: "YapProbe") == nil && defaults.string(forKey: "YapSnapshots") == nil
		#endif
		if startsDictation {
			dictation.start()
		}
	}

	var statusLine: String {
		isTakingNotes ? "Taking notes" : dictation.statusLine
	}

	/// Shell only: shows the recording notch until NotesSession exists.
	func toggleNotes() {
		isTakingNotes.toggle()
		overlay.show(isTakingNotes ? .recording(since: .now) : .hidden)
	}
}
