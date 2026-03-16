import { useEffect, useState } from 'react'
import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { Layout } from './components/layout'
import { HomePage } from './pages/home'
import { SettingsPage } from './pages/settings'
import { OverlayPage } from './pages/overlay'
import { initDb } from './lib/db'
import { initTray } from './lib/tray'
import { useDictationStore } from './stores/dictation-store'

interface DictationEvent {
	state: string
	text: string | null
	error: string | null
	duration_ms: number | null
}

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

			// Apply saved dictation style prompt
			const { getSetting } = await import('./lib/settings')
			const { invoke } = await import('@tauri-apps/api/core')
			const style = await getSetting('dictation_style') || 'balanced'
			const prompts: Record<string, string> = {
				formal: 'Skriv med korrekt grammatik, fullständiga meningar och formell stil. Använd skiljetecken. Inga förkortningar eller talspråk.',
				balanced: 'Skriv naturligt med korrekt interpunktion och grammatik. Balansera mellan formellt och informellt.',
				casual: 'Skriv vardagligt och avslappnat, som i en chatt. Korta meningar, inga onödiga formaliteter.',
				dev: 'You are transcribing a software developer dictating instructions for an AI coding assistant. Write clear, precise, technical language. Preserve exact technical terms, library names, function names, and programming concepts as spoken. Use imperative mood ("add a function", "refactor the component"). Structure as actionable instructions. Fill in obvious gaps — if the developer says "add error handling" assume try/catch or Result types as appropriate. Keep code references exact (React, TypeScript, Rust, API names). Output in the same language the developer speaks but keep all code terms in English.',
			}
			if (prompts[style]) {
				await invoke('set_prompt', { prompt: prompts[style] })
			}

			setReady(true)
		}
		init()
	}, [loadDictations, isOverlay])

	// Listen for completed dictations and save to DB (main window only)
	useEffect(() => {
		if (isOverlay) return

		const unlisten = listen<DictationEvent>('dictation-state', (event) => {
			const { state, text, duration_ms } = event.payload
			if (state === 'complete' && text) {
				addDictation({
					text,
					language: 'sv',
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
