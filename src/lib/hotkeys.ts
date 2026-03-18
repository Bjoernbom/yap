// Maps JavaScript event.code to a display symbol
const KEY_SYMBOLS: Record<string, string> = {
	AltRight: '⌥R', AltLeft: '⌥L',
	ControlRight: '⌃R', ControlLeft: '⌃L',
	ShiftRight: '⇧R', ShiftLeft: '⇧L',
	MetaRight: '⌘R', MetaLeft: '⌘L',
	RightAlt: '⌥R', LeftAlt: '⌥L',
	RightControl: '⌃R', LeftControl: '⌃L',
	RightShift: '⇧R', LeftShift: '⇧L',
	RightMeta: '⌘R', LeftMeta: '⌘L',
	Space: '␣', Tab: '⇥', CapsLock: '⇪', Backquote: '`', Escape: '⎋',
}

const MODIFIER_SYMBOLS: Record<string, string> = {
	MetaLeft: '⌘', MetaRight: '⌘',
	AltLeft: '⌥', AltRight: '⌥',
	ControlLeft: '⌃', ControlRight: '⌃',
	ShiftLeft: '⇧', ShiftRight: '⇧',
}

function codeToSymbol(code: string): string {
	if (KEY_SYMBOLS[code]) return KEY_SYMBOLS[code]
	if (code.startsWith('F') && /^F\d+$/.test(code)) return code
	if (code.startsWith('Key')) return code.slice(3)
	if (code.startsWith('Digit')) return code.slice(5)
	return code
}

function codeToLabel(code: string): string {
	const labels: Record<string, string> = {
		AltRight: 'Right Option', AltLeft: 'Left Option',
		ControlRight: 'Right Control', ControlLeft: 'Left Control',
		ShiftRight: 'Right Shift', ShiftLeft: 'Left Shift',
		MetaRight: 'Right Cmd', MetaLeft: 'Left Cmd',
		RightAlt: 'Right Option', LeftAlt: 'Left Option',
		Space: 'Space', Tab: 'Tab', CapsLock: 'Caps Lock', Backquote: 'Backtick', Escape: 'Escape',
	}
	if (labels[code]) return labels[code]
	if (code.startsWith('F') && /^F\d+$/.test(code)) return code
	if (code.startsWith('Key')) return code.slice(3)
	if (code.startsWith('Digit')) return code.slice(5)
	return code
}

function isModifier(code: string): boolean {
	return code.startsWith('Meta') || code.startsWith('Alt') || code.startsWith('Control') || code.startsWith('Shift')
}

/**
 * Get display symbol for a hotkey combo string like "MetaRight+KeyR" or "AltRight"
 */
export function getHotkeySymbol(combo: string): string {
	const parts = combo.split('+')
	if (parts.length === 1) return codeToSymbol(parts[0])

	const modSymbols: string[] = []
	let primary = ''
	for (const part of parts) {
		if (isModifier(part)) {
			const sym = MODIFIER_SYMBOLS[part]
			if (sym && !modSymbols.includes(sym)) modSymbols.push(sym)
		} else {
			primary = codeToSymbol(part)
		}
	}

	if (primary) return [...modSymbols, primary].join('')
	// All modifiers — show the last one with its side
	return codeToSymbol(parts[parts.length - 1])
}

/**
 * Get human-readable label for a hotkey combo
 */
export function getHotkeyLabel(combo: string): string {
	const parts = combo.split('+')
	if (parts.length === 1) return codeToLabel(parts[0])

	return parts.map(codeToLabel).join(' + ')
}
