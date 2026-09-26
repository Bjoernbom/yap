// swift-tools-version: 6.2
import PackageDescription

// The Info.plist is embedded into the executable's __TEXT,__info_plist section so
// TCC finds usage strings (NSMicrophoneUsageDescription, NSAudioCaptureUsageDescription)
// even though this is a bare CLI and not an .app bundle.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"

let package = Package(
	name: "yapio",
	platforms: [.macOS(.v26)],
	targets: [
		.executableTarget(
			name: "yapio",
			linkerSettings: [
				.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
			]
		),
	]
)
