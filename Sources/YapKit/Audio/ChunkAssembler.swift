import AVFoundation
import os

/// Turns mono slots at the device rate into 16 kHz `AudioChunk`s with the host
/// time of each chunk's first sample.
///
/// Audio is handled in segments. A segment is a run of gap-free input at one
/// sample rate, fed through one `AVAudioConverter` so the resampling filter
/// keeps its state across chunks. A new segment starts when the ring reports a
/// discontinuity (dropped audio, device switch), when the rate changes, or when
/// host times jump. The old segment is flushed first, so no audio is lost.
///
/// Timing: every input slot records (input frame index, host time). A chunk's
/// host time is interpolated from the latest record at or before its first
/// sample, so it follows the device clock instead of drifting with a nominal
/// rate on long captures. The converter uses `.normal` priming (zero latency),
/// so output frame n lines up with input frame n × rate / 16 kHz.
///
/// Not thread-safe: owned by one pump task.
package final class ChunkAssembler {
	package static let outputFormat: AVAudioFormat = {
		guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: false) else {
			preconditionFailure("16 kHz mono Float32 is always a valid format")
		}
		return format
	}()

	private static let log = Logger(subsystem: "com.bjornbom.yap", category: "audio")

	private let ticksPerSecond: Double
	/// Largest host-time jump between slots still treated as continuous.
	private let tolerance: Double

	private var converter: AVAudioConverter?
	private var input: AVAudioPCMBuffer?
	private var inputRate: Double = 0
	private var framesIn = 0
	private var framesOut = 0
	private var marks: [(frame: Int, hostTime: UInt64)] = []
	private var expectedHostTime: UInt64?
	private var ready: [AudioChunk] = []

	package init(ticksPerSecond: Double = HostClock.ticksPerSecond, tolerance: Double = 0.005) {
		self.ticksPerSecond = ticksPerSecond
		self.tolerance = tolerance
	}

	/// Queues one slot for conversion. Copies the samples, so the slot can be
	/// released right after.
	package func append(_ slot: RingBuffer.Slot) {
		guard slot.samples.count > 0, slot.sampleRate > 0 else { return }
		if startsNewSegment(slot) {
			finishSegment()
			beginSegment(rate: slot.sampleRate)
		}
		guard converter != nil else { return }
		let count = slot.samples.count
		if let input, Int(input.frameCapacity - input.frameLength) < count {
			convertPending(flush: false)
		}
		if input == nil || Int(input?.frameCapacity ?? 0) < count {
			let capacity = max(count, Int(inputRate / 4))
			input = AVAudioPCMBuffer(pcmFormat: Self.inputFormat(inputRate), frameCapacity: AVAudioFrameCount(capacity))
		}
		guard let input, let channel = input.floatChannelData?[0], let source = slot.samples.baseAddress else { return }
		(channel + Int(input.frameLength)).update(from: source, count: count)
		input.frameLength += AVAudioFrameCount(count)

		marks.append((framesIn, slot.hostTime))
		framesIn += count
		expectedHostTime = slot.hostTime &+ UInt64(Double(count) / slot.sampleRate * ticksPerSecond)
	}

	/// Converts everything queued so far and returns the finished chunks.
	/// With `endOfStream` the converter's filter tail is flushed too and the
	/// next `append` starts a fresh segment.
	package func takeChunks(endOfStream: Bool = false) -> [AudioChunk] {
		if endOfStream {
			finishSegment()
		} else {
			convertPending(flush: false)
		}
		defer { ready.removeAll(keepingCapacity: true) }
		return ready
	}

	/// Drains `ring` into this assembler and returns the finished chunks.
	package func consume(_ ring: RingBuffer, endOfStream: Bool = false) -> [AudioChunk] {
		ring.drain { append($0) }
		return takeChunks(endOfStream: endOfStream)
	}

	// MARK: Segments

	private func startsNewSegment(_ slot: RingBuffer.Slot) -> Bool {
		guard converter != nil, let expected = expectedHostTime else { return true }
		if slot.discontinuity || slot.sampleRate != inputRate { return true }
		return abs(Double(slot.hostTime) - Double(expected)) / ticksPerSecond > tolerance
	}

	private func beginSegment(rate: Double) {
		inputRate = rate
		converter = AVAudioConverter(from: Self.inputFormat(rate), to: Self.outputFormat)
		converter?.primeMethod = .normal
		if converter == nil { Self.log.error("no converter from \(rate) Hz to 16 kHz; dropping this segment") }
		if input?.format.sampleRate != rate { input = nil }
		framesIn = 0
		framesOut = 0
		marks.removeAll(keepingCapacity: true)
		expectedHostTime = nil
	}

	private func finishSegment() {
		convertPending(flush: true)
		converter = nil
		expectedHostTime = nil
	}

	private func convertPending(flush: Bool) {
		guard let converter else { return }
		let pending = Int(input?.frameLength ?? 0)
		guard pending > 0 || flush else { return }
		// Room for this input plus the filter tail that a flush releases.
		let capacity = Int((Double(pending) * AudioChunk.sampleRate / inputRate).rounded(.up)) + 1024
		guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else { return }

		// The input block is called synchronously inside convert(); these are
		// never touched from another thread.
		nonisolated(unsafe) var fed = pending == 0
		nonisolated(unsafe) let source = input
		var error: NSError?
		let status = converter.convert(to: output, error: &error) { _, outStatus in
			if !fed, let source {
				fed = true
				outStatus.pointee = .haveData
				return source
			}
			outStatus.pointee = flush ? .endOfStream : .noDataNow
			return nil
		}
		input?.frameLength = 0
		if status == .error {
			Self.log.error("resampling failed: \(String(describing: error), privacy: .public)")
			return
		}
		let n = Int(output.frameLength)
		guard n > 0, let data = output.floatChannelData?[0] else { return }
		ready.append(AudioChunk(samples: Array(UnsafeBufferPointer(start: data, count: n)), hostTime: hostTime(forOutputFrame: framesOut)))
		framesOut += n
	}

	/// Host time of output frame `n` of the current segment, from the latest
	/// input mark at or before it. Older marks are dropped as chunks advance.
	private func hostTime(forOutputFrame n: Int) -> UInt64 {
		let inputFrame = Double(n) * inputRate / AudioChunk.sampleRate
		guard !marks.isEmpty else { return 0 }
		var index = 0
		while index + 1 < marks.count, Double(marks[index + 1].frame) <= inputFrame { index += 1 }
		if index > 0 { marks.removeFirst(index) }
		let mark = marks[0]
		let offset = max(inputFrame - Double(mark.frame), 0)
		return mark.hostTime &+ UInt64(offset / inputRate * ticksPerSecond)
	}

	private static func inputFormat(_ rate: Double) -> AVAudioFormat {
		guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
			preconditionFailure("mono Float32 at a positive rate is always valid")
		}
		return format
	}
}
