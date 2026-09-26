import Darwin
import FluidAudio
import Foundation
import Synchronization
import YapKit

struct Options {
	var command = ""
	var file: String?
	var model = ParakeetModel.preferred
	var json = false
	/// Stream playback speed; 0 means as fast as possible.
	var speed = 1.0
	/// Size of each `append`, like one mic buffer.
	var pieceMilliseconds = 100
	var cancelAfter: Double?
	var finishTwice = false
	var concurrent = false
	/// Overrides `ChunkPolicy.maxChunk`, to force cuts inside sentences.
	var maxChunk: Double?
	/// Seconds to wait between warm-up and the measured call.
	var idle: Double?

	init(_ arguments: [String]) throws {
		var rest = arguments[...]
		guard let command = rest.popFirst() else { throw BenchError.usage(nil) }
		self.command = command
		while let argument = rest.popFirst() {
			func value() throws -> String {
				guard let value = rest.popFirst() else { throw BenchError.usage("missing value for \(argument)") }
				return value
			}
			switch argument {
			case "--json": json = true
			case "--finish-twice": finishTwice = true
			case "--concurrent": concurrent = true
			case "--model":
				let name = try value()
				guard let model = ParakeetModel(rawValue: name) else { throw BenchError.usage("unknown model \(name)") }
				self.model = model
			case "--speed":
				guard let speed = Double(try value()), speed >= 0 else { throw BenchError.usage("bad --speed") }
				self.speed = speed
			case "--piece-ms":
				guard let piece = Int(try value()), piece > 0 else { throw BenchError.usage("bad --piece-ms") }
				pieceMilliseconds = piece
			case "--max-chunk":
				guard let seconds = Double(try value()), seconds > 1 else { throw BenchError.usage("bad --max-chunk") }
				maxChunk = seconds
			case "--idle":
				guard let seconds = Double(try value()), seconds >= 0 else { throw BenchError.usage("bad --idle") }
				idle = seconds
			case "--cancel-after":
				guard let seconds = Double(try value()), seconds >= 0 else { throw BenchError.usage("bad --cancel-after") }
				cancelAfter = seconds
			default:
				if argument.hasPrefix("--") || file != nil { throw BenchError.usage("unexpected \(argument)") }
				file = argument
			}
		}
	}

	func requireFile() throws -> String {
		guard let file else { throw BenchError.usage("\(command) needs a WAV file") }
		return file
	}
}

enum BenchError: Error, CustomStringConvertible {
	case usage(String?)

	var description: String {
		switch self {
		case .usage(let message): message ?? "usage"
		}
	}
}

/// Any audio file as 16 kHz mono Float32.
func loadAudio(_ path: String) throws -> [Float] {
	try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
}

/// Process memory as the kernel counts it. `footprint` is what Activity
/// Monitor shows; `neural` is what the Neural Engine holds for us (the model
/// weights), which is not part of `footprint`.
struct MemorySnapshot: Codable {
	var footprintMB: Double
	var neuralMB: Double
	var residentMB: Double

	static func now() -> MemorySnapshot {
		var info = rusage_info_v6()
		let result = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
				proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
			}
		}
		guard result == 0 else { return MemorySnapshot(footprintMB: 0, neuralMB: 0, residentMB: 0) }
		return MemorySnapshot(
			footprintMB: megabytes(info.ri_phys_footprint),
			neuralMB: megabytes(info.ri_neural_footprint),
			residentMB: megabytes(info.ri_resident_size))
	}

	var summary: String {
		"footprint \(format(footprintMB, 0)) MB, neural \(format(neuralMB, 0)) MB, resident \(format(residentMB, 0)) MB"
	}

	private static func megabytes(_ bytes: UInt64) -> Double {
		Double(bytes) / 1_048_576
	}
}

func milliseconds(_ duration: Duration) -> Double {
	Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

func format(_ value: Double, _ digits: Int = 1) -> String {
	String(format: "%.\(digits)f", value)
}

/// Progress and chatter go to stderr so `--json` output stays parseable.
func log(_ message: String) {
	FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printJSON(_ value: some Encodable) throws {
	let encoder = JSONEncoder()
	encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
	print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Logs model progress, but only when the step changes or the download
/// moves by 5 %, so a 600 MB download doesn't print a thousand lines.
final class ProgressLogger: Sendable {
	private let label: String
	private let last = Mutex<String>("")

	init(label: String = "") {
		self.label = label
	}

	func callAsFunction(_ progress: ModelProgress) {
		let line: String
		switch progress {
		case .downloading(let fraction): line = "downloading \(Int(fraction * 20) * 5) %"
		case .compiling: line = "loading / compiling"
		case .ready: line = "ready"
		}
		let changed = last.withLock { previous in
			defer { previous = line }
			return previous != line
		}
		if changed { log("\(label)model: \(line)") }
	}
}
