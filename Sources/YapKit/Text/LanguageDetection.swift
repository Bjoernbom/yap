import Foundation
import NaturalLanguage

/// Which language a piece of dictated text is in. Parakeet doesn't say, and
/// polish must name it explicitly (a small model drifts to English on short
/// Swedish input) and skip languages the model doesn't support.
enum LanguageDetection {
	/// A BCP 47 language code such as "sv", or nil if there's too little to tell.
	/// No hints or constraints: they would hide Finnish or Polish from the gate.
	static func dominantLanguage(of text: String) -> String? {
		let recognizer = NLLanguageRecognizer()
		recognizer.processString(text)
		guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
		return language.rawValue
	}

	/// Same, limited to `candidates`: used by the output guard, where short
	/// text would otherwise flip between close languages.
	static func dominantLanguage(of text: String, among candidates: [String]) -> String? {
		let recognizer = NLLanguageRecognizer()
		recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
		recognizer.processString(text)
		return recognizer.dominantLanguage?.rawValue
	}

	/// "sv" → "Swedish", for the prompt.
	static func englishName(of code: String) -> String {
		Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
	}
}
