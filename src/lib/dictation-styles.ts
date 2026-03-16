export type StyleKey = 'formal' | 'balanced' | 'casual' | 'dev'

export interface StyleOption {
	value: StyleKey
	label: string
	hint: string
	prompt: string
}

export const STYLE_OPTIONS: StyleOption[] = [
	{
		value: 'formal',
		label: 'Proper',
		hint: 'full sentences, correct grammar',
		prompt: 'Skriv med korrekt grammatik, fullständiga meningar och formell stil. Använd skiljetecken. Inga förkortningar eller talspråk.',
	},
	{
		value: 'balanced',
		label: 'Natural',
		hint: 'how you\'d normally write',
		prompt: 'Skriv naturligt med korrekt interpunktion och grammatik. Balansera mellan formellt och informellt.',
	},
	{
		value: 'casual',
		label: 'Chill',
		hint: 'like texting a friend',
		prompt: 'Skriv vardagligt och avslappnat, som i en chatt. Korta meningar, inga onödiga formaliteter.',
	},
	{
		value: 'dev',
		label: 'Dev',
		hint: 'optimized for LLM prompts & code',
		prompt: 'You are transcribing a software developer dictating instructions for an AI coding assistant. Write clear, precise, technical language. Preserve exact technical terms, library names, function names, and programming concepts as spoken. Use imperative mood ("add a function", "refactor the component"). Structure as actionable instructions. Fill in obvious gaps — if the developer says "add error handling" assume try/catch or Result types as appropriate. Keep code references exact (React, TypeScript, Rust, API names). Output in the same language the developer speaks but keep all code terms in English.',
	},
]

export function getPromptByStyle(style: string): string | undefined {
	return STYLE_OPTIONS.find((s) => s.value === style)?.prompt
}
