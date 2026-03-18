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
		hint: 'full sentences, correct punctuation',
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
		hint: 'clean technical instructions',
	},
]

// These are style hints for Claude post-processing.
// They tell Claude HOW to format, not WHAT to say.
const STYLE_PROMPTS: Record<StyleKey, string> = {
	formal: 'Style: ensure complete sentences, proper punctuation, and capitalize correctly. Keep it professional but don\'t change the words.',
	balanced: 'Style: light cleanup only. Keep the person\'s natural voice. Add punctuation where needed.',
	casual: 'Style: keep it casual. Lowercase is fine. Short sentences. Don\'t formalize anything.',
	dev: 'Style: this is a developer dictating technical content. Preserve all technical terms, code references, library names exactly as spoken. Format as clear instructions. Keep code terms in English even if the rest is in another language.',
}

export function getPromptByStyle(style: string, _language?: string): string | undefined {
	return STYLE_PROMPTS[style as StyleKey]
}
