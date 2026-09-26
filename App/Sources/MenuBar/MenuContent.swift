import SwiftUI

/// The menu bar menu. Short on purpose: yap mostly lives in the notch.
struct MenuContent: View {
	let model: AppModel
	@Environment(\.openWindow) private var openWindow
	@Environment(\.openSettings) private var openSettings

	var body: some View {
		Text(model.statusLine)

		if model.dictation.needsPermissions {
			Button("Grant access…") {
				Task { await model.dictation.grantAccess() }
			}
		}

		Divider()

		// ⌃⌘V also works while another app is frontmost: `GlobalHotKey`
		// registers it system-wide. The shortcut here is what the menu shows.
		Button("Paste last") {
			// Let the menu close and focus settle back on the user's app first.
			Task {
				try? await Task.sleep(for: .milliseconds(150))
				model.dictation.pasteLast()
			}
		}
		.keyboardShortcut("v", modifiers: [.control, .command])

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
			Button("Try it window") {
				bringToFront()
				openWindow(id: WindowID.tryIt)
			}
			Divider()
			Button("Cycle overlay states") { model.demo.cycle() }
			Button("Rapid-fire overlay states") { model.demo.rapidCycle() }
			Divider()
			Button("Listening") { model.demo.show(.listening) }
			Button("Working") { model.demo.show(.working) }
			Button("Done") { model.demo.show(.done) }
			Button("Recording") { model.demo.show(.recording(since: .now)) }
			Button("Hide overlay") { model.demo.show(.hidden) }
			Divider()
			Button("Record system audio (5 s)") { NotesProbe.shared.recordFromMenu() }
			Button(NotesProbe.shared.isWatchingCalls ? "Stop watching for calls" : "Watch for calls") { NotesProbe.shared.toggleCallWatch() }
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
	#if DEBUG
	static let tryIt = "try-it"
	#endif
}
