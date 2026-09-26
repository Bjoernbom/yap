import ApplicationServices

/// A thin wrapper over `AXUIElement`. AX calls are IPC to the target app and safe from any
/// thread, so passing elements between tasks is fine even though the CF type is not marked
/// `Sendable`.
struct AXElement: @unchecked Sendable {
	let raw: AXUIElement

	/// A hung target would otherwise block each call for ~6 s. Set on the system-wide element
	/// this becomes the process-wide default.
	static let messagingTimeout: Float = 0.25

	static var systemWide: AXElement {
		let element = AXElement(raw: AXUIElementCreateSystemWide())
		AXUIElementSetMessagingTimeout(element.raw, messagingTimeout)
		return element
	}

	static func application(_ pid: pid_t) -> AXElement {
		let element = AXElement(raw: AXUIElementCreateApplication(pid))
		AXUIElementSetMessagingTimeout(element.raw, messagingTimeout)
		return element
	}

	var pid: pid_t? {
		var pid: pid_t = 0
		return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
	}

	func value(_ attribute: String) -> (AXError, CFTypeRef?) {
		var value: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(raw, attribute as CFString, &value)
		return (error, value)
	}

	func string(_ attribute: String) -> String? {
		value(attribute).1 as? String
	}

	func element(_ attribute: String) -> AXElement? {
		guard let value = value(attribute).1, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
		// The type ID check above makes this cast safe.
		return AXElement(raw: unsafeDowncast(value, to: AXUIElement.self))
	}

	func isSettable(_ attribute: String) -> Bool {
		var settable: DarwinBoolean = false
		return AXUIElementIsAttributeSettable(raw, attribute as CFString, &settable) == .success && settable.boolValue
	}

	func set(_ attribute: String, to value: CFTypeRef) -> AXError {
		AXUIElementSetAttributeValue(raw, attribute as CFString, value)
	}

	var role: String? { string(kAXRoleAttribute) }
	var subrole: String? { string(kAXSubroleAttribute) }
	var isSecureTextField: Bool { subrole == kAXSecureTextFieldSubrole }
}
