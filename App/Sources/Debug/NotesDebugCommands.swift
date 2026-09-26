#if DEBUG
import AppKit
import OSLog

/// Lets a verification script drive notes through distributed
/// notifications, since the menu bar menu can't be clicked headless:
///
/// - `com.bjornbom.yap.debug.notes.start` / `.stop`: what the menu items do
///   (a start while recording and a stop while idle are ignored, like the
///   menu).
/// - `com.bjornbom.yap.debug.notes.toggle`: what ⌥⌘N does.
/// - `com.bjornbom.yap.debug.notes.live`: what a click on the notch does.
/// - `com.bjornbom.yap.debug.notes.capture`: writes the notes windows to
///   `-YapCaptureDir` as `notes-<title>.png` (its own name, so other yap
///   instances listening for `captureWindows` stay out of it).
/// - `com.bjornbom.yap.debug.notes.where`: logs where the notch's timer is
///   on screen, in CoreGraphics coordinates, so a script can click it.
@MainActor
final class NotesDebugCommands {
	private var observers: [NSObjectProtocol] = []

	init(notes: NotesController, overlay: OverlayController) {
		let center = DistributedNotificationCenter.default()
		let commands: [(String, @MainActor (NotesController) -> Void)] = [
			("start", { if $0.phase == .idle { $0.toggle() } }),
			("stop", { if $0.isRecording { $0.toggle() } }),
			("toggle", { $0.toggle() }),
			("live", { $0.showLiveTranscript() }),
			("capture", { _ in Self.captureWindows() }),
			("where", { [weak overlay] _ in overlay.map(Self.logTimerLocation) }),
		]
		for (name, command) in commands {
			observers.append(center.addObserver(
				forName: Notification.Name("com.bjornbom.yap.debug.notes.\(name)"), object: nil, queue: .main
			) { [weak notes] _ in
				MainActor.assumeIsolated {
					guard let notes else { return }
					command(notes)
				}
			})
		}
	}

	private static func logTimerLocation(_ overlay: OverlayController) {
		guard let panel = overlay.debugPanel, let screen = NSScreen.screens.first else { return }
		let geometry = overlay.debugGeometry
		// The timer sits in the right wing, next to the hardware notch.
		let notchWidth = geometry.notch?.width ?? 0
		let x = geometry.midX + notchWidth / 2 + OverlayLayout.wing / 2
		let y = screen.frame.maxY - geometry.screenFrame.maxY + (geometry.notch?.height ?? geometry.menuBarHeight) / 2
		Logger.notes.notice("Timer at x=\(x, privacy: .public) y=\(y, privacy: .public) ignoresMouse=\(panel.ignoresMouseEvents, privacy: .public)")
	}

	private static func captureWindows() {
		guard let directory = UserDefaults.standard.string(forKey: "YapCaptureDir").map({ URL(filePath: $0) }) else { return }
		for window in NSApp.windows where window.isVisible && ["Live transcript", "Note"].contains(window.title) {
			let slug = window.title.lowercased().replacingOccurrences(of: " ", with: "-")
			PanelCapture.writeWindowServerImage(of: window, to: directory.appending(path: "notes-\(slug).png"))
		}
	}
}
#endif
