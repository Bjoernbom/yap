import { create } from 'zustand'

export interface Session {
	id: string
	type: 'note' | 'meeting'
	title: string
	summary: string | null
	transcript: string | null
	actionItems: string[]
	audioPath: string | null
	audioBlob: Blob | null
	duration: number
	status: 'recording' | 'processing' | 'ready' | 'error'
	createdAt: string
}

interface SessionStore {
	sessions: Session[]
	addSession: (params: {
		type: 'note' | 'meeting'
		audioBlob: Blob
		duration: number
	}) => void
	updateSession: (id: string, updates: Partial<Session>) => void
	deleteSession: (id: string) => void
	getSession: (id: string) => Session | undefined
}

export const useSessionStore = create<SessionStore>((set, get) => ({
	sessions: [],

	addSession: ({ type, audioBlob, duration }) => {
		const session: Session = {
			id: crypto.randomUUID(),
			type,
			title: type === 'note' ? 'Voice Note' : 'Meeting Recording',
			summary: null,
			transcript: null,
			actionItems: [],
			audioPath: null,
			audioBlob,
			duration,
			status: 'processing',
			createdAt: new Date().toISOString(),
		}

		set((state) => ({
			sessions: [session, ...state.sessions],
		}))

		// TODO: trigger transcription + AI processing pipeline
	},

	updateSession: (id, updates) =>
		set((state) => ({
			sessions: state.sessions.map((s) =>
				s.id === id ? { ...s, ...updates } : s,
			),
		})),

	deleteSession: (id) =>
		set((state) => ({
			sessions: state.sessions.filter((s) => s.id !== id),
		})),

	getSession: (id) => get().sessions.find((s) => s.id === id),
}))
