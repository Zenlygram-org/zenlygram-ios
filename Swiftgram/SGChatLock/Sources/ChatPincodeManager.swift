import Foundation
import UIKit
import Security
import CryptoKit
import LocalAuthentication
import Postbox
import SGProtectedStore

// Keychain service identifier — picks up our own bundle's namespace so
// extensions cannot accidentally read this app's pincodes.
private let keychainService = "uz.fenixuz.app.ChatLock"

// Second keychain service for per-peer metadata (password type + biometric flag).
// Kept separate so legacy password items are never accidentally corrupted.
private let metadataService = "uz.fenixuz.app.ChatLock.meta"

// Third keychain service for arbitrary secret blobs owned by sibling Fenix features
// (e.g. the Secret Vault's hidden-peer set) and for ChatLock's own record salt
// (see recordSalt()). Kept on its OWN service so the ChatLock service-wide sweep in
// disableChatLock() never touches it, and so these values are encrypted at rest
// instead of living in plaintext UserDefaults.
private let blobService = "uz.fenixuz.app.ChatLock.blob"
private let fallbackBlobKeyPrefix = "fenixuz_chatlock_fb_blob_"

// Legacy UserDefaults location — only read once at startup, then deleted.
private let legacyDefaultsKey = "chat_pincode_map"
private let legacyMigrationDoneKey = "chat_pincode_migration_done"

// Fallback store (UserDefaults) — engaged only when the keychain rejects writes in the
// current build. Fake-codesigned dev/simulator builds carry no keychain entitlements
// (no application-identifier / keychain-access-groups), so securityd fails every SecItem
// call with errSecMissingEntitlement (-34018) and the lock silently never engages.
// The credential is stored as a salted SHA-256 hash here — never plaintext.
private let fallbackSaltKey = "fenixuz_chatlock_fb_salt"
private let fallbackPasswordKeyPrefix = "fenixuz_chatlock_fb_pw_"
private let fallbackMetadataKeyPrefix = "fenixuz_chatlock_fb_meta_"

// Non-secret mirror of the locked peer ids (see the locked-peer cache below). Lets isLocked() answer
// while the keychain is unreadable (device locked) without failing open.
private let lockedIdsMirrorKey = "fenix_chatlock_locked_ids_v1"

// MARK: - Password type

/// The credential variant chosen by the user for a given chat.
public enum ChatLockPasswordType: String, Codable {
    /// Classic 4-digit numeric PIN (original behaviour).
    case pin
    /// Alphanumeric password of any length ≥ 1.
    case text
}

// MARK: - Per-peer metadata

/// Stored alongside the credential to capture user-chosen options.
public struct ChatLockMetadata: Codable {
    /// Which entry mode the user chose.
    public var passwordType: ChatLockPasswordType
    /// Whether the user opted in to biometric unlock for this chat.
    public var biometricEnabled: Bool

    public init(passwordType: ChatLockPasswordType, biometricEnabled: Bool) {
        self.passwordType = passwordType
        self.biometricEnabled = biometricEnabled
    }

    // Default for chats that were locked before this feature existed (legacy PIN).
    public static let defaultLegacy = ChatLockMetadata(passwordType: .pin, biometricEnabled: false)
}

// MARK: - Credential state

/// Zenlygram — tri-state presence of a stored credential (audit batch 3). Only `errSecItemNotFound` (while
/// protected data is available) is `.absent`; anything else that prevents an answer is `.unreadable`.
public enum SGCredentialState {
    case present
    case absent
    case unreadable
}

// MARK: - Vault credential health, checks and recovery (Zenlygram — audit batch 4)

/// Whether the vault credential can be checked at all right now (audit #27 / #41 / #70).
public enum SGVaultCredentialHealth: Equatable {
    /// A record exists and everything needed to verify it is readable.
    case ready
    /// Definitively no record (errSecItemNotFound while protected data is available).
    case absent
    /// A record exists but nothing can verify it any more (its salt is gone, or it does not decode).
    case unverifiable
    /// Cannot be answered right now (device locked, keychain error, app extension): fail closed.
    case unreadable
}

/// Outcome of one vault credential check made OUTSIDE a PIN screen (the secret-code search gate).
public enum SGVaultCheckResult: Equatable {
    case match
    case mismatch
    /// The `.vault` brute-force budget is exhausted; the candidate was NOT looked at.
    case throttled(seconds: Int)
    /// Nothing could be checked (unreadable / absent / unverifiable credential). Never counts as a failure.
    case unavailable
}

/// Which credential a biometric enrolment baseline belongs to (audit #40).
public enum SGBiometricSlot: Hashable {
    case vault
    case master
    case chat(PeerId)
}

/// Whether Face ID / Touch ID is still the enrolment this credential was protected with (audit #40).
public enum SGBiometricEnrollment: Equatable {
    case unchanged
    /// Faces / fingerprints were added or removed since: biometrics must not stand in for the PIN any more.
    case changed
    /// No biometric hardware, nothing enrolled, or biometry locked out.
    case unavailable
}

/// What the surfaces need to know about a protection that must be set up again (audit #70 / #71).
public struct SGProtectionRecoveryStatus: Equatable {
    /// Any vault-side recovery bit: the vault must not be opened, mutated or used as a secret code.
    public let vaultNeedsRecovery: Bool
    /// The set of hidden chats could not be restored either (they are visible again).
    public let vaultMembershipLost: Bool
    /// A vault record exists but cannot be verified (audit #41), so a new PIN is the only way forward.
    public let vaultUnverifiable: Bool
    public let chatLockNeedsRecovery: Bool
    /// At least one of those bits has not been shown to the user yet.
    public let hasUnacknowledged: Bool
    /// How many chats the vault held when it was last readable (0 = unknown).
    public let lastKnownVaultMemberCount: Int
    /// Chats still treated as locked although their credential is gone.
    public let pendingLockedChatCount: Int

    public init(vaultNeedsRecovery: Bool, vaultMembershipLost: Bool, vaultUnverifiable: Bool, chatLockNeedsRecovery: Bool, hasUnacknowledged: Bool, lastKnownVaultMemberCount: Int, pendingLockedChatCount: Int) {
        self.vaultNeedsRecovery = vaultNeedsRecovery
        self.vaultMembershipLost = vaultMembershipLost
        self.vaultUnverifiable = vaultUnverifiable
        self.chatLockNeedsRecovery = chatLockNeedsRecovery
        self.hasUnacknowledged = hasUnacknowledged
        self.lastKnownVaultMemberCount = lastKnownVaultMemberCount
        self.pendingLockedChatCount = pendingLockedChatCount
    }
}

// MARK: - Manager

public final class ChatPincodeManager {
    public static let shared = ChatPincodeManager()

    /// Posted on the main queue after any change of the set of locked peers.
    /// userInfo: `["added": Set<PeerId>, "removed": Set<PeerId>]`.
    public static let lockedPeersDidChangeNotification = Notification.Name("fenixChatLockLockedPeersDidChange")

    /// Zenlygram — audit batch 3: builds that may legitimately run without keychain entitlements (fake-codesigned
    /// dev / simulator builds, where every SecItem call fails with errSecMissingEntitlement, -34018). Only there
    /// is -34018 "the keychain is simply not available"; a signed release build can hit it transiently, and then
    /// it must be treated as unreadable (fail closed), never as "nothing stored", and vault data must not fall
    /// back to plaintext UserDefaults.
    #if DEBUG || targetEnvironment(simulator)
    public static let isKeychainlessBuild = true
    #else
    public static let isKeychainlessBuild = false
    #endif

    private let lock = NSLock()
    private var hasMigratedLegacy = false

    // Locked-peer cache. Guarded by its OWN lock: migrateLegacyIfNeeded() holds `lock` while it writes.
    private let lockedCacheLock = NSLock()
    private var cachedLockedIds: Set<Int64>?
    private var cachedLockedIdsAreAuthoritative = false
    private var lockedCacheGeneration = 0
    private var isProtectedDataAvailable = true
    private var lockedCacheObservers: [NSObjectProtocol] = []

    // Zenlygram — the locked set last written through to the shared snapshot by this process (nil = unknown), so
    // an unchanged set costs no keychain round trip (audit batch 3, launch cost). Guarded by `snapshotSyncLock`,
    // which serializes the write-throughs (never taken inside another lock of this manager).
    private let snapshotSyncLock = NSLock()
    private var lastSyncedLockedIds: Set<Int64>?

    // Zenlygram — audit batch 4: the vault credential's health (see `vaultCredentialHealth()`), cached so the
    // secret-code search gate can ask on every keystroke. Invalidated on every vault write, on a recovery
    // change and when protected data comes and goes; an `.unreadable` answer is only cached briefly.
    private let vaultHealthLock = NSLock()
    private var cachedVaultHealth: (value: SGVaultCredentialHealth, at: Double)?
    private static let unreadableHealthRetryInterval: Double = 2.0

    private init() {
        // Zenlygram — app extensions never touch the app-private keychain items: they answer from the shared
        // SGProtectedStore snapshot, and every writer below is a no-op there (audit batch 3).
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        // Audit batch 4 (#90): before any vault screen or the search gate can ask, so installing this build
        // never hands a user in the middle of a vault lockout a fresh budget.
        ChatLockThrottle.migrateLegacyToVaultIfNeeded()
        self.migrateLegacyIfNeeded()
        self.installLockedCacheObservers()
        // Migration M3 seeds the snapshot's locked set from this cache (never a rebuild: no re-entrancy).
        SGProtectedStore.shared.lockedIdsProvider = { [weak self] in
            return self?.lockedIdsForSnapshotMigration()
        }
    }

    // MARK: - Public credential API

    /// Returns the stored credential RECORD for a chat (nil when the chat is not
    /// locked). New-format records are a version-prefixed salted hash, so this can
    /// no longer recover the plaintext PIN — use it only as a presence check.
    public func getPincode(for peerId: PeerId) -> String? {
        return self.readPassword(account: self.account(for: peerId))
    }

    /// Store a credential together with its options.
    public func setPincode(
        _ code: String,
        for peerId: PeerId,
        type: ChatLockPasswordType = .pin,
        biometricEnabled: Bool = false
    ) {
        guard !SGProtectedStore.isAppExtension else { return }
        self.warmLockedCacheBeforeMutation()
        let key = self.account(for: peerId)
        self.writePassword(self.hashedRecord(of: code), account: key)
        self.writeMetadata(ChatLockMetadata(passwordType: type, biometricEnabled: biometricEnabled), account: key)
        if biometricEnabled {
            // Audit #40: remember which Face ID / Touch ID enrolment this credential was set with.
            self.recordBiometricBaseline(.chat(peerId))
        }
        self.updateLockedCache { $0.insert(peerId.toInt64()) }
        self.updateChatLockConfiguredFlag()
    }

