import SwiftUI

@main
struct YapApp: App {
	var body: some Scene {
		MenuBarExtra("yap", systemImage: "waveform") {
			Button("Quit yap") { NSApp.terminate(nil) }
		}
	}
}
