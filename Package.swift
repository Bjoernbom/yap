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
		.testTarget(name: "YapKitTests", dependencies: ["YapKit"]),
	]
)
