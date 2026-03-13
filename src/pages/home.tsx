import { useState, useEffect, useRef } from 'react'
import { Search } from 'lucide-react'
import { RecordButton } from '@/components/record-button'
import { SessionList } from '@/components/session-list'
import { useSessionStore } from '@/stores/session-store'

export function HomePage() {
	const [search, setSearch] = useState('')
	const [searchOpen, setSearchOpen] = useState(false)
	const searchRef = useRef<HTMLInputElement>(null)
	const searchSessions = useSessionStore((s) => s.searchSessions)
	const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

	useEffect(() => {
		if (timerRef.current) clearTimeout(timerRef.current)
		timerRef.current = setTimeout(() => {
			searchSessions(search)
		}, 300)
		return () => {
			if (timerRef.current) clearTimeout(timerRef.current)
		}
	}, [search, searchSessions])

	useEffect(() => {
		if (searchOpen && searchRef.current) {
			searchRef.current.focus()
		}
	}, [searchOpen])

	return (
		<div className="relative flex h-full flex-col animate-fade-in">
			<div className="px-6">
				<div className="flex items-center justify-between py-3">
					<span className="section-label">Recordings</span>
					{searchOpen ? (
						<input
							ref={searchRef}
							type="text"
							placeholder="search..."
							value={search}
							onChange={(e) => setSearch(e.target.value)}
							onBlur={() => {
								if (!search) setSearchOpen(false)
							}}
							className="h-8 w-48 rounded-lg border border-border bg-bg-secondary px-3 text-[13px] text-text placeholder:text-text-tertiary focus:outline-none"
						/>
					) : (
						<button
							onClick={() => setSearchOpen(true)}
							className="flex h-8 w-8 items-center justify-center rounded-lg text-text-tertiary transition-colors duration-150 hover:bg-bg-secondary hover:text-text-secondary"
						>
							<Search size={16} strokeWidth={1.5} />
						</button>
					)}
				</div>
			</div>

			<div className="flex-1 overflow-auto">
				<div className="px-6 pb-40">
					<SessionList />
				</div>
			</div>

			<div className="pointer-events-none absolute inset-x-0 bottom-0 flex justify-center bg-gradient-to-t from-bg via-bg/80 to-transparent pb-8 pt-24">
				<div className="pointer-events-auto">
					<RecordButton />
				</div>
			</div>
		</div>
	)
}
