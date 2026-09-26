#if DEBUG
import AppKit

/// Runs the live overlay through every state and records what the window
/// server sees: frames, Space, occlusion, focus. Also captures the real
/// panel and menu bar item to PNG in-process, which needs no screen
/// recording permission. Started with `-YapProbe <dir>`; writes
/// `<dir>/probe.txt` and quits unless `-YapProbeStay YES`.
@MainActor
final class OverlayProbe {
	private let overlay: OverlayController
	private let demo: OverlayDemo
	private let directory: URL
	private var lines: [String] = []

	init(overlay: OverlayController, demo: OverlayDemo, directory: URL) {
		self.overlay = overlay
		self.demo = demo
		self.directory = directory
	}

	func run() async {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try? await Task.sleep(for: .seconds(1))
		log("front app at start: \(frontApp)")
		log("screens: " + NSScreen.screens.map { "\($0.localizedName) \($0.frame) notch=\($0.safeAreaInsets.top > 0)" }.joined(separator: " | "))
		captureStatusItem()

		let states: [(String, OverlayState)] = [
			("listening", .listening),
			("working", .working),
			("done", .done),
			("message", .message("Couldn't type here. It's on your clipboard.")),
			("recording", .recording(since: .now.addingTimeInterval(-754))),
		]
		overlay.holdsDone = true
		for (name, state) in states {
			demo.show(state)
			try? await Task.sleep(for: .milliseconds(name == "working" ? 900 : 700))
			record(name)
		}
		overlay.holdsDone = false

		demo.show(.hidden)
		try? await Task.sleep(for: .milliseconds(600))
		record("hidden")

		// Rapid cycling: must end hidden, with the panel parked.
		let start = Date.now
		for _ in 0..<80 {
			let state: OverlayState = [.listening, .working, .done, .recording(since: .now), .hidden].randomElement() ?? .hidden
			demo.show(state)
			try? await Task.sleep(for: .milliseconds(Int.random(in: 15...120)))
		}
		demo.show(.listening)
		try? await Task.sleep(for: .milliseconds(80))
		demo.show(.hidden)
		try? await Task.sleep(for: .milliseconds(600))
		log(String(format: "rapid: 80 random states in %.1f s", Date.now.timeIntervalSince(start)))
		record("after-rapid")

		// Done must close on its own.
		demo.show(.done)
		try? await Task.sleep(for: .milliseconds(1500))
		record("done-auto-dismiss")

		captureWindows()

		let report = lines.joined(separator: "\n") + "\n"
		try? report.write(to: directory.appending(path: "probe.txt"), atomically: true, encoding: .utf8)
		if !UserDefaults.standard.bool(forKey: "YapProbeStay") {
			NSApp.terminate(nil)
		}
	}

	private var frontApp: String {
		NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
	}

	private func record(_ name: String) {
		guard let panel = overlay.debugPanel else {
			log("\(name): no panel yet")
			return
		}
		let geometry = overlay.debugGeometry
		log("""
		\(name): state=\(overlay.state) visible=\(panel.isVisible) \
		onActiveSpace=\(panel.isOnActiveSpace) occluded=\(!panel.occlusionState.contains(.visible)) \
		frame=\(panel.frame) screen=\(panel.screen?.localizedName ?? "none") \
		notch=\(geometry.notch.map { "\($0)" } ?? "none") midX=\(geometry.midX) \
		level=\(panel.level.rawValue) key=\(panel.isKeyWindow) yapActive=\(NSApp.isActive) front=\(frontApp)
		""")
		if panel.isVisible, let view = panel.contentView {
			write(view, name: "live-\(name).png")
		}
	}

	private func captureStatusItem() {
		let window = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBar") }
		guard let view = window?.contentView else {
			log("status item: window not found")
			return
		}
		log("status item: frame=\(window?.frame ?? .zero) appearance=\(view.effectiveAppearance.name.rawValue)")
		write(view, name: "live-menubar-item.png")
	}

	/// Settings and History, if `-YapOpenWindows YES` opened them.
	private func captureWindows() {
		for window in NSApp.windows where window.isVisible && !window.title.isEmpty {
			log("window: title=\"\(window.title)\" frame=\(window.frame) key=\(window.isKeyWindow)")
			// The frame view includes the title bar.
			if let view = window.contentView?.superview ?? window.contentView {
				let slug = window.title.lowercased().replacingOccurrences(of: " ", with: "-")
				write(view, name: "live-window-\(slug).png")
			}
		}
	}

	private func write(_ view: NSView, name: String) {
		PanelCapture.write(view, to: directory.appending(path: name))
	}

	private func log(_ line: String) {
		lines.append(line)
	}
}
#endif
