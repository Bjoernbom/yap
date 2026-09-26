// Renders an app's icon the way Finder and System Settings show it, by asking
// NSWorkspace (IconServices) for it, so the macOS 26 mask, scaling and edge
// light are all applied.
//
// usage: swift render-icon.swift <path.app> <out dir> <prefix> [size ...]
// Writes <prefix>-<size>.png (1x) and <prefix>-<size>@2x.png for each size.

import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
	FileHandle.standardError.write(Data("usage: render-icon <app> <out dir> <prefix> [size ...]\n".utf8))
	exit(2)
}
let icon = NSWorkspace.shared.icon(forFile: args[1])
let sizes = args.count > 4 ? args[4...].compactMap { Int($0) } : [16, 32, 128, 512]

for size in sizes {
	for scale in [1, 2] {
		let pixels = size * scale
		guard let rep = NSBitmapImageRep(
			bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
			bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
			colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
		) else { exit(1) }
		// Point size stays `size`, so a 2x rep picks the icon's @2x image,
		// exactly like a Retina display.
		rep.size = NSSize(width: size, height: size)
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		icon.draw(
			in: NSRect(x: 0, y: 0, width: size, height: size),
			from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil
		)
		NSGraphicsContext.restoreGraphicsState()
		let name = scale == 1 ? "\(args[3])-\(size).png" : "\(args[3])-\(size)@2x.png"
		guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
		try data.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
	}
}
