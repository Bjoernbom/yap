import * as React from 'react'
import { useNavigate } from 'react-router-dom'
import { Mic, Users, Clock } from 'lucide-react'
import { useSessionStore } from '@/stores/session-store'
import { formatDistanceToNow } from 'date-fns'

export function SessionList() {
	const sessions = useSessionStore((s) => s.sessions)
	const navigate = useNavigate()

	if (sessions.length === 0) {
		return (
			<div className="flex flex-col items-center justify-center gap-3 py-20 text-text-tertiary">
				<Mic size={32} />
				<p>No recordings yet</p>
				<p className="text-sm">Hit the record button to get started</p>
			</div>
		)
	}

	return (
		<div className="flex flex-col gap-1">
			{sessions.map((session) => (
				<button
					key={session.id}
					onClick={() => navigate(`/session/${session.id}`)}
					className="flex items-start gap-3 rounded-lg px-4 py-3 text-left transition-colors hover:bg-bg-tertiary"
				>
					<div
						className={`mt-1 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg ${
							session.type === 'meeting'
								? 'bg-accent/15 text-accent'
								: 'bg-success/15 text-success'
						}`}
					>
						{session.type === 'meeting' ? (
							<Users size={16} />
						) : (
							<Mic size={16} />
						)}
					</div>
					<div className="min-w-0 flex-1">
						<h3 className="truncate text-sm font-medium text-text">
							{session.title}
						</h3>
						{session.summary && (
							<p className="mt-0.5 line-clamp-2 text-xs text-text-secondary">
								{session.summary}
							</p>
						)}
						<div className="mt-1 flex items-center gap-3 text-xs text-text-tertiary">
							<span className="flex items-center gap-1">
								<Clock size={12} />
								{formatDistanceToNow(new Date(session.createdAt), {
									addSuffix: true,
								})}
							</span>
							{session.duration > 0 && (
								<span>
									{Math.floor(session.duration / 60)}m{' '}
									{session.duration % 60}s
								</span>
							)}
						</div>
					</div>
				</button>
			))}
		</div>
	)
}
