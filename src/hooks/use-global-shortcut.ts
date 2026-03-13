import { useEffect } from 'react'
import { register, unregister } from '@tauri-apps/plugin-global-shortcut'
import { emit } from '@tauri-apps/api/event'

export function useGlobalShortcut() {
	useEffect(() => {
		const shortcuts = [
			{ key: 'CommandOrControl+Shift+R', event: 'toggle-recording' },
			{ key: 'CommandOrControl+Shift+P', event: 'pause-recording' },
		] as const

		for (const s of shortcuts) {
			register(s.key, () => {
				emit(s.event)
			}).catch((err) => {
				console.error(`Failed to register shortcut ${s.key}:`, err)
			})
		}

		return () => {
			for (const s of shortcuts) {
				unregister(s.key).catch(() => {})
			}
		}
	}, [])
}
