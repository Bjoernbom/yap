import Foundation

/// Who said something in a meeting.
public enum Speaker: Sendable, Hashable {
	/// The note taker, from the microphone track.
	case you
	/// The other side, from the system-audio track. The number is the
	/// diarized speaker (1, 2, …) or nil when diarization didn't run.
	case them(Int?)

	/// How the transcript labels the speaker.
	public var label: String {
		switch self {
		case .you: "you"
		case .them(let number?): "speaker \(number)"
		case .them(nil): "them"
		}
	}
}

/// One stretch of speech from one speaker.
public struct NoteSegment: Sendable, Equatable {
	public var speaker: Speaker
	/// Seconds from the start of the meeting, on host time, so the two
	/// tracks line up even when one of them had gaps.
	public var start: Double
	public var end: Double
	public var text: String
	/// The words of `text` in meeting time, when the engine gave timings.
	/// Echo removal uses them to tell the user's own words from the call's.
	public var words: [TimedWord]

	public init(speaker: Speaker, start: Double, end: Double, text: String, words: [TimedWord] = []) {
		self.speaker = speaker
		self.start = start
		self.end = end
		self.text = text
		self.words = words
	}
}

/// What the language model made of the meeting.
public struct MeetingSummary: Sendable, Equatable {
	public struct ActionItem: Sendable, Equatable {
		public var task: String
		/// A first name, "you", or nil when nobody took it on.
		public var owner: String?

		public init(task: String, owner: String? = nil) {
			self.task = task
			self.owner = owner
		}
	}

	public var title: String
	public var summary: String
	public var decisions: [String]
	public var actionItems: [ActionItem]

	public init(title: String, summary: String, decisions: [String] = [], actionItems: [ActionItem] = []) {
		self.title = title
		self.summary = summary
		self.decisions = decisions
		self.actionItems = actionItems
	}
}

/// A finished meeting, ready to be written down.
public struct Note: Sendable, Equatable {
	public var startedAt: Date
	/// Seconds from start to stop.
	public var duration: Double
	/// In time order, echo removed, "them" diarized when possible.
	public var segments: [NoteSegment]
	/// Nil when there is no summary; `notices` then says why.
	public var summary: MeetingSummary?
	/// Call apps in use during the meeting, for the front matter.
	public var apps: [String]
	/// One-line remarks for the reader: why the summary is missing, that
	/// only the microphone was recorded, and similar.
	public var notices: [String]

	public init(
		startedAt: Date, duration: Double, segments: [NoteSegment],
		summary: MeetingSummary? = nil, apps: [String] = [], notices: [String] = []
	) {
		self.startedAt = startedAt
		self.duration = duration
		self.segments = segments
		self.summary = summary
		self.apps = apps
		self.notices = notices
	}

	/// Nothing was said, so there is nothing worth a file.
	public var isEmpty: Bool {
		segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
	}
}
