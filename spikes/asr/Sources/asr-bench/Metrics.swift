import Darwin
import Foundation
import Synchronization

/// Process memory as the kernel accounts it. `footprint` is what Activity
/// Monitor shows as "Memory"; `resident` also counts clean file-backed pages
/// such as memory-mapped model weights.
struct MemorySnapshot: Sendable {
	var resident: UInt64
	var footprint: UInt64
	var lifetimePeakFootprint: UInt64

	static func now() -> MemorySnapshot {
		var info = rusage_info_v4()
		let result = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
				proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
			}
		}
		guard result == 0 else { return MemorySnapshot(resident: 0, footprint: 0, lifetimePeakFootprint: 0) }
		return MemorySnapshot(
			resident: info.ri_resident_size,
			footprint: info.ri_phys_footprint,
			lifetimePeakFootprint: info.ri_lifetime_max_phys_footprint
		)
	}
}

func mb(_ bytes: UInt64) -> String {
	String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

/// Polls memory on a background thread so we catch the peak inside a window
/// (the kernel only keeps a lifetime peak).
final class PeakMemorySampler: Sendable {
	private let state = Mutex<(running: Bool, resident: UInt64, footprint: UInt64)>((false, 0, 0))

	func start() {
		let now = MemorySnapshot.now()
		state.withLock { $0 = (true, now.resident, now.footprint) }
		let thread = Thread { [self] in
			while state.withLock({ $0.running }) {
				let snapshot = MemorySnapshot.now()
				state.withLock {
					$0.resident = max($0.resident, snapshot.resident)
					$0.footprint = max($0.footprint, snapshot.footprint)
				}
				usleep(5_000)
			}
		}
		thread.start()
	}

	func stop() -> (resident: UInt64, footprint: UInt64) {
		state.withLock {
			$0.running = false
			return ($0.resident, $0.footprint)
		}
	}
}

func seconds(since start: ContinuousClock.Instant) -> Double {
	let duration = ContinuousClock.now - start
	return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// MARK: - Word error rate

enum TextNormalizer {
	/// Lowercase, drop everything that is not a letter or digit, collapse whitespace.
	static func normalize(_ text: String) -> String {
		let lowered = text.lowercased()
		let scalars = lowered.unicodeScalars.map { scalar -> Character in
			CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
				? Character(scalar) : " "
		}
		return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	static func words(_ text: String, normalized: Bool) -> [String] {
		let source = normalized ? normalize(text) : text
		return source.split(whereSeparator: \.isWhitespace).map(String.init)
	}
}

struct WordErrors: Sendable {
	var edits: Int
	var referenceWords: Int

	var rate: Double { referenceWords == 0 ? 0 : Double(edits) / Double(referenceWords) }

	static func + (lhs: WordErrors, rhs: WordErrors) -> WordErrors {
		WordErrors(edits: lhs.edits + rhs.edits, referenceWords: lhs.referenceWords + rhs.referenceWords)
	}

	static let zero = WordErrors(edits: 0, referenceWords: 0)
}

func wordErrors(reference: String, hypothesis: String, normalized: Bool) -> WordErrors {
	let ref = TextNormalizer.words(reference, normalized: normalized)
	let hyp = TextNormalizer.words(hypothesis, normalized: normalized)
	if ref.isEmpty { return WordErrors(edits: hyp.count, referenceWords: 0) }
	var previous = Array(0...hyp.count)
	var current = [Int](repeating: 0, count: hyp.count + 1)
	for i in 1...ref.count {
		current[0] = i
		if !hyp.isEmpty {
			for j in 1...hyp.count {
				let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
				current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
			}
		}
		swap(&previous, &current)
	}
	return WordErrors(edits: previous[hyp.count], referenceWords: ref.count)
}

// MARK: - Stats

func percentile(_ values: [Double], _ p: Double) -> Double {
	guard !values.isEmpty else { return 0 }
	let sorted = values.sorted()
	let index = min(sorted.count - 1, Int((p / 100 * Double(sorted.count - 1)).rounded()))
	return sorted[index]
}

func fmt(_ value: Double, _ digits: Int = 3) -> String {
	String(format: "%.\(digits)f", value)
}
