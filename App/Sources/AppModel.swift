import Foundation
import Observation

/// App-wide state the menu and windows read. The real dictation and notes
/// sessions from YapKit plug in here later.
@MainActor
@Observable
final class AppModel {
	private(set) var isTakingNotes = false

	var statusLine: String {
		isTakingNotes ? "Taking notes" : "Hold fn to talk"
	}

	/// Shell only: flips the state until NotesSession exists.
	func toggleNotes() {
		isTakingNotes.toggle()
	}
}
