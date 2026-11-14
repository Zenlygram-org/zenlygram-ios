import Foundation
import Security
import UIKit
import notify
import SGAppGroupIdentifier

/// How a peer must be treated by a surface outside the main app's session (extensions, system surfaces).
public enum SGPeerProtection: Equatable {
    case none
    case locked
    case vaulted
    /// Protection is configured but the shared state cannot be read right now: fail closed.
    case unknown
}

/// Bits of `zg.protect.migrations`.
public enum SGProtectedMigration: Int {
    /// Settings moved from standard defaults to the app-group suite.
    case m0SharedDefaults = 0
    /// Chat Lock keychain items moved to AfterFirstUnlockThisDeviceOnly (audit #30).
    case m1KeychainClass = 1
    /// `vaultConfigured` / `chatLockConfigured` reconciled at least once (M2 also runs on every launch).
    case m2Flags = 2
    /// Shared snapshot created from the legacy vault set.
    case m3Snapshot = 3
    /// Legacy unassigned vault ids assigned to the logged-in accounts.
    case m4AccountAssignment = 4
    /// One-time cleanup of donations / delivered notifications / widgets.
    case m5Cleanup = 5
    /// Kept-deleted messages / edit history settings (Batch 6) moved to the app-group suite, also on devices
    /// where M0 already ran (SGSharedDefaultsMigration).
    case m6RetentionSettings = 6
}

/// Raw state of the shared snapshot item (`SGProtectedStore.snapshotState()`).
public enum SGProtectionSnapshotState {
    /// Decoded. `isNewerFormat` marks an item written by a newer build, read leniently and used as is.
    case known(SGProtectionSnapshot)
    /// No snapshot and `zg.protect.schema < 1`: migration M3 has not run yet.
    case preMigration
    /// Present (keychain item, or the dev fallback) but does not decode. Readers fail closed (`.unknown`,
    /// retried on a timer); writers rebuild it only while the vault is off (`vaultConfigured == false`).
    case corrupt(Data)
    /// Cannot be read right now (device locked, keychain error, -34018 in a signed build): fail closed.
    case unknown
}

public enum SGLegacyVaultIdsResult {
    case present(Set<Int64>)
    case absent
    case unreadable
}

public enum SGProtectedStoreError: Error {
    case notMainApp
    case unreadable
    case encodingFailed
    case writeFailed(OSStatus)
    case verifyFailed
}

public struct SGProtectionSnapshotMutation {
    public let before: SGProtectionSnapshot
    public let after: SGProtectionSnapshot

    public var changed: Bool {
        return self.before != self.after
    }
}

/// Zenlygram — Secret Vault / Chat Lock state shared by the app and its extensions (audit batch 3, design §4–§5).
///
/// Storage:
/// - The snapshot (vault members per account, legacy unassigned ids, locked ids) is one keychain item in the
///   app-group access group, `AfterFirstUnlockThisDeviceOnly`, written only by the main app and verified by a
///   read-back after every write. Only a keychain-less build (`SGProtectedKeychain.isKeychainlessBuild`: fake-
///   codesigned simulator or DEBUG) treats `errSecMissingEntitlement` as "no keychain" and uses the plaintext
///   group-defaults key `zg.protect.fb.snapshot.v1` instead. Signed release builds treat -34018 as unreadable and
///   never create that key; an existing copy (from a dev build) is only read while the keychain item is absent,
///   and the next successful keychain write deletes it.
/// - Non-secret flags (`secretVaultEnabled`, `zg.protect.*`) live in the app-group defaults and are read
///   uncached, so every process sees the main app's latest writes.
///
/// Reads fail closed: a configured protection whose snapshot cannot be read (or does not decode) answers
/// `.unknown` / "hidden", and an unknown result is never cached as empty; it is re-resolved after
/// `unknownRetryInterval` (and, in the main app, when protected data becomes available / the app becomes
/// active). Writers (main app only) refuse to mutate on top of an unreadable base. An undecodable item, or one
/// written by a newer build, is rebuilt only while the vault is off (`vaultConfigured == false`, which the
/// Settings off switch sets through ChatPincodeManager.removeVault() before SecretVaultManager.clearVault()),
/// so that path recovers a broken item without ever downgrading a configured vault. Extensions never write.
public final class SGProtectedStore {
    public enum ChangeKind: String {
        /// Vault membership (or the legacy unassigned set) was written.
        case vault
        /// Only the Chat Lock mirror was written.
        case locked
        /// `vaultConfigured` / `chatLockConfigured` changed.
        case flags
        /// The snapshot became readable again (unknown → known).
        case readability
        /// A migration created or reshaped the snapshot.
        case migration
        /// Extensions: another process changed the state (Darwin notification).
        case external
    }

    public static let shared = SGProtectedStore()

    public static let isAppExtension: Bool = Bundle.main.bundlePath.hasSuffix(".appex")

    /// In-process, posted on the main queue after any change / revision bump, and after the state became
    /// readable again. userInfo: `[SGProtectedStore.changeKindKey: SGProtectedStore.ChangeKind]`.
    public static let didChangeNotification = Notification.Name("SGProtectedStoreDidChange")
    public static let changeKindKey = "kind"

    /// Darwin notification posted by the main app after every write (extensions drop their cache on it).
    public static var darwinNotificationName: String {
        return "\(SGProtectedKeychain.sharedAccessGroup).protect.changed"
    }

    // MARK: - Keys

