export type StyleKey = 'formal' | 'balanced' | 'casual' | 'dev'

export interface StyleOption {
	value: StyleKey
	label: string
	hint: string
}

export const STYLE_OPTIONS: StyleOption[] = [
	{
		value: 'formal',
		label: 'Proper',
		hint: 'full sentences, correct grammar',
	},
	{
		value: 'balanced',
		label: 'Natural',
		hint: 'how you\'d normally write',
	},
	{
		value: 'casual',
		label: 'Chill',
		hint: 'like texting a friend',
	},
	{
		value: 'dev',
		label: 'Dev',
		hint: 'optimized for LLM prompts & code',
	},
]

const PROMPTS: Record<string, Record<StyleKey, string>> = {
	sv: {
		formal: 'Skriv med korrekt grammatik, fullständiga meningar och formell stil. Använd skiljetecken. Inga förkortningar eller talspråk.',
		balanced: 'Skriv naturligt med korrekt interpunktion och grammatik. Balansera mellan formellt och informellt.',
		casual: 'Skriv vardagligt och avslappnat, som i en chatt. Korta meningar, inga onödiga formaliteter.',
		dev: 'You are transcribing a software developer dictating instructions for an AI coding assistant. Write clear, precise, technical language. Preserve exact technical terms, library names, function names, and programming concepts as spoken. Use imperative mood. Structure as actionable instructions. Output in Swedish but keep all code terms in English.',
	},
	en: {
		formal: 'Write with correct grammar, complete sentences, and formal style. Use proper punctuation. No abbreviations or slang.',
		balanced: 'Write naturally with correct punctuation and grammar. Balance between formal and informal.',
		casual: 'Write casually and relaxed, like in a chat. Short sentences, no unnecessary formalities.',
		dev: 'You are transcribing a software developer dictating instructions for an AI coding assistant. Write clear, precise, technical language. Preserve exact technical terms, library names, function names, and programming concepts as spoken. Use imperative mood ("add a function", "refactor the component"). Structure as actionable instructions. Fill in obvious gaps — if the developer says "add error handling" assume try/catch or Result types as appropriate. Keep code references exact (React, TypeScript, Rust, API names).',
	},
	de: {
		formal: 'Schreibe mit korrekter Grammatik, vollständigen Sätzen und formellem Stil. Verwende Satzzeichen. Keine Abkürzungen oder Umgangssprache.',
		balanced: 'Schreibe natürlich mit korrekter Interpunktion und Grammatik. Balance zwischen formell und informell.',
		casual: 'Schreibe locker und entspannt, wie in einem Chat. Kurze Sätze, keine unnötigen Formalitäten.',
		dev: 'You are transcribing a software developer dictating instructions for an AI coding assistant. Write clear, precise, technical language. Preserve exact technical terms. Use imperative mood. Structure as actionable instructions. Output in German but keep all code terms in English.',
	},
	fr: {
		formal: 'Écrivez avec une grammaire correcte, des phrases complètes et un style formel. Utilisez la ponctuation. Pas d\'abréviations ni d\'argot.',
		balanced: 'Écrivez naturellement avec une ponctuation et une grammaire correctes. Équilibrez entre formel et informel.',
		casual: 'Écrivez de manière décontractée, comme dans un chat. Phrases courtes, pas de formalités inutiles.',
		dev: 'You are transcribing a software developer dictating instructions for an AI coding assistant. Write clear, precise, technical language. Preserve exact technical terms. Use imperative mood. Structure as actionable instructions. Output in French but keep all code terms in English.',
	},
	es: {
		formal: 'Escribe con gramática correcta, oraciones completas y estilo formal. Usa puntuación. Sin abreviaturas ni jerga.',
		balanced: 'Escribe de forma natural con puntuación y gramática correctas. Equilibra entre formal e informal.',
		casual: 'Escribe de forma casual y relajada, como en un chat. Frases cortas, sin formalidades innecesarias.',
		dev: 'You are transcribing a software developer dictating instructions for an AI coding assistant. Write clear, precise, technical language. Preserve exact technical terms. Use imperative mood. Structure as actionable instructions. Output in Spanish but keep all code terms in English.',
	},
}

// Fallback to English for languages without specific prompts
const FALLBACK_LANG = 'en'

export function getPromptByStyle(style: string, language?: string): string | undefined {
	const lang = language || FALLBACK_LANG
	const langPrompts = PROMPTS[lang] || PROMPTS[FALLBACK_LANG]
	return langPrompts[style as StyleKey]
}
