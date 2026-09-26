import AppKit

/// Where the notch is on one screen, in that screen's global coordinates.
/// Screens without a hardware notch get a virtual one centered in the menu bar.
struct NotchGeometry: Equatable, Sendable {
	var screenFrame: CGRect
	/// Size of the hardware notch, or nil on screens without one.
	var notch: CGSize?
	/// Horizontal center of the notch (or of the screen).
	var midX: CGFloat
	var menuBarHeight: CGFloat

	init(screenFrame: CGRect, notch: CGSize?, midX: CGFloat, menuBarHeight: CGFloat) {
		self.screenFrame = screenFrame
		self.notch = notch
		self.midX = midX
		self.menuBarHeight = menuBarHeight
	}

	@MainActor
	init(screen: NSScreen) {
		let frame = screen.frame
		let topInset = screen.safeAreaInsets.top
		if topInset > 0,
		   let left = screen.auxiliaryTopLeftArea,
		   let right = screen.auxiliaryTopRightArea {
			// The notch is whatever the two usable menu bar areas leave out.
			let width = frame.width - left.width - right.width
			self.init(
				screenFrame: frame,
				notch: CGSize(width: width, height: topInset),
				midX: frame.minX + left.width + width / 2,
				menuBarHeight: topInset
			)
		} else {
			let visibleMenuBar = frame.maxY - screen.visibleFrame.maxY
			self.init(
				screenFrame: frame,
				notch: nil,
				midX: frame.midX,
				menuBarHeight: visibleMenuBar > 0 ? visibleMenuBar : NSStatusBar.system.thickness
			)
		}
	}

	var hasNotch: Bool { notch != nil }
}