    public func removePincode(for peerId: PeerId) {
        guard !SGProtectedStore.isAppExtension else { return }
        self.warmLockedCacheBeforeMutation()
        let key = self.account(for: peerId)
        self.deletePassword(account: key)
        self.deleteMetadata(account: key)
        self.deleteFallbackPassword(account: key)
        self.deleteFallbackMetadata(account: key)
        self.deleteSecureBlob(account: self.biometricDomainAccount(.chat(peerId)))
        self.updateLockedCache { $0.remove(peerId.toInt64()) }
        self.updateChatLockConfiguredFlag()
    }

    /// Zenlygram — audit batch 3: gives `target` the same Chat Lock as `source` (a basic group upgraded to a
    /// supergroup gets a new peer id, which must not open unprotected). The stored record is copied verbatim, never
    /// re-hashed: record hashes are salted per device, not per chat, so the same PIN / password unlocks both.
    /// Main app only. Returns false when `source` has no readable credential.
    @discardableResult
    public func copyLock(from source: PeerId, to target: PeerId) -> Bool {
        guard !SGProtectedStore.isAppExtension else { return false }
        self.warmLockedCacheBeforeMutation()
        let sourceKey = self.account(for: source)
        let targetKey = self.account(for: target)
        if let record = self.readPassword(account: sourceKey) {
            self.writePassword(record, account: targetKey)
        } else if let fallbackHash = self.readFallbackPasswordHash(account: sourceKey) {
            // Keychain-less build: the fallback store holds fallbackHash(record); copy that hash as is.
            UserDefaults.standard.set(fallbackHash, forKey: fallbackPasswordKeyPrefix + targetKey)
        } else {
            return false
        }
        if let metadata = self.readMetadata(account: sourceKey) {
            self.writeMetadata(metadata, account: targetKey)
        }
        self.updateLockedCache { $0.insert(target.toInt64()) }
        self.updateChatLockConfiguredFlag()
        return true
    }

    /// Whether `peerId` has a Chat Lock credential. O(1) and thread-safe (served from the locked-peer
    /// cache), so list rendering, search and notification paths can call it freely from any queue.
    /// App extensions answer from the shared snapshot; unreadable while Chat Lock is configured → locked.
    public func isLocked(_ peerId: PeerId) -> Bool {
        if SGProtectedStore.isAppExtension {
            if let ids = SGProtectedStore.shared.lockedPeerIds() {
                return ids.contains(peerId.toInt64())
            }
            return SGProtectedStore.shared.chatLockConfiguredFlag ?? false
        }
        return self.lockedIdSet().contains(peerId.toInt64())
    }

    /// Snapshot of every locked peer. Any thread.
    public func lockedPeerIds() -> Set<PeerId> {
        return Set(self.lockedIdSet().map { PeerId($0) })
    }

    public func verify(_ code: String, for peerId: PeerId) -> Bool {
        return self.verifyCredential(code, account: self.account(for: peerId))
    }

    // MARK: - Metadata API

    public func getMetadata(for peerId: PeerId) -> ChatLockMetadata {
        return self.readMetadata(account: self.account(for: peerId)) ?? .defaultLegacy
    }

    /// Update only the biometric flag without changing the stored credential.
    public func setBiometricEnabled(_ enabled: Bool, for peerId: PeerId) {
        guard !SGProtectedStore.isAppExtension else { return }
        let key = self.account(for: peerId)
        var meta = self.readMetadata(account: key) ?? .defaultLegacy
        meta.biometricEnabled = enabled
        self.writeMetadata(meta, account: key)
        if enabled {
            self.recordBiometricBaseline(.chat(peerId)) // audit #40
        }
    }

    // MARK: - Master pincode API
    //
    // The "master" is one global credential that (a) gates whether the per-chat
    // lock feature is available at all, and (b) acts as a recovery key
    // ("Forgot pincode?") to clear a single chat's lock. It reuses the same
    // keychain + salted-hash fallback plumbing as per-chat credentials, stored
    // under a reserved account key that can never collide with a numeric
    // peerId.toInt64().
    private let masterAccount = "__fenix_master__"

    /// True when a master pincode has been set (i.e. the chat-lock feature is on).
    public func isMasterEnabled() -> Bool {
        return self.readPassword(account: self.masterAccount) != nil
            || self.readFallbackPasswordHash(account: self.masterAccount) != nil
    }

    /// Store the master credential together with its options.
    public func setMasterPincode(_ code: String, type: ChatLockPasswordType = .pin, biometricEnabled: Bool = false) {
        guard !SGProtectedStore.isAppExtension else { return }
        // Audit batch 4: read BEFORE the write — a master CREATED where there was none gets a fresh
        // generation marker, so it can never pass for the master a vault PIN was set with (see the
        // "Credential generations" section). Re-writing an EXISTING master (the "PIN only" branch of the
        // enrolment-change prompt) keeps its generation, so a legitimate vault rung 2 is not lost.
        let masterExisted = self.isMasterEnabled()
        self.writePassword(self.hashedRecord(of: code), account: self.masterAccount)
        self.writeMetadata(ChatLockMetadata(passwordType: type, biometricEnabled: biometricEnabled), account: self.masterAccount)
        if !masterExisted {
            self.writeMasterGeneration()
        }
        // Audit #40: the master is the Chat Lock recovery path, so its enrolment baseline is always recorded
        // (the "Forgot pincode?" ladder asks for it even when biometric unlock itself is off).
        self.recordBiometricBaseline(.master)
        self.updateChatLockConfiguredFlag()
    }

    /// Verify a candidate against the stored master credential (constant-time).
    public func verifyMaster(_ code: String) -> Bool {
        return self.verifyCredential(code, account: self.masterAccount)
    }

    /// Master credential options (password type + biometric flag).
    public func getMasterMetadata() -> ChatLockMetadata {
        return self.readMetadata(account: self.masterAccount) ?? .defaultLegacy
    }

    /// Zenlygram — Chat Lock Center: update only the master's biometric flag without touching the stored
    /// credential or its generation marker (the vault's "Forgot" rung 2 survives). Metadata-only mirror of
    /// `setVaultBiometricEnabled(_:)` on the master account; enabling records the `.master` enrolment
    /// baseline (audit #40), so a face added later must not inherit the master's power.
    public func setMasterBiometricEnabled(_ enabled: Bool) {
        guard !SGProtectedStore.isAppExtension else { return }
        var meta = self.readMetadata(account: self.masterAccount) ?? .defaultLegacy
        meta.biometricEnabled = enabled
        self.writeMetadata(meta, account: self.masterAccount)
        if enabled {
            self.recordBiometricBaseline(.master)
        }
    }

    /// Zenlygram — Chat Lock Center: tri-state presence of the master credential (mirror of
    /// `vaultCredentialState()`). An `.unreadable` keychain must never read as "no master": a set-up offered
    /// on that answer would overwrite a real master (`setMasterPincode` decides "created" from
    /// `isMasterEnabled()`), so the Chat Lock screen shows a notice instead.
    public func masterCredentialState() -> SGCredentialState {
        return self.credentialState(account: self.masterAccount)
    }

    /// Remove only the master credential (leaves per-chat locks in place).
    public func removeMaster() {
        guard !SGProtectedStore.isAppExtension else { return }
        self.deletePassword(account: self.masterAccount)
        self.deleteMetadata(account: self.masterAccount)
        self.deleteFallbackPassword(account: self.masterAccount)
        self.deleteFallbackMetadata(account: self.masterAccount)
        self.deleteSecureBlob(account: self.biometricDomainAccount(.master))
        self.deleteMasterGeneration() // audit batch 4: the next master must not inherit this one's vault rung
        self.updateChatLockConfiguredFlag()
    }

    /// Turn the whole chat-lock feature off: wipe the master AND every per-chat
    /// credential so nothing is stranded and re-enabling later starts clean.
    public func disableChatLock() {
        guard !SGProtectedStore.isAppExtension else { return }
        self.warmLockedCacheBeforeMutation()
        // The Secret Vault credential lives under the same keychain services but a
        // separate account; it is an independent feature, so snapshot it before the
        // service-wide sweep and put it back afterwards. Turning ChatLock off must
        // never disable the vault.
        let vaultPassword = self.readPassword(account: self.vaultAccount)
        let vaultFallbackHash = vaultPassword == nil ? self.readFallbackPasswordHash(account: self.vaultAccount) : nil
        let vaultMetadata = self.readMetadata(account: self.vaultAccount)

        // Keychain: drop every item under both of our services in one sweep.
        for service in [keychainService, metadataService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
        // UserDefaults fallback: remove every per-account password/metadata key.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(fallbackPasswordKeyPrefix) || key.hasPrefix(fallbackMetadataKeyPrefix) {
            defaults.removeObject(forKey: key)
        }

        // Restore the vault credential if one existed before the sweep.
        if let vaultPassword {
            self.writePassword(vaultPassword, account: self.vaultAccount)
        } else if let vaultFallbackHash {
            UserDefaults.standard.set(vaultFallbackHash, forKey: fallbackPasswordKeyPrefix + self.vaultAccount)
        }
        if let vaultMetadata {
            self.writeMetadata(vaultMetadata, account: self.vaultAccount)
        }
        // Audit #40: the biometric baselines live under blobService, outside the sweep above. The vault keeps
        // its own (independent feature); the master's and every chat's go with the credentials they describe.
        self.deleteChatLockBiometricBaselines()
        self.deleteMasterGeneration() // audit batch 4: see removeMaster()

        // Audit batch 4 (#71): Chat Lock is gone on purpose now, so the locked-ids mirror is unfrozen BEFORE
        // the cache update below empties it (while the bit is set, mirror writes are ignored). Emptying it
        // right away also keeps a rebuild that lands in between from reading the just-swept keychain plus a
        // non-empty mirror as a fresh "credentials lost".
        SGProtectedStore.shared.clearRecovery(.chatLockCredentialLost)
        self.writeLockedIdsMirror([])
        self.updateLockedCache { $0.removeAll() }
        ChatLockThrottle.resetAll()
        self.updateChatLockConfiguredFlag()
    }

    // MARK: - Secret Vault pincode API
    //
    // The vault credential gates the hidden-chats "Secret Vault" feature. It is
    // fully independent from the master / per-chat locks (its own reserved account
    // key), but reuses the same keychain + salted-hash fallback plumbing so the
    // Secret Vault module never has to duplicate the Security-framework code.
    private let vaultAccount = "__fenix_vault__"

