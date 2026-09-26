import Foundation
import Observation

/// App-wide state the menu and windows read. The real dictation and notes
/// sessions from YapKit plug in here later.
@MainActor
@Observable
final class AppModel {
	let overlay: OverlayController
	private(set) var isTakingNotes = false

	#if DEBUG
	let demo: OverlayDemo
	#endif

	init() {
		let overlay = OverlayController()
		self.overlay = overlay
		#if DEBUG
		demo = OverlayDemo(overlay: overlay)
		demo.applyLaunchArguments()
		#endif
	}

	var statusLine: String {
		isTakingNotes ? "Taking notes" : "Hold fn to talk"
	}

	/// Shell only: shows the recording notch until NotesSession exists.
	func toggleNotes() {
		isTakingNotes.toggle()
		overlay.show(isTakingNotes ? .recording(since: .now) : .hidden)
	}
}
