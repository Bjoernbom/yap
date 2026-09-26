// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "asr-bench",
	platforms: [.macOS(.v26)],
	dependencies: [
		.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
	],
	targets: [
		.executableTarget(
			name: "asr-bench",
			dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
		),
	]
)