    static let snapshotService = "uz.zenlygram.protected"
    static let snapshotAccount = "snapshot.v1"
    /// Best-effort copy of an undecodable snapshot, kept when the store rebuilds it (vault off).
    static let corruptSnapshotAccount = "snapshot.v1.corrupt"
    static let fallbackSnapshotKey = "zg.protect.fb.snapshot.v1"
    static let vaultConfiguredKey = "zg.protect.vaultConfigured"
    static let chatLockConfiguredKey = "zg.protect.chatLockConfigured"
    static let schemaKey = "zg.protect.schema"
    static let revisionKey = "zg.protect.revision"
    static let secretVaultEnabledKey = "secretVaultEnabled"
    /// Zenlygram — audit batch 4 (#70 / #71 / #41): non-secret recovery bitmask (`SGProtectionRecovery`), the
    /// bits the user has already been told about, the last known number of vaulted chats (for the recovery copy)
    /// and the vault credential's shape hint (for the secret-code gate). App-group defaults, uncached reads.
    static let recoveryKey = "zg.protect.recovery"
    static let recoveryAckKey = "zg.protect.recovery.ack"
    static let vaultCountKey = "zg.protect.vaultCount"
    static let vaultShapeKey = "zg.protect.vaultShape"
    static let vaultLengthKey = "zg.protect.vaultCodeLength"

    // Legacy, app-private (always queried without an access group).
    static let legacyCredentialService = "uz.fenixuz.app.ChatLock"
    static let legacyMetadataService = "uz.fenixuz.app.ChatLock.meta"
    static let legacyBlobService = "uz.fenixuz.app.ChatLock.blob"
    static let legacyVaultPeersAccount = "__fenix_vault_peers__"
    static let legacyVaultCredentialAccount = "__fenix_vault__"
    static let legacyBlobFallbackPrefix = "fenixuz_chatlock_fb_blob_"
    static let legacyPasswordFallbackPrefix = "fenixuz_chatlock_fb_pw_"
    /// Pre-v1 plaintext copy of the vault set (SGSimpleSettings.secretVaultPeerIds, standard defaults).
    static let legacyPlaintextVaultIdsKey = "secretVaultPeerIds"

    /// A cached unknown result is re-resolved after this long (extensions and the main app; the main app also
    /// retries when protected data becomes available / the app becomes active).
    static let unknownRetryInterval: Double = 2.0

    private enum Membership {
        case known(SGProtectionSnapshot)
        case unknown
    }

    private let defaults: UserDefaults?
    private let lock = NSLock()
    /// Serializes writers (main app).
    private let writeLock = NSLock()
    /// Serializes the recovery bitmask's read-modify-write (audit batch 4). Never taken inside `writeLock`.
    private let recoveryLock = NSLock()

    // Guarded by `lock`.
    private var cachedMembership: Membership?
    private var cacheGeneration = 0
    private var cachedRevision = -1
    private var cachedUnknownAt: Double = 0.0
    private var credentialProbe: (configured: Bool, isDefinitive: Bool, at: Double)?
    private var protectedDataAvailable: Bool?
    private var lockedIdsProviderValue: (() -> Set<Int64>?)?
    private var isDarwinObserverRegistered = false
    private var darwinToken: Int32 = 0

    private var observers: [NSObjectProtocol] = []

