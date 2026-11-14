import Foundation

/// Tracks the lifecycle of the settings "NEW" badges.
///
/// A badge for a given key stays visible until EITHER:
///  - the user interacts with that row (`markInteracted`), OR
///  - 30 days have passed since the badge was first seen
///    (`shouldShow` stamps the first-seen timestamp on its first evaluation).
///
/// Keys are the stable case names of the settings enums (e.g. "secretVaultEnabled",
/// "chatLock"). Both maps are persisted in UserDefaults via the module's
/// `UserDefaultsBackedDictionary` (thread-safe: `shouldShow` is evaluated from the
/// settings entries-builder, which runs on every list state update and may run off-main).
public enum SGNewBadgeTracker {
    /// A badge expires 30 days after it was first seen, even without interaction.
    private static let badgeTTL: TimeInterval = 30.0 * 24.0 * 60.0 * 60.0

    // Touch SGSimpleSettings.shared first so the registered defaults ([:]) are in
    // place before UserDefaultsBackedDictionary force-casts the stored dictionary.
    // The trailing `keys` read warms the wrapper's container cache on this single
    // thread: its read paths lazily load the cache under only a READ lock, so the
    // first load must not race — static-let init is once-guarded, and no other
    // thread holds the reference until this closure returns.
    private static let firstSeen: UserDefaultsBackedDictionary<String, Double> = {
        let _ = SGSimpleSettings.shared
        let dict = UserDefaultsBackedDictionary<String, Double>(userDefaultsKey: SGSimpleSettings.Keys.newBadgeFirstSeen.rawValue, threadSafe: true)
        let _ = dict.keys
        return dict
    }()

    private static let interacted: UserDefaultsBackedDictionary<String, Bool> = {
        let _ = SGSimpleSettings.shared
        let dict = UserDefaultsBackedDictionary<String, Bool>(userDefaultsKey: SGSimpleSettings.Keys.newBadgeInteracted.rawValue, threadSafe: true)
        let _ = dict.keys
        return dict
    }()

    /// Returns whether the NEW badge for `key` should be visible.
    /// Stamps the first-seen timestamp for the key if absent (idempotent), so the
    /// 30-day clock starts the first time the badge could have been displayed.
    public static func shouldShow(_ key: String) -> Bool {
        if interacted.contains(key) {
            return false
        }
        if let firstSeenTimestamp = firstSeen[key] {
            return Date().timeIntervalSince1970 - firstSeenTimestamp < badgeTTL
        }
        firstSeen[key] = Date().timeIntervalSince1970
        return true
    }

    /// Marks the row for `key` as interacted with, permanently retiring its badge.
    public static func markInteracted(_ key: String) {
        if !interacted.contains(key) {
            interacted[key] = true
        }
    }
}
