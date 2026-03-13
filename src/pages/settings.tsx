import * as React from 'react'
import { useState } from 'react'

export function SettingsPage() {
	const [apiKey, setApiKey] = useState('')
	const [model, setModel] = useState('claude')

	return (
		<div className="flex h-full flex-col">
			<header className="border-b border-border px-6 py-4">
				<h1 className="text-lg font-semibold">Settings</h1>
			</header>

			<div className="flex-1 overflow-auto px-6 py-6">
				<div className="mx-auto max-w-lg space-y-8">
					<section>
						<h2 className="mb-4 text-sm font-medium text-text-secondary">
							AI Provider
						</h2>
						<div className="space-y-3">
							<div>
								<label className="mb-1.5 block text-xs text-text-tertiary">
									Provider
								</label>
								<select
									value={model}
									onChange={(e) => setModel(e.target.value)}
									className="h-9 w-full rounded-lg border border-border bg-bg-secondary px-3 text-sm text-text focus:border-accent focus:outline-none"
								>
									<option value="claude">Anthropic (Claude)</option>
									<option value="openai">OpenAI (GPT)</option>
								</select>
							</div>
							<div>
								<label className="mb-1.5 block text-xs text-text-tertiary">
									API Key
								</label>
								<input
									type="password"
									value={apiKey}
									onChange={(e) => setApiKey(e.target.value)}
									placeholder="sk-..."
									className="h-9 w-full rounded-lg border border-border bg-bg-secondary px-3 text-sm text-text placeholder:text-text-tertiary focus:border-accent focus:outline-none"
								/>
							</div>
						</div>
					</section>

					<section>
						<h2 className="mb-4 text-sm font-medium text-text-secondary">
							Transcription
						</h2>
						<div className="rounded-lg border border-border bg-bg-secondary px-4 py-3 text-sm text-text-secondary">
							Using Whisper.cpp for local transcription.
							<br />
							<span className="text-xs text-text-tertiary">
								Model: base.en (requires Rust backend)
							</span>
						</div>
					</section>

					<section>
						<h2 className="mb-4 text-sm font-medium text-text-secondary">
							Storage
						</h2>
						<div className="rounded-lg border border-border bg-bg-secondary px-4 py-3 text-sm text-text-secondary">
							All data stored locally in app directory.
							<br />
							<span className="text-xs text-text-tertiary">
								~/Library/Application Support/voice-thing/
							</span>
						</div>
					</section>
				</div>
			</div>
		</div>
	)
}
