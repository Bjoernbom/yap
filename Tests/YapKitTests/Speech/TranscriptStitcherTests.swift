import Testing
@testable import YapKit

/// Words as "text@start-end" in seconds from the chunk start, e.g.
/// `words("vi@0.1-0.3 får@0.3-0.6")`.
private func transcript(_ spec: String) -> Transcript {
	let words = spec.split(separator: " ").map { item -> TimedWord in
		let parts = item.split(separator: "@")
		let times = parts[1].split(separator: "-")
		return TimedWord(text: String(parts[0]), start: Double(times[0])!, end: Double(times[1])!)
	}
	return Transcript(text: words.map(\.text).joined(separator: " "), confidence: 1, words: words)
}

/// Two chunks around a cut at 5 s with 1 s overlap: the left one covers
/// 0–6 s and keeps 0–5, the right one starts at 4 s and keeps from 1 s in.
private let leftKeep = 0.0..<5.0
private let rightStart = 4.0
private let rightKeep = 1.0..<Double.infinity

@Suite("Stitching overlapping chunks")
struct TranscriptStitcherTests {
	@Test func eachWordComesFromTheSideOfTheCutItIsOn() {
		var stitcher = TranscriptStitcher()
		// The left chunk garbles its last word at the edge; the right one
		// makes something up for the half word it starts in.
		_ = stitcher.add(
			transcript("vi@4.0-4.3 får@4.3-4.7 ut@4.7-4.9 den@5.1-5.4 nya@5.4-5.9 versio.@5.9-6.0"),
			start: 0, keep: leftKeep)
		_ = stitcher.add(
			transcript("Får@0.2-0.7 ut@0.7-0.9 den@1.1-1.4 nya@1.4-1.8 versionen.@1.8-2.6"),
			start: rightStart, keep: rightKeep)
		#expect(stitcher.finish() == "vi får ut den nya versionen.")
	}

	@Test func aWordTimedAcrossTheCutByBothChunksComesOutOnce() {
		var stitcher = TranscriptStitcher()
		// Left hears "den" ending before the cut, right hears it starting
		// after: without dedupe this is "den den".
		_ = stitcher.add(transcript("får@4.3-4.6 ut@4.6-4.8 den@4.8-5.1"), start: 0, keep: leftKeep)
		_ = stitcher.add(transcript("den@0.95-1.3 nya@1.3-1.8"), start: rightStart, keep: rightKeep)
		#expect(stitcher.finish() == "får ut den nya")
	}

	@Test func aRealRepeatAcrossTheCutIsKept() {
		var stitcher = TranscriptStitcher()
		_ = stitcher.add(transcript("tänker@4.2-4.6 att@4.7-4.9"), start: 0, keep: leftKeep)
		_ = stitcher.add(transcript("att@1.0-1.2 vi@1.2-1.4"), start: rightStart, keep: rightKeep)
		#expect(stitcher.finish() == "tänker att att vi")
	}

	@Test func wordsTheRightChunkSkippedAreFilledFromTheLeftOne() {
		var stitcher = TranscriptStitcher()
		// The right chunk starts mid-sentence and jumps to the next sentence
		// start, 1.5 s after the cut.
		_ = stitcher.add(
			transcript("och@4.5-4.7 arbetade@4.7-5.3 med@5.3-5.5 dokumentation.@5.5-6.0"),
			start: 0, keep: leftKeep)
		_ = stitcher.add(transcript("Jag@2.5-2.7 vet@2.7-3.0"), start: rightStart, keep: rightKeep)
		#expect(stitcher.finish() == "och arbetade med dokumentation. Jag vet")
	}

	@Test func theLeftChunksOverlapIsNotUsedWhenTheRightChunkHasIt() {
		var stitcher = TranscriptStitcher()
		_ = stitcher.add(transcript("steg@4.2-4.6 är@4.6-4.8 att@5.2-5.4"), start: 0, keep: leftKeep)
		_ = stitcher.add(transcript("att@1.1-1.4 sammanfatta@1.4-2.2"), start: rightStart, keep: rightKeep)
		#expect(stitcher.finish() == "steg är att sammanfatta")
	}

	@Test func aSilentTailStillGetsTheOverlapWords() {
		var stitcher = TranscriptStitcher()
		_ = stitcher.add(transcript("hej@4.0-4.5 då@5.2-5.6"), start: 0, keep: leftKeep)
		_ = stitcher.add(Transcript(text: "", confidence: 1), start: rightStart, keep: rightKeep)
		#expect(stitcher.finish() == "hej då")
	}

	@Test func chunksCutAtPausesAreJoinedWhole() {
		var stitcher = TranscriptStitcher()
		let everything = 0.0..<Double.infinity
		_ = stitcher.add(transcript("Hej@0.1-0.4 där.@0.4-0.8"), start: 0, keep: everything)
		_ = stitcher.add(transcript("Hur@0.2-0.4 mår@0.4-0.6 du?@0.6-0.9"), start: 3, keep: everything)
		#expect(stitcher.finish() == "Hej där. Hur mår du?")
	}

	@Test func anEngineWithoutTimingsFallsBackToItsText() {
		var stitcher = TranscriptStitcher()
		_ = stitcher.add(Transcript(text: "c0", confidence: 1), start: 0, keep: leftKeep)
		_ = stitcher.add(Transcript(text: "c1", confidence: 1), start: rightStart, keep: rightKeep)
		#expect(stitcher.finish() == "c0 c1")
	}

	@Test func addReturnsWhatTheChunkContributed() {
		var stitcher = TranscriptStitcher()
		let left = stitcher.add(transcript("vi@4.0-4.3 får@4.3-4.7 ut@5.1-5.4"), start: 0, keep: leftKeep)
		let right = stitcher.add(transcript("ut@1.1-1.4 den@1.4-1.7"), start: rightStart, keep: rightKeep)
		#expect(left == "vi får")
		#expect(right == "ut den")
	}
}
