import AppKit
import SwiftUI
import YapKit

/// The first-run window: one step at a time, the model download underneath.
struct OnboardingView: View {
	let model: OnboardingModel
	@Environment(\.dismissWindow) private var dismissWindow
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	static let size = CGSize(width: 520, height: 470)

	var body: some View {
		VStack(spacing: 0) {
			ZStack {
				stepView
					.id(model.step)
					.transition(stepTransition)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.clipped()

			footer
		}
		.frame(width: Self.size.width, height: Self.size.height)
		#if DEBUG
		// `-YapAppearance light|dark`, to capture both without touching the system.
		.preferredColorScheme(Self.debugColorScheme)
		#endif
		.task {
			// Live checks while the window is up: the user flips switches in
			// System Settings, which tells us nothing.
			while !Task.isCancelled {
				model.dictation.checkPermissions()
				try? await Task.sleep(for: .seconds(1))
			}
		}
		.onDisappear {
			// Closed any way at all: first run is over; the menu reopens it.
			model.markCompleted()
		}
	}

	@ViewBuilder
	private var stepView: some View {
		switch model.step {
		case .hi: HiStep()
		case .permissions: PermissionsStep(model: model)
		case .key: KeyStep(dictation: model.dictation)
		case .tryIt: TryItStep(model: model)
		case .done: DoneStep(trigger: model.dictation.trigger)
		}
	}

	#if DEBUG
	private static var debugColorScheme: ColorScheme? {
		switch UserDefaults.standard.string(forKey: "YapAppearance") {
		case "light": .light
		case "dark": .dark
		default: nil
		}
	}
	#endif

	private var stepTransition: AnyTransition {
		if reduceMotion { return .opacity }
		let edge: Edge = model.movedForward ? .trailing : .leading
		let opposite: Edge = model.movedForward ? .leading : .trailing
		return .asymmetric(
			insertion: .push(from: edge).combined(with: .opacity),
			removal: .push(from: opposite).combined(with: .opacity)
		)
	}

	private func move(_ change: () -> Void) {
		withAnimation(.spring(duration: 0.45, bounce: 0.12)) { change() }
	}

	// MARK: - Footer

	private var footer: some View {
		VStack(spacing: 14) {
			ModelStatusBar(dictation: model.dictation)
			HStack(spacing: 12) {
				StepDots(current: model.step)
				Spacer()
				if model.step != .done {
					Button("Skip") { finish() }
						.buttonStyle(.plain)
						.foregroundStyle(.secondary)
						.help("Set up later from the menu bar")
				}
				if model.step > .hi, model.step != .done {
					Button("Back") { move { model.back() } }
						.keyboardShortcut("[", modifiers: .command)
				}
				primaryButton
			}
		}
		.padding(.horizontal, 28)
		.padding(.top, 16)
		.padding(.bottom, 22)
	}

	@ViewBuilder
	private var primaryButton: some View {
		let title = switch model.step {
		case .hi: "Get started"
		case .done: "Done"
		default: "Continue"
		}
		Button(title) {
			if model.step == .done {
				finish()
			} else {
				move { model.next() }
			}
		}
		.buttonStyle(PrimaryButtonStyle())
		.keyboardShortcut(.defaultAction)
		.disabled(!model.canContinue)
	}

	private func finish() {
		model.markCompleted()
		dismissWindow(id: WindowID.onboarding)
	}
}

/// Black on light, white on dark: the prominent button without the system
/// accent colour, which the palette leaves out.
private struct PrimaryButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.body.weight(.medium))
			.foregroundStyle(Color(nsColor: .windowBackgroundColor))
			.padding(.horizontal, 16)
			.padding(.vertical, 6)
			.background(Color.primary, in: Capsule())
			.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.25)
			.scaleEffect(configuration.isPressed ? 0.97 : 1)
			.animation(.easeOut(duration: 0.15), value: isEnabled)
			.contentShape(Capsule())
	}
}

/// Five pixels, one lit: where you are.
private struct StepDots: View {
	let current: OnboardingModel.Step

	var body: some View {
		HStack(spacing: 5) {
			ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
				Rectangle()
					.fill(Color.primary.opacity(step == current ? 1 : 0.18))
					.frame(width: step == current ? 14 : 5, height: 5)
			}
		}
		.animation(.spring(duration: 0.35, bounce: 0.2), value: current)
		.accessibilityElement()
		.accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
	}
}

// MARK: - Shared pieces

/// Lowercase headline and one or two lines under it.
private struct StepHeader: View {
	let title: String
	let detail: String

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title)
				.font(.system(size: 26, weight: .semibold))
				.accessibilityAddTraits(.isHeader)
			Text(detail)
				.font(.body)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// A lime pixel tick on a black chip: the notch's "done", on the window.
struct DoneChip: View {
	var size: CGFloat = 26
	@State private var since = Date.now

