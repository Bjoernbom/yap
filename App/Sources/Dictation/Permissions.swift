import AppKit
import AVFoundation
import Observation
import YapKit

/// Microphone and Accessibility, the two permissions dictation needs.
///
/// Onboarding asks for each on its own row; after that the menu shows
/// what's missing and one item that asks for both.
@MainActor
@Observable
final class Permissions {
	private(set) var microphone: AVAuthorizationStatus
	private(set) var accessibility: Bool

	init() {
		microphone = AVCaptureDevice.authorizationStatus(for: .audio)
		accessibility = Self.accessibilityGranted
	}

	#if DEBUG
	/// `-YapSimulateNoAccessibility YES` reports Accessibility as off, so
	/// onboarding and the menu can be checked without revoking the real
	/// grant. Posting `com.bjornbom.yap.debug.grantAccessibility.<pid>`
	/// flips it back on, like the user turning the switch.
	static var simulatesNoAccessibility = UserDefaults.standard.bool(forKey: "YapSimulateNoAccessibility")
	#endif

	private static var accessibilityGranted: Bool {
		#if DEBUG
		if simulatesNoAccessibility { return false }
		#endif
		return AccessibilityPermission.isGranted
	}

	var hasMicrophone: Bool { microphone == .authorized }
	var allGranted: Bool { hasMicrophone && accessibility }

	/// Sentence-case status for the menu, or nil when nothing is missing.
	var missingSummary: String? {
		switch (hasMicrophone, accessibility) {
		case (true, true): nil
		case (false, false): "Needs Microphone and Accessibility"
		case (false, true): "Needs Microphone"
		case (true, false): "Needs Accessibility"
		}
	}

	/// Re-reads both. Cheap; called on activation and while something is missing.
	func refresh() {
		let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
		let accessibility = Self.accessibilityGranted
		// Only assign on change, so observers don't re-render every poll.
		if microphone != self.microphone { self.microphone = microphone }
		if accessibility != self.accessibility { self.accessibility = accessibility }
	}

	/// Asks for whatever is missing: the system Microphone prompt (or its
	/// Settings pane once denied), then the Accessibility prompt and pane.
	func request() async {
		await requestMicrophone()
		if !Self.accessibilityGranted {
			requestAccessibility()
		}
		refresh()
	}

	/// The system Microphone prompt, or its Settings pane once denied.
	func requestMicrophone() async {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .notDetermined:
			_ = await AVCaptureDevice.requestAccess(for: .audio)
		case .denied, .restricted:
			// macOS never asks twice; the switch lives in System Settings.
			Self.openPrivacyPane("Privacy_Microphone")
		default:
			break
		}
		refresh()
	}

	/// The Accessibility prompt and its Settings pane.
	func requestAccessibility() {
		#if DEBUG
		// Simulating: the real grant is on, and the system pane would open on
		// the screen of whoever is running the probe.
		if Self.simulatesNoAccessibility { return }
		#endif
		AccessibilityPermission.request()
		// The prompt only appears once per app identity; the pane always works.
		Self.openPrivacyPane("Privacy_Accessibility")
		refresh()
	}

	static func openPrivacyPane(_ anchor: String) {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
		NSWorkspace.shared.open(url)
	}
}
