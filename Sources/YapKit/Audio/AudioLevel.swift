import Foundation

/// RMS and peak of a run of samples, in dBFS. Used by diagnostics and the
/// Settings mic check; the waveform uses `AudioChunk.level`.
public struct AudioLevel: Sendable, Equatable {
	public var rms: Float
	public var peak: Float

	public init(_ samples: some Collection<Float>) {
		var sumSquares: Double = 0
		var peak: Float = 0
		for sample in samples {
			sumSquares += Double(sample * sample)
			peak = max(peak, abs(sample))
		}
		rms = samples.isEmpty ? 0 : Float((sumSquares / Double(samples.count)).squareRoot())
		self.peak = peak
	}

	/// -infinity for digital silence.
	public var rmsDBFS: Float { Self.dbfs(rms) }
	public var peakDBFS: Float { Self.dbfs(peak) }

	public static func dbfs(_ amplitude: Float) -> Float {
		amplitude > 0 ? 20 * log10(amplitude) : -.infinity
	}
}
