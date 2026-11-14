// MARK: Zenlygram — call recording delivery: the native upload gate's decider.
//
// TelegramCore's `OutgoingLocalFileUploadGate` asks, when ANY upload of a recording file starts —
// Telegram's own Retry and every restart included — whether it may run, and keeps listening until
// the content is ready (a `false` then disposes it). This file answers.
//
// THE DECIDER READS ONE THING: an immutable `SGCallRecordingUploadSnapshot`, published on main.
// It runs on the pending-message queue, so it touches no store, file, Keychain or main-queue state,
// and `installUploadGate()` does nothing but register it: it runs at launch before the app group,
// the root path or any account exists.
//
// Allowances are granted ONLY after `advance`/`enqueue` re-validated the leg (owner account signed
// in, not removed, same account database; ledger entry not retiring; privacy `.open` or `.protected`
// with this recording's own grant), and revoked on every cancel, retirement, withdrawal, protection
// change, account removal and finish. An allowance for a leg Delivery is enqueuing right now is
// published BEFORE `enqueueMessages`, because an unknown resource is denied at once.
//
// LOCKED RELAUNCH IS FAIL CLOSED. Until Delivery has a live account, a readable sidecar and a
// protection verdict, nothing is allowed: a restarted recording upload is denied and its message
// fails. When proof returns, each such leg is re-sent ONCE under the consent already recorded —
// only legs the gate itself denied (its last verdict in this process, or the ledger's durable mark
// when this process saw none), never other failures. See SGCallRecordingGateDenialRecovery.swift.

import Foundation

import SwiftSignalKit
import TelegramCore
import AccountContext

import SGCallRecording
import SGCallRecordingDeliveryCore

/// State shared between main (which publishes allowances) and the gate's decider (which reads them
/// and records its verdicts). Pure values behind locks; creating it has no side effects, so the
/// decider can exist before anything is set up.
final class SGCallRecordingUploadGateState {
    let snapshot = ValuePromise<SGCallRecordingUploadSnapshot>(SGCallRecordingUploadSnapshot(), ignoreRepeated: true)
    /// The verdicts the decider delivered (written on the pending-message queue) and the re-send
    /// bookkeeping (main).
    let denialRecovery = SGCallRecordingGateDenialRecovery()
}

let sgCallRecordingUploadGateState = SGCallRecordingUploadGateState()

extension SGCallRecordingDelivery {
    /// Registers the decider with TelegramCore. Call once, at launch, before any account starts.
    /// Registers and nothing else: no store, ledger, path, Keychain or network access, and it does
    /// not create `SGCallRecordingDelivery.shared`.
    public static func installUploadGate() {
        let state = sgCallRecordingUploadGateState
        OutgoingLocalFileUploadGate.setDecider { request in
            let facts = SGCallRecordingUploadRequestFacts(
                postboxIdentity: request.postboxIdentity,
                accountPeerId: request.accountPeerId.toInt64(),
                peerId: request.peerId.toInt64(),
                messagePeerId: request.messageId.peerId.toInt64(),
                messageNamespaceIsLocal: request.messageId.namespace == Namespaces.Message.Local,
                messageId: request.messageId.id,
                localFilePath: request.localFilePath,
                resourceRandomId: request.resourceRandomId
            )
            return state.snapshot.get()
            |> map { snapshot -> Bool in
                let allowed = snapshot.allows(facts)
                // The LAST verdict counts: an allow after a deny makes a later failure ordinary.
                state.denialRecovery.recordVerdict(resourceRandomId: facts.resourceRandomId, allowed: allowed)
                return allowed
            }
        }
    }

    // MARK: - Allowances (main only)

    func allowUpload(context: AccountContext, correlationId: Int64, fileName: String, localMessageId: Int32?) {
        if fileName.isEmpty || self.removedAccountPeerIds.contains(context.account.peerId.toInt64()) {
            return
        }
        let key = sgCallRecordingResourceRandomId(correlationId: correlationId)
        let entry = SGCallRecordingUploadAllowEntry(
            postboxIdentity: OutgoingLocalFileUploadGate.postboxIdentity(account: context.account),
            accountPeerId: context.account.peerId.toInt64(),
            fileName: fileName,
            localMessageId: localMessageId
        )
        if self.uploadSnapshot.entries[key] != entry {
            self.uploadSnapshot.entries[key] = entry
            self.publishUploadSnapshot()
        }
    }

    /// Binds an EXISTING allowance to a known local id (enqueue completion, a Retry copy found).
    /// Never creates one: a revocation that happened meanwhile stands.
    func rebindUpload(correlationId: Int64, localMessageId: Int32) {
        let key = sgCallRecordingResourceRandomId(correlationId: correlationId)
        guard let current = self.uploadSnapshot.entries[key], current.localMessageId != localMessageId else {
            return
        }
        self.uploadSnapshot.entries[key] = SGCallRecordingUploadAllowEntry(postboxIdentity: current.postboxIdentity, accountPeerId: current.accountPeerId, fileName: current.fileName, localMessageId: localMessageId)
        self.publishUploadSnapshot()
    }

