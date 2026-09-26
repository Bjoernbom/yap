import AppKit

/// The pixel "yap" wordmark for the menu bar, drawn in code so it stays crisp
/// at any scale. A template image, so macOS tints it for light, dark and
/// highlighted menu bars.
@MainActor
enum MenuBarIcon {
	/// One glyph pixel, in points. 1.5 pt lands on whole device pixels on
	/// Retina displays (3 px), which is what makes it look sharp.
	private static let unit: CGFloat = 1.5

	/// Rows top to bottom. Rows 0–3 are the x-height, 4–5 the descenders.
	private static let glyphs: [[String]] = [
		// y
		["#..#",
		 "#..#",
		 "#..#",
		 ".###",
		 "...#",
		 "###."],
		// a
		[".##.",
		 "#..#",
		 "#..#",
		 ".###",
		 "....",
		 "...."],
		// p
		["###.",
		 "#..#",
		 "#..#",
		 "###.",
		 "#...",
		 "#..."],
	]

	static let image: NSImage = {
		let glyphWidth = 4
		let spacing = 1
		let columns = glyphs.count * glyphWidth + (glyphs.count - 1) * spacing
		let size = NSSize(width: CGFloat(columns) * unit, height: 16)
		// Center the x-height, not the whole glyph, so it sits like text.
		let top = (size.height - 4 * unit) / 2 - unit

		let image = NSImage(size: size, flipped: true) { _ in
			NSColor.black.setFill()
			for (index, glyph) in glyphs.enumerated() {
				let originColumn = index * (glyphWidth + spacing)
				for (row, line) in glyph.enumerated() {
					for (column, pixel) in line.enumerated() where pixel == "#" {
						NSRect(
							x: CGFloat(originColumn + column) * unit,
							y: top + CGFloat(row) * unit,
							width: unit,
							height: unit
						).fill()
					}
				}
			}
			return true
		}
		image.isTemplate = true
		image.accessibilityDescription = "yap"
		return image
	}()
}
