// MARK: Zenlygram — call recording: removing an account's recordings (or all of them), durably.
//
// "Recordings never outlive the account that made them." That used to be one synchronous pass in
// `deleteAll(accountPeerId:)` that silently skipped every sidecar it could not read — and while the
// device is locked it can read none of them (they are `.completeUnlessOpen`, then `.complete`). A
// logout processed in the background (another device terminated the session, a VoIP push woke the
// app for a different account) therefore removed nothing, was never retried, and the recordings
// stayed listed, playable and shareable under the next account. It also skipped the LIVE recording
// outright, so a call recorded on the account being removed was finalised and kept afterwards. And a
// global wipe ("Delete All", last-account logout, Reset All) that failed part-way left no trace.
//
// THE LEDGER. Before a removal touches anything, what is being removed — an account id, the set of
// signed-in accounts for a launch reconciliation, or "everything" for a global wipe — is written to
// `account-removals.json` in the recordings directory. It holds account ids and flags only — no
// name, no path, no time — and is created `completeUntilFirstUserAuthentication`, so it can be
// written and read while the device is locked, which is exactly when it is needed. An entry is
// cleared only once the cleanup it describes is CONFIRMED: every sidecar readable and every match
// gone (or, for the live recording, durably tombstoned). Until then:
//
//   * `list()`, `item(id:)`, `readState(id:)`, `sendRecord(id:)`, `pendingSends()`, `exists(id:)` and
//     `setSendRecord` treat every recording the entry covers as gone, so no other account — and no
//     delivery — can reach it meanwhile;
//   * NO NEW RECORDING can be reserved for an account the entry covers (all accounts, for a pending
//     wipe): `canRecord(accountPeerId:)` is false and the first sidecar write is refused. That is
//     what lets an entry cover "every recording of that owner" with no timestamps at all — nothing
//     new can appear under it while it is pending, so a deferred cleanup can never delete a fresh
//     recording and a clock change can never make an old one survive;
//   * `retryPendingAccountRemovals()` finishes the job once the files can be read. It is called ONLY
//     from the explicit account lifecycle hooks, after `reconcileAccounts` recorded the current set —
//     never from `list()` or any other read, which could run before the current set is known and
//     would then act on an older reconciliation.
//
// IF THE LEDGER ITSELF CANNOT BE WRITTEN the removal is not durable and the result says so
// (`.failedToPersist`): the entry is honoured in memory for the rest of this process — hidden,
// blocking, retried — but nothing claims it will survive a relaunch; the caller must retry. A ledger
// that exists but cannot be read or decoded fails closed: every readable recording reads as
// `.unreadable` and no recording can be started until it can be read, while "Delete All" (which
// clears the ledger with everything else) stays reachable.

import Foundation
import Darwin

/// The outcome of an account removal, a reconciliation or a global wipe.
public enum SGCallRecordingAccountRemovalResult: Equatable {
    /// Every recording it covers is gone (or, if live, durably tombstoned).
    case completed
    /// Not finished — a sidecar could not be read or a file could not be removed yet, typically
    /// because the device is locked — and the pending entry IS on disk. Retry later.
    case deferred
    /// Not finished, and the pending entry could NOT be written. It is honoured for the rest of this
    /// process only; the caller must retry rather than assume it will survive a relaunch.
    case failedToPersist
}

/// What a cleanup knows about who made a recording.
enum SGCallRecordingOwnerEvidence: Equatable {
    /// The sidecar (or this process's own write) says so. nil = a version-1 sidecar with no owner.
    case owner(Int64?)
    /// Nothing decodable says so: a damaged / unknown-format sidecar, or files with no sidecar.
    case unknown
}

struct SGCallRecordingAccountLedgerContents: Codable, Equatable {
    static let currentVersion = 2

