import AppKit
import SwiftUI

/// Black and white plus one accent. Red is reserved for recording a meeting.
enum Palette {
	/// Bone, `#D9D4C7`: "listening". Quiet on purpose: the notch is black and
	/// white, and the accent only warms it.
	static let bone = Color(red: 217 / 255, green: 212 / 255, blue: 199 / 255)
	/// Bone for strokes on a window. Bone itself vanishes on a light window,
	/// so light mode gets a darker stone from the same family.
	static let boneOnWindow = Color(nsColor: NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			? NSColor(red: 217 / 255, green: 212 / 255, blue: 199 / 255, alpha: 1)
			: NSColor(red: 120 / 255, green: 112 / 255, blue: 96 / 255, alpha: 1)
	})
	/// Recording a meeting, and nothing else.
	static let recording = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
	static let notch = Color.black
	static let ink = Color.white
}
