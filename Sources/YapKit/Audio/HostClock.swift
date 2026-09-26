import Darwin

/// Mach host time, the clock Core Audio stamps buffers with. `AudioChunk.hostTime`
/// is in these ticks so mic and system-audio tracks line up without conversion.
public enum HostClock {
	/// Ticks per second (24 MHz on Apple Silicon).
	public static let ticksPerSecond: Double = {
		var info = mach_timebase_info_data_t()
		mach_timebase_info(&info)
		guard info.numer > 0 else { return 1e9 }
		return 1e9 * Double(info.denom) / Double(info.numer)
	}()

	public static func now() -> UInt64 { mach_absolute_time() }

	public static func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }

	public static func ticks(seconds: Double) -> UInt64 { UInt64(max(seconds, 0) * ticksPerSecond) }

	/// Signed difference `later - earlier` in milliseconds.
	public static func milliseconds(from earlier: UInt64, to later: UInt64) -> Double {
		(Double(later) - Double(earlier)) / ticksPerSecond * 1000
	}
}
