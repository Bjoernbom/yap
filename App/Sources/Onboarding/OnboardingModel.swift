import Foundation
import Observation

/// First run: hi, permissions, key, try it, done. Shown once; the menu's
/// "Set up yap…" brings it back.
@MainActor
@Observable
final class OnboardingModel {
	enum Step: Int, CaseIterable, Comparable {
		case hi, permissions, key, tryIt, done

		static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

		#if DEBUG
		/// `-YapOnboardingStep <name>` opens straight at a step, for captures.
		init?(debugName: String) {
			switch debugName {
			case "hi": self = .hi
			case "permissions": self = .permissions
			case "key": self = .key
			case "tryIt", "try-it": self = .tryIt
			case "done": self = .done
			default: return nil
			}
		}
		#endif
	}

	private static let completedKey = "onboardingCompleted"
	/// How long Accessibility may stay off after the user opened its pane
	/// before we suspect a stale entry: macOS keeps a switch for an older
	/// build of yap that looks on but doesn't apply to this one.
	static let staleAccessibilityDelay: Duration = .seconds(10)

	private(set) var step = Step.hi
	/// Which way the last step change went, so the transition slides with it.
	private(set) var movedForward = true
	/// When the user last asked for Accessibility, to spot the stale entry.
	private(set) var accessibilityRequestedAt: ContinuousClock.Instant?
	/// Dictation has landed in the "try it" box.
	private(set) var triedIt = false
	@ObservationIgnored private var insertionsAtTryIt = 0

	let dictation: DictationController

	init(dictation: DictationController) {
		self.dictation = dictation
		#if DEBUG
		if let name = UserDefaults.standard.string(forKey: "YapOnboardingStep"), let step = Step(debugName: name) {
			self.step = step
			if step == .tryIt { insertionsAtTryIt = dictation.ownWindowInsertions }
		}
		#endif
	}

	/// Whether first run should open the window at launch.
	var shouldShowAtLaunch: Bool {
		#if DEBUG
		if UserDefaults.standard.string(forKey: "YapOnboardingStep") != nil { return true }
		#endif
		return !AppDefaults.store.bool(forKey: Self.completedKey)
	}

	/// Finished, skipped or closed: don't open by itself again. A permission
	/// missing later shows in the menu instead.
	func markCompleted() {
		AppDefaults.store.set(true, forKey: Self.completedKey)
	}

	/// From the menu: start over at the first step.
	func restart() {
		go(to: .hi)
		accessibilityRequestedAt = nil
	}

	var canContinue: Bool {
		switch step {
		case .hi, .key, .done: true
		case .permissions: dictation.permissions.allGranted
		case .tryIt: triedIt
		}
	}

	func next() {
		guard let next = Step(rawValue: step.rawValue + 1) else { return }
		go(to: next)
	}

	func back() {
		guard let previous = Step(rawValue: step.rawValue - 1) else { return }
		go(to: previous)
	}

	private func go(to step: Step) {
		movedForward = step >= self.step
		self.step = step
		if step == .tryIt {
			// Only dictation from here on counts, not an earlier visit's.
			triedIt = false
			insertionsAtTryIt = dictation.ownWindowInsertions
		}
	}

	// MARK: - Permissions

	func requestMicrophone() async {
		await dictation.permissions.requestMicrophone()
		dictation.checkPermissions()
	}

	func requestAccessibility() {
		accessibilityRequestedAt = .now
		dictation.permissions.requestAccessibility()
		dictation.checkPermissions()
	}

	/// Accessibility is still off well after the user went to turn it on.
	func accessibilityLooksStale(now: ContinuousClock.Instant) -> Bool {
		guard !dictation.permissions.accessibility, let accessibilityRequestedAt else { return false }
		return now - accessibilityRequestedAt > Self.staleAccessibilityDelay
	}

	// MARK: - Try it

	/// Called when the box's text changes: typing doesn't count, a
	/// dictation typed into our own window does.
	func tryItTextChanged(_ text: String) {
		guard step == .tryIt, !triedIt else { return }
		if dictation.ownWindowInsertions != insertionsAtTryIt,
		   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			triedIt = true
		}
	}
}
