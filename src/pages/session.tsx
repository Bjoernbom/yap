import * as React from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ArrowLeft, Play, Pause, Trash2, Loader2 } from 'lucide-react'
import { useSessionStore } from '@/stores/session-store'

export function SessionPage() {
	const { id } = useParams<{ id: string }>()
	const navigate = useNavigate()
	const session = useSessionStore((s) => s.getSession(id!))
	const deleteSession = useSessionStore((s) => s.deleteSession)

	if (!session) {
		return (
			<div className="flex h-full items-center justify-center text-text-tertiary">
				Session not found
			</div>
		)
	}

	function handleDelete() {
		deleteSession(session!.id)
		navigate('/')
	}

	return (
		<div className="flex h-full flex-col">
			<header className="flex items-center gap-3 border-b border-border px-6 py-4">
				<button
					onClick={() => navigate('/')}
					className="flex h-8 w-8 items-center justify-center rounded-lg text-text-tertiary transition-colors hover:bg-bg-tertiary hover:text-text"
				>
					<ArrowLeft size={18} />
				</button>
				<div className="flex-1">
					<h1 className="text-lg font-semibold">{session.title}</h1>
					<p className="text-xs text-text-tertiary">
						{new Date(session.createdAt).toLocaleString()}
					</p>
				</div>
				<button
					onClick={handleDelete}
					className="flex h-8 w-8 items-center justify-center rounded-lg text-text-tertiary transition-colors hover:bg-recording/10 hover:text-recording"
				>
					<Trash2 size={16} />
				</button>
			</header>

			<div className="flex-1 overflow-auto px-6 py-6">
				{session.status === 'processing' && (
					<div className="flex items-center gap-2 rounded-lg bg-bg-secondary px-4 py-3 text-sm text-text-secondary">
						<Loader2 size={16} className="animate-spin" />
						Processing recording...
					</div>
				)}

				{session.summary && (
					<section className="mb-6">
						<h2 className="mb-2 text-sm font-medium text-text-secondary">
							Summary
						</h2>
						<p className="text-sm leading-relaxed text-text">
							{session.summary}
						</p>
					</section>
				)}

				{session.actionItems.length > 0 && (
					<section className="mb-6">
						<h2 className="mb-2 text-sm font-medium text-text-secondary">
							Action Items
						</h2>
						<ul className="space-y-1">
							{session.actionItems.map((item, i) => (
								<li
									key={i}
									className="flex items-start gap-2 text-sm text-text"
								>
									<span className="mt-1 h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
									{item}
								</li>
							))}
						</ul>
					</section>
				)}

				{session.transcript && (
					<section>
						<h2 className="mb-2 text-sm font-medium text-text-secondary">
							Transcript
						</h2>
						<p className="whitespace-pre-wrap text-sm leading-relaxed text-text-secondary">
							{session.transcript}
						</p>
					</section>
				)}
			</div>
		</div>
	)
}
