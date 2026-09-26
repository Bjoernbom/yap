import Testing
@testable import YapKit

@Test func versionIsSet() {
	#expect(!YapKit.version.isEmpty)
}
