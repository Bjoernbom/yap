import { useState, useCallback, useEffect } from 'react'
import { Mic, Pause, Play, Users } from 'lucide-react'
import { invoke } from '@tauri-apps/api/core'
import { useRecorder, type RecordingMode } from '@/hooks/use-recorder'

function LevelMeter({ level, label }: { level: number; label: string }) {
	const width = Math.min(level * 500, 100)
	return (
		<div className="flex items-center gap-2 text-[11px] text-text-secondary">
			<span className="w-12 shrink-0">{label}</span>
			<div className="h-1 flex-1 overflow-hidden rounded-full bg-bg-tertiary">
				<div
					className="h-full rounded-full bg-accent transition-all duration-75"
					style={{ width: `${width}%` }}
				/>
			</div>
		</div>
	)
}

export function RecordButton() {
	const [mode, setMode] = useState<RecordingMode>('note')
	const [permissionOk, setPermissionOk] = useState<boolean | null>(null)
	const {
		isRecording,
		isPaused,
		duration,
		liveTranscript,
		micLevel,
		systemLevel,
		error,
		start,
		stop,
		togglePause,
	} = useRecorder(mode)

	const checkPermission = useCallback(async () => {
		if (mode !== 'meeting') return
		try {
			const ok = await invoke<boolean>('check_screen_recording_permission')
			setPermissionOk(ok)
		} catch {
			setPermissionOk(false)
		}
	}, [mode])

	useEffect(() => {
		if (mode === 'meeting') {
			checkPermission()
		}
	}, [mode, checkPermission])

	async function handleStart() {
		if (mode === 'meeting' && !permissionOk) {
			await invoke('request_screen_recording_permission')
			const ok = await invoke<boolean>('check_screen_recording_permission')
			setPermissionOk(ok)
			if (!ok) return
		}
		start()
	}

	function formatDuration(seconds: number) {
		const m = Math.floor(seconds / 60)
		const s = seconds % 60
		return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`
	}

	const isMeeting = mode === 'meeting'

	return (
		<div className="flex flex-col items-center gap-3">
			{isRecording && liveTranscript && !isMeeting && (
				<div className="relative max-h-[120px] w-72 overflow-hidden rounded-xl bg-bg-secondary px-4 py-3 shadow-[0_1px_2px_rgba(0,0,0,0.3)]">
					<div className="pointer-events-none absolute inset-x-0 top-0 h-8 bg-gradient-to-b from-bg-secondary to-transparent" />
					<p className="mono text-[13px] leading-relaxed text-text-secondary">
						{liveTranscript}
					</p>
				</div>
			)}

			{isRecording && isMeeting && (
				<div className="w-72 space-y-1.5 rounded-xl bg-bg-secondary px-4 py-3 shadow-[0_1px_2px_rgba(0,0,0,0.3)]">
					<LevelMeter level={micLevel} label="Mic" />
					<LevelMeter level={systemLevel} label="System" />
				</div>
			)}

			<div className="flex items-center gap-3">
				{/* Mode toggle — only when not recording */}
				{!isRecording && (
					<div className="flex rounded-lg bg-bg-tertiary p-0.5">
						<button
							onClick={() => setMode('note')}
							className={`flex h-8 w-8 items-center justify-center rounded-md transition-colors ${
								mode === 'note'
									? 'bg-bg text-text shadow-sm'
									: 'text-text-tertiary hover:text-text-secondary'
							}`}
							title="Voice note"
						>
							<Mic size={14} strokeWidth={1.5} />
						</button>
						<button
							onClick={() => setMode('meeting')}
							className={`flex h-8 w-8 items-center justify-center rounded-md transition-colors ${
								mode === 'meeting'
									? 'bg-bg text-text shadow-sm'
									: 'text-text-tertiary hover:text-text-secondary'
							}`}
							title="Meeting recording"
						>
							<Users size={14} strokeWidth={1.5} />
						</button>
					</div>
				)}

				{isRecording && !isMeeting && (
					<button
						onClick={togglePause}
						className="flex h-10 w-10 items-center justify-center rounded-full bg-bg-tertiary text-text-secondary transition-all duration-150 hover:text-text"
					>
						{isPaused ? (
							<Play size={16} strokeWidth={1.5} />
						) : (
							<Pause size={16} strokeWidth={1.5} />
						)}
					</button>
				)}

				<div className="relative flex items-center justify-center">
					{isRecording && !isPaused && (
						<span
							className={`animate-ring absolute h-14 w-14 rounded-full border ${
								isMeeting ? 'border-accent/30' : 'border-recording/30'
							}`}
						/>
					)}
					<button
						onClick={isRecording ? stop : handleStart}
						className={`relative flex h-14 w-14 items-center justify-center rounded-full transition-all duration-150 ${
							isRecording
								? isPaused
									? isMeeting
										? 'bg-accent/60'
										: 'bg-recording/60'
									: isMeeting
										? 'animate-breathe bg-accent shadow-[0_0_20px_rgba(99,102,241,0.3)]'
										: 'animate-breathe bg-recording shadow-[0_0_20px_rgba(224,90,71,0.3)]'
								: 'bg-accent shadow-[0_0_20px_rgba(232,164,67,0.15)] hover:scale-[1.04] hover:bg-accent-hover'
						}`}
					>
						{isRecording ? (
							<span className="block h-2.5 w-2.5 rounded-[2px] bg-white" />
						) : isMeeting ? (
							<Users size={18} strokeWidth={1.5} className="text-white" />
						) : (
							<span className="block h-2 w-2 rounded-full bg-white" />
						)}
					</button>
				</div>
			</div>

			{isRecording && (
				<div className="flex flex-col items-center gap-0.5">
					<span
						className={`mono text-[13px] ${
							isPaused
								? 'text-text-tertiary'
								: isMeeting
									? 'text-accent'
									: 'text-recording'
						}`}
					>
						{formatDuration(duration)}
					</span>
					{isPaused && (
						<span className="text-[11px] text-text-tertiary">paused</span>
					)}
					{isMeeting && !isPaused && (
						<span className="text-[11px] text-text-tertiary">meeting</span>
					)}
				</div>
			)}

			{!isRecording && isMeeting && permissionOk === false && (
				<p className="text-[11px] text-recording">
					Screen Recording permission required
				</p>
			)}
			{!isRecording && error && (
				<p className="max-w-xs text-center text-[11px] text-recording">
					{error}
				</p>
			)}
		</div>
	)
}
