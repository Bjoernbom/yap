import Foundation

/// Where yap keeps its own preferences (trigger key, onboarding done).
///
/// Normally the standard domain. Debug builds accept `-YapDefaultsSuite <name>`
/// so a test build can go through first run and switch keys without touching
/// the defaults of the user's own yap, which shares the bundle ID.
enum AppDefaults {
	// UserDefaults is documented thread-safe; the SDK just doesn't mark it Sendable.
	nonisolated(unsafe) static let store: UserDefaults = {
		#if DEBUG
		if let suite = UserDefaults.standard.string(forKey: "YapDefaultsSuite"), !suite.isEmpty,
		   let defaults = UserDefaults(suiteName: suite) {
			return defaults
		}
		#endif
		return .standard
	}()
}
