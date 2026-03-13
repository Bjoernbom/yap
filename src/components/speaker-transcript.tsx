import { useState, useMemo } from 'react'
import type { TranscriptSegment, SpeakerInfo } from '@/stores/session-store'

const SPEAKER_COLORS = [
	'#6366f1', // indigo
	'#f59e0b', // amber
	'#10b981', // emerald
	'#ef4444', // red
	'#8b5cf6', // violet
	'#ec4899', // pink
	'#14b8a6', // teal
	'#f97316', // orange
	'#06b6d4', // cyan
	'#84cc16', // lime
]

function getSpeakerColor(label: string): string {
	let hash = 0
	for (let i = 0; i < label.length; i++) {
		hash = label.charCodeAt(i) + ((hash << 5) - hash)
	}
	return SPEAKER_COLORS[Math.abs(hash) % SPEAKER_COLORS.length]
}

function formatMs(ms: number): string {
	const totalSecs = Math.floor(ms / 1000)
	const mins = Math.floor(totalSecs / 60)
	const secs = totalSecs % 60
	return `${mins}:${secs.toString().padStart(2, '0')}`
}

interface SpeakerGroup {
	speakerLabel: string
	startMs: number
	segments: TranscriptSegment[]
}

function groupConsecutiveSegments(segments: TranscriptSegment[]): SpeakerGroup[] {
	const groups: SpeakerGroup[] = []

	for (const segment of segments) {
		const label = segment.speakerLabel || 'Unknown'
		const last = groups[groups.length - 1]

		if (last && last.speakerLabel === label) {
			last.segments.push(segment)
		} else {
			groups.push({
				speakerLabel: label,
				startMs: segment.startMs,
				segments: [segment],
			})
		}
	}

	return groups
}

interface SpeakerTranscriptProps {
	segments: TranscriptSegment[]
	speakers: SpeakerInfo[]
	onRenameSpeaker?: (label: string, newName: string) => void
}

export function SpeakerTranscript({ segments, speakers, onRenameSpeaker }: SpeakerTranscriptProps) {
	const [editingLabel, setEditingLabel] = useState<string | null>(null)
	const [editValue, setEditValue] = useState('')

	const speakerNames = useMemo(() => {
		const map = new Map<string, string>()
		for (const s of speakers) {
			if (s.suggestedName) {
				map.set(s.label, s.suggestedName)
			}
		}
		return map
	}, [speakers])

	const groups = useMemo(() => groupConsecutiveSegments(segments), [segments])

	function getDisplayName(label: string): string {
		return speakerNames.get(label) || label
	}

	function handleStartEdit(label: string) {
		setEditingLabel(label)
		setEditValue(getDisplayName(label))
	}

	function handleFinishEdit(label: string) {
		if (editValue.trim() && onRenameSpeaker) {
			onRenameSpeaker(label, editValue.trim())
		}
		setEditingLabel(null)
	}

	if (segments.length === 0) {
		return (
			<p className="text-sm text-text-tertiary">No transcript segments</p>
		)
	}

	return (
		<div className="space-y-4">
			{groups.map((group, gi) => {
				const color = getSpeakerColor(group.speakerLabel)
				const displayName = getDisplayName(group.speakerLabel)
				const isEditing = editingLabel === group.speakerLabel

				return (
					<div key={gi} className="flex gap-3">
						<div
							className="mt-1 h-2 w-2 shrink-0 rounded-full"
							style={{ backgroundColor: color }}
						/>
						<div className="min-w-0 flex-1">
							<div className="mb-1 flex items-center gap-2">
								{isEditing ? (
									<input
										autoFocus
										value={editValue}
										onChange={(e) => setEditValue(e.target.value)}
										onBlur={() => handleFinishEdit(group.speakerLabel)}
										onKeyDown={(e) => {
											if (e.key === 'Enter') handleFinishEdit(group.speakerLabel)
											if (e.key === 'Escape') setEditingLabel(null)
										}}
										className="h-5 rounded bg-bg-tertiary px-1.5 text-[13px] font-medium text-text focus:outline-none"
									/>
								) : (
									<button
										onClick={() => handleStartEdit(group.speakerLabel)}
										className="text-[13px] font-medium transition-colors hover:text-accent"
										style={{ color }}
										title="Click to rename speaker"
									>
										{displayName}
									</button>
								)}
								<span className="mono text-[11px] text-text-tertiary">
									{formatMs(group.startMs)}
								</span>
							</div>
							<div className="rounded-lg bg-bg-secondary px-3 py-2">
								<p className="text-[13px] leading-relaxed text-text-secondary">
									{group.segments.map((s) => s.text).join(' ')}
								</p>
							</div>
						</div>
					</div>
				)
			})}
		</div>
	)
}
