// MARK: Zenlygram — call recording delivery: vanished legs, discard, retirement, accounts.
//
// Split out of SGCallRecordingDelivery.swift; same type, same rules (see that file's header).
//
// A VANISHED LEG is one whose own local message is no longer at its recorded local id while the
// in-process correlation map has no cloud id for it. Four things produce that, told apart by EXACT
// evidence only — never by contact, file name, size or time:
//   * the server acknowledged it in an earlier process (or this one missed the callback): the
//     message's globallyUniqueId, recorded in the ledger, now resolves to a CLOUD id (audit #68);
//   * Telegram's own Retry replaced it: a newer outgoing local message in Saved Messages carries the
//     leg's own upload resource, whose random id is derived from the leg's correlation id (#69);
//   * the user deleted the queued message;
//   * no evidence at all (including a Retry copy beyond the scan window).
// The last two are "abandoned": the audio is KEPT, the record is KEPT (so its local id and
// correlation id stay available to a later cancel's discard), and the row reads "not sent".
//
// RETIREMENT is what happens to a delivery whose recording is finished, deleted or withdrawn: its
// unacknowledged own messages (and any Retry copy of them found in the scan window) are discarded
// and the exact media-cache copies its uploads left behind are removed. The ledger entry is marked
// retiring BEFORE the caller may unlink anything, and dropped only once both are done.

import Foundation

import SwiftSignalKit
import TelegramCore
import AccountContext

import SGCallRecording
import SGCallRecordingDeliveryCore

extension SGCallRecordingDelivery {
    // MARK: - Vanished legs

    func resolveVanishedLegs(context: AccountContext, id: String, record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?, legIndices: [Int]) {
        if self.resolvingIds.contains(id) {
            return
        }
        let peerId = context.account.peerId
        var legSignals: [Signal<(Int, SGCallRecordingLegResolution), NoError>] = []
        for index in legIndices where index < record.legs.count {
            let leg = record.legs[index]
            let vanishedLocalMessageId = leg.localMessageId
            let correlationId = leg.correlationId
            let globallyUniqueId = entry?.facts(legIndex: index, correlationId: correlationId)?.globallyUniqueId

            let byGloballyUniqueId: Signal<SGCallRecordingResolvedMessage?, NoError>
            if let globallyUniqueId {
                byGloballyUniqueId = context.engine.messages.messageId(peerId: peerId, globallyUniqueId: globallyUniqueId)
                |> map { messageId -> SGCallRecordingResolvedMessage? in
                    guard let messageId else {
                        return nil
                    }
                    guard messageId.peerId == peerId else {
                        return .other
                    }
                    if messageId.namespace == Namespaces.Message.Cloud {
                        return .cloud(id: messageId.id)
                    }
                    if messageId.namespace == Namespaces.Message.Local {
                        return .local(id: messageId.id)
                    }
                    return .other
                }
            } else {
                byGloballyUniqueId = .single(nil)
            }

            let scanIds = vanishedLocalMessageId.map { sgCallRecordingRetryScanIds(after: $0) } ?? []
            let retryReplacement: Signal<(localMessageId: Int32, globallyUniqueId: Int64?)?, NoError>
            if scanIds.isEmpty {
                retryReplacement = .single(nil)
            } else {
                let ids = Set(scanIds.map { EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: $0) })
                retryReplacement = context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Messages(ids: ids))
                |> map { messages -> (localMessageId: Int32, globallyUniqueId: Int64?)? in
                    // The newest outgoing message carrying THIS attempt's own upload resource.
                    let match = messages.values
                        .filter { sgCallRecordingMessageIsOwned($0, correlationIds: [correlationId], ownedFiles: nil) }
                        .max(by: { $0.id.id < $1.id.id })
                    guard let match else {
                        return nil
                    }
                    return (match.id.id, match.globallyUniqueId)
                }
            }

