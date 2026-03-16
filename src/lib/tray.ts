import { TrayIcon } from '@tauri-apps/api/tray'
import { Menu, MenuItem, PredefinedMenuItem } from '@tauri-apps/api/menu'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { exit } from '@tauri-apps/plugin-process'

export async function initTray(): Promise<void> {
	const window = getCurrentWindow()

	window.onCloseRequested(async (event) => {
		event.preventDefault()
		await window.hide()
	})

	const showItem = await MenuItem.new({
		id: 'show-window',
		text: 'Open yap',
		action: async () => {
			await window.show()
			await window.setFocus()
		},
	})

	const separator = await PredefinedMenuItem.new({ item: 'Separator' })

	const quitItem = await MenuItem.new({
		id: 'quit',
		text: 'Quit',
		action: () => exit(0),
	})

	const menu = await Menu.new({
		items: [showItem, separator, quitItem],
	})

	// Get the tray icon created by tauri.conf.json — left click shows menu with "Open yap"
	const tray = await TrayIcon.getById('yap-tray')
	if (tray) {
		await tray.setMenu(menu)
		await tray.setMenuOnLeftClick(true)
	}
}

export async function showDashboard(): Promise<void> {
	const { WebviewWindow } = await import('@tauri-apps/api/webviewWindow')
	const main = await WebviewWindow.getByLabel('main')
	if (main) {
		await main.show()
		await main.setFocus()
	}
}