    /// True when a vault pincode has been set (i.e. the Secret Vault feature is on).
    public func isVaultEnabled() -> Bool {
        return self.readPassword(account: self.vaultAccount) != nil
            || self.readFallbackPasswordHash(account: self.vaultAccount) != nil
    }

    /// Store the vault credential together with its options.
    ///
    /// Zenlygram — audit #41: the record is now the SAME format as the master / per-chat ones (`sgh1$` + a hash
    /// salted with the KEYCHAIN-resident `recordSalt()`). The pre-batch-4 vault record was salted with a
    /// UserDefaults salt, which does not survive delete + reinstall while the keychain record does — the
    /// correct PIN was then rejected for good. Old records are still accepted once and re-persisted in this
    /// format (see `compareVaultCredential`).
    public func setVaultPincode(_ code: String, type: ChatLockPasswordType = .pin, biometricEnabled: Bool = false) {
        guard !SGProtectedStore.isAppExtension else { return }
        self.writePassword(self.hashedRecord(of: code), account: self.vaultAccount)
        self.writeMetadata(ChatLockMetadata(passwordType: type, biometricEnabled: biometricEnabled), account: self.vaultAccount)
        // Audit batch 4: pin down WHICH master pincode (if any) the "Forgot pincode?" ladder may accept for
        // this credential — the one that already existed at this moment, never one created afterwards.
        self.recordMasterGenerationForVault()
        // Non-secret shape hint for the secret-code search gate (audit #27): it must know whether a 4-digit
        // string can be this credential without touching the keychain on every keystroke.
        SGProtectedStore.shared.setVaultCodeShapeHint(type == .pin ? .pin4 : .text)
        // Audit #40: the vault's "Forgot" ladder needs the enrolment baseline even when biometric unlock is
        // off, so it is always recorded here.
        self.recordBiometricBaseline(.vault)
        // A new credential ends any lockout and any recovery state left by the old one.
        ChatLockThrottle.reset(.vault)
        SGProtectedStore.shared.clearRecovery(.vaultAny)
        self.invalidateVaultCredentialHealth()
        // Zenlygram — the vault is configured: the shared flag lets the extensions (and the store) know.
        SGProtectedStore.shared.setFlags(vaultConfigured: true)
        ChatLockSession.shared.noteVaultCredentialProof()
    }

    /// Verify a candidate against the stored vault credential (constant-time). Alias of
    /// `verifyVaultCredential`, kept until every caller has migrated (post-merge cleanup deletes it).
    public func verifyVault(_ code: String) -> Bool {
        return self.verifyVaultCredential(code)
    }

    /// SCREENS ONLY (`ChatPincodeViewController` does the throttle bookkeeping for its own screen; calling
    /// `checkVault` from a screen would count every wrong entry twice). False whenever the credential cannot
    /// be checked right now, so an unreadable keychain never "verifies" anything.
    public func verifyVaultCredential(_ code: String) -> Bool {
        guard self.vaultCredentialHealth() == .ready else {
            return false
        }
        let comparison = self.compareVaultCredential(code)
        guard comparison.isMatch else {
            return false
        }
        self.noteVaultCredentialSuccess(code: code, needsUpgrade: comparison.needsUpgrade)
        return true
    }

    /// The choke point for every vault check made outside a PIN screen (the secret-code search gate, audit
    /// #27). The order is load-bearing:
    /// 1. while `.vault` is locked out the candidate is not even looked at (no keychain access);
    /// 2. an unreadable / absent / unverifiable credential answers `.unavailable` and counts NO failure, so a
    ///    boot-time keychain hiccup can never lock the owner out;
    /// 3. a match clears the budget; a mismatch costs one attempt when the caller says it is a full candidate.
    public func checkVault(_ code: String, countsAsAttempt: Bool) -> SGVaultCheckResult {
        let remaining = ChatLockThrottle.remaining(.vault)
        if remaining > 0 {
            return .throttled(seconds: remaining)
        }
        guard self.vaultCredentialHealth() == .ready else {
            return .unavailable
        }
        let comparison = self.compareVaultCredential(code)
        if comparison.isMatch {
            ChatLockThrottle.reset(.vault)
            self.noteVaultCredentialSuccess(code: code, needsUpgrade: comparison.needsUpgrade)
            return .match
        }
        if countsAsAttempt {
            ChatLockThrottle.registerFailure(.vault)
        }
        return .mismatch
    }

    /// Whether the vault credential can be checked at all right now (cached; see `computeVaultCredentialHealth`).
    public func vaultCredentialHealth() -> SGVaultCredentialHealth {
        let now = ChatLockThrottle.monotonicNow()
        self.vaultHealthLock.lock()
        if let cached = self.cachedVaultHealth, cached.value != .unreadable || now - cached.at < ChatPincodeManager.unreadableHealthRetryInterval {
            self.vaultHealthLock.unlock()
            return cached.value
        }
        self.vaultHealthLock.unlock()

        let value = self.computeVaultCredentialHealth()
        self.vaultHealthLock.lock()
        self.cachedVaultHealth = (value, now)
        self.vaultHealthLock.unlock()
        return value
    }

    /// The vault credential's entry shape, for surfaces that must decide whether a string can be the
    /// credential at all. Read from the metadata when it is readable (which also refreshes the shared hint),
    /// otherwise from that hint — never inferred from `ChatLockMetadata.defaultLegacy`, which is what an
    /// unreadable item would silently look like.
    public func vaultCodeShape() -> SGVaultCodeShape {
        guard !SGProtectedStore.isAppExtension, case let .present(metadata) = self.readMetadataResult(account: self.vaultAccount) else {
            return SGProtectedStore.shared.vaultCodeShapeHint
        }
        let shape: SGVaultCodeShape = metadata.passwordType == .pin ? .pin4 : .text
        SGProtectedStore.shared.setVaultCodeShapeHint(shape)
        return shape
    }

    /// Drops the cached health after anything that can change it.
    func invalidateVaultCredentialHealth() {
        self.vaultHealthLock.lock()
        self.cachedVaultHealth = nil
        self.vaultHealthLock.unlock()
    }

    private func computeVaultCredentialHealth() -> SGVaultCredentialHealth {
        if SGProtectedStore.isAppExtension {
            return .unreadable
        }
        // Keychain-unavailable builds: the fallback store is the whole truth, salted with the UserDefaults
        // salt that shares its lifetime.
        if self.readFallbackPasswordHash(account: self.vaultAccount) != nil {
            return self.existingFallbackSalt() != nil ? .ready : .unverifiable
        }
        let record: String
        switch SGProtectedKeychain.read(service: keychainService, account: self.vaultAccount, accessGroup: nil) {
        case let .present(data):
            guard let value = String(data: data, encoding: .utf8) else {
                // Present but not a record this build can read: only a new PIN can resolve it.
                return .unverifiable
            }
            record = value
        case .absent:
            // A locked device may hide items: "absent" is trusted only while protected data is available.
            self.lockedCacheLock.lock()
            let protectedDataAvailable = self.isProtectedDataAvailable
            self.lockedCacheLock.unlock()
            return protectedDataAvailable ? .absent : .unreadable
        case let .unreadable(status):
            return status == errSecMissingEntitlement && ChatPincodeManager.isKeychainlessBuild ? .absent : .unreadable
        }
        if case .unreadable = self.readMetadataResult(account: self.vaultAccount) {
            // Without the metadata the entry UI (and the shape the gate relies on) is unknown.
            return .unreadable
        }
        if self.isHashedRecord(record) {
            switch self.recordSaltState() {
            case .present:
                return .ready
            case .absent:
                // The keychain salt that hashed this record is gone: nothing can verify it (audit #41).
                return .unverifiable
            case .unreadable:
                return .unreadable
            }
        }
        if ChatPincodeManager.isHexHash(record) {
            // Pre-batch-4 vault record: SHA-256(UserDefaults salt + code). Verifiable only while that salt is
            // still there — after delete + reinstall it is not (audit #41).
            return self.existingFallbackSalt() != nil ? .ready : .unverifiable
        }
        // Pre-hash vault: the record IS the credential.
        return .ready
    }

    /// One vault comparison: constant-time throughout, and never mints a salt.
    private struct VaultComparison {
        let isMatch: Bool
        /// The stored record is in a legacy format and must be re-persisted as `sgh1$`.
        let needsUpgrade: Bool

        static let noMatch = VaultComparison(isMatch: false, needsUpgrade: false)
    }

    private func compareVaultCredential(_ code: String) -> VaultComparison {
        if let stored = self.readPassword(account: self.vaultAccount) {
            if self.isHashedRecord(stored) {
                guard let hashed = self.hashedRecordIfSaltReadable(of: code) else {
                    return .noMatch
                }
                return VaultComparison(isMatch: constantTimeEquals(stored, hashed), needsUpgrade: false)
            }
            if ChatPincodeManager.isHexHash(stored), let legacy = self.existingFallbackHash(of: code), constantTimeEquals(stored, legacy) {
                return VaultComparison(isMatch: true, needsUpgrade: true)
            }
            if constantTimeEquals(stored, code) {
                // Pre-hash vault: accept the raw credential once, then re-persist it hashed.
                return VaultComparison(isMatch: true, needsUpgrade: true)
            }
            return .noMatch
        }
        guard let storedHash = self.readFallbackPasswordHash(account: self.vaultAccount) else {
            return .noMatch
        }
        // Keychain-unavailable builds: the fallback store holds fallbackHash(<record>).
        if let record = self.hashedRecordIfSaltReadable(of: code), let candidate = self.existingFallbackHash(of: record), constantTimeEquals(storedHash, candidate) {
            return VaultComparison(isMatch: true, needsUpgrade: false)
        }
        if let inner = self.existingFallbackHash(of: code) {
            // Pre-batch-4 fallback records: fallbackHash(fallbackHash(code)), and before that fallbackHash(code).
            if let candidate = self.existingFallbackHash(of: inner), constantTimeEquals(storedHash, candidate) {
                return VaultComparison(isMatch: true, needsUpgrade: true)
            }
            if constantTimeEquals(storedHash, inner) {
                return VaultComparison(isMatch: true, needsUpgrade: true)
            }
        }
        return .noMatch
    }

    /// After any successful vault check: upgrade a legacy record, refresh the shape hint and note the proof
    /// that gates the Settings switches for the next minute.
    private func noteVaultCredentialSuccess(code: String, needsUpgrade: Bool) {
        if needsUpgrade, let record = self.hashedRecordIfSaltReadable(of: code) {
            self.writePassword(record, account: self.vaultAccount)
            self.invalidateVaultCredentialHealth()
        }
        let _ = self.vaultCodeShape()
        ChatLockSession.shared.noteVaultCredentialProof()
    }