    var version: Int = SGCallRecordingAccountLedgerContents.currentVersion
    /// Accounts whose recordings (and every ownerless one) are being removed.
    var removedAccountPeerIds: [Int64] = []
    /// A launch reconciliation in progress: recordings whose owner is NOT in this set are removed.
    var signedInAccountPeerIds: [Int64]?
    /// A global wipe in progress: every recording is removed.
    var isWipePending: Bool = false

    init() {
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case removedAccountPeerIds
        case signedInAccountPeerIds
        case isWipePending
    }

    /// `version` is required, and a version newer than this build's is REFUSED (the ledger then
    /// reads as unreadable, which fails closed) rather than half-understood. Within a known version
    /// absent collections and flags mean "nothing pending of that kind".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        guard self.version <= SGCallRecordingAccountLedgerContents.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "newer ledger format")
        }
        self.removedAccountPeerIds = try container.decodeIfPresent([Int64].self, forKey: .removedAccountPeerIds) ?? []
        self.signedInAccountPeerIds = try container.decodeIfPresent([Int64].self, forKey: .signedInAccountPeerIds)
        self.isWipePending = try container.decodeIfPresent(Bool.self, forKey: .isWipePending) ?? false
    }

    var isEmpty: Bool {
        return self.removedAccountPeerIds.isEmpty && self.signedInAccountPeerIds == nil && !self.isWipePending
    }

    /// An explicit removal covers its account's recordings AND every recording it cannot
    /// attribute — an ownerless version-1 sidecar, a damaged sidecar, audio with no sidecar.
    /// Leaving an unattributable recording for whichever account is still signed in is the wrong
    /// half of the guess, and the same rule has applied to version-1 recordings all along.
    static func removalCovers(accountPeerId: Int64, owner: SGCallRecordingOwnerEvidence) -> Bool {
        switch owner {
        case .unknown, .owner(nil):
            return true
        case let .owner(value?):
            return value == accountPeerId
        }
    }

    /// Launch reconciliation is conservative: it removes only recordings whose owner is KNOWN and
    /// not signed in. An ownerless or unattributable recording is not evidence that any particular
    /// account went away, so another account's audio is never removed just because its sidecar is
    /// damaged — it stays, as a neutral Delete-only row.
    static func reconciliationCovers(signedIn: [Int64], owner: SGCallRecordingOwnerEvidence) -> Bool {
        guard case let .owner(value?) = owner else {
            return false
        }
        return !signedIn.contains(value)
    }

    func covers(owner: SGCallRecordingOwnerEvidence) -> Bool {
        if self.isWipePending {
            return true
        }
        if self.removedAccountPeerIds.contains(where: { SGCallRecordingAccountLedgerContents.removalCovers(accountPeerId: $0, owner: owner) }) {
            return true
        }
        if let signedIn = self.signedInAccountPeerIds {
            return SGCallRecordingAccountLedgerContents.reconciliationCovers(signedIn: signedIn, owner: owner)
        }
        return false
    }

    /// Whether a new recording with this owner (nil = ownerless) would fall under a pending entry.
    func blocksRecording(owner: Int64?) -> Bool {
        if self.isWipePending {
            return true
        }
        guard let accountPeerId = owner else {
            // Every explicit removal covers ownerless recordings.
            return !self.removedAccountPeerIds.isEmpty
        }
        if self.removedAccountPeerIds.contains(accountPeerId) {
            return true
        }
        if let signedIn = self.signedInAccountPeerIds, !signedIn.contains(accountPeerId) {
            return true
        }
        return false
    }

    /// `other` is the NEWER state (memory over disk): its reconciliation set wins.
    mutating func merge(_ other: SGCallRecordingAccountLedgerContents) {
        for id in other.removedAccountPeerIds where !self.removedAccountPeerIds.contains(id) {
            self.removedAccountPeerIds.append(id)
        }
        if let signedIn = other.signedInAccountPeerIds {
            self.signedInAccountPeerIds = signedIn
        }
        self.isWipePending = self.isWipePending || other.isWipePending
    }
}

/// The durable half of account removal. Thread-safe; every method is synchronous.
final class SGCallRecordingAccountLedger {
    static let fileName = "account-removals.json"

