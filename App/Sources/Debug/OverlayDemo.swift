#if DEBUG
import AppKit

/// Drives the notch with fake data so its look can be reviewed without
/// speech. DEBUG builds only.
///
/// Launch arguments:
/// - `-YapDebugOverlay listening|working|done|recording|cycle|rapid` shows
///   that state at launch (`done` stays up).
/// - `-YapOverlayScreen notch` prefers the built-in notched screen.
/// - `-YapSnapshots <dir>` renders every state to PNGs in `<dir>` and quits.
@MainActor
final class OverlayDemo {
	private let overlay: OverlayController
	private var task: Task<Void, Never>?

	init(overlay: OverlayController) {
		self.overlay = overlay
	}

	func show(_ state: OverlayState) {
		task?.cancel()
		apply(state)
	}

	/// Listening, working, done, then a meeting, then gone.
	func cycle() {
		task?.cancel()
		overlay.holdsDone = false
		task = Task { [weak self] in
			let steps: [(OverlayState, Duration)] = [
				(.listening, .seconds(3)),
				(.working, .seconds(1.4)),
				(.done, .seconds(1.6)),
				(.recording(since: .now.addingTimeInterval(-754)), .seconds(4)),
				(.hidden, .zero),
			]
			for (state, duration) in steps {
				guard let self, !Task.isCancelled else { return }
				self.apply(state)
				try? await Task.sleep(for: duration)
			}
		}
	}

	/// Random states every 40–160 ms, to shake out animation races.
	func rapidCycle(count: Int = 60) {
		task?.cancel()
		overlay.holdsDone = false
		task = Task { [weak self] in
			let states: [OverlayState] = [.listening, .working, .done, .recording(since: .now), .hidden]
			for _ in 0..<count {
				guard let self, !Task.isCancelled, let state = states.randomElement() else { return }
				self.apply(state)
				try? await Task.sleep(for: .milliseconds(Int.random(in: 40...160)))
			}
			self?.apply(.hidden)
		}
	}

	func applyLaunchArguments() {
		let defaults = UserDefaults.standard
		if let directory = defaults.string(forKey: "YapSnapshots") {
			Task {
				OverlaySnapshots.write(to: URL(filePath: directory))
				NSApp.terminate(nil)
			}
			return
		}
		guard let name = defaults.string(forKey: "YapDebugOverlay") else { return }
		Task { [weak self] in
			// Let the menu bar item settle before the notch opens.
			try? await Task.sleep(for: .milliseconds(600))
			guard let self else { return }
			switch name {
			case "cycle": self.cycle()
			case "rapid": self.rapidCycle()
			case "listening": self.show(.listening)
			case "working":
				self.show(.listening)
				try? await Task.sleep(for: .seconds(1.2))
				self.show(.working)
			case "done":
				self.overlay.holdsDone = true
				self.show(.done)
			case "recording": self.show(.recording(since: .now.addingTimeInterval(-754)))
			default: break
			}
		}
	}

	private func apply(_ state: OverlayState) {
		if state == .listening {
			overlay.follow(levels: FakeLevels.stream())
		}
		overlay.show(state)
	}
}
#endif