    /// Vault credential options (password type + biometric flag).
    public func getVaultMetadata() -> ChatLockMetadata {
        return self.readMetadata(account: self.vaultAccount) ?? .defaultLegacy
    }

    /// Update only the vault biometric flag without touching the stored credential.
    /// Mirrors setBiometricEnabled(_:for:) but targets the reserved vault account.
    public func setVaultBiometricEnabled(_ enabled: Bool) {
        guard !SGProtectedStore.isAppExtension else { return }
        var meta = self.readMetadata(account: self.vaultAccount) ?? .defaultLegacy
        meta.biometricEnabled = enabled
        self.writeMetadata(meta, account: self.vaultAccount)
        if enabled {
            self.recordBiometricBaseline(.vault) // audit #40
        }
    }

    /// One-time default: turn vault biometric unlock ON for an already-configured vault when
    /// the device supports Face ID / Touch ID, so opening hidden chats uses biometrics out of
    /// the box (PIN stays the fallback). Guarded by a flag so a later manual OFF sticks.
    public func migrateVaultBiometricDefaultIfNeeded() {
        guard !SGProtectedStore.isAppExtension else { return }
        let defaults = UserDefaults.standard
        let flagKey = "fenix_vault_biometric_default_on_v1"
        guard defaults.bool(forKey: flagKey) != true else {
            return
        }
        defaults.set(true, forKey: flagKey)
        guard self.isVaultEnabled(), ChatLockBiometricHelper.availableType() != nil else {
            return
        }
        if !self.getVaultMetadata().biometricEnabled {
            self.setVaultBiometricEnabled(true)
        }
    }

    /// Remove the vault credential (turns the Secret Vault feature off). Leaves the
    /// vaulted-peer set untouched — the caller decides whether to also clear it.
    public func removeVault() {
        guard !SGProtectedStore.isAppExtension else { return }
        self.deletePassword(account: self.vaultAccount)
        self.deleteMetadata(account: self.vaultAccount)
        self.deleteFallbackPassword(account: self.vaultAccount)
        self.deleteFallbackMetadata(account: self.vaultAccount)
        self.deleteSecureBlob(account: self.biometricDomainAccount(.vault)) // audit #40
        self.deleteSecureBlob(account: ChatPincodeManager.vaultMasterGenerationAccount) // audit batch 4
        SGProtectedStore.shared.setFlags(vaultConfigured: false)
        // Audit batch 4: the vault is gone on purpose now — no recovery is pending, no proof is live, and the
        // shape hint must not describe a credential that no longer exists.
        SGProtectedStore.shared.clearRecovery(.vaultAny)
        SGProtectedStore.shared.setVaultCodeShapeHint(.unknown)
        self.invalidateVaultCredentialHealth()
        ChatLockSession.shared.clearVaultCredentialProof()
    }

    // MARK: - Protection flags (Zenlygram — audit batch 3)

    /// Tri-state presence of the vault credential (attributes only, plus the dev fallback store).
    public func vaultCredentialState() -> SGCredentialState {
        return self.credentialState(account: self.vaultAccount)
    }

    private func credentialState(account: String) -> SGCredentialState {
        if SGProtectedStore.isAppExtension {
            return .unreadable
        }
        if self.readFallbackPasswordHash(account: account) != nil {
            return .present
        }
        switch SGProtectedKeychain.probe(service: keychainService, account: account, accessGroup: nil) {
        case .present:
            return .present
        case .absent:
            // A locked device may hide items that are not AfterFirstUnlock yet (before M1): trust "absent"
            // only while protected data is available.
            self.lockedCacheLock.lock()
            let protectedDataAvailable = self.isProtectedDataAvailable
            self.lockedCacheLock.unlock()
            return protectedDataAvailable ? .absent : .unreadable
        case let .unreadable(status):
            // Keychain-less dev builds: the fallback store (checked above) is the whole truth. A signed build can
            // see -34018 transiently: unreadable there (fail closed).
            return status == errSecMissingEntitlement && ChatPincodeManager.isKeychainlessBuild ? .absent : .unreadable
        }
    }

    /// Migration M2 (every launch while the keychain is readable): reconciles the shared
    /// `vaultConfigured` / `chatLockConfigured` flags with the credentials. A flag is written only when its
    /// answer is certain (vault: present/absent; Chat Lock: master present ∨ authoritative locked set
    /// non-empty, or master absent ∧ authoritative empty set). Returns true when both were decided.
    @discardableResult
    public func reconcileProtectionFlags() -> Bool {
        guard !SGProtectedStore.isAppExtension else {
            return true
        }
        // Launch cost (audit batch 3): once M2 has run and both flags say "not configured" there is nothing to
        // reconcile — every credential writer sets its flag (setVaultPincode; setPincode / setMasterPincode /
        // copyLock via updateChatLockConfiguredFlag), so the keychain probes below could only confirm it.
        // Audit batch 4 (#70): the fast path may only skip the work when there is no intent to protect
        // anything either — otherwise a restored device (feature on, credential gone) would never be detected.
        let store = SGProtectedStore.shared
        if store.hasMigration(.m2Flags) && store.vaultConfiguredFlag == false && store.chatLockConfiguredFlag == false
            && !store.isVaultFeatureEnabled && self.readLockedIdsMirror().isEmpty {
            return true
        }
        var isDone = true
        var vaultConfigured: Bool?
        switch self.vaultCredentialState() {
        case .present:
            vaultConfigured = true
            // Audit #41: a record that nothing can verify any more (its salt is gone) is a recovery state, not
            // an endless "Wrong code" loop.
            switch self.vaultCredentialHealth() {
            case .ready:
                store.clearRecovery(.vaultAny)
            case .unverifiable:
                if store.isVaultFeatureEnabled {
                    store.insertRecovery(.vaultCredentialUnverifiable)
                }
            case .absent, .unreadable:
                break
            }
        case .absent:
            // Audit #70: the vault PIN is a ThisDeviceOnly keychain item, so restoring onto a new iPhone
            // leaves it behind while `secretVaultEnabled` (app-group defaults, backed up) says the user still
            // wants the vault. Never write `vaultConfigured = false` there: that is the silent disable the
            // audit reports. Raise a recovery state instead and leave the flag as it is.
            if store.isVaultFeatureEnabled && !ChatPincodeManager.isKeychainlessBuild {
                var bits: SGProtectionRecovery = .vaultCredentialLost
                if store.snapshotItemIsAbsent() {
                    // The shared snapshot is gone too: the list of hidden chats cannot be restored.
                    bits.insert(.vaultMembershipLost)
                }
                store.insertRecovery(bits)
            } else {
                vaultConfigured = false
            }
        case .unreadable:
            isDone = false
        }
        self.lockedCacheLock.lock()
        let lockedIds = self.cachedLockedIdsAreAuthoritative ? self.cachedLockedIds : nil
        self.lockedCacheLock.unlock()
        var chatLockConfigured: Bool?
        let master = self.credentialState(account: self.masterAccount)
        if store.recovery.contains(.chatLockCredentialLost) {
            // Audit #71: the credentials are gone but the chats stay covered until the user decides.
            chatLockConfigured = true
        } else if case .present = master {
            chatLockConfigured = true
        } else if let lockedIds, !lockedIds.isEmpty {
            chatLockConfigured = true
        } else if case .absent = master, lockedIds != nil {
            chatLockConfigured = false
        } else {
            isDone = false
        }
        SGProtectedStore.shared.setFlags(vaultConfigured: vaultConfigured, chatLockConfigured: chatLockConfigured)
        if isDone {
            SGProtectedStore.shared.markMigration(.m2Flags)
        }
        return isDone
    }

    /// After a Chat Lock mutation (the device is unlocked: the user is acting).
    private func updateChatLockConfiguredFlag() {
        // Audit #71: chats whose credential was lost still count as configured until they are recovered or
        // Chat Lock is turned off.
        let configured = self.isMasterEnabled() || !self.lockedIdSet().isEmpty || !self.pendingRecoveryLockedIds().isEmpty
        SGProtectedStore.shared.setFlags(chatLockConfigured: configured)
    }

    // MARK: - Protection recovery (Zenlygram — audit batch 4: #70, #71, #41)

    /// What the surfaces need to show: which protection must be set up again on THIS iPhone, and how much of
    /// it is still pending. Any thread.
    public func protectionRecoveryStatus() -> SGProtectionRecoveryStatus {
        let store = SGProtectedStore.shared
        let recovery = store.recovery
        return SGProtectionRecoveryStatus(
            vaultNeedsRecovery: !recovery.intersection(.vaultAny).isEmpty,
            vaultMembershipLost: recovery.contains(.vaultMembershipLost),
            vaultUnverifiable: recovery.contains(.vaultCredentialUnverifiable),
            chatLockNeedsRecovery: recovery.contains(.chatLockCredentialLost),
            hasUnacknowledged: !store.unacknowledgedRecovery.isEmpty,
            lastKnownVaultMemberCount: store.lastKnownVaultMemberCount,
            pendingLockedChatCount: self.pendingRecoveryLockedIds().count
        )
    }

    /// The launch notice was shown: do not show it again for the bits that are set now.
    public func acknowledgeProtectionRecovery() {
        SGProtectedStore.shared.acknowledgeRecovery(SGProtectedStore.shared.recovery)
    }

    /// Clears every recovery state (logout / teardown).
    public func clearProtectionRecovery() {
        guard !SGProtectedStore.isAppExtension else { return }
        SGProtectedStore.shared.clearRecovery(.all)
        self.invalidateVaultCredentialHealth()
    }

    /// Recovery: a new vault PIN replaces the one that did not come along. The hidden-chat membership cannot
    /// be restored (the shared snapshot was device-only too), so the vault simply starts empty.
    public func resolveVaultRecovery(newCode: String, type: ChatLockPasswordType, biometricEnabled: Bool) {
        guard !SGProtectedStore.isAppExtension else { return }
        self.setVaultPincode(newCode, type: type, biometricEnabled: biometricEnabled)
        SGProtectedStore.shared.setFlags(vaultConfigured: true)
    }

    /// Recovery: ONE new PIN becomes the master credential and the credential of every chat that is still
    /// covered (per-chat PINs cannot be told apart any more — the copy says so).
    public func resolveChatLockRecovery(newCode: String, type: ChatLockPasswordType, biometricEnabled: Bool) {
        guard !SGProtectedStore.isAppExtension else { return }
        let pending = self.pendingRecoveryLockedIds()
        self.setMasterPincode(newCode, type: type, biometricEnabled: biometricEnabled)
        for id in pending.sorted() {
            self.setPincode(newCode, for: PeerId(id), type: type, biometricEnabled: biometricEnabled)
        }
        SGProtectedStore.shared.clearRecovery(.chatLockCredentialLost)
        // Unfrozen again: the rebuild writes the mirror and the shared snapshot from the keychain.
        self.rebuildLockedCache()
        self.updateChatLockConfiguredFlag()
    }

