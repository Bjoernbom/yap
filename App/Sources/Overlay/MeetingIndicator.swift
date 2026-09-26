import SwiftUI

/// Red dot and elapsed time while taking notes. Ticks once a second, which
/// keeps an hour-long meeting cheap.
struct MeetingDot: View {
	var body: some View {
		Circle()
			.fill(Palette.recording)
			.frame(width: 9, height: 9)
			.shadow(color: Palette.recording.opacity(0.6), radius: 4)
			.accessibilityLabel("Recording")
	}
}

struct MeetingTimer: View {
	let since: Date
	var size: CGFloat = 15

	var body: some View {
		TimelineView(.periodic(from: since, by: 1)) { timeline in
			let text = Self.format(timeline.date.timeIntervalSince(since))
			HStack(spacing: 0) {
				// Fixed advance per character, so the digits never jiggle.
				ForEach(Array(text.enumerated()), id: \.offset) { _, character in
					Text(String(character))
						.frame(width: character == ":" ? size * 0.34 : size * 0.6)
				}
			}
			.font(BrandFont.pixel(size))
			.foregroundStyle(Palette.ink)
			.accessibilityLabel(Text("Recording for \(text)"))
		}
	}

	static func format(_ interval: TimeInterval) -> String {
		let seconds = max(Int(interval), 0)
		let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
		let twoDigits = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
		return hours > 0
			? "\(hours):\(twoDigits(minutes)):\(twoDigits(rest))"
			: "\(minutes):\(twoDigits(rest))"
	}
}
