import CoreML
import FluidAudio
import Foundation

struct Paths {
	let local: URL
	/// `ASR_BENCH_MODELS` points at a copy of the models, e.g. to force a cold ANE compile.
	var models: URL {
		if let override = ProcessInfo.processInfo.environment["ASR_BENCH_MODELS"] {
			return URL(fileURLWithPath: override, isDirectory: true)
		}
		return local.appendingPathComponent("Models", isDirectory: true)
	}
	var data: URL { local.appendingPathComponent("data", isDirectory: true) }
	var results: URL { local.appendingPathComponent("results", isDirectory: true) }

	static let current = Paths(
		local: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent(".local", isDirectory: true)
	)

	func modelDirectory(for version: AsrModelVersion) -> URL {
		models.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
	}
}

enum ModelChoice: String {
	case v3
	case ultra

	var version: AsrModelVersion {
		switch self {
		case .v3: .v3
		case .ultra: .ultra
		}
	}

	var repo: Repo {
		switch self {
		case .v3: .parakeetV3
		case .ultra: .parakeetUltra
		}
	}

	/// v3 ships several encoder precisions; the default download uses the `int8` variant tag.
	var downloadVariant: String? { self == .v3 ? ParakeetEncoderPrecision.int8.rawValue : nil }
}

/// Thin wrapper so every call gets a fresh TDT decoder state.
struct Engine {
	let manager: AsrManager
	let version: AsrModelVersion

	static func load(_ choice: ModelChoice, paths: Paths = .current) async throws -> (Engine, Double) {
		let start = ContinuousClock.now
		let models = try await AsrModels.load(from: paths.modelDirectory(for: choice.version), version: choice.version)
		let manager = AsrManager(config: .default)
		try await manager.loadModels(models)
		return (Engine(manager: manager, version: choice.version), seconds(since: start))
	}

	func transcribe(_ samples: [Float], language: Language? = nil) async throws -> ASRResult {
		var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
		return try await manager.transcribe(samples, decoderState: &state, language: language)
	}

	/// Carries decoder (LSTM) state across calls, for chunked streaming experiments.
	func transcribe(_ samples: [Float], state: inout TdtDecoderState, language: Language? = nil) async throws
		-> ASRResult
	{
		try await manager.transcribe(samples, decoderState: &state, language: language)
	}
}

struct Clip {
	let name: String
	let reference: String
	let samples: [Float]

	var duration: Double { Double(samples.count) / 16_000 }
}

enum Dataset {
	static func load(_ name: String, paths: Paths = .current) throws -> [Clip] {
		let directory = paths.data.appendingPathComponent(name, isDirectory: true)
		let manifest = try String(contentsOf: directory.appendingPathComponent("manifest.tsv"), encoding: .utf8)
		let converter = AudioConverter()
		return try manifest.split(separator: "\n").map { line in
			let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
			let samples = try converter.resampleAudioFile(directory.appendingPathComponent(fields[0]))
			return Clip(name: fields[0], reference: fields[1], samples: samples)
		}
	}
}

func directorySize(_ url: URL) -> UInt64 {
	guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
		return 0
	}
	var total: UInt64 = 0
	for case let file as URL in enumerator {
		total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
	}
	return total
}
