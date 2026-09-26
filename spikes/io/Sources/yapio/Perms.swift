import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Foundation

/// Reads the Globe/Fn key action from System Settings > Keyboard > "Press 🌐 key to".
/// Stored in the com.apple.HIToolbox domain; `defaults read com.apple.HIToolbox AppleFnUsageType`.
enum FnUsage: Int {
	case doNothing = 0, changeInputSource = 1, showEmojiAndSymbols = 2, startDictation = 3

	static func current() -> (raw: Int?, usage: FnUsage?) {
		let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
		let raw = (value as? NSNumber)?.intValue
		return (raw, raw.flatMap(FnUsage.init))
	}

	/// Anything other than "Do Nothing" means holding Fn for push-to-talk will also trigger
	/// a system action on release, so onboarding should show the fix.
	var conflictsWithPushToTalk: Bool { self != .doNothing }
}

/// Private TCC SPI, only for reporting. There is no public preflight for System Audio Recording
/// (kTCCServiceAudioCapture). Returns 0 = granted, 1 = denied, 2 = not determined (observed values).
func tccPreflight(_ service: String) -> Int? {
	guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
		let sym = dlsym(handle, "TCCAccessPreflight")
	else { return nil }
	typealias Fn = @convention(c) (CFString, CFDictionary?) -> Int
	let fn = unsafeBitCast(sym, to: Fn.self)
	return fn(service as CFString, nil)
}

func micStatusName(_ s: AVAuthorizationStatus) -> String {
	switch s {
	case .authorized: "authorized"
	case .denied: "denied"
	case .restricted: "restricted"
	case .notDetermined: "notDetermined"
	@unknown default: "unknown(\(s.rawValue))"
	}
}

@MainActor
func runPerms(_ args: Args) {
	print("== Permissions for pid \(getpid()) (\(CommandLine.arguments[0]))")
	print("Bundle id seen by Foundation: \(Bundle.main.bundleIdentifier ?? "nil")")
	print("Accessibility (AXIsProcessTrusted): \(AXIsProcessTrusted())")
	print("Input Monitoring (CGPreflightListenEventAccess): \(CGPreflightListenEventAccess())")
	print("Post events (CGPreflightPostEventAccess): \(CGPreflightPostEventAccess())")
	print("Microphone (AVCaptureDevice): \(micStatusName(AVCaptureDevice.authorizationStatus(for: .audio)))")
	let tccNames = ["kTCCServiceAudioCapture", "kTCCServiceMicrophone", "kTCCServiceListenEvent", "kTCCServicePostEvent", "kTCCServiceAccessibility"]
	for name in tccNames {
		print("TCCAccessPreflight(\(name)) [SPI]: \(tccPreflight(name).map(String.init) ?? "unavailable")")
	}
	print("Secure event input (IsSecureEventInputEnabled): \(IsSecureEventInputEnabled())")
	let fn = FnUsage.current()
	print("AppleFnUsageType: raw \(fn.raw.map(String.init) ?? "unset") -> \(fn.usage.map { "\($0)" } ?? "unknown"), conflicts with PTT: \(fn.usage?.conflictsWithPushToTalk ?? false)")
	print("NSPasteboard.general.accessBehavior: \(pasteboardAccessName(NSPasteboard.general.accessBehavior))")

	if args.flag("request") {
		print("-- requesting (one-shot prompts)")
		let ax = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
		print("AXIsProcessTrustedWithOptions(prompt): \(ax)")
		print("CGRequestListenEventAccess: \(CGRequestListenEventAccess())")
		print("CGRequestPostEventAccess: \(CGRequestPostEventAccess())")
		var mic: Bool?
		AVCaptureDevice.requestAccess(for: .audio) { granted in
			DispatchQueue.main.async { mic = granted }
		}
		runLoop(for: 30) { mic != nil }
		print("AVCaptureDevice.requestAccess: \(mic.map(String.init) ?? "no answer within 30 s")")
	}
}

func pasteboardAccessName(_ b: NSPasteboard.AccessBehavior) -> String {
	switch b {
	case .default: "default"
	case .ask: "ask"
	case .alwaysAllow: "alwaysAllow"
	case .alwaysDeny: "alwaysDeny"
	@unknown default: "unknown(\(b.rawValue))"
	}
}
