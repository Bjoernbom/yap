export type DictationStatus = 'idle' | 'listening' | 'locked' | 'transcribing' | 'polishing' | 'complete' | 'error'

export interface DictationEvent {
	state: DictationStatus
	text: string | null
	error: string | null
	duration_ms: number | null
}
