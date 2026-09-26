import Foundation
import Synchronization

/// Carries audio from Core Audio's realtime IO thread to the thread that
/// resamples it, without locks or allocation on the realtime side.
///
/// It is a single-producer, single-consumer queue of fixed-size slots. Each
/// slot holds one mono run of samples plus the host time of its first sample
/// and the rate it was captured at, so the consumer can timestamp chunks and
/// notice device changes. When the consumer falls behind, the producer drops
/// the incoming audio (it never blocks the IO thread) and marks the next slot
/// it does write as a discontinuity.
package final class RingBuffer: @unchecked Sendable {
	/// One slot as seen by the consumer. `samples` is valid only inside the
	/// `drain` callback.
	package struct Slot {
		package var samples: UnsafeBufferPointer<Float>
		package var hostTime: UInt64
		package var sampleRate: Double
		/// Audio before this slot was lost or came from another device.
		package var discontinuity: Bool
	}

	package let slotCount: Int
	package let slotFrames: Int

	// Preallocated once; @unchecked Sendable is sound because a slot is only
	// touched by the producer before it is published via `head` and only by the
	// consumer after that, until the consumer releases it via `tail`.
	private let storage: UnsafeMutablePointer<Float>
	private let frames: UnsafeMutablePointer<Int>
	private let hostTimes: UnsafeMutablePointer<UInt64>
	private let rates: UnsafeMutablePointer<Double>
	private let breaks: UnsafeMutablePointer<Bool>

	/// Monotonic counters; slot index is `counter % slotCount`.
	private let head = Atomic<Int>(0)
	private let tail = Atomic<Int>(0)
	private let pendingBreak = Atomic<Bool>(true)
	private let droppedFrames = Atomic<Int>(0)

	package init(slotCount: Int, slotFrames: Int) {
		precondition(slotCount > 0 && slotFrames > 0)
		self.slotCount = slotCount
		self.slotFrames = slotFrames
		storage = .allocate(capacity: slotCount * slotFrames)
		storage.initialize(repeating: 0, count: slotCount * slotFrames)
		frames = .allocate(capacity: slotCount)
		frames.initialize(repeating: 0, count: slotCount)
		hostTimes = .allocate(capacity: slotCount)
		hostTimes.initialize(repeating: 0, count: slotCount)
		rates = .allocate(capacity: slotCount)
		rates.initialize(repeating: 0, count: slotCount)
		breaks = .allocate(capacity: slotCount)
		breaks.initialize(repeating: false, count: slotCount)
	}

	deinit {
		storage.deallocate()
		frames.deallocate()
		hostTimes.deallocate()
		rates.deallocate()
		breaks.deallocate()
	}

	/// Frames the producer had to throw away because the queue was full.
	package var dropped: Int { droppedFrames.load(ordering: .relaxed) }

	/// Slots waiting for the consumer.
	package var count: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }

	// MARK: Producer (realtime thread)

	/// Copies `frameCount` frames of channel 0 from `source`. `stride` is the
	/// distance between frames in floats (1 for deinterleaved audio, the channel
	/// count for interleaved). Runs longer than a slot are split, with each
	/// piece's host time advanced by its offset.
	/// - Returns: false if some audio was dropped because the queue was full.
	@discardableResult
	package func write(
		_ source: UnsafePointer<Float>,
		frameCount: Int,
		stride: Int = 1,
		hostTime: UInt64,
		sampleRate: Double,
		ticksPerSecond: Double
	) -> Bool {
		var offset = 0
		while offset < frameCount {
			let h = head.load(ordering: .relaxed)
			let t = tail.load(ordering: .acquiring)
			guard h - t < slotCount else {
				droppedFrames.add(frameCount - offset, ordering: .relaxed)
				pendingBreak.store(true, ordering: .relaxed)
				return false
			}
			let slot = h % slotCount
			let n = min(slotFrames, frameCount - offset)
			let destination = storage + slot * slotFrames
			if stride == 1 {
				destination.update(from: source + offset, count: n)
			} else {
				for i in 0..<n { destination[i] = source[(offset + i) * stride] }
			}
			frames[slot] = n
			hostTimes[slot] = hostTime &+ UInt64(Double(offset) / sampleRate * ticksPerSecond)
			rates[slot] = sampleRate
			breaks[slot] = pendingBreak.exchange(false, ordering: .relaxed)
			head.store(h + 1, ordering: .releasing)
			offset += n
		}
		return true
	}

	// MARK: Consumer

	/// Hands every waiting slot to `body` in order and frees it afterwards.
	/// - Returns: the number of slots consumed.
	@discardableResult
	package func drain(_ body: (Slot) -> Void) -> Int {
		var t = tail.load(ordering: .relaxed)
		let h = head.load(ordering: .acquiring)
		let start = t
		while t < h {
			let slot = t % slotCount
			body(Slot(
				samples: UnsafeBufferPointer(start: storage + slot * slotFrames, count: frames[slot]),
				hostTime: hostTimes[slot],
				sampleRate: rates[slot],
				discontinuity: breaks[slot]
			))
			t += 1
			tail.store(t, ordering: .releasing)
		}
		return t - start
	}

	// MARK: Control (only while the producer is stopped)

	/// Throws away anything queued and flags the next write as a new segment.
	/// Call only while no IO callback can run, i.e. with the engine stopped.
	package func reset() {
		tail.store(head.load(ordering: .acquiring), ordering: .releasing)
		pendingBreak.store(true, ordering: .relaxed)
		droppedFrames.store(0, ordering: .relaxed)
	}

	/// Flags the next write as a new segment (e.g. after switching devices).
	package func markDiscontinuity() {
		pendingBreak.store(true, ordering: .relaxed)
	}
}
