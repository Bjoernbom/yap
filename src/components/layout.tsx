import * as React from 'react'
import { Outlet, NavLink } from 'react-router-dom'
import { Mic, Library, Settings } from 'lucide-react'

export function Layout() {
	return (
		<div className="flex h-full">
			<nav className="flex w-16 flex-col items-center gap-2 border-r border-border bg-bg-secondary py-4">
				<NavLink
					to="/"
					className={({ isActive }) =>
						`flex h-10 w-10 items-center justify-center rounded-lg transition-colors ${
							isActive
								? 'bg-accent text-white'
								: 'text-text-tertiary hover:bg-bg-tertiary hover:text-text'
						}`
					}
				>
					<Mic size={20} />
				</NavLink>
				<div className="mt-auto flex flex-col gap-2">
					<NavLink
						to="/settings"
						className={({ isActive }) =>
							`flex h-10 w-10 items-center justify-center rounded-lg transition-colors ${
								isActive
									? 'bg-accent text-white'
									: 'text-text-tertiary hover:bg-bg-tertiary hover:text-text'
							}`
						}
					>
						<Settings size={20} />
					</NavLink>
				</div>
			</nav>
			<main className="flex-1 overflow-auto">
				<Outlet />
			</main>
		</div>
	)
}
