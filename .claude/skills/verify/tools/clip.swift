// clip save <file> | clip restore <file> | clip read
// Saves every pasteboard item with all its types, so the user's clipboard
// can be put back exactly after probes that leave text on it.
import AppKit

let args = CommandLine.arguments
let pasteboard = NSPasteboard.general
switch args.count > 1 ? args[1] : "" {
case "save":
	var items: [[String: Data]] = []
	for item in pasteboard.pasteboardItems ?? [] {
		var dict: [String: Data] = [:]
		for type in item.types {
			if let data = item.data(forType: type) { dict[type.rawValue] = data }
		}
		items.append(dict)
	}
	let data = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
	try data.write(to: URL(filePath: args[2]))
	print("saved \(items.count) item(s), changeCount \(pasteboard.changeCount)")
case "restore":
	let data = try Data(contentsOf: URL(filePath: args[2]))
	let items = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Data]] ?? []
	pasteboard.clearContents()
	let objects = items.map { dict -> NSPasteboardItem in
		let item = NSPasteboardItem()
		for (type, value) in dict { item.setData(value, forType: .init(type)) }
		return item
	}
	if !objects.isEmpty { pasteboard.writeObjects(objects) }
	print("restored \(objects.count) item(s)")
case "read":
	print(pasteboard.string(forType: .string) ?? "<no string>")
default:
	print("usage: clip save|restore <file> | clip read")
}
