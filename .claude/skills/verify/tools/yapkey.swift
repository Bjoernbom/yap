// Posts one synthetic key event for yap verification, but only when the
// frontmost app and its focused window are the ones we expect (our own test
// window). Usage: yapkey <bundle-id or pid:N> <window-title-substring> <action>
// actions: fn-down fn-up ropt-down ropt-up esc pastelast (⌃⌘V)
// Exit 0 posted, 3 focus check failed (a release is still posted so yap
// never stays stuck listening; yap itself refuses to type into another app).
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 4 else {
	FileHandle.standardError.write(Data("usage: yapkey <bundle-id> <title-substring> <action>\n".utf8))
	exit(2)
}
let expectBundle = args[1], expectTitle = args[2], action = args[3]

func frontInfo() -> (String, String) {
	guard let app = NSWorkspace.shared.frontmostApplication else { return ("none", "") }
	let axApp = AXUIElementCreateApplication(app.processIdentifier)
	var window: CFTypeRef?
	var title = ""
	if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success, let window {
		var value: CFTypeRef?
		if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
			title = (value as? String) ?? ""
		}
	}
	// Cross-check with the system-wide focused app.
	var focused: CFTypeRef?
	var focusedPID: pid_t = 0
	if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success, let focused {
		AXUIElementGetPid(focused as! AXUIElement, &focusedPID)
	}
	if focusedPID != 0 && focusedPID != app.processIdentifier { return ("mismatch-\(focusedPID)", title) }
	// "pid:<n>" tells two copies of one app apart (a test build next to the user's yap).
	if expectBundle.hasPrefix("pid:") { return ("pid:\(app.processIdentifier)", title) }
	return (app.bundleIdentifier ?? "none", title)
}

let (bundle, title) = frontInfo()
let ok = bundle == expectBundle && title.contains(expectTitle)
let isRelease = action.hasSuffix("-up")
if !ok {
	print("FOCUS CHECK FAILED: front=\(bundle) title='\(title)' expected=\(expectBundle) '\(expectTitle)'")
	if !isRelease { exit(3) }
}

let source = CGEventSource(stateID: .privateState)
func flags(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
	let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
	event?.type = .flagsChanged
	event?.flags = flags
	event?.post(tap: .cghidEventTap)
}
switch action {
case "fn-down": flags(63, .maskSecondaryFn)
case "fn-up": flags(63, [])
case "ropt-down": flags(61, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40))
case "ropt-up": flags(61, [])
case "esc":
	for down in [true, false] {
		CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
	}
case "pastelast":
	for down in [true, false] {
		let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
		event?.flags = [.maskControl, .maskCommand]
		event?.post(tap: .cghidEventTap)
	}
default:
	print("unknown action \(action)")
	exit(2)
}
// Posting is asynchronous: exiting right away sometimes drops the event
// before any tap sees it (observed as lost releases in M1 verification).
usleep(150_000)
let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
print("\(stamp) posted \(action) front=\(bundle) title='\(title)'")
exit(ok ? 0 : 3)
