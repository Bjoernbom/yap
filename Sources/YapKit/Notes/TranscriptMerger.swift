/// Turns chunk-sized segments into readable paragraphs: consecutive segments
/// from the same speaker become one.
enum TranscriptMerger {
	/// A pause longer than this starts a new paragraph even for the same
	/// speaker, so a timestamp still says roughly where something was said.
	static let maxGap = 30.0
	/// A paragraph never spans more than this, for the same reason.
	static let maxLength = 120.0

	static func merge(_ segments: [NoteSegment], maxGap: Double = maxGap, maxLength: Double = maxLength) -> [NoteSegment] {
		var merged: [NoteSegment] = []
		for segment in sortedByStart(segments) {
			let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { continue }
			if var last = merged.last,
			   last.speaker == segment.speaker,
			   segment.start - last.end <= maxGap,
			   segment.end - last.start <= maxLength {
				last.text = TranscriptJoiner.join([last.text, text])
				last.end = max(last.end, segment.end)
				last.words += segment.words
				merged[merged.count - 1] = last
			} else {
				var paragraph = segment
				paragraph.text = text
				merged.append(paragraph)
			}
		}
		return merged
	}

	/// Stable, so two segments starting together keep their track order.
	static func sortedByStart(_ segments: [NoteSegment]) -> [NoteSegment] {
		segments.enumerated()
			.sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
			.map(\.element)
	}
}
