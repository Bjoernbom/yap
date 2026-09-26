import SwiftUI

/// Placeholder for dictation history (M1).
struct HistoryView: View {
	var body: some View {
		ContentUnavailableView {
			Label("Nothing yet", systemImage: "text.bubble")
		} description: {
			Text("Everything you dictate shows up here for 30 days.")
		}
		.frame(minWidth: 520, minHeight: 360)
	}
}

#Preview {
	HistoryView()
}
