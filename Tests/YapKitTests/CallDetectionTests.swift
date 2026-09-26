import Testing
@testable import YapKit

@Suite struct CallAppTests {
	@Test(arguments: [
		("us.zoom.xos", CallApp.zoom),
		("us.zoom.CptHost", .zoom),
		("com.microsoft.teams2", .teams),
		("com.microsoft.teams2.helper", .teams),
		("com.tinyspeck.slackmacgap.helper", .slack),
		("com.apple.FaceTime", .faceTime),
		("com.apple.avconferenced", .faceTime),
		("Cisco-Systems.Spark", .webex),
		("com.hnc.Discord.helper", .discord),
		("co.teamport.around", .around),
		("com.google.Chrome.helper", .browser("Chrome")),
		("com.google.chrome.helper.renderer", .browser("Chrome")),
		("com.apple.WebKit.GPU", .browser("Safari")),
		("company.thebrowser.Browser.helper", .browser("Arc")),
		("com.microsoft.edgemac.helper", .browser("Edge")),
	])
	func mapsHelpersToTheirApp(bundleID: String, app: CallApp) {
		#expect(CallApp.known(bundleID: bundleID) == app)
	}

	@Test func matchesOnDotBoundariesOnly() {
		#expect(CallApp.known(bundleID: "us.zoomer.app") == nil)
		#expect(CallApp.known(bundleID: "com.apple.FaceTimeAgent") == nil)
		#expect(CallApp.known(bundleID: "") == nil)
	}

	@Test func fallsBackToTheOutermostAppInThePath() {
		let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
		#expect(CallApp.outermostAppPath(in: helper) == "/Applications/Google Chrome.app")
		let lookup: (String) -> String? = { $0 == "/Applications/Google Chrome.app" ? "com.google.Chrome" : nil }
		#expect(CallApp.identify(bundleID: "", executablePath: helper, bundleIDOfApp: lookup) == .browser("Chrome"))
	}

	@Test func unknownRecordersAreNamedAfterTheirAppOrExecutable() {
		let none: (String) -> String? = { _ in nil }
		#expect(CallApp.identify(bundleID: "com.example.Recorder", executablePath: "/Applications/Recorder.app/Contents/MacOS/Recorder", bundleIDOfApp: none) == .other("Recorder"))
		#expect(CallApp.identify(bundleID: "", executablePath: "/usr/local/bin/yap-harness-notes", bundleIDOfApp: none) == .other("yap-harness-notes"))
		#expect(CallApp.identify(bundleID: "", executablePath: nil, bundleIDOfApp: none) == .other("Unknown app"))
	}

	@Test func onlyCallAppsAndBrowsersMightBeCalls() {
		#expect(CallApp.zoom.isCallApp && CallApp.zoom.mightBeCall)
		#expect(!CallApp.browser("Chrome").isCallApp && CallApp.browser("Chrome").mightBeCall)
		#expect(!CallApp.other("Recorder").mightBeCall)
	}
}

@Suite struct CallDebouncerTests {
	/// Replays (time, recorders) samples and collects (time, event).
	private func run(_ samples: [(Double, [CallApp])], minimum: Double = 3, grace: Double = 1) -> [(Double, CallEvent)] {
		var debouncer = CallDebouncer(minimumDuration: minimum, endGrace: grace)
		var out: [(Double, CallEvent)] = []
		for (time, recorders) in samples {
			out += debouncer.update(recorders: recorders, at: time).map { (time, $0) }
		}
		return out
	}

	@Test func shortMicUseIsNotACall() {
		let events = run([(0, [.other("Recorder")]), (1, [.other("Recorder")]), (2.9, []), (10, [])])
		#expect(events.isEmpty)
	}

	@Test func startsAfterTheMinimumAndEndsAfterTheGrace() {
		var debouncer = CallDebouncer(minimumDuration: 3, endGrace: 1)
		#expect(debouncer.update(recorders: [.zoom], at: 10).isEmpty)
		#expect(debouncer.deadline == 13)
		#expect(debouncer.update(recorders: [.zoom], at: 12.9).isEmpty)
		#expect(debouncer.update(recorders: [.zoom], at: 13) == [.started(app: .zoom)])
		#expect(debouncer.activeCall == .zoom)
		#expect(debouncer.deadline == nil)
		#expect(debouncer.update(recorders: [], at: 60).isEmpty)
		#expect(debouncer.deadline == 61)
		#expect(debouncer.update(recorders: [], at: 61) == [.ended])
		#expect(debouncer.activeCall == nil)
	}

	@Test func aGapBeforeTheMinimumRestartsTheClock() {
		let events = run([(0, [.zoom]), (2, []), (2.5, [.zoom]), (5, [.zoom]), (5.5, [.zoom])])
		#expect(events.map(\.0) == [5.5])
	}

	@Test func aBriefDropoutDuringACallDoesNotEndIt() {
		let events = run([(0, [.teams]), (3, [.teams]), (20, []), (20.4, [.teams]), (30, [.teams]), (40, []), (41, [])])
		#expect(events.map(\.1) == [.started(app: .teams), .ended])
		#expect(events.map(\.0) == [3, 41])
	}

	@Test func namesTheMostLikelyCallAppWhenSeveralRecord() {
		let events = run([(0, [.other("Recorder"), .browser("Chrome")]), (1, [.other("Recorder"), .browser("Chrome"), .zoom]), (3, [.other("Recorder"), .browser("Chrome"), .zoom])])
		#expect(events.map(\.1) == [.started(app: .zoom)])
		#expect(CallDebouncer.mostLikelyCall([.browser("Arc"), .browser("Chrome")]) == .browser("Arc"))
	}

	@Test func zeroGraceEndsOnTheFirstEmptySample() {
		let events = run([(0, [.slack]), (3, [.slack]), (8, [])], grace: 0)
		#expect(events.map(\.1) == [.started(app: .slack), .ended])
		#expect(events.last?.0 == 8)
	}
}
