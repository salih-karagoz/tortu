import Foundation

/// Where the app's settings are read and written.
///
/// Normally this is `.standard`. It exists as a seam because the snapshot
/// tool runs the real bundle, under the real bundle identifier, and would
/// otherwise write its own choices — which chart was being captured, which
/// appearance — straight into the user's preferences. The data store is
/// already protected by opening it in memory; this closes the same hole for
/// defaults.
///
/// Resolved once from the environment rather than switched at runtime, so
/// there is no window in which something has already read `.standard`.
enum AppDefaults {
    #if DEBUG
    /// A suite that is wiped on first use, so a capture run starts from the
    /// shipped defaults and leaves nothing behind.
    static let snapshotSuiteName = "com.muhammedsalihkaragoz.tortu.snapshot"
    #endif

    // `UserDefaults` is not `Sendable`, but this one instance is shared and
    // read-only after the first access, and `UserDefaults` is itself
    // thread-safe.
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TORTU_SNAPSHOT_DIR"] != nil,
           let suite = UserDefaults(suiteName: snapshotSuiteName) {
            suite.removePersistentDomain(forName: snapshotSuiteName)
            return suite
        }
        #endif
        return .standard
    }()
}
