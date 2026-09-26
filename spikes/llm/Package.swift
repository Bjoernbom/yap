// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "llm-bench",
	platforms: [.macOS(.v26)],
	targets: [
		.executableTarget(
			name: "llm-bench",
			resources: [.copy("Fixtures")]
		),
	]
)
