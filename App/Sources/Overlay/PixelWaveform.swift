import SwiftUI

/// The signature element: chunky pixel bars, mirrored around a center row.
/// The newest level sits in the middle bar and ripples outwards.
///
/// While working, the bars fold down to one row and a highlight sweeps
/// across it. Only lives while the notch is open, so idle costs nothing.
struct PixelWaveform: View {
	enum Phase: Equatable {
		case listening
		case working(since: Date)
	}

	let levels: AudioLevels
	let phase: Phase

	static let bars = AudioLevels.count * 2 - 1
	static let rows = 9
	/// Bars are one pixel wide with a one-pixel gap, so they read as bars.
	static let barPitch: CGFloat = 6
	private static let foldDuration: TimeInterval = 0.16
	private static let sweepDuration: TimeInterval = 1.1
	/// Fixed per-bar texture, so neighbours differ like a real waveform.
	private static let texture: [Float] = [
		0.82, 1, 0.7, 0.94, 0.78, 1, 0.86, 0.72, 0.98, 0.8, 0.9, 1,
		0.88, 0.74, 1, 0.84, 0.96, 0.7, 0.9, 1, 0.76, 0.92, 0.84,
	]

	var body: some View {
		TimelineView(.animation) { timeline in
			// Copy out on the main actor; the canvas only sees plain values.
			let history = levels.history
			let date = timeline.date
			let phase = phase
			Canvas { context, _ in
				Self.draw(in: context, history: history, phase: phase, at: date)
			}
		}
		.frame(width: PixelGrid.length(Self.bars, pitch: Self.barPitch), height: PixelGrid.length(Self.rows))
		.accessibilityHidden(true)
	}

	private static func draw(in context: GraphicsContext, history: [Float], phase: Phase, at date: Date) {
		let center = rows / 2
		let middle = bars / 2

		var fold: Double = 0
		var sweep: Double?
		if case .working(let since) = phase {
			let elapsed = max(date.timeIntervalSince(since), 0)
			fold = min(elapsed / foldDuration, 1)
			if elapsed > foldDuration {
				let progress = ((elapsed - foldDuration) / sweepDuration).truncatingRemainder(dividingBy: 1)
				// Travel from just off the left edge to just off the right one.
				sweep = -5 + Double(bars + 10) * progress
			}
		}

		for bar in 0..<bars {
			let distance = abs(bar - middle)
			let level = history[distance] * texture[bar % texture.count]
			let extent = Self.extent(level: level, distance: distance, max: center)

			if let sweep {
				let glow = exp(-pow((Double(bar) - sweep) / 2.2, 2))
				fill(context, bar: bar, row: center, color: Palette.ink.opacity(0.22 + 0.78 * glow))
				if glow > 0.5 {
					let bump = Palette.ink.opacity((glow - 0.5) / 0.5 * 0.6)
					fill(context, bar: bar, row: center - 1, color: bump)
					fill(context, bar: bar, row: center + 1, color: bump)
				}
				continue
			}

			let folded = Int((Double(extent) * (1 - fold)).rounded())
			// A silent bar is a dim dot, so the line reads as "listening, quiet".
			let color = extent == 0 && fold == 0
				? Palette.lime.opacity(0.45)
				: Palette.lime.mix(with: Palette.ink.opacity(0.22), by: fold)
			for row in (center - folded)...(center + folded) {
				fill(context, bar: bar, row: row, color: color)
			}
		}
	}

	private static func fill(_ context: GraphicsContext, bar: Int, row: Int, color: Color) {
		context.fillPixel(column: bar, row: row, with: color, columnPitch: barPitch)
	}

	/// Rows above (and below) the center row for a level at `distance` bars
	/// from the middle. Outer bars are damped so the shape tapers.
	private static func extent(level: Float, distance: Int, max: Int) -> Int {
		let edge = Float(distance) / Float(AudioLevels.count - 1)
		let taper = 1 - 0.5 * edge * edge
		// A gentle curve lifts normal speech into the upper rows.
		let value = pow(level, 0.8) * taper * Float(max)
		return min(max, Int(value.rounded()))
	}
}
