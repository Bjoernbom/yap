import { useState, useRef, useCallback, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { listen } from '@tauri-apps/api/event'
import { invoke } from '@tauri-apps/api/core'
import { useSessionStore } from '@/stores/session-store'
import { saveAudioFile } from '@/lib/audio'
import { processSession, processMeetingSession } from '@/lib/pipeline'
import { getSetting } from '@/lib/settings'
import { updateTrayState } from '@/lib/tray'

function resample(samples: Float32Array, fromRate: number, toRate: number): Float32Array {
	if (fromRate === toRate) return samples
	const ratio = fromRate / toRate
	const newLength = Math.round(samples.length / ratio)
	const result = new Float32Array(newLength)
	for (let i = 0; i < newLength; i++) {
		const srcIndex = i * ratio
		const low = Math.floor(srcIndex)
		const high = Math.min(low + 1, samples.length - 1)
		const frac = srcIndex - low
		result[i] = samples[low] * (1 - frac) + samples[high] * frac
	}
	return result
}

function float32ToBase64(samples: Float32Array): string {
	const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength)
	let binary = ''
	for (let i = 0; i < bytes.length; i++) {
		binary += String.fromCharCode(bytes[i])
	}
	return btoa(binary)
}

export type RecordingMode = 'note' | 'meeting'

