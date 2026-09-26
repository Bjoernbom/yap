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

	private let model: OverlayModel
	private var panel: NotchPanel?
	private var levelTask: Task<Void, Never>?
	private var dismissTask: Task<Void, Never>?
	private var screenObserver: NSObjectProtocol?

	#if DEBUG
	/// Keeps the tick on screen for reviewing the look.
	var holdsDone = false
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

		if state == .done {
			scheduleDismiss()
		}
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

	private func scheduleDismiss() {
		#if DEBUG
		if holdsDone { return }
		#endif
		dismissTask = Task { [weak self] in
			try? await Task.sleep(for: Self.doneHold)
			guard !Task.isCancelled, let self, self.model.state == .done else { return }
			self.hide()
		}
	}

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
		if UserDefaults.standard.string(forKey: "YapOverlayScreen") == "notch",
		   let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
			return notched
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
