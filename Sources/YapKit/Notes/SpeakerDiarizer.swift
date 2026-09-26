import FluidAudio
import Foundation

/// One diarized stretch of the "them" track: who spoke when, in seconds of
/// the track's stream.
public struct SpeakerTurn: Sendable, Equatable {
	public var speaker: String
	public var start: Double
	public var end: Double

	public init(speaker: String, start: Double, end: Double) {
		self.speaker = speaker
		self.start = start
		self.end = end
	}
}

/// Tells the voices on the "them" track apart after the meeting.
public protocol SpeakerDiarizing: Sendable {
	/// Downloads and compiles the models; called when notes start so the
	/// first stop doesn't wait for a download.
	func prepare() async throws
	func diarize(_ recording: TrackRecording) async throws -> [SpeakerTurn]
}

/// FluidAudio's offline pipeline (pyannote segmentation + WeSpeaker
/// embeddings + VBx clustering) on Core ML. Offline rather than streaming
/// because it runs once after stop, sees the whole meeting when clustering,
/// and reads the audio from a memory-mapped file.
public struct FluidSpeakerDiarizer: SpeakerDiarizing {
	public init() {}

	/// FluidAudio's defaults, except that embeddings are skipped for windows
	/// whose speaker mask barely changed. FluidAudio documents ≤ 1 pp DER for
	/// it; the embedding model is the slow part and meetings are long.
	static var configuration: OfflineDiarizerConfig {
		var configuration = OfflineDiarizerConfig.default
		configuration.embedding.skipStrategy = .maskSimilarity(threshold: 0.95)
		return configuration
	}

	public func prepare() async throws {
		try await OfflineDiarizerManager(config: Self.configuration).prepareModels()
	}

	public func diarize(_ recording: TrackRecording) async throws -> [SpeakerTurn] {
		// A fresh manager per call: it isn't Sendable, and loading from the
		// compile cache is cheap next to diarizing a meeting.
		let manager = OfflineDiarizerManager(config: Self.configuration)
		try await manager.prepareModels()
		let source = PCMSampleSource(pcm: try recording.mappedSamples())
		let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0)
		return result.segments.map {
			SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
		}
	}
}

private struct PCMSampleSource: AudioSampleSource {
	let pcm: MappedPCM

	var sampleCount: Int { pcm.count }

	func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
		pcm.copy(into: destination, offset: offset, count: count)
	}
}

/// Gives each "them" word a speaker from the diarized turns and cuts a
/// segment where the speaker changes. Pure, so it can be tested with
/// made-up turns.
struct SpeakerAssignment {
	/// A word outside every turn takes the nearest one within this many
	/// seconds; further away it keeps the previous word's speaker.
	static let reach = 1.0
	/// A speaker stretch shorter than this inside a chunk joins its
	/// neighbour. Turn edges from the diarizer are off by up to a second, and
	/// without this a sentence gets cut around its first or last words.
	static let minimumRun = 1.5

	private let turns: [SpeakerTurn]
	/// Diarizer ids → "speaker 1", "speaker 2" in order of first appearance
	/// in the transcript.
	private(set) var numbers: [String: Int] = [:]

	init(turns: [SpeakerTurn]) {
		self.turns = turns.sorted { $0.start < $1.start }
	}

	/// Splits one run of words (stream time) into runs of one speaker each.
	mutating func split(_ words: [TimedWord]) -> [(speaker: Int?, words: [TimedWord])] {
		var runs: [(id: String?, words: [TimedWord])] = []
		var previous: String?
		for word in words {
			let id = speakerID(at: (word.start + word.end) / 2) ?? previous
			previous = id
			if let last = runs.last, last.id == id {
				runs[runs.count - 1].words.append(word)
			} else {
				runs.append((id, [word]))
			}
		}
		// Absorb short stretches, shortest first, until every one is long
		// enough or one is left. Each pass removes a run, so this ends.
		while runs.count > 1,
		      let short = runs.indices.filter({ Self.duration(runs[$0].words) < Self.minimumRun })
		      .min(by: { Self.duration(runs[$0].words) < Self.duration(runs[$1].words) }) {
			let target = short == 0 ? 1 : short - 1
			let words = short < target ? runs[short].words + runs[target].words : runs[target].words + runs[short].words
			runs[target].words = words
			runs.remove(at: short)
			// Neighbours may now share a speaker.
			var index = 1
			while index < runs.count {
				if runs[index].id == runs[index - 1].id {
					runs[index - 1].words += runs[index].words
					runs.remove(at: index)
				} else {
					index += 1
				}
			}
		}
		return runs.map { (speaker: $0.id.map { number(for: $0) }, words: $0.words) }
	}

	/// The speaker who talked most within `range`, for text without timings.
	mutating func dominantSpeaker(in range: ClosedRange<Double>) -> Int? {
		var talk: [String: Double] = [:]
		for turn in turns {
			let overlap = min(turn.end, range.upperBound) - max(turn.start, range.lowerBound)
			if overlap > 0 { talk[turn.speaker, default: 0] += overlap }
		}
		let id = talk.max(by: { $0.value < $1.value })?.key ?? speakerID(at: (range.lowerBound + range.upperBound) / 2)
		return id.map { number(for: $0) }
	}

	private func speakerID(at time: Double) -> String? {
		if let turn = turns.first(where: { $0.start <= time && time <= $0.end }) {
			return turn.speaker
		}
		let nearest = turns.min { distance($0, time) < distance($1, time) }
		guard let nearest, distance(nearest, time) <= Self.reach else { return nil }
		return nearest.speaker
	}

	private func distance(_ turn: SpeakerTurn, _ time: Double) -> Double {
		time < turn.start ? turn.start - time : time - turn.end
	}

	private static func duration(_ words: [TimedWord]) -> Double {
		guard let first = words.first, let last = words.last else { return 0 }
		return last.end - first.start
	}

	private mutating func number(for id: String) -> Int {
		if let number = numbers[id] { return number }
		let number = numbers.count + 1
		numbers[id] = number
		return number
	}
}
