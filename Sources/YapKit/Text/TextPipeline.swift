import Foundation
import Synchronization

/// The user's text settings. The app persists them as JSON.
public struct TextSettings: Codable, Sendable, Equatable {
	/// Opt-in until polish passes the LLM spike's corpus with Apple Intelligence on.
	public var polishEnabled: Bool
	/// Per-app style choices by bundle id.
	public var styleOverrides: [String: WritingStyle]
	public var dictionary: [DictionaryEntry]

	public init(polishEnabled: Bool = false, styleOverrides: [String: WritingStyle] = [:], dictionary: [DictionaryEntry] = []) {
		self.polishEnabled = polishEnabled
		self.styleOverrides = styleOverrides
		self.dictionary = dictionary
	}

	// Every key optional, so a file from an older or newer yap still loads.
	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		polishEnabled = try container.decodeIfPresent(Bool.self, forKey: .polishEnabled) ?? false
		styleOverrides = try container.decodeIfPresent([String: WritingStyle].self, forKey: .styleOverrides) ?? [:]
		dictionary = try container.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? []
	}
}

/// Every stage of one run, for yap-bench and tests.
public struct TextResult: Sendable, Equatable {
	public var input: String
	public var style: WritingStyle
	public var cleaned: String
	public var dictionary: String
	public var polish: PolishOutcome
	public var text: String
}

/// cleanup → dictionary → polish (if on and available) → style finishing.
///
/// Settings can change at any time from the app; a dictation uses the ones
/// current at key-up.
public final class TextPipeline: TextProcessing, Sendable {
	private struct State {
		var settings: TextSettings
		var context: AppContext
		var dictionary: TextDictionary
		/// Made at key-down, used once at key-up.
		var prepared: (style: WritingStyle, polish: PreparedPolish)?
		/// Guess for the next key-down's prewarm: people dictate in the
		/// language they used last time.
		var lastLanguage = "en"
	}

	private let polisher: Polisher
	private let state: Mutex<State>

	public init(settings: TextSettings = TextSettings(), polisher: Polisher = Polisher()) {
		self.polisher = polisher
		state = Mutex(State(
			settings: settings,
			context: AppContext(overrides: settings.styleOverrides),
			dictionary: TextDictionary(entries: settings.dictionary)
		))
	}

	public var settings: TextSettings {
		state.withLock { $0.settings }
	}

	public func update(_ settings: TextSettings) {
		state.withLock { state in
			guard state.settings != settings else { return }
			state.settings = settings
			state.context = AppContext(overrides: settings.styleOverrides)
			state.dictionary = TextDictionary(entries: settings.dictionary)
		}
	}

	public var polishAvailability: PolishAvailability { polisher.availability }

	public func style(for bundleID: String?) -> WritingStyle {
		state.withLock { $0.context.style(for: bundleID) }
	}

	public func prepare(for target: FocusTarget?) async {
		let (enabled, style, language) = state.withLock { state in
			(state.settings.polishEnabled, state.context.style(for: target?.bundleID), state.lastLanguage)
		}
		guard enabled, polisher.availability.isAvailable else { return }
		let prepared = polisher.prepare(style: style, language: language)
		state.withLock { $0.prepared = (style, prepared) }
	}

	public func process(_ text: String, for target: FocusTarget?) async -> String {
		await run(text, bundleID: target?.bundleID).text
	}

	/// - Parameter style: Overrides the app's style (yap-bench).
	public func run(_ input: String, bundleID: String?, style: WritingStyle? = nil) async -> TextResult {
		let (settings, context, dictionary, prepared) = state.withLock { state in
			defer { state.prepared = nil }
			return (state.settings, state.context, state.dictionary, state.prepared)
		}
		let style = style ?? context.style(for: bundleID)
		let cleaned = Cleanup.apply(input, style: style)
		let corrected = dictionary.apply(cleaned)

		let polish = await polish(corrected, style: style, enabled: settings.polishEnabled, prepared: prepared, dictionary: dictionary)
		// The model may still misspell a term; the dictionary has the last word.
		let polished: String
		if case .polished(let text) = polish {
			polished = dictionary.apply(text)
		} else {
			polished = corrected
		}
		let text = StyleFinisher.finish(polished, style: style)
		return TextResult(input: input, style: style, cleaned: cleaned, dictionary: corrected, polish: polish, text: text)
	}

	private func polish(
		_ text: String,
		style: WritingStyle,
		enabled: Bool,
		prepared: (style: WritingStyle, polish: PreparedPolish)?,
		dictionary: TextDictionary
	) async -> PolishOutcome {
		guard enabled else { return .skipped(.disabled) }
		guard polisher.availability.isAvailable else { return .skipped(.unavailable) }
		if let language = LanguageDetection.dominantLanguage(of: text) {
			state.withLock { $0.lastLanguage = language }
		}
		// No key-down (paste last, yap-bench) or the style changed: a cold session still works.
		let session = prepared.flatMap { $0.style == style ? $0.polish : nil }
			?? polisher.prepare(style: style, language: state.withLock { $0.lastLanguage })
		return await session.polish(text, vocabulary: dictionary.vocabulary)
	}
}
