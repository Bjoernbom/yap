import Foundation
import Testing
@testable import YapKit

/// A 1 MHz fake host clock keeps the arithmetic readable: 1 tick = 1 µs.
private let tps: Double = 1_000_000

private func sine(_ frequency: Double, rate: Double, seconds: Double, amplitude: Float) -> [Float] {
	(0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}

/// Feeds `samples` in `slotFrames` pieces with gap-free host times starting at `start`.
private func feed(
	_ assembler: ChunkAssembler,
	_ samples: [Float],
	rate: Double,
	slotFrames: Int,
	start: UInt64,
	discontinuityFirst: Bool = false,
	collect chunks: inout [AudioChunk]
) {
	samples.withUnsafeBufferPointer { all in
		var offset = 0
		while offset < all.count {
			let n = min(slotFrames, all.count - offset)
			let slot = RingBuffer.Slot(
				samples: UnsafeBufferPointer(rebasing: all[offset..<offset + n]),
				hostTime: start + UInt64(Double(offset) / rate * tps),
				sampleRate: rate,
				discontinuity: discontinuityFirst && offset == 0
			)
			assembler.append(slot)
			offset += n
			// Take chunks every other slot, like the pump does on its timer.
			if (offset / slotFrames) % 2 == 0 { chunks += assembler.takeChunks() }
		}
	}
}

@Suite struct ChunkAssemblerTests {
	@Test func resamples48kTo16kPreservingLevelAndPitch() {
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		var chunks: [AudioChunk] = []
		feed(assembler, sine(440, rate: 48_000, seconds: 1, amplitude: 0.5), rate: 48_000, slotFrames: 512, start: 1_000_000, collect: &chunks)
		chunks += assembler.takeChunks(endOfStream: true)

		let out = chunks.flatMap(\.samples)
		#expect(abs(out.count - 16_000) <= 2)
		// Skip the filter edges when measuring.
		let middle = Array(out[800..<15_200])
		let rms = AudioLevel(middle).rms
		#expect(abs(rms - Float(0.5 / 2.0.squareRoot())) < 0.005)
		var crossings = 0
		for i in 1..<middle.count where (middle[i - 1] < 0) != (middle[i] < 0) { crossings += 1 }
		// 440 Hz over 0.9 s crosses zero ~792 times.
		#expect(abs(crossings - 792) <= 4)
	}

	@Test func chunkHostTimesFollowSampleCount() {
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		var chunks: [AudioChunk] = []
		let start: UInt64 = 5_000_000
		feed(assembler, sine(200, rate: 48_000, seconds: 0.5, amplitude: 0.1), rate: 48_000, slotFrames: 480, start: start, collect: &chunks)
		chunks += assembler.takeChunks(endOfStream: true)

		#expect(chunks.count > 5)
		#expect(chunks.first?.hostTime == start)
		var before = 0
		for chunk in chunks {
			let expected = Double(start) + Double(before) / 16_000 * tps
			#expect(abs(Double(chunk.hostTime) - expected) <= 1, "chunk at sample \(before)")
			before += chunk.samples.count
		}
	}

	@Test func impulseLandsAtTheRightTime() {
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		var input = [Float](repeating: 0, count: 48_000)
		input[24_000] = 1 // 0.5 s in
		var chunks: [AudioChunk] = []
		let start: UInt64 = 10_000_000
		feed(assembler, input, rate: 48_000, slotFrames: 1024, start: start, collect: &chunks)
		chunks += assembler.takeChunks(endOfStream: true)

		// Find the output peak and its host time.
		var peakTime: Double = 0
		var peak: Float = 0
		for chunk in chunks {
			for (i, sample) in chunk.samples.enumerated() where abs(sample) > peak {
				peak = abs(sample)
				peakTime = Double(chunk.hostTime) + Double(i) / 16_000 * tps
			}
		}
		#expect(peak > 0.1)
		// Within one output sample (62.5 µs) of 0.5 s.
		#expect(abs(peakTime - (Double(start) + 500_000)) <= 63)
	}

	@Test func followsDeviceClockDrift() {
		// Device clock runs 1 % slow relative to the host: each 480-frame slot
		// advances host time by 10.1 ms instead of 10 ms. Chunks should track it.
		let assembler = ChunkAssembler(ticksPerSecond: tps, tolerance: 0.005)
		let samples = sine(300, rate: 48_000, seconds: 1, amplitude: 0.1)
		var chunks: [AudioChunk] = []
		samples.withUnsafeBufferPointer { all in
			for (k, offset) in stride(from: 0, to: all.count, by: 480).enumerated() {
				assembler.append(RingBuffer.Slot(
					samples: UnsafeBufferPointer(rebasing: all[offset..<offset + 480]),
					hostTime: UInt64(k) * 10_100,
					sampleRate: 48_000,
					discontinuity: false
				))
				if k % 3 == 2 { chunks += assembler.takeChunks() }
			}
		}
		chunks += assembler.takeChunks(endOfStream: true)
		let last = chunks.last(where: { !$0.samples.isEmpty })
		var before = 0
		for chunk in chunks.dropLast() { before += chunk.samples.count }
		// The last chunk starts `before` output samples in; that is `before * 3`
		// input frames, i.e. slot index before*3/480 at 10.1 ms per slot. Inside
		// a slot the nominal rate is used, so allow 1 % of one slot (~100 µs);
		// ignoring the drift entirely would be off by ~10 ms here.
		let expected = Double(before * 3) / 480 * 10_100
		#expect(abs(Double(last?.hostTime ?? 0) - expected) < 110)
	}

	@Test func discontinuityStartsNewSegmentWithoutLosingAudio() {
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		var chunks: [AudioChunk] = []
		feed(assembler, sine(440, rate: 48_000, seconds: 0.2, amplitude: 0.3), rate: 48_000, slotFrames: 512, start: 0, collect: &chunks)
		let firstSegment = chunks.flatMap(\.samples).count + assembler.takeChunks().flatMap(\.samples).count
		chunks.removeAll()
		// Device switch: new rate, host time 1 s later, flagged by the ring.
		feed(assembler, sine(440, rate: 44_100, seconds: 0.2, amplitude: 0.3), rate: 44_100, slotFrames: 441, start: 1_000_000, discontinuityFirst: true, collect: &chunks)
		chunks += assembler.takeChunks(endOfStream: true)

		// The flush of segment one arrives with the first chunks of segment two.
		let total = firstSegment + chunks.flatMap(\.samples).count
		#expect(abs(total - 6_400) <= 4)
		let secondStart = chunks.first { $0.hostTime >= 1_000_000 }
		#expect(secondStart?.hostTime == 1_000_000)
	}

	@Test func hostTimeJumpStartsNewSegment() {
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		let a = sine(440, rate: 48_000, seconds: 0.1, amplitude: 0.2)
		var chunks: [AudioChunk] = []
		feed(assembler, a, rate: 48_000, slotFrames: 480, start: 0, collect: &chunks)
		// Same rate, no flag, but 50 ms of audio is missing.
		feed(assembler, a, rate: 48_000, slotFrames: 480, start: 150_000, collect: &chunks)
		chunks += assembler.takeChunks(endOfStream: true)
		#expect(chunks.contains { $0.hostTime == 150_000 })
	}

	@Test func passesThrough16k() {
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		var chunks: [AudioChunk] = []
		let input = sine(1_000, rate: 16_000, seconds: 0.25, amplitude: 0.4)
		feed(assembler, input, rate: 16_000, slotFrames: 160, start: 0, collect: &chunks)
		chunks += assembler.takeChunks(endOfStream: true)
		#expect(chunks.flatMap(\.samples).count == input.count)
	}

	@Test func emptyAssemblerYieldsNothing() {
		let assembler = ChunkAssembler(ticksPerSecond: tps)
		#expect(assembler.takeChunks().isEmpty)
		#expect(assembler.takeChunks(endOfStream: true).isEmpty)
	}
}

@Suite struct RingBufferTests {
	@Test func deliversInOrderWithHostTimes() {
		let ring = RingBuffer(slotCount: 8, slotFrames: 4)
		let data: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
		// 10 frames at 1 Hz on a 1 MHz clock: pieces start 4 s and 8 s later.
		_ = data.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 10, hostTime: 100, sampleRate: 1, ticksPerSecond: tps) }
		var seen: [([Float], UInt64, Bool)] = []
		let n = ring.drain { seen.append((Array($0.samples), $0.hostTime, $0.discontinuity)) }
		#expect(n == 3)
		#expect(seen.map(\.0) == [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
		#expect(seen.map(\.1) == [100, 4_000_100, 8_000_100])
		// The very first write starts a segment.
		#expect(seen.map(\.2) == [true, false, false])
		#expect(ring.drain { _ in } == 0)
	}

	@Test func dropsWhenFullAndFlagsTheNextWrite() {
		let ring = RingBuffer(slotCount: 2, slotFrames: 2)
		let data: [Float] = [1, 2]
		data.withUnsafeBufferPointer { p in
			for i in 0..<3 {
				ring.write(p.baseAddress!, frameCount: 2, hostTime: UInt64(i), sampleRate: 1, ticksPerSecond: 1)
			}
		}
		#expect(ring.dropped == 2)
		#expect(ring.drain { _ in } == 2)
		_ = data.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 2, hostTime: 9, sampleRate: 1, ticksPerSecond: 1) }
		var flags: [Bool] = []
		ring.drain { flags.append($0.discontinuity) }
		#expect(flags == [true])
	}

	@Test func takesChannelZeroFromInterleavedAudio() {
		let ring = RingBuffer(slotCount: 4, slotFrames: 8)
		let stereo: [Float] = [1, -1, 2, -2, 3, -3]
		_ = stereo.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 3, stride: 2, hostTime: 0, sampleRate: 1, ticksPerSecond: 1) }
		var got: [Float] = []
		ring.drain { got += Array($0.samples) }
		#expect(got == [1, 2, 3])
	}

	@Test func resetDiscardsQueuedAudio() {
		let ring = RingBuffer(slotCount: 4, slotFrames: 2)
		let data: [Float] = [1, 2]
		_ = data.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 2, hostTime: 0, sampleRate: 1, ticksPerSecond: 1) }
		ring.reset()
		#expect(ring.count == 0)
		_ = data.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: 2, hostTime: 5, sampleRate: 1, ticksPerSecond: 1) }
		var flags: [Bool] = []
		ring.drain { flags.append($0.discontinuity) }
		#expect(flags == [true])
	}

	@Test func concurrentProducerAndConsumerKeepEverySample() async {
		let ring = RingBuffer(slotCount: 64, slotFrames: 128)
		let total = 200_000
		let producer = Task.detached {
			var buffer = [Float](repeating: 0, count: 100)
			var next = 0
			while next < total {
				let n = min(100, total - next)
				for i in 0..<n { buffer[i] = Float(next + i) }
				let ok = buffer.withUnsafeBufferPointer { ring.write($0.baseAddress!, frameCount: n, hostTime: 0, sampleRate: 1, ticksPerSecond: 1) }
				if ok { next += n } else { await Task.yield() }
			}
		}
		var received: [Float] = []
		received.reserveCapacity(total)
		while received.count < total {
			ring.drain { received += Array($0.samples) }
			await Task.yield()
		}
		await producer.value
		// A failed write drops audio and is retried from the same offset here, so
		// the stream must still be exactly 0, 1, 2, ...
		#expect(received.count == total)
		#expect(received.enumerated().allSatisfy { Float($0.offset) == $0.element })
	}
}

