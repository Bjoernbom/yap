import { Outlet, NavLink } from 'react-router-dom'
import { useGlobalShortcut } from '@/hooks/use-global-shortcut'

export function Layout() {
	useGlobalShortcut()

	return (
		<div className="flex h-full flex-col">
			<header
				className="flex h-12 shrink-0 items-center justify-between border-b border-white/[0.06] bg-bg/80 px-6 backdrop-blur-xl"
				data-tauri-drag-region
			>
				<NavLink
					to="/"
					className="text-[15px] font-medium tracking-tight text-text"
					data-tauri-drag-region
				>
					voice thing
				</NavLink>
				<NavLink
					to="/settings"
					className={({ isActive }) =>
						`text-[13px] transition-colors duration-150 ${
							isActive
								? 'text-text'
								: 'text-text-tertiary hover:text-text-secondary'
						}`
					}
				>
					setup
				</NavLink>
			</header>
			<main className="flex-1 overflow-hidden">
				<Outlet />
			</main>
		</div>
	)
}
