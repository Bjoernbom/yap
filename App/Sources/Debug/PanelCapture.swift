#if DEBUG
import AppKit

/// Writes a view to PNG in-process. Needs no Screen Recording permission,
/// unlike `screencapture`, and sees yap's own panels, which the computer-use
/// tools filter out.
@MainActor
enum PanelCapture {
	static func write(_ view: NSView, to url: URL) {
		try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
		view.cacheDisplay(in: view.bounds, to: rep)
		guard let png = rep.representation(using: .png, properties: [:]) else { return }
		try? png.write(to: url)
	}
}
#endif
