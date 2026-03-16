import { Outlet, NavLink } from 'react-router-dom'
import { DictationBadge } from '@/components/dictation-badge'

export function Layout() {
	return (
		<div className="flex h-full flex-col">
			{/* Titlebar area — macOS traffic lights sit here */}
			<header
				className="flex h-12 shrink-0 items-end justify-between px-3.5 pb-1.5"
				data-tauri-drag-region
			>
				<NavLink
					to="/"
					className="text-[13px] font-semibold tracking-tight text-foreground/90"
				>
					yap
				</NavLink>
				<NavLink
					to="/settings"
					className={({ isActive }) =>
						`text-[11px] font-medium transition-colors ${
							isActive
								? 'text-foreground/70'
								: 'text-muted-foreground/40 hover:text-foreground/50'
						}`
					}
				>
					settings
				</NavLink>
			</header>
			<div className="mx-3.5 border-b border-border/30" />
			<main className="relative flex-1 overflow-hidden">
				<Outlet />
				<DictationBadge />
			</main>
		</div>
	)
}
