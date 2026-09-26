#if DEBUG
import Foundation

/// Speech-shaped input levels, for reviewing the waveform without a mic:
/// syllables at ~4.5 Hz inside phrases, with short pauses between them.
struct FakeLevels {
	private var time: Double = 0
	private var phraseEnds: Double = 0
	private var pauseEnds: Double = 0
	private var phraseLoudness: Double = 0.8
	private var generator = SystemRandomNumberGenerator()

	static let rate: Double = 30

	/// A stream that runs until the consumer stops listening.
	static func stream() -> AsyncStream<Float> {
		AsyncStream { continuation in
			let task = Task {
				var levels = FakeLevels()
				while !Task.isCancelled {
					continuation.yield(levels.next())
					try? await Task.sleep(for: .seconds(1 / rate))
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	mutating func next() -> Float {
		time += 1 / Self.rate
		if time >= pauseEnds, time >= phraseEnds {
			let phrase = Double.random(in: 1.2...2.6, using: &generator)
			phraseEnds = time + phrase
			pauseEnds = phraseEnds + Double.random(in: 0.2...0.55, using: &generator)
			phraseLoudness = Double.random(in: 0.7...1, using: &generator)
		}
		guard time < phraseEnds else {
			return Float(Double.random(in: 0...0.05, using: &generator))
		}
		let syllable = pow(abs(sin(time * .pi * 4.5)), 1.4)
		let jitter = Double.random(in: 0.75...1, using: &generator)
		return Float(phraseLoudness * (0.25 + 0.75 * syllable) * jitter)
	}
}
#endif
