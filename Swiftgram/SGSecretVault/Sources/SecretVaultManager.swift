import Foundation
import Postbox
import SwiftSignalKit
import SGChatLock
import SGSimpleSettings
import SGProtectedStore
import SGCustomerSyncCore

public extension Notification.Name {
    /// Posted on the main queue whenever the Secret Vault state changes, so chat lists, the Chat Lock session
    /// and the app glue re-evaluate. userInfo:
    /// - `"accountPeerId": PeerId` — the account whose vault changed; absent for a global change (feature flag,
    ///   vault PIN set / removed, the shared state became readable, a migration).
    /// - `"added"` / `"removed"`: `Set<PeerId>` — present with `"accountPeerId"`.
    static let fenixSecretVaultChanged = Notification.Name("FenixSecretVaultChanged")
}

/// What the vault changed on a chat when it was added, so removing it (or the add's Undo) restores it.
/// `isLegacy`: recorded before batch 3, when records were not per account — unmute it only if it is still muted
/// forever. `didMute`: the vault muted it (a record may exist only for `wasArchived` / `wasPinned`). `wasArchived`:
/// the vault moved it out of the Archive (audit #8), so removing it archives it again (audit batch 3).
/// `wasPinned`: the vault unpinned it from the main list — a hidden pin would still count against Telegram's pin
/// limit and give the vault away — so removing it pins it again.
public struct SecretVaultMuteRecord: Equatable {
    public let isLegacy: Bool
    public let didMute: Bool
    public let wasArchived: Bool
    public let wasPinned: Bool

    public init(isLegacy: Bool, didMute: Bool = true, wasArchived: Bool = false, wasPinned: Bool = false) {
        self.isLegacy = isLegacy
        self.didMute = didMute
        self.wasArchived = wasArchived
        self.wasPinned = wasPinned
    }
}

/// Zenlygram — the Secret Vault membership facade (audit batch 3, design §6).
///
/// Membership is per account (audit #19 / #47 / #48): `accountPeerId` is the account's own peer id, which is
/// never vaulted in its own account (Saved Messages). The state lives in `SGProtectedStore` (shared with the
/// app extensions); the vault PIN lives in `ChatPincodeManager` (`__fenix_vault__`). Reads are thread-safe and
/// fail closed: while the shared state is unreadable `shouldHide` answers true for every peer but the account
/// itself, and mutations refuse (return false) instead of overwriting the stored set.
///
/// Side effects of a membership change (mute, unarchive, donation / notification cleanup, widget reload) are
/// applied by the app glue (TelegramUI, `sgSecretVaultConfigure`) from `.fenixSecretVaultChanged`, so this
/// module stays free of TelegramCore.
public final class SecretVaultManager {
    public static let shared = SecretVaultManager()

    public static let accountPeerIdKey = "accountPeerId"
    public static let addedKey = "added"
    public static let removedKey = "removed"

    private let store = SGProtectedStore.shared
    private let recordsLock = NSLock()
    private var storeObserver: NSObjectProtocol?

    // In-memory knowledge that spares keychain reads on every account-list emission (audit batch 3). Only this
    // process (the main app) writes the blobs, so they stay true until this manager writes again. Guarded by
    // `recordsLock`.
    /// The last read / write of the records had no "unassigned" entry (false = unknown or present).
    private var knownNoUnassignedRecords = false
    /// The pending-unmutes blob may hold an entry: nil = unknown (read once), false = known empty.
    private var pendingUnmutesMayExist: Bool?
    /// Audit #74: BOTH record blobs (v2 and the v1 legacy set) answered `.absent` on the last read, i.e. the
    /// mute bookkeeping itself is gone rather than merely empty. nil = not established yet (only
    /// `.unreadable` answers so far), false = a blob is there. See `vaultMuteBookkeepingIsLost`.
    private var knownRecordsBlobsAbsent: Bool?

    private init() {
        if !SGProtectedStore.isAppExtension {
            self.migrateFromUserDefaultsIfNeeded()
        }
        // Store-level changes that are not our own keyed mutations (flags, readability, migrations, another
        // process) are re-posted as a global vault change. Vault writes post their own keyed notification;
        // Chat Lock mirror writes are announced by ChatPincodeManager.
        self.storeObserver = NotificationCenter.default.addObserver(forName: SGProtectedStore.didChangeNotification, object: nil, queue: nil, using: { notification in
            let kind = notification.userInfo?[SGProtectedStore.changeKindKey] as? SGProtectedStore.ChangeKind
            switch kind {
            case .vault?, .locked?:
                return
            default:
                SecretVaultManager.postChange(accountPeerId: nil, added: [], removed: [])
            }
        })
    }

    // MARK: - Reads (any thread)

    /// Feature on (`secretVaultEnabled`) and a vault PIN configured.
    public var isActive: Bool {
        return self.store.isVaultActive
    }

