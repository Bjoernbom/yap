import * as React from 'react'
import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { Layout } from './components/layout'
import { HomePage } from './pages/home'
import { SessionPage } from './pages/session'
import { SettingsPage } from './pages/settings'

export function App() {
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