            legSignals.append(combineLatest(byGloballyUniqueId, retryReplacement)
            |> map { [weak self] resolved, replacement -> (Int, SGCallRecordingLegResolution) in
                // Asked again: an acknowledgement may have landed while this was running.
                let correlationCloudId = self?.confirmedCloudMessageId(context: context, correlationId: correlationId)
                return (index, sgCallRecordingResolveLeg(
                    correlationCloudId: correlationCloudId,
                    globallyUniqueIdResolution: resolved,
                    retryReplacement: replacement,
                    vanishedLocalMessageId: vanishedLocalMessageId
                ))
            })
        }
        if legSignals.isEmpty {
            return
        }
        self.resolvingIds.insert(id)
        let _ = (combineLatest(legSignals)
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] results in
            self?.applyResolution(context: context, id: id, snapshot: record, results: results)
        })
    }

    private func applyResolution(context: AccountContext, id: String, snapshot: SGCallRecordingSendRecord, results: [(Int, SGCallRecordingLegResolution)]) {
        self.resolvingIds.remove(id)
        if self.removedAccountPeerIds.contains(context.account.peerId.toInt64()) {
            return
        }
        guard let working = self.workingRecord(id: id) else {
            self.advance(id: id)
            return
        }
        var record = working.record
        var gids: [Int: Int64] = [:]
        var abandoned: [Int] = []
        var changed = false
        for (index, resolution) in results {
            // Only for the very attempt that was resolved: a retry or cancel in between wins.
            guard index < record.legs.count, index < snapshot.legs.count, record.legs[index].correlationId == snapshot.legs[index].correlationId, record.legs[index].cloudMessageId == nil else {
                continue
            }
            switch resolution {
            case let .confirmed(cloudMessageId):
                record.legs[index].cloudMessageId = cloudMessageId
                changed = true
            case let .rebound(localMessageId, globallyUniqueId):
                record.legs[index].localMessageId = localMessageId
                // The upload gate follows the leg to Telegram's Retry copy (only if still allowed).
                self.rebindUpload(correlationId: record.legs[index].correlationId, localMessageId: localMessageId)
                // A known gid is kept when the replacement's is not known yet; it is read on the
                // next observation of the replacement.
                if let globallyUniqueId {
                    gids[index] = globallyUniqueId
                }
                changed = true
            case .abandoned:
                abandoned.append(index)
            }
        }
        // Acknowledgements and re-bindings are durable before anything else is decided.
        if changed {
            self.writeLedger(id: id, record: record, origin: nil, gids: gids)
            if working.sidecarReadable {
                _ = SGCallRecordingStore.shared.setSendRecord(id: id, record)
            }
        }
        for index in abandoned {
            self.abandonedCorrelationIds.insert(record.legs[index].correlationId)
        }
        // Nothing abandoned may upload: a later Retry of it is denied (fail closed) and the row
        // offers "Try sending again".
        self.revokeUploads(correlationIds: abandoned.map { record.legs[$0].correlationId })
        if !abandoned.isEmpty && self.onlyDeadLegsRemain(record) && self.statuses[id] != .failed {
            // Nothing left on its way and something did not arrive. The record stays exactly as it
            // is: re-sending a message the user may have deleted is worse than not sending it, and a
            // later cancel still needs its local and correlation ids. "Try sending again" rebuilds
            // only the unconfirmed legs.
            self.statuses[id] = .failed
            self.notifyChanged()
        }
        self.advance(id: id)
    }

    // MARK: - Discard and cache cleanup

    /// The failed-send path of `sendManually`: the dead legs' own messages (and any Retry copy of
    /// them) go, and so do their cache copies. Acknowledged legs are left alone.
    func discardMessages(context: AccountContext, record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?, item: SGCallRecordingItem?) {
        var localIds: [Int32] = []
        var correlations: [Int64] = []
        for leg in record.legs where leg.cloudMessageId == nil {
            correlations.append(leg.correlationId)
            if let localMessageId = leg.localMessageId {
                localIds.append(localMessageId)
            }
        }
        self.revokeUploads(correlationIds: correlations)
        let _ = self.discardAndClean(context: context, localMessageIds: localIds, cloudMessageIds: [], correlationIds: correlations, knownGloballyUniqueIds: entry?.knownGloballyUniqueIds ?? [], ownedFiles: self.ownedFiles(item: item)).startStandalone()
    }

    /// Deletes this delivery's OWN unacknowledged local messages — each given local id, plus any
    /// outgoing message in the Retry scan window after it — but only those that carry one of the
    /// given attempts' upload resources (or the recording's own audio path). A message at a recorded
    /// id that is not ours is never touched. Then removes exactly these media-cache entries:
    ///   * each attempt's upload resource, by the id derived from its correlation id;
    ///   * the owned local-file resources found on the deleted messages;
    ///   * the file resource of each given ACKNOWLEDGED cloud message, which must be outgoing and
    ///     either carry a known globallyUniqueId of this delivery or come from a delivery whose facts
    ///     are bound to this very account database (callers only pass a context that passed
    ///     `liveContext` with the entry's record id).
    func discardAndClean(context: AccountContext, localMessageIds: [Int32], cloudMessageIds: [Int32], correlationIds: [Int64], knownGloballyUniqueIds: [Int64], ownedFiles: (directory: String, fileNames: [String])?) -> Signal<Never, NoError> {
        let peerId = context.account.peerId
        var candidates = Set<EngineMessage.Id>()
        for localMessageId in localMessageIds {
            candidates.insert(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: localMessageId))
            for scanId in sgCallRecordingRetryScanIds(after: localMessageId) {
                candidates.insert(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: scanId))
            }
        }
        for cloudMessageId in cloudMessageIds {
            candidates.insert(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: cloudMessageId))
        }
        var derived = Set<EngineMediaResource.Id>()
        for correlationId in correlationIds {
            derived.insert(sgCallRecordingUploadResourceId(correlationId: correlationId))
        }
        let knownGids = Set(knownGloballyUniqueIds)
        let messages: Signal<[EngineMessage.Id: EngineMessage], NoError>
        if candidates.isEmpty {
            messages = .single([:])
        } else {
            messages = context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Messages(ids: candidates))
        }
        return messages
        |> mapToSignal { messages -> Signal<Never, NoError> in
            var resourceIds = derived
            var deleteIds: [EngineMessage.Id] = []
            for message in messages.values {
                if message.id.namespace == Namespaces.Message.Cloud {
                    guard !message.flags.contains(.Incoming), cloudMessageIds.contains(message.id.id) else {
                        continue
                    }
                    if let gid = message.globallyUniqueId, !knownGids.isEmpty, !knownGids.contains(gid) {
                        continue
                    }
                    for media in message.media {
                        if let file = media as? TelegramMediaFile {
                            resourceIds.insert(EngineMediaResource(file.resource).id)
                        }
                    }
                } else if sgCallRecordingMessageIsOwned(message, correlationIds: correlationIds, ownedFiles: ownedFiles) {
                    deleteIds.append(message.id)
                    for resource in sgCallRecordingLocalResources(of: message) {
                        resourceIds.insert(sgCallRecordingUploadResourceId(randomId: resource.randomId))
                    }
                }
            }
            let delete: Signal<Never, NoError>
            if deleteIds.isEmpty {
                delete = .complete()
            } else {
                delete = context.engine.messages.deleteMessagesInteractively(messageIds: deleteIds, type: .forLocalPeer)
                |> ignoreValues
            }
            let remove: Signal<Never, NoError> = context.engine.resources.removeCachedResources(ids: Array(resourceIds), force: true)
            |> ignoreValues
            return delete |> then(remove)
        }
    }

    func ownedFiles(item: SGCallRecordingItem?) -> (directory: String, fileNames: [String])? {
        guard let item, let directory = SGCallRecordingStore.shared.directoryPath else {
            return nil
        }
        return (directory, item.audioPaths.map { ($0 as NSString).lastPathComponent })
    }

    // MARK: - Retirement

    /// Marks the entry retiring and runs the retirement. Returns whether the mark is on disk. With
    /// `revertIfNotDurable`, a mark that could not be made durable is undone in memory too and
    /// nothing runs — the caller is about to tell the user the recording was NOT deleted.
    @discardableResult
    func beginRetirement(id: String, entry: SGCallRecordingDeliveryEntry, item: SGCallRecordingItem?, revertIfNotDurable: Bool) -> Bool {
        let key = SGCallRecordingDeliveryLedger.key(recordingId: id)
        return self.beginRetirement(key: key, entry: entry, ownedFiles: self.ownedFiles(item: item), revertIfNotDurable: revertIfNotDurable)
    }

    @discardableResult
    private func beginRetirement(key: String, entry: SGCallRecordingDeliveryEntry, ownedFiles: (directory: String, fileNames: [String])?, revertIfNotDurable: Bool) -> Bool {
        var retiring = entry
        var durable = true
        if !retiring.isRetiring {
            retiring.isRetiring = true
            durable = self.ledger.set(key: key, retiring)
            if !durable && revertIfNotDurable {
                self.ledger.set(key: key, entry)
                return false
            }
        }
        self.runRetirement(key: key, entry: retiring, ownedFiles: ownedFiles)
        return durable
    }

    func runRetirement(id: String, entry: SGCallRecordingDeliveryEntry, item: SGCallRecordingItem?) {
        self.runRetirement(key: SGCallRecordingDeliveryLedger.key(recordingId: id), entry: entry, ownedFiles: self.ownedFiles(item: item))
    }

    /// Picks up retirements a kill interrupted.
    func resumeRetirements() {
        guard let entries = self.ledger.allEntries() else {
            return
        }
        for (key, entry) in entries where entry.isRetiring {
            self.runRetirement(key: key, entry: entry, ownedFiles: nil)
        }
    }

    /// Retires entries whose recording no longer exists at all — removed outside this file (a
    /// store-side delete, a damaged sidecar deleted from the list). Only when the store's directory
    /// could actually be listed: an unlistable directory proves nothing.
    func retireOrphanEntries() {
        guard let entries = self.ledger.allEntries(), !entries.isEmpty else {
            return
        }
        let store = SGCallRecordingStore.shared
        guard let directory = store.directoryPath else {
            return
        }
        var known = Set<String>()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, (try? FileManager.default.contentsOfDirectory(atPath: directory)) != nil else {
                return
            }
            known.formUnion(store.list().map { $0.id })
            known.formUnion(store.managementOnlyRecordingIds())
        }
        let busyKeys = Set(self.enqueuingIds.union(self.resolvingIds).map { SGCallRecordingDeliveryLedger.key(recordingId: $0) })
        for key in sgCallRecordingOrphanLedgerKeys(entries: entries, knownRecordingIds: known) where !busyKeys.contains(key) {
            if let entry = entries[key] {
                self.beginRetirement(key: key, entry: entry, ownedFiles: nil, revertIfNotDurable: false)
            }
        }
    }

    /// Retires every ledger entry ("Delete All", reset). False while an enqueue or resolution is in
    /// flight (their ids are about to change), when the ledger cannot be read, or when a retiring
    /// mark could not be made durable.
    func retireAllEntries() -> Bool {
        if !self.enqueuingIds.isEmpty || !self.resolvingIds.isEmpty {
            return false
        }
        guard let entries = self.ledger.allEntries() else {
            return false
        }
        for id in Array(self.observers.keys) where entries[SGCallRecordingDeliveryLedger.key(recordingId: id)] != nil {
            self.stopObserving(id: id)
            self.statuses[id] = nil
        }
        var durable = true
        for (key, entry) in entries {
            if !self.beginRetirement(key: key, entry: entry, ownedFiles: nil, revertIfNotDurable: false) {
                durable = false
            }
        }
        return durable
    }

    private func runRetirement(key: String, entry: SGCallRecordingDeliveryEntry, ownedFiles: (directory: String, fileNames: [String])?) {
        // Whatever happens below, nothing of a retiring delivery may upload any more.
        self.revokeUploads(correlationIds: entry.allCorrelationIds)
        if self.retiringKeys.contains(key) {
            return
        }
        guard let context = self.liveContext(accountPeerId: entry.accountPeerId, accountRecordId: entry.accountRecordId) else {
            let isRemoved = self.removedAccountPeerIds.contains(entry.accountPeerId)
            let isSignedOut = !self.contexts.isEmpty && self.contexts[entry.accountPeerId] == nil
            let isOtherDatabase = self.contexts[entry.accountPeerId] != nil && !isRemoved
            if isRemoved || isSignedOut || isOtherDatabase {
                // Its queued messages and media box live in a database that is gone or is not this
                // one; nothing here can reach them, and nothing may be applied elsewhere.
                self.ledger.set(key: key, nil)
            }
            // Otherwise the account list has not arrived yet: kept for the next resume.
            return
        }
        self.retiringKeys.insert(key)
        let cloudIds = entry.legs.compactMap { $0.cloudMessageId }
        let _ = (self.discardAndClean(context: context, localMessageIds: entry.unacknowledgedLocalMessageIds, cloudMessageIds: cloudIds, correlationIds: entry.allCorrelationIds, knownGloballyUniqueIds: entry.knownGloballyUniqueIds, ownedFiles: ownedFiles)
        |> deliverOnMainQueue).startStandalone(completed: { [weak self] in
            guard let self else {
                return
            }
            self.retiringKeys.remove(key)
            // Dropped only if it is still the retiring entry this run was for.
            if case let .known(current?) = self.ledger.lookup(key: key), current.isRetiring {
                self.ledger.set(key: key, nil)
            }
        })
    }

    // MARK: - Ownerless recordings

    /// The store deletes recordings that name no account on ANY logout, so their deliveries (queued
    /// to whichever account the user tapped) are retired on any account removal. Returns whether
    /// every retiring mark is durable.
    private func retireOwnerlessEntries(_ entries: [String: SGCallRecordingDeliveryEntry]) -> Bool {
        var durable = true
        for (key, entry) in entries where entry.isOwnerlessRecording && !entry.isRetiring {
            if !self.beginRetirement(key: key, entry: entry, ownedFiles: nil, revertIfNotDurable: false) {
                durable = false
            }
        }
        return durable
    }

    /// Completes an ownerless retirement requested while the ledger could not be read.
    func processOwnerlessRetirementRequest() {
        guard self.ledger.isOwnerlessRetirementRequested, let entries = self.ledger.allEntries() else {
            return
        }
        if self.retireOwnerlessEntries(entries) {
            self.ledger.clearOwnerlessRetirementRequest()
        }
    }

    // MARK: - Accounts

    /// An account was removed (logged out). Call BEFORE the store deletes that account's recordings.
    ///
    /// Synchronous and sidecar-free, so locked, unreadable, corrupt and legacy metadata do not
    /// matter. Immediately and for the rest of this process nothing is sent, enqueued, retried,
    /// observed or written to the ledger for the account; late callbacks of work started before
    /// this discard what they produced instead. While its context is still live, its own
    /// unacknowledged messages (and Retry copies in the scan window) and their exact cache copies are
    /// discarded — only messages that carry this delivery's own uploads. Deliveries of OWNERLESS
    /// recordings (any account) are retired too, because the store deletes those on any logout;
    /// other accounts' owned deliveries are not touched.
    ///
    /// Returns true when no durable delivery state for the account remains and the ownerless
    /// retirement is durable; false when the ledger cannot be read or written right now — call again
    /// later (or `reconcileAccounts`). The in-process block holds either way, and an ownerless
    /// retirement that could not run is recorded in a marker that survives the lock and a relaunch.
    @discardableResult
    public func accountRemoved(accountPeerId: Int64) -> Bool {
        assert(Thread.isMainThread)
        self.removedAccountPeerIds.insert(accountPeerId)
        self.revokeUploads(accountPeerId: accountPeerId)
        self.pendingAutoSend = self.pendingAutoSend.filter { $0.value.account.peerId.toInt64() != accountPeerId }
        for (id, observer) in self.observers where observer.accountPeerId == accountPeerId {
            self.stopObserving(id: id)
            self.statuses[id] = nil
        }
        guard let entries = self.ledger.allEntries() else {
            self.ledger.removeAll(accountPeerId: accountPeerId)
            self.ledger.requestOwnerlessRetirement()
            self.notifyChanged()
            return false
        }
        if let context = self.contexts[accountPeerId] {
            for (key, entry) in entries where entry.accountPeerId == accountPeerId && !self.retiringKeys.contains(key) {
                if let recordId = entry.accountRecordId, recordId != context.account.id.int64 {
                    continue
                }
                let cloudIds = entry.legs.compactMap { $0.cloudMessageId }
                let _ = self.discardAndClean(context: context, localMessageIds: entry.unacknowledgedLocalMessageIds, cloudMessageIds: cloudIds, correlationIds: entry.allCorrelationIds, knownGloballyUniqueIds: entry.knownGloballyUniqueIds, ownedFiles: nil).startStandalone()
            }
        }
        let ownerlessDurable = self.retireOwnerlessEntries(entries.filter { $0.value.accountPeerId != accountPeerId })
        if !ownerlessDurable {
            self.ledger.requestOwnerlessRetirement()
        }
        self.ledger.removeAll(accountPeerId: accountPeerId)
        self.notifyChanged()
        return self.ledger.holdsNothing(accountPeerId: accountPeerId) && ownerlessDurable
    }

    /// The full, authoritative set of signed-in accounts (launch, every account-list change). Every
    /// account the delivery knows of that is not in it is treated as `accountRemoved`. A removed
    /// account that is signed in again is unblocked ONLY once the ledger is readable and holds
    /// nothing of its old state. Returns true when nothing durable of any absent account remains and
    /// no ownerless retirement is pending.
    @discardableResult
    public func reconcileAccounts(signedInAccountPeerIds: Set<Int64>) -> Bool {
        assert(Thread.isMainThread)
        self.processOwnerlessRetirementRequest()
        let entries = self.ledger.allEntries()
        if entries != nil {
            for accountPeerId in self.removedAccountPeerIds.intersection(signedInAccountPeerIds) where self.ledger.holdsNothing(accountPeerId: accountPeerId) {
                self.removedAccountPeerIds.remove(accountPeerId)
            }
        }
        var absent = Set(self.contexts.keys)
        for observer in self.observers.values {
            absent.insert(observer.accountPeerId)
        }
        if let entries {
            for entry in entries.values {
                absent.insert(entry.accountPeerId)
            }
        }
        absent.subtract(signedInAccountPeerIds)
        var complete = entries != nil
        for accountPeerId in absent {
            if !self.accountRemoved(accountPeerId: accountPeerId) {
                complete = false
            }
        }
        if self.ledger.isOwnerlessRetirementRequested {
            complete = false
        }
        return complete
    }
}

