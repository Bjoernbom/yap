import { useEffect, useState } from 'react'
import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { listen } from '@tauri-apps/api/event'
import { invoke } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { Layout } from './components/layout'
import { HomePage } from './pages/home'
import { SettingsPage } from './pages/settings'
import { OverlayPage } from './pages/overlay'
import { initDb } from './lib/db'
import { initTray } from './lib/tray'
import { getSetting } from './lib/settings'
import { getPromptByStyle } from './lib/dictation-styles'
import { useDictationStore } from './stores/dictation-store'
import type { DictationEvent } from './types/dictation'

export function App() {
	const [ready, setReady] = useState(false)
	const loadDictations = useDictationStore((s) => s.loadDictations)
	const addDictation = useDictationStore((s) => s.addDictation)
	const isOverlay = getCurrentWindow().label === 'overlay'

	useEffect(() => {
		// Overlay window: transparent background, no init needed
		if (isOverlay) {
			document.documentElement.style.background = 'transparent'
			document.body.style.background = 'transparent'
			setReady(true)
			return
		}

		async function init() {
			await initDb()
			await loadDictations()
			await initTray()

			// Apply saved dictation style prompt with language
			const [style, language] = await Promise.all([
				getSetting('dictation_style'),
				getSetting('whisper_language'),
			])
			const prompt = getPromptByStyle(style || 'balanced', language || 'en')
			if (prompt) {
				await invoke('set_prompt', { prompt })
			}

			setReady(true)
		}
		init()
	}, [loadDictations, isOverlay])

	// Listen for completed dictations and save to DB (main window only)
	useEffect(() => {
		if (isOverlay) return

		const unlisten = listen<DictationEvent>('dictation-state', async (event) => {
			const { state, text, duration_ms } = event.payload
			if (state === 'complete' && text) {
				const language = await getSetting('whisper_language') || 'en'
				addDictation({
					text,
					language,
					durationMs: duration_ms || 0,
				})
			}
		})

		return () => {
			unlisten.then((fn) => fn())
		}
	}, [addDictation, isOverlay])

	if (!ready) {
		return (
			<div className="flex h-full items-center justify-center text-muted-foreground">
				Loading...
			</div>
		)
	}

	return (
		<BrowserRouter>
			<Routes>
				<Route path="/overlay" element={<OverlayPage />} />
				<Route element={<Layout />}>
					<Route path="/" element={<HomePage />} />
					<Route path="/settings" element={<SettingsPage />} />
				</Route>
			</Routes>
		</BrowserRouter>
	)
}
