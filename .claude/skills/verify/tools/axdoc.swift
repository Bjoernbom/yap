// axdoc <bundle-id or pid:N> <title-substring> text|clear|front|secure
// Reads or clears the text area of OUR test window via Accessibility (no
// AppleScript automation prompt), or checks it is frontmost. `secure` focuses
// the window's password field (the Try it window has one).
// "pid:<n>" picks one copy of an app (a test build next to the user's yap).
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: axdoc <bundle|pid:N> <title> text|clear|front|secure"); exit(2) }
let bundle = args[1], title = args[2], command = args[3]

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
	var value: CFTypeRef?
	return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

let pid = bundle.hasPrefix("pid:") ? pid_t(bundle.dropFirst(4)) : nil
guard let app = pid.flatMap(NSRunningApplication.init(processIdentifier:))
	?? NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
	print("not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

if command == "front" {
	let frontApp = NSWorkspace.shared.frontmostApplication
	let front = pid != nil ? "pid:\(frontApp?.processIdentifier ?? 0)" : frontApp?.bundleIdentifier ?? "none"
	let focused = attr(axApp, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
	let focusedTitle = focused.flatMap { attr($0, kAXTitleAttribute) as? String } ?? ""
	print("front=\(front) focusedWindow='\(focusedTitle)'")
	exit(front == bundle && focusedTitle.contains(title) ? 0 : 1)
}

let windows = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { ((attr($0, kAXTitleAttribute) as? String) ?? "").contains(title) }) else {
	print("window not found; windows: \(windows.map { (attr($0, kAXTitleAttribute) as? String) ?? "?" })"); exit(1)
}
func find(_ matches: (AXUIElement) -> Bool) -> AXUIElement? {
	var queue = [window]
	while !queue.isEmpty {
		let element = queue.removeFirst()
		if matches(element) { return element }
		queue += (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
	}
	return nil
}
if command == "secure" {
	guard let field = find({ (attr($0, kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String) }) else {
		print("no password field"); exit(1)
	}
	let focused = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
	// A password field's value reads back as bullets; its length tells whether anything was typed.
	print("\(focused ? "focused" : "focus failed") length=\(((attr(field, kAXValueAttribute) as? String) ?? "").count)")
	exit(focused ? 0 : 1)
}
guard let area = find({ (attr($0, kAXRoleAttribute) as? String) == (kAXTextAreaRole as String) }) else {
	print("no text area"); exit(1)
}
switch command {
case "text": print((attr(area, kAXValueAttribute) as? String) ?? "")
case "clear": print(AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, "" as CFString) == .success ? "cleared" : "clear failed")
default: print("unknown"); exit(2)
}
