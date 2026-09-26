import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import YapKit

@Suite struct PasteboardSnapshotTests {
	/// A private named pasteboard, so tests never touch the user's clipboard.
	private func withPrivatePasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
		let pasteboard = NSPasteboard(name: .init("com.bjornbom.yap.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		try body(pasteboard)
	}

	private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + (0..<512).map { UInt8($0 % 251) })

	@Test func roundTripIsByteIdentical() {
		withPrivatePasteboard { pasteboard in
			let first = NSPasteboardItem()
			first.setString("before", forType: .string)
			first.setData(Self.png, forType: .png)
			first.setData(Data("{\\rtf1 before}".utf8), forType: .rtf)
			first.setData(Data([0, 1, 2, 3, 255]), forType: .init("com.bjornbom.yap.custom"))
			let second = NSPasteboardItem()
			second.setString("https://example.com", forType: .URL)
			pasteboard.clearContents()
			pasteboard.writeObjects([first, second])

			let saved = PasteboardSnapshot(of: pasteboard)
			#expect(saved.items.count == 2)
			#expect(saved.items[0].contains { $0.type == NSPasteboard.PasteboardType.png.rawValue && $0.data == Self.png })

			pasteboard.clearContents()
			pasteboard.setString("dictated text", forType: .string)
			saved.restore(to: pasteboard)

			#expect(PasteboardSnapshot(of: pasteboard) == saved)
			#expect(pasteboard.data(forType: .png) == Self.png)
			#expect(pasteboard.string(forType: .string) == "before")
		}
	}

	@Test func emptyPasteboardRestoresEmpty() {
		withPrivatePasteboard { pasteboard in
			pasteboard.clearContents()
			let saved = PasteboardSnapshot(of: pasteboard)
			#expect(saved.isEmpty)
			pasteboard.setString("dictated text", forType: .string)
			saved.restore(to: pasteboard)
			#expect(PasteboardSnapshot(of: pasteboard).isEmpty)
		}
	}
}

@Suite struct KeyboardLayoutTests {
	// Row positions of a few keys (virtual key codes are physical positions).
	private let qwerty: [CGKeyCode: String] = [0: "a", 1: "s", 9: "v", 40: "k", 47: "."]
	/// Plain Dvorak: the QWERTY "V" position types "k", and "v" lives on the QWERTY "." key.
	private let dvorak: [CGKeyCode: String] = [0: "a", 1: "o", 9: "k", 40: "t", 47: "v"]

	@Test func qwertyUsesThePreferredKey() {
		let code = KeyboardLayout.keyCode(for: "v", preferred: CGKeyCode(kVK_ANSI_V)) { qwerty[$0] }
		#expect(code == CGKeyCode(kVK_ANSI_V))
	}

	@Test func dvorakFindsTheMovedKey() {
		let code = KeyboardLayout.keyCode(for: "v", preferred: CGKeyCode(kVK_ANSI_V)) { dvorak[$0] }
		#expect(code == CGKeyCode(kVK_ANSI_Period))
	}

	@Test func matchIgnoresCase() {
		#expect(KeyboardLayout.keyCode(for: "v") { $0 == 9 ? "V" : nil } == 9)
	}

	@Test func missingCharacterGivesNil() {
		#expect(KeyboardLayout.keyCode(for: "v") { _ in "x" } == nil)
	}

	@MainActor
	@Test func currentLayoutRoundTrips() throws {
		let layout = try #require(KeyboardLayout.currentLayoutData())
		let code = try #require(KeyboardLayout.currentKeyCode(for: "v"))
		let typed = KeyboardLayout.translate(code, layout: layout, keyboardType: UInt32(LMGetKbdType()))
		#expect(typed?.lowercased() == "v")
	}
}
