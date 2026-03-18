import { useState, useEffect } from 'react'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { open as shellOpen } from '@tauri-apps/plugin-shell'
import { getSetting, setSetting, deleteSetting } from '@/lib/settings'
import { STYLE_OPTIONS, getPromptByStyle } from '@/lib/dictation-styles'
import { getHotkeySymbol, getHotkeyLabel } from '@/lib/hotkeys'
import { checkForUpdates, downloadAndInstallUpdate, type UpdateInfo } from '@/lib/updates'
import { Loader2, Check, ChevronDown, ExternalLink } from 'lucide-react'
import { Progress } from '@/components/ui/progress'

const MODEL_OPTIONS = [
	{ value: 'large-v3-turbo', label: 'Turbo', size: '1.6 GB', badge: 'recommended' },
	{ value: 'large-v3', label: 'Large', size: '3 GB', badge: 'best' },
	{ value: 'medium', label: 'Medium', size: '1.5 GB', badge: '' },
	{ value: 'small', label: 'Small', size: '466 MB', badge: '' },
	{ value: 'base', label: 'Base', size: '142 MB', badge: '' },
	{ value: 'tiny', label: 'Tiny', size: '75 MB', badge: 'fast' },
]

const LANGUAGE_OPTIONS = [
	{ value: 'en', label: 'English' },
	{ value: 'sv', label: 'Svenska' },
	{ value: 'de', label: 'Deutsch' },
	{ value: 'fr', label: 'Français' },
	{ value: 'es', label: 'Español' },
	{ value: 'no', label: 'Norsk' },
	{ value: 'da', label: 'Dansk' },
	{ value: 'fi', label: 'Suomi' },
	{ value: 'nl', label: 'Nederlands' },
	{ value: 'it', label: 'Italiano' },
	{ value: 'pt', label: 'Português' },
	{ value: 'ja', label: '日本語' },
	{ value: 'zh', label: '中文' },
	{ value: 'ko', label: '한국어' },
	{ value: '', label: 'Auto' },
]

function Row({ label, children, status }: {
	label: string
	children: React.ReactNode
	status?: 'ok' | 'warn' | 'loading'
}) {
	return (
		<div className="space-y-2 border-b border-border/30 px-3.5 py-3">
			<div className="flex items-center gap-2">
				<span className="text-[10px] font-medium uppercase tracking-widest text-muted-foreground/60">
					{label}
				</span>
				{status === 'ok' && (
					<span className="flex items-center gap-0.5 text-[9px] font-medium text-success/80">
						<Check size={8} /> ok
					</span>
				)}
				{status === 'warn' && (
					<span className="text-[9px] font-medium text-amber">
						needs setup
					</span>
				)}
				{status === 'loading' && (
					<Loader2 size={9} className="animate-spin text-muted-foreground/55" />
				)}
			</div>
			{children}
		</div>
	)
}

function Select({ value, onChange, children }: {
	value: string
	onChange: (v: string) => void
	children: React.ReactNode
}) {
	return (
		<div className="relative">
			<select
				value={value}
				onChange={(e) => onChange(e.target.value)}
				className="h-7 w-full appearance-none rounded-md border border-border/60 bg-white/[0.02] px-2 pr-6 text-[11px] text-foreground/90 transition-colors focus:border-border focus:outline-none"
			>
				{children}
			</select>
			<ChevronDown size={10} className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground/50" />
		</div>
	)
}

function isModifierKey(code: string): boolean {
	return code.startsWith('Meta') || code.startsWith('Alt') || code.startsWith('Control') || code.startsWith('Shift')
}