    /// Recovery: the user gives up on the lost Chat Lock credentials and turns the feature off.
    public func resolveChatLockRecoveryByTurningOff() {
        self.disableChatLock()
    }

    /// While `.chatLockCredentialLost` is set, the non-secret mirror IS the set of chats that must stay
    /// covered (it is frozen: no writer may change it until the user recovers or turns Chat Lock off).
    private func pendingRecoveryLockedIds() -> Set<Int64> {
        guard SGProtectedStore.shared.recovery.contains(.chatLockCredentialLost) else {
            return []
        }
        return self.readLockedIdsMirror()
    }

    // MARK: - Secure blob API (encrypted-at-rest storage for sibling features)
    //
    // General-purpose keychain-backed string storage so other Fenix modules (e.g.
    // SGSecretVault) can persist small secrets encrypted at rest without duplicating
    // the Security-framework plumbing. Unlike credentials these values must be read
    // back verbatim, so the keychain-unavailable dev/simulator fallback keeps the raw
    // value in UserDefaults (same as metadata) rather than a one-way hash. Stored under
    // its own keychain service, so disableChatLock()'s sweep never removes it.
    //
    // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly is used for both add and update:
    // the chat-list hide filter may read the vaulted set during a background refresh
    // while the device is locked; kSecAttrAccessibleWhenUnlocked would make it
    // unreadable then and leak vaulted chats into the refreshed list.

