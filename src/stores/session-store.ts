import { create } from 'zustand'
import * as db from '@/lib/db'
import type { TranscriptSegment, SpeakerInfo } from '@/lib/db'

export type { TranscriptSegment, SpeakerInfo }

export interface Session {
	id: string
	type: 'note' | 'meeting'
	title: string
	summary: string | null
	transcript: string | null
	cleanedTranscript: string | null
	actionItems: string[]
	audioPath: string | null
	duration: number
	status: 'recording' | 'transcribing' | 'structuring' | 'ready' | 'error'
	createdAt: string
	errorMessage: string | null
	segmentedTranscript: TranscriptSegment[] | null
	keyDecisions: string[]
	speakers: SpeakerInfo[]
}

interface SessionStore {
	sessions: Session[]
	loadSessions: () => Promise<void>
	addSession: (params: {
		id: string
		type: 'note' | 'meeting'
		duration: number
		audioPath: string | null
	}) => Promise<void>
	updateSession: (id: string, updates: Partial<Session>) => Promise<void>
	deleteSession: (id: string) => Promise<void>
	getSession: (id: string) => Session | undefined
	searchSessions: (query: string) => Promise<void>
}

function dbToSession(row: db.DbSession): Session {
	return {
		id: row.id,
		type: row.type as 'note' | 'meeting',
		title: row.title,
		summary: row.summary,
		transcript: row.transcript,
		cleanedTranscript: row.cleaned_transcript,
		actionItems: row.action_items ? JSON.parse(row.action_items) : [],
		audioPath: row.audio_path,
		duration: row.duration,
		status: row.status as Session['status'],
		createdAt: row.created_at,
		errorMessage: row.error_message,
		segmentedTranscript: row.segmented_transcript ? JSON.parse(row.segmented_transcript) : null,
		keyDecisions: row.key_decisions ? JSON.parse(row.key_decisions) : [],
		speakers: row.speakers ? JSON.parse(row.speakers) : [],
	}
}

export const useSessionStore = create<SessionStore>((set, get) => ({
	sessions: [],

	loadSessions: async () => {
		const rows = await db.getAllSessions()
		set({ sessions: rows.map(dbToSession) })
	},

	addSession: async ({ id, type, duration, audioPath }) => {
		const session: Session = {
			id,
			type,
			title: type === 'note' ? 'Voice Note' : 'Meeting Recording',
			summary: null,
			transcript: null,
			cleanedTranscript: null,
			actionItems: [],
			audioPath,
			duration,
			status: 'transcribing',
			createdAt: new Date().toISOString(),
			errorMessage: null,
			segmentedTranscript: null,
			keyDecisions: [],
			speakers: [],
		}

		await db.insertSession({
			id: session.id,
			type: session.type,
			title: session.title,
			duration: session.duration,
			status: session.status,
			createdAt: session.createdAt,
			audioPath: session.audioPath,
		})

		set((state) => ({
			sessions: [session, ...state.sessions],
		}))
	},

	updateSession: async (id, updates) => {
		await db.updateSession(id, updates)
		set((state) => ({
			sessions: state.sessions.map((s) =>
				s.id === id ? { ...s, ...updates } : s,
			),
		}))
	},

	deleteSession: async (id) => {
		await db.deleteSession(id)
		set((state) => ({
			sessions: state.sessions.filter((s) => s.id !== id),
		}))
	},

	getSession: (id) => get().sessions.find((s) => s.id === id),

	searchSessions: async (query) => {
		if (!query.trim()) {
			const rows = await db.getAllSessions()
			set({ sessions: rows.map(dbToSession) })
			return
		}
		const rows = await db.searchSessions(query)
		set({ sessions: rows.map(dbToSession) })
	},
}))