// MARK: - Resource identity

/// The media-box id of the upload resource for an attempt with `correlationId`.
func sgCallRecordingUploadResourceId(correlationId: Int64) -> EngineMediaResource.Id {
    return sgCallRecordingUploadResourceId(randomId: sgCallRecordingResourceRandomId(correlationId: correlationId))
}

func sgCallRecordingUploadResourceId(randomId: Int64) -> EngineMediaResource.Id {
    return EngineMediaResource(LocalFileReferenceMediaResource(localFilePath: "", randomId: randomId)).id
}

/// The local-file resources on a message, as plain values for the ownership test.
func sgCallRecordingLocalResources(of message: EngineMessage) -> [SGCallRecordingLocalResource] {
    var result: [SGCallRecordingLocalResource] = []
    for media in message.media {
        if let file = media as? TelegramMediaFile, let resource = file.resource as? LocalFileReferenceMediaResource {
            result.append(SGCallRecordingLocalResource(randomId: resource.randomId, path: resource.localFilePath))
        }
    }
    return result
}

/// See `sgCallRecordingIsOwnedMessage`: outgoing and carrying one of these attempts' own uploads.
func sgCallRecordingMessageIsOwned(_ message: EngineMessage, correlationIds: [Int64], ownedFiles: (directory: String, fileNames: [String])?) -> Bool {
    return sgCallRecordingIsOwnedMessage(
        isIncoming: message.flags.contains(.Incoming),
        resources: sgCallRecordingLocalResources(of: message),
        correlationIds: correlationIds,
        ownedDirectory: ownedFiles?.directory,
        ownedFileNames: ownedFiles?.fileNames ?? []
    )
}