function KeyRecorder({ value, onChange }: { value: string; onChange: (code: string) => void }) {
	const [recording, setRecording] = useState(false)
	const [heldModifiers, setHeldModifiers] = useState<string[]>([])

	useEffect(() => {
		if (!recording) {
			setHeldModifiers([])
			return
		}

		const mods = new Set<string>()

		function handleKeyDown(e: KeyboardEvent) {
			e.preventDefault()
			e.stopPropagation()

			if (e.code === 'Escape') {
				setRecording(false)
				return
			}

			if (isModifierKey(e.code)) {
				mods.add(e.code)
				setHeldModifiers([...mods])
			} else {
				// Non-modifier pressed → finalize combo
				const combo = mods.size > 0
					? [...mods, e.code].join('+')
					: e.code
				onChange(combo)
				setRecording(false)
			}
		}

		function handleKeyUp(e: KeyboardEvent) {
			e.preventDefault()
			e.stopPropagation()

			if (isModifierKey(e.code) && mods.has(e.code)) {
				// Modifier released without a primary key → use as lone modifier (or combo of modifiers)
				const combo = [...mods].join('+')
				if (combo) {
					onChange(combo)
					setRecording(false)
				}
			}
		}

		window.addEventListener('keydown', handleKeyDown, true)
		window.addEventListener('keyup', handleKeyUp, true)
		return () => {
			window.removeEventListener('keydown', handleKeyDown, true)
			window.removeEventListener('keyup', handleKeyUp, true)
		}
	}, [recording, onChange])

	const liveSymbol = heldModifiers.length > 0
		? heldModifiers.map((m) => getHotkeySymbol(m)).join(' ')
		: null

	return (
		<button
			onClick={() => setRecording(true)}
			className={`flex h-7 w-full items-center justify-between rounded-md border px-2 text-[11px] transition-colors ${
				recording
					? 'border-foreground/30 bg-foreground/5 text-foreground/90'
					: 'border-border/60 bg-white/[0.02] text-foreground/90 hover:border-border'
			}`}
		>
			{recording ? (
				<span className="text-muted-foreground/60">
					{liveSymbol ? <span className="text-foreground/80">{liveSymbol} + ...</span> : <span className="animate-pulse">press a key combo...</span>}
				</span>
			) : (
				<>
					<span>{getHotkeyLabel(value)}</span>
					<kbd className="rounded border border-border/40 bg-white/[0.04] px-1.5 py-0.5 text-[9px] font-medium text-foreground/70">
						{getHotkeySymbol(value)}
					</kbd>
				</>
			)}
		</button>
	)
}