    func revokeUploads(correlationIds: [Int64]) {
        var changed = false
        for correlationId in correlationIds {
            if self.uploadSnapshot.entries.removeValue(forKey: sgCallRecordingResourceRandomId(correlationId: correlationId)) != nil {
                changed = true
            }
        }
        if changed {
            self.publishUploadSnapshot()
        }
    }

    func revokeUploads(accountPeerId: Int64) {
        let before = self.uploadSnapshot.entries.count
        self.uploadSnapshot.entries = self.uploadSnapshot.entries.filter { $0.value.accountPeerId != accountPeerId }
        if self.uploadSnapshot.entries.count != before {
            self.publishUploadSnapshot()
        }
    }

    func isUploadAllowed(correlationId: Int64) -> Bool {
        return self.uploadSnapshot.entries[sgCallRecordingResourceRandomId(correlationId: correlationId)] != nil
    }

    private func publishUploadSnapshot() {
        sgCallRecordingUploadGateState.snapshot.set(self.uploadSnapshot)
    }

    // MARK: - Re-send after a gate denial

    /// The recovery's view of one enqueued, unacknowledged leg: the ledger's durable mark, the
    /// allowance `advance` published from current proof, the leg's own file, and whether the
    /// delivery's provenance still consents to a re-send without a tap (an automatic one only while
    /// the setting is on; no entry, no consent). A leg the sidecar does not name a file for (a
    /// ledger-only view) is never re-sendable.
    func gateDeniedLeg(_ leg: SGCallRecordingSendLeg, legIndex: Int, entry: SGCallRecordingDeliveryEntry?, durablyDenied: Bool? = nil) -> SGCallRecordingGateDeniedLeg {
        let uploadAllowed = self.isUploadAllowed(correlationId: leg.correlationId)
        // Probed only when it can matter: without an allowance nothing is re-sendable anyway.
        var fileReadable = false
        if uploadAllowed, let path = SGCallRecordingStore.shared.path(forAudioFileName: leg.fileName) {
            fileReadable = sgCallRecordingFileIsReadable(atPath: path)
        }
        return SGCallRecordingGateDeniedLeg(
            correlationId: leg.correlationId,
            durablyDenied: durablyDenied ?? (entry?.facts(legIndex: legIndex, correlationId: leg.correlationId)?.uploadGateDenied ?? false),
            uploadAllowed: uploadAllowed,
            fileReadable: fileReadable,
            resendConsented: sgCallRecordingGateDeniedResendConsented(isAutomatic: entry?.isAutomatic, autoSendEnabled: self.autoSendEnabled)
        )
    }

    /// Re-sends legs whose failed message the gate denied, once proof is back: the failed message
    /// (own upload only) and its cache copy go, and the leg is enqueued under a fresh correlation
    /// — the "Try sending again" path, under the consent and provenance already recorded.
    func resendGateDeniedLegs(context: AccountContext, id: String, record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?, legIndices: [Int], item: SGCallRecordingItem?) {
        guard let entry, !legIndices.isEmpty else {
            return
        }
        var retry = record
        var oldCorrelations: [Int64] = []
        var oldLocalIds: [Int32] = []
        for index in legIndices where index < retry.legs.count && retry.legs[index].cloudMessageId == nil {
            let old = retry.legs[index]
            oldCorrelations.append(old.correlationId)
            if let localMessageId = old.localMessageId {
                oldLocalIds.append(localMessageId)
            }
            let fresh = Int64.random(in: Int64.min ... Int64.max)
            sgCallRecordingUploadGateState.denialRecovery.markResent(old: old.correlationId, fresh: fresh)
            retry.legs[index].localMessageId = nil
            retry.legs[index].correlationId = fresh
        }
        if oldCorrelations.isEmpty {
            return
        }
        self.revokeUploads(correlationIds: oldCorrelations)
        self.stopObserving(id: id)
        let _ = self.discardAndClean(context: context, localMessageIds: oldLocalIds, cloudMessageIds: [], correlationIds: oldCorrelations, knownGloballyUniqueIds: entry.knownGloballyUniqueIds, ownedFiles: self.ownedFiles(item: item)).startStandalone()
        let origin = EntryOrigin(accountRecordId: context.account.id.int64, exportAuthorized: entry.exportAuthorized, isAutomatic: entry.isAutomatic, isOwnerlessRecording: entry.isOwnerlessRecording)
        guard self.writeLedger(id: id, record: retry, origin: origin) else {
            return
        }
        guard SGCallRecordingStore.shared.setSendRecord(id: id, retry) else {
            return
        }
        self.statuses[id] = .waiting
        self.notifyChanged()
        self.advance(id: id)
    }
}
