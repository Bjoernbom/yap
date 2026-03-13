import { useEffect, useState } from 'react'
import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { Layout } from './components/layout'
import { HomePage } from './pages/home'
import { SessionPage } from './pages/session'
import { SettingsPage } from './pages/settings'
import { initDb } from './lib/db'
import { initTray } from './lib/tray'
import { useSessionStore } from './stores/session-store'

export function App() {
	const [ready, setReady] = useState(false)
	const loadSessions = useSessionStore((s) => s.loadSessions)

	useEffect(() => {
		async function init() {
			await initDb()
			await loadSessions()
			await initTray()
			setReady(true)
		}
		init()
	}, [loadSessions])

	if (!ready) {
		return (
			<div className="flex h-full items-center justify-center text-text-tertiary">
				Loading...
			</div>
		)
	}

	return (
		<BrowserRouter>
			<Routes>
				<Route element={<Layout />}>
					<Route path="/" element={<HomePage />} />
					<Route path="/session/:id" element={<SessionPage />} />
					<Route path="/settings" element={<SettingsPage />} />
				</Route>
			</Routes>
		</BrowserRouter>
	)
}
