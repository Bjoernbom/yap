import { TrayIcon } from '@tauri-apps/api/tray'
import { Menu, MenuItem, PredefinedMenuItem } from '@tauri-apps/api/menu'
import { emit } from '@tauri-apps/api/event'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { exit } from '@tauri-apps/plugin-process'
import { resolveResource } from '@tauri-apps/api/path'
import { Image } from '@tauri-apps/api/image'

let tray: TrayIcon | null = null
let toggleItem: MenuItem | null = null
let pauseItem: MenuItem | null = null

export async function initTray(): Promise<void> {
	const window = getCurrentWindow()

	window.onCloseRequested(async (event) => {
		event.preventDefault()
		await window.hide()
	})

	toggleItem = await MenuItem.new({
		id: 'toggle-recording',
		text: 'Start Recording',
		accelerator: 'CommandOrControl+Shift+R',
		action: () => {
			emit('toggle-recording')
		},
	})

	pauseItem = await MenuItem.new({
		id: 'pause-recording',
		text: 'Pause Recording',
		accelerator: 'CommandOrControl+Shift+P',
		enabled: false,
		action: () => {
			emit('pause-recording')
		},
	})

	const showItem = await MenuItem.new({
		id: 'show-window',
		text: 'Show Window',
		action: async () => {
			await window.show()
			await window.setFocus()
		},
	})

	const separator = await PredefinedMenuItem.new({ item: 'Separator' })

	const quitItem = await MenuItem.new({
		id: 'quit',
		text: 'Quit',
		action: () => {
			exit(0)
		},
	})

	const menu = await Menu.new({
		items: [toggleItem, pauseItem, showItem, separator, quitItem],
	})

	const iconPath = await resolveResource('icons/icon.png')
	const icon = await Image.fromPath(iconPath)

	tray = await TrayIcon.new({
		icon,
		iconAsTemplate: true,
		menu,
		showMenuOnLeftClick: false,
		tooltip: 'Voice Thing',
		action: async (event) => {
			if (event.type === 'Click' && event.button === 'Left') {
				await window.show()
				await window.setFocus()
			}
		},
	})
}

export async function updateTrayState(state: 'idle' | 'recording' | 'paused'): Promise<void> {
	if (!tray) return

	switch (state) {
		case 'idle':
			await toggleItem?.setText('Start Recording')
			await pauseItem?.setText('Pause Recording')
			await pauseItem?.setEnabled(false)
			await tray.setIconAsTemplate(true)
			await tray.setTooltip('Voice Thing')
			try {
				const iconPath = await resolveResource('icons/icon.png')
				const icon = await Image.fromPath(iconPath)
				await tray.setIcon(icon)
			} catch {}
			break

		case 'recording':
			await toggleItem?.setText('Stop Recording')
			await pauseItem?.setText('Pause Recording')
			await pauseItem?.setEnabled(true)
			await tray.setIconAsTemplate(false)
			await tray.setTooltip('Voice Thing — Recording')
			try {
				const iconPath = await resolveResource('icons/icon-recording.png')
				const icon = await Image.fromPath(iconPath)
				await tray.setIcon(icon)
			} catch {}
			break

		case 'paused':
			await toggleItem?.setText('Stop Recording')
			await pauseItem?.setText('Resume Recording')
			await pauseItem?.setEnabled(true)
			await tray.setIconAsTemplate(true)
			await tray.setTooltip('Voice Thing — Paused')
			try {
				const iconPath = await resolveResource('icons/icon.png')
				const icon = await Image.fromPath(iconPath)
				await tray.setIcon(icon)
			} catch {}
			break
	}
}
