import Database from '@tauri-apps/plugin-sql'

let db: Database | null = null

export async function getDb(): Promise<Database> {
	if (!db) {
		db = await Database.get('sqlite:voice-thing.db')
	}
	return db
}

export async function initDb(): Promise<void> {
	const database = await getDb()

	await database.execute(`
		CREATE TABLE IF NOT EXISTS dictations (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			text TEXT NOT NULL,
			language TEXT DEFAULT 'en',
			duration_ms INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL
		)
	`)

	await database.execute(`
		CREATE TABLE IF NOT EXISTS settings (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)
	`)
}

export interface DbDictation {
	id: number
	text: string
	language: string
	duration_ms: number
	created_at: string
}

export async function insertDictation(dictation: {
	text: string
	language: string
	durationMs: number
}): Promise<number> {
	const database = await getDb()
	const result = await database.execute(
		`INSERT INTO dictations (text, language, duration_ms, created_at)
		 VALUES ($1, $2, $3, $4)`,
		[dictation.text, dictation.language, dictation.durationMs, new Date().toISOString()],
	)
	return result.lastInsertId ?? 0
}

export async function deleteDictation(id: number): Promise<void> {
	const database = await getDb()
	await database.execute('DELETE FROM dictations WHERE id = $1', [id])
}

export async function clearAllDictations(): Promise<void> {
	const database = await getDb()
	await database.execute('DELETE FROM dictations')
}

export async function getAllDictations(): Promise<DbDictation[]> {
	const database = await getDb()
	return await database.select<DbDictation[]>(
		'SELECT * FROM dictations ORDER BY created_at DESC',
	)
}
