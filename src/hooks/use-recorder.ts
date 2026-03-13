import { useState, useRef, useCallback, useEffect } from 'react'
import { useSessionStore } from '@/stores/session-store'

export function useRecorder() {
	const [isRecording, setIsRecording] = useState(false)
	const [duration, setDuration] = useState(0)
	const mediaRecorderRef = useRef<MediaRecorder | null>(null)
	const chunksRef = useRef<Blob[]>([])
	const timerRef = useRef<ReturnType<typeof setInterval> | null>(null)
	const addSession = useSessionStore((s) => s.addSession)

	useEffect(() => {
		return () => {
			if (timerRef.current) clearInterval(timerRef.current)
		}
	}, [])

	const start = useCallback(async () => {
		try {
			const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
			const mediaRecorder = new MediaRecorder(stream, {
				mimeType: 'audio/webm;codecs=opus',
			})

			chunksRef.current = []
			mediaRecorderRef.current = mediaRecorder

			mediaRecorder.ondataavailable = (e) => {
				if (e.data.size > 0) {
					chunksRef.current.push(e.data)
				}
			}

			mediaRecorder.onstop = () => {
				const blob = new Blob(chunksRef.current, { type: 'audio/webm' })
				stream.getTracks().forEach((track) => track.stop())

				addSession({
					type: 'note',
					audioBlob: blob,
					duration,
				})
			}

			mediaRecorder.start(1000)
			setIsRecording(true)
			setDuration(0)

			timerRef.current = setInterval(() => {
				setDuration((d) => d + 1)
			}, 1000)
		} catch (err) {
			console.error('Failed to start recording:', err)
		}
	}, [addSession, duration])

	const stop = useCallback(() => {
		if (mediaRecorderRef.current?.state === 'recording') {
			mediaRecorderRef.current.stop()
		}
		if (timerRef.current) {
			clearInterval(timerRef.current)
			timerRef.current = null
		}
		setIsRecording(false)
	}, [])

	return { isRecording, duration, start, stop }
}
