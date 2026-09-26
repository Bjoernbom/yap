import Foundation
import FoundationModels

enum AvailabilityProbe {
	static func run() async {
		let model = SystemLanguageModel.default
		print("availability: \(model.availability)")
		print("isAvailable: \(model.isAvailable)")
		let languages = model.supportedLanguages
			.map { $0.minimalIdentifier }
			.sorted()
		print("supportedLanguages (\(languages.count)): \(languages.joined(separator: ", "))")
		let swedish = model.supportedLanguages.contains { $0.languageCode?.identifier == "sv" }
		print("swedish in supportedLanguages: \(swedish)")
		for id in ["sv_SE", "en_US", "en_GB", "nb_NO"] {
			print("supportsLocale(\(id)): \(model.supportsLocale(Locale(identifier: id)))")
		}
		print("current locale: \(Locale.current.identifier), supported: \(model.supportsLocale())")
	}

	/// The macOS 26.1 SDK has no `contextSize` API, so find the window empirically:
	/// binary-search the prompt length at which `exceededContextWindowSize` is thrown.
	static func probeContext() async throws {
		guard Bench.requireModel() else { throw BenchError.modelUnavailable }
		let filler = "The quick brown fox jumps over the lazy dog near the river bank. "
		func prompt(_ repeats: Int) -> String {
			"Reply with OK.\n" + String(repeating: filler, count: repeats)
		}
		var low = 1
		var high = 800
		var lastError = ""
		while high - low > 4 {
			let mid = (low + high) / 2
			let session = LanguageModelSession()
			do {
				_ = try await session.respond(to: prompt(mid), options: GenerationOptions(maximumResponseTokens: 4))
				low = mid
				print("repeats \(mid): ok")
			} catch let error as LanguageModelSession.GenerationError {
				if case .exceededContextWindowSize(let context) = error {
					high = mid
					lastError = context.debugDescription
					print("repeats \(mid): exceeded")
				} else {
					print("repeats \(mid): other error \(error)")
					return
				}
			} catch {
				print("repeats \(mid): \(error)")
				return
			}
		}
		let words = prompt(low).split(separator: " ").count
		print("largest fitting prompt: \(low) repeats, ~\(words) words, \(prompt(low).count) chars")
		print("error text: \(lastError)")
	}
}
