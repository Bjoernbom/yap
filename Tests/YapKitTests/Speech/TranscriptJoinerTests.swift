import Testing
@testable import YapKit

@Suite("Joining chunk texts")
struct TranscriptJoinerTests {
	@Test func joinsWithSingleSpacesAndDropsEmptyPieces() {
		let text = TranscriptJoiner.join(["Hej där.", "", "  Hur  mår du? ", "\n"])
		#expect(text == "Hej där. Hur mår du?")
	}

	@Test func nothingSaidIsEmpty() {
		#expect(TranscriptJoiner.join([]) == "")
		#expect(TranscriptJoiner.join(["", " "]) == "")
	}

	@Test func collapsesDoublePeriods() {
		#expect(TranscriptJoiner.join(["Vi har grannar..", "Nästa mening.."]) == "Vi har grannar. Nästa mening.")
	}

	@Test func keepsEllipsesAndSinglePeriods() {
		#expect(TranscriptJoiner.collapseDoublePeriods("Vänta... okej. 3.5 procent") == "Vänta... okej. 3.5 procent")
	}
}