    private init() {
        if !SGProtectedStore.isAppExtension {
            SGSharedDefaultsMigration.runIfNeeded()
        }
        self.defaults = UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup)
        if !SGProtectedStore.isAppExtension {
            // Notification names only (never UIApplication.shared: this module is linked into extensions).
            let center = NotificationCenter.default
            self.observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.setProtectedDataAvailable(true)
                self?.retryUnknownMembership()
            }))
            self.observers.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.setProtectedDataAvailable(false)
            }))
            self.observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil, using: { [weak self] _ in
                self?.retryUnknownMembership()
            }))
        }
    }

    // MARK: - Flags (uncached reads of the app-group suite)

    private func storedBool(_ key: String) -> Bool? {
        guard let value = self.defaults?.object(forKey: key) as? NSNumber else {
            return nil
        }
        return value.boolValue
    }

    /// The Secret Vault setting (`secretVaultEnabled`), shared with the extensions.
    public var isVaultFeatureEnabled: Bool {
        return self.defaults?.bool(forKey: SGProtectedStore.secretVaultEnabledKey) ?? false
    }

    /// `zg.protect.vaultConfigured`; nil = not reconciled yet (before M2).
    public var vaultConfiguredFlag: Bool? {
        return self.storedBool(SGProtectedStore.vaultConfiguredKey)
    }

    /// `zg.protect.chatLockConfigured`; nil = not reconciled yet (before M2).
    public var chatLockConfiguredFlag: Bool? {
        return self.storedBool(SGProtectedStore.chatLockConfiguredKey)
    }

    /// `zg.protect.schema`; ≥ 1 means the snapshot is authoritative.
    public var schemaVersion: Int {
        return self.defaults?.integer(forKey: SGProtectedStore.schemaKey) ?? 0
    }

    /// `zg.protect.revision`, incremented on every snapshot write.
    public var revision: Int {
        return self.defaults?.integer(forKey: SGProtectedStore.revisionKey) ?? 0
    }

    /// Feature flag on and a vault PIN configured. Never throws; reads only defaults (and, in the main app
    /// before migration M2 ran once, a cached attributes-only probe of the vault credential).
    public var isVaultActive: Bool {
        guard self.isVaultFeatureEnabled else {
            return false
        }
        return self.isVaultConfigured
    }

    private var isVaultConfigured: Bool {
        if let value = self.vaultConfiguredFlag {
            return value
        }
        if SGProtectedStore.isAppExtension {
            // D9: before the first launch of the updated app, extensions keep the previous behaviour.
            return false
        }
        return self.probedVaultConfigured()
    }

    private var isChatLockConfigured: Bool {
        if let value = self.chatLockConfiguredFlag {
            return value
        }
        // Before M2: the main app assumes configured (fail closed); extensions keep the status quo (D9).
        return !SGProtectedStore.isAppExtension
    }

    /// `isVaultActive || chatLockConfigured`.
    public var isAnyProtectionConfigured: Bool {
        return self.isVaultActive || self.isChatLockConfigured
    }

    /// False when protection is configured but the snapshot is unreadable right now.
    public var isMembershipKnown: Bool {
        if !self.isAnyProtectionConfigured {
            return true
        }
        if case .unknown = self.membership() {
            return false
        }
        return true
    }

    // MARK: - Recovery state (audit batch 4; any thread, uncached reads; writers main-app only)
    //
    // The bitmask says which protection needs the user's help (see SGProtectionRecovery). It lives in the
    // app-group defaults, so it survives a restore exactly like the user's intent it is compared against
    // (`secretVaultEnabled`) and is readable by the extensions; `snapshotState()` and every verdict above stay
    // untouched, so a recovery state never hides or reveals a chat by itself.

    public var recovery: SGProtectionRecovery {
        return SGProtectionRecovery(rawValue: self.defaults?.integer(forKey: SGProtectedStore.recoveryKey) ?? 0)
    }

    /// The recovery bits the user has not been told about yet (the chat list shows its notice once).
    public var unacknowledgedRecovery: SGProtectionRecovery {
        let acknowledged = SGProtectionRecovery(rawValue: self.defaults?.integer(forKey: SGProtectedStore.recoveryAckKey) ?? 0)
        return self.recovery.subtracting(acknowledged)
    }

    /// Main app only. Newly set bits are unacknowledged again.
    public func insertRecovery(_ bits: SGProtectionRecovery) {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return
        }
        guard !bits.isEmpty else {
            return
        }
        self.recoveryLock.lock()
        let current = self.recovery
        let updated = current.union(bits)
        var changed = false
        if updated != current {
            self.defaults?.set(updated.rawValue, forKey: SGProtectedStore.recoveryKey)
            // A bit that was just (re-)raised must be announced again.
            let acknowledged = SGProtectionRecovery(rawValue: self.defaults?.integer(forKey: SGProtectedStore.recoveryAckKey) ?? 0)
            let keptAck = acknowledged.subtracting(updated.subtracting(current))
            if keptAck != acknowledged {
                self.defaults?.set(keptAck.rawValue, forKey: SGProtectedStore.recoveryAckKey)
            }
            changed = true
        }
        self.recoveryLock.unlock()
        if changed {
            notify_post(SGProtectedStore.darwinNotificationName)
            self.postChange(.flags)
        }
    }

    /// Main app only. Also drops those bits from the acknowledged set, so a later recurrence is announced again.
    public func clearRecovery(_ bits: SGProtectionRecovery) {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return
        }
        guard !bits.isEmpty else {
            return
        }
        self.recoveryLock.lock()
        let current = self.recovery
        let acknowledged = SGProtectionRecovery(rawValue: self.defaults?.integer(forKey: SGProtectedStore.recoveryAckKey) ?? 0)
        let updated = current.subtracting(bits)
        let updatedAck = acknowledged.subtracting(bits)
        var changed = false
        if updated != current {
            self.defaults?.set(updated.rawValue, forKey: SGProtectedStore.recoveryKey)
            changed = true
        }
        if updatedAck != acknowledged {
            self.defaults?.set(updatedAck.rawValue, forKey: SGProtectedStore.recoveryAckKey)
            changed = true
        }
        self.recoveryLock.unlock()
        if changed {
            notify_post(SGProtectedStore.darwinNotificationName)
            self.postChange(.flags)
        }
    }

    /// Main app only: the user has seen the notice for these bits (only bits that are actually set are marked).
    public func acknowledgeRecovery(_ bits: SGProtectionRecovery) {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return
        }
        self.recoveryLock.lock()
        let acknowledged = SGProtectionRecovery(rawValue: self.defaults?.integer(forKey: SGProtectedStore.recoveryAckKey) ?? 0)
        let updated = acknowledged.union(bits.intersection(self.recovery))
        var changed = false
        if updated != acknowledged {
            self.defaults?.set(updated.rawValue, forKey: SGProtectedStore.recoveryAckKey)
            changed = true
        }
        self.recoveryLock.unlock()
        if changed {
            notify_post(SGProtectedStore.darwinNotificationName)
            self.postChange(.flags)
        }
    }

    /// How many chats the vault held the last time it could be read (recovery copy only; 0 = unknown).
    /// Maintained by `mutateSnapshot`, which never overwrites it from a snapshot that was synthesized empty
    /// because the item is gone (a restore), so the number survives the migration it is needed for.
    public var lastKnownVaultMemberCount: Int {
        return self.defaults?.integer(forKey: SGProtectedStore.vaultCountKey) ?? 0
    }

    /// Non-secret shape of the vault credential (`ChatPincodeManager.vaultCodeShape()` keeps it current).
    public var vaultCodeShapeHint: SGVaultCodeShape {
        return SGVaultCodeShape(rawValue: self.defaults?.integer(forKey: SGProtectedStore.vaultShapeKey) ?? 0) ?? .unknown
    }

    /// Main app only.
    public func setVaultCodeShapeHint(_ shape: SGVaultCodeShape) {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return
        }
        guard self.vaultCodeShapeHint != shape else {
            return
        }
        self.defaults?.set(shape.rawValue, forKey: SGProtectedStore.vaultShapeKey)
    }

    /// Audit batch 4 (round 2) — non-secret length of the vault credential, learned by the secret-code search
    /// gate the first time the credential actually matched (`SGVaultCodeLength.unknown` = never observed).
    ///
    /// It is a BILLING hint, not an authorisation input: the gate uses it only to decide whether a failed check
    /// is worth one `.vaultSearch` attempt, never to decide whether to check at all, so a stale value (the user
    /// changed the PIN to a different length) can delay a lockout but can never refuse the real credential. It
    /// is deliberately kept next to `vaultCodeShapeHint`, which is already this coarse, and never holds any part
    /// of the credential itself.
    public var vaultCodeLengthHint: Int {
        return self.defaults?.integer(forKey: SGProtectedStore.vaultLengthKey) ?? SGVaultCodeLength.unknown
    }

    /// Main app only. `SGVaultCodeLength.unknown` (0) — or anything below it — CLEARS the hint, which is what
    /// removing the vault should do alongside `setVaultCodeShapeHint(.unknown)`.
    public func setVaultCodeLengthHint(_ length: Int) {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return
        }
        let value = max(length, SGVaultCodeLength.unknown)
        guard self.vaultCodeLengthHint != value else {
            return
        }
        if value == SGVaultCodeLength.unknown {
            self.defaults?.removeObject(forKey: SGProtectedStore.vaultLengthKey)
        } else {
            self.defaults?.set(value, forKey: SGProtectedStore.vaultLengthKey)
        }
    }

    /// True only when the snapshot item is DEFINITIVELY gone (no keychain item, no dev fallback copy): the
    /// vault membership cannot be recovered. False while it is merely unreadable (fail closed).
    public func snapshotItemIsAbsent() -> Bool {
        guard case .absent = SGProtectedKeychain.read(service: SGProtectedStore.snapshotService, account: SGProtectedStore.snapshotAccount, accessGroup: SGProtectedKeychain.sharedAccessGroup) else {
            return false
        }
        return self.defaults?.data(forKey: SGProtectedStore.fallbackSnapshotKey) == nil
    }

    // MARK: - Verdicts (any thread)

    /// 1. self → `.none`; 2. vault member of this account (or legacy unassigned) → `.vaulted`; 3. locked →
    /// `.locked`; 4. unreadable while protection is configured → `.unknown`; 5. `.none`.
    public func protection(peerId: Int64, accountPeerId: Int64) -> SGPeerProtection {
        if peerId == accountPeerId {
            return .none
        }
        let vaultActive = self.isVaultActive
        if !vaultActive && !self.isChatLockConfigured {
            return .none
        }
        switch self.membership() {
        case let .known(snapshot):
            if vaultActive && snapshot.isVaulted(peerId, accountPeerId: accountPeerId) {
                return .vaulted
            }
            if snapshot.locked.contains(peerId) {
                return .locked
            }
            return .none
        case .unknown:
            return .unknown
        }
    }

    /// Same verdict for "any account" (system-wide surfaces that are not tied to one account).
    public func deviceProtection(peerId: Int64) -> SGPeerProtection {
        let vaultActive = self.isVaultActive
        if !vaultActive && !self.isChatLockConfigured {
            return .none
        }
        switch self.membership() {
        case let .known(snapshot):
            if vaultActive && snapshot.isVaultedInAnyAccount(peerId) {
                return .vaulted
            }
            if snapshot.locked.contains(peerId) {
                return .locked
            }
            return .none
        case .unknown:
            return .unknown
        }
    }

    /// Vault active and the peer is vaulted in some account (or membership is unknown). Fail closed.
    public func isVaultHiddenInAnyAccount(peerId: Int64) -> Bool {
        guard self.isVaultActive else {
            return false
        }
        switch self.membership() {
        case let .known(snapshot):
            return snapshot.isVaultedInAnyAccount(peerId)
        case .unknown:
            return true
        }
    }

    // MARK: - Core-internal reads (SGSecretVault / SGChatLock; surfaces use SecretVaultManager)

    /// `peerId != accountPeerId && isVaultActive && (member of this account's vault || unassigned || unknown)`.
    public func isVaultHidden(peerId: Int64, accountPeerId: Int64) -> Bool {
        if peerId == accountPeerId {
            return false
        }
        guard self.isVaultActive else {
            return false
        }
        switch self.membership() {
        case let .known(snapshot):
            return snapshot.isVaulted(peerId, accountPeerId: accountPeerId)
        case .unknown:
            return true
        }
    }

    /// The current snapshot (legacy vault set as `unassigned` before M3, main app), nil when unreadable.
    /// Ignores the feature flag.
    public func currentSnapshot() -> SGProtectionSnapshot? {
        if case let .known(snapshot) = self.membership() {
            return snapshot
        }
        return nil
    }

    /// Vault members of one account (own set + unassigned, never the account itself); nil when unreadable.
    /// Ignores the feature flag.
    public func vaultMemberIds(accountPeerId: Int64) -> Set<Int64>? {
        return self.currentSnapshot()?.vaultMembers(accountPeerId: accountPeerId)
    }

    /// Chat Lock peers from the snapshot; nil when unreadable.
    public func lockedPeerIds() -> Set<Int64>? {
        return self.currentSnapshot()?.locked
    }

    /// Legacy account-less vault ids that migration M4 has not assigned yet.
    public var hasUnassignedEntries: Bool {
        guard let snapshot = self.currentSnapshot() else {
            return false
        }
        return !snapshot.unassigned.isEmpty
    }

    // MARK: - Snapshot reads

    /// Raw state of the snapshot item (keychain; the plaintext dev fallback on `errSecMissingEntitlement` only
    /// in a keychain-less build, or read-only while the keychain item is absent).
    public func snapshotState() -> SGProtectionSnapshotState {
        let schema = self.schemaVersion
        let data: Data
        switch SGProtectedKeychain.read(service: SGProtectedStore.snapshotService, account: SGProtectedStore.snapshotAccount, accessGroup: SGProtectedKeychain.sharedAccessGroup) {
        case let .present(value):
            data = value
        case .absent:
            // Read-only compatibility: a device that once ran a keychain-less dev build may still hold the
            // plaintext copy (the next successful keychain write deletes it; release builds never create it).
            if let fallback = self.defaults?.data(forKey: SGProtectedStore.fallbackSnapshotKey) {
                data = fallback
            } else {
                // Absent with schema ≥ 1: a keychain wiped by a restore; the flags reconcile via M2.
                return schema >= 1 ? .known(.empty) : .preMigration
            }
        case let .unreadable(status):
            // A signed release build treats every read failure, -34018 included, as unreadable (fail closed).
            guard status == errSecMissingEntitlement && SGProtectedKeychain.isKeychainlessBuild else {
                return .unknown
            }
            if let fallback = self.defaults?.data(forKey: SGProtectedStore.fallbackSnapshotKey) {
                data = fallback
            } else if schema < 1 {
                return .preMigration
            } else {
                return .unknown
            }
        }
        guard let snapshot = try? JSONDecoder().decode(SGProtectionSnapshot.self, from: data) else {
            return .corrupt(data)
        }
        return .known(snapshot)
    }

    private func membership() -> Membership {
        if SGProtectedStore.isAppExtension {
            return self.extensionMembership()
        }
        let now = SGProtectedStore.now()
        self.lock.lock()
        // True when this call dropped a stale unknown result: a known answer then announces `.readability`.
        var droppedUnknown = false
        if let cached = self.cachedMembership {
            if case .unknown = cached, now - self.cachedUnknownAt >= SGProtectedStore.unknownRetryInterval {
                // A transient failure (keychain error while unlocked, undecodable item that a write may have
                // rebuilt) must not hide everything until the next activation: re-resolve on a timer too.
                self.cachedMembership = nil
                self.cacheGeneration += 1
                droppedUnknown = true
            } else {
                self.lock.unlock()
                return cached
            }
        }
        let generation = self.cacheGeneration
        self.lock.unlock()

        let value = self.resolveMainAppMembership()

        self.lock.lock()
        if self.cacheGeneration == generation && self.cachedMembership == nil {
            // An unknown result is kept for `unknownRetryInterval`, or until protected data becomes available /
            // the app becomes active (retryUnknownMembership), and is never cached as empty.
            self.cachedMembership = value
            if case .unknown = value {
                self.cachedUnknownAt = now
            }
        }
        self.lock.unlock()
        if droppedUnknown, case .known = value {
            self.postChange(.readability)
        }
        return value
    }

    private func resolveMainAppMembership() -> Membership {
        switch self.snapshotState() {
        case let .known(snapshot):
            return .known(snapshot)
        case .corrupt, .unknown:
            return .unknown
        case .preMigration:
            // Before M3: the legacy (account-less) vault set, hidden in every account.
            switch self.legacyVaultIds() {
            case let .present(ids):
                return .known(SGProtectionSnapshot(vault: [:], unassigned: ids, locked: self.lockedIdsProvider?() ?? []))
            case .absent:
                return .known(SGProtectionSnapshot(vault: [:], unassigned: [], locked: self.lockedIdsProvider?() ?? []))
            case .unreadable:
                return .unknown
            }
        }
    }

    private func extensionMembership() -> Membership {
        self.ensureDarwinObserver()
        let revision = self.revision
        let now = SGProtectedStore.now()
        self.lock.lock()
        if let cached = self.cachedMembership, self.cachedRevision == revision {
            var isFresh = true
            if case .unknown = cached, now - self.cachedUnknownAt >= SGProtectedStore.unknownRetryInterval {
                isFresh = false
            }
            if isFresh {
                self.lock.unlock()
                return cached
            }
        }
        self.lock.unlock()

        let value: Membership
        switch self.snapshotState() {
        case let .known(snapshot):
            value = .known(snapshot)
        case .preMigration:
            // D9: until the updated app has launched once, extensions keep the previous behaviour.
            value = .known(.empty)
        case .corrupt, .unknown:
            value = .unknown
        }

        self.lock.lock()
        self.cachedMembership = value
        self.cachedRevision = revision
        if case .unknown = value {
            self.cachedUnknownAt = now
        }
        self.lock.unlock()
        return value
    }

    private func ensureDarwinObserver() {
        self.lock.lock()
        if self.isDarwinObserverRegistered {
            self.lock.unlock()
            return
        }
        self.isDarwinObserverRegistered = true
        self.lock.unlock()

        var token: Int32 = 0
        let status = notify_register_dispatch(SGProtectedStore.darwinNotificationName, &token, DispatchQueue.main, { [weak self] _ in
            guard let self else {
                return
            }
            self.invalidateCache()
            self.postChange(.external)
        })
        if status == 0 { // NOTIFY_STATUS_OK
            self.lock.lock()
            self.darwinToken = token
            self.lock.unlock()
        }
    }

    private func invalidateCache() {
        self.lock.lock()
        self.cachedMembership = nil
        self.cacheGeneration += 1
        self.lock.unlock()
    }

    /// Main app: an unknown result is retried when protected data becomes available / the app becomes active.
    private func retryUnknownMembership() {
        self.lock.lock()
        var wasUnknown = false
        if let cached = self.cachedMembership, case .unknown = cached {
            wasUnknown = true
            self.cachedMembership = nil
            self.cacheGeneration += 1
        }
        if let probe = self.credentialProbe, !probe.isDefinitive {
            self.credentialProbe = nil
        }
        self.lock.unlock()
        if wasUnknown, case .known = self.membership() {
            self.postChange(.readability)
        }
    }

    // MARK: - Protected data (main app)

    /// Main app: the glue passes `UIApplication.shared.isProtectedDataAvailable` at configuration time; the
    /// store tracks it afterwards. Until then an absent credential probe is not trusted (fail closed).
    public func setProtectedDataAvailable(_ available: Bool) {
        self.lock.lock()
        self.protectedDataAvailable = available
        self.lock.unlock()
    }

    private var isProtectedDataKnownAvailable: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.protectedDataAvailable == true
    }

    /// Set once by ChatPincodeManager (main app): its current locked set, from its cache only (never a
    /// rebuild), used when migration M3 creates the snapshot.
    public var lockedIdsProvider: (() -> Set<Int64>?)? {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.lockedIdsProviderValue
        }
        set {
            self.lock.lock()
            self.lockedIdsProviderValue = newValue
            self.lock.unlock()
        }
    }

    // MARK: - Legacy readers (main app)

    /// The pre-batch-3 vault set: blob `uz.fenixuz.app.ChatLock.blob` / `__fenix_vault_peers__` (app-private),
    /// its dev fallback, and any leftover pre-v1 plaintext copy. Comma-separated Int64 values; `∅` = empty.
    public func legacyVaultIds() -> SGLegacyVaultIdsResult {
        guard !SGProtectedStore.isAppExtension else {
            return .unreadable
        }
        var ids = Set<Int64>()
        if let plaintext = UserDefaults.standard.stringArray(forKey: SGProtectedStore.legacyPlaintextVaultIdsKey) {
            ids.formUnion(plaintext.compactMap { Int64($0) })
        }
        let fallbackKey = SGProtectedStore.legacyBlobFallbackPrefix + SGProtectedStore.legacyVaultPeersAccount
        switch SGProtectedKeychain.read(service: SGProtectedStore.legacyBlobService, account: SGProtectedStore.legacyVaultPeersAccount, accessGroup: nil) {
        case let .present(data):
            ids.formUnion(SGProtectedStore.parseLegacyIds(String(data: data, encoding: .utf8) ?? ""))
            return .present(ids)
        case .absent:
            if let fallback = UserDefaults.standard.string(forKey: fallbackKey) {
                ids.formUnion(SGProtectedStore.parseLegacyIds(fallback))
                return .present(ids)
            }
            return ids.isEmpty ? .absent : .present(ids)
        case let .unreadable(status):
            if let fallback = UserDefaults.standard.string(forKey: fallbackKey) {
                ids.formUnion(SGProtectedStore.parseLegacyIds(fallback))
                return .present(ids)
            }
            if status == errSecMissingEntitlement && SGProtectedKeychain.isKeychainlessBuild {
                // Keychain-less dev build without a fallback copy: there is no legacy set.
                return ids.isEmpty ? .absent : .present(ids)
            }
            // Signed builds: -34018 is unreadable too, so M3 fails and retries instead of setting `schema = 1`
            // on top of a legacy set it could not read.
            return .unreadable
        }
    }

    static func parseLegacyIds(_ value: String) -> Set<Int64> {
        return Set(value.split(separator: ",").compactMap { Int64($0) })
    }

    /// Attributes-only probe of the vault credential (`uz.fenixuz.app.ChatLock` / `__fenix_vault__`) and its
    /// dev fallback. Absent is trusted only while protected data is known to be available.
    public func legacyVaultCredentialPresence() -> SGKeychainProbeResult {
        if UserDefaults.standard.string(forKey: SGProtectedStore.legacyPasswordFallbackPrefix + SGProtectedStore.legacyVaultCredentialAccount) != nil {
            return .present
        }
        switch SGProtectedKeychain.probe(service: SGProtectedStore.legacyCredentialService, account: SGProtectedStore.legacyVaultCredentialAccount, accessGroup: nil) {
        case .present:
            return .present
        case .absent:
            return self.isProtectedDataKnownAvailable ? .absent : .unreadable(errSecInteractionNotAllowed)
        case let .unreadable(status):
            if status == errSecMissingEntitlement && SGProtectedKeychain.isKeychainlessBuild {
                // Keychain-less dev build: there is no credential. Signed builds fail closed (non-definitive).
                return .absent
            }
            return .unreadable(status)
        }
    }

    private func probedVaultConfigured() -> Bool {
        let now = SGProtectedStore.now()
        self.lock.lock()
        if let probe = self.credentialProbe, probe.isDefinitive || now - probe.at < SGProtectedStore.unknownRetryInterval {
            self.lock.unlock()
            return probe.configured
        }
        self.lock.unlock()

        let configured: Bool
        let isDefinitive: Bool
        switch self.legacyVaultCredentialPresence() {
        case .present:
            configured = true
            isDefinitive = true
        case .absent:
            configured = false
            isDefinitive = true
        case .unreadable:
            // Unreadable counts as configured (fail closed).
            configured = true
            isDefinitive = false
        }
        self.lock.lock()
        self.credentialProbe = (configured, isDefinitive, now)
        self.lock.unlock()
        return configured
    }

    // MARK: - Writers (main app only)

    /// Applies `transform` to the current snapshot and persists the result (read-back verified). Refuses on an
    /// unreadable base; runs M3 first when the snapshot does not exist yet. No-op (no write, no revision bump)
    /// when nothing changed, except that an undecodable / newer-format item that may be rebuilt (vault off) is
    /// always rewritten, followed by a `.readability` change.
    public func mutateSnapshot(_ transform: (inout SGProtectionSnapshot) -> Void) -> Result<SGProtectionSnapshotMutation, SGProtectedStoreError> {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return .failure(.notMainApp)
        }
        self.writeLock.lock()
        var didMigrate = false
        var didRecover = false
        let result = self.mutateSnapshotLocked(transform, didMigrate: &didMigrate, didRecover: &didRecover)
        self.writeLock.unlock()

        if didMigrate {
            self.postChange(.migration)
        }
        if didRecover {
            // An undecodable / newer-format item was rebuilt: readers that failed closed can re-evaluate.
            self.postChange(.readability)
        }
        if case let .success(mutation) = result, mutation.changed {
            if mutation.before.vault != mutation.after.vault || mutation.before.unassigned != mutation.after.unassigned {
                self.postChange(.vault)
            } else {
                self.postChange(.locked)
            }
        }
        return result
    }

    private func mutateSnapshotLocked(_ transform: (inout SGProtectionSnapshot) -> Void, didMigrate: inout Bool, didRecover: inout Bool) -> Result<SGProtectionSnapshotMutation, SGProtectedStoreError> {
        let base: SGProtectionSnapshot
        var isRecovered = false
        if self.schemaVersion < 1 {
            switch self.runM3Locked() {
            case let .success(snapshot):
                base = snapshot
                didMigrate = true
            case let .failure(error):
                return .failure(error)
            }
        } else {
            switch self.writableBaseLocked() {
            case let .success(resolved):
                base = resolved.snapshot
                isRecovered = resolved.isRecovered
            case let .failure(error):
                // Never mutate on top of an unreadable base: that would overwrite the real set.
                return .failure(error)
            }
        }
        var updated = base
        transform(&updated)
        updated.normalize()
        // A recovered base is always written, even when the transform changes nothing (e.g. clearVault() on
        // an already empty vault), so the broken item is replaced by a readable v1 one.
        if updated == base && !isRecovered {
            self.storeKnown(base)
            self.recordVaultMemberCountLocked(before: base, after: base)
            return .success(SGProtectionSnapshotMutation(before: base, after: base))
        }
        if case let .failure(error) = self.writeSnapshotLocked(updated) {
            self.invalidateCache()
            return .failure(error)
        }
        self.bumpRevisionLocked()
        self.storeKnown(updated)
        self.recordVaultMemberCountLocked(before: base, after: updated)
        didRecover = isRecovered
        return .success(SGProtectionSnapshotMutation(before: base, after: updated))
    }

    /// M3: the v1 vault ids become `unassigned`; `locked` comes from ChatPincodeManager's current set (its
    /// authoritative write-through corrects it later). Written, read back and verified, then `schema = 1`.
    /// The v1 blobs are kept (rollback-safe; removed in batch 4). Caller holds `writeLock`.
    private func runM3Locked() -> Result<SGProtectionSnapshot, SGProtectedStoreError> {
        let legacyIds: Set<Int64>
        switch self.legacyVaultIds() {
        case let .present(ids):
            legacyIds = ids
        case .absent:
            legacyIds = []
        case .unreadable:
            return .failure(.unreadable)
        }
        // A snapshot written by an interrupted earlier M3 (killed before `schema` was set) is merged, not lost;
        // an undecodable / newer-format one is rebuilt only while the vault is off (writableBaseLocked).
        var snapshot: SGProtectionSnapshot
        switch self.writableBaseLocked() {
        case let .success(resolved):
            snapshot = resolved.snapshot
        case let .failure(error):
            return .failure(error)
        }
        snapshot.unassigned.formUnion(legacyIds)
        if let locked = self.lockedIdsProvider?() {
            snapshot.locked = locked
        }
        snapshot.normalize()
        if case let .failure(error) = self.writeSnapshotLocked(snapshot) {
            self.invalidateCache()
            return .failure(error)
        }
        self.defaults?.set(1, forKey: SGProtectedStore.schemaKey)
        SGSharedDefaultsMigration.markMigration(.m3Snapshot)
        self.bumpRevisionLocked()
        self.storeKnown(snapshot)
        self.recordVaultMemberCountLocked(before: snapshot, after: snapshot)
        return .success(snapshot)
    }

    /// Audit batch 4 (#70): maintains `lastKnownVaultMemberCount` for the recovery copy. Skipped while both the
    /// base and the result hold no vault member: a snapshot that reads as empty because its item is gone (a
    /// restore onto a new iPhone) must not erase how many chats the vault held. Caller holds `writeLock`.
    private func recordVaultMemberCountLocked(before: SGProtectionSnapshot, after: SGProtectionSnapshot) {
        let count = SGProtectedStore.vaultMemberCount(after)
        if count == 0 && SGProtectedStore.vaultMemberCount(before) == 0 {
            return
        }
        if self.lastKnownVaultMemberCount != count {
            self.defaults?.set(count, forKey: SGProtectedStore.vaultCountKey)
        }
    }

    /// Vault members summed over the accounts, plus the legacy unassigned ones (a chat hidden in two accounts
    /// counts twice: the copy speaks about hidden chat rows, not about distinct peers).
    private static func vaultMemberCount(_ snapshot: SGProtectionSnapshot) -> Int {
        var count = snapshot.unassigned.count
        for (_, peerIds) in snapshot.vault {
            count += peerIds.count
        }
        return count
    }

    /// The snapshot a writer may build on (caller holds `writeLock`). `isRecovered`: the item was undecodable or
    /// written by a newer build and is replaced; allowed only while the vault is off (`vaultConfigured ==
    /// false`), where only the Chat Lock set carries information, so a configured vault is never downgraded or
    /// dropped. Otherwise such an item is `.unreadable`, like a keychain read failure.
    private func writableBaseLocked() -> Result<(snapshot: SGProtectionSnapshot, isRecovered: Bool), SGProtectedStoreError> {
        switch self.snapshotState() {
        case let .known(snapshot):
            guard snapshot.isNewerFormat else {
                return .success((snapshot, false))
            }
            guard self.vaultConfiguredFlag == false else {
                return .failure(.unreadable)
            }
            return .success((SGProtectionSnapshot(vault: [:], unassigned: [], locked: snapshot.locked), true))
        case .preMigration:
            return .success((.empty, false))
        case let .corrupt(data):
            guard self.vaultConfiguredFlag == false else {
                return .failure(.unreadable)
            }
            // Best-effort copy for diagnosis (failure ignored); the locked set comes from ChatPincodeManager,
            // whose write-through keeps it authoritative afterwards.
            SGProtectedKeychain.write(data, service: SGProtectedStore.snapshotService, account: SGProtectedStore.corruptSnapshotAccount, accessGroup: SGProtectedKeychain.sharedAccessGroup)
            return .success((SGProtectionSnapshot(vault: [:], unassigned: [], locked: self.lockedIdsProvider?() ?? []), true))
        case .unknown:
            return .failure(.unreadable)
        }
    }

    private func writeSnapshotLocked(_ snapshot: SGProtectionSnapshot) -> Result<Void, SGProtectedStoreError> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return .failure(.encodingFailed)
        }
        let status = SGProtectedKeychain.write(data, service: SGProtectedStore.snapshotService, account: SGProtectedStore.snapshotAccount, accessGroup: SGProtectedKeychain.sharedAccessGroup)
        if status == errSecSuccess {
            self.defaults?.removeObject(forKey: SGProtectedStore.fallbackSnapshotKey)
        } else if status == errSecMissingEntitlement && SGProtectedKeychain.isKeychainlessBuild {
            // Keychain-less build only (fake-codesigned simulator / DEBUG): plaintext app-group fallback.
            self.defaults?.set(data, forKey: SGProtectedStore.fallbackSnapshotKey)
        } else {
            // Signed builds: -34018 is a failed write like any other (the caller invalidates the cache and M3
            // does not set `schema`); the plaintext fallback is never created.
            return .failure(.writeFailed(status))
        }
        // Read-back verification: only a value that reads back identically counts as written.
        guard case let .known(readBack) = self.snapshotState(), readBack == snapshot else {
            return .failure(.verifyFailed)
        }
        return .success(())
    }

    private func storeKnown(_ snapshot: SGProtectionSnapshot) {
        self.lock.lock()
        self.cachedMembership = .known(snapshot)
        self.cacheGeneration += 1
        self.lock.unlock()
    }

    private func bumpRevisionLocked() {
        let revision = self.revision + 1
        self.defaults?.set(revision, forKey: SGProtectedStore.revisionKey)
        notify_post(SGProtectedStore.darwinNotificationName)
    }

    /// Updates the non-secret configuration flags (nil = leave unchanged).
    public func setFlags(vaultConfigured: Bool? = nil, chatLockConfigured: Bool? = nil) {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return
        }
        var changed = false
        if let vaultConfigured, self.vaultConfiguredFlag != vaultConfigured {
            self.defaults?.set(vaultConfigured, forKey: SGProtectedStore.vaultConfiguredKey)
            changed = true
        }
        if let chatLockConfigured, self.chatLockConfiguredFlag != chatLockConfigured {
            self.defaults?.set(chatLockConfigured, forKey: SGProtectedStore.chatLockConfiguredKey)
            changed = true
        }
        if vaultConfigured != nil {
            self.lock.lock()
            self.credentialProbe = nil
            self.lock.unlock()
        }
        if changed {
            notify_post(SGProtectedStore.darwinNotificationName)
            self.postChange(.flags)
        }
    }

    // MARK: - Migrations (main app)

    public func hasMigration(_ migration: SGProtectedMigration) -> Bool {
        return SGSharedDefaultsMigration.hasMigration(migration)
    }

    public func markMigration(_ migration: SGProtectedMigration) {
        guard !SGProtectedStore.isAppExtension else {
            assertionFailure("SGProtectedStore: writers are main-app only")
            return
        }
        SGSharedDefaultsMigration.markMigration(migration)
    }

    /// M1 (keychain class, audit #30) and M3 (snapshot). Returns true when both are done, false when a step
    /// must be retried (call again on `protectedDataDidBecomeAvailable` / `didBecomeActive`). The caller runs
    /// it only while protected data is available.
    @discardableResult
    public func runMainAppMigrations() -> Bool {
        guard !SGProtectedStore.isAppExtension else {
            return true
        }
        SGSharedDefaultsMigration.runIfNeeded()
        self.lock.lock()
        let isLocked = self.protectedDataAvailable == false
        self.lock.unlock()
        if isLocked {
            return false
        }
        var isDone = true
        if !self.hasMigration(.m1KeychainClass) {
            var upgraded = true
            for service in [SGProtectedStore.legacyCredentialService, SGProtectedStore.legacyMetadataService, SGProtectedStore.legacyBlobService] {
                if !SGProtectedKeychain.upgradeAccessibility(service: service) {
                    upgraded = false
                }
            }
            if upgraded {
                self.markMigration(.m1KeychainClass)
            } else {
                isDone = false
            }
        }
        if self.schemaVersion < 1 {
            self.writeLock.lock()
            let result = self.runM3Locked()
            self.writeLock.unlock()
            switch result {
            case .success:
                self.postChange(.migration)
            case .failure:
                isDone = false
            }
        }
        return isDone
    }

    /// M4 (store part): `vault[A] ∪= unassigned \ {A}` for every account, then clears `unassigned`.
    @discardableResult
    public func assignUnassigned(toAccounts accountPeerIds: [Int64]) -> Bool {
        guard !accountPeerIds.isEmpty else {
            return false
        }
        let result = self.mutateSnapshot { snapshot in
            guard !snapshot.unassigned.isEmpty else {
                return
            }
            for accountPeerId in accountPeerIds {
                var peerIds = snapshot.vault[accountPeerId] ?? []
                peerIds.formUnion(snapshot.unassigned.subtracting([accountPeerId]))
                snapshot.vault[accountPeerId] = peerIds
            }
            snapshot.unassigned = []
        }
        switch result {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    // MARK: - Notifications

    private func postChange(_ kind: ChangeKind) {
        let post = {
            NotificationCenter.default.post(name: SGProtectedStore.didChangeNotification, object: nil, userInfo: [SGProtectedStore.changeKindKey: kind])
        }
        // Always asynchronous: writers may run inside other singletons' initializers.
        DispatchQueue.main.async(execute: post)
    }

    private static func now() -> Double {
        return ProcessInfo.processInfo.systemUptime
    }
}
