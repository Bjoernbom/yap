import CoreAudio
import Foundation

struct AudioProcess: Equatable {
	let object: AudioObjectID
	let pid: pid_t
	let bundleID: String
	let input: Bool
	let output: Bool
}

func audioProcesses() -> [AudioProcess] {
	getArray(systemObject, address(kAudioHardwarePropertyProcessObjectList), AudioObjectID(0)).map { obj in
		AudioProcess(
			object: obj,
			pid: getValue(obj, address(kAudioProcessPropertyPID), pid_t(0)) ?? 0,
			bundleID: getString(obj, address(kAudioProcessPropertyBundleID)) ?? "",
			input: (getValue(obj, address(kAudioProcessPropertyIsRunningInput), UInt32(0)) ?? 0) != 0,
			output: (getValue(obj, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
		)
	}
}

func processName(_ pid: pid_t) -> String {
	var buffer = [CChar](repeating: 0, count: 1024)
	proc_pidpath(pid, &buffer, UInt32(buffer.count))
	let path = String(cString: buffer)
	return path.isEmpty ? "?" : (path as NSString).lastPathComponent
}

/// Watches the default input device and per-process input state via property listeners.
final class CallWatcher: @unchecked Sendable {
	let queue = DispatchQueue(label: "yapio.calls")
	let startNs = nowNs()
	private var inputUsers: Set<pid_t> = []
	private var registered: Set<AudioObjectID> = []
	private(set) var events: [(Double, String)] = []

	func log(_ s: String) {
		let t = msValue(nowNs() - startNs)
		events.append((t, s))
		print(String(format: "  +%7.1f ms  %@", t, s))
	}

	func start() {
		let device = defaultDevice(input: true)
		var running = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
		AudioObjectAddPropertyListenerBlock(device, &running, queue) { [self] _, _ in
			log("default input '\(AudioDeviceDescription(device))' isRunningSomewhere = \(isRunningSomewhere(device))")
			refresh("device running changed")
		}
		var list = address(kAudioHardwarePropertyProcessObjectList)
		AudioObjectAddPropertyListenerBlock(systemObject, &list, queue) { [self] _, _ in log("event: process list changed (\(audioProcesses().count) objects)"); refresh("process list changed") }
		queue.sync { refresh("initial") }
	}

	/// Polling fallback, to tell apart "listener did not fire" from "property never changed".
	func poll() { queue.async { [self] in refresh("poll") } }

	/// Per-process IsRunningInput listeners; the process list listener alone does not fire when an
	/// existing audio client starts using the mic.
	private func refresh(_ why: String) {
		let procs = audioProcesses()
		for p in procs where !registered.contains(p.object) {
			registered.insert(p.object)
			var addr = address(kAudioProcessPropertyIsRunningInput)
			AudioObjectAddPropertyListenerBlock(p.object, &addr, queue) { [self] _, _ in log("event: isRunningInput changed on obj \(p.object)"); refresh("isRunningInput changed") }
		}
		let now = Set(procs.filter(\.input).map(\.pid))
		for pid in now.subtracting(inputUsers) {
			let p = procs.first { $0.pid == pid }
			log("mic START pid \(pid) \(processName(pid)) bundle '\(p?.bundleID ?? "")' (\(why))")
		}
		for pid in inputUsers.subtracting(now) {
			log("mic STOP  pid \(pid) \(processName(pid)) (\(why))")
		}
		inputUsers = now
	}
}

func AudioDeviceDescription(_ id: AudioDeviceID) -> String { device(id).name }

@MainActor
func runCalls(_ args: Args) {
	print("== Call detection")
	let def = defaultDevice(input: true)
	print("  default input: \(def) '\(device(def).name)' isRunningSomewhere=\(isRunningSomewhere(def))")
	let procs = audioProcesses()
	print("  audio process objects: \(procs.count)")
	for p in procs where p.input || p.output || args.flag("verbose") {
		print("    obj \(p.object) pid \(p.pid) \(processName(p.pid)) bundle '\(p.bundleID)' in=\(p.input) out=\(p.output)")
	}
	let watcher = CallWatcher()
	watcher.start()
	let timer = Timer(timeInterval: 0.1, repeats: true) { _ in if args.flag("poll") { watcher.poll() } }
	RunLoop.current.add(timer, forMode: .common)
	defer { timer.invalidate() }
	if args.flag("demo") {
		// Start another process that records the mic, to prove we see it (bundle id comes from the
		// embedded Info.plist of the child).
		let exe = CommandLine.arguments[0]
		let launchNs = nowNs()
		watcher.log("launching child: \(exe) mic --record 2 --name calls-demo")
		let child = Children.shared.launch(exe, ["mic", "--record", "2", "--name", "calls-demo"])
		runLoop(for: 5) { !(child?.isRunning ?? false) }
		print("  child exited after \(ms(nowNs() - launchNs))")
		runLoop(for: 1)
	} else {
		let seconds = args.double("seconds", 15)
		print("  watching \(Int(seconds)) s — start a call or any recorder ...")
		runLoop(for: seconds)
	}
	Children.shared.killAll()
}
