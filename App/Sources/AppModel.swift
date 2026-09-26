import Foundation
import Observation

/// App-wide state the menu and windows read. The real dictation and notes
/// sessions from YapKit plug in here later.
@MainActor
@Observable
final class AppModel {
	let overlay: OverlayController
	private(set) var isTakingNotes = false

	init() {
		overlay = OverlayController()
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
