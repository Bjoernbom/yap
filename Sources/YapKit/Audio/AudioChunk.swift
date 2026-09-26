import Foundation

/// A run of 16 kHz mono Float32 samples, stamped with the host time of its
/// first sample so separate tracks can be lined up later.
public struct AudioChunk: Sendable, Equatable {
	public static let sampleRate: Double = 16_000

	public var samples: [Float]
	public var hostTime: UInt64

	public init(samples: [Float], hostTime: UInt64) {
		self.samples = samples
		self.hostTime = hostTime
	}

	public var duration: Double { Double(samples.count) / Self.sampleRate }

	/// Loudness in 0...1 for the waveform: RMS mapped from -60...0 dBFS.
	public var level: Float {
		guard !samples.isEmpty else { return 0 }
		let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
		guard meanSquare > 0 else { return 0 }
		let dbfs = 10 * log10(meanSquare)
		return min(max((dbfs + 60) / 60, 0), 1)
	}
}
