import { check } from '@tauri-apps/plugin-updater'
import { relaunch } from '@tauri-apps/plugin-process'

export interface UpdateInfo {
	available: boolean
	version: string
	url: string
}

export const CURRENT_VERSION = '0.3.0'

export async function checkForUpdates(): Promise<UpdateInfo> {
	try {
		const update = await check()
		if (update) {
			return {
				available: true,
				version: update.version,
				url: `https://github.com/Bjoernbom/yap/releases/tag/v${update.version}`,
			}
		}
	} catch {
		// Updater not available or network error
	}
	return { available: false, version: '', url: '' }
}

export async function downloadAndInstallUpdate(): Promise<void> {
	const update = await check()
	if (!update) return

	await update.downloadAndInstall()
	await relaunch()
}
