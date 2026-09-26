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

	/// Asks the window server for one of our own windows, which needs no
	/// permission. `CGWindowListCreateImage` is obsoleted in the macOS 15 SDK
	/// (unavailable to Swift) but still answers for the caller's own windows,
	/// so it is looked up at runtime. Debug-only; returns false if it's gone.
	@discardableResult
	static func writeWindowServerImage(of window: NSWindow, to url: URL) -> Bool {
		typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
		// Windows that were never ordered in have no window server number.
		guard window.windowNumber > 0, let windowID = UInt32(exactly: window.windowNumber),
		      let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
		else { return false }
		let create = unsafeBitCast(symbol, to: CreateImage.self)
		// .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
		guard let image = create(.null, 1 << 3, windowID, 1 << 0 | 1 << 3)?.takeRetainedValue(),
		      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
		else { return false }
		try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		return (try? png.write(to: url)) != nil
	}
}
#endif
