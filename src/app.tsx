import { useEffect, useState } from 'react'
import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { listen } from '@tauri-apps/api/event'
import { invoke } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { Layout } from './components/layout'
import { HomePage } from './pages/home'
import { SettingsPage } from './pages/settings'
import { OverlayPage } from './pages/overlay'
import { OnboardingPage } from './pages/onboarding'
import { initDb } from './lib/db'
import { initTray } from './lib/tray'
import { getSetting } from './lib/settings'
import { getPromptByStyle } from './lib/dictation-styles'
import { useDictationStore } from './stores/dictation-store'
import type { DictationEvent } from './types/dictation'

export function App() {
	const [ready, setReady] = useState(false)
	const [needsOnboarding, setNeedsOnboarding] = useState(false)
	const loadDictations = useDictationStore((s) => s.loadDictations)
	const addDictation = useDictationStore((s) => s.addDictation)
	const isOverlay = getCurrentWindow().label === 'overlay'

	useEffect(() => {
		// Overlay window: transparent background, no init needed
		if (isOverlay) {
			document.documentElement.style.background = 'transparent'
			document.documentElement.style.margin = '0'
			document.documentElement.style.padding = '0'
			document.documentElement.style.overflow = 'hidden'
			document.body.style.background = 'transparent'
			document.body.style.margin = '0'
			document.body.style.padding = '0'
			document.body.style.overflow = 'hidden'
			setReady(true)
			return
		}

		async function init() {
			await initDb()

			const onboardingComplete = await getSetting('onboarding_complete')
			if (!onboardingComplete) {
				setNeedsOnboarding(true)
				setReady(true)
				return
			}

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

	async function completeOnboarding() {
		setNeedsOnboarding(false)
		await loadDictations()
		await initTray()

		const [style, language] = await Promise.all([
			getSetting('dictation_style'),
			getSetting('whisper_language'),
		])
		const prompt = getPromptByStyle(style || 'balanced', language || 'en')
		if (prompt) {
			await invoke('set_prompt', { prompt })
		}
	}

	if (!ready) {
		return (
			<div className="flex h-full items-center justify-center text-muted-foreground">
				Loading...
			</div>
		)
	}

	if (needsOnboarding) {
		return <OnboardingPage onComplete={completeOnboarding} />
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
