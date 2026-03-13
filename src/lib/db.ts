import Database from '@tauri-apps/plugin-sql'

let db: Database | null = null

async function getDb(): Promise<Database> {
	if (!db) {
		db = await Database.get('sqlite:voice-thing.db')
	}
	return db
}

export async function initDb(): Promise<void> {
	const database = await getDb()

	await database.execute(`
		CREATE TABLE IF NOT EXISTS sessions (
			rowid INTEGER PRIMARY KEY AUTOINCREMENT,
			id TEXT UNIQUE NOT NULL,
			type TEXT NOT NULL DEFAULT 'note',
			title TEXT NOT NULL,
			summary TEXT,
			transcript TEXT,
			cleaned_transcript TEXT,
			action_items TEXT,
			audio_path TEXT,
			duration INTEGER NOT NULL DEFAULT 0,
			status TEXT NOT NULL DEFAULT 'processing',
			created_at TEXT NOT NULL,
			error_message TEXT
		)
	`)

	// Migration: add cleaned_transcript column if missing
	try {
		await database.execute(`ALTER TABLE sessions ADD COLUMN cleaned_transcript TEXT`)
	} catch {
		// Column already exists
	}

	// Migration: add segmented_transcript column
	try {
		await database.execute(`ALTER TABLE sessions ADD COLUMN segmented_transcript TEXT`)
	} catch {
		// Column already exists
	}

	// Migration: add key_decisions column
	try {
		await database.execute(`ALTER TABLE sessions ADD COLUMN key_decisions TEXT`)
	} catch {
		// Column already exists
	}

	// Migration: add speakers column
	try {
		await database.execute(`ALTER TABLE sessions ADD COLUMN speakers TEXT`)
	} catch {
		// Column already exists
	}

	await database.execute(`
		CREATE TABLE IF NOT EXISTS settings (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)
	`)

	await database.execute(`
		CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
			title, summary, transcript, cleaned_transcript,
			content='sessions', content_rowid='rowid'
		)
	`)

	await database.execute(`
		CREATE TRIGGER IF NOT EXISTS sessions_ai AFTER INSERT ON sessions BEGIN
			INSERT INTO sessions_fts(rowid, title, summary, transcript, cleaned_transcript)
			VALUES (new.rowid, new.title, new.summary, new.transcript, new.cleaned_transcript);
		END
	`)

	await database.execute(`
		CREATE TRIGGER IF NOT EXISTS sessions_ad AFTER DELETE ON sessions BEGIN
			INSERT INTO sessions_fts(sessions_fts, rowid, title, summary, transcript, cleaned_transcript)
			VALUES ('delete', old.rowid, old.title, old.summary, old.transcript, old.cleaned_transcript);
		END
	`)

	await database.execute(`
		CREATE TRIGGER IF NOT EXISTS sessions_au AFTER UPDATE ON sessions BEGIN
			INSERT INTO sessions_fts(sessions_fts, rowid, title, summary, transcript, cleaned_transcript)
			VALUES ('delete', old.rowid, old.title, old.summary, old.transcript, old.cleaned_transcript);
			INSERT INTO sessions_fts(rowid, title, summary, transcript, cleaned_transcript)
			VALUES (new.rowid, new.title, new.summary, new.transcript, new.cleaned_transcript);
		END
	`)
}

export interface DbSession {
	rowid: number
	id: string
	type: string
	title: string
	summary: string | null
	transcript: string | null
	cleaned_transcript: string | null
	action_items: string | null
	audio_path: string | null
	duration: number
	status: string
	created_at: string
	error_message: string | null
	segmented_transcript: string | null
	key_decisions: string | null
	speakers: string | null
}

