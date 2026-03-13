import { useNavigate } from 'react-router-dom'
import { useSessionStore } from '@/stores/session-store'
import { formatDistanceToNow } from 'date-fns'

export function SessionList() {
	const sessions = useSessionStore((s) => s.sessions)
	const navigate = useNavigate()

	if (sessions.length === 0) {
		return (
			<div className="flex flex-col items-center justify-center gap-3 rounded-xl border border-border bg-bg-secondary py-24">
				<p className="text-[14px] text-text-tertiary">nothing here yet</p>
				<p className="mono text-[12px] text-text-tertiary/50">
					press the button below to start
				</p>
			</div>
		)
	}

	return (
		<div className="overflow-hidden rounded-xl border border-border bg-bg-secondary">
			{sessions.map((session, i) => (
				<button
					key={session.id}
					onClick={() => navigate(`/session/${session.id}`)}
					className={`group flex w-full items-start gap-3 px-5 py-4 text-left transition-colors duration-150 hover:bg-bg-tertiary ${
						i > 0 ? 'border-t border-border' : ''
					}`}
				>
					<span
						className={`mt-[7px] h-1.5 w-1.5 shrink-0 rounded-full ${
							session.type === 'meeting'
								? 'bg-[#5a9e8f]'
								: 'bg-accent'
						}`}
					/>
					<div className="min-w-0 flex-1">
						<div className="flex items-baseline justify-between gap-4">
							<h3 className="truncate text-[14px] font-semibold text-text">
								{session.title}
							</h3>
							<span className="shrink-0 text-[11px] text-text-tertiary">
								{formatDistanceToNow(
									new Date(session.createdAt),
									{ addSuffix: true },
								)}
							</span>
						</div>
						{session.summary && (
							<p className="mt-0.5 line-clamp-1 text-[13px] text-text-secondary">
								{session.summary}
							</p>
						)}
						{session.duration > 0 && (
							<p className="mono mt-1 text-[11px] text-text-tertiary">
								{Math.floor(session.duration / 60)}m{' '}
								{session.duration % 60}s
							</p>
						)}
					</div>
				</button>
			))}
		</div>
	)
}
