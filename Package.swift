// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "YapKit",
	platforms: [.macOS(.v26)],
	products: [
		.library(name: "YapKit", targets: ["YapKit"]),
	],
	targets: [
		.target(name: "YapKit"),
		.testTarget(name: "YapKitTests", dependencies: ["YapKit"]),
	]
)