	var body: some View {
		RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
			.fill(Palette.notch)
			.overlay {
				RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
					.strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
			}
			.overlay {
				// The tick is 37 pt wide at notch scale; make it ~60 % of the chip.
				PixelTick(since: since, color: Palette.lime)
					.scaleEffect(size * 0.6 / 37)
			}
			.frame(width: size, height: size)
			.onAppear { since = .now }
			.accessibilityHidden(true)
	}
}

// MARK: - 1. Hi

private struct HiStep: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Spacer(minLength: 0)
			Text("yap")
				.font(BrandFont.pixel(76))
				.accessibilityLabel("yap")
				.accessibilityAddTraits(.isHeader)
			Text("talk. it types.")
				.font(.system(size: 22, weight: .semibold))
				.padding(.top, 6)
			Text("Hold a key, say what you mean, let go. The words land wherever you're typing. It all runs on your Mac. Nothing leaves it.")
				.font(.body)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 14)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 44)
		.padding(.top, 20)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - 2. Permissions

private struct PermissionsStep: View {
	let model: OnboardingModel
	@State private var showsStaleHint = false

	var body: some View {
		let permissions = model.dictation.permissions
		VStack(alignment: .leading, spacing: 22) {
			StepHeader(title: "two switches.", detail: "So yap can hear you and type for you.")
			VStack(spacing: 0) {
				PermissionRow(
					symbol: "mic",
					title: "Microphone",
					detail: "Only while you hold the key or take notes.",
					granted: permissions.hasMicrophone,
					action: permissions.microphone == .notDetermined ? "Allow" : "Open Settings"
				) {
					Task { await model.requestMicrophone() }
				}
				Divider().padding(.leading, 44)
				PermissionRow(
					symbol: "accessibility",
					title: "Accessibility",
					detail: "To notice the key and type the text.",
					granted: permissions.accessibility,
					action: model.accessibilityRequestedAt == nil ? "Allow" : "Open Settings"
				) {
					model.requestAccessibility()
				}
			}
			.padding(.horizontal, 14)
			.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

			if showsStaleHint {
				Label("Already on? Remove yap from the list with −, then add it again.", systemImage: "arrow.triangle.2.circlepath")
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
					.transition(.opacity.combined(with: .offset(y: 4)))
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 44)
		.padding(.top, 44)
		.task {
			// Time passing is what makes the entry look stale, so check each second.
			while !Task.isCancelled {
				let stale = model.accessibilityLooksStale(now: .now)
				if stale != showsStaleHint {
					withAnimation(.easeOut(duration: 0.3)) { showsStaleHint = stale }
				}
				try? await Task.sleep(for: .seconds(1))
			}
		}
	}
}

private struct PermissionRow: View {
	let symbol: String
	let title: String
	let detail: String
	let granted: Bool
	let action: String
	let perform: () -> Void

	var body: some View {
		HStack(spacing: 14) {
			Image(systemName: symbol)
				.font(.system(size: 17))
				.frame(width: 30)
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.body.weight(.medium))
				Text(detail).font(.callout).foregroundStyle(.secondary)
			}
			Spacer(minLength: 12)
			ZStack(alignment: .trailing) {
				if granted {
					DoneChip(size: 24)
						.transition(.scale(scale: 0.6).combined(with: .opacity))
				} else {
					Button(action, action: perform)
						.transition(.opacity)
				}
			}
			.animation(.spring(duration: 0.35, bounce: 0.3), value: granted)
		}
		.padding(.vertical, 14)
		.accessibilityElement(children: .combine)
		.accessibilityValue(granted ? "On" : "Off")
	}
}

// MARK: - 3. Your key

private struct KeyStep: View {
	let dictation: DictationController
	/// Read on appear and on activation: the user may fix it in System Settings.
	@State private var fnUsage = KeyStep.currentFnUsage

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			StepHeader(title: "your key.", detail: "Hold it, talk, let go. Double-tap to go hands-free. Esc cancels.")
			HStack(spacing: 26) {
				Keycap(trigger: dictation.trigger)
					.id(dictation.trigger)
					.transition(.opacity)
				KeyChoice(selection: trigger)
			}
			.padding(.vertical, 6)
			.animation(.easeOut(duration: 0.2), value: dictation.trigger)

			if dictation.trigger == .fn, let fnUsage, fnUsage.conflictsWithPushToTalk {
				VStack(alignment: .leading, spacing: 8) {
					Text("fn also \(fnUsage.onboardingAction). Set “Press 🌐 key to” to Do Nothing.")
						.font(.callout)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					Button("Open Keyboard Settings") {
						if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
							NSWorkspace.shared.open(url)
						}
					}
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 44)
		.padding(.top, 44)
		.onAppear { fnUsage = Self.currentFnUsage }
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			fnUsage = Self.currentFnUsage
		}
	}

	private var trigger: Binding<HotkeyTrigger> {
		// Same path as Settings: saved and applied to the hotkey at once.
		Binding { dictation.trigger } set: { dictation.setTrigger($0) }
	}

	private static var currentFnUsage: FnKeyUsage? {
		#if DEBUG
		// `-YapFnUsage 2` shows the fix without changing the system setting.
		if let raw = UserDefaults.standard.object(forKey: "YapFnUsage") as? Int {
			return FnKeyUsage(rawValue: raw)
		}
		if let text = UserDefaults.standard.string(forKey: "YapFnUsage"), let raw = Int(text) {
			return FnKeyUsage(rawValue: raw)
		}
		#endif
		return FnKeyUsage.current
	}
}