export function SettingsPage() {
	const [modelDownloaded, setModelDownloaded] = useState<boolean | null>(null)
	const [downloading, setDownloading] = useState(false)
	const [downloadProgress, setDownloadProgress] = useState({ downloaded: 0, total: 0 })
	const [downloadError, setDownloadError] = useState<string | null>(null)
	const [micPermission, setMicPermission] = useState<'prompt' | 'granted' | 'denied'>('prompt')
	const [audioDevices, setAudioDevices] = useState<MediaDeviceInfo[]>([])
	const [selectedDeviceId, setSelectedDeviceId] = useState('')
	const [whisperModel, setWhisperModel] = useState('large-v3-turbo')
	const [whisperLanguage, setWhisperLanguage] = useState('en')
	const [hotkey, setHotkey] = useState('RightAlt')
	const [style, setStyle] = useState('balanced')
	const [accessibilityGranted, setAccessibilityGranted] = useState<boolean | null>(null)
	const [autostart, setAutostart] = useState(false)
	const [updateInfo, setUpdateInfo] = useState<UpdateInfo | null>(null)
	const [apiKey, setApiKey] = useState('')
	const [hasApiKey, setHasApiKey] = useState(false)
	const [updating, setUpdating] = useState(false)

	async function loadDevices() {
		const devices = await navigator.mediaDevices.enumerateDevices()
		const mics = devices.filter((d) => d.kind === 'audioinput' && d.deviceId)
		setAudioDevices(mics)
		const savedId = await getSetting('mic_device_id')
		if (savedId && mics.some((d) => d.deviceId === savedId)) setSelectedDeviceId(savedId)
		else if (mics.length > 0) setSelectedDeviceId(mics[0].deviceId)
	}

	useEffect(() => {
		async function load() {
			const [model, lang, hk, st] = await Promise.all([
				getSetting('whisper_model'),
				getSetting('whisper_language'),
				getSetting('hotkey'),
				getSetting('dictation_style'),
			])
			if (model) setWhisperModel(model)
			if (lang) setWhisperLanguage(lang)
			if (hk) setHotkey(hk)
			if (st) setStyle(st)

			const savedStyle = st || 'balanced'
			const savedLang = lang || 'en'
			const prompt = getPromptByStyle(savedStyle, savedLang)
			if (prompt) await invoke('set_prompt', { prompt })

			const [status, accessible] = await Promise.all([
				invoke<boolean>('check_model_status', { modelName: model || 'large-v3-turbo' }),
				invoke<boolean>('check_accessibility'),
			])
			setModelDownloaded(status)
			setAccessibilityGranted(accessible)

			invoke<boolean>('get_autostart').then(setAutostart).catch(() => {})

			const savedKey = await getSetting('claude_api_key')
			if (savedKey) {
				setApiKey(savedKey)
				setHasApiKey(true)
				await invoke('set_api_key', { key: savedKey })
			}
			checkForUpdates().then(setUpdateInfo).catch(() => {})

			try {
				const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
				stream.getTracks().forEach((t) => t.stop())
				setMicPermission('granted')
				await loadDevices()
			} catch {
				const devices = await navigator.mediaDevices.enumerateDevices()
				if (devices.some((d) => d.kind === 'audioinput' && d.label)) {
					setMicPermission('granted')
					await loadDevices()
				}
			}
		}
		load()

		const unlisten = listen<{ downloaded: number; total: number }>(
			'model-download-progress',
			(event) => setDownloadProgress(event.payload),
		)
		return () => { unlisten.then((fn) => fn()) }
	}, [])

	async function handleSelectDevice(deviceId: string) {
		setSelectedDeviceId(deviceId)
		await setSetting('mic_device_id', deviceId)
		const device = audioDevices.find((d) => d.deviceId === deviceId)
		if (device) await invoke('set_mic_device', { deviceName: device.label || null })
	}

	const progressPercent = downloadProgress.total > 0
		? Math.round((downloadProgress.downloaded / downloadProgress.total) * 100)
		: 0

	return (
		<div className="flex h-full flex-col animate-fade-in">
			<div className="flex-1 overflow-auto">
				{/* Accessibility banner */}
				{accessibilityGranted === false && (
					<div className="flex items-center justify-between border-b border-destructive/20 bg-destructive/[0.04] px-3.5 py-2.5">
						<div>
							<p className="text-[11px] font-medium text-destructive">accessibility needed</p>
							<p className="text-[10px] text-muted-foreground/60">for hotkey + paste to work</p>
						</div>
						<div className="flex items-center gap-1">
							<button
								onClick={async () => {
									await invoke('request_accessibility')
									const poll = setInterval(async () => {
										if (await invoke<boolean>('check_accessibility')) {
											setAccessibilityGranted(true)
											clearInterval(poll)
										}
									}, 1000)
									setTimeout(() => clearInterval(poll), 60000)
								}}
								className="rounded-md bg-foreground/12 px-2.5 py-1 text-[10px] font-medium text-foreground/80 transition-colors hover:bg-foreground/15"
							>
								grant
							</button>
							<button
								onClick={() => invoke('open_accessibility_settings')}
								className="flex h-6 w-6 items-center justify-center rounded-md text-muted-foreground/55 hover:text-foreground/60"
							>
								<ExternalLink size={11} />
							</button>
						</div>
					</div>
				)}

				{/* Trigger */}
				<Row label="trigger">
					<KeyRecorder
						value={hotkey}
						onChange={async (code) => {
							setHotkey(code)
							await setSetting('hotkey', code)
							await invoke('set_hotkey', { key: code })
						}}
					/>
					<p className="text-[10px] text-muted-foreground/50">hold to talk, release to paste</p>
				</Row>

				{/* Polish — API key */}
				<Row label="polish" status={hasApiKey ? 'ok' : undefined}>
					{hasApiKey ? (
						<div className="flex items-center justify-between">
							<span className="text-[11px] text-foreground/70">connected</span>
							<button
								onClick={async () => {
									setApiKey('')
									setHasApiKey(false)
									await deleteSetting('claude_api_key')
									await invoke('set_api_key', { key: null })
								}}
								className="text-[10px] text-muted-foreground/50 hover:text-destructive/60"
							>
								disconnect
							</button>
						</div>
					) : (
						<form onSubmit={async (e) => {
							e.preventDefault()
							if (!apiKey.startsWith('sk-')) return
							await setSetting('claude_api_key', apiKey)
							await invoke('set_api_key', { key: apiKey })
							setHasApiKey(true)
						}}>
							<input
								type="password"
								value={apiKey}
								onChange={(e) => setApiKey(e.target.value)}
								placeholder="sk-ant-..."
								className="h-7 w-full rounded-md border border-border/60 bg-white/[0.02] px-2 text-[11px] text-foreground/90 placeholder:text-muted-foreground/30 focus:border-border focus:outline-none"
							/>
							<p className="mt-1 text-[10px] text-muted-foreground/50">
								paste your claude api key — cleans up your speech with ai
							</p>
						</form>
					)}
				</Row>

				{/* Style — only when polish is enabled */}
				{hasApiKey && (
					<Row label="vibe">
						<div className="flex gap-1">
							{STYLE_OPTIONS.map((opt) => (
								<button
									key={opt.value}
									onClick={async () => {
										setStyle(opt.value)
										await setSetting('dictation_style', opt.value)
										const prompt = getPromptByStyle(opt.value, whisperLanguage)
										if (prompt) await invoke('set_prompt', { prompt })
									}}
									className={`flex-1 rounded-md px-2 py-1.5 text-center transition-all ${
										style === opt.value
											? 'bg-foreground/12 text-[11px] font-medium text-foreground/90'
											: 'text-[11px] text-muted-foreground/50 hover:bg-white/[0.02] hover:text-muted-foreground/60'
									}`}
								>
									{opt.label}
								</button>
							))}
						</div>
						<p className="text-[10px] text-muted-foreground/50">
							{STYLE_OPTIONS.find((s) => s.value === style)?.hint}
						</p>
					</Row>
				)}

				{/* Mic */}
				<Row label="mic" status={micPermission === 'granted' ? 'ok' : 'warn'}>
					{micPermission !== 'granted' ? (
						<button
							onClick={async () => {
								try {
									const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
									stream.getTracks().forEach((t) => t.stop())
									setMicPermission('granted')
									await loadDevices()
								} catch { setMicPermission('denied') }
							}}
							className="rounded-md bg-foreground/12 px-2.5 py-1 text-[10px] font-medium text-foreground/80 transition-colors hover:bg-foreground/15"
						>
							connect microphone
						</button>
					) : audioDevices.length > 1 ? (
						<Select value={selectedDeviceId} onChange={handleSelectDevice}>
							{audioDevices.map((d) => (
								<option key={d.deviceId} value={d.deviceId}>
									{d.label || `mic ${d.deviceId.slice(0, 6)}`}
								</option>
							))}
						</Select>
					) : (
						<p className="text-[11px] text-foreground/50">
							{audioDevices[0]?.label || 'default microphone'}
						</p>
					)}
				</Row>

				{/* Model */}
				<Row label="brain" status={modelDownloaded === null ? 'loading' : modelDownloaded ? 'ok' : 'warn'}>
					<div className="flex gap-1">
						{MODEL_OPTIONS.slice(0, 3).map((opt) => (
							<button
								key={opt.value}
								onClick={async () => {
									setWhisperModel(opt.value)
									await setSetting('whisper_model', opt.value)
									setModelDownloaded(await invoke<boolean>('check_model_status', { modelName: opt.value }))
								}}
								className={`flex-1 rounded-md px-1.5 py-1.5 text-center transition-all ${
									whisperModel === opt.value
										? 'bg-foreground/12 text-[10px] font-medium text-foreground/90'
										: 'text-[10px] text-muted-foreground/50 hover:bg-white/[0.02] hover:text-muted-foreground/60'
								}`}
							>
								<span>{opt.label}</span>
								{opt.badge && (
									<span className="ml-1 text-[8px] text-muted-foreground/50">{opt.badge}</span>
								)}
							</button>
						))}
					</div>

					{!modelDownloaded && !downloading && !downloadError && (
						<button
							onClick={async () => {
								setDownloading(true)
								setDownloadError(null)
								try {
									await invoke('download_model', { modelName: whisperModel })
									setModelDownloaded(true)
								} catch (e) {
									setDownloadError(String(e))
								} finally {
									setDownloading(false)
								}
							}}
							className="mt-1 w-full rounded-md bg-foreground/12 py-1.5 text-[10px] font-medium text-foreground/80 transition-colors hover:bg-foreground/15"
						>
							download {MODEL_OPTIONS.find((m) => m.value === whisperModel)?.label?.toLowerCase()} ({MODEL_OPTIONS.find((m) => m.value === whisperModel)?.size})
						</button>
					)}

					{downloading && (
						<div className="mt-1.5 space-y-1">
							<Progress value={progressPercent} className="h-1" />
							<p className="text-[10px] tabular-nums text-muted-foreground/55">{progressPercent}%</p>
						</div>
					)}

					{downloadError && (
						<div className="mt-1.5 space-y-1">
							<p className="text-[10px] text-destructive/70">{downloadError}</p>
							<button
								onClick={() => setDownloadError(null)}
								className="text-[10px] text-foreground/50 hover:text-foreground/70"
							>
								retry
							</button>
						</div>
					)}
				</Row>

				{/* Language */}
				<Row label="language">
					<Select value={whisperLanguage} onChange={async (v) => {
						setWhisperLanguage(v)
						if (v) await setSetting('whisper_language', v)
						else await deleteSetting('whisper_language')
						await invoke('set_language', { language: v })
						const prompt = getPromptByStyle(style, v || 'en')
						if (prompt) await invoke('set_prompt', { prompt })
					}}>
						{LANGUAGE_OPTIONS.map((o) => (
							<option key={o.value} value={o.value}>{o.label}</option>
						))}
					</Select>
				</Row>

				{/* Startup */}
				<Row label="startup">
					<button
						onClick={async () => {
							const next = !autostart
							await invoke('set_autostart', { enabled: next })
							setAutostart(next)
						}}
						className={`rounded-md px-2.5 py-1.5 text-[11px] font-medium transition-all ${
							autostart
								? 'bg-foreground/12 text-foreground/90'
								: 'text-muted-foreground/50 hover:bg-white/[0.02] hover:text-muted-foreground/60'
						}`}
					>
						{autostart ? 'launches on login' : 'manual'}
					</button>
				</Row>

				{/* Footer info */}
				<div className="px-3.5 py-3">
					<div className="space-y-1.5 text-[10px] text-muted-foreground/55">
						<div className="flex justify-between">
							<span>accessibility</span>
							<span className={accessibilityGranted ? 'text-success/60' : 'text-destructive/60'}>
								{accessibilityGranted === null ? '...' : accessibilityGranted ? 'granted' : 'missing'}
							</span>
						</div>
						<div className="flex justify-between">
							<span>storage</span>
							<span>text only</span>
						</div>
						<div className="flex justify-between">
							<span>transcription</span>
							<span>local</span>
						</div>
						{hasApiKey && (
							<div className="flex justify-between">
								<span>polish</span>
								<span>anthropic api</span>
							</div>
						)}
						<div className="flex justify-between">
							<span>v0.4.0</span>
							{updateInfo?.available && (
								<button
									onClick={async () => {
										setUpdating(true)
										try {
											await downloadAndInstallUpdate()
										} catch {
											shellOpen(updateInfo.url)
										}
										setUpdating(false)
									}}
									disabled={updating}
									className="text-foreground/50 transition-colors hover:text-foreground/70 disabled:opacity-50"
								>
									{updating ? 'updating...' : `v${updateInfo.version} — tap to update`}
								</button>
							)}
						</div>
					</div>
				</div>
			</div>
		</div>
	)
}
