import SwiftUI

/// The black notch: flush with the top edge, rounded at the bottom, with
/// small concave shoulders so it looks like it melts out of the bezel.
/// Drawn horizontally centered in its rect, anchored to the top.
struct NotchShape: Shape {
	var width: CGFloat
	var height: CGFloat
	var bottomRadius: CGFloat
	var shoulder: CGFloat

	var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
		get { .init(.init(width, height), .init(bottomRadius, shoulder)) }
		set {
			width = newValue.first.first
			height = newValue.first.second
			bottomRadius = newValue.second.first
			shoulder = newValue.second.second
		}
	}

	func path(in rect: CGRect) -> Path {
		var path = Path()
		let height = max(height, 0)
		guard width > 0, height > 0 else { return path }

		let left = rect.midX - width / 2
		let right = rect.midX + width / 2
		let top = rect.minY
		let bottom = top + height
		let radius = min(bottomRadius, height / 2, width / 2)
		let shoulder = min(shoulder, height - radius, width / 4)

		path.move(to: CGPoint(x: left - shoulder, y: top))
		if shoulder > 0 {
			path.addArc(
				tangent1End: CGPoint(x: left, y: top),
				tangent2End: CGPoint(x: left, y: top + shoulder),
				radius: shoulder
			)
		}
		path.addArc(
			tangent1End: CGPoint(x: left, y: bottom),
			tangent2End: CGPoint(x: right, y: bottom),
			radius: radius
		)
		path.addArc(
			tangent1End: CGPoint(x: right, y: bottom),
			tangent2End: CGPoint(x: right, y: top),
			radius: radius
		)
		if shoulder > 0 {
			path.addArc(
				tangent1End: CGPoint(x: right, y: top),
				tangent2End: CGPoint(x: right + shoulder, y: top),
				radius: shoulder
			)
		} else {
			path.addLine(to: CGPoint(x: right, y: top))
		}
		path.closeSubpath()
		return path
	}
}
