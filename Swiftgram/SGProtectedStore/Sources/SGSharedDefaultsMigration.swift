import Foundation
import SGAppGroupIdentifier

/// Zenlygram — migrations M0 / M6 (audit batch 3, #49): move the settings the app extensions must read from
/// the app's standard defaults into the app-group suite, and own the `zg.protect.migrations` bitmask (M0–M6).
///
/// Main app only, idempotent (bits 0 and 6). Values are read with `persistentDomain(forName:)`: SGSimpleSettings
/// registers defaults for these keys, so `object(forKey:)` would never be nil and could not tell a stored
/// value from a registered one.
/// - M0 (Batch 3) moves every key below.
/// - M6 (Batch 6) adds the kept-deleted / edit-history keys that the extensions' replay path reads. On a
///   device where M0 already ran it moves only those (retention) keys once more, so a build without Batch 3
///   that ran in between cannot leave them behind in standard defaults, and a Secret Vault flag already in
///   the group suite is never replaced by a stale standard copy.
public enum SGSharedDefaultsMigration {
    static let migrationsKey = "zg.protect.migrations"

    /// Kept-deleted messages / edit history switches, moved unchanged (same keys) by M0 and M6.
    static let retentionValueKeys: [String] = [
        "showDeletedMessages",
        "editHistoryEnabled"
    ]
    /// Boolean settings that moved to the group suite unchanged (same keys) by M0.
    static let movedValueKeys: [String] = [
        "secretVaultEnabled",
        "secretVaultUseSecretCode"
    ] + retentionValueKeys
    /// `[String]` legacy registry of kept-deleted messages: merged as a union. Batch 6 replaced it with a
    /// Postbox index; its one-time migration reads it from the group suite and then deletes it.
    static let registryKey = "deletedMessagesRegistry"
    /// `[accountId: Int]` legacy last sweep timestamps: merged with a per-key max.
    static let lastSweepKey = "deletedMessagesLastSweep"
    /// `Int` Unix-time purge requests (Batch 6): merged with a max, so a requested purge is never lost.
    static let purgeBeforeKeys: [String] = [
        "editHistoryPurgeBefore",
        "keptDeletedPurgeBefore"
    ]

    private static let lock = NSLock()
    private static let groupDefaults: UserDefaults? = UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup)

    public static func runIfNeeded() {
        if SGProtectedStore.isAppExtension {
            return
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let group = self.groupDefaults else {
            return
        }
        let bits = group.integer(forKey: self.migrationsKey)
        let m0Bit = 1 << SGProtectedMigration.m0SharedDefaults.rawValue
        let m6Bit = 1 << SGProtectedMigration.m6RetentionSettings.rawValue
        if bits & m0Bit != 0 && bits & m6Bit != 0 {
            return
        }
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        let standard = UserDefaults.standard
        let domain = standard.persistentDomain(forName: bundleId) ?? [:]

        // M6 alone (M0 already done): the retention keys only. The registry below moves with the
        // showDeletedMessages flag, so the Batch 6 migration finds both in the same store.
        let valueKeys = bits & m0Bit == 0 ? self.movedValueKeys : self.retentionValueKeys
        for key in valueKeys {
            if let value = domain[key] {
                group.set(value, forKey: key)
                standard.removeObject(forKey: key)
            }
        }
        if let legacyRegistry = domain[self.registryKey] as? [String] {
            var registry = group.stringArray(forKey: self.registryKey) ?? []
            let existing = Set(registry)
            registry.append(contentsOf: legacyRegistry.filter { !existing.contains($0) })
            group.set(registry, forKey: self.registryKey)
            standard.removeObject(forKey: self.registryKey)
        }
        if let legacySweep = domain[self.lastSweepKey] as? [String: Any] {
            var merged: [String: Int] = [:]
            if let current = group.dictionary(forKey: self.lastSweepKey) {
                for (accountId, value) in current {
                    merged[accountId] = (value as? NSNumber)?.intValue ?? 0
                }
            }
            for (accountId, value) in legacySweep {
                let timestamp = (value as? NSNumber)?.intValue ?? 0
                merged[accountId] = max(merged[accountId] ?? 0, timestamp)
            }
            group.set(merged, forKey: self.lastSweepKey)
            standard.removeObject(forKey: self.lastSweepKey)
        }
        for key in self.purgeBeforeKeys {
            if let legacyTimestamp = (domain[key] as? NSNumber)?.intValue {
                group.set(max(group.integer(forKey: key), legacyTimestamp), forKey: key)
                standard.removeObject(forKey: key)
            }
        }
        group.set(bits | m0Bit | m6Bit, forKey: self.migrationsKey)
    }

    // MARK: - Migration bitmask (shared lock, so concurrent M0 / Mn updates never lose a bit)

    static func hasMigration(_ migration: SGProtectedMigration) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let bits = self.groupDefaults?.integer(forKey: self.migrationsKey) ?? 0
        return bits & (1 << migration.rawValue) != 0
    }

    static func markMigration(_ migration: SGProtectedMigration) {
        if SGProtectedStore.isAppExtension {
            return
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let group = self.groupDefaults else {
            return
        }
        let bits = group.integer(forKey: self.migrationsKey)
        group.set(bits | (1 << migration.rawValue), forKey: self.migrationsKey)
    }
}
