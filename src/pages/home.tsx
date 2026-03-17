import { useState, useEffect, useMemo } from 'react'
import { Copy, Trash2, Check } from 'lucide-react'
import { useDictationStore, type Dictation } from '@/stores/dictation-store'
import { getSetting } from '@/lib/settings'
import { getHotkeySymbol } from '@/lib/hotkeys'

function formatTime(iso: string): string {
	const d = new Date(iso)
	const now = new Date()
	const diff = now.getTime() - d.getTime()

	if (diff < 60_000) return 'now'
	if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m`
	if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h`

	return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

function formatDuration(ms: number): string {
	const secs = Math.round(ms / 1000)
	if (secs < 60) return `${secs}s`
	return `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`
}

function Stat({ label, value }: { label: string; value: string }) {
	return (
		<div className="flex-1 text-center">
			<div className="text-[15px] font-semibold tabular-nums text-foreground/80">{value}</div>
			<div className="mt-0.5 text-[9px] font-medium uppercase tracking-widest text-muted-foreground/30">{label}</div>
		</div>
	)
}

function DictationItem({ item }: { item: Dictation }) {
	const deleteDictation = useDictationStore((s) => s.deleteDictation)
	const [copied, setCopied] = useState(false)

	async function handleCopy() {
		await navigator.clipboard.writeText(item.text)
		setCopied(true)
		setTimeout(() => setCopied(false), 1200)
	}

	return (
		<div className="group animate-fade-in-fast">
			<div className="flex items-start gap-2.5 px-3.5 py-2.5 transition-colors hover:bg-white/[0.02]">
				<div className="min-w-0 flex-1">
					<p className="text-[13px] leading-[1.55] text-foreground/85">
						{item.text}
					</p>
					<div className="mt-1 flex items-center gap-1.5">
						<span className="text-[10px] tabular-nums text-muted-foreground/40">
							{formatTime(item.createdAt)}
						</span>
						<span className="text-[10px] text-muted-foreground/15">/</span>
						<span className="text-[10px] tabular-nums text-muted-foreground/40">
							{formatDuration(item.durationMs)}
						</span>
					</div>
				</div>
				<div className="flex shrink-0 gap-0.5 pt-0.5 opacity-0 transition-opacity group-hover:opacity-100">
					<button
						onClick={handleCopy}
						className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground/40 transition-colors hover:bg-white/[0.06] hover:text-foreground/60"
					>
						{copied
							? <Check size={12} className="text-success" />
							: <Copy size={12} />
						}
					</button>
					<button
						onClick={() => deleteDictation(item.id)}
						className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground/20 transition-colors hover:bg-destructive/10 hover:text-destructive/60"
					>
						<Trash2 size={12} />
					</button>
				</div>
			</div>
			<div className="mx-3.5 border-b border-border/20" />
		</div>
	)
}

export function HomePage() {
	const dictations = useDictationStore((s) => s.dictations)
	const [hotkeySymbol, setHotkeySymbol] = useState('⌥R')

	useEffect(() => {
		getSetting('hotkey').then((hk) => {
			if (hk) setHotkeySymbol(getHotkeySymbol(hk))
		})
	}, [])

	const stats = useMemo(() => {
		const today = new Date()
		today.setHours(0, 0, 0, 0)

		const todayCount = dictations.filter(
			(d) => new Date(d.createdAt) >= today
		).length

		const totalWords = dictations.reduce(
			(sum, d) => sum + d.text.split(/\s+/).filter(Boolean).length, 0
		)

		const totalDuration = dictations.reduce((sum, d) => sum + d.durationMs, 0)
		const totalMins = Math.round(totalDuration / 60000)

		const wpm = totalMins > 0 ? Math.round(totalWords / totalMins) : 0

		return { todayCount, totalWords, totalMins, wpm }
	}, [dictations])

	return (
		<div className="flex h-full flex-col">
			{/* Trigger + Stats bar */}
			<div className="flex items-center border-b border-border/20 px-3.5 py-3">
				<div className="flex items-center gap-1.5">
					<kbd className="rounded border border-border/40 bg-white/[0.03] px-1.5 py-0.5 text-[10px] font-medium text-foreground/50">
						{hotkeySymbol}
					</kbd>
					<span className="text-[9px] font-medium uppercase tracking-widest text-muted-foreground/30">
						trigger
					</span>
				</div>
				{dictations.length > 0 && (
					<>
						<div className="mx-3 h-6 w-px bg-border/20" />
						<Stat label="today" value={String(stats.todayCount)} />
						<div className="h-6 w-px bg-border/20" />
						<Stat label="words" value={stats.totalWords > 999 ? `${(stats.totalWords / 1000).toFixed(1)}k` : String(stats.totalWords)} />
						<div className="h-6 w-px bg-border/20" />
						<Stat label="wpm" value={stats.wpm > 0 ? String(stats.wpm) : '—'} />
					</>
				)}
			</div>

			{/* History header */}
			{dictations.length > 0 && (
				<div className="flex items-center justify-between px-3.5 py-2">
					<span className="text-[9px] font-medium uppercase tracking-widest text-muted-foreground/30">
						recent
					</span>
					<span className="text-[9px] tabular-nums text-muted-foreground/20">
						{dictations.length}
					</span>
				</div>
			)}

			{/* List */}
			<div className="flex-1 overflow-auto">
				{dictations.length === 0 ? (
					<div className="flex h-full flex-col items-center justify-center gap-5 px-10 text-center">
						<div className="flex gap-1.5">
							<div className="h-2 w-2 rounded-full bg-muted-foreground/15" />
							<div className="h-2 w-2 rounded-full bg-muted-foreground/25" />
							<div className="h-2 w-2 rounded-full bg-muted-foreground/15" />
						</div>
						<div className="space-y-2">
							<p className="text-[14px] font-medium text-foreground/60">
								nothing here yet
							</p>
							<p className="text-[11px] leading-relaxed text-muted-foreground/35">
								hold <kbd className="mx-0.5 rounded border border-border/40 bg-white/[0.03] px-1.5 py-0.5 text-[10px] font-medium text-foreground/40">{hotkeySymbol}</kbd> and start talking
								<br />
								<span className="text-muted-foreground/25">text appears wherever your cursor is</span>
							</p>
						</div>
					</div>
				) : (
					dictations.map((d) => (
						<DictationItem key={d.id} item={d} />
					))
				)}
			</div>
		</div>
	)
}
