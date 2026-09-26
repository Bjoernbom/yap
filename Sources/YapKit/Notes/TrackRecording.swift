import Foundation

/// The "them" track's audio on disk, kept only so the diarizer can run after
/// the meeting. Raw 16 kHz mono Int16, no header: 115 MB per hour, written
/// as it arrives so memory stays flat, and deleted once the note is done
/// (the plan: audio is deleted unless the user opts in to keeping it).
///
/// The file holds exactly what the transcriber was fed, gap silence
/// included, so a time in the file is a time in the transcriber's stream and
/// diarized turns line up with word timings without any mapping.
public final class TrackRecorder {
	public let url: URL
	private var handle: FileHandle?
	public private(set) var sampleCount = 0
	public private(set) var failed = false

	public init(directory: URL) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		url = directory.appending(path: "yap-them-\(UUID().uuidString).pcm")
		guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
		}
		handle = try FileHandle(forWritingTo: url)
	}

	/// A failed write (disk full) stops recording but never the meeting:
	/// the note then skips diarization.
	public func append(_ samples: [Float]) {
		guard let handle, !failed, !samples.isEmpty else { return }
		// Clamped first: converting NaN or an out-of-range float to an
		// integer traps.
		let pcm = samples.map { Int16((($0.isFinite ? min(max($0, -1), 1) : 0) * 32767).rounded()) }
		let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
		do {
			try handle.write(contentsOf: data)
			sampleCount += samples.count
		} catch {
			failed = true
		}
	}

	public func close() {
		try? handle?.close()
		handle = nil
	}

	public func delete() {
		close()
		try? FileManager.default.removeItem(at: url)
		// The folder is ours (yap-notes in the temp directory); leave nothing
		// behind once it's empty.
		let directory = url.deletingLastPathComponent()
		if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
			try? FileManager.default.removeItem(at: directory)
		}
	}

	public var recording: TrackRecording {
		TrackRecording(url: url, sampleCount: sampleCount)
	}
}

/// A finished recording, as handed to the diarizer.
public struct TrackRecording: Sendable {
	public var url: URL
	public var sampleCount: Int

	public var duration: Double { Double(sampleCount) / AudioChunk.sampleRate }

	/// Memory-maps the file: reading three hours of audio costs page cache,
	/// not 700 MB of floats.
	public func mappedSamples() throws -> MappedPCM {
		MappedPCM(data: try Data(contentsOf: url, options: .alwaysMapped))
	}
}

/// Int16 samples from a mapped file, converted to Float on read.
public struct MappedPCM: Sendable {
	let data: Data

	public var count: Int { data.count / MemoryLayout<Int16>.stride }

	public func copy(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) {
		let start = max(0, offset)
		let available = min(self.count - start, count)
		guard available > 0 else { return }
		data.withUnsafeBytes { raw in
			let samples = raw.bindMemory(to: Int16.self)
			for index in 0..<available {
				destination[index] = Float(samples[start + index]) / 32767
			}
		}
	}
}
