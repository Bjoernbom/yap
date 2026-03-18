// Maps JavaScript event.code to a display symbol
const KEY_SYMBOLS: Record<string, string> = {
	// Modifiers
	AltRight: '⌥R', AltLeft: '⌥L',
	ControlRight: '⌃R', ControlLeft: '⌃L',
	ShiftRight: '⇧R', ShiftLeft: '⇧L',
	MetaRight: '⌘R', MetaLeft: '⌘L',
	// Legacy names
	RightAlt: '⌥R', LeftAlt: '⌥L',
	RightControl: '⌃R', LeftControl: '⌃L',
	RightShift: '⇧R', LeftShift: '⇧L',
	RightMeta: '⌘R', LeftMeta: '⌘L',
	// Function keys
	F1: 'F1', F2: 'F2', F3: 'F3', F4: 'F4', F5: 'F5',
	F6: 'F6', F7: 'F7', F8: 'F8', F9: 'F9', F10: 'F10',
	F11: 'F11', F12: 'F12', F13: 'F13', F14: 'F14', F15: 'F15',
	F16: 'F16', F17: 'F17', F18: 'F18', F19: 'F19', F20: 'F20',
	// Special
	Space: 'Space', Tab: 'Tab', CapsLock: 'Caps', Backquote: '`', Escape: 'Esc',
}

const KEY_LABELS: Record<string, string> = {
	AltRight: 'Right Option', AltLeft: 'Left Option',
	ControlRight: 'Right Control', ControlLeft: 'Left Control',
	ShiftRight: 'Right Shift', ShiftLeft: 'Left Shift',
	MetaRight: 'Right Cmd', MetaLeft: 'Left Cmd',
	RightAlt: 'Right Option', LeftAlt: 'Left Option',
	RightControl: 'Right Control', LeftControl: 'Left Control',
	RightShift: 'Right Shift', LeftShift: 'Left Shift',
	RightMeta: 'Right Cmd', LeftMeta: 'Left Cmd',
	Space: 'Space', Tab: 'Tab', CapsLock: 'Caps Lock', Backquote: 'Backtick', Escape: 'Escape',
}

export function getHotkeySymbol(code: string): string {
	if (KEY_SYMBOLS[code]) return KEY_SYMBOLS[code]
	// Function keys
	if (code.startsWith('F') && /^F\d+$/.test(code)) return code
	// Letters: KeyA → A
	if (code.startsWith('Key')) return code.slice(3)
	// Digits: Digit0 → 0
	if (code.startsWith('Digit')) return code.slice(5)
	return code
}

export function getHotkeyLabel(code: string): string {
	if (KEY_LABELS[code]) return KEY_LABELS[code]
	if (code.startsWith('F') && /^F\d+$/.test(code)) return code
	if (code.startsWith('Key')) return code.slice(3)
	if (code.startsWith('Digit')) return code.slice(5)
	return code
}
