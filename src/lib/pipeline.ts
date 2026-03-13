import { invoke } from '@tauri-apps/api/core'
import { useSessionStore } from '@/stores/session-store'
import { getSetting } from '@/lib/settings'
import type { TranscriptSegment, SpeakerInfo } from '@/lib/db'

export async function processSession(
	sessionId: string,
	audioPath: string,
	existingTranscript?: string,
): Promise<void> {
	const { updateSession } = useSessionStore.getState()

	try {
		let transcript = existingTranscript

		if (!transcript) {
			await updateSession(sessionId, { status: 'transcribing' })
			const modelName = await getSetting('whisper_model') || 'large-v3-turbo'
			const language = await getSetting('whisper_language') || null
			transcript = await invoke<string>('transcribe_cmd', { audioPath, modelName, language })
			await updateSession(sessionId, { transcript })
		}

		const apiKey = await getSetting('api_key')

		if (apiKey && transcript) {
			await updateSession(sessionId, { status: 'structuring' })

			const result = await invoke<{
				title: string
				summary: string | null
				cleaned_transcript: string
				action_items: string[]
			}>('structure_transcript', { apiKey, transcript })

			await updateSession(sessionId, {
				title: result.title,
				summary: result.summary,
				cleanedTranscript: result.cleaned_transcript,
				actionItems: result.action_items,
				status: 'ready',
			})
		} else {
			await updateSession(sessionId, { status: 'ready' })
		}
	} catch (err) {
		const message = err instanceof Error ? err.message : String(err)
		await updateSession(sessionId, {
			status: 'error',
			errorMessage: message,
		})
	}
}

export async function processMeetingSession(
	sessionId: string,
	micPath: string,
	systemPath: string,
): Promise<void> {
	const { updateSession } = useSessionStore.getState()

	try {
		// 1. Transcribe + diarize
		await updateSession(sessionId, { status: 'transcribing' })
		const modelName = await getSetting('whisper_model') || 'large-v3-turbo'
		const language = await getSetting('whisper_language') || null

		const result = await invoke<{
			text: string
			segments: Array<{
				text: string
				start_ms: number
				end_ms: number
				source: string | null
				speaker_label: string | null
			}>
		}>('transcribe_meeting_cmd', { micPath, systemPath, modelName, language })

		const segments: TranscriptSegment[] = result.segments.map((s) => ({
			text: s.text,
			startMs: s.start_ms,
			endMs: s.end_ms,
			source: s.source,
			speakerLabel: s.speaker_label,
		}))

		await updateSession(sessionId, {
			transcript: result.text,
			segmentedTranscript: segments,
		})

		// 2. AI structuring
		const apiKey = await getSetting('api_key')

		if (apiKey && segments.length > 0) {
			await updateSession(sessionId, { status: 'structuring' })

			const meetingResult = await invoke<{
				title: string
				summary: string | null
				cleaned_transcript: string
				action_items: Array<{ text: string; assignee: string | null }>
				speakers: Array<{ label: string; suggested_name: string | null; role: string | null }>
				key_decisions: string[]
			}>('structure_meeting_cmd', {
				apiKey,
				segments: result.segments,
			})

			const speakers: SpeakerInfo[] = meetingResult.speakers.map((s) => ({
				label: s.label,
				suggestedName: s.suggested_name,
				role: s.role,
			}))

			await updateSession(sessionId, {
				title: meetingResult.title,
				summary: meetingResult.summary,
				cleanedTranscript: meetingResult.cleaned_transcript,
				actionItems: meetingResult.action_items.map((a) =>
					a.assignee ? `${a.text} (@${a.assignee})` : a.text,
				),
				speakers,
				keyDecisions: meetingResult.key_decisions,
				status: 'ready',
			})
		} else {
			await updateSession(sessionId, { status: 'ready' })
		}
	} catch (err) {
		const message = err instanceof Error ? err.message : String(err)
		await updateSession(sessionId, {
			status: 'error',
			errorMessage: message,
		})
	}
}