    /// Every NON-vault surface of this account (lists, search, pickers, stories, calls…) hides the peer.
    /// Unknown membership → true; the account itself → false.
    public func shouldHide(_ peerId: PeerId, accountPeerId: PeerId) -> Bool {
        return self.store.isVaultHidden(peerId: peerId.toInt64(), accountPeerId: accountPeerId.toInt64())
    }

    /// Membership (this account's set or legacy unassigned), e.g. the vault screen's "show only" filter and the
    /// Add / Remove menu. Unknown → false; the account itself → false. Ignores the feature flag.
    public func isVaulted(_ peerId: PeerId, accountPeerId: PeerId) -> Bool {
        if peerId == accountPeerId {
            return false
        }
        guard let snapshot = self.store.currentSnapshot() else {
            return false
        }
        return snapshot.isVaulted(peerId.toInt64(), accountPeerId: accountPeerId.toInt64())
    }

    /// System-wide surfaces not tied to one account (Spotlight, CallKit, share preselection): vaulted in any
    /// account. Fail closed.
    public func shouldHideOnDevice(_ peerId: PeerId) -> Bool {
        return self.store.isVaultHiddenInAnyAccount(peerId: peerId.toInt64())
    }

    /// This account's vault members; empty while the vault is inactive or unreadable.
    public func vaultedPeerIds(accountPeerId: PeerId) -> Set<PeerId> {
        guard self.store.isVaultActive, let ids = self.store.vaultMemberIds(accountPeerId: accountPeerId.toInt64()) else {
            return Set()
        }
        return Set(ids.map { PeerId($0) })
    }

    public func count(accountPeerId: PeerId) -> Int {
        return self.vaultedPeerIds(accountPeerId: accountPeerId).count
    }