@Suite struct AudioLevelTests {
	@Test func fullScaleSineIsMinus3dB() {
		let level = AudioLevel(sine(1_000, rate: 48_000, seconds: 1, amplitude: 1))
		#expect(abs(level.rmsDBFS - -3.01) < 0.02)
		#expect(abs(level.peakDBFS) < 0.01)
	}

	@Test func silenceIsMinusInfinity() {
		let level = AudioLevel([Float](repeating: 0, count: 160))
		#expect(level.rmsDBFS == -.infinity)
		#expect(AudioLevel([Float]()).rms == 0)
	}

	@Test func chunkLevelMapsMinus60To0dB() {
		#expect(AudioChunk(samples: [Float](repeating: 1, count: 16), hostTime: 0).level == 1)
		#expect(AudioChunk(samples: [Float](repeating: 0.001, count: 16), hostTime: 0).level == 0)
		let minus30 = AudioChunk(samples: [Float](repeating: pow(10, -30 / 20), count: 16), hostTime: 0).level
		#expect(abs(minus30 - 0.5) < 0.001)
	}

	@Test func hostClockRoundTrips() {
		let ticks = HostClock.ticks(seconds: 0.25)
		#expect(abs(HostClock.seconds(ticks) - 0.25) < 1e-6)
		#expect(abs(HostClock.milliseconds(from: 0, to: ticks) - 250) < 0.001)
	}
}
