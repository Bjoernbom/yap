import { getDb } from './db'

export async function getSetting(key: string): Promise<string | null> {
	const db = await getDb()
	const rows = await db.select<{ value: string }[]>(
		'SELECT value FROM settings WHERE key = $1',
		[key],
	)
	return rows[0]?.value ?? null
}

export async function setSetting(key: string, value: string): Promise<void> {
	const db = await getDb()
	await db.execute(
		'INSERT OR REPLACE INTO settings (key, value) VALUES ($1, $2)',
		[key, value],
	)
}

export async function deleteSetting(key: string): Promise<void> {
	const db = await getDb()
	await db.execute('DELETE FROM settings WHERE key = $1', [key])
}
