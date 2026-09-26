import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Synchronization

/// Types dictated text into the app that had focus at key-down: through Accessibility when
/// the field supports it, otherwise by pasting with ⌘V and putting the clipboard back.
///
/// Never types into anything but the captured app: if focus moved to another process, or the
/// field is a password field, nothing is typed and the caller keeps the text.
/// Insert one text at a time; two overlapping pastes would fight over the clipboard.
public final class Inserter: TextInserter {
	/// How long the paste fallback waits for the target to read our text before it decides
	/// nothing was pasted.
	static let readTimeout: Duration = .milliseconds(500)
	/// Grace period between the target reading our text and the clipboard restore (M0: the
	/// target asked 4–19 ms after ⌘V).
	static let restoreDelay: Duration = .milliseconds(50)

	/// nspasteboard.org markers: clipboard managers skip transient and concealed items, so
	/// the dictation doesn't end up in the user's clipboard history.
	static let markerTypes: [NSPasteboard.PasteboardType] = [
		.init("org.nspasteboard.TransientType"),
		.init("org.nspasteboard.ConcealedType"),
	]

	private struct Captured: Sendable {
		var pid: pid_t
		var element: AXElement
	}

	/// The element focused at key-down; used when the app won't name its focused element at
	/// insert time (some apps only answer through the system-wide element).
	private let captured = Mutex<Captured?>(nil)

	public init() {}

	// `@concurrent` keeps the system-wide AX queries off the caller's actor: when one of our
	// own windows has focus they are answered by our main thread, and asking from the main
	// thread would wait on itself until the messaging timeout.
	@concurrent
	public func captureTarget() async -> FocusTarget? {
		let focusedApp = AXElement.systemWide.element(kAXFocusedApplicationAttribute)
		guard let pid = focusedApp?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
			captured.withLock { $0 = nil }
			return nil
		}
		let element = await Self.onAXThread(for: pid) {
			AXElement.application(pid).element(kAXFocusedUIElementAttribute)
		}
		captured.withLock { $0 = element.map { Captured(pid: pid, element: $0) } }
		return FocusTarget(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
	}

	@concurrent
	public func insert(_ text: String, into target: FocusTarget) async -> InsertOutcome {
		// Without Accessibility we can neither see the focus nor post ⌘V.
		guard AXIsProcessTrusted() else { return .failed }
		guard Self.focusedPID() == target.pid else { return .focusChanged }

		let pid = target.pid
		let focused = await Self.onAXThread(for: pid) {
			AXElement.application(pid).element(kAXFocusedUIElementAttribute)
		}
		let element = focused ?? captured.withLock { $0?.pid == pid ? $0?.element : nil }
		if let element {
			if await Self.onAXThread(for: pid, { element.isSecureTextField }) { return .secureField }
		} else if IsSecureEventInputEnabled() {
			// We can't see the field, but something turned on secure input: assume a password.
			return .secureField
		}
		if let element, await Self.insertThroughAccessibility(text, into: element, pid: pid) { return .ax }
		return await paste(text, into: target)
	}

	/// AppKit answers AX calls for our own windows in-process, on the calling thread, and its
	/// text views crash off the main thread. yap's own windows (onboarding's "try it" box) are
	/// valid targets, so those calls hop to the main actor; calls into other apps stay here.
	private static func onAXThread<T: Sendable>(for pid: pid_t, _ body: @Sendable () -> T) async -> T {
		if pid == getpid() { return await MainActor.run { body() } }
		return body()
	}

	/// The pid of the app that has keyboard focus right now.
	static func focusedPID() -> pid_t? {
		AXElement.systemWide.element(kAXFocusedApplicationAttribute)?.pid
			?? NSWorkspace.shared.frontmostApplication?.processIdentifier
	}

	// MARK: - Accessibility

