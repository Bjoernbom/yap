import { useState, useEffect } from 'react'
import { listen } from '@tauri-apps/api/event'
import type { DictationEvent } from '@/types/dictation'

export function DictationBadge() {
	const [status, setStatus] = useState<DictationEvent['state'] | 'idle'>('idle')
	const [message, setMessage] = useState('')

	useEffect(() => {
		const unlisten = listen<DictationEvent>('dictation-state', (event) => {
			const { state, text, error } = event.payload
			setStatus(state)

			if (state === 'listening') setMessage('yapping...')
			else if (state === 'locked') setMessage('yapping...')
			else if (state === 'transcribing') setMessage('cooking...')
			else if (state === 'polishing') setMessage('polishing...')
			else if (state === 'complete' && text) {
				setMessage('yapped')
				setTimeout(() => setStatus('idle'), 1500)
			} else if (state === 'error') {
				const msg = error || 'oops'
				setMessage(msg.length > 30 ? msg.slice(0, 30) + '...' : msg)
				setTimeout(() => setStatus('idle'), 2500)
			} else if (state === 'complete') {
				setMessage('too quiet')
				setTimeout(() => setStatus('idle'), 1200)
			}
		})

		return () => { unlisten.then((fn) => fn()) }
	}, [])

	if (status === 'idle') return null

	return (
		<div className="pointer-events-none absolute inset-x-0 bottom-0 flex justify-center pb-4">
			<div className="pointer-events-auto flex items-center gap-2 rounded-full border border-border/30 bg-card/95 px-3.5 py-1.5 shadow-xl shadow-black/20 backdrop-blur-sm animate-fade-in">
				{status === 'listening' && (
					<div className="relative flex h-3 w-3 items-center justify-center">
						<div className="absolute h-3 w-3 animate-ping rounded-full bg-recording/40" />
						<div className="h-1.5 w-1.5 rounded-full bg-recording" />
					</div>
				)}
				{status === 'locked' && (
					<div className="relative flex h-3 w-3 items-center justify-center">
						<div className="absolute h-3 w-3 animate-ping rounded-full bg-amber/30" />
						<div className="h-1.5 w-1.5 rounded-full bg-amber" />
					</div>
				)}
				{(status === 'transcribing' || status === 'polishing') && (
					<div className="h-1.5 w-1.5 animate-pulse-dot rounded-full bg-amber" />
				)}
				{status === 'complete' && (
					<div className="h-1.5 w-1.5 rounded-full bg-success" />
				)}
				{status === 'error' && (
					<div className="h-1.5 w-1.5 rounded-full bg-destructive" />
				)}
				<span className={`text-[11px] font-medium text-foreground/75 ${
				message.startsWith('yap') ? 'font-brand' : ''
			}`}>{message}</span>
			</div>
		</div>
	)
}
