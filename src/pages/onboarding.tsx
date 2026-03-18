import { useState, useEffect, useCallback } from 'react'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { setSetting } from '@/lib/settings'
import { getPromptByStyle } from '@/lib/dictation-styles'
import { Progress } from '@/components/ui/progress'
import { Check, Mic, Shield } from 'lucide-react'

const LANGUAGES = [
	{ value: 'en', label: 'English' },
	{ value: 'sv', label: 'Svenska' },
	{ value: 'de', label: 'Deutsch' },
	{ value: 'fr', label: 'Fran\u00e7ais' },
	{ value: 'es', label: 'Espa\u00f1ol' },
	{ value: '', label: 'Auto' },
]

type Step = 'welcome' | 'language' | 'permissions' | 'model' | 'ready'

const STEPS: Step[] = ['welcome', 'language', 'permissions', 'model', 'ready']

export function OnboardingPage({ onComplete }: { onComplete: () => void }) {
	const [step, setStep] = useState<Step>('welcome')
	const [animating, setAnimating] = useState(false)
	const [selectedLanguage, setSelectedLanguage] = useState<string | null>(null)

	// Permissions
	const [accessibilityGranted, setAccessibilityGranted] = useState(false)
	const [micGranted, setMicGranted] = useState(false)
	const [checkingAccessibility, setCheckingAccessibility] = useState(false)
	const [checkingMic, setCheckingMic] = useState(false)

	// Model download
	const [downloadProgress, setDownloadProgress] = useState({ downloaded: 0, total: 0 })
	const [downloadError, setDownloadError] = useState<string | null>(null)
	const [downloadComplete, setDownloadComplete] = useState(false)

	const goTo = useCallback((next: Step) => {
		setAnimating(true)
		setTimeout(() => {
			setStep(next)
			setAnimating(false)
		}, 200)
	}, [])

	// Check initial states when reaching permissions step
	useEffect(() => {
		if (step === 'permissions') {
			invoke<boolean>('check_accessibility').then(setAccessibilityGranted)
			navigator.mediaDevices.getUserMedia({ audio: true })
				.then((stream) => {
					stream.getTracks().forEach((t) => t.stop())
					setMicGranted(true)
				})
				.catch(() => {
					navigator.mediaDevices.enumerateDevices().then((devices) => {
						if (devices.some((d) => d.kind === 'audioinput' && d.label)) {
							setMicGranted(true)
						}
					})
				})
		}
	}, [step])

	// Auto-start model download when reaching model step
	useEffect(() => {
		if (step !== 'model' || downloadComplete) return

		let cancelled = false

		async function startDownload() {
			try {
				await invoke('download_model', { modelName: 'large-v3-turbo' })
				if (!cancelled) {
					await setSetting('whisper_model', 'large-v3-turbo')
					setDownloadComplete(true)
				}
			} catch (e) {
				if (!cancelled) setDownloadError(String(e))
			}
		}

		startDownload()
		return () => { cancelled = true }
	}, [step, downloadComplete])

	// Auto-advance after download completes
	useEffect(() => {
		if (!downloadComplete || step !== 'model') return
		const timer = setTimeout(() => goTo('ready'), 600)
		return () => clearTimeout(timer)
	}, [downloadComplete, step, goTo])

	// Listen for download progress
	useEffect(() => {
		const unlisten = listen<{ downloaded: number; total: number }>(
			'model-download-progress',
			(event) => setDownloadProgress(event.payload),
		)
		return () => { unlisten.then((fn) => fn()) }
	}, [])

	const progressPercent = downloadProgress.total > 0
		? Math.round((downloadProgress.downloaded / downloadProgress.total) * 100)
		: 0

	async function handleLanguageSelect(lang: string) {
		setSelectedLanguage(lang)
		if (lang) {
			await setSetting('whisper_language', lang)
		}
		await invoke('set_language', { language: lang })
		const prompt = getPromptByStyle('balanced', lang || 'en')
		if (prompt) await invoke('set_prompt', { prompt })
		setTimeout(() => goTo('permissions'), 300)
	}

	async function handleGrantAccessibility() {
		setCheckingAccessibility(true)
		await invoke('request_accessibility')
		const poll = setInterval(async () => {
			const granted = await invoke<boolean>('check_accessibility')
			if (granted) {
				setAccessibilityGranted(true)
				setCheckingAccessibility(false)
				clearInterval(poll)
			}
		}, 1000)
		setTimeout(() => {
			clearInterval(poll)
			setCheckingAccessibility(false)
		}, 60000)
	}

	async function handleGrantMic() {
		setCheckingMic(true)
		try {
			const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
			stream.getTracks().forEach((t) => t.stop())
			setMicGranted(true)
		} catch {
			// Permission denied
		} finally {
			setCheckingMic(false)
		}
	}

	async function handleComplete() {
		await setSetting('onboarding_complete', 'true')
		onComplete()
	}

	return (
		<div className="flex h-full flex-col bg-background">
			{/* Titlebar drag region */}
			<div className="h-12 shrink-0" data-tauri-drag-region />

			{/* Content */}
			<div className="flex flex-1 flex-col items-center justify-center px-8">
				<div
					className={`flex w-full max-w-[280px] flex-col items-center text-center transition-all duration-200 ${
						animating
							? 'translate-y-2 opacity-0'
							: 'translate-y-0 opacity-100'
					}`}
				>
					{step === 'welcome' && (
						<>
							<h1 className="font-brand text-[36px] font-bold tracking-tight text-foreground">
								yap
							</h1>
							<p className="mt-1.5 text-[13px] font-medium text-muted-foreground/60">
								push-to-talk dictation
							</p>
							<p className="mt-6 text-[12px] leading-relaxed text-muted-foreground/40">
								hold a key, speak, release — text appears wherever your cursor is
							</p>
							<button
								onClick={() => goTo('language')}
								className="mt-10 w-full rounded-lg bg-foreground px-5 py-2.5 text-[12px] font-medium text-background transition-opacity hover:opacity-90"
							>
								get started
							</button>
						</>
					)}

					{step === 'language' && (
						<>
							<h2 className="text-[18px] font-semibold tracking-tight text-foreground">
								what language do you speak?
							</h2>
							<div className="mt-8 grid w-full grid-cols-2 gap-2">
								{LANGUAGES.map((lang) => (
									<button
										key={lang.value}
										onClick={() => handleLanguageSelect(lang.value)}
										className={`rounded-lg border px-4 py-3 text-[12px] font-medium transition-all ${
											selectedLanguage === lang.value
												? 'border-foreground/30 bg-foreground/10 text-foreground'
												: 'border-border/40 text-muted-foreground/60 hover:border-border hover:bg-white/[0.02] hover:text-foreground/80'
										}`}
									>
										{lang.label}
									</button>
								))}
							</div>
						</>
					)}

					{step === 'permissions' && (
						<>
							<h2 className="text-[18px] font-semibold tracking-tight text-foreground">
								yap needs two permissions
							</h2>
							<div className="mt-8 w-full space-y-3">
								<div className="flex items-center justify-between rounded-lg border border-border/40 px-4 py-3">
									<div className="flex items-center gap-3">
										<Shield size={16} className={accessibilityGranted ? 'text-success' : 'text-muted-foreground/40'} />
										<div className="text-left">
											<p className="text-[12px] font-medium text-foreground/80">accessibility</p>
											<p className="text-[10px] text-muted-foreground/40">for hotkey + paste</p>
										</div>
									</div>
									{accessibilityGranted ? (
										<Check size={14} className="text-success" />
									) : (
										<button
											onClick={handleGrantAccessibility}
											disabled={checkingAccessibility}
											className="rounded-md bg-foreground/10 px-3 py-1.5 text-[10px] font-medium text-foreground/70 transition-colors hover:bg-foreground/15 disabled:opacity-50"
										>
											{checkingAccessibility ? 'waiting...' : 'grant'}
										</button>
									)}
								</div>

								<div className="flex items-center justify-between rounded-lg border border-border/40 px-4 py-3">
									<div className="flex items-center gap-3">
										<Mic size={16} className={micGranted ? 'text-success' : 'text-muted-foreground/40'} />
										<div className="text-left">
											<p className="text-[12px] font-medium text-foreground/80">microphone</p>
											<p className="text-[10px] text-muted-foreground/40">to hear your voice</p>
										</div>
									</div>
									{micGranted ? (
										<Check size={14} className="text-success" />
									) : (
										<button
											onClick={handleGrantMic}
											disabled={checkingMic}
											className="rounded-md bg-foreground/10 px-3 py-1.5 text-[10px] font-medium text-foreground/70 transition-colors hover:bg-foreground/15 disabled:opacity-50"
										>
											{checkingMic ? 'waiting...' : 'connect'}
										</button>
									)}
								</div>
							</div>

							<button
								onClick={() => goTo('model')}
								disabled={!accessibilityGranted || !micGranted}
								className="mt-8 w-full rounded-lg bg-foreground px-5 py-2.5 text-[12px] font-medium text-background transition-opacity hover:opacity-90 disabled:opacity-20"
							>
								continue
							</button>
						</>
					)}

					{step === 'model' && (
						<>
							<h2 className="text-[18px] font-semibold tracking-tight text-foreground">
								downloading your brain
							</h2>
							<p className="mt-2 text-[11px] text-muted-foreground/40">
								large-v3-turbo model (1.6 GB)
							</p>

							{downloadError ? (
								<div className="mt-8 w-full space-y-3">
									<p className="text-[11px] text-destructive/70">{downloadError}</p>
									<button
										onClick={() => {
											setDownloadError(null)
											setDownloadComplete(false)
										}}
										className="rounded-md bg-foreground/10 px-4 py-2 text-[11px] font-medium text-foreground/70 transition-colors hover:bg-foreground/15"
									>
										retry
									</button>
								</div>
							) : (
								<div className="mt-8 w-full space-y-2">
									<Progress value={downloadComplete ? 100 : progressPercent} className="h-1.5" />
									<p className="text-[10px] tabular-nums text-muted-foreground/40">
										{downloadComplete ? 'done' : `${progressPercent}%`}
									</p>
								</div>
							)}

							<p className="mt-6 text-[10px] text-muted-foreground/25">
								everything runs locally — no cloud
							</p>
						</>
					)}

					{step === 'ready' && (
						<>
							<h2 className="text-[18px] font-semibold tracking-tight text-foreground">
								you're all set
							</h2>
							<div className="mt-8 flex flex-col items-center gap-2">
								<kbd className="rounded-lg border border-border/40 bg-white/[0.03] px-4 py-2 text-[14px] font-medium text-foreground/60">
									⌥R
								</kbd>
								<p className="text-[11px] text-muted-foreground/40">
									hold Right Option and start talking
								</p>
							</div>
							<button
								onClick={handleComplete}
								className="mt-10 w-full rounded-lg bg-foreground px-5 py-2.5 text-[12px] font-medium text-background transition-opacity hover:opacity-90"
							>
								start <span className="font-brand">yapping</span>
							</button>
						</>
					)}
				</div>
			</div>

			{/* Step indicator */}
			<div className="flex justify-center gap-1.5 pb-6">
				{STEPS.map((s) => (
					<div
						key={s}
						className={`h-1 rounded-full transition-all duration-300 ${
							s === step
								? 'w-4 bg-foreground/40'
								: STEPS.indexOf(s) < STEPS.indexOf(step)
									? 'w-1 bg-foreground/20'
									: 'w-1 bg-foreground/8'
						}`}
					/>
				))}
			</div>
		</div>
	)
}
