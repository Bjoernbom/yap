import SwiftUI

/// The speech model's download, quietly, under every onboarding step. It
/// starts at launch (`DictationController`), so by "try it" it's usually done.
struct ModelStatusBar: View {
	let dictation: DictationController

	/// Parakeet TDT v3 Ultra, measured in spike M0. FluidAudio reports only a
	/// fraction, so megabytes are that fraction of this.
	static let downloadMegabytes = 603.0

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				label
				Spacer(minLength: 8)
				trailing
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			if let fraction = barFraction {
				Bar(fraction: fraction)
			}
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel("Speech model")
		.accessibilityValue(accessibilityValue)
		.animation(.easeOut(duration: 0.25), value: dictation.modelStatus)
	}

	/// Nil hides the bar: nothing is moving.
	private var barFraction: Double?? {
		switch dictation.modelStatus {
		case .loading(let fraction): .some(fraction)
		case .ready, .failed: nil
		}
	}

	@ViewBuilder
	private var label: some View {
		switch dictation.modelStatus {
		case .loading(let fraction?):
			Text("Downloading the speech model · \(Self.megabytes(fraction)) of \(Int(Self.downloadMegabytes)) MB")
		case .loading(nil):
			Text("Warming up the speech model…")
		case .ready:
			Label("Speech model ready", systemImage: "checkmark")
				.labelStyle(.titleAndIcon)
		case .failed:
			Text(dictation.modelFailedOffline
				? "You're offline. The speech model needs one download."
				: "Couldn't get the speech model.")
		}
	}

	@ViewBuilder
	private var trailing: some View {
		switch dictation.modelStatus {
		case .loading(let fraction?):
			Text("\(Self.percent(fraction))%")
				.font(BrandFont.pixel(16))
				.monospacedDigit()
				.foregroundStyle(.primary)
		case .failed:
			Button("Try again") { dictation.retryModel() }
				.controlSize(.small)
		case .loading(nil), .ready:
			EmptyView()
		}
	}

	private var accessibilityValue: String {
		switch dictation.modelStatus {
		case .loading(let fraction?): "Downloading, \(Self.percent(fraction)) percent"
		case .loading(nil): "Warming up"
		case .ready: "Ready"
		case .failed: dictation.modelFailedOffline ? "Offline" : "Failed"
		}
	}

	static func percent(_ fraction: Double) -> Int {
		Int((fraction * 100).rounded())
	}

	private static func megabytes(_ fraction: Double) -> Int {
		Int((fraction * downloadMegabytes).rounded())
	}

	/// A hairline track; indeterminate (a sliding segment) while compiling.
	private struct Bar: View {
		let fraction: Double?
		@Environment(\.accessibilityReduceMotion) private var reduceMotion

		var body: some View {
			GeometryReader { proxy in
				let width = proxy.size.width
				ZStack(alignment: .leading) {
					Capsule().fill(Color.primary.opacity(0.1))
					if let fraction {
						Capsule()
							.fill(Color.primary)
							.frame(width: max(3, width * min(max(fraction, 0), 1)))
							.animation(.easeOut(duration: 0.3), value: fraction)
					} else if reduceMotion {
						Capsule().fill(Color.primary.opacity(0.35))
					} else {
						TimelineView(.animation) { timeline in
							let period = 1.6
							let phase = timeline.date.timeIntervalSinceReferenceDate
								.truncatingRemainder(dividingBy: period) / period
							Capsule()
								.fill(Color.primary.opacity(0.6))
								.frame(width: width * 0.28)
								.offset(x: (width * 1.28) * phase - width * 0.28)
						}
						.clipShape(Capsule())
					}
				}
			}
			.frame(height: 3)
		}
	}
}
