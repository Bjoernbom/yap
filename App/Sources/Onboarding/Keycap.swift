import SwiftUI
import YapKit

/// The push-to-talk key as a small keycap that presses itself: hold, let go.
struct Keycap: View {
	let trigger: HotkeyTrigger
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.colorScheme) private var colorScheme

	private enum Phase: CaseIterable {
		case up, down, held, released

		var isDown: Bool { self == .down || self == .held }

		/// Quick press, a long hold (the talking), a quick release, a rest.
		var animation: Animation {
			switch self {
			case .up: .spring(duration: 0.3, bounce: 0.35)
			case .down: .easeOut(duration: 0.09)
			case .held: .linear(duration: 1.3)
			case .released: .linear(duration: 0.9)
			}
		}
	}

	var body: some View {
		if reduceMotion {
			cap(isDown: false)
		} else {
			PhaseAnimator(Phase.allCases) { phase in
				cap(isDown: phase.isDown)
			} animation: { phase in
				phase.animation
			}
		}
	}

	private func cap(isDown: Bool) -> some View {
		let face = colorScheme == .dark ? Color(white: 0.16) : Color.white
		let edge = colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.78)
		return ZStack {
			// The key's side, visible below the face until it's pressed.
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(edge)
				.offset(y: 4)
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(face)
				.overlay {
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.strokeBorder(isDown ? Palette.boneOnWindow : Color.primary.opacity(0.12), lineWidth: isDown ? 2 : 1)
				}
				.overlay(alignment: .topTrailing) { legendTop }
				.overlay(alignment: .bottomLeading) { legendBottom }
				.offset(y: isDown ? 3 : 0)
				.shadow(color: isDown ? Palette.boneOnWindow.opacity(0.55) : .clear, radius: 10)
		}
		.frame(width: 76, height: 72)
		.accessibilityElement()
		.accessibilityLabel("\(trigger.spokenName) key")
	}

	@ViewBuilder
	private var legendTop: some View {
		switch trigger {
		case .fn:
			Image(systemName: "globe")
				.font(.system(size: 14, weight: .regular))
				.foregroundStyle(.secondary)
				.padding(10)
		case .rightOption:
			Text("⌥")
				.font(.system(size: 15, weight: .regular))
				.foregroundStyle(.secondary)
				.padding(10)
		}
	}

	private var legendBottom: some View {
		Text(trigger == .fn ? "fn" : "option")
			.font(.system(size: 15, weight: .medium))
			.foregroundStyle(.primary)
			.padding(10)
	}
}

extension HotkeyTrigger {
	/// For VoiceOver: "fn", "right option".
	var spokenName: String {
		switch self {
		case .fn: "fn"
		case .rightOption: "right option"
		}
	}
}
