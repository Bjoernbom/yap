import { useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { ArrowLeft, Loader2 } from 'lucide-react'
import Markdown from 'react-markdown'
import { useSessionStore } from '@/stores/session-store'
import { deleteAudioFile } from '@/lib/audio'
import { processSession } from '@/lib/pipeline'
import { SpeakerTranscript } from '@/components/speaker-transcript'

export function SessionPage() {
	const { id } = useParams<{ id: string }>()
	const navigate = useNavigate()
	const session = useSessionStore((s) => s.getSession(id!))
	const deleteSession = useSessionStore((s) => s.deleteSession)
	const updateSession = useSessionStore((s) => s.updateSession)
	const [showRaw, setShowRaw] = useState(false)
	const [showSpeakers, setShowSpeakers] = useState(true)

	if (!session) {
		return (
			<div className="flex h-full items-center justify-center text-text-tertiary">
				gone
			</div>
		)
	}

	async function handleDelete() {
		if (session!.audioPath) {
			await deleteAudioFile(session!.audioPath)
		}
		await deleteSession(session!.id)
		navigate('/')
	}

	const isProcessing =
		session.status === 'transcribing' || session.status === 'structuring'
	const isMeeting = session.type === 'meeting'
	const hasSegments = !!session.segmentedTranscript && session.segmentedTranscript.length > 0

	function handleRetry() {
		if (!session!.audioPath || isProcessing) return
		processSession(
			session!.id,
			session!.audioPath,
			session!.transcript || undefined,
		)
	}

	function handleRenameSpeaker(label: string, newName: string) {
		const speakers = [...(session!.speakers || [])]
		const existing = speakers.find((s) => s.label === label)
		if (existing) {
			existing.suggestedName = newName
		} else {
			speakers.push({ label, suggestedName: newName, role: null })
		}
		updateSession(session!.id, { speakers })
	}

	const hasCleanedTranscript = !!session.cleanedTranscript
	const showingRaw = showRaw || !hasCleanedTranscript

	return (
		<div className="relative flex h-full flex-col animate-fade-in">
			<button
				onClick={() => navigate('/')}
				className="absolute left-4 top-3 flex h-8 w-8 items-center justify-center rounded-full text-text-tertiary transition-colors duration-150 hover:text-text"
			>
				<ArrowLeft size={18} strokeWidth={1.5} />
			</button>

			<div className="flex-1 overflow-auto px-6 pb-8 pt-14">
				<div className="mx-auto max-w-2xl">
					<h1 className="text-[20px] font-semibold tracking-tight">
						{session.title}
					</h1>
					<p className="mt-1 text-[13px] text-text-tertiary">
						{isMeeting && (
							<span className="mr-1.5 rounded bg-accent/15 px-1.5 py-0.5 text-[11px] text-accent">
								meeting
							</span>
						)}
						{new Date(session.createdAt).toLocaleDateString(undefined, {
							weekday: 'short',
							month: 'short',
							day: 'numeric',
						})}
						{session.duration > 0 && (
							<>
								{' · '}
								<span className="mono">
									{Math.floor(session.duration / 60)}m{' '}
									{session.duration % 60}s
								</span>
							</>
						)}
					</p>

					{session.status === 'transcribing' && (
						<div className="mt-6 flex items-center gap-2 text-[13px] text-text-secondary">
							<Loader2
								size={14}
								strokeWidth={1.5}
								className="animate-spin"
							/>
							{isMeeting ? 'transcribing & identifying speakers...' : 'listening back...'}
						</div>
					)}

					{session.status === 'structuring' && (
						<div className="mt-6 flex items-center gap-2 text-[13px] text-text-secondary">
							<Loader2
								size={14}
								strokeWidth={1.5}
								className="animate-spin"
							/>
							{isMeeting ? 'structuring meeting notes...' : 'making sense of it...'}
						</div>
					)}

					{session.status === 'error' && (
						<div className="mt-6 flex items-center gap-3 text-[13px] text-text-secondary">
							<span>that didn't work</span>
							{session.audioPath && (
								<button
									onClick={handleRetry}
									className="text-accent transition-colors duration-150 hover:text-accent-hover"
								>
									retry
								</button>
							)}
						</div>
					)}

					{/* Speaker transcript for meetings */}
					{isMeeting && hasSegments && (
						<section className="mt-8">
							<div className="mb-3 flex items-center gap-3">
								<span className="section-label">conversation</span>
								{hasCleanedTranscript && (
									<div className="flex rounded-full bg-bg-tertiary p-0.5 text-[11px]">
										<button
											onClick={() => setShowSpeakers(true)}
											className={`rounded-full px-2.5 py-0.5 transition-colors ${
												showSpeakers
													? 'bg-bg text-text'
													: 'text-text-tertiary hover:text-text-secondary'
											}`}
										>
											speakers
										</button>
										<button
											onClick={() => setShowSpeakers(false)}
											className={`rounded-full px-2.5 py-0.5 transition-colors ${
												!showSpeakers
													? 'bg-bg text-text'
													: 'text-text-tertiary hover:text-text-secondary'
											}`}
										>
											cleaned
										</button>
									</div>
								)}
							</div>

							{showSpeakers ? (
								<SpeakerTranscript
									segments={session.segmentedTranscript!}
									speakers={session.speakers}
									onRenameSpeaker={handleRenameSpeaker}
								/>
							) : (
								<div className="rounded-xl bg-bg-secondary p-5">
									<div className="prose prose-sm max-w-none text-text">
										<Markdown>{session.cleanedTranscript!}</Markdown>
									</div>
								</div>
							)}
						</section>
					)}

					{/* Regular transcript for notes */}
					{!isMeeting && session.transcript && (
						<section className="mt-8">
							<div className="mb-3 flex items-center gap-3">
								<span className="section-label">transcript</span>
								{hasCleanedTranscript && (
									<div className="flex rounded-full bg-bg-tertiary p-0.5 text-[11px]">
										<button
											onClick={() => setShowRaw(false)}
											className={`rounded-full px-2.5 py-0.5 transition-colors ${
												!showingRaw
													? 'bg-bg text-text'
													: 'text-text-tertiary hover:text-text-secondary'
											}`}
										>
											cleaned
										</button>
										<button
											onClick={() => setShowRaw(true)}
											className={`rounded-full px-2.5 py-0.5 transition-colors ${
												showingRaw
													? 'bg-bg text-text'
													: 'text-text-tertiary hover:text-text-secondary'
											}`}
										>
											raw
										</button>
									</div>
								)}
							</div>

							<div className="rounded-xl bg-bg-secondary p-5">
								{showingRaw ? (
									<p className="whitespace-pre-wrap text-[14px] leading-[1.8] text-text-secondary">
										{session.transcript}
									</p>
								) : (
									<div className="prose prose-sm max-w-none text-text">
										<Markdown>
											{session.cleanedTranscript!}
										</Markdown>
									</div>
								)}
							</div>
						</section>
					)}

					{/* Meeting also shows flat transcript if no segments */}
					{isMeeting && !hasSegments && session.transcript && (
						<section className="mt-8">
							<span className="section-label">transcript</span>
							<div className="mt-3 rounded-xl bg-bg-secondary p-5">
								<p className="whitespace-pre-wrap text-[14px] leading-[1.8] text-text-secondary">
									{session.transcript}
								</p>
							</div>
						</section>
					)}

					{session.summary && (
						<>
							<hr className="my-6 border-border" />
							<section>
								<span className="section-label">summary</span>
								<p className="mt-3 text-[14px] leading-relaxed text-text">
									{session.summary}
								</p>
							</section>
						</>
					)}

					{/* Key decisions (meetings) */}
					{session.keyDecisions.length > 0 && (
						<>
							<hr className="my-6 border-border" />
							<section>
								<span className="section-label">decisions</span>
								<ul className="mt-3 space-y-1.5">
									{session.keyDecisions.map((decision, i) => (
										<li
											key={i}
											className="flex items-start gap-2.5 text-[14px] text-text"
										>
											<span className="mt-[7px] h-1.5 w-1.5 shrink-0 rounded-full bg-success" />
											{decision}
										</li>
									))}
								</ul>
							</section>
						</>
					)}

					{session.actionItems.length > 0 && (
						<>
							<hr className="my-6 border-border" />
							<section>
								<span className="section-label">actions</span>
								<ul className="mt-3 space-y-1.5">
									{session.actionItems.map((item, i) => (
										<li
											key={i}
											className="flex items-start gap-2.5 text-[14px] text-text"
										>
											<span className="mt-[7px] h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
											{item}
										</li>
									))}
								</ul>
							</section>
						</>
					)}

					<div className="mt-16 pb-8">
						<button
							onClick={handleDelete}
							className="text-[13px] text-text-tertiary transition-colors duration-150 hover:text-recording"
						>
							delete
						</button>
					</div>
				</div>
			</div>
		</div>
	)
}