    private let lock = NSLock()
    /// What is on disk, once it has been read. nil = not read yet (or unreadable so far).
    private var persisted: SGCallRecordingAccountLedgerContents?
    /// Entries that could not be written. Honoured for this process; never claimed durable.
    private var memoryOnly = SGCallRecordingAccountLedgerContents()

    private func filePath(directory: String) -> String {
        return (directory as NSString).appendingPathComponent(SGCallRecordingAccountLedger.fileName)
    }

    /// nil when the ledger exists but cannot be read or decoded right now. Caller holds the lock.
    private func loadLocked(directory: String?) -> SGCallRecordingAccountLedgerContents? {
        if let persisted = self.persisted {
            return persisted
        }
        guard let directory = directory else {
            return nil
        }
        let path = self.filePath(directory: directory)
        guard FileManager.default.fileExists(atPath: path) else {
            let empty = SGCallRecordingAccountLedgerContents()
            self.persisted = empty
            return empty
        }
        guard let data = FileManager.default.contents(atPath: path), let decoded = try? JSONDecoder().decode(SGCallRecordingAccountLedgerContents.self, from: data) else {
            return nil
        }
        self.persisted = decoded
        return decoded
    }

    /// Atomic: written beside and renamed over, so the file is always one whole version.
    private func writeLocked(_ contents: SGCallRecordingAccountLedgerContents, directory: String) -> Bool {
        let path = self.filePath(directory: directory)
        if contents.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
            return !FileManager.default.fileExists(atPath: path)
        }
        guard let data = try? JSONEncoder().encode(contents) else {
            return false
        }
        let tempPath = path + ".tmp"
        if FileManager.default.fileExists(atPath: tempPath) {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        guard FileManager.default.createFile(atPath: tempPath, contents: data, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]) else {
            try? FileManager.default.removeItem(atPath: tempPath)
            return false
        }
        guard Darwin.rename(tempPath, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            return false
        }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }

    /// Applies a change to the on-disk ledger and returns whether it is durable. An ADDITION that
    /// cannot be written is kept in memory instead (fail closed for this process); a CLEAR always
    /// applies to memory too, and a clear that cannot be written only leaves a stale entry behind,
    /// which is harmless: its cleanup is already confirmed, so the next retry completes at once.
    private func apply(directory: String?, isAddition: Bool, _ change: (inout SGCallRecordingAccountLedgerContents) -> Void) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if !isAddition {
            change(&self.memoryOnly)
        }
        guard let directory = directory, var next = self.loadLocked(directory: directory) else {
            if isAddition {
                change(&self.memoryOnly)
            }
            return false
        }
        let current = next
        change(&next)
        if next == current {
            return true
        }
        if self.writeLocked(next, directory: directory) {
            self.persisted = next
            return true
        }
        if isAddition {
            change(&self.memoryOnly)
        }
        return false
    }

    func recordRemoval(accountPeerId: Int64, directory: String?) -> Bool {
        return self.apply(directory: directory, isAddition: true) { contents in
            if !contents.removedAccountPeerIds.contains(accountPeerId) {
                contents.removedAccountPeerIds.append(accountPeerId)
            }
        }
    }

    @discardableResult
    func clearRemoval(accountPeerId: Int64, directory: String?) -> Bool {
        return self.apply(directory: directory, isAddition: false) { contents in
            contents.removedAccountPeerIds.removeAll { $0 == accountPeerId }
        }
    }

    /// Records the CURRENT signed-in set. There is only ever one reconciliation: the newest one
    /// supersedes every earlier one, durable or memory-only, in the same locked step. Without that,
    /// a memory-only set left by an earlier failed write ([A]) would outlive a newer durable one
    /// ([A, X]) — and once that newer one completed and was cleared, the stale set would keep
    /// covering, and later delete, the recordings of the newly signed-in account X. Removal and wipe
    /// intents are untouched.
    func recordReconciliation(signedInAccountPeerIds: [Int64], directory: String?) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.memoryOnly.signedInAccountPeerIds = nil
        guard let directory = directory, var next = self.loadLocked(directory: directory) else {
            self.memoryOnly.signedInAccountPeerIds = signedInAccountPeerIds
            return false
        }
        let current = next
        next.signedInAccountPeerIds = signedInAccountPeerIds
        if next == current {
            return true
        }
        if self.writeLocked(next, directory: directory) {
            self.persisted = next
            return true
        }
        // Not durable: the memory copy is the newest and, in `effectiveLocked`, overrides the older
        // set still on disk.
        self.memoryOnly.signedInAccountPeerIds = signedInAccountPeerIds
        return false
    }

    /// Marks the reconciliation for exactly this signed-in set as completed. Returns whether the
    /// ledger on disk now holds no stale set that could cover these accounts.
    ///
    /// Not the generic `apply`: that would drop the memory copy first, and if the newest set lives
    /// only in memory ([A, X], its write failed) while an OLDER one is still on disk ([A]), the older
    /// one would take over again and cover — then delete — the newly signed-in X. So, in one locked
    /// step:
    ///
    ///   * memory holds THIS set (it is the newest): it supersedes whatever older set is on disk, so
    ///     the disk set is cleared, and only once that clear is durable is the memory copy dropped.
    ///     If the clear cannot be written, the memory copy stays and keeps overriding the stale disk
    ///     set for this process (`effectiveLocked`); it covers only accounts that really are signed
    ///     out, so keeping it is safe.
    ///   * memory holds a DIFFERENT set: that one is newer and untouched; the disk set is cleared
    ///     only if it is this one.
    ///   * memory holds none: the disk set is cleared only if it is this one.
    ///
    /// Removal and wipe intents, on disk and in memory, are never touched.
    @discardableResult
    func clearReconciliation(signedInAccountPeerIds: [Int64], directory: String?) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let memoryIsThisSet = self.memoryOnly.signedInAccountPeerIds == signedInAccountPeerIds
        guard let directory = directory, let disk = self.loadLocked(directory: directory) else {
            return false
        }
        guard let diskSet = disk.signedInAccountPeerIds else {
            if memoryIsThisSet {
                self.memoryOnly.signedInAccountPeerIds = nil
            }
            return true
        }
        guard memoryIsThisSet || diskSet == signedInAccountPeerIds else {
            // An older or newer set that is not the one completed: not ours to clear.
            return true
        }
        var next = disk
        next.signedInAccountPeerIds = nil
        guard self.writeLocked(next, directory: directory) else {
            return false
        }
        self.persisted = next
        if memoryIsThisSet {
            self.memoryOnly.signedInAccountPeerIds = nil
        }
        return true
    }

    func recordWipe(directory: String?) -> Bool {
        return self.apply(directory: directory, isAddition: true) { $0.isWipePending = true }
    }

    /// Writes every entry that so far lives only in memory into the on-disk ledger. Memory is
    /// cleared ONLY once that write succeeded; until then the entries keep failing closed in this
    /// process. Returns whether nothing is left memory-only.
    @discardableResult
    func persistPending(directory: String?) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.memoryOnly.isEmpty {
            return true
        }
        guard let directory = directory, let disk = self.loadLocked(directory: directory) else {
            return false
        }
        var next = disk
        next.merge(self.memoryOnly)
        if next != disk {
            guard self.writeLocked(next, directory: directory) else {
                return false
            }
            self.persisted = next
        }
        self.memoryOnly = SGCallRecordingAccountLedgerContents()
        return true
    }

    /// What is pending as one state: the disk ledger with the memory-only entries merged over it
    /// (a memory-only reconciliation is always the newest, see `recordReconciliation`). nil when
    /// the disk ledger cannot be read. Caller holds the lock.
    private func effectiveLocked(directory: String?) -> SGCallRecordingAccountLedgerContents? {
        guard let disk = self.loadLocked(directory: directory) else {
            return nil
        }
        var merged = disk
        merged.merge(self.memoryOnly)
        return merged
    }

    /// Whether a pending entry covers a recording with this owner. nil = the ledger cannot be read
    /// and nothing held in memory already covers it.
    func covers(owner: SGCallRecordingOwnerEvidence, directory: String?) -> Bool? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let effective = self.effectiveLocked(directory: directory) else {
            return self.memoryOnly.covers(owner: owner) ? true : nil
        }
        return effective.covers(owner: owner)
    }

    /// Whether a new recording with this owner (nil = ownerless) must be refused. nil = the ledger
    /// cannot be read and nothing held in memory already blocks it.
    func blocksRecording(owner: Int64?, directory: String?) -> Bool? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let effective = self.effectiveLocked(directory: directory) else {
            return self.memoryOnly.blocksRecording(owner: owner) ? true : nil
        }
        return effective.blocksRecording(owner: owner)
    }

    /// Everything pending: (entries, whether the disk part could be read, whether any is memory-only).
    func pending(directory: String?) -> (contents: SGCallRecordingAccountLedgerContents, isReadable: Bool, hasUnpersisted: Bool) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let disk = self.loadLocked(directory: directory)
        var merged = disk ?? SGCallRecordingAccountLedgerContents()
        merged.merge(self.memoryOnly)
        return (merged, disk != nil, !self.memoryOnly.isEmpty)
    }

    /// A global wipe CONFIRMED that nothing it covers is left: every pending entry is moot.
    func reset(directory: String?) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.memoryOnly = SGCallRecordingAccountLedgerContents()
        guard let directory = directory else {
            self.persisted = nil
            return
        }
        let path = self.filePath(directory: directory)
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        self.persisted = FileManager.default.fileExists(atPath: path) ? nil : SGCallRecordingAccountLedgerContents()
    }
}

