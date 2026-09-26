// axdoc <bundle-id> <title-substring> text|clear|front
// Reads or clears the text area of OUR test window via Accessibility (no
// AppleScript automation prompt), or checks it is frontmost.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: axdoc <bundle> <title> text|clear|front"); exit(2) }
let bundle = args[1], title = args[2], command = args[3]

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
	var value: CFTypeRef?
	return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
	print("not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

if command == "front" {
	let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
	let focused = attr(axApp, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
	let focusedTitle = focused.flatMap { attr($0, kAXTitleAttribute) as? String } ?? ""
	print("front=\(front) focusedWindow='\(focusedTitle)'")
	exit(front == bundle && focusedTitle.contains(title) ? 0 : 1)
}

let windows = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { ((attr($0, kAXTitleAttribute) as? String) ?? "").contains(title) }) else {
	print("window not found; windows: \(windows.map { (attr($0, kAXTitleAttribute) as? String) ?? "?" })"); exit(1)
}
var queue = [window]
var area: AXUIElement?
while !queue.isEmpty {
	let element = queue.removeFirst()
	if (attr(element, kAXRoleAttribute) as? String) == (kAXTextAreaRole as String) { area = element; break }
	queue += (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
guard let area else { print("no text area"); exit(1) }
switch command {
case "text": print((attr(area, kAXValueAttribute) as? String) ?? "")
case "clear": print(AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, "" as CFString) == .success ? "cleared" : "clear failed")
default: print("unknown"); exit(2)
}
