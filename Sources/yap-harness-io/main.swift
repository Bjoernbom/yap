// yap-harness-io: a DEBUG-only runtime check for YapKit's Input and Output modules.
//
// It opens its own windows and drives the real Inserter and HotkeyMonitor into them. It
// must never type into another app: before every insertion and every synthetic key event it
// checks that one of its own processes is frontmost and has keyboard focus, and aborts if not.
//
//   swift build --product yap-harness-io && .build/debug/yap-harness-io
//
// Run it from a terminal that has Accessibility (the harness inherits the terminal's grants).

#if DEBUG
import AppKit
import ApplicationServices
import YapKit

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Shared helpers

func log(_ line: String) { print(line) }

/// AX focus as the system sees it. Runs off the main thread: when our own window has focus,
/// the query is answered by our main thread and would wait on itself.
func focusedAppPID() async -> pid_t? {
	await Task.detached {
		let system = AXUIElementCreateSystemWide()
		AXUIElementSetMessagingTimeout(system, 0.25)
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
			let value, CFGetTypeID(value) == AXUIElementGetTypeID()
		else { return nil }
		var pid: pid_t = 0
		AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid)
		return pid
	}.value
}

/// The value of `pid`'s focused element, read over AX (used to check the helper's field).
func focusedValue(of pid: pid_t) async -> String? {
	await Task.detached {
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, 0.25)
		var focused: CFTypeRef?
		guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
			let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
		else { return nil }
		var value: CFTypeRef?
		AXUIElementCopyAttributeValue(unsafeDowncast(focused, to: AXUIElement.self), kAXValueAttribute as CFString, &value)
		return value as? String
	}.value
}