public extension SGCallRecordingStore {
    /// The recordings an account removal of `accountPeerId` would delete (its own, plus ownerless
    /// and unattributable ones), for the caller to cancel their deliveries FIRST. nil when some
    /// sidecar cannot be opened right now — the list would be incomplete, so do not treat it as
    /// "nothing to cancel".
    func recordingIds(ownedBy accountPeerId: Int64) -> [String]? {
        var ids: [String] = []
        let complete = self.forEachRecordingOwner { id, owner in
            if SGCallRecordingAccountLedgerContents.removalCovers(accountPeerId: accountPeerId, owner: owner) {
                ids.append(id)
            }
        }
        return complete ? ids : nil
    }

    /// Whether a NEW recording may be started for this account right now. False while a removal
    /// covering the account — or a global wipe — is pending (or the ledger cannot be read), and for
    /// the rest of this process after the account was removed, until a reconciliation reports it
    /// signed in again.
    ///
    /// This is the fence that keeps cleanup and capture apart: a call object of a removed account
    /// that outlives the cleanup must not start a capture the cleanup will never see, and a
    /// re-login must not start one that a still-pending removal would then delete. `writeMetadata`
    /// enforces it for a recording's FIRST sidecar, so a session that skips the check still cannot
    /// create one; the session checks it first to fail with a reason.
    func canRecord(accountPeerId: Int64) -> Bool {
        return self.canReserve(owner: accountPeerId)
    }

