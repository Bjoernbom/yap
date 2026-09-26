import SwiftUI
import YapKit

/// Placeholder for the one-screen settings (M4).
struct SettingsView: View {
	var body: some View {
		VStack(spacing: 10) {
			Text("yap")
				.font(BrandFont.pixel(56))
			Text("Settings will live here.")
				.foregroundStyle(.secondary)
			Text("Version \(YapKit.version)")
				.font(.caption)
				.foregroundStyle(.tertiary)
				.padding(.top, 6)
		}
		.frame(width: 460, height: 300)
	}
}

#Preview {
	SettingsView()
}
