import SwiftUI

/// The menu bar menu. Short on purpose: yap mostly lives in the notch.
struct MenuContent: View {
	let model: AppModel
	@Environment(\.openWindow) private var openWindow
	@Environment(\.openSettings) private var openSettings

	var body: some View {
		Text(model.statusLine)

		Divider()

		Button(model.isTakingNotes ? "Stop notes" : "Start notes") {
			model.toggleNotes()
		}
		.keyboardShortcut("n", modifiers: [.option, .command])

		Button("History") {
			bringToFront()
			openWindow(id: WindowID.history)
		}
		.keyboardShortcut("y")

		Button("Settings…") {
			bringToFront()
			openSettings()
		}
		.keyboardShortcut(",")

		#if DEBUG
		Divider()

		Menu("Debug") {
			Button("Cycle overlay states") { model.demo.cycle() }
			Button("Rapid-fire overlay states") { model.demo.rapidCycle() }
			Divider()
			Button("Listening") { model.demo.show(.listening) }
			Button("Working") { model.demo.show(.working) }
			Button("Done") { model.demo.show(.done) }
			Button("Recording") { model.demo.show(.recording(since: .now)) }
			Button("Hide overlay") { model.demo.show(.hidden) }
		}
		#endif

		Divider()

		Button("Quit yap") {
			NSApp.terminate(nil)
		}
		.keyboardShortcut("q")
	}

	/// A menu bar app is never active on its own, so its windows would open
	/// behind whatever the user is in.
	private func bringToFront() {
		NSApp.activate()
	}
}

enum WindowID {
	static let history = "history"
}
