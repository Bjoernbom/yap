import AppKit
import AVFoundation
import Observation
import YapKit

/// Microphone and Accessibility, the two permissions dictation needs.
///
/// Minimal first-run gate until onboarding (M4): the menu shows what's
/// missing and one item that asks for both.
@MainActor
@Observable
final class Permissions {
	private(set) var microphone: AVAuthorizationStatus
	private(set) var accessibility: Bool

	init() {
		microphone = AVCaptureDevice.authorizationStatus(for: .audio)
		accessibility = AccessibilityPermission.isGranted
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
		let accessibility = AccessibilityPermission.isGranted
		// Only assign on change, so observers don't re-render every poll.
		if microphone != self.microphone { self.microphone = microphone }
		if accessibility != self.accessibility { self.accessibility = accessibility }
	}

	/// Asks for whatever is missing: the system Microphone prompt (or its
	/// Settings pane once denied), then the Accessibility prompt and pane.
	func request() async {
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

		if !AccessibilityPermission.isGranted {
			AccessibilityPermission.request()
			// The prompt only appears once per app identity; the pane always works.
			Self.openPrivacyPane("Privacy_Accessibility")
		}
		refresh()
	}

	private static func openPrivacyPane(_ anchor: String) {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
		NSWorkspace.shared.open(url)
	}
}
