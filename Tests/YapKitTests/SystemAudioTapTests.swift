import CoreAudio
import Foundation
import Testing
@testable import YapKit

/// A 1 MHz fake host clock: 1 tick = 1 µs.
private let tps: Double = 1_000_000

/// Calls the IOProc body with `frames` frames of `channels`-channel
/// interleaved audio, like the tap's aggregate device does.
private func deliver(_ interleaved: [Float], channels: Int, hostTime: UInt64, rate: Double, ring: RingBuffer, meter: TapMeter) {
	var data = interleaved
	data.withUnsafeMutableBytes { bytes in
		var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
		var time = AudioTimeStamp()
		time.mHostTime = hostTime
		time.mFlags = .hostTimeValid
		SystemAudioTap.ingest(&list, inputTime: time, sampleRate: rate, ticksPerSecond: tps, ring: ring, meter: meter)
	}
}

private func tone(rate: Double, seconds: Double, amplitude: Float) -> [Float] {
	(0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * 440 * Double($0) / rate)) }
}

@Suite struct SystemAudioTapTests {
	@Test func monoTapAt48kBecomes16kChunks() {
		let ring = RingBuffer(slotCount: 256, slotFrames: 1024)
		let meter = TapMeter()
		let samples = tone(rate: 48_000, seconds: 1, amplitude: 0.25)
		for start in stride(from: 0, to: samples.count, by: 512) {
			let piece = Array(samples[start..<min(start + 512, samples.count)])
			deliver(piece, channels: 1, hostTime: 2_000_000 + UInt64(Double(start) / 48_000 * tps), rate: 48_000, ring: ring, meter: meter)
		}
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		let chunks = assembler.consume(ring, endOfStream: true)
		let out = chunks.flatMap(\.samples)
		#expect(abs(out.count - 16_000) <= 2)
		#expect(chunks.first?.hostTime == 2_000_000)
		let rms = AudioLevel(Array(out[800..<15_200])).rms
		#expect(abs(rms - Float(0.25 / 2.0.squareRoot())) < 0.005)

		let snapshot = meter.snapshot()
		#expect(snapshot.callbacks == 94) // 48 000 / 512, rounded up
		#expect(snapshot.audibleCallbacks == 94)
		#expect(abs(snapshot.peak - 0.25) < 0.001)
		#expect(snapshot.firstHostTime == 2_000_000)
	}

	@Test func interleavedStereoKeepsChannelZero() {
		let ring = RingBuffer(slotCount: 16, slotFrames: 1024)
		let meter = TapMeter()
		// Left 0.5, right -0.9: only the left channel should reach the ring,
		// but the meter sees the loudest sample of either.
		let frames = 480
		let interleaved = (0..<frames).flatMap { _ in [Float(0.5), Float(-0.9)] }
		deliver(interleaved, channels: 2, hostTime: 1_000, rate: 48_000, ring: ring, meter: meter)
		var copied: [Float] = []
		ring.drain { copied += Array($0.samples) }
		#expect(copied.count == frames)
		#expect(copied.allSatisfy { $0 == 0.5 })
		#expect(meter.snapshot().peak == Float(0.9))
	}

	/// Nothing playing means no callbacks at all. The gap must stay a gap in
	/// host time, not be filled with invented silence.
	@Test func gapsBetweenCallbacksAreNotFilled() {
		let ring = RingBuffer(slotCount: 64, slotFrames: 1024)
		let meter = TapMeter()
		let burst = tone(rate: 48_000, seconds: 0.1, amplitude: 0.1)
		deliver(burst, channels: 1, hostTime: 1_000_000, rate: 48_000, ring: ring, meter: meter)
		// Two seconds later: the next sound.
		deliver(burst, channels: 1, hostTime: 3_100_000, rate: 48_000, ring: ring, meter: meter)
		let chunks = ChunkAssembler(ticksPerSecond: tps).consume(ring, endOfStream: true)
		let total = chunks.reduce(0) { $0 + $1.samples.count }
		#expect(abs(total - 3_200) <= 4) // 2 × 0.1 s at 16 kHz, no gap samples
		let second = chunks.first { $0.hostTime >= 3_100_000 }
		#expect(second?.hostTime == 3_100_000)
	}

	@Test func silentBuffersCountAsCallbacksButNotAudible() {
		let ring = RingBuffer(slotCount: 64, slotFrames: 1024)
		let meter = TapMeter()
		for i in 0..<10 {
			deliver([Float](repeating: 0, count: 512), channels: 1, hostTime: UInt64(i) * 10_667, rate: 48_000, ring: ring, meter: meter)
		}
		let snapshot = meter.snapshot()
		#expect(snapshot.callbacks == 10)
		#expect(snapshot.audibleCallbacks == 0)
		#expect(snapshot.peak == 0)
		meter.reset()
		#expect(meter.snapshot().callbacks == 0)
	}

	@Test func looksBlockedNeedsZerosWhileSomethingPlays() {
		let enough = SystemAudioTap.blockedAfterCallbacks
		#expect(SystemAudioTap.looksBlocked(callbacks: enough, audibleCallbacks: 0, coveredProcessIsPlaying: true))
		// Real audio arrived: not blocked.
		#expect(!SystemAudioTap.looksBlocked(callbacks: enough, audibleCallbacks: 1, coveredProcessIsPlaying: true))
		// Nobody plays: zeros are just silence.
		#expect(!SystemAudioTap.looksBlocked(callbacks: enough, audibleCallbacks: 0, coveredProcessIsPlaying: false))
		// Too early to tell.
		#expect(!SystemAudioTap.looksBlocked(callbacks: enough - 1, audibleCallbacks: 0, coveredProcessIsPlaying: true))
		#expect(!SystemAudioTap.looksBlocked(callbacks: 0, audibleCallbacks: 0, coveredProcessIsPlaying: true))
	}
}
