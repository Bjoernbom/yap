import { useState, useEffect } from 'react'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getSetting, setSetting, deleteSetting } from '@/lib/settings'
import { Loader2 } from 'lucide-react'

export function SettingsPage() {
	const [apiKey, setApiKey] = useState('')
	const [provider, setProvider] = useState('claude')
	const [modelDownloaded, setModelDownloaded] = useState<boolean | null>(null)
	const [downloading, setDownloading] = useState(false)
	const [downloadProgress, setDownloadProgress] = useState({
		downloaded: 0,
		total: 0,
	})
	const [saved, setSaved] = useState(false)
	const [micPermission, setMicPermission] = useState<
		'prompt' | 'granted' | 'denied'
	>('prompt')
	const [audioDevices, setAudioDevices] = useState<MediaDeviceInfo[]>([])
	const [selectedDeviceId, setSelectedDeviceId] = useState('')
	const [whisperModel, setWhisperModel] = useState('large-v3-turbo')
	const [whisperLanguage, setWhisperLanguage] = useState('')

	const [expandedSection, setExpandedSection] = useState<string | null>(null)
	const [screenPermission, setScreenPermission] = useState<boolean | null>(null)
	const [pyannoteReady, setPyannoteReady] = useState<boolean | null>(null)
	const [downloadingPyannote, setDownloadingPyannote] = useState(false)

	async function loadDevices() {
		const devices = await navigator.mediaDevices.enumerateDevices()
		const mics = devices.filter(
			(d) => d.kind === 'audioinput' && d.deviceId,
		)
		setAudioDevices(mics)

		const savedId = await getSetting('mic_device_id')
		if (savedId && mics.some((d) => d.deviceId === savedId)) {
			setSelectedDeviceId(savedId)
		} else if (mics.length > 0) {
			setSelectedDeviceId(mics[0].deviceId)
		}
	}

	async function checkMicPermission() {
		try {
			const stream = await navigator.mediaDevices.getUserMedia({
				audio: true,
			})
			stream.getTracks().forEach((t) => t.stop())
			setMicPermission('granted')
			await loadDevices()
		} catch {
			setMicPermission('denied')
		}
	}

	useEffect(() => {
		async function load() {
			const key = await getSetting('api_key')
			const prov = await getSetting('provider')
			const model = await getSetting('whisper_model')
			const lang = await getSetting('whisper_language')
			if (key) setApiKey(key)
			if (prov) setProvider(prov)
			if (model) setWhisperModel(model)
			if (lang) setWhisperLanguage(lang)

			const modelName = model || 'large-v3-turbo'
			const status = await invoke<boolean>('check_model_status', {
				modelName,
			})
			setModelDownloaded(status)

			const devices = await navigator.mediaDevices.enumerateDevices()
			const mics = devices.filter((d) => d.kind === 'audioinput')
			if (mics.length > 0 && mics[0].label) {
				setMicPermission('granted')
				await loadDevices()
			}

			// Check system audio permission
			try {
				const perm = await invoke<boolean>('check_screen_recording_permission')
				setScreenPermission(perm)
			} catch {
				setScreenPermission(false)
			}

			// Check pyannote models
			try {
				const ready = await invoke<boolean>('check_pyannote_models')
				setPyannoteReady(ready)
			} catch {
				setPyannoteReady(false)
			}
		}
		load()

		const unlisten = listen<{ downloaded: number; total: number }>(
			'model-download-progress',
			(event) => {
				setDownloadProgress(event.payload)
			},
		)

		return () => {
			unlisten.then((fn) => fn())
		}
	}, [])

	async function handleSelectDevice(deviceId: string) {
		setSelectedDeviceId(deviceId)
		await setSetting('mic_device_id', deviceId)
	}

	async function handleSaveApiKey() {
		if (apiKey.trim()) {
			await setSetting('api_key', apiKey.trim())
		} else {
			await deleteSetting('api_key')
		}
		await setSetting('provider', provider)
		setSaved(true)
		setTimeout(() => setSaved(false), 2000)
	}

	async function handleSelectModel(model: string) {
		setWhisperModel(model)
		await setSetting('whisper_model', model)
		const status = await invoke<boolean>('check_model_status', {
			modelName: model,
		})
		setModelDownloaded(status)
	}

	async function handleSelectLanguage(lang: string) {
		setWhisperLanguage(lang)
		if (lang) {
			await setSetting('whisper_language', lang)
		} else {
			await deleteSetting('whisper_language')
		}
	}

	async function handleDownloadModel() {
		setDownloading(true)
		try {
			await invoke('download_model', { modelName: whisperModel })
			setModelDownloaded(true)
		} catch (err) {
			console.error('Model download failed:', err)
		} finally {
			setDownloading(false)
		}
	}

	const progressPercent =
		downloadProgress.total > 0
			? Math.round(
					(downloadProgress.downloaded / downloadProgress.total) * 100,
				)
			: 0

	const selectedMic = audioDevices.find(
		(d) => d.deviceId === selectedDeviceId,
	)

	const modelLabels: Record<string, string> = {
		tiny: 'tiny (~75 MB)',
		base: 'base (~142 MB)',
		small: 'small (~466 MB)',
		medium: 'medium (~1.5 GB)',
		'large-v3': 'large v3 (~3 GB)',
		'large-v3-turbo': 'large v3 turbo (~1.6 GB)',
	}

	return (
		<div className="flex h-full flex-col animate-fade-in">
			<div className="flex-1 overflow-auto px-6 py-6">
				<div className="mx-auto max-w-lg space-y-3">
					{/* Microphone */}
					<div className="rounded-xl bg-bg-secondary p-4">
						<div className="flex items-center justify-between">
							<div>
								<span className="section-label">microphone</span>
								<p className="mt-1 text-[13px] text-text">
									{micPermission === 'granted'
										? selectedMic?.label || 'connected'
										: micPermission === 'denied'
											? 'mic access blocked'
											: 'not connected'}
								</p>
							</div>
							{micPermission === 'granted' ? (
								<button
									onClick={() =>
										setExpandedSection(
											expandedSection === 'mic'
												? null
												: 'mic',
										)
									}
									className="text-[13px] text-text-tertiary transition-colors duration-150 hover:text-text-secondary"
								>
									change
								</button>
							) : micPermission === 'denied' ? (
								<button
									onClick={checkMicPermission}
									className="text-[13px] text-accent transition-colors duration-150 hover:text-accent-hover"
								>
									fix in settings
								</button>
							) : (
								<button
									onClick={checkMicPermission}
									className="text-[13px] text-accent transition-colors duration-150 hover:text-accent-hover"
								>
									connect
								</button>
							)}
						</div>
						{expandedSection === 'mic' && audioDevices.length > 0 && (
							<div className="mt-3 border-t border-border pt-3">
								<select
									value={selectedDeviceId}
									onChange={(e) =>
										handleSelectDevice(e.target.value)
									}
									className="h-9 w-full rounded-lg bg-bg-tertiary px-3 text-[13px] text-text focus:outline-none"
								>
									{audioDevices.map((device) => (
										<option
											key={device.deviceId}
											value={device.deviceId}
										>
											{device.label ||
												`Microphone ${device.deviceId.slice(0, 8)}`}
										</option>
									))}
								</select>
							</div>
						)}
					</div>

					{/* System Audio (Meeting Recording) */}
					<div className="rounded-xl bg-bg-secondary p-4">
						<div className="flex items-center justify-between">
							<div>
								<span className="section-label">system audio</span>
								<p className="mt-1 text-[13px] text-text">
									{screenPermission === null
										? 'checking...'
										: screenPermission
											? 'screen recording allowed'
											: 'permission needed'}
								</p>
								{screenPermission && (
									<p className="mt-0.5 text-[12px] text-success">
										ready for meeting capture
									</p>
								)}
							</div>
							{screenPermission === false && (
								<button
									onClick={async () => {
										await invoke('request_screen_recording_permission')
										const ok = await invoke<boolean>('check_screen_recording_permission')
										setScreenPermission(ok)
									}}
									className="text-[13px] text-accent transition-colors duration-150 hover:text-accent-hover"
								>
									grant access
								</button>
							)}
						</div>
						{screenPermission === false && (
							<p className="mt-2 text-[11px] text-text-tertiary">
								Voice Thing needs Screen Recording permission to capture system audio from Zoom, Teams, and other apps.
							</p>
						)}
					</div>

					{/* Speaker Diarization Models */}
					<div className="rounded-xl bg-bg-secondary p-4">
						<div className="flex items-center justify-between">
							<div>
								<span className="section-label">speaker detection</span>
								<p className="mt-1 text-[13px] text-text">
									{pyannoteReady === null
										? 'checking...'
										: pyannoteReady
											? 'models downloaded (~30 MB)'
											: 'models needed (~30 MB)'}
								</p>
								{pyannoteReady && (
									<p className="mt-0.5 text-[12px] text-success">
										ready
									</p>
								)}
							</div>
							{pyannoteReady === null ? (
								<Loader2
									size={14}
									strokeWidth={1.5}
									className="animate-spin text-text-tertiary"
								/>
							) : pyannoteReady ? null : downloadingPyannote ? (
								<Loader2
									size={14}
									strokeWidth={1.5}
									className="animate-spin text-accent"
								/>
							) : (
								<button
									onClick={async () => {
										setDownloadingPyannote(true)
										try {
											await invoke('download_pyannote_models')
											setPyannoteReady(true)
										} catch (err) {
											console.error('Pyannote download failed:', err)
										} finally {
											setDownloadingPyannote(false)
										}
									}}
									className="text-[13px] text-accent transition-colors duration-150 hover:text-accent-hover"
								>
									download
								</button>
							)}
						</div>
						<p className="mt-2 text-[11px] text-text-tertiary">
							Required for identifying who said what in meeting recordings.
						</p>
					</div>

					{/* Transcription model */}
					<div className="rounded-xl bg-bg-secondary p-4">
						<div className="flex items-center justify-between">
							<div>
								<span className="section-label">
									transcription
								</span>
								<p className="mt-1 text-[13px] text-text">
									{modelDownloaded === null
										? 'checking...'
										: modelDownloaded
											? modelLabels[whisperModel] ||
												whisperModel
											: 'model needed'}
								</p>
								{modelDownloaded && (
									<p className="mt-0.5 text-[12px] text-success">
										ready
									</p>
								)}
							</div>
							{modelDownloaded === null ? (
								<Loader2
									size={14}
									strokeWidth={1.5}
									className="animate-spin text-text-tertiary"
								/>
							) : modelDownloaded ? (
								<button
									onClick={() =>
										setExpandedSection(
											expandedSection === 'model'
												? null
												: 'model',
										)
									}
									className="text-[13px] text-text-tertiary transition-colors duration-150 hover:text-text-secondary"
								>
									change
								</button>
							) : downloading ? null : (
								<button
									onClick={handleDownloadModel}
									className="text-[13px] text-accent transition-colors duration-150 hover:text-accent-hover"
								>
									download
								</button>
							)}
						</div>

						{downloading && (
							<div className="mt-3 space-y-2 border-t border-border pt-3">
								<p className="text-[13px] text-text-secondary">
									getting the brain ready{'  '}
									<span className="mono">{progressPercent}%</span>
								</p>
								<div className="h-1.5 overflow-hidden rounded-full bg-bg-tertiary">
									<div
										className="h-full rounded-full bg-accent transition-all"
										style={{
											width: `${progressPercent}%`,
										}}
									/>
								</div>
							</div>
						)}

						{expandedSection === 'model' && !downloading && (
							<div className="mt-3 space-y-3 border-t border-border pt-3">
								<select
									value={whisperModel}
									onChange={(e) =>
										handleSelectModel(e.target.value)
									}
									className="h-9 w-full rounded-lg bg-bg-tertiary px-3 text-[13px] text-text focus:outline-none"
								>
									<option value="tiny">
										tiny (~75 MB) — fastest
									</option>
									<option value="base">
										base (~142 MB)
									</option>
									<option value="small">
										small (~466 MB)
									</option>
									<option value="medium">
										medium (~1.5 GB)
									</option>
									<option value="large-v3">
										large v3 (~3 GB) — best quality
									</option>
									<option value="large-v3-turbo">
										large v3 turbo (~1.6 GB) — recommended
									</option>
								</select>

								<div>
									<label className="mb-1.5 block text-[12px] text-text-tertiary">
										language
									</label>
									<select
										value={whisperLanguage}
										onChange={(e) =>
											handleSelectLanguage(e.target.value)
										}
										className="h-9 w-full rounded-lg bg-bg-tertiary px-3 text-[13px] text-text focus:outline-none"
									>
										<option value="">auto-detect</option>
										<option value="sv">Svenska</option>
										<option value="en">English</option>
										<option value="de">Deutsch</option>
										<option value="fr">Français</option>
										<option value="es">Español</option>
										<option value="no">Norsk</option>
										<option value="da">Dansk</option>
										<option value="fi">Suomi</option>
										<option value="nl">Nederlands</option>
										<option value="it">Italiano</option>
										<option value="pt">Português</option>
										<option value="ja">日本語</option>
										<option value="zh">中文</option>
										<option value="ko">한국어</option>
									</select>
								</div>
							</div>
						)}
					</div>

					{/* AI Provider */}
					<div className="rounded-xl bg-bg-secondary p-4">
						<div className="flex items-center justify-between">
							<div>
								<span className="section-label">
									ai provider
								</span>
								<p className="mt-1 text-[13px] text-text">
									{provider === 'claude'
										? 'anthropic (claude)'
										: 'openai (gpt)'}
								</p>
								{apiKey && (
									<p className="mt-0.5 text-[12px] text-success">
										configured
									</p>
								)}
							</div>
							<button
								onClick={() =>
									setExpandedSection(
										expandedSection === 'ai'
											? null
											: 'ai',
									)
								}
								className="text-[13px] text-text-tertiary transition-colors duration-150 hover:text-text-secondary"
							>
								{apiKey ? 'change' : 'configure'}
							</button>
						</div>
						{expandedSection === 'ai' && (
							<div className="mt-3 space-y-3 border-t border-border pt-3">
								<select
									value={provider}
									onChange={(e) => setProvider(e.target.value)}
									className="h-9 w-full rounded-lg bg-bg-tertiary px-3 text-[13px] text-text focus:outline-none"
								>
									<option value="claude">
										anthropic (claude)
									</option>
									<option value="openai">
										openai (gpt)
									</option>
								</select>
								<input
									type="password"
									value={apiKey}
									onChange={(e) => setApiKey(e.target.value)}
									placeholder="sk-..."
									className="h-9 w-full rounded-lg bg-bg-tertiary px-3 text-[13px] text-text placeholder:text-text-tertiary focus:outline-none"
								/>
								<button
									onClick={handleSaveApiKey}
									className="text-[13px] text-accent transition-colors duration-150 hover:text-accent-hover"
								>
									{saved ? 'saved' : 'save'}
								</button>
							</div>
						)}
					</div>

					{/* Storage */}
					<div className="rounded-xl bg-bg-secondary p-4">
						<span className="section-label">storage</span>
						<p className="mt-1 text-[13px] text-text-secondary">
							all data stored locally
						</p>
						<p className="mt-0.5 mono text-[11px] text-text-tertiary">
							~/Library/Application Support/com.voicething.app/
						</p>
					</div>
				</div>
			</div>
		</div>
	)
}
