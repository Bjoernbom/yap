import * as React from 'react'
import { useState } from 'react'
import { Search } from 'lucide-react'
import { RecordButton } from '@/components/record-button'
import { SessionList } from '@/components/session-list'

export function HomePage() {
	const [search, setSearch] = useState('')

	return (
		<div className="flex h-full flex-col">
			<header className="flex items-center gap-4 border-b border-border px-6 py-4">
				<h1 className="text-lg font-semibold">Voice Thing</h1>
				<div className="relative ml-auto">
					<Search
						size={16}
						className="absolute left-3 top-1/2 -translate-y-1/2 text-text-tertiary"
					/>
					<input
						type="text"
						placeholder="Search recordings..."
						value={search}
						onChange={(e) => setSearch(e.target.value)}
						className="h-9 rounded-lg border border-border bg-bg-secondary pl-9 pr-4 text-sm text-text placeholder:text-text-tertiary focus:border-accent focus:outline-none"
					/>
				</div>
			</header>

			<div className="flex-1 overflow-auto px-6 py-4">
				<SessionList />
			</div>

			<div className="border-t border-border px-6 py-6">
				<div className="flex items-center justify-center">
					<RecordButton />
				</div>
			</div>
		</div>
	)
}
