import Foundation
import Testing
@testable import YapKit

@Suite("Dictionary")
struct TextDictionaryTests {
	let builtIn = TextDictionary(entries: [])

	@Test func fixesTheBrand() {
		#expect(builtIn.apply("Jag använder yapp varje dag.") == "Jag använder yap varje dag.")
		#expect(builtIn.apply("Yapp is great.") == "yap is great.")
		#expect(builtIn.apply("Download it from yap dot app.") == "Download it from yap.app.")
		#expect(builtIn.apply("Download it from Yap  dot  App.") == "Download it from yap.app.")
	}

	@Test(arguments: [
		// Everyday Swedish near the brand stays untouched.
		"Jag laddade ner en app i går.",
		"Finns det i appen?",
		"Vi ses upp på kontoret.",
		"Han yappar hela tiden.",
		"Ta upp det i app store.",
	])
	func leavesSwedishAlone(input: String) {
		#expect(builtIn.apply(input) == input)
	}

	@Test func replacesWholeWordsOnly() {
		let dictionary = TextDictionary(entries: [
			DictionaryEntry(spoken: "app", written: "APP"),
			DictionaryEntry(spoken: "pr", written: "PR"),
		])
		#expect(dictionary.apply("Öppna appen och appar.") == "Öppna appen och appar.")
		#expect(dictionary.apply("the app works") == "the APP works")
		#expect(dictionary.apply("Open a pr for it, then print it.") == "Open a PR for it, then print it.")
		#expect(dictionary.apply("user_app and app_id stay") == "user_app and app_id stay")
	}

	@Test func termsGetTheirSpelling() {
		let dictionary = TextDictionary(entries: [
			DictionaryEntry(written: "Kubernetes"),
			DictionaryEntry(written: "Mehmet"),
			DictionaryEntry(written: "GitHub"),
			DictionaryEntry(written: "Visual Studio Code"),
		])
		#expect(dictionary.apply("vi kör kubernetes") == "vi kör Kubernetes")
		#expect(dictionary.apply("ask mehmet") == "ask Mehmet")
		#expect(dictionary.apply("push to Git Hub") == "push to GitHub")
		#expect(dictionary.apply("open visual studio code") == "open Visual Studio Code")
		// Near misses on long terms only.
		#expect(dictionary.apply("deploy to kubernetis") == "deploy to Kubernetes")
		#expect(dictionary.apply("deploy to kubernettes now") == "deploy to Kubernetes now")
	}

	@Test func fuzzyMatchingIsConservative() {
		let dictionary = TextDictionary(entries: [
			DictionaryEntry(written: "Kristin"),
			DictionaryEntry(written: "Isak"),
			DictionaryEntry(written: "Stefan"),
			DictionaryEntry(written: "Parakeet"),
		])
		// Short names sit one letter from real words.
		#expect(dictionary.apply("han är kristen") == "han är kristen")
		#expect(dictionary.apply("i sak har du rätt") == "i sak har du rätt")
		// Inflections aren't misspellings.
		#expect(dictionary.apply("det är Stefans bil") == "det är Stefans bil")
		#expect(dictionary.apply("two parakeets") == "two parakeets")
		// But a long term's near miss is fixed.
		#expect(dictionary.apply("parakeat is fast") == "Parakeet is fast")
	}

	@Test func longerPhrasesWin() {
		let dictionary = TextDictionary(entries: [DictionaryEntry(spoken: "yap", written: "YAP")])
		#expect(dictionary.apply("see yap dot app") == "see yap.app")
	}

	@Test func emptyEntriesAreIgnored() {
		let dictionary = TextDictionary(entries: [DictionaryEntry(spoken: "x", written: "  ")], includeBuiltIn: false)
		#expect(dictionary.apply("x marks it") == "x marks it")
		#expect(dictionary.vocabulary.isEmpty)
	}

	@Test func vocabularyListsWrittenForms() {
		let dictionary = TextDictionary(entries: [DictionaryEntry(written: "Kubernetes")])
		#expect(dictionary.vocabulary.contains("Kubernetes"))
		#expect(dictionary.vocabulary.contains("yap"))
	}

	@Test func editDistance() {
		#expect(TextDictionary.editDistance("kubernetes", "kubernetis", limit: 2) == 1)
		#expect(TextDictionary.editDistance("abcd", "abdc", limit: 2) == 1)
		#expect(TextDictionary.editDistance("same", "same", limit: 0) == 0)
	}
}
