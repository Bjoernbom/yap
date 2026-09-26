import SwiftUI

/// The shared pixel grid for everything drawn in the notch. Whole points map
/// to whole device pixels on Retina, which keeps the squares sharp.
enum PixelGrid {
	/// Side of one square pixel.
	static let pixel: CGFloat = 3
	/// Distance from one pixel to the next.
	static let cell: CGFloat = 4

	static func length(_ count: Int, pitch: CGFloat = cell) -> CGFloat {
		CGFloat(count) * pitch - (pitch - pixel)
	}

	static func rect(column: Int, row: Int, columnPitch: CGFloat = cell) -> CGRect {
		CGRect(x: CGFloat(column) * columnPitch, y: CGFloat(row) * cell, width: pixel, height: pixel)
	}
}

extension GraphicsContext {
	func fillPixel(column: Int, row: Int, with color: Color, columnPitch: CGFloat = PixelGrid.cell) {
		fill(Path(PixelGrid.rect(column: column, row: row, columnPitch: columnPitch)), with: .color(color))
	}
}
