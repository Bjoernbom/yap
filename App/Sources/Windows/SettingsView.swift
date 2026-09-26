import AppKit
import SwiftUI
import YapKit

/// Settings: the push-to-talk key, polish, styles per app and the
/// dictionary. The rest of the one-screen settings (Health, mic, notes)
/// arrive in M4.
struct SettingsView: View {
	let dictation: DictationController
	let text: TextSettingsStore

	/// Read when the window appears; the user may have changed it in System
	/// Settings meanwhile.
	@State private var fnUsage = FnKeyUsage.current

	var body: some View {
		Form {
			Section {
				Picker("Push to talk", selection: trigger) {
					Text("fn").tag(HotkeyTrigger.fn)
					Text("Right ⌥").tag(HotkeyTrigger.rightOption)
				}
				if dictation.trigger == .fn, let fnUsage, fnUsage.conflictsWithPushToTalk {
					fnConflict(fnUsage)
				}
			} footer: {
				Text("Hold it, talk, let go. Esc cancels.")
					.foregroundStyle(.secondary)
			}

			PolishSection(text: text)
			StylesSection(text: text, history: dictation.history, historyRevision: dictation.historyRevision)
			DictionarySection(text: text)

			Section {
				LabeledContent("Paste last", value: "⌃⌘V")
			}

			Section {
				LabeledContent("Version", value: YapKit.version)
			}
		}
		.formStyle(.grouped)
		.frame(width: 460)
		.fixedSize(horizontal: false, vertical: true)
		.onAppear {
			fnUsage = FnKeyUsage.current
			text.refreshAvailability()
		}
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			fnUsage = FnKeyUsage.current
			text.refreshAvailability()
		}
	}

	private var trigger: Binding<HotkeyTrigger> {
		Binding { dictation.trigger } set: { dictation.setTrigger($0) }
	}

	private func fnConflict(_ usage: FnKeyUsage) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Pressing fn also \(usage.systemAction). Set “Press 🌐 key to” to Do Nothing.")
				.font(.callout)
				.foregroundStyle(.secondary)
			Button("Open Keyboard Settings") {
				if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
					NSWorkspace.shared.open(url)
				}
			}
		}
	}
}

private extension FnKeyUsage {
	/// Finishes "Pressing fn also …".
	var systemAction: String {
		switch self {
		case .doNothing: "does nothing"
		case .changeInputSource: "changes the input source"
		case .showEmojiAndSymbols: "opens emoji & symbols"
		case .startDictation: "starts Apple dictation"
		}
	}
}