export async function insertSession(session: {
	id: string
	type: string
	title: string
	duration: number
	status: string
	createdAt: string
	audioPath: string | null
}): Promise<void> {
	const database = await getDb()
	await database.execute(
		`INSERT INTO sessions (id, type, title, duration, status, created_at, audio_path)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		[session.id, session.type, session.title, session.duration, session.status, session.createdAt, session.audioPath],
	)
}

export async function updateSession(
	id: string,
	updates: Partial<{
		title: string
		summary: string | null
		transcript: string | null
		cleanedTranscript: string | null
		actionItems: string[]
		audioPath: string | null
		duration: number
		status: string
		errorMessage: string | null
		segmentedTranscript: TranscriptSegment[] | null
		keyDecisions: string[]
		speakers: SpeakerInfo[]
	}>,
): Promise<void> {
	const database = await getDb()
	const setClauses: string[] = []
	const values: unknown[] = []
	let paramIndex = 1

	if (updates.title !== undefined) {
		setClauses.push(`title = $${paramIndex++}`)
		values.push(updates.title)
	}
	if (updates.summary !== undefined) {
		setClauses.push(`summary = $${paramIndex++}`)
		values.push(updates.summary)
	}
	if (updates.transcript !== undefined) {
		setClauses.push(`transcript = $${paramIndex++}`)
		values.push(updates.transcript)
	}
	if (updates.cleanedTranscript !== undefined) {
		setClauses.push(`cleaned_transcript = $${paramIndex++}`)
		values.push(updates.cleanedTranscript)
	}
	if (updates.actionItems !== undefined) {
		setClauses.push(`action_items = $${paramIndex++}`)
		values.push(JSON.stringify(updates.actionItems))
	}
	if (updates.audioPath !== undefined) {
		setClauses.push(`audio_path = $${paramIndex++}`)
		values.push(updates.audioPath)
	}
	if (updates.duration !== undefined) {
		setClauses.push(`duration = $${paramIndex++}`)
		values.push(updates.duration)
	}
	if (updates.status !== undefined) {
		setClauses.push(`status = $${paramIndex++}`)
		values.push(updates.status)
	}
	if (updates.errorMessage !== undefined) {
		setClauses.push(`error_message = $${paramIndex++}`)
		values.push(updates.errorMessage)
	}
	if (updates.segmentedTranscript !== undefined) {
		setClauses.push(`segmented_transcript = $${paramIndex++}`)
		values.push(updates.segmentedTranscript ? JSON.stringify(updates.segmentedTranscript) : null)
	}
	if (updates.keyDecisions !== undefined) {
		setClauses.push(`key_decisions = $${paramIndex++}`)
		values.push(JSON.stringify(updates.keyDecisions))
	}
	if (updates.speakers !== undefined) {
		setClauses.push(`speakers = $${paramIndex++}`)
		values.push(JSON.stringify(updates.speakers))
	}

	if (setClauses.length === 0) return

	values.push(id)
	await database.execute(
		`UPDATE sessions SET ${setClauses.join(', ')} WHERE id = $${paramIndex}`,
		values,
	)
}

export interface TranscriptSegment {
	text: string
	startMs: number
	endMs: number
	source: string | null
	speakerLabel: string | null
}

export interface SpeakerInfo {
	label: string
	suggestedName: string | null
	role: string | null
}

export async function deleteSession(id: string): Promise<void> {
	const database = await getDb()
	await database.execute('DELETE FROM sessions WHERE id = $1', [id])
}

export async function getAllSessions(): Promise<DbSession[]> {
	const database = await getDb()
	return await database.select<DbSession[]>(
		'SELECT * FROM sessions ORDER BY created_at DESC',
	)
}

export async function getSessionById(id: string): Promise<DbSession | null> {
	const database = await getDb()
	const rows = await database.select<DbSession[]>(
		'SELECT * FROM sessions WHERE id = $1',
		[id],
	)
	return rows[0] ?? null
}

export async function searchSessions(query: string): Promise<DbSession[]> {
	const database = await getDb()
	return await database.select<DbSession[]>(
		`SELECT sessions.* FROM sessions
		 JOIN sessions_fts ON sessions.rowid = sessions_fts.rowid
		 WHERE sessions_fts MATCH $1
		 ORDER BY rank`,
		[`"${query.replace(/"/g, '""')}"*`],
	)
}
