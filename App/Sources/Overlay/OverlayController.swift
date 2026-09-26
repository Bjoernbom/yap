import AppKit
import OSLog
import SwiftUI

/// Owns the notch panel. The only way in is `show(_:)` plus a level stream,
/// so the dictation engine can drive it without knowing about AppKit.
@MainActor
final class OverlayController {
	private static let grow = Animation.spring(duration: 0.22, bounce: 0.22)
	private static let shrink = Animation.spring(duration: 0.2, bounce: 0)
	/// How long the tick stays before the notch closes.
	private static let doneHold: Duration = .milliseconds(850)
	/// Long enough to read one line, short enough not to linger.
	private static let messageHold: Duration = .milliseconds(2600)

	private let model: OverlayModel
	private var panel: NotchPanel?
	private var levelTask: Task<Void, Never>?
	private var dismissTask: Task<Void, Never>?
	private var screenObserver: NSObjectProtocol?

	#if DEBUG
	/// Keeps the tick on screen for reviewing the look.
	var holdsDone = false
	/// The live panel, for the verification probe.
	var debugPanel: NSPanel? { panel }
	var debugGeometry: NotchGeometry { model.geometry }
	/// When set (`-YapCaptureDir`), every shown state is written to a PNG
	/// once its animation settled, so real dictations can be reviewed.
	var captureDirectory: URL?
	private var captureCount = 0
	#endif

	init() {
		model = OverlayModel(geometry: NotchGeometry(screen: Self.targetScreen()))
		screenObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.placePanel() }
		}
	}

	var state: OverlayState { model.state }

	func show(_ state: OverlayState) {
		dismissTask?.cancel()
		guard state != .hidden else {
			hide()
			return
		}

		let panel = panel ?? makePanel()
		if !panel.isVisible {
			placePanel()
			panel.orderFrontRegardless()
			// Render the tucked-in notch once, so the first frame grows from it.
			panel.displayIfNeeded()
		}

		if state.content != model.state.content || state == .working {
			model.stateSince = .now
		}
		if state != .listening {
			stopLevels()
		}
		withAnimation(Self.grow) {
			model.state = state
		}

		switch state {
		case .done: scheduleDismiss(of: state, after: Self.doneHold)
		case .message: scheduleDismiss(of: state, after: Self.messageHold)
		default: break
		}

		#if DEBUG
		capture(state)
		#endif
	}

	func hide() {
		dismissTask?.cancel()
		stopLevels()
		guard model.state != .hidden else { return }
		withAnimation(Self.shrink) {
			model.state = .hidden
		} completion: { [weak self] in
			// A show() during the shrink wins; only park the panel if still hidden.
			guard let self, self.model.state == .hidden else { return }
			self.panel?.orderOut(nil)
		}
	}

	/// Feeds the waveform. Levels are 0...1, about 30 per second.
	func follow(levels: AsyncStream<Float>) {
		stopLevels()
		model.levels.reset()
		levelTask = Task { [weak self] in
			for await level in levels {
				guard let self else { return }
				self.model.levels.push(level)
			}
		}
	}

	private func stopLevels() {
		levelTask?.cancel()
		levelTask = nil
	}

	private func scheduleDismiss(of state: OverlayState, after hold: Duration) {
		#if DEBUG
		if holdsDone { return }
		#endif
		dismissTask = Task { [weak self] in
			try? await Task.sleep(for: hold)
			guard !Task.isCancelled, let self, self.model.state == state else { return }
			self.hide()
		}
	}

	#if DEBUG
	private func capture(_ state: OverlayState) {
		guard let directory = captureDirectory else { return }
		captureCount += 1
		let prefix = String(format: "%02d-", captureCount) + Self.slug(for: state)
		// Working lasts ~100 ms with a warm model, so catch it right away. The
		// others once the spring has settled; listening a few more times, since
		// speech starts a moment after the key.
		let delays: [Duration] = switch state {
		case .working: [.milliseconds(30)]
		case .listening: [.milliseconds(420), .milliseconds(1500), .milliseconds(3000)]
		default: [.milliseconds(420)]
		}
		Task { [weak self] in
			var elapsed = Duration.zero
			for (index, delay) in delays.enumerated() {
				try? await Task.sleep(for: delay - elapsed)
				elapsed = delay
				guard let self, self.model.state == state, let view = self.panel?.contentView else { return }
				let suffix = index == 0 ? "" : "-\(index + 1)"
				PanelCapture.write(view, to: directory.appending(path: prefix + suffix + ".png"))
			}
		}
	}

	private static func slug(for state: OverlayState) -> String {
		switch state {
		case .hidden: "hidden"
		case .listening: "listening"
		case .working: "working"
		case .done: "done"
		case .message: "message"
		case .recording: "recording"
		}
	}
	#endif

	private func makePanel() -> NotchPanel {
		let layout = OverlayLayout(geometry: model.geometry)
		let panel = NotchPanel(contentRect: layout.panelFrame)
		let host = NSHostingView(rootView: OverlayView(model: model))
		host.sizingOptions = []
		host.safeAreaRegions = []
		panel.contentView = host
		self.panel = panel
		return panel
	}

	/// Re-reads the screen (it may have changed) and pins the panel to its notch.
	private func placePanel() {
		model.geometry = NotchGeometry(screen: Self.targetScreen())
		let frame = OverlayLayout(geometry: model.geometry).panelFrame
		panel?.setFrame(frame, display: false)
		Logger.overlay.debug(
			"Notch \(String(describing: self.model.geometry.notch), privacy: .public) panel \(String(describing: frame), privacy: .public)"
		)
	}

	/// The screen the user is looking at: the one with the pointer.
	private static func targetScreen() -> NSScreen {
		#if DEBUG
		// "notch" or "plain" pins the overlay to a screen with or without one.
		if let preference = UserDefaults.standard.string(forKey: "YapOverlayScreen"),
		   let screen = NSScreen.screens.first(where: { ($0.safeAreaInsets.top > 0) == (preference == "notch") }) {
			return screen
		}
		#endif
		let pointer = NSEvent.mouseLocation
		return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
			?? NSScreen.main
			?? NSScreen.screens[0]
	}
}

extension Logger {
	static let overlay = Logger(subsystem: "com.bjornbom.yap", category: "overlay")
}
