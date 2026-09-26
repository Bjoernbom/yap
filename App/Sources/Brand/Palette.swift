import SwiftUI

/// Black and white plus one accent. Red is reserved for recording a meeting.
enum Palette {
	/// Signal lime, `#C8FF3D`: "listening".
	static let lime = Color(red: 200 / 255, green: 255 / 255, blue: 61 / 255)
	/// Recording a meeting, and nothing else.
	static let recording = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)
	static let notch = Color.black
	static let ink = Color.white
}