    /// Returns true when the value was stored (keychain, or the plaintext fallback). Zenlygram — audit batch 3:
    /// `allowPlaintextFallback: false` (the Secret Vault's peer-id blobs on signed builds) never writes the
    /// UserDefaults copy — a transient keychain failure then fails the write (false) instead of leaving the vault
    /// membership in plaintext.
    @discardableResult
    public func setSecureBlob(_ value: String, account: String, allowPlaintextFallback: Bool = true) -> Bool {
        guard !SGProtectedStore.isAppExtension else { return false }
        guard let data = value.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: blobService,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(base as CFDictionary, updateAttributes as CFDictionary) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackBlobKeyPrefix + account)
            return true
        }
        var addQuery = base
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackBlobKeyPrefix + account)
            return true
        }
        guard allowPlaintextFallback else {
            return false
        }
        // Keychain rejected the write (dev/simulator builds get -34018
        // errSecMissingEntitlement) — keep the feature working on those builds.
        UserDefaults.standard.set(value, forKey: fallbackBlobKeyPrefix + account)
        return true
    }

    public func readSecureBlob(account: String) -> String? {
        if case let .present(value) = self.readSecureBlobResult(account: account) {
            return value
        }
        return nil
    }

    /// Distinguishes a genuinely-absent keychain entry (`.absent`, errSecItemNotFound) from a
    /// transiently-unreadable one (`.unreadable`, e.g. the device is locked during a background
    /// refresh). Callers can safely cache an `.absent` result as "known empty" while retrying an
    /// `.unreadable` one, instead of treating both as nil and either re-reading the keychain on
    /// every row (absent) or caching a wrong empty set for the process lifetime (unreadable).
    public enum SecureBlobResult {
        case present(String)
        case absent
        case unreadable
    }

    public func readSecureBlobResult(account: String) -> SecureBlobResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: blobService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) {
            return .present(value)
        }
        // Fall back to the dev/simulator UserDefaults mirror before deciding absent vs unreadable.
        if let fallback = UserDefaults.standard.string(forKey: fallbackBlobKeyPrefix + account) {
            return .present(fallback)
        }
        if status == errSecItemNotFound {
            return .absent
        }
        return .unreadable
    }

    public func deleteSecureBlob(account: String) {
        guard !SGProtectedStore.isAppExtension else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: blobService,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackBlobKeyPrefix + account)
    }

    // MARK: - Biometric enrolment baselines (Zenlygram — audit #40)
    //
    // Face ID / Touch ID stands in for a credential, so a NEW enrolment (someone added their own face to this
    // iPhone) must not silently keep that power. LocalAuthentication answers this with a domain state that
    // changes whenever the biometric database does; a hash of it is stored per credential ("slot") under
    // blobService, and every biometric path compares the current state against its slot before prompting.
    //
    // The baseline is written when the credential is set, when biometrics are turned on for it, and — for
    // credentials that predate this build — once at launch (`prepareBiometricBaselinesIfNeeded`): trust on
    // first use, because nothing earlier can be compared against.

    private static let biometricDomainAccountPrefix = "__fenix_bio_domain_"
    private static let biometricBaselineMigrationKey = "fenix_bio_baseline_v1"

    private func biometricDomainAccount(_ slot: SGBiometricSlot) -> String {
        switch slot {
        case .vault:
            return ChatPincodeManager.biometricDomainAccountPrefix + "vault__"
        case .master:
            return ChatPincodeManager.biometricDomainAccountPrefix + "master__"
        case let .chat(peerId):
            return ChatPincodeManager.biometricDomainAccountPrefix + "\(peerId.toInt64())__"
        }
    }

    /// Whether Face ID / Touch ID is still the enrolment this slot was protected with. `.unchanged` is also
    /// the answer the first time a slot is asked (it records the baseline then).
    public func biometricEnrollment(for slot: SGBiometricSlot) -> SGBiometricEnrollment {
        guard let current = self.currentBiometricDomainState() else {
            return .unavailable
        }
        switch self.readSecureBlobResult(account: self.biometricDomainAccount(slot)) {
        case let .present(stored):
            return constantTimeEquals(stored, current) ? .unchanged : .changed
        case .absent:
            self.writeBiometricBaseline(current, slot: slot)
            return .unchanged
        case .unreadable:
            if ChatPincodeManager.isKeychainlessBuild {
                self.writeBiometricBaseline(current, slot: slot)
                return .unchanged
            }
            // Fail closed: without the baseline nothing says this enrolment is still the owner's.
            return .changed
        }
    }

    /// Accepts the current enrolment for `slot` (a credential was just set, biometrics were turned on, or the
    /// user chose "Keep using Face ID" after an enrolment change). No-op without usable biometrics.
    public func recordBiometricBaseline(_ slot: SGBiometricSlot) {
        guard !SGProtectedStore.isAppExtension, let current = self.currentBiometricDomainState() else {
            return
        }
        self.writeBiometricBaseline(current, slot: slot)
    }

    /// One-time (`fenix_bio_baseline_v1`) baseline for credentials created before this build. Called from the
    /// app glue after the flags reconciled, i.e. while protected data is available; retried on a later launch
    /// when the keychain could not be enumerated.
    public func prepareBiometricBaselinesIfNeeded() {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: ChatPincodeManager.biometricBaselineMigrationKey) else {
            return
        }
        guard let current = self.currentBiometricDomainState() else {
            // No usable biometrics on this device: every slot records its baseline on first use instead.
            defaults.set(true, forKey: ChatPincodeManager.biometricBaselineMigrationKey)
            return
        }
        if self.isVaultEnabled() {
            self.writeBiometricBaseline(current, slot: .vault)
        }
        if self.isMasterEnabled() {
            self.writeBiometricBaseline(current, slot: .master)
        }
        guard let peerIds = self.biometricEnabledChatPeerIds() else {
            return
        }
        for peerId in peerIds {
            self.writeBiometricBaseline(current, slot: .chat(peerId))
        }
        defaults.set(true, forKey: ChatPincodeManager.biometricBaselineMigrationKey)
    }

    private func writeBiometricBaseline(_ value: String, slot: SGBiometricSlot) {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        // Not a secret (a hash of a state hash), but a signed build still never writes it to plaintext
        // defaults — only keychain-less dev builds use the mirror.
        self.setSecureBlob(value, account: self.biometricDomainAccount(slot), allowPlaintextFallback: ChatPincodeManager.isKeychainlessBuild)
    }

    /// base64(SHA-256(biometric domain state)) from a FRESH LAContext; nil without usable biometrics (no
    /// hardware, nothing enrolled, biometry locked out) or when the state itself is unavailable (a
    /// passcode-only device), which must read as `.unavailable`, never as `.changed`.
    private func currentBiometricDomainState() -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        let state: Data?
        if #available(iOS 18.0, *) {
            state = context.domainState.biometry.stateHash
        } else {
            state = context.evaluatedPolicyDomainState
        }
        guard let state else {
            return nil
        }
        return Data(SHA256.hash(data: state)).base64EncodedString()
    }

    /// Chats whose metadata opted in to biometric unlock. One enumeration of the metadata service plus the
    /// keychain-less fallback store; nil when the keychain could not be enumerated at all.
    private func biometricEnabledChatPeerIds() -> [PeerId]? {
        var result: [PeerId] = []
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: metadataService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            for item in (items as? [[String: Any]]) ?? [] {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let id = ChatPincodeManager.lockedPeerId(fromAccount: account),
                      let data = item[kSecValueData as String] as? Data,
                      let metadata = try? JSONDecoder().decode(ChatLockMetadata.self, from: data),
                      metadata.biometricEnabled
                else {
                    continue
                }
                result.append(PeerId(id))
            }
        case errSecItemNotFound:
            break
        case errSecMissingEntitlement where ChatPincodeManager.isKeychainlessBuild:
            break
        default:
            return nil
        }
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(fallbackMetadataKeyPrefix) {
            guard let id = ChatPincodeManager.lockedPeerId(fromAccount: String(key.dropFirst(fallbackMetadataKeyPrefix.count))),
                  let data = value as? Data,
                  let metadata = try? JSONDecoder().decode(ChatLockMetadata.self, from: data),
                  metadata.biometricEnabled
            else {
                continue
            }
            result.append(PeerId(id))
        }
        return result
    }

    /// Drops the master's and every chat's baseline (the vault keeps its own: independent feature). Needed
    /// because blobService is outside `disableChatLock()`'s service-wide sweep.
    private func deleteChatLockBiometricBaselines() {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        let prefix = ChatPincodeManager.biometricDomainAccountPrefix
        let vaultAccount = self.biometricDomainAccount(.vault)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: blobService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var items: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess {
            for item in (items as? [[String: Any]]) ?? [] {
                guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix), account != vaultAccount else {
                    continue
                }
                self.deleteSecureBlob(account: account)
            }
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(fallbackBlobKeyPrefix + prefix) {
            let account = String(key.dropFirst(fallbackBlobKeyPrefix.count))
            if account != vaultAccount {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Credential generations (Zenlygram — audit batch 4: the vault recovery ladder)
    //
    // The vault's "Forgot pincode?" ladder offers the Chat Lock MASTER pincode as its second rung. That is
    // only sound while the master is a secret the user ALREADY had: Settings presents a bare "set master
    // pincode" screen with no authentication at all, so anyone holding an unlocked iPhone could otherwise
    // create a master and walk straight into the vault — which exists precisely to hide chats from someone
    // who knows the iPhone passcode.
    //
    // Every master credential therefore carries a non-secret random "generation" marker, and the vault
    // records the master generation that existed when its PIN was set. The master rung is offered only while
    // the two still match, so a master created (or re-created) afterwards never qualifies. Both values live
    // in the keychain under `blobService`, exactly like the biometric baselines: they share the credentials'
    // lifetime (surviving delete + reinstall) and `disableChatLock()`'s service sweep never touches them,
    // which is why `removeMaster()` / `disableChatLock()` delete the master's marker explicitly.

    private static let masterGenerationAccount = "__fenix_cred_gen_master__"
    private static let vaultMasterGenerationAccount = "__fenix_vault_master_gen__"
    /// Recorded with the vault credential when NO master existed at that moment — an explicit "this vault has
    /// no master rung", which reads the same as a missing or unreadable marker: refuse.
    private static let noMasterGenerationValue = "__none__"

    /// The master's current generation, minting one when a master exists but predates this scheme (it is
    /// still a pre-existing secret). Nil when there is no master, or when the marker can neither be read nor
    /// written — both of which must fail closed.
    private func currentMasterGeneration() -> String? {
        guard !SGProtectedStore.isAppExtension, self.isMasterEnabled() else {
            return nil
        }
        switch self.readSecureBlobResult(account: ChatPincodeManager.masterGenerationAccount) {
        case let .present(value):
            return value
        case .absent:
            return self.writeMasterGeneration()
        case .unreadable:
            return nil
        }
    }

    /// Writes a fresh random generation for the master. Nil when the write did not stick (the caller then
    /// treats the master as ineligible rather than assuming a value nothing can compare against).
    @discardableResult
    private func writeMasterGeneration() -> String? {
        let value = self.makeRandomSalt()
        // Not a secret, but a signed build still keeps it out of plaintext defaults (as with the baselines).
        guard self.setSecureBlob(value, account: ChatPincodeManager.masterGenerationAccount, allowPlaintextFallback: ChatPincodeManager.isKeychainlessBuild) else {
            return nil
        }
        return value
    }

    /// Records, alongside a just-written vault credential, which master (if any) may act as its rung 2. An
    /// unreadable marker is recorded as "no master": the ladder then refuses instead of trusting a value it
    /// could not verify.
    private func recordMasterGenerationForVault() {
        let value = self.currentMasterGeneration() ?? ChatPincodeManager.noMasterGenerationValue
        self.setSecureBlob(value, account: ChatPincodeManager.vaultMasterGenerationAccount, allowPlaintextFallback: ChatPincodeManager.isKeychainlessBuild)
    }

    /// Whether the vault's "Forgot pincode?" ladder may offer the Chat Lock master pincode. True only when a
    /// master exists AND it is the very master that existed when the vault PIN was set. Everything else — no
    /// master, one created afterwards, a re-created one, an unreadable marker, or a vault record from before
    /// this scheme — answers false and the screen shows the honest "cannot be recovered here" alert. Failing
    /// closed on older records loses nothing: the master rung has never shipped.
    public func vaultRecoveryAcceptsMasterPincode() -> Bool {
        guard let current = self.currentMasterGeneration() else {
            return false
        }
        guard case let .present(recorded) = self.readSecureBlobResult(account: ChatPincodeManager.vaultMasterGenerationAccount), recorded != ChatPincodeManager.noMasterGenerationValue else {
            return false
        }
        return constantTimeEquals(recorded, current)
    }

    /// Drops the master's generation marker so a master set later starts a new one (and cannot inherit the
    /// vault rung recorded for its predecessor).
    private func deleteMasterGeneration() {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        self.deleteSecureBlob(account: ChatPincodeManager.masterGenerationAccount)
    }

    // MARK: - Keychain account key

    private func account(for peerId: PeerId) -> String {
        return "\(peerId.toInt64())"
    }

    // MARK: - Hashed credential records (per-chat + master)
    //
    // Per-chat and master credentials are persisted as a salted SHA-256 hash,
    // never plaintext, so a keychain dump cannot reveal them. New records carry a
    // version prefix to make them distinguishable from legacy plaintext records;
    // any record without the prefix is treated as legacy plaintext, accepted once,
    // and transparently re-persisted in the new format.
    //
    // The salt for these records lives in the KEYCHAIN (recordSalt()), not in
    // UserDefaults like the fallback store's salt: keychain items survive app
    // deletion + reinstall on the same device while UserDefaults does not, so the
    // salt must share the records' lifetime. A UserDefaults-only salt would orphan
    // every surviving record after a reinstall — including the master credential
    // backing the "Forgot pincode?" recovery path — locking chats permanently.
    private let hashedRecordPrefix = "sgh1$"

    private func hashedRecord(of code: String) -> String {
        return self.hashedRecordPrefix + self.recordHash(of: code)
    }

    /// SHA-256 of (keychain-resident salt + code): the body of a new-format record.
    private func recordHash(of code: String) -> String {
        let payload = Data((self.recordSalt() + code).utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// Like `hashedRecord(of:)`, but nil instead of hashing with an EPHEMERAL salt while the real one is
    /// unreadable — a comparison against such a hash can only fail, and a write would orphan the record
    /// (audit batch 4).
    private func hashedRecordIfSaltReadable(of code: String) -> String? {
        guard let salt = self.recordSaltIfReadable() else {
            return nil
        }
        let payload = Data((salt + code).utf8)
        return self.hashedRecordPrefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// A record in the current format: the version prefix plus exactly 64 hex characters (SHA-256).
    private func isHashedRecord(_ record: String) -> Bool {
        guard record.hasPrefix(self.hashedRecordPrefix) else {
            return false
        }
        return ChatPincodeManager.isHexHash(String(record.dropFirst(self.hashedRecordPrefix.count)))
    }

    /// Exactly 64 hex characters: an unprefixed SHA-256 record (the pre-batch-4 vault format).
    private static func isHexHash(_ value: String) -> Bool {
        guard value.count == 64 else {
            return false
        }
        return value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    // Reserved blob account holding the record salt. It lives under blobService on
    // purpose: disableChatLock()'s sweep only clears keychainService + metadataService,
    // so wiping the feature never orphans a salt still referenced by a restored record.
    private let recordSaltAccount = "__fenix_record_salt__"
    private var cachedRecordSalt: String?
    /// Serializes the "create the salt on first use" path (never taken inside `saltLock`).
    private let saltCreationLock = NSLock()

    private func cacheRecordSalt(_ value: String) {
        self.saltLock.lock()
        self.cachedRecordSalt = value
        self.saltLock.unlock()
    }

    /// Per-device random salt for keychain-resident hashed records. Stored in the
    /// keychain (with the blob API's UserDefaults mirror on keychain-unavailable
    /// dev/simulator builds) so it survives reinstall exactly as long as the records
    /// it salts. Created lazily on first use.
    private func recordSalt() -> String {
        switch self.recordSaltState() {
        case let .present(salt):
            return salt
        case .absent:
            // Genuinely absent — first use. Generate and persist (setSecureBlob writes to
            // the keychain, or to the UserDefaults mirror when the keychain is unavailable).
            // Serialized: two threads must never persist two different salts.
            self.saltCreationLock.lock()
            defer { self.saltCreationLock.unlock() }
            if case let .present(salt) = self.recordSaltState() {
                return salt
            }
            let salt = self.makeRandomSalt()
            self.setSecureBlob(salt, account: self.recordSaltAccount)
            self.cacheRecordSalt(salt)
            return salt
        case .unreadable:
            // Transiently unreadable (e.g. before first unlock after boot): fail closed
            // with an ephemeral salt that is neither persisted nor cached, so this
            // verification merely fails instead of clobbering the real salt for good.
            return self.makeRandomSalt()
        }
    }

    /// Zenlygram — audit batch 4: `recordSalt()` without the ephemeral fallback, so a caller can tell
    /// "cannot verify right now" (nil) from "verified / did not match".
    private func recordSaltIfReadable() -> String? {
        switch self.recordSaltState() {
        case let .present(salt):
            return salt
        case .absent:
            return self.recordSalt()
        case .unreadable:
            return nil
        }
    }

    /// Tri-state read of the keychain-resident record salt (audit batch 4: the vault's health must tell a
    /// missing salt — which orphans every record it hashed — from a transiently unreadable one).
    private enum RecordSaltState {
        case present(String)
        case absent
        case unreadable
    }

    private func recordSaltState() -> RecordSaltState {
        self.saltLock.lock()
        let cached = self.cachedRecordSalt
        self.saltLock.unlock()
        if let cached {
            return .present(cached)
        }
        let cache: (String) -> RecordSaltState = { value in
            self.cacheRecordSalt(value)
            return .present(value)
        }
        // Keychain-unavailable builds (-34018 errSecMissingEntitlement) keep the salt in the blob API's
        // UserDefaults mirror — the same lifetime as the fallback credential store those builds use.
        let mirrored = UserDefaults.standard.string(forKey: fallbackBlobKeyPrefix + self.recordSaltAccount)
        switch SGProtectedKeychain.read(service: blobService, account: self.recordSaltAccount, accessGroup: nil) {
        case let .present(data):
            guard let value = String(data: data, encoding: .utf8) else {
                return .unreadable
            }
            return cache(value)
        case .absent:
            if let mirrored {
                return cache(mirrored)
            }
            return .absent
        case let .unreadable(status):
            if let mirrored {
                return cache(mirrored)
            }
            return status == errSecMissingEntitlement && ChatPincodeManager.isKeychainlessBuild ? .absent : .unreadable
        }
    }

    /// Shared verify path for per-chat and master credentials (constant-time
    /// compares throughout). NOT used by the vault, which keeps its own scheme
    /// (unprefixed hash records) for compatibility with already-stored vaults.
    private func verifyCredential(_ code: String, account: String) -> Bool {
        let hashed = self.hashedRecord(of: code)
        if let stored = self.readPassword(account: account) {
            // New-format records are exactly prefix + 64 hex chars (SHA-256). The
            // length guard keeps a contrived legacy TEXT password that merely starts
            // with the prefix on the legacy path instead of locking its owner out.
            if stored.hasPrefix(self.hashedRecordPrefix), stored.count == hashed.count {
                return constantTimeEquals(stored, hashed)
            }
            // Legacy record: the keychain still holds the plaintext credential.
            // Accept it once, then transparently re-persist in the hashed format.
            if constantTimeEquals(stored, code) {
                self.writePassword(hashed, account: account)
                return true
            }
            return false
        }
        if let storedHash = self.readFallbackPasswordHash(account: account) {
            // New-format fallback record: writePassword's keychain-unavailable path
            // stores fallbackHash(value), and the value is now the prefixed record.
            // Audit batch 4: compare through the READ-ONLY hash, so a missing salt answers "no match"
            // instead of minting one that can never match anything again.
            if let candidate = self.existingFallbackHash(of: hashed), constantTimeEquals(storedHash, candidate) {
                return true
            }
            // Legacy fallback record: fallbackHash(plaintext code). Accept it once,
            // then transparently re-persist in the new format.
            if let candidate = self.existingFallbackHash(of: code), constantTimeEquals(storedHash, candidate) {
                self.writeFallbackPassword(hashed, account: account)
                return true
            }
            return false
        }
        return false
    }

    /// Tri-state read of a credential's metadata (audit batch 4: the vault's health must tell "no metadata"
    /// from "cannot read it", which `readMetadata` collapses into `ChatLockMetadata.defaultLegacy`).
    private enum MetadataRead {
        case present(ChatLockMetadata)
        case absent
        case unreadable
    }

    private func readMetadataResult(account: String) -> MetadataRead {
        let fallback = UserDefaults.standard.data(forKey: fallbackMetadataKeyPrefix + account)
            .flatMap { try? JSONDecoder().decode(ChatLockMetadata.self, from: $0) }
        switch SGProtectedKeychain.read(service: metadataService, account: account, accessGroup: nil) {
        case let .present(data):
            if let metadata = try? JSONDecoder().decode(ChatLockMetadata.self, from: data) {
                return .present(metadata)
            }
            // Undecodable metadata is as good as none: the defaults apply, nothing is blocked by it.
            return fallback.map { MetadataRead.present($0) } ?? .absent
        case .absent:
            return fallback.map { MetadataRead.present($0) } ?? .absent
        case let .unreadable(status):
            if let fallback {
                return .present(fallback)
            }
            return status == errSecMissingEntitlement && ChatPincodeManager.isKeychainlessBuild ? .absent : .unreadable
        }
    }

    // MARK: - Password keychain plumbing

    private func basePasswordQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    private func readPassword(account: String) -> String? {
        var query = self.basePasswordQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private func writePassword(_ value: String, account: String) {
        guard !SGProtectedStore.isAppExtension else { return }
        guard let data = value.data(using: .utf8) else { return }

        let updateQuery = self.basePasswordQuery(account: account)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary) == errSecSuccess {
            self.deleteFallbackPassword(account: account)
            return
        }
        var addQuery = self.basePasswordQuery(account: account)
        addQuery[kSecValueData as String] = data
        // Zenlygram — audit #30: same class as the update path, so a first write is readable while the phone
        // is locked (background launches); existing items are moved by migration M1.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess {
            self.deleteFallbackPassword(account: account)
        } else {
            // Keychain rejected the write (dev/simulator builds get -34018
            // errSecMissingEntitlement) — persist a salted hash instead so the
            // lock still engages rather than silently failing open.
            self.writeFallbackPassword(value, account: account)
        }
    }

    private func deletePassword(account: String) {
        guard !SGProtectedStore.isAppExtension else { return }
        _ = SecItemDelete(self.basePasswordQuery(account: account) as CFDictionary)
    }

    // MARK: - Metadata keychain plumbing

    private func baseMetadataQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: metadataService,
            kSecAttrAccount as String: account
        ]
    }

    private func readMetadata(account: String) -> ChatLockMetadata? {
        var query = self.baseMetadataQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try? JSONDecoder().decode(ChatLockMetadata.self, from: data)
        }
        // Keychain miss — check the fallback store (metadata is not secret: type + flag).
        if let data = UserDefaults.standard.data(forKey: fallbackMetadataKeyPrefix + account) {
            return try? JSONDecoder().decode(ChatLockMetadata.self, from: data)
        }
        return nil
    }

    private func writeMetadata(_ metadata: ChatLockMetadata, account: String) {
        guard !SGProtectedStore.isAppExtension else { return }
        guard let data = try? JSONEncoder().encode(metadata) else { return }

        let updateQuery = self.baseMetadataQuery(account: account)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary) == errSecSuccess {
            self.deleteFallbackMetadata(account: account)
            return
        }
        var addQuery = self.baseMetadataQuery(account: account)
        addQuery[kSecValueData as String] = data
        // Zenlygram — audit #30 (see writePassword).
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess {
            self.deleteFallbackMetadata(account: account)
        } else {
            // Same keychain-unavailable case as writePassword — keep type/biometric
            // choices working on dev/simulator builds.
            UserDefaults.standard.set(data, forKey: fallbackMetadataKeyPrefix + account)
        }
    }

    private func deleteMetadata(account: String) {
        guard !SGProtectedStore.isAppExtension else { return }
        _ = SecItemDelete(self.baseMetadataQuery(account: account) as CFDictionary)
    }

    // MARK: - UserDefaults fallback (keychain-unavailable builds)

    private let saltLock = NSLock()

    /// Per-install random salt for the fallback hash. Created lazily on first use.
    /// Lives in UserDefaults on purpose — it salts only UserDefaults-resident values
    /// (the fallback store), which share its lifetime. Keychain-resident records use
    /// the keychain-resident recordSalt() instead.
    /// WRITE SIDE ONLY (`writeFallbackPassword` / `fallbackHash`): reading through this would MINT a salt and
    /// orphan every record the old one hashed. Read paths use `existingFallbackSalt()` (audit batch 4).
    private func fallbackSalt() -> String {
        self.saltLock.lock()
        defer { self.saltLock.unlock() }

        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: fallbackSaltKey) {
            return existing
        }
        let salt = self.makeRandomSalt()
        defaults.set(salt, forKey: fallbackSaltKey)
        return salt
    }

    /// The fallback salt as it is: nil when there is none, so a comparison can answer "cannot be verified"
    /// instead of silently creating a salt that matches nothing (audit #41).
    private func existingFallbackSalt() -> String? {
        return UserDefaults.standard.string(forKey: fallbackSaltKey)
    }

    private func makeRandomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: .min ... .max)
            }
        }
        return Data(bytes).base64EncodedString()
    }

    /// WRITE SIDE ONLY (it mints the salt when there is none): read paths use `existingFallbackHash(of:)`.
    private func fallbackHash(of code: String) -> String {
        let payload = Data((self.fallbackSalt() + code).utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// `fallbackHash(of:)` for comparisons: nil while the salt is gone, so nothing is minted (audit #41).
    private func existingFallbackHash(of code: String) -> String? {
        guard let salt = self.existingFallbackSalt() else {
            return nil
        }
        let payload = Data((salt + code).utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func writeFallbackPassword(_ value: String, account: String) {
        guard !SGProtectedStore.isAppExtension else { return }
        UserDefaults.standard.set(self.fallbackHash(of: value), forKey: fallbackPasswordKeyPrefix + account)
    }

    private func readFallbackPasswordHash(account: String) -> String? {
        return UserDefaults.standard.string(forKey: fallbackPasswordKeyPrefix + account)
    }

    private func deleteFallbackPassword(account: String) {
        UserDefaults.standard.removeObject(forKey: fallbackPasswordKeyPrefix + account)
    }

    private func deleteFallbackMetadata(account: String) {
        UserDefaults.standard.removeObject(forKey: fallbackMetadataKeyPrefix + account)
    }

    // MARK: - One-time legacy migration

    private func migrateLegacyIfNeeded() {
        self.lock.lock()
        defer { self.lock.unlock() }

        if self.hasMigratedLegacy { return }
        self.hasMigratedLegacy = true

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: legacyMigrationDoneKey) { return }

        // Read whatever may still be living in plaintext.
        var migratedIds = Set<Int64>()
        if let legacy = defaults.dictionary(forKey: legacyDefaultsKey) as? [String: String] {
            for (account, code) in legacy where !code.isEmpty {
                self.writePassword(self.hashedRecord(of: code), account: account)
                // Legacy entries had no metadata — write the default (PIN, no biometrics).
                self.writeMetadata(.defaultLegacy, account: account)
                if let id = ChatPincodeManager.lockedPeerId(fromAccount: account) {
                    migratedIds.insert(id)
                }
            }
        }

        defaults.removeObject(forKey: legacyDefaultsKey)
        defaults.set(true, forKey: legacyMigrationDoneKey)

        if !migratedIds.isEmpty {
            // Runs inside init (before anyone could read the cache): drop any cache so the next read
            // re-enumerates the keychain, and announce asynchronously — a synchronous post from inside
            // the `shared` initializer would re-enter it from the observers.
            self.lockedCacheLock.lock()
            self.cachedLockedIds = nil
            self.lockedCacheGeneration += 1
            self.lockedCacheLock.unlock()
            self.postLockedPeersChange(added: migratedIds, removed: [], forceAsync: true)
        }
    }

    // MARK: - Locked-peer cache (Zenlygram — Chat Lock central gate)
    //
    // isLocked() is on hot paths (chat list rows, search, storage, notifications — often off the main
    // thread), so it must not hit the keychain. The set of locked peer ids is built once from a SINGLE
    // keychain enumeration (plus the keychain-unavailable UserDefaults fallback store) and then kept in
    // sync by every mutation, which also announces the change via lockedPeersDidChangeNotification.
    //
    // Items added before audit #30 used the "when unlocked" class (migration M1 moves them to
    // AfterFirstUnlockThisDeviceOnly), so the enumeration can fail while the device is locked (e.g. a
    // background launch). Such a result is NOT authoritative: the set
    // is then answered from the last authoritative mirror ∪ the fallback store (fail closed, no false
    // positives), and rebuilt once protected data becomes available. An authoritative set is never
    // replaced by a non-authoritative one.

    /// Warms the cache. Called by ChatLockSession.configure on the main thread with the current
    /// UIApplication.isProtectedDataAvailable (which the manager cannot read off the main thread).
    public func prepareLockedPeersCache(protectedDataAvailable: Bool) {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        self.lockedCacheLock.lock()
        self.isProtectedDataAvailable = protectedDataAvailable
        let needsBuild = self.cachedLockedIds == nil || !self.cachedLockedIdsAreAuthoritative
        self.lockedCacheLock.unlock()
        if needsBuild {
            self.rebuildLockedCache()
        }
    }

    /// Mutations must see the pre-change set, otherwise a first lazy build made AFTER the keychain write
    /// would already contain the change and the difference would never be announced.
    private func warmLockedCacheBeforeMutation() {
        let _ = self.lockedIdSet()
    }

    private func lockedIdSet() -> Set<Int64> {
        if SGProtectedStore.isAppExtension {
            return SGProtectedStore.shared.lockedPeerIds() ?? []
        }
        self.lockedCacheLock.lock()
        let cached = self.cachedLockedIds
        self.lockedCacheLock.unlock()
        if let cached {
            return cached
        }
        return self.rebuildLockedCache()
    }

    @discardableResult
    private func rebuildLockedCache() -> Set<Int64> {
        self.lockedCacheLock.lock()
        let generation = self.lockedCacheGeneration
        let protectedDataAvailable = self.isProtectedDataAvailable
        self.lockedCacheLock.unlock()

        let enumeration = self.enumerateLockedKeychainAccounts(protectedDataAvailable: protectedDataAvailable)
        let keychainIsAuthoritative = enumeration.isAuthoritative
        var ids = enumeration.ids.union(self.fallbackLockedIds())
        let mirror = self.readLockedIdsMirror()

        // Zenlygram — audit #71: Chat Lock credentials are ThisDeviceOnly keychain items, so restoring onto a
        // new iPhone leaves every one of them behind. The keychain then says "nothing is locked" while the
        // non-secret mirror still names the chats the user locked — the ONLY surviving evidence, which the
        // rebuild below would overwrite on this very first launch. The check lives here (not in a launch step)
        // so no ordering between migrations, the cache warm-up and the flag reconciliation can lose it.
        let store = SGProtectedStore.shared
        var isFrozen = store.recovery.contains(.chatLockCredentialLost)
        if !isFrozen && !ChatPincodeManager.isKeychainlessBuild && enumeration.isNotFound && keychainIsAuthoritative && enumeration.ids.isEmpty && !mirror.isEmpty {
            store.insertRecovery(.chatLockCredentialLost)
            isFrozen = true
        }
        if isFrozen || !keychainIsAuthoritative {
            // While the bit is set the mirror is part of the truth until the user sets a new PIN or turns Chat
            // Lock off: those chats stay covered, their previews stay redacted and search keeps skipping them.
            // (An authoritative enumeration stays authoritative — the mirror is frozen, so it can only add.)
            ids.formUnion(mirror)
        }

        self.lockedCacheLock.lock()
        if generation != self.lockedCacheGeneration, let current = self.cachedLockedIds {
            // A mutation landed while the keychain was being read; it already holds the newer truth.
            self.lockedCacheLock.unlock()
            return current
        }
        if !keychainIsAuthoritative, self.cachedLockedIdsAreAuthoritative, let current = self.cachedLockedIds {
            // Never downgrade an authoritative set to a guess.
            self.lockedCacheLock.unlock()
            return current
        }
        let previous = self.cachedLockedIds
        self.cachedLockedIds = ids
        self.cachedLockedIdsAreAuthoritative = keychainIsAuthoritative
        self.lockedCacheGeneration += 1
        self.lockedCacheLock.unlock()

        if keychainIsAuthoritative {
            self.writeLockedIdsMirror(ids)
            // Zenlygram — the extensions read the locked set from the shared snapshot.
            self.syncLockedSnapshot(ids)
        }
        if let previous, previous != ids {
            self.postLockedPeersChange(added: ids.subtracting(previous), removed: previous.subtracting(ids), forceAsync: true)
        }
        return ids
    }

    private func rebuildLockedCacheIfNotAuthoritative() {
        self.lockedCacheLock.lock()
        let isAuthoritative = self.cachedLockedIds != nil && self.cachedLockedIdsAreAuthoritative
        self.lockedCacheLock.unlock()
        if !isAuthoritative {
            self.rebuildLockedCache()
        }
    }

    /// Applies a mutation made by this manager (set / remove / disable) to the cache and the mirror, then
    /// announces the difference. The caller has already written the keychain / fallback store.
    private func updateLockedCache(_ mutate: (inout Set<Int64>) -> Void) {
        guard !SGProtectedStore.isAppExtension else { return }
        let base = self.lockedIdSet()
        self.lockedCacheLock.lock()
        var ids = self.cachedLockedIds ?? base
        let previous = ids
        mutate(&ids)
        self.cachedLockedIds = ids
        self.lockedCacheGeneration += 1
        self.lockedCacheLock.unlock()

        self.writeLockedIdsMirror(ids)
        self.syncLockedSnapshot(ids)
        if previous != ids {
            self.postLockedPeersChange(added: ids.subtracting(previous), removed: previous.subtracting(ids), forceAsync: false)
        }
    }

    /// Zenlygram — writes the locked set through to the shared snapshot (no-op when unchanged; skipped when the
    /// snapshot is unreadable — the next authoritative rebuild retries). Never called with a lock held.
    private func syncLockedSnapshot(_ ids: Set<Int64>) {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        let store = SGProtectedStore.shared
        self.snapshotSyncLock.lock()
        defer {
            self.snapshotSyncLock.unlock()
        }
        // Launch cost (audit batch 3): mutateSnapshot always reads the keychain item, even for a no-op. Skip it when
        // this process already wrote the same set, and when Chat Lock is known unconfigured (M2 flag) with the
        // snapshot authoritative (schema ≥ 1) — the last write-through that emptied the set ran before the flag
        // went false (updateLockedCache precedes updateChatLockConfiguredFlag).
        if self.lastSyncedLockedIds == ids {
            return
        }
        if ids.isEmpty && store.chatLockConfiguredFlag == false && store.schemaVersion >= 1 {
            return
        }
        if case .success = store.mutateSnapshot({ snapshot in
            snapshot.locked = ids
        }) {
            self.lastSyncedLockedIds = ids
        }
    }

    /// Zenlygram — the current locked set for migration M3: the cache (authoritative or the fail-closed
    /// guess), else the mirror. Never rebuilds (M3 runs inside the store's write lock).
    private func lockedIdsForSnapshotMigration() -> Set<Int64>? {
        self.lockedCacheLock.lock()
        let cached = self.cachedLockedIds
        self.lockedCacheLock.unlock()
        if let cached {
            return cached
        }
        return self.readLockedIdsMirror().union(self.fallbackLockedIds())
    }

    /// One SecItemCopyMatching over the credential service (attributes only, never the secrets).
    /// `isNotFound`: the service holds no item at all — with an authoritative read and a non-empty mirror that
    /// is how a restore onto a new iPhone looks (audit #71).
    private func enumerateLockedKeychainAccounts(protectedDataAvailable: Bool) -> (ids: Set<Int64>, isAuthoritative: Bool, isNotFound: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        var ids = Set<Int64>()
        switch status {
        case errSecSuccess:
            if let items = result as? [[String: Any]] {
                for item in items {
                    if let account = item[kSecAttrAccount as String] as? String, let id = ChatPincodeManager.lockedPeerId(fromAccount: account) {
                        ids.insert(id)
                    }
                }
            }
            // While the device is locked the system may silently omit WhenUnlocked items.
            return (ids, protectedDataAvailable, false)
        case errSecItemNotFound:
            return (ids, protectedDataAvailable, true)
        case errSecMissingEntitlement:
            // Keychain-less dev/simulator builds: the UserDefaults fallback store is the whole truth. A signed build
            // can see -34018 transiently: not authoritative there (the mirror keeps the set, fail closed).
            return (ids, ChatPincodeManager.isKeychainlessBuild, false)
        default:
            // e.g. errSecInteractionNotAllowed before first unlock.
            return (ids, false, false)
        }
    }

    /// Peers locked in the keychain-unavailable fallback store (dev/simulator builds).
    private func fallbackLockedIds() -> Set<Int64> {
        var ids = Set<Int64>()
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(fallbackPasswordKeyPrefix) {
            if let id = ChatPincodeManager.lockedPeerId(fromAccount: String(key.dropFirst(fallbackPasswordKeyPrefix.count))) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Per-peer credential accounts are `"\(peerId.toInt64())"`; reserved accounts start with `__fenix_`.
    private static func lockedPeerId(fromAccount account: String) -> Int64? {
        if account.hasPrefix("__fenix_") {
            return nil
        }
        return Int64(account)
    }

    private func readLockedIdsMirror() -> Set<Int64> {
        guard let values = UserDefaults.standard.array(forKey: lockedIdsMirrorKey) else {
            return []
        }
        return Set(values.compactMap { ($0 as? NSNumber)?.int64Value })
    }

    private func writeLockedIdsMirror(_ ids: Set<Int64>) {
        guard !SGProtectedStore.isAppExtension else { return }
        // Audit #71: while the credentials are known to be lost the mirror is the only record of which chats
        // must stay covered — frozen until the user sets a new PIN (resolveChatLockRecovery) or turns Chat
        // Lock off (disableChatLock), both of which clear the bit first.
        guard !SGProtectedStore.shared.recovery.contains(.chatLockCredentialLost) else { return }
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: lockedIdsMirrorKey)
        } else {
            UserDefaults.standard.set(ids.sorted(), forKey: lockedIdsMirrorKey)
        }
    }

    private func postLockedPeersChange(added: Set<Int64>, removed: Set<Int64>, forceAsync: Bool) {
        if added.isEmpty && removed.isEmpty {
            return
        }
        let userInfo: [String: Any] = [
            "added": Set(added.map { PeerId($0) }),
            "removed": Set(removed.map { PeerId($0) })
        ]
        let post = {
            NotificationCenter.default.post(name: ChatPincodeManager.lockedPeersDidChangeNotification, object: nil, userInfo: userInfo)
        }
        if Thread.isMainThread && !forceAsync {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    private func installLockedCacheObservers() {
        let center = NotificationCenter.default
        self.lockedCacheObservers.append(center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let self else {
                return
            }
            self.lockedCacheLock.lock()
            self.isProtectedDataAvailable = false
            self.lockedCacheLock.unlock()
            // Audit batch 4: "absent" answers are only trustworthy while protected data is available.
            self.invalidateVaultCredentialHealth()
        }))
        self.lockedCacheObservers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let self else {
                return
            }
            self.lockedCacheLock.lock()
            self.isProtectedDataAvailable = true
            self.lockedCacheLock.unlock()
            self.invalidateVaultCredentialHealth()
            self.rebuildLockedCacheIfNotAuthoritative()
        }))
        self.lockedCacheObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.rebuildLockedCacheIfNotAuthoritative()
        }))
    }
}

// MARK: - Constant-time string compare

private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count {
        diff |= aBytes[i] ^ bBytes[i]
    }
    return diff == 0
}