    /// Emits once on subscription (synchronously), then after every `.fenixSecretVaultChanged` (main queue).
    public func changes() -> Signal<Void, NoError> {
        return Signal { subscriber in
            subscriber.putNext(Void())
            let observer = NotificationCenter.default.addObserver(forName: .fenixSecretVaultChanged, object: nil, queue: .main, using: { _ in
                subscriber.putNext(Void())
            })
            return ActionDisposable {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    // MARK: - Mutations (main app; core-internal — surfaces use the context menu / settings)

    /// Adds peers to `accountPeerId`'s vault. The account's own peer is dropped. Returns false (and changes
    /// nothing) when there is nothing to add or the shared state is unreadable.
    @discardableResult
    public func addToVault(_ peerIds: [PeerId], accountPeerId: PeerId) -> Bool {
        guard !SGProtectedStore.isAppExtension else {
            return false
        }
        let account = accountPeerId.toInt64()
        let ids = Set(peerIds.map { $0.toInt64() }).subtracting([account])
        guard !ids.isEmpty else {
            return false
        }
        let result = self.store.mutateSnapshot { snapshot in
            var members = snapshot.vault[account] ?? []
            members.formUnion(ids)
            snapshot.vault[account] = members
        }
        guard case let .success(mutation) = result else {
            return false
        }
        let added = mutation.after.vaultMembers(accountPeerId: account).subtracting(mutation.before.vaultMembers(accountPeerId: account))
        if !added.isEmpty {
            // Audit #74: this account now has a vault member, so from here on an ABSENT records blob really
            // does mean the bookkeeping was lost, not that it was never written (a vault whose every chat was
            // already muted, never archived and never pinned writes no record at all). See
            // `vaultMuteBookkeepingIsLost`.
            self.ensureRecordsBlobExists()
            SecretVaultManager.postChange(accountPeerId: accountPeerId, added: Set(added.map { PeerId($0) }), removed: [])
            // Zenlygram — one `vault.chat_added` per chat that actually entered the vault (design 40 §10.2).
            for _ in added {
                SGAnalytics.record(.vaultChatAdded, accountPeerId: account)
            }
        }
        return true
    }

    /// Removes peers from `accountPeerId`'s vault (and from the legacy unassigned set, which migration M4 has
    /// normally emptied). Returns false when the shared state is unreadable.
    @discardableResult
    public func removeFromVault(_ peerIds: [PeerId], accountPeerId: PeerId) -> Bool {
        guard !SGProtectedStore.isAppExtension else {
            return false
        }
        let account = accountPeerId.toInt64()
        let ids = Set(peerIds.map { $0.toInt64() })
        guard !ids.isEmpty else {
            return false
        }
        let result = self.store.mutateSnapshot { snapshot in
            #if DEBUG
            if !snapshot.unassigned.isEmpty {
                assertionFailure("SecretVaultManager: legacy unassigned vault entries left (migration M4 has not run)")
            }
            #endif
            if var members = snapshot.vault[account] {
                members.subtract(ids)
                snapshot.vault[account] = members
            }
            snapshot.unassigned.subtract(ids)
        }
        guard case let .success(mutation) = result else {
            return false
        }
        let removed = mutation.before.vaultMembers(accountPeerId: account).subtracting(mutation.after.vaultMembers(accountPeerId: account))
        if !removed.isEmpty {
            SecretVaultManager.postChange(accountPeerId: accountPeerId, added: [], removed: Set(removed.map { PeerId($0) }))
            // Zenlygram — one `vault.chat_removed` per chat that actually left the vault (design 40 §10.2).
            for _ in removed {
                SGAnalytics.record(.vaultChatRemoved, accountPeerId: account)
            }
        }
        return true
    }

    /// Empties every account's vault and the mute records (turning the vault off; the caller restores the
    /// notifications first). Pending unmutes are kept.
    public func clearVault() {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        let _ = self.store.mutateSnapshot { snapshot in
            snapshot.vault = [:]
            snapshot.unassigned = []
        }
        self.recordsLock.lock()
        self.writeRecordsLocked([:])
        self.recordsLock.unlock()
        SecretVaultManager.postChange(accountPeerId: nil, added: [], removed: [])
    }

    // MARK: - Vault mute records (v2, per account, app-private keychain blob)
    //
    // The chats WE muted when they were vaulted (only those the user had not muted), so removing a chat from
    // the vault restores its notifications without clobbering the user's own mute; the chats we moved out of
    // the Archive, so removing it archives it again; and the chats we unpinned, so removing it pins it again. JSON
    // `{"<accountPeerId>": {"<peerId>": {"legacy": Bool, "muted": Bool, "archived": Bool, "pinned": Bool}}}`
    // ("muted" absent = true, "archived" / "pinned" absent = false: records written before these fields); the
    // pseudo-account "unassigned" holds the v1 (account-less) set until migration M4 moves it into the primary
    // account.

    private static let muteRecordsAccount = "__fenix_vault_muted_v2__"
    private static let legacyMutedAccount = "__fenix_vault_muted__"
    private static let pendingUnmutesAccount = "__fenix_vault_unmute_pending_v2__"
    private static let unassignedRecordsKey = "unassigned"
    private static let legacyRecordField = "legacy"
    private static let mutedRecordField = "muted"
    private static let archivedRecordField = "archived"
    private static let pinnedRecordField = "pinned"

    private typealias RawRecords = [String: [String: [String: Bool]]]

    private enum RecordsRead {
        case present(RawRecords)
        case unreadable
    }

    /// Caller holds `recordsLock`. v2 absent → converts the v1 muted set (M3, mute part) into legacy records
    /// under "unassigned" (the v1 blob is kept, rollback-safe).
    ///
    /// `.present([:])` is deliberately returned both for an empty blob and for no blob at all, because every
    /// record caller treats them alike; the difference — bookkeeping that is GONE versus bookkeeping that is
    /// simply empty — is recorded in `knownRecordsBlobsAbsent` for `vaultMuteBookkeepingIsLost` (audit #74).
    private func readRecordsLocked() -> RecordsRead {
        let manager = ChatPincodeManager.shared
        switch manager.readSecureBlobResult(account: SecretVaultManager.muteRecordsAccount) {
        case let .present(json):
            self.knownRecordsBlobsAbsent = false
            guard let data = json.data(using: .utf8), let records = try? JSONDecoder().decode(RawRecords.self, from: data) else {
                // A corrupt blob would otherwise block every later record; start over (worst case: a chat
                // stays muted after leaving the vault).
                self.knownNoUnassignedRecords = true
                return .present([:])
            }
            self.knownNoUnassignedRecords = records[SecretVaultManager.unassignedRecordsKey] == nil
            return .present(records)
        case .absent:
            switch manager.readSecureBlobResult(account: SecretVaultManager.legacyMutedAccount) {
            case let .present(blob):
                self.knownRecordsBlobsAbsent = false
                let ids = blob.split(separator: ",").compactMap { Int64($0) }
                var legacy: [String: [String: Bool]] = [:]
                for id in ids {
                    legacy["\(id)"] = [SecretVaultManager.legacyRecordField: true]
                }
                let records: RawRecords = legacy.isEmpty ? [:] : [SecretVaultManager.unassignedRecordsKey: legacy]
                if !SGProtectedStore.isAppExtension {
                    self.writeRecordsLocked(records)
                }
                self.knownNoUnassignedRecords = legacy.isEmpty
                return .present(records)
            case .absent:
                // Neither blob exists: positive evidence that the bookkeeping is gone (audit #74), which is
                // NOT the same as "this peer has no record".
                self.knownRecordsBlobsAbsent = true
                self.knownNoUnassignedRecords = true
                return .present([:])
            case .unreadable:
                // Transient (protected data unavailable): never evidence of anything, so the verdict stays
                // unestablished and every caller falls back to "not lost".
                self.knownRecordsBlobsAbsent = nil
                return .unreadable
            }
        case .unreadable:
            self.knownRecordsBlobsAbsent = nil
            return .unreadable
        }
    }

    private func writeRecordsLocked(_ records: RawRecords) {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records), let json = String(data: data, encoding: .utf8) else {
            return
        }
        // Vault peer ids never go to plaintext UserDefaults on a signed build (audit batch 3, -34018).
        if ChatPincodeManager.shared.setSecureBlob(json, account: SecretVaultManager.muteRecordsAccount, allowPlaintextFallback: ChatPincodeManager.isKeychainlessBuild) {
            // The blob exists again: the bookkeeping is by definition not lost any more (audit #74).
            self.knownRecordsBlobsAbsent = false
        }
    }

    private static func record(fields: [String: Bool], isLegacy: Bool) -> SecretVaultMuteRecord {
        return SecretVaultMuteRecord(
            isLegacy: isLegacy || (fields[SecretVaultManager.legacyRecordField] ?? false),
            didMute: fields[SecretVaultManager.mutedRecordField] ?? true,
            wasArchived: fields[SecretVaultManager.archivedRecordField] ?? false,
            wasPinned: fields[SecretVaultManager.pinnedRecordField] ?? false
        )
    }

    /// Applies `update` to the fields of `peerId` in `accountPeerId` (nil = no record yet) and writes the result.
    /// Skipped while the records are unreadable.
    private func updateRecord(_ peerId: PeerId, accountPeerId: PeerId, _ update: ([String: Bool]?) -> [String: Bool]) {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        guard case var .present(records) = self.readRecordsLocked() else {
            return
        }
        let accountKey = "\(accountPeerId.toInt64())"
        let peerKey = "\(peerId.toInt64())"
        let fields = update(records[accountKey]?[peerKey])
        records[accountKey, default: [:]][peerKey] = fields
        self.writeRecordsLocked(records)
    }

    /// Records that the vault muted `peerId` in `accountPeerId` (the glue calls it before muting): a non-legacy
    /// mute; an existing "archived" mark is kept. Skipped while the records are unreadable (the chat then simply
    /// stays muted after leaving the vault).
    public func recordVaultMuted(_ peerId: PeerId, accountPeerId: PeerId) {
        self.updateRecord(peerId, accountPeerId: accountPeerId, { fields in
            var fields = fields ?? [:]
            fields[SecretVaultManager.legacyRecordField] = false
            fields[SecretVaultManager.mutedRecordField] = true
            return fields
        })
    }

    /// Records that the vault moved `peerId` out of the Archive in `accountPeerId` (the glue calls it before
    /// unarchiving), so removing it from the vault archives it again (audit batch 3). A new record did not mute.
    public func recordVaultArchived(_ peerId: PeerId, accountPeerId: PeerId) {
        self.updateRecord(peerId, accountPeerId: accountPeerId, { fields in
            var fields = fields ?? [SecretVaultManager.legacyRecordField: false, SecretVaultManager.mutedRecordField: false]
            fields[SecretVaultManager.archivedRecordField] = true
            return fields
        })
    }

    /// Records that the vault unpinned `peerId` from the main list in `accountPeerId` (the glue calls it before
    /// unpinning): a pin hidden in the vault still counts against Telegram's pin limit, so a "limit reached" screen
    /// or an unexpected device-local extra pin (Unlimited Pinned Chats) would reveal that hidden chats exist.
    /// Removing it from the vault pins it again. A new record did not mute.
    public func recordVaultPinned(_ peerId: PeerId, accountPeerId: PeerId) {
        self.updateRecord(peerId, accountPeerId: accountPeerId, { fields in
            var fields = fields ?? [SecretVaultManager.legacyRecordField: false, SecretVaultManager.mutedRecordField: false]
            fields[SecretVaultManager.pinnedRecordField] = true
            return fields
        })
    }

    /// Removes and returns the record for `peerId` in `accountPeerId` (before migration M4, falling back to a
    /// legacy unassigned record), nil when the vault changed nothing on it or the records are unreadable.
    public func takeVaultMuteRecord(_ peerId: PeerId, accountPeerId: PeerId) -> SecretVaultMuteRecord? {
        guard !SGProtectedStore.isAppExtension else {
            return nil
        }
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        guard case var .present(records) = self.readRecordsLocked() else {
            return nil
        }
        let peerKey = "\(peerId.toInt64())"
        var accountKeys = ["\(accountPeerId.toInt64())"]
        if !self.store.hasMigration(.m4AccountAssignment) {
            // After M4 the legacy records live in the primary account; "unassigned" is gone.
            accountKeys.append(SecretVaultManager.unassignedRecordsKey)
        }
        for accountKey in accountKeys {
            guard var accountRecords = records[accountKey] else {
                continue
            }
            guard let fields = accountRecords.removeValue(forKey: peerKey) else {
                continue
            }
            records[accountKey] = accountRecords.isEmpty ? nil : accountRecords
            self.writeRecordsLocked(records)
            return SecretVaultManager.record(fields: fields, isLegacy: accountKey == SecretVaultManager.unassignedRecordsKey)
        }
        return nil
    }

    /// Every account's records of chats the vault MUTED (the Settings disable flow unmutes each one; records that
    /// only remember an unarchive / unpin are left out). The "unassigned" pseudo-account is reported by
    /// `unassignedMuteRecordPeerIds`.
    public func vaultMuteRecords() -> [PeerId: [PeerId: SecretVaultMuteRecord]] {
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        guard case let .present(records) = self.readRecordsLocked() else {
            return [:]
        }
        var result: [PeerId: [PeerId: SecretVaultMuteRecord]] = [:]
        for (accountKey, accountRecords) in records {
            guard let account = Int64(accountKey) else {
                continue
            }
            var peers: [PeerId: SecretVaultMuteRecord] = [:]
            for (peerKey, fields) in accountRecords {
                guard let peer = Int64(peerKey) else {
                    continue
                }
                let record = SecretVaultManager.record(fields: fields, isLegacy: false)
                if record.didMute {
                    peers[PeerId(peer)] = record
                }
            }
            if !peers.isEmpty {
                result[PeerId(account)] = peers
            }
        }
        return result
    }

    /// Legacy (v1) records not assigned to an account yet (before migration M4). Always legacy.
    public func unassignedMuteRecordPeerIds() -> Set<PeerId> {
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        guard case let .present(records) = self.readRecordsLocked(), let legacy = records[SecretVaultManager.unassignedRecordsKey] else {
            return Set()
        }
        return Set(legacy.keys.compactMap { Int64($0) }.map { PeerId($0) })
    }

    /// Writes an empty records blob when both record blobs are absent, so that the absence of the blob stays a
    /// meaningful signal (audit #74). Never runs while the blobs are unreadable, and never when the v1 legacy
    /// blob is there (an empty v2 blob would shadow its conversion): `knownRecordsBlobsAbsent` is only true
    /// when BOTH answered `.absent`.
    private func ensureRecordsBlobExists() {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        if self.knownRecordsBlobsAbsent == nil {
            let _ = self.readRecordsLocked()
        }
        if self.knownRecordsBlobsAbsent == true {
            self.writeRecordsLocked([:])
        }
    }

    /// Zenlygram — audit #74: positive evidence that the mute BOOKKEEPING ITSELF is gone.
    ///
    /// This is deliberately not the same question as "does this chat have a record": a vault member with no
    /// record is the NORMAL case for a chat the user had already muted when they vaulted it (the add effect
    /// records nothing then, so that leaving the vault leaves that mute alone). Only with the evidence below
    /// may a missing record be treated as a legacy one and the chat unmuted.
    ///
    /// Evidence is either a pending vault recovery (a restore onto a new iPhone left every ThisDeviceOnly
    /// keychain item behind), or both record blobs answering `.absent` while this account still has vault
    /// members — members the vault muted with records that no longer exist (`ensureRecordsBlobExists` makes
    /// sure a vault that has never written a record still has a blob, so "absent" cannot mean "never
    /// written"). `.unreadable` is NEVER evidence: the keychain is only transiently unavailable there, so this
    /// fails closed to false and nothing is unmuted. The blob verdict is cached (only this process writes the
    /// blobs), so per-peer callers do not pay a keychain read each.
    public func vaultMuteBookkeepingIsLost(accountPeerId: PeerId) -> Bool {
        if !self.store.recovery.intersection(.vaultAny).isEmpty {
            return true
        }
        guard let members = self.store.vaultMemberIds(accountPeerId: accountPeerId.toInt64()), !members.isEmpty else {
            // nil = membership unreadable (again, not evidence); empty = nothing the vault could have muted.
            return false
        }
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        if self.knownRecordsBlobsAbsent == nil {
            // Establishes the verdict as a side effect; it also performs the v1 → v2 conversion if that is
            // what the blobs hold, which is exactly the answer "the bookkeeping is still there".
            let _ = self.readRecordsLocked()
        }
        return self.knownRecordsBlobsAbsent ?? false
    }

    // MARK: - Pending unmutes (restored through an account that was not active when the vault was turned off)

    private typealias RawPending = [String: [Int64]]

    private func readPendingLocked() -> RawPending? {
        switch ChatPincodeManager.shared.readSecureBlobResult(account: SecretVaultManager.pendingUnmutesAccount) {
        case let .present(json):
            guard let data = json.data(using: .utf8), let pending = try? JSONDecoder().decode(RawPending.self, from: data) else {
                return [:]
            }
            return pending
        case .absent:
            return [:]
        case .unreadable:
            return nil
        }
    }

    @discardableResult
    private func writePendingLocked(_ pending: RawPending) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(pending), let json = String(data: data, encoding: .utf8) else {
            return false
        }
        // Vault peer ids never go to plaintext UserDefaults on a signed build (audit batch 3, -34018).
        return ChatPincodeManager.shared.setSecureBlob(json, account: SecretVaultManager.pendingUnmutesAccount, allowPlaintextFallback: ChatPincodeManager.isKeychainlessBuild)
    }

    public func addPendingUnmutes(_ peerIds: Set<PeerId>, accountPeerId: PeerId) {
        guard !SGProtectedStore.isAppExtension, !peerIds.isEmpty else {
            return
        }
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        self.pendingUnmutesMayExist = true
        guard var pending = self.readPendingLocked() else {
            return
        }
        let key = "\(accountPeerId.toInt64())"
        let merged = Set(pending[key] ?? []).union(peerIds.map { $0.toInt64() })
        pending[key] = merged.sorted()
        self.writePendingLocked(pending)
    }

    public func takePendingUnmutes(accountPeerId: PeerId) -> Set<PeerId> {
        guard !SGProtectedStore.isAppExtension else {
            return Set()
        }
        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        // Called on every account-list emission (audit batch 3): once the blob is known empty, no keychain read.
        // Only this process writes it (addPendingUnmutes marks it non-empty again).
        if self.pendingUnmutesMayExist == false {
            return Set()
        }
        guard var pending = self.readPendingLocked() else {
            // Unreadable: stays unknown, retried on the next call.
            return Set()
        }
        guard let ids = pending.removeValue(forKey: "\(accountPeerId.toInt64())") else {
            if pending.isEmpty {
                self.pendingUnmutesMayExist = false
            }
            return Set()
        }
        if self.writePendingLocked(pending) && pending.isEmpty {
            self.pendingUnmutesMayExist = false
        }
        return Set(ids.map { PeerId($0) })
    }

    // MARK: - Logout cleanup (audit #96; driven by SGAccountCleanup, main app, main queue)

    /// Forgets a logged-out account's vault: its set in the shared snapshot, its mute / unarchive / unpin records
    /// and its pending unmutes. The device-wide checks (`shouldHideOnDevice`, the extensions' `deviceProtection`:
    /// notification content, CallKit, Spotlight, share suggestions, Siri) read every account's set, so a set left
    /// behind would keep hiding those chats in the accounts that are still logged in. The account's Postbox is
    /// gone, so nothing can be restored there: if it logs in again its chats are no longer hidden, and a chat the
    /// vault muted stays muted (a server-side setting). Returns false when some state was unreadable (the next
    /// launch's reconciliation retries).
    @discardableResult
    public func forgetAccount(_ accountPeerId: PeerId) -> Bool {
        let account = accountPeerId.toInt64()
        return self.forgetAccounts(where: { $0 == account }, readRecords: true)
    }

    /// Launch reconciliation: forgets every account that is not logged in (a logout the app was killed during,
    /// or one that ran on a build without this cleanup). The app-private records are read only when the (cached)
    /// snapshot still names such an account, so a normal launch costs no extra keychain read.
    @discardableResult
    public func forgetAccounts(notIn activeAccountPeerIds: Set<PeerId>) -> Bool {
        let active = Set(activeAccountPeerIds.map { $0.toInt64() })
        let snapshotNamesOthers = self.store.currentSnapshot().map { !Set($0.vault.keys).isSubset(of: active) } ?? false
        return self.forgetAccounts(where: { !active.contains($0) }, readRecords: snapshotNamesOthers)
    }

    private func forgetAccounts(where isForgotten: (Int64) -> Bool, readRecords: Bool) -> Bool {
        guard !SGProtectedStore.isAppExtension else {
            return false
        }
        var isComplete = true

        // The shared snapshot (the legacy "unassigned" set is left to M4). Global change: the account is gone,
        // so there is nothing to unmute / re-archive, which a keyed "removed" change would try.
        if let snapshot = self.store.currentSnapshot() {
            let forgotten = Set(snapshot.vault.keys.filter(isForgotten))
            if !forgotten.isEmpty {
                let result = self.store.mutateSnapshot { updated in
                    for account in forgotten {
                        updated.vault[account] = nil
                    }
                }
                switch result {
                case let .success(mutation):
                    if mutation.changed {
                        SecretVaultManager.postChange(accountPeerId: nil, added: [], removed: [])
                    }
                case .failure:
                    isComplete = false
                }
            }
        } else {
            isComplete = false
        }

        self.recordsLock.lock()
        defer {
            self.recordsLock.unlock()
        }
        // Mute / unarchive / unpin records ("unassigned" is not an account id and stays for M4).
        if readRecords {
            if case let .present(records) = self.readRecordsLocked() {
                let kept = records.filter { key, _ in
                    return Int64(key).map { !isForgotten($0) } ?? true
                }
                if kept.count != records.count {
                    self.writeRecordsLocked(kept)
                }
            } else {
                isComplete = false
            }
        }
        // Pending unmutes (they would also cost a keychain read on every account-list emission).
        if self.pendingUnmutesMayExist != false {
            if let pending = self.readPendingLocked() {
                let kept = pending.filter { key, _ in
                    return Int64(key).map { !isForgotten($0) } ?? true
                }
                let isWritten = kept.count == pending.count || self.writePendingLocked(kept)
                if isWritten && kept.isEmpty {
                    self.pendingUnmutesMayExist = false
                }
            } else {
                isComplete = false
            }
        }
        return isComplete
    }

    /// The last account logged out (SGAccountCleanup): whoever signs in next must not inherit the vault, neither
    /// the Secret Vault switch and PIN nor the sets, records and pending unmutes. Same teardown as the Settings
    /// off switch, minus the unmutes (no account is left to restore them through).
    public func resetForNoAccounts() {
        guard !SGProtectedStore.isAppExtension else {
            return
        }
        // The PIN first: `vaultConfigured == false` also lets clearVault rebuild an undecodable snapshot.
        ChatPincodeManager.shared.removeVault()
        self.clearVault()
        self.recordsLock.lock()
        ChatPincodeManager.shared.deleteSecureBlob(account: SecretVaultManager.pendingUnmutesAccount)
        self.pendingUnmutesMayExist = false
        self.recordsLock.unlock()
        SGSimpleSettings.shared.secretVaultEnabled = false
        self.invalidateFeatureEnabledCache()
    }

    // MARK: - Migration M4 (per-account assignment of the legacy set)

    /// Legacy (account-less) vault ids or mute records that M4 has not assigned yet. Evaluated on every
    /// account-list emission, so it avoids keychain reads (audit batch 3): after M4 only the store's (cached)
    /// snapshot can hold legacy entries; before it a read that found no "unassigned" record is remembered.
    public var hasLegacyUnassignedEntries: Bool {
        if self.store.hasMigration(.m4AccountAssignment) {
            return self.store.hasUnassignedEntries
        }
        if self.store.hasUnassignedEntries {
            return true
        }
        self.recordsLock.lock()
        let knownNoUnassignedRecords = self.knownNoUnassignedRecords
        self.recordsLock.unlock()
        if knownNoUnassignedRecords {
            return false
        }
        return !self.unassignedMuteRecordPeerIds().isEmpty
    }

    /// M4: `vault[A] ∪= unassigned \ {A}` for every logged-in account, then the unassigned set is cleared. The
    /// legacy mute records move ONLY into the primary account (`legacy: true`, where it has no record): before
    /// batch 3 vaulting muted the chat only in the account that was active then, so a record elsewhere would
    /// unmute a chat the vault never muted there. Then each account gets a keyed change with its newly assigned
    /// peers, so the app glue applies the add effects there (mute where not muted — recorded —, unarchive,
    /// donation / delivered-notification cleanup); in the primary account the legacy mute is already in place and
    /// the adopted legacy record restores it on removal. Returns false to retry (no primary account yet,
    /// unreadable state).
    @discardableResult
    public func assignLegacyEntries(accountPeerIds: [PeerId], primaryAccountPeerId: PeerId?) -> Bool {
        guard !SGProtectedStore.isAppExtension, !accountPeerIds.isEmpty, let primaryAccountPeerId else {
            return false
        }
        let accounts = accountPeerIds.map { $0.toInt64() }
        self.recordsLock.lock()
        // Records first: an unreadable blob must not leave the snapshot assigned without its keyed changes.
        guard case var .present(records) = self.readRecordsLocked(), let before = self.store.currentSnapshot() else {
            self.recordsLock.unlock()
            return false
        }
        guard self.store.assignUnassigned(toAccounts: accounts), let after = self.store.currentSnapshot() else {
            self.recordsLock.unlock()
            return false
        }
        var newlyAssigned: [PeerId: Set<PeerId>] = [:]
        for account in accounts {
            let added = (after.vault[account] ?? []).subtracting(before.vault[account] ?? [])
            if !added.isEmpty {
                newlyAssigned[PeerId(account)] = Set(added.map { PeerId($0) })
            }
        }
        if let legacy = records[SecretVaultManager.unassignedRecordsKey] {
            let primaryKey = "\(primaryAccountPeerId.toInt64())"
            var primaryRecords = records[primaryKey] ?? [:]
            for (peerKey, _) in legacy where peerKey != primaryKey && primaryRecords[peerKey] == nil {
                primaryRecords[peerKey] = [SecretVaultManager.legacyRecordField: true]
            }
            if !primaryRecords.isEmpty {
                records[primaryKey] = primaryRecords
            }
            records[SecretVaultManager.unassignedRecordsKey] = nil
            self.writeRecordsLocked(records)
            self.knownNoUnassignedRecords = true
        }
        self.recordsLock.unlock()
        self.store.markMigration(.m4AccountAssignment)
        for (accountPeerId, added) in newlyAssigned {
            SecretVaultManager.postChange(accountPeerId: accountPeerId, added: added, removed: [])
        }
        SecretVaultManager.postChange(accountPeerId: nil, added: [], removed: [])
        return true
    }

    // MARK: - Global change posts

    /// Kept for the settings call sites: the vault PIN was created / removed. Posts a global change.
    public func invalidateEnabledCache() {
        SecretVaultManager.postChange(accountPeerId: nil, added: [], removed: [])
    }

    /// Kept for the settings call sites: `secretVaultEnabled` was toggled. Posts a global change (every read is
    /// uncached, so there is nothing else to invalidate).
    public func invalidateFeatureEnabledCache() {
        SecretVaultManager.postChange(accountPeerId: nil, added: [], removed: [])
    }

    static func postChange(accountPeerId: PeerId?, added: Set<PeerId>, removed: Set<PeerId>) {
        var userInfo: [String: Any]?
        if let accountPeerId {
            userInfo = [
                SecretVaultManager.accountPeerIdKey: accountPeerId,
                SecretVaultManager.addedKey: added,
                SecretVaultManager.removedKey: removed
            ]
        }
        let post = {
            NotificationCenter.default.post(name: .fenixSecretVaultChanged, object: nil, userInfo: userInfo)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    // MARK: - Pre-v1 plaintext migration (main app)

    /// One-time move of the vaulted-peer set (and the vault-muted set) out of plaintext UserDefaults, then wipe
    /// the plaintext copies so they never survive in a device backup. Before M3 they go to the v1 blobs (which
    /// M3 reads); afterwards straight into the shared snapshot / the v2 records as legacy entries.
    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let manager = ChatPincodeManager.shared

        let migratedKey = "fenix_vault_peerids_migrated_v1"
        if !defaults.bool(forKey: migratedKey) {
            let legacy = Set(SGSimpleSettings.shared.secretVaultPeerIds.compactMap { Int64($0) })
            if !legacy.isEmpty {
                if self.store.schemaVersion >= 1 {
                    let result = self.store.mutateSnapshot { snapshot in
                        snapshot.unassigned.formUnion(legacy)
                    }
                    guard case .success = result else {
                        // Unreadable right now: retried on the next launch.
                        return
                    }
                } else {
                    let v1Account = "__fenix_vault_peers__"
                    var ids = legacy
                    switch manager.readSecureBlobResult(account: v1Account) {
                    case let .present(blob):
                        ids.formUnion(blob.split(separator: ",").compactMap { Int64($0) })
                    case .absent:
                        break
                    case .unreadable:
                        return
                    }
                    // Never to plaintext on a signed build (audit batch 3, -34018); a failed write keeps the
                    // plaintext source and retries on the next launch.
                    guard manager.setSecureBlob(ids.map { String($0) }.joined(separator: ","), account: v1Account, allowPlaintextFallback: ChatPincodeManager.isKeychainlessBuild) else {
                        return
                    }
                }
            }
            SGSimpleSettings.shared.secretVaultPeerIds = []
            defaults.set(true, forKey: migratedKey)
        }

        let mutedMigratedKey = "fenix_vault_mutedids_migrated_v1"
        if !defaults.bool(forKey: mutedMigratedKey) {
            let legacyMuted = Set(SGSimpleSettings.shared.secretVaultMutedPeerIds.compactMap { Int64($0) })
            if !legacyMuted.isEmpty {
                self.recordsLock.lock()
                let read = self.readRecordsLocked()
                if case var .present(records) = read {
                    var legacy = records[SecretVaultManager.unassignedRecordsKey] ?? [:]
                    for id in legacyMuted {
                        legacy["\(id)"] = [SecretVaultManager.legacyRecordField: true]
                    }
                    records[SecretVaultManager.unassignedRecordsKey] = legacy
                    self.writeRecordsLocked(records)
                    self.knownNoUnassignedRecords = false
                }
                self.recordsLock.unlock()
                guard case .present = read else {
                    return
                }
            }
            SGSimpleSettings.shared.secretVaultMutedPeerIds = []
            defaults.set(true, forKey: mutedMigratedKey)
        }
    }
}