export function useRecorder(mode: RecordingMode = 'note') {
	const [isRecording, setIsRecording] = useState(false)
	const [isPaused, setIsPaused] = useState(false)
	const [duration, setDuration] = useState(0)
	const [liveTranscript, setLiveTranscript] = useState('')
	const [micLevel, setMicLevel] = useState(0)
	const [systemLevel, setSystemLevel] = useState(0)
	const [error, setError] = useState<string | null>(null)
	const liveTranscriptRef = useRef('')
	const navigate = useNavigate()
	const navigateRef = useRef(navigate)
	navigateRef.current = navigate
	const streamRef = useRef<MediaStream | null>(null)
	const audioContextRef = useRef<AudioContext | null>(null)
	const processorRef = useRef<ScriptProcessorNode | null>(null)
	const pcmBufferRef = useRef<Float32Array[]>([])
	const timerRef = useRef<ReturnType<typeof setInterval> | null>(null)
	const durationRef = useRef(0)
	const isRecordingRef = useRef(false)
	const isPausedRef = useRef(false)
	const startRef = useRef<() => void>(() => {})
	const stopRef = useRef<() => void>(() => {})
	const togglePauseRef = useRef<() => void>(() => {})
	const transcribeIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)
	const transcribingRef = useRef(false)
	const levelIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null)
	const modeRef = useRef(mode)
	modeRef.current = mode
	const addSessionRef = useRef(useSessionStore.getState().addSession)
	addSessionRef.current = useSessionStore.getState().addSession

	useEffect(() => {
		const unlistenToggle = listen('toggle-recording', () => {
			if (isRecordingRef.current) {
				stopRef.current()
			} else {
				startRef.current()
			}
		})
		const unlistenPause = listen('pause-recording', () => {
			if (isRecordingRef.current) {
				togglePauseRef.current()
			}
		})
		return () => {
			if (timerRef.current) clearInterval(timerRef.current)
			if (transcribeIntervalRef.current) clearInterval(transcribeIntervalRef.current)
			if (levelIntervalRef.current) clearInterval(levelIntervalRef.current)
			unlistenToggle.then((fn) => fn())
			unlistenPause.then((fn) => fn())
		}
	}, [])

	const transcribeAccumulated = useCallback(async () => {
		if (transcribingRef.current) return
		const chunks = pcmBufferRef.current
		if (chunks.length === 0) return

		const totalLength = chunks.reduce((sum, c) => sum + c.length, 0)
		if (totalLength < 16000) return

		const allSamples = new Float32Array(totalLength)
		let offset = 0
		for (const chunk of chunks) {
			allSamples.set(chunk, offset)
			offset += chunk.length
		}

		transcribingRef.current = true
		try {
			const modelName = await getSetting('whisper_model').catch(() => null) || 'large-v3-turbo'
			const language = await getSetting('whisper_language').catch(() => null) || null
			const b64 = float32ToBase64(allSamples)
			const text = await invoke<string>('transcribe_chunk', { samplesB64: b64, modelName, language })
			if (text) {
				liveTranscriptRef.current = text
				setLiveTranscript(text)
			}
		} catch (err) {
			console.error('Live transcription error:', err)
		} finally {
			transcribingRef.current = false
		}
	}, [])

	const startNote = useCallback(async () => {
		try {
			const savedDeviceId = await getSetting('mic_device_id').catch(() => null)
			const stream = await navigator.mediaDevices.getUserMedia({
				audio: savedDeviceId
					? { deviceId: { exact: savedDeviceId } }
					: true,
			})

			streamRef.current = stream
			pcmBufferRef.current = []
			liveTranscriptRef.current = ''
			setLiveTranscript('')

			const audioContext = new AudioContext()
			audioContextRef.current = audioContext

			const source = audioContext.createMediaStreamSource(stream)
			const processor = audioContext.createScriptProcessor(4096, 1, 1)
			processorRef.current = processor

			const capturedRate = audioContext.sampleRate

			processor.onaudioprocess = (e) => {
				const input = e.inputBuffer.getChannelData(0)
				const resampled = resample(new Float32Array(input), capturedRate, 16000)
				pcmBufferRef.current.push(resampled)
			}

			source.connect(processor)
			processor.connect(audioContext.destination)

			transcribeIntervalRef.current = setInterval(() => {
				transcribeAccumulated()
			}, 3000)

			setIsRecording(true)
			isRecordingRef.current = true
			setIsPaused(false)
			isPausedRef.current = false
			setDuration(0)
			durationRef.current = 0

			timerRef.current = setInterval(() => {
				durationRef.current += 1
				setDuration(durationRef.current)
			}, 1000)

			updateTrayState('recording')
		} catch (err) {
			console.error('Failed to start recording:', err)
		}
	}, [transcribeAccumulated])

	const startMeeting = useCallback(async () => {
		try {
			setError(null)
			const sessionId = crypto.randomUUID()

			await invoke('start_meeting_capture', { sessionId })

			setIsRecording(true)
			isRecordingRef.current = true
			setIsPaused(false)
			isPausedRef.current = false
			setDuration(0)
			durationRef.current = 0

			timerRef.current = setInterval(() => {
				durationRef.current += 1
				setDuration(durationRef.current)
			}, 1000)

			// Poll audio levels for UI meters
			levelIntervalRef.current = setInterval(async () => {
				try {
					const levels = await invoke<{ mic_level: number; system_level: number }>(
						'get_meeting_audio_levels',
					)
					setMicLevel(levels.mic_level)
					setSystemLevel(levels.system_level)
				} catch {
					// ignore
				}
			}, 100)

			updateTrayState('recording')
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err)
			console.error('Failed to start meeting capture:', message)
			setError(message)
		}
	}, [])

	const start = useCallback(async () => {
		if (modeRef.current === 'meeting') {
			await startMeeting()
		} else {
			await startNote()
		}
	}, [startNote, startMeeting])

	const stopNote = useCallback(async () => {
		if (!isRecordingRef.current) return

		setIsRecording(false)
		isRecordingRef.current = false
		setIsPaused(false)
		isPausedRef.current = false

		if (timerRef.current) {
			clearInterval(timerRef.current)
			timerRef.current = null
		}
		if (transcribeIntervalRef.current) {
			clearInterval(transcribeIntervalRef.current)
			transcribeIntervalRef.current = null
		}

		processorRef.current?.disconnect()
		processorRef.current = null

		streamRef.current?.getTracks().forEach((t) => t.stop())
		streamRef.current = null

		if (audioContextRef.current) {
			try { await audioContextRef.current.close() } catch {}
			audioContextRef.current = null
		}

		updateTrayState('idle')

		const chunks = pcmBufferRef.current
		if (chunks.length === 0) return

		const totalLength = chunks.reduce((sum, c) => sum + c.length, 0)
		const samples = new Float32Array(totalLength)
		let offset = 0
		for (const chunk of chunks) {
			samples.set(chunk, offset)
			offset += chunk.length
		}
		pcmBufferRef.current = []

		const sessionId = crypto.randomUUID()
		const finalDuration = durationRef.current
		const finalTranscript = liveTranscriptRef.current

		try {
			const audioPath = await saveAudioFile(samples, 16000, sessionId)
			await addSessionRef.current({
				id: sessionId,
				type: 'note',
				duration: finalDuration,
				audioPath,
			})

			if (finalTranscript) {
				const { updateSession } = useSessionStore.getState()
				await updateSession(sessionId, { transcript: finalTranscript })
			}

			navigateRef.current(`/session/${sessionId}`)
			processSession(sessionId, audioPath, finalTranscript || undefined)
		} catch (err) {
			console.error('Failed to save recording:', err)
		}

		liveTranscriptRef.current = ''
		setLiveTranscript('')
	}, [])

	const stopMeeting = useCallback(async () => {
		if (!isRecordingRef.current) return

		setIsRecording(false)
		isRecordingRef.current = false
		setIsPaused(false)
		isPausedRef.current = false

		if (timerRef.current) {
			clearInterval(timerRef.current)
			timerRef.current = null
		}
		if (levelIntervalRef.current) {
			clearInterval(levelIntervalRef.current)
			levelIntervalRef.current = null
		}

		updateTrayState('idle')
		setMicLevel(0)
		setSystemLevel(0)

		try {
			const result = await invoke<{
				mic_path: string
				system_path: string
				mixed_path: string
				duration: number
			}>('stop_meeting_capture')

			const sessionId = crypto.randomUUID()
			const finalDuration = durationRef.current

			await addSessionRef.current({
				id: sessionId,
				type: 'meeting',
				duration: finalDuration,
				audioPath: result.mixed_path,
			})

			navigateRef.current(`/session/${sessionId}`)
			processMeetingSession(sessionId, result.mic_path, result.system_path)
		} catch (err) {
			console.error('Failed to stop meeting capture:', err)
		}
	}, [])

	const stop = useCallback(async () => {
		if (modeRef.current === 'meeting') {
			await stopMeeting()
		} else {
			await stopNote()
		}
	}, [stopNote, stopMeeting])

	const togglePause = useCallback(async () => {
		if (!isRecordingRef.current) return

		// Pause/resume only supported in note mode
		if (modeRef.current === 'meeting') return

		if (isPausedRef.current) {
			if (audioContextRef.current?.state === 'suspended') {
				await audioContextRef.current.resume()
			}

			transcribeIntervalRef.current = setInterval(() => {
				transcribeAccumulated()
			}, 3000)

			timerRef.current = setInterval(() => {
				durationRef.current += 1
				setDuration(durationRef.current)
			}, 1000)

			setIsPaused(false)
			isPausedRef.current = false
			updateTrayState('recording')
		} else {
			if (audioContextRef.current?.state === 'running') {
				await audioContextRef.current.suspend()
			}

			if (transcribeIntervalRef.current) {
				clearInterval(transcribeIntervalRef.current)
				transcribeIntervalRef.current = null
			}
			if (timerRef.current) {
				clearInterval(timerRef.current)
				timerRef.current = null
			}

			setIsPaused(true)
			isPausedRef.current = true
			updateTrayState('paused')
		}
	}, [transcribeAccumulated])

	startRef.current = start
	stopRef.current = stop
	togglePauseRef.current = togglePause

	return { isRecording, isPaused, duration, liveTranscript, micLevel, systemLevel, error, start, stop, togglePause }
}
