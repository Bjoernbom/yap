// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "YapKit",
	platforms: [.macOS(.v26)],
	products: [
		.library(name: "YapKit", targets: ["YapKit"]),
	],
	dependencies: [
		// No traits: the default NemoTextProcessing trait adds ~8 MB we don't use.
		.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4", traits: []),
		.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
	],
	targets: [
		.target(
			name: "YapKit",
			dependencies: [
				.product(name: "FluidAudio", package: "FluidAudio"),
				.product(name: "GRDB", package: "GRDB.swift"),
			]
		),
		// Benchmark CLI for the plan's section 6 budgets: latency and memory.
		.executableTarget(
			name: "yap-bench",
			dependencies: [
				"YapKit",
				.product(name: "FluidAudio", package: "FluidAudio"),
			]
		),
		.testTarget(name: "YapKitTests", dependencies: ["YapKit"]),
		// Dev harness: exercises the real MicCapture on this Mac (latency, levels, probes).
		.executableTarget(name: "yap-harness-mic", dependencies: ["YapKit"]),
		// Dev harness: drives DictationSession through the public API with
		// scripted fakes and the real history store.
		.executableTarget(name: "yap-harness-session", dependencies: ["YapKit"]),
		// Dev-only runtime check for Input/Output in the harness's own windows. Not a product.
		.executableTarget(name: "yap-harness-io", dependencies: ["YapKit"]),
		// Dev harness: CallDetector with a child recorder, and SystemAudioTap
		// plumbing (a bare CLI captures zeros; the real check is the Debug app).
		.executableTarget(name: "yap-harness-notes", dependencies: ["YapKit"]),
	]
)
