import { invoke } from '@tauri-apps/api/core'
import { convertFileSrc } from '@tauri-apps/api/core'

function float32ToBase64(samples: Float32Array): string {
	const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength)
	let binary = ''
	for (let i = 0; i < bytes.length; i++) {
		binary += String.fromCharCode(bytes[i])
	}
	return btoa(binary)
}

export async function saveAudioFile(
	samples: Float32Array,
	_sampleRate: number,
	sessionId: string,
): Promise<string> {
	const b64 = float32ToBase64(samples)
	const audioPath = await invoke<string>('save_recording', {
		samplesB64: b64,
		sessionId,
	})
	return audioPath
}

export async function deleteAudioFile(audioPath: string): Promise<void> {
	try {
		await invoke('delete_recording', { audioPath })
	} catch {
		// File may not exist
	}
}

export function getAudioUrl(audioPath: string): string {
	return convertFileSrc(audioPath)
}