	/// Sets the field's selected text and checks the value changed. Some apps (Electron,
	/// some web views, and buttons in M0) report success and ignore the write.
	private static func insertThroughAccessibility(_ text: String, into element: AXElement, pid: pid_t) async -> Bool {
		// nil: not written. .some(before): written, `before` is the value we compare against.
		let written: String?? = await onAXThread(for: pid) {
			guard element.isSettable(kAXSelectedTextAttribute) else { return nil }
			let before = element.string(kAXValueAttribute)
			guard element.set(kAXSelectedTextAttribute, to: text as CFString) == .success else { return nil }
			return .some(before)
		}
		guard let before = written else { return false }
		// A changed value counts, even if it doesn't contain `text` verbatim (formatters,
		// smart quotes): calling that a failure would paste the text a second time.
		for attempt in 0..<3 {
			let after = await onAXThread(for: pid) { element.string(kAXValueAttribute) }
			if let after, after != before { return true }
			if attempt < 2 { try? await Task.sleep(for: .milliseconds(10)) }
		}
		return false
	}

	// MARK: - Paste fallback

	private func paste(_ text: String, into target: FocusTarget) async -> InsertOutcome {
		let keyCode = await MainActor.run { KeyboardLayout.currentKeyCode(for: "v") } ?? CGKeyCode(kVK_ANSI_V)
		let pasteboard = NSPasteboard.general
		// With "ask" or "deny" for pasteboard access, reading to save would prompt or fail.
		// Paste anyway and leave the text on the clipboard instead of restoring.
		let snapshot: PasteboardSnapshot? = switch pasteboard.accessBehavior {
		case .ask, .alwaysDeny: nil
		default: PasteboardSnapshot(of: pasteboard)
		}

		// A lazy provider tells us exactly when someone reads the text: the earliest safe
		// moment to restore, and proof that the paste landed.
		let provider = PasteDataProvider(text: text)
		let item = NSPasteboardItem()
		item.setDataProvider(provider, forTypes: [.string])
		for marker in Self.markerTypes { item.setData(Data(), forType: marker) }
		pasteboard.clearContents()
		guard pasteboard.writeObjects([item]) else {
			snapshot?.restore(to: pasteboard)
			return .failed
		}
		let ours = pasteboard.changeCount

		// Last look before the keystroke: ⌘V goes to whoever has focus now.
		guard Self.focusedPID() == target.pid else {
			finish(pasteboard, ours: ours, snapshot: snapshot, text: text)
			return .focusChanged
		}
		Self.postCommand(keyCode)

		// No AX calls into the target from here until the restore: it may be blocked asking
		// us for the data, and both sides would wait out the messaging timeout.
		let read = await provider.waitForRead(timeout: Self.readTimeout)
		if read { try? await Task.sleep(for: Self.restoreDelay) }
		withExtendedLifetime(provider) {
			finish(pasteboard, ours: ours, snapshot: snapshot, text: text)
		}
		return read ? .paste : .noTarget
	}

	private func finish(_ pasteboard: NSPasteboard, ours: Int, snapshot: PasteboardSnapshot?, text: String) {
		// Someone copied something after us: that is newer than both our text and the
		// snapshot, so leave it.
		guard pasteboard.changeCount == ours else { return }
		if let snapshot {
			snapshot.restore(to: pasteboard)
		} else {
			// The lazy provider goes away with us; leave a real copy of the text behind.
			pasteboard.clearContents()
			pasteboard.setString(text, forType: .string)
		}
	}

	private static func postCommand(_ keyCode: CGKeyCode) {
		let source = CGEventSource(stateID: .combinedSessionState)
		for keyDown in [true, false] {
			guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
			event.flags = .maskCommand
			// Our own hotkey tap must not read this as the user typing (a chord).
			event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.paste)
			event.post(tap: .cghidEventTap)
		}
	}
}

/// Serves the dictated text on demand and records that it was asked for.
private final class PasteDataProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
	let text: String
	private let requested = Atomic<Bool>(false)

	init(text: String) {
		self.text = text
	}

	func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
		item.setString(text, forType: type)
		requested.store(true, ordering: .releasing)
	}

	func waitForRead(timeout: Duration) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline {
			if requested.load(ordering: .acquiring) { return true }
			try? await Task.sleep(for: .milliseconds(2))
		}
		return requested.load(ordering: .acquiring)
	}
}
