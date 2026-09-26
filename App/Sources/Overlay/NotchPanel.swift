import AppKit

/// A borderless panel that sits over the menu bar and the notch. It never
/// takes focus, so whatever the user is typing into stays focused.
final class NotchPanel: NSPanel {
	init(contentRect: NSRect) {
		super.init(
			contentRect: contentRect,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: true
		)
		isFloatingPanel = true
		// Above the menu bar, and shown over full-screen apps.
		level = .statusBar
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		hidesOnDeactivate = false
		isMovable = false
		isReleasedWhenClosed = false
		animationBehavior = .none
	}

	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }

	/// AppKit pushes windows below the menu bar; this one belongs in it.
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}
}
