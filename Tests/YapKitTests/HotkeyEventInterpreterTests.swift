import Carbon.HIToolbox
import Testing
@testable import YapKit

private let fnFlag: UInt64 = 0x80_0000
private let optionFlag: UInt64 = 0x8_0000
private let rightOptionDeviceBit: UInt64 = 0x40
private let leftOptionDeviceBit: UInt64 = 0x20

@Suite struct HotkeyEventInterpreterTests {
	@Test func fnHoldFromFlagsChanged() {
		var i = HotkeyEventInterpreter(trigger: .fn)
		let fn = Int64(kVK_Function)
		#expect(i.handle(.flagsChanged, keyCode: fn, flags: fnFlag, at: .zero).actions == [.start])
		#expect(i.handle(.flagsChanged, keyCode: fn, flags: 0, at: .seconds(1)).actions == [.stop])
	}

	@Test func rightOptionNeedsTheDeviceBit() {
		var i = HotkeyEventInterpreter(trigger: .rightOption)
		// Left ⌥ has the same key-independent flag but a different device bit.
		let left = i.handle(.flagsChanged, keyCode: Int64(kVK_Option), flags: optionFlag | leftOptionDeviceBit, at: .zero)
		#expect(left.actions.isEmpty)
		_ = i.handle(.flagsChanged, keyCode: Int64(kVK_Option), flags: 0, at: .milliseconds(10))
		let right = Int64(kVK_RightOption)
		#expect(i.handle(.flagsChanged, keyCode: right, flags: optionFlag | rightOptionDeviceBit, at: .milliseconds(20)).actions == [.start])
		#expect(i.handle(.flagsChanged, keyCode: right, flags: 0, at: .seconds(1)).actions == [.stop])
	}

	@Test func otherModifiersAreNotChords() {
		var i = HotkeyEventInterpreter(trigger: .fn)
		_ = i.handle(.flagsChanged, keyCode: Int64(kVK_Function), flags: fnFlag, at: .zero)
		let shift = i.handle(.flagsChanged, keyCode: Int64(kVK_Shift), flags: fnFlag | 0x2_0000, at: .milliseconds(100))
		#expect(shift.actions.isEmpty)
		#expect(i.machine.isListening)
	}

	@Test func missedReleaseIsRecoveredFromTheNextFlagsChanged() {
		var i = HotkeyEventInterpreter(trigger: .fn)
		_ = i.handle(.flagsChanged, keyCode: Int64(kVK_Function), flags: fnFlag, at: .zero)
		let out = i.handle(.flagsChanged, keyCode: Int64(kVK_Shift), flags: 0x2_0000, at: .seconds(1))
		#expect(out.actions == [.stop])
	}

	@Test func escapeKeyDownAndItsKeyUpAreSwallowed() {
		var i = HotkeyEventInterpreter(trigger: .fn)
		let esc = Int64(kVK_Escape)
		_ = i.handle(.flagsChanged, keyCode: Int64(kVK_Function), flags: fnFlag, at: .zero)
		let down = i.handle(.keyDown, keyCode: esc, flags: fnFlag, at: .milliseconds(200))
		#expect(down == .init([.cancel], swallow: true))
		// Auto-repeat of the same press stays swallowed.
		#expect(i.handle(.keyDown, keyCode: esc, flags: fnFlag, at: .milliseconds(700)).swallow)
		#expect(i.handle(.keyUp, keyCode: esc, flags: fnFlag, at: .milliseconds(800)).swallow)
		// The next Esc, with no dictation running, belongs to the app again.
		#expect(!i.handle(.keyDown, keyCode: esc, flags: 0, at: .seconds(2)).swallow)
		#expect(!i.handle(.keyUp, keyCode: esc, flags: 0, at: .seconds(2)).swallow)
	}

	@Test func chordKeyPassesThrough() {
		var i = HotkeyEventInterpreter(trigger: .rightOption)
		_ = i.handle(.flagsChanged, keyCode: Int64(kVK_RightOption), flags: optionFlag | rightOptionDeviceBit, at: .zero)
		let a = i.handle(.keyDown, keyCode: Int64(kVK_ANSI_2), flags: optionFlag | rightOptionDeviceBit, at: .milliseconds(150))
		#expect(a == .init([.cancel], swallow: false))
		#expect(!i.handle(.keyUp, keyCode: Int64(kVK_ANSI_2), flags: optionFlag | rightOptionDeviceBit, at: .milliseconds(200)).swallow)
		#expect(i.handle(.flagsChanged, keyCode: Int64(kVK_RightOption), flags: 0, at: .milliseconds(300)).actions.isEmpty)
	}

	@Test func tickExpiresAStrayTap() {
		var i = HotkeyEventInterpreter(trigger: .fn)
		_ = i.handle(.flagsChanged, keyCode: Int64(kVK_Function), flags: fnFlag, at: .zero)
		_ = i.handle(.flagsChanged, keyCode: Int64(kVK_Function), flags: 0, at: .milliseconds(50))
		#expect(i.machine.deadline == .milliseconds(350))
		#expect(i.tick(at: .milliseconds(350)).actions == [.cancel])
	}
}