    /// Removes the recordings made by one account, plus every ownerless (version-1) recording,
    /// including the live one (durably tombstoned, deleted when its session ends). Synchronous, any
    /// thread. The pending removal is written down BEFORE anything is scanned; see the file header.
    ///
    /// Does not cancel deliveries — this module cannot reach them. Cancel the ids from
    /// `recordingIds(ownedBy:)` first.
    @discardableResult
    func deleteAll(accountPeerId: Int64) -> SGCallRecordingAccountRemovalResult {
        self.fenceRecording(accountPeerId: accountPeerId)
        guard self.hasRecordingsDirectory else {
            return .completed
        }
        let durable = self.accountLedger.recordRemoval(accountPeerId: accountPeerId, directory: self.directoryPath)
        if self.removeRecordings(where: { SGCallRecordingAccountLedgerContents.removalCovers(accountPeerId: accountPeerId, owner: $0) }) {
            self.accountLedger.clearRemoval(accountPeerId: accountPeerId, directory: self.directoryPath)
            return .completed
        }
        return durable ? .deferred : .failedToPersist
    }

    /// Launch reconciliation: removes every recording whose (non-nil) owner is not signed in, and
    /// lifts the recording fence for every account in the set. Pass the FULL set of signed-in
    /// accounts, only once they are all known, and again whenever it changes. An empty set is
    /// ignored — "no account" is handled by the last-logout `deleteAll()`, and an empty set reaching
    /// here is far more likely to be "not loaded yet" than a fact. A later call replaces a pending one.
    @discardableResult
    func reconcileAccounts(signedInAccountPeerIds: Set<Int64>) -> SGCallRecordingAccountRemovalResult {
        if signedInAccountPeerIds.isEmpty {
            return .completed
        }
        self.unfenceRecording(signedInAccountPeerIds: signedInAccountPeerIds)
        guard self.hasRecordingsDirectory else {
            return .completed
        }
        let signedIn = signedInAccountPeerIds.sorted()
        let durable = self.accountLedger.recordReconciliation(signedInAccountPeerIds: signedIn, directory: self.directoryPath)
        if self.removeRecordings(where: { SGCallRecordingAccountLedgerContents.reconciliationCovers(signedIn: signedIn, owner: $0) }) {
            self.accountLedger.clearReconciliation(signedInAccountPeerIds: signedIn, directory: self.directoryPath)
            return .completed
        }
        return durable ? .deferred : .failedToPersist
    }

