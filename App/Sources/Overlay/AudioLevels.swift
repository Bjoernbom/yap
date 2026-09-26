/// Recent input levels, newest first, smoothed for display. Read every frame
/// by the waveform, so it is deliberately not observable.
@MainActor
final class AudioLevels {
	static let count = 12

	private(set) var history = [Float](repeating: 0, count: count)
	private var envelope: Float = 0

	/// `level` is perceptual loudness in 0...1 (e.g. -50...0 dBFS mapped
	/// linearly), pushed at roughly 30 Hz.
	func push(_ level: Float) {
		let level = min(max(level, 0), 1)
		// Fast attack, slower release: syllables pop, pauses settle without flicker.
		envelope = level > envelope ? level : envelope * 0.4 + level * 0.6
		history.removeLast()
		history.insert(envelope, at: 0)
	}

	func reset() {
		history = [Float](repeating: 0, count: Self.count)
		envelope = 0
	}
}
