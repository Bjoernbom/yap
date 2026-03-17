export const HOTKEY_OPTIONS = [
	{ value: 'RightAlt', label: 'Right Option', symbol: '⌥R' },
	{ value: 'LeftAlt', label: 'Left Option', symbol: '⌥L' },
	{ value: 'RightControl', label: 'Right Control', symbol: '⌃R' },
	{ value: 'RightShift', label: 'Right Shift', symbol: '⇧R' },
	{ value: 'RightMeta', label: 'Right Cmd', symbol: '⌘R' },
	{ value: 'F5', label: 'F5', symbol: 'F5' },
	{ value: 'F6', label: 'F6', symbol: 'F6' },
	{ value: 'F7', label: 'F7', symbol: 'F7' },
	{ value: 'F8', label: 'F8', symbol: 'F8' },
	{ value: 'F9', label: 'F9', symbol: 'F9' },
	{ value: 'F13', label: 'F13', symbol: 'F13' },
	{ value: 'F16', label: 'F16', symbol: 'F16' },
	{ value: 'F17', label: 'F17', symbol: 'F17' },
	{ value: 'F18', label: 'F18', symbol: 'F18' },
	{ value: 'F19', label: 'F19', symbol: 'F19' },
]

export function getHotkeySymbol(value: string): string {
	return HOTKEY_OPTIONS.find((o) => o.value === value)?.symbol || value
}
