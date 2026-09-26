import CoreGraphics

/// Sizes of the notch per state. Pure numbers, so the panel and the view
/// always agree.
struct OverlayLayout: Equatable, Sendable {
	struct Spec: Equatable, Sendable {
		var size: CGSize
		var bottomRadius: CGFloat
		var shoulder: CGFloat
	}

	/// Height of the strip that drops below the notch for dictation.
	static let strip: CGFloat = 46
	/// Width of the strip for a one-line message; the longest ones ("That's a
	/// password field. It's on your clipboard.") fit at 13 pt.
	static let messageWidth: CGFloat = 340
	/// Width of each side wing while recording a meeting.
	static let wing: CGFloat = 72
	static let shoulder: CGFloat = 7
	/// Extra room so the spring can overshoot without being clipped.
	static let overshoot: CGFloat = 12

	let geometry: NotchGeometry

	/// The band at the top that the hardware notch hides.
	var topBand: CGFloat { geometry.notch?.height ?? 0 }

	func spec(for state: OverlayState) -> Spec {
		let notch = geometry.notch
		switch state {
		case .hidden:
			if let notch {
				// Slightly smaller than the hardware notch, so it vanishes into it.
				return Spec(size: CGSize(width: notch.width - 4, height: notch.height - 2), bottomRadius: 10, shoulder: 0)
			}
			return Spec(size: CGSize(width: 150, height: 0), bottomRadius: 0, shoulder: 0)

		case .listening, .working, .done:
			let width = max((notch?.width ?? 0) + 28, 184)
			return Spec(size: CGSize(width: width, height: topBand + Self.strip), bottomRadius: 20, shoulder: Self.shoulder)

		case .message, .prompt:
			let width = max((notch?.width ?? 0) + 28, Self.messageWidth)
			return Spec(size: CGSize(width: width, height: topBand + Self.strip), bottomRadius: 20, shoulder: Self.shoulder)

		case .recording:
			if let notch {
				return Spec(size: CGSize(width: notch.width + 2 * Self.wing, height: notch.height), bottomRadius: 12, shoulder: 6)
			}
			return Spec(size: CGSize(width: 108, height: geometry.menuBarHeight + 2), bottomRadius: 11, shoulder: 6)
		}
	}

	/// The panel is sized once for the largest state; the shape animates inside it.
	var panelSize: CGSize {
		let states: [OverlayState] = [.listening, .message(""), .recording(since: .distantPast)]
		let widest = states.map { spec(for: $0).size.width }.max() ?? 0
		let tallest = states.map { spec(for: $0).size.height }.max() ?? 0
		return CGSize(width: widest + 2 * Self.shoulder + 2 * Self.overshoot, height: tallest + Self.overshoot)
	}

	/// Panel frame in global screen coordinates: flush with the top, centered on the notch.
	var panelFrame: CGRect {
		let size = panelSize
		return CGRect(
			x: (geometry.midX - size.width / 2).rounded(),
			y: geometry.screenFrame.maxY - size.height,
			width: size.width,
			height: size.height
		)
	}
}
