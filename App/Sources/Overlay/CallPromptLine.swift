import SwiftUI

/// "on a call? take notes": the question dimmed, the action as a white pill
/// so it reads as the thing to click. While notes run the red dot stays in
/// front, since the notch no longer shows the timer.
struct CallPromptLine: View {
	let prompt: NotchPrompt

	var body: some View {
		HStack(spacing: 8) {
			if prompt == .stopNotes {
				MeetingDot()
			}
			Text(prompt.question)
				.foregroundStyle(Palette.ink.opacity(0.7))
			Text(prompt.action)
				.foregroundStyle(Palette.notch)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(Capsule().fill(Palette.ink))
		}
		.font(.system(size: 13, weight: .medium))
		.lineLimit(1)
		.padding(.horizontal, 18)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text("\(prompt.question) \(prompt.action)"))
		.accessibilityAddTraits(.isButton)
	}
}