    /// Finishes every pending removal and wipe it now can. Call ONLY from the account lifecycle hooks
    /// (launch / unlock / foreground), and only after `reconcileAccounts` has recorded the current
    /// signed-in set — an older reconciliation still on disk would otherwise be acted on. No read
    /// path (`list()`, delivery) calls it.
    @discardableResult
    func retryPendingAccountRemovals() -> SGCallRecordingAccountRemovalResult {
        // First make every entry that so far lives only in memory durable: a cleanup that is still
        // pending must survive a kill even if it was first requested while the ledger was unwritable.
        if self.hasRecordingsDirectory {
            self.accountLedger.persistPending(directory: self.directoryPath)
        }
        self.completePendingDeletes()
        let pending = self.accountLedger.pending(directory: self.directoryPath)
        if pending.contents.isWipePending {
            // Content-free, so it can finish even while sidecars are locked; it subsumes the rest.
            if self.wipeFiles() {
                self.accountLedger.reset(directory: self.directoryPath)
                return .completed
            }
            return pending.hasUnpersisted ? .failedToPersist : .deferred
        }
        var allDone = pending.isReadable
        for accountPeerId in pending.contents.removedAccountPeerIds {
            if self.removeRecordings(where: { SGCallRecordingAccountLedgerContents.removalCovers(accountPeerId: accountPeerId, owner: $0) }) {
                self.accountLedger.clearRemoval(accountPeerId: accountPeerId, directory: self.directoryPath)
            } else {
                allDone = false
            }
        }
        if let signedIn = pending.contents.signedInAccountPeerIds {
            if self.removeRecordings(where: { SGCallRecordingAccountLedgerContents.reconciliationCovers(signedIn: signedIn, owner: $0) }) {
                self.accountLedger.clearReconciliation(signedInAccountPeerIds: signedIn, directory: self.directoryPath)
            } else {
                allDone = false
            }
        }
        if allDone {
            return .completed
        }
        return pending.hasUnpersisted ? .failedToPersist : .deferred
    }

