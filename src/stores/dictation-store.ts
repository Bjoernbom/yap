import { create } from 'zustand'
import * as db from '@/lib/db'

export interface Dictation {
	id: number
	text: string
	language: string
	durationMs: number
	createdAt: string
}

interface DictationStore {
	dictations: Dictation[]
	loadDictations: () => Promise<void>
	addDictation: (params: {
		text: string
		language: string
		durationMs: number
	}) => Promise<void>
	deleteDictation: (id: number) => Promise<void>
}

function dbToDictation(row: db.DbDictation): Dictation {
	return {
		id: row.id,
		text: row.text,
		language: row.language,
		durationMs: row.duration_ms,
		createdAt: row.created_at,
	}
}

export const useDictationStore = create<DictationStore>((set) => ({
	dictations: [],

	loadDictations: async () => {
		const rows = await db.getAllDictations()
		set({ dictations: rows.map(dbToDictation) })
	},

	addDictation: async ({ text, language, durationMs }) => {
		const id = await db.insertDictation({ text, language, durationMs })
		const dictation: Dictation = {
			id,
			text,
			language,
			durationMs,
			createdAt: new Date().toISOString(),
		}
		set((state) => ({
			dictations: [dictation, ...state.dictations],
		}))
	},

	deleteDictation: async (id) => {
		await db.deleteDictation(id)
		set((state) => ({
			dictations: state.dictations.filter((d) => d.id !== id),
		}))
	},
}))
