#if DEBUG
import AppKit
import OSLog
import SwiftUI

/// Renders each overlay state over a stand-in desktop, for design review.
/// Uses the same views as the live panel; needs no screen recording access.
@MainActor
enum OverlaySnapshots {
	static func write(to directory: URL) {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
		let geometries: [(String, NotchGeometry)] = [
			("", notched.map(NotchGeometry.init(screen:)) ?? macBookPro14),
			("-no-notch", plainDisplay),
		]
		let now = Date.now
		let states: [(String, OverlayState, Date)] = [
			("listening", .listening, now),
			("working", .working, now.addingTimeInterval(-0.62)),
			("done", .done, now.addingTimeInterval(-2)),
			("message", .message("Couldn't type here. It's on your clipboard."), now),
			("recording", .recording(since: now.addingTimeInterval(-754)), now),
			("prompt-take-notes", .prompt(.takeNotes), now),
			("prompt-stop-notes", .prompt(.stopNotes), now),
		]

		for (suffix, geometry) in geometries {
			for (name, state, since) in states {
				let model = OverlayModel(geometry: geometry)
				model.state = state
				model.stateSince = since
				var levels = FakeLevels()
				for _ in 0..<42 {
					model.levels.push(levels.next())
				}
				let view = Backdrop(geometry: geometry) { OverlayView(model: model) }
				let renderer = ImageRenderer(content: view)
				renderer.scale = 2
				guard let image = renderer.cgImage,
				      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
				else { continue }
				let url = directory.appending(path: "overlay-\(name)\(suffix).png")
				do {
					try png.write(to: url)
				} catch {
					Logger.overlay.error("Snapshot \(url.path, privacy: .public) failed: \(error, privacy: .public)")
				}
			}
		}
	}

	private static let macBookPro14 = NotchGeometry(
		screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
		notch: CGSize(width: 185, height: 32),
		midX: 756,
		menuBarHeight: 32
	)

	private static let plainDisplay = NotchGeometry(
		screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
		notch: nil,
		midX: 864,
		menuBarHeight: 24
	)

	/// A slice of the top of a desktop: wallpaper, menu bar, hardware notch.
	private struct Backdrop<Overlay: View>: View {
		let geometry: NotchGeometry
		@ViewBuilder let overlay: Overlay

		var body: some View {
			let panel = OverlayLayout(geometry: geometry).panelSize
			ZStack(alignment: .top) {
				LinearGradient(
					colors: [Color(red: 0.42, green: 0.47, blue: 0.58), Color(red: 0.68, green: 0.62, blue: 0.66)],
					startPoint: .top,
					endPoint: .bottom
				)
				Rectangle()
					.fill(.white.opacity(0.18))
					.frame(height: geometry.menuBarHeight)
				if let notch = geometry.notch {
					NotchShape(width: notch.width, height: notch.height, bottomRadius: 10, shoulder: 0)
						.fill(.black)
				}
				overlay
			}
			.frame(width: panel.width + 180, height: panel.height + 28)
		}
	}
}
#endif
