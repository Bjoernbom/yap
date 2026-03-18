import { useState, useEffect, useRef } from 'react'
import { listen } from '@tauri-apps/api/event'
import { invoke } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { WebviewWindow } from '@tauri-apps/api/webviewWindow'
import type { DictationEvent, DictationStatus } from '@/types/dictation'

export function OverlayPage() {
	const [status, setStatus] = useState<DictationStatus>('idle')
	const [message, setMessage] = useState('yap')
	const [elapsed, setElapsed] = useState(0)
	const timerRef = useRef<ReturnType<typeof setInterval> | null>(null)

	useEffect(() => {
		invoke('configure_overlay_window').catch(() => {})
	}, [])

	useEffect(() => {
		const unlisten = listen<DictationEvent>('dictation-state', (event) => {
			const { state, text, error } = event.payload
			setStatus(state)

			if (state === 'idle') { setMessage('yap'); setElapsed(0) }
			else if (state === 'listening') { setMessage('yapping'); setElapsed(0) }
			else if (state === 'locked') { setMessage('yapping'); setElapsed(0) }
			else if (state === 'transcribing') setMessage('cooking')
			else if (state === 'complete' && text) setMessage('yapped')
			else if (state === 'error') {
				const msg = error || 'oops'
				setMessage(msg.length > 20 ? msg.slice(0, 20) + '...' : msg)
			}
			else if (state === 'complete') setMessage(error || 'yapped')
		})
		return () => { unlisten.then((fn) => fn()) }
	}, [])

	useEffect(() => {
		if (status === 'listening') {
			const start = Date.now()
			timerRef.current = setInterval(() => {
				setElapsed(Math.floor((Date.now() - start) / 100) / 10)
			}, 100)
		} else {
			if (timerRef.current) { clearInterval(timerRef.current); timerRef.current = null }
		}
		return () => { if (timerRef.current) clearInterval(timerRef.current) }
	}, [status])

	const isActive = status === 'listening' || status === 'locked' || status === 'transcribing'

	async function openDashboard() {
		const main = await WebviewWindow.getByLabel('main')
		if (main) {
			await main.show()
			await main.setFocus()
		}
	}

	return (
		<div
			onMouseDown={() => getCurrentWindow().startDragging()}
			onDoubleClick={openDashboard}
			style={{
				width: '100%',
				height: '100%',
				display: 'flex',
				alignItems: 'center',
				justifyContent: 'center',
				cursor: 'grab',
				userSelect: 'none',
				overflow: 'hidden',
				background: '#09090b',
				transition: 'background 200ms',
			}}
		>
			<div style={{ display: 'flex', alignItems: 'center', gap: '6px', pointerEvents: 'none' }}>
				<div style={{ position: 'relative', width: '12px', height: '12px', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
					{status === 'listening' && (
						<>
							<div style={{
								position: 'absolute', width: '12px', height: '12px', borderRadius: '50%',
								background: 'rgba(255, 64, 64, 0.25)',
								animation: 'ping 1s cubic-bezier(0, 0, 0.2, 1) infinite',
							}} />
							<div style={{ width: '6px', height: '6px', borderRadius: '50%', background: '#ff4040' }} />
						</>
					)}
					{status === 'locked' && (
						<>
							<div style={{
								position: 'absolute', width: '12px', height: '12px', borderRadius: '50%',
								background: 'rgba(245, 158, 11, 0.25)',
								animation: 'ping 1.5s cubic-bezier(0, 0, 0.2, 1) infinite',
							}} />
							<div style={{ width: '6px', height: '6px', borderRadius: '50%', background: '#f59e0b' }} />
						</>
					)}
					{status === 'transcribing' && (
						<div style={{
							width: '6px', height: '6px', borderRadius: '50%', background: '#f59e0b',
							animation: 'pulse 0.7s ease-in-out infinite',
						}} />
					)}
					{status === 'complete' && (
						<div style={{ width: '6px', height: '6px', borderRadius: '50%', background: '#22c55e' }} />
					)}
					{status === 'error' && (
						<div style={{ width: '6px', height: '6px', borderRadius: '50%', background: '#ef4444' }} />
					)}
					{status === 'idle' && (
						<div style={{ width: '5px', height: '5px', borderRadius: '50%', background: '#3f3f46' }} />
					)}
				</div>

				<span style={{
					fontSize: '10px', fontWeight: 500, letterSpacing: '-0.01em',
					fontFamily: "'Pixelify Sans Variable', 'Geist Variable', sans-serif",
					color: isActive ? 'rgba(250,250,250,0.85)' : 'rgba(250,250,250,0.25)',
					transition: 'color 200ms',
				}}>
					{message}
				</span>

				{status === 'listening' && elapsed > 0 && (
					<span style={{
						fontSize: '9px', fontWeight: 500,
						fontFamily: "'Pixelify Sans Variable', 'Geist Variable', sans-serif",
						fontVariantNumeric: 'tabular-nums',
						color: 'rgba(250,250,250,0.2)',
					}}>
						{elapsed.toFixed(1)}s
					</span>
				)}
			</div>

			<style>{`
				@keyframes ping { 75%, 100% { transform: scale(2.5); opacity: 0; } }
				@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.25; } }
			`}</style>
		</div>
	)
}