/// fn or right ⌥, in black and white rather than the accent-blue segmented
/// control.
private struct KeyChoice: View {
	@Binding var selection: HotkeyTrigger

	var body: some View {
		HStack(spacing: 2) {
			option(.fn, title: "fn")
			option(.rightOption, title: "Right ⌥")
		}
		.padding(3)
		.background(Color.primary.opacity(0.07), in: Capsule())
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Push to talk key")
	}

	private func option(_ trigger: HotkeyTrigger, title: String) -> some View {
		let selected = selection == trigger
		return Button {
			withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = trigger }
		} label: {
			Text(title)
				.font(.body.weight(selected ? .semibold : .regular))
				.foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
				.frame(width: 86, height: 26)
				.background {
					if selected { Capsule().fill(Color.primary) }
				}
				.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.accessibilityLabel(trigger.spokenName)
		.accessibilityAddTraits(selected ? .isSelected : [])
	}
}

private extension FnKeyUsage {
	/// Finishes "fn also …".
	var onboardingAction: String {
		switch self {
		case .doNothing: "does nothing"
		case .changeInputSource: "changes the input source"
		case .showEmojiAndSymbols: "opens emoji & symbols"
		case .startDictation: "starts Apple dictation"
		}
	}
}

// MARK: - 4. Try it

private struct TryItStep: View {
	let model: OnboardingModel
	@State private var text = ""
	@FocusState private var boxFocused: Bool

	var body: some View {
		let dictation = model.dictation
		VStack(alignment: .leading, spacing: 18) {
			HStack(alignment: .firstTextBaseline) {
				StepHeader(title: "try it.", detail: "Hold \(dictation.trigger.displayName), say something, let go.")
				if model.triedIt {
					DoneChip(size: 30)
						.transition(.scale(scale: 0.5).combined(with: .opacity))
						.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 8 }
				}
			}
			TextEditor(text: $text)
				.font(.system(size: 15))
				.scrollContentBackground(.hidden)
				.padding(10)
				.focused($boxFocused)
				.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.overlay {
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.strokeBorder(model.triedIt ? Palette.lime : Color.primary.opacity(boxFocused ? 0.25 : 0.1), lineWidth: model.triedIt ? 2 : 1)
				}
				.overlay(alignment: .topLeading) {
					if text.isEmpty {
						placeholder(dictation)
							.padding(.horizontal, 15)
							.padding(.vertical, 10)
							.allowsHitTesting(false)
					}
				}
				.frame(height: 140)
				.accessibilityLabel("Try it")
				.accessibilityHint("Hold \(dictation.trigger.spokenName), speak, then let go.")
			Text(model.triedIt ? "That's it. Works in any app." : "Everything you say is kept in History for 30 days.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.contentTransition(.opacity)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 44)
		.padding(.top, 44)
		.animation(.spring(duration: 0.4, bounce: 0.35), value: model.triedIt)
		.onChange(of: text) { _, text in model.tryItTextChanged(text) }
		// The count bumps after the text lands, so check on both.
		.onChange(of: dictation.ownWindowInsertions) { _, _ in model.tryItTextChanged(text) }
		.task {
			// Wait out the step transition, then put the cursor in the box:
			// dictation types into whatever has focus.
			try? await Task.sleep(for: .milliseconds(350))
			boxFocused = true
		}
	}

	@ViewBuilder
	private func placeholder(_ dictation: DictationController) -> some View {
		switch dictation.modelStatus {
		case .ready:
			Text("Your words land here.")
				.foregroundStyle(.tertiary)
		case .loading(let fraction?):
			Text("Almost ready… \(ModelStatusBar.percent(fraction))%")
				.foregroundStyle(.secondary)
		case .loading(nil):
			Text("Warming up… The first time takes about 20 seconds.")
				.foregroundStyle(.secondary)
		case .failed:
			Text("The speech model isn't here yet. Try again below.")
				.foregroundStyle(.secondary)
		}
	}
}

// MARK: - 5. Done

private struct DoneStep: View {
	let trigger: HotkeyTrigger

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			StepHeader(title: "you're set.", detail: "yap lives in the menu bar. Hold \(trigger.displayName) anywhere.")
			VStack(alignment: .leading, spacing: 14) {
				line(symbol: "waveform", text: "Take notes with ⌥⌘N, or when yap spots a call.")
				line(symbol: "clock.arrow.circlepath", text: "Everything you've said is in History, in the menu bar.")
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 44)
		.padding(.top, 44)
	}

	private func line(symbol: String, text: String) -> some View {
		Label {
			Text(text)
		} icon: {
			Image(systemName: symbol)
				.foregroundStyle(.secondary)
				.frame(width: 24)
		}
		.font(.body)
	}
}