    /// Wipes everything. Called from `SGAccountCleanup` when the last account logs out, from
    /// `SGDBReset`'s Reset All, and from "Delete All Recordings" on the recordings screen.
    ///
    /// That last caller is the reason this cannot just `removeItem` the directory: the recordings
    /// screen is reachable while a call is minimised and still recording, and unlinking a file the
    /// encoder holds open destroys the recording silently (the descriptor keeps working, so nothing
    /// reports an error and the user is still shown the REC indicator). The live recording is
    /// tombstoned instead — hidden from that moment on and removed by its own session when it ends,
    /// or by the next launch if the process dies first.
    ///
    /// A WIPE THAT DOES NOT FINISH IS NOT FORGOTTEN. The pending wipe is written to the ledger FIRST;
    /// until a later pass confirms nothing is left, every recording reads as gone, no new recording
    /// can be started, and `retryPendingAccountRemovals()` finishes it after unlock or relaunch —
    /// ownerless legacy recordings included, which launch reconciliation deliberately leaves alone.
    /// If the marker itself cannot be written, the wipe is honoured in memory for this process and
    /// the result is `.failedToPersist`.
    ///
    /// Content-free: nothing is read, so this works while the device is locked.
    @discardableResult
    func deleteAll() -> SGCallRecordingAccountRemovalResult {
        guard let directory = self.directoryPath else {
            return .failedToPersist
        }
        guard FileManager.default.fileExists(atPath: directory) else {
            self.accountLedger.reset(directory: nil)
            return .completed
        }
        let durable = self.accountLedger.recordWipe(directory: directory)
        guard self.wipeFiles() else {
            return durable ? .deferred : .failedToPersist
        }
        // Confirmed: nothing any pending entry could cover is left. The ledger goes last.
        self.accountLedger.reset(directory: directory)
        if self.activeRecordingId == nil, let names = try? FileManager.default.contentsOfDirectory(atPath: directory), names.isEmpty {
            try? FileManager.default.removeItem(atPath: directory)
        }
        return .completed
    }
}

extension SGCallRecordingStore {
    /// Whether a first sidecar with this owner may be written now (nil = ownerless, which every
    /// removal and every wipe covers). False on an unreadable ledger.
    func canReserve(owner: Int64?) -> Bool {
        if let owner = owner, self.isRecordingFenced(accountPeerId: owner) {
            return false
        }
        return self.accountLedger.blocksRecording(owner: owner, directory: self.directoryPath) == false
    }
}

extension SGCallRecordingStore {
    /// Deletes every recording `matches` covers. Returns whether the pass was complete: every
    /// sidecar attributable and every match gone or durably tombstoned.
    func removeRecordings(where matches: (_ owner: SGCallRecordingOwnerEvidence) -> Bool) -> Bool {
        self.completePendingDeletes()
        var complete = true
        let scanned = self.forEachRecordingOwner { id, owner in
            if matches(owner) && !self.delete(id: id) {
                complete = false
            }
        }
        return scanned && complete
    }

    /// Content-free removal of every file in the directory except the ledger; the live recording is
    /// tombstoned rather than unlinked. Returns whether nothing is left but that tombstoned
    /// recording. Safe to repeat: no new recording can be reserved while a wipe is pending.
    func wipeFiles() -> Bool {
        guard let directory = self.directoryPath else {
            return false
        }
        guard FileManager.default.fileExists(atPath: directory) else {
            return true
        }
        let activeId = self.activeRecordingId
        // Tombstone the live recording FIRST, so it is hidden even if the rest of the pass fails.
        var allGone = true
        if let activeId = activeId, !self.delete(id: activeId) {
            allGone = false
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        for name in names where !name.hasPrefix(SGCallRecordingAccountLedger.fileName) {
            if let activeId = activeId, self.isActive(id: activeId), name.hasPrefix(activeId + ".") {
                continue
            }
            let path = (directory as NSString).appendingPathComponent(name)
            try? FileManager.default.removeItem(atPath: path)
            if FileManager.default.fileExists(atPath: path) {
                allGone = false
            }
        }
        return allGone
    }
}
