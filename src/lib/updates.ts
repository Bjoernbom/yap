const REPO = 'Bjoernbom/yap'
const CURRENT_VERSION = '0.2.0'

export interface UpdateInfo {
	available: boolean
	version: string
	url: string
}

export async function checkForUpdates(): Promise<UpdateInfo> {
	const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`)
	if (!res.ok) return { available: false, version: CURRENT_VERSION, url: '' }
	const data = await res.json()
	const latest = data.tag_name?.replace('v', '') || CURRENT_VERSION
	return {
		available: latest !== CURRENT_VERSION,
		version: latest,
		url: data.html_url || `https://github.com/${REPO}/releases/latest`,
	}
}
