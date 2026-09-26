import CoreText
import OSLog
import SwiftUI

/// Pixelify Sans, for brand moments only: the wordmark, the notch timer and
/// big numbers. Everything else uses the system font.
enum BrandFont {
	static let family = "Pixelify Sans"

	/// Registers the bundled font for this process. Call once at launch.
	static func register() {
		guard let url = Bundle.main.url(forResource: "PixelifySans", withExtension: "ttf") else {
			Logger.brand.error("PixelifySans.ttf is missing from the bundle")
			return
		}
		var error: Unmanaged<CFError>?
		if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
			let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
			Logger.brand.error("Could not register Pixelify Sans: \(reason, privacy: .public)")
		}
	}

	/// A fixed-size pixel font. Pixel type must not scale with Dynamic Type,
	/// or its pixels stop landing on the grid.
	static func pixel(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
		.custom(family, fixedSize: size).weight(weight)
	}
}

extension Logger {
	static let brand = Logger(subsystem: "com.bjornbom.yap", category: "brand")
}
