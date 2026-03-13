import * as React from 'react'
import { Mic, Square } from 'lucide-react'
import { useRecorder } from '@/hooks/use-recorder'

export function RecordButton() {
	const { isRecording, duration, start, stop } = useRecorder()

	function formatDuration(seconds: number) {
		const m = Math.floor(seconds / 60)
		const s = seconds % 60
		return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`
	}

	return (
		<div className="flex flex-col items-center gap-3">
			<button
				onClick={isRecording ? stop : start}
				className={`flex h-16 w-16 items-center justify-center rounded-full transition-all ${
					isRecording
						? 'animate-pulse bg-recording text-white shadow-[0_0_24px_rgba(239,68,68,0.4)]'
						: 'bg-accent text-white hover:bg-accent-hover hover:shadow-[0_0_16px_rgba(99,102,241,0.3)]'
				}`}
			>
				{isRecording ? <Square size={24} /> : <Mic size={24} />}
			</button>
			{isRecording && (
				<span className="font-mono text-sm text-recording">
					{formatDuration(duration)}
				</span>
			)}
		</div>
	)
}
