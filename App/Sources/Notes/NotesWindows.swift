import AppKit
import SwiftUI
import YapKit

/// The meeting as it's being transcribed. Follows the newest line unless the
/// user scrolled up to read.
struct LiveTranscriptView: View {
	let notes: NotesController

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			Divider()
			if notes.liveSegments.isEmpty {
				Text(notes.isRecording ? "Listening. Text shows up here as people talk." : "Not taking notes.")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollViewReader { proxy in
					ScrollView {
						LazyVStack(alignment: .leading, spacing: 10) {
							ForEach(Array(notes.liveSegments.enumerated()), id: \.offset) { index, segment in
								TranscriptLine(segment: segment).id(index)
							}
						}
						.padding(16)
						.textSelection(.enabled)
					}
					.defaultScrollAnchor(.bottom)
					.onChange(of: notes.liveSegments.count) { _, count in
						proxy.scrollTo(count - 1, anchor: .bottom)
					}
				}
			}
		}
		.frame(minWidth: 420, minHeight: 320)
	}

	private var header: some View {
		HStack(spacing: 8) {
			if case .recording(let since) = notes.phase {
				Circle().fill(Palette.recording).frame(width: 8, height: 8)
				Text(since, style: .timer).monospacedDigit()
			}
			if notes.isMicOnly {
				Text("Mic only: the other side of the call isn't recorded.")
					.foregroundStyle(.secondary)
			} else if notes.isSystemAudioBlocked {
				Text("Call audio is silent. Allow yap under Screen & System Audio Recording.")
					.foregroundStyle(.secondary)
			}
			Spacer()
			if notes.isRecording {
				Button("Stop notes") { notes.toggle() }
			}
		}
		.font(.callout)
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
	}
}

/// A finished note: the same sections as the Markdown file, rendered.
struct NoteView: View {
	let notes: NotesController
	@State private var copied = false

	var body: some View {
		Group {
			if let finished = notes.lastNote {
				content(finished)
			} else {
				Text("No note yet.")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.frame(minWidth: 520, minHeight: 440)
	}

	private func content(_ finished: FinishedNote) -> some View {
		let note = finished.note
		return VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					VStack(alignment: .leading, spacing: 4) {
						Text(finished.title).font(.title2.weight(.semibold))
						Text("\(note.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MarkdownWriter.clock(note.duration))")
							.foregroundStyle(.secondary)
					}
					ForEach(note.notices + [finished.written.fallbackNotice].compactMap { $0 }, id: \.self) { notice in
						Label(notice, systemImage: "info.circle")
							.foregroundStyle(.secondary)
					}
					if let summary = note.summary {
						section("Summary") { Text(summary.summary) }
						if !summary.decisions.isEmpty {
							section("Decisions") {
								ForEach(summary.decisions, id: \.self) { Text("• \($0)") }
							}
						}
						if !summary.actionItems.isEmpty {
							section("Action items") {
								ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
									Label(item.task + (item.owner.map { " (\($0))" } ?? ""), systemImage: "square")
								}
							}
						}
					}
					section("Transcript") {
						ForEach(Array(finished.paragraphs.enumerated()), id: \.offset) { _, segment in
							TranscriptLine(segment: segment)
						}
					}
				}
				.padding(20)
				.frame(maxWidth: .infinity, alignment: .leading)
				.textSelection(.enabled)
			}
			Divider()
			HStack {
				Text(finished.written.url.lastPathComponent)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer()
				Button(copied ? "Copied" : "Copy as Markdown") {
					let pasteboard = NSPasteboard.general
					pasteboard.clearContents()
					pasteboard.setString(finished.written.markdown, forType: .string)
					copied = true
				}
				Button("Show in Finder") {
					NSWorkspace.shared.activateFileViewerSelecting([finished.written.url])
				}
			}
			.padding(12)
		}
		.onChange(of: finished.written.url) { copied = false }
	}

	private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(.headline)
			content()
		}
	}
}

/// "speaker 1  [00:05]  text", the transcript line in both windows.
private struct TranscriptLine: View {
	let segment: NoteSegment

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 6) {
				Text(segment.speaker.label).fontWeight(.semibold)
				Text(MarkdownWriter.clock(segment.start))
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
			.font(.callout)
			Text(segment.text)
		}
	}
}

extension FinishedNote {
	/// Same paragraphs as the file.
	var paragraphs: [NoteSegment] { MarkdownWriter.paragraphs(of: note) }
}

/// Opens the notes windows when the controller asks. Attached to the menu
/// bar label, the one view that is always alive and has `openWindow`.
struct NotesWindowOpener: ViewModifier {
	let notes: NotesController
	@Environment(\.openWindow) private var openWindow

	func body(content: Content) -> some View {
		content.onChange(of: notes.windowRequest) { _, request in
			guard let request else { return }
			NSApp.activate()
			openWindow(id: request.id)
		}
	}
}
