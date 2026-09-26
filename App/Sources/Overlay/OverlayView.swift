import SwiftUI

/// What the overlay view renders. Owned by `OverlayController`.
@MainActor
@Observable
final class OverlayModel {
	var state: OverlayState = .hidden
	var geometry: NotchGeometry
	/// When the current state began; drives the fold and the tick draw-on.
	var stateSince = Date.now
	@ObservationIgnored let levels = AudioLevels()

	init(geometry: NotchGeometry) {
		self.geometry = geometry
	}
}

/// The notch itself: a black shape that grows out of the hardware notch,
/// with the state's content revealed inside it.
struct OverlayView: View {
	let model: OverlayModel

	var body: some View {
		let layout = OverlayLayout(geometry: model.geometry)
		let spec = layout.spec(for: model.state)
		let shape = NotchShape(
			width: spec.size.width,
			height: spec.size.height,
			bottomRadius: spec.bottomRadius,
			shoulder: spec.shoulder
		)

		ZStack(alignment: .top) {
			shape.fill(Palette.notch)
			content(layout: layout)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
				// The growing shape reveals the content instead of it popping in.
				.clipShape(shape)
		}
		.frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .top)
		.ignoresSafeArea()
		.environment(\.colorScheme, .dark)
	}

	@ViewBuilder
	private func content(layout: OverlayLayout) -> some View {
		switch model.state.content {
		case .none:
			EmptyView()

		case .waveform:
			belowNotch(layout: layout) {
				PixelWaveform(levels: model.levels, phase: waveformPhase)
			}
			.transition(.opacity)

		case .tick:
			belowNotch(layout: layout) {
				PixelTick(since: model.stateSince)
			}
			.transition(.opacity.combined(with: .scale(scale: 0.8)))

		case .message:
			if case .message(let text) = model.state {
				belowNotch(layout: layout) {
					Text(text)
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(Palette.ink)
						.lineLimit(1)
						.minimumScaleFactor(0.8)
						.padding(.horizontal, 18)
						// A new line while one is showing (download progress) swaps in place.
						.contentTransition(.opacity)
				}
				.transition(.opacity)
			}

		case .meeting:
			if case .recording(let since) = model.state {
				meeting(since: since, layout: layout)
					.transition(.opacity)
			}
		}
	}

	private var waveformPhase: PixelWaveform.Phase {
		model.state == .working ? .working(since: model.stateSince) : .listening
	}

	private func belowNotch(layout: OverlayLayout, @ViewBuilder content: () -> some View) -> some View {
		VStack(spacing: 0) {
			Color.clear.frame(height: layout.topBand)
			content()
				.frame(height: OverlayLayout.strip)
				// Optical center: the rounded bottom makes true center look low.
				.offset(y: -1)
		}
	}

	@ViewBuilder
	private func meeting(since: Date, layout: OverlayLayout) -> some View {
		let height = layout.spec(for: model.state).size.height
		if let notch = layout.geometry.notch {
			// Wings on either side; the camera sits in the middle.
			HStack(spacing: 0) {
				MeetingDot()
					.frame(width: OverlayLayout.wing, alignment: .center)
					.offset(x: 4)
				Color.clear.frame(width: notch.width)
				MeetingTimer(since: since)
					.frame(width: OverlayLayout.wing, alignment: .center)
					.offset(x: -4)
			}
			.frame(height: height)
		} else {
			HStack(spacing: 8) {
				MeetingDot()
				MeetingTimer(since: since, size: 14)
			}
			.frame(height: height)
		}
	}
}