func sleep(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

@MainActor
func makeWindow(_ title: String, x: CGFloat, height: CGFloat) -> NSWindow {
	let window = NSWindow(
		contentRect: NSRect(x: x, y: 300, width: 360, height: height),
		styleMask: [.titled], backing: .buffered, defer: false
	)
	window.title = title
	window.isReleasedWhenClosed = false
	return window
}

@MainActor
func installMenu() {
	// ⌘V reaches `paste:` through the Edit menu's key equivalent, as in a real app.
	let main = NSMenu()
	let appItem = NSMenuItem()
	appItem.submenu = NSMenu()
	appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
	main.addItem(appItem)
	let editItem = NSMenuItem()
	let edit = NSMenu(title: "Edit")
	edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
	edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
	edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
	editItem.submenu = edit
	main.addItem(editItem)
	NSApp.mainMenu = main
}

// MARK: - Helper process (the "second window" that steals focus)

if CommandLine.arguments.contains("--helper") {
	let app = NSApplication.shared
	app.setActivationPolicy(.regular)
	let window = makeWindow("yap harness B (helper)", x: 620, height: 80)
	let field = NSTextField(frame: NSRect(x: 20, y: 25, width: 320, height: 24))
	window.contentView?.addSubview(field)
	window.makeKeyAndOrderFront(nil)
	window.makeFirstResponder(field)
	// Never outlive the parent by much, whatever happens to it.
	DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
	Task { @MainActor in
		for _ in 0..<30 where !NSApp.isActive {
			NSApp.activate()
			await sleep(ms: 100)
		}
	}
	app.run()
	exit(0)
}

// MARK: - Main harness

/// A focusable view with no AX text role that accepts ⌘V, like an app Accessibility can't
/// write into. Forces the Inserter onto its paste fallback.
final class PasteOnlyView: NSView {
	var pasted = ""
	override var acceptsFirstResponder: Bool { true }
	@objc func paste(_ sender: Any?) {
		pasted += NSPasteboard.general.string(forType: .string) ?? ""
		needsDisplay = true
	}
	override func draw(_ dirtyRect: NSRect) {
		NSColor.textBackgroundColor.setFill()
		bounds.fill()
		("paste target: " + pasted as NSString).draw(at: NSPoint(x: 4, y: 4), withAttributes: nil)
	}
}

@MainActor
final class Harness {
	let window = makeWindow("yap harness A", x: 200, height: 200)
	let plain = NSTextField(frame: NSRect(x: 20, y: 150, width: 320, height: 24))
	let secure = NSSecureTextField(frame: NSRect(x: 20, y: 110, width: 320, height: 24))
	let pasteView = PasteOnlyView(frame: NSRect(x: 20, y: 60, width: 320, height: 30))
	let button = NSButton(title: "no text here", target: nil, action: nil)
	let inserter = Inserter()
	var results: [(String, Bool)] = []
	var keyDownsSeen: [UInt16] = []

	init() {
		button.frame = NSRect(x: 20, y: 15, width: 320, height: 24)
		for view in [plain, secure, pasteView, button] as [NSView] { window.contentView?.addSubview(view) }
	}

	func record(_ name: String, _ pass: Bool, _ detail: String) {
		results.append((name, pass))
		log("PROBE \(name): \(pass ? "PASS" : "FAIL") \(detail)")
	}

	/// The safety gate. True only if this process is active, frontmost and has AX focus.
	func weHaveFocus(_ label: String) async -> Bool {
		let me = getpid()
		let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
		let axPID = await focusedAppPID()
		let ok = NSApp.isActive && front == me && axPID == me
		if !ok {
			log("SAFETY [\(label)]: not ours (active=\(NSApp.isActive) frontmost=\(front.map(String.init) ?? "nil") axFocus=\(axPID.map(String.init) ?? "nil") self=\(me)); aborting")
		}
		return ok
	}

	func focus(_ responder: NSResponder?) async -> Bool {
		window.makeKeyAndOrderFront(nil)
		for attempt in 0..<30 {
			if !NSApp.isActive {
				if attempt < 10 {
					NSApp.activate()
				} else {
					// Cooperative activation refuses a process started from a terminal while
					// the user is in another app; only the deprecated call still gets our own
					// window forward (the one build warning in this dev-only target).
					NSApp.activate(ignoringOtherApps: true)
				}
			}
			window.makeKeyAndOrderFront(nil)
			window.makeFirstResponder(responder)
			await sleep(ms: 100)
			if NSApp.isActive, await focusedAppPID() == getpid() { break }
			if attempt == 29 {
				log("  focus failed after \(attempt + 1) tries: frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") active=\(NSApp.isActive)")
				return false
			}
		}
		return true
	}

	func abort(_ why: String) -> Never {
		log("ABORT: \(why)")
		exit(3)
	}

	/// Captures the target and checks it is us before inserting anything.
	func captureOwnTarget(_ label: String) async -> FocusTarget {
		guard await weHaveFocus(label) else { abort("\(label): lost focus before capture") }
		guard let target = await inserter.captureTarget(), target.pid == getpid() else {
			abort("\(label): captured target is not this process")
		}
		return target
	}

	func fieldText(_ field: NSTextField) -> String {
		field.currentEditor()?.string ?? field.stringValue
	}

	// MARK: Insertion probes

	func probeAX() async {
		guard await focus(plain) else { abort("could not focus the harness window (activation refused)") }
		let target = await captureOwnTarget("ax")
		guard await weHaveFocus("ax insert") else { abort("ax") }
		let outcome = await inserter.insert("hello from yap", into: target)
		record("ax-plain-field", outcome == .ax && fieldText(plain) == "hello from yap", "outcome=\(outcome) field='\(fieldText(plain))'")
	}

	func probePaste() async {
		let pasteboard = NSPasteboard.general
		let item = NSPasteboardItem()
		let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
		let tiff = image?.tiffRepresentation ?? Data()
		let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) ?? Data()
		item.setData(png, forType: .png)
		item.setData(tiff, forType: .tiff)
		item.setString("clipboard before yap", forType: .string)
		item.setData(Data([0, 1, 2, 254, 255]), forType: .init("com.bjornbom.yap.harness.custom"))
		pasteboard.clearContents()
		pasteboard.writeObjects([item])
		let before = PasteboardSnapshot(of: pasteboard)
		let types = before.items.flatMap { $0.map { "\($0.type)(\($0.data.count) B)" } }
		log("  clipboard before: \(types.joined(separator: ", "))")

		guard await focus(pasteView) else { abort("focus paste view") }
		let target = await captureOwnTarget("paste")
		guard await weHaveFocus("paste insert") else { abort("paste") }
		let started = ContinuousClock.now
		let outcome = await inserter.insert("pasted by yap", into: target)
		let elapsed = ContinuousClock.now - started
		let after = PasteboardSnapshot(of: pasteboard)
		record("paste-fallback", outcome == .paste && pasteView.pasted == "pasted by yap",
			"outcome=\(outcome) view='\(pasteView.pasted)' in \(elapsed.formatted(.units(allowed: [.milliseconds])))")
		record("clipboard-restored-identical", before == after && !png.isEmpty,
			"items \(before.items.count)->\(after.items.count), png \(png.count) B, tiff \(tiff.count) B, identical=\(before == after)")
	}

	func probeSecure() async {
		guard await focus(secure) else { abort("focus secure field") }
		let target = await captureOwnTarget("secure")
		guard await weHaveFocus("secure insert") else { abort("secure") }
		let outcome = await inserter.insert("secret", into: target)
		record("secure-field", outcome == .secureField && fieldText(secure).isEmpty, "outcome=\(outcome) secure field empty=\(fieldText(secure).isEmpty)")
	}

	func probeNoField() async {
		// The window itself as first responder: no text field anywhere in focus.
		guard await focus(nil) else { abort("focus window") }
		let target = await captureOwnTarget("no field")
		let before = PasteboardSnapshot(of: .general)
		guard await weHaveFocus("no-field insert") else { abort("no field") }
		let outcome = await inserter.insert("nowhere", into: target)
		record("no-focused-field", outcome == .noTarget && PasteboardSnapshot(of: .general) == before,
			"outcome=\(outcome) clipboard unchanged=\(PasteboardSnapshot(of: .general) == before)")
	}

	func probeFocusChanged() async {
		guard await focus(plain) else { abort("focus plain field") }
		let plainBefore = fieldText(plain)
		let target = await captureOwnTarget("focus changed")

		let helper = Process()
		helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
		helper.arguments = ["--helper"]
		do { try helper.run() } catch { abort("could not start helper: \(error)") }
		defer { helper.terminate() }
		let helperPID = helper.processIdentifier
		// macOS 26 activation is cooperative: hand focus over explicitly.
		var moved = false
		for _ in 0..<40 {
			if let app = NSRunningApplication(processIdentifier: helperPID) { NSApp.yieldActivation(to: app) }
			await sleep(ms: 100)
			if await focusedAppPID() == helperPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID {
				moved = true
				break
			}
		}
		if moved {
			// Focus is in our helper window now. The Inserter must refuse to type anywhere.
			let outcome = await inserter.insert("must not appear", into: target)
			await sleep(ms: 200)
			let helperValue = await focusedValue(of: helperPID) ?? ""
			record("focus-moved-to-second-window", outcome == .focusChanged && helperValue.isEmpty && fieldText(plain) == plainBefore,
				"outcome=\(outcome) helper field='\(helperValue)' own field unchanged=\(fieldText(plain) == plainBefore)")
		} else {
			log("  helper never got focus (activation refused); checking the refusal with a stale target instead")
			guard await weHaveFocus("stale target") else { abort("stale target") }
			let stale = FocusTarget(pid: helperPID, bundleID: nil)
			let outcome = await inserter.insert("must not appear", into: stale)
			record("focus-changed-stale-target", outcome == .focusChanged, "outcome=\(outcome)")
		}
		helper.terminate()
		helper.waitUntilExit()
	}

	// MARK: Hotkey probe

	func post(flags keyCode: CGKeyCode, _ flags: CGEventFlags) async -> Bool {
		guard await weHaveFocus("post flags \(keyCode)") else { return false }
		let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: keyCode, keyDown: true)
		event?.type = .flagsChanged
		event?.flags = flags
		event?.post(tap: .cghidEventTap)
		return true
	}

	func post(key keyCode: CGKeyCode) async -> Bool {
		guard await weHaveFocus("post key \(keyCode)") else { return false }
		let source = CGEventSource(stateID: .privateState)
		for down in [true, false] {
			CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.post(tap: .cghidEventTap)
		}
		return true
	}

	func probeHotkey() async {
		// A synthetic Fn press would also run the system's Fn action if one is set; use right ⌥
		// then, so the probe never opens the emoji picker or dictation.
		let usage = FnKeyUsage.current
		let trigger: HotkeyTrigger = (usage ?? .doNothing) == .doNothing ? .fn : .rightOption
		log("  AppleFnUsageType=\(usage.map { "\($0)" } ?? "unset"), Accessibility=\(AccessibilityPermission.isGranted), InputMonitoring=\(AccessibilityPermission.canListenToEvents); trigger=\(trigger)")
		let key: CGKeyCode = trigger == .fn ? 63 : 61
		let down: CGEventFlags = trigger == .fn ? .maskSecondaryFn : CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)

		let monitor = HotkeyMonitor(trigger: trigger)
		let started = ContinuousClock.now
		do { try monitor.start() } catch {
			record("hotkey-monitor", false, "start failed: \(error)")
			return
		}
		log("  tap live in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))")
		var actions: [HotkeyAction] = []
		let stream = monitor.actions()
		let collector = Task { @MainActor in
			for await action in stream {
				actions.append(action)
				log("    action: \(action)")
			}
		}
		keyDownsSeen = []
		let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			self?.keyDownsSeen.append(event.keyCode)
			return event
		}
		defer {
			monitor.stop()
			collector.cancel()
			if let localMonitor { NSEvent.removeMonitor(localMonitor) }
		}
		guard await focus(plain) else { abort("focus for hotkey") }

		func step(_ name: String, _ body: () async -> Bool) async {
			log("  -- \(name)")
			guard await body() else { abort("lost focus during hotkey probe (\(name))") }
		}
		await step("hold 600 ms") {
			guard await post(flags: key, down) else { return false }
			await sleep(ms: 600)
			return await post(flags: key, [])
		}
		await sleep(ms: 150)
		await step("double-tap, then tap") {
			for gap in [120, 800, 500] {
				guard await post(flags: key, down) else { return false }
				await sleep(ms: 60)
				guard await post(flags: key, []) else { return false }
				await sleep(ms: gap)
			}
			return true
		}
		await step("lone short tap") {
			guard await post(flags: key, down) else { return false }
			await sleep(ms: 80)
			guard await post(flags: key, []) else { return false }
			await sleep(ms: 500)
			return true
		}
		await step("hold + Esc (swallowed)") {
			guard await post(flags: key, down) else { return false }
			await sleep(ms: 200)
			guard await post(key: 53) else { return false }
			await sleep(ms: 100)
			return await post(flags: key, [])
		}
		await sleep(ms: 150)
		await step("hold + A (chord, passes through)") {
			guard await post(flags: key, down) else { return false }
			await sleep(ms: 200)
			guard await post(key: 0) else { return false }
			await sleep(ms: 100)
			return await post(flags: key, [])
		}
		await sleep(ms: 150)
		await step("rapid taps x6") {
			for _ in 0..<6 {
				guard await post(flags: key, down) else { return false }
				await sleep(ms: 30)
				guard await post(flags: key, []) else { return false }
				await sleep(ms: 40)
			}
			return true
		}
		await sleep(ms: 500)
		await step("Esc while idle (passes through)") {
			await post(key: 53)
		}
		await sleep(ms: 300)

		let want: [HotkeyAction] = [
			.start, .stop,
			.start, .lock, .stop,
			.start, .cancel,
			.start, .cancel,
			.start, .cancel,
			.start, .lock, .stop, .start, .lock, .stop,
		]
		record("hotkey-actions", actions == want, "got \(actions)")
		let escapes = keyDownsSeen.filter { $0 == 53 }.count
		let aKeys = keyDownsSeen.filter { $0 == 0 }.count
		record("hotkey-esc-swallowed-chord-passed", escapes == 1 && aKeys == 1,
			"Esc keyDowns reaching the app: \(escapes) (want 1: only the idle one), A: \(aKeys) (want 1)")
	}

	func run() async {
		log("yap-harness-io pid \(getpid()), Accessibility=\(AccessibilityPermission.isGranted), pasteboard access=\(NSPasteboard.general.accessBehavior.rawValue)")
		let userClipboard = PasteboardSnapshot(of: .general)
		NSApp.setActivationPolicy(.regular)
		installMenu()
		window.makeKeyAndOrderFront(nil)

		if CommandLine.arguments.contains("--hotkey-only") {
			await probeHotkey()
		} else {
			await probeAX()
			await probePaste()
			await probeSecure()
			await probeNoField()
			await probeFocusChanged()
			await probeHotkey()
		}

		userClipboard.restore(to: .general)
		log("user clipboard restored: \(PasteboardSnapshot(of: .general) == userClipboard)")
		let failed = results.filter { !$0.1 }.map(\.0)
		log("SUMMARY: \(results.count - failed.count)/\(results.count) passed\(failed.isEmpty ? "" : ", failed: \(failed.joined(separator: ", "))")")
		exit(failed.isEmpty ? 0 : 1)
	}
}

let app = NSApplication.shared
// Hard stop: the harness must never linger with an active event tap.
DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
	print("ABORT: watchdog")
	exit(4)
}
let harness = Harness()
Task { @MainActor in await harness.run() }
app.run()

#else
print("yap-harness-io is a DEBUG-only tool.")
#endif
