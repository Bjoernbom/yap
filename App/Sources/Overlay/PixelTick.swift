import SwiftUI

/// "Done": a pixel tick that draws itself on, one pixel at a time.
struct PixelTick: View {
	let since: Date
	/// White in the notch; onboarding draws it in bone on the window.
	var color: Color = Palette.ink

	/// A two-pixel stroke in drawing order: down the short arm, up the long one.
	private static let pixels: [(column: Int, row: Int)] = [
		(0, 2), (1, 2), (1, 3), (2, 3), (2, 4), (3, 4), (3, 5), (4, 5), (4, 4),
		(5, 4), (5, 3), (6, 3), (6, 2), (7, 2), (7, 1), (8, 1), (8, 0), (9, 0),
	]
	private static let columns = 10
	private static let rows = 6
	private static let stepDuration: TimeInterval = 0.014

	private var drawDuration: TimeInterval {
		Double(Self.pixels.count) * Self.stepDuration
	}

	var body: some View {
		// Animate only while drawing on; afterwards the frame is static.
		TimelineView(.animation(paused: Date.now.timeIntervalSince(since) > drawDuration + 0.1)) { timeline in
			let elapsed = timeline.date.timeIntervalSince(since)
			Canvas { context, _ in
				for (index, pixel) in Self.pixels.enumerated() {
					let appear = (elapsed - Double(index) * Self.stepDuration) / Self.stepDuration
					guard appear > 0 else { break }
					context.fillPixel(column: pixel.column, row: pixel.row, with: color.opacity(min(appear, 1)))
				}
			}
		}
		.frame(width: PixelGrid.length(Self.columns), height: PixelGrid.length(Self.rows))
		.accessibilityLabel("Done")
	}
}
