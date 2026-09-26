import AppKit

/// Every item and every type on a pasteboard, as raw bytes, so the paste fallback can put
/// the user's clipboard back exactly as it was.
public struct PasteboardSnapshot: Sendable, Equatable {
	public struct Entry: Sendable, Equatable {
		public var type: String
		public var data: Data

		public init(type: String, data: Data) {
			self.type = type
			self.data = data
		}
	}

	/// One pasteboard item's entries, in the order the pasteboard listed its types (the
	/// order carries the owner's preference, so it is kept).
	public var items: [[Entry]]

	public init(items: [[Entry]]) {
		self.items = items
	}

	/// Reads every type of every item. This forces promised data out of the app that
	/// copied it, which is the slow part for big images.
	public init(of pasteboard: NSPasteboard) {
		items = (pasteboard.pasteboardItems ?? []).map { item in
			item.types.compactMap { type in
				item.data(forType: type).map { Entry(type: type.rawValue, data: $0) }
			}
		}
	}

	public var isEmpty: Bool { items.isEmpty }

	/// Replaces the pasteboard's contents with the snapshot.
	public func restore(to pasteboard: NSPasteboard) {
		pasteboard.clearContents()
		guard !items.isEmpty else { return }
		pasteboard.writeObjects(items.map { entries in
			let item = NSPasteboardItem()
			for entry in entries {
				item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
			}
			return item
		})
	}
}
