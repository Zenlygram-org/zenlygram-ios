// MARK: Zenlygram — call recording, delivery to the user's own Saved Messages.
//
// WHAT CHANGED, AND WHY EVERYTHING HERE IS SHAPED BY IT. Until this file existed, "the recording
// never leaves this iPhone" was not a promise the code made — it was a property of the code, because
// nothing in the app could move a recording anywhere. That is over. A finished recording can now be
// sent to the user's own Saved Messages, which is an ordinary Telegram cloud chat: the audio is
// stored on Telegram's servers, it is NOT end-to-end encrypted, and it contains the other party's
// voice as well as the user's. The consent screen, the setting's description and
// appstore/privacy-policy.html say exactly that; this file must never do more than they describe.
//
// TWO WAYS IN, AND ONLY TWO:
//   * the "Send to Saved Messages" setting, DEFAULT OFF. Nothing is uploaded on its own while it is
//     off, and turning it off withdraws automatic records nothing of which has been handed to
//     Telegram yet. When it is on, a recording that has finished being written (a recording that
//     stopped early included) is queued automatically — but ONLY when the recording names its own
//     account AND the other party, and that party is neither in the Secret Vault nor Chat-Locked for
//     that account (`SGProtectedStore`, fail closed). An unknown identity or an unreadable
//     protection state is never "unprotected" (audit #9).
//   * the per-recording action on the recordings list, which works whether or not the setting is
//     on, because it is the user tapping it in that moment — exactly like the share sheet. For a
//     PROTECTED recording the list must first establish local authorization and pass a grant bound
//     to that recording's account and peer (`SGCallRecordingExportGrant`); the message then names
//     nobody. An unverifiable recording is never exported.
// There is no third path from this file. Nothing here runs on a timer, on a push, or on anything
// but those two.
//
// THE NATIVE GATE. Telegram's own Retry on a failed message, and the pending-message manager's
// restarts, re-start an upload without passing through here; observing and discarding afterwards
// can only remove a message once it is seen. So every upload of a recording file also asks
// TelegramCore's `OutgoingLocalFileUploadGate`, whose decider (SGCallRecordingDeliveryUploadGate.swift)
// allows only legs this file re-validated, and revokes them — disposing an upload still building —
// on every cancel, withdrawal, protection change, account removal and finish. A revocation after the
// content is ready (the send request is in flight) can only delete the local message.
//
// A DOCUMENT, NOT A VOICE MESSAGE. The same file goes as a DOCUMENT with
// `.Audio(isVoice: false, title:, performer:)` and a `.FileName`: it plays inline with a seek bar,
// keeps a file name that identifies the recording, lands in the Files/Music tab of Saved Messages,
// and is searchable. A forty-minute call as a voice message is a nameless waveform.
//
// CONFIRMATION IS THE WHOLE POINT. Enqueuing is not sending. The local file is deleted only when
// every leg has a CLOUD message id that the server gave it. Two proofs exist, in this order:
//   1. the correlation id handed to `enqueueMessages` (in-memory map, this process only);
//   2. the message's `globallyUniqueId`, which Postbox re-points to the cloud id on acknowledgement
//      and keeps across relaunches, recorded in the delivery's own ledger
//      (`SGCallRecordingDeliveryLedger`), which stays readable while the device is locked — the
//      recording's sidecar does not (audit #68).
// A message found at a recorded local id is trusted — for its failed flag, its globallyUniqueId or
// as something to delete — ONLY if it is outgoing and carries this delivery's own upload resource.
// Telegram's Retry re-enqueues WITHOUT our correlation id but WITH the same media resource, whose
// random id is derived from the correlation id; the delivery finds the replacement by that exact
// resource and re-binds the leg to it (audit #69). Nothing is matched by contact, name, size or time.
//
// THE MEDIA CACHE COPY. The uploader COPIES the recording into the account's media box
// (`isUniquelyReferencedTemporaryFile: false` — handing over the original would delete it at the
// start of the upload). That copy is removed by exact resource id, only through a context whose
// account record matches the delivery's: after a cancel, once the queued message is gone; after an
// acknowledgement, from the cloud message's own file resource, to which Telegram moves the data
// (audit #13). While an upload is pending the audio IS in that cache (Telegram's protection class,
// not the Vault's), and a cancel cannot recall bytes already sent.
//
// NOTHING HERE IS LOGGED, for the same reason as everywhere else in this feature: no path, no file
// name, no duration and no peer reaches SGLogging or any other sink that can leave the process.

import Foundation
import UIKit

import SwiftSignalKit
import TelegramCore
import AccountContext

import SGCallRecording
import SGCallRecordingDeliveryCore
import SGProtectedStore
import SGSimpleSettings
import SGStrings

/// What the recordings list has to say about a recording's delivery.
public enum SGCallRecordingSendStatus: Equatable {
    /// Nothing was ever queued for this recording.
    case none
    /// Queued and not yet acknowledged by the server. The file stays exactly where it is.
    case waiting
    /// Some leg did not get through (failed, deleted, cannot be built). The file stays; the list
    /// offers to send it again, which clears the dead messages first.
    case failed
}

public final class SGCallRecordingDelivery {
    public static let shared = SGCallRecordingDelivery()

    struct Observer {
        let accountPeerId: Int64
        let disposable: Disposable
    }

    /// What a newly written ledger entry records about its origin.
    struct EntryOrigin {
        let accountRecordId: Int64
        let exportAuthorized: Bool
        let isAutomatic: Bool
        let isOwnerlessRecording: Bool
    }

    /// Bumped whenever a delivery's state changes, so the recordings list can re-read the store.
    private let versionPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    private var version: Int = 0
    public var stateVersion: Signal<Int, NoError> {
        return self.versionPromise.get()
    }

    /// Signed-in accounts by `PeerId.toInt64()`.
    var contexts: [Int64: AccountContext] = [:]
    /// One observer per recording being delivered.
    var observers: [String: Observer] = [:]
    /// Recordings whose `enqueueMessages` call is in flight; cancellation refuses while it is.
    var enqueuingIds = Set<String>()
    /// Recordings whose vanished legs are being resolved (acknowledged / retried / abandoned).
    var resolvingIds = Set<String>()
    /// Ledger keys whose retirement (discard + cache cleanup) is running in this process.
    var retiringKeys = Set<String>()
    /// Automatic intents that could not be written down yet. In memory only, deliberately: an intent
    /// is not a send, and a recording that stays local loses nothing.
    var pendingAutoSend: [String: AccountContext] = [:]
    /// Cached per-recording status for the list.
    var statuses: [String: SGCallRecordingSendStatus] = [:]
    /// Accounts the parent reported removed. Nothing is sent, enqueued, retried, observed or written
    /// to the ledger for them in this process. Lifted only by `reconcileAccounts`, and only once no
    /// durable state of the removed account remains.
    var removedAccountPeerIds = Set<Int64>()
    /// Attempts' legs found abandoned in this process (message gone, no evidence it arrived). Not
    /// observed again, or the same vanished leg would be resolved on every pass.
    var abandonedCorrelationIds = Set<Int64>()
    /// Attempts' legs that cannot be handed to Telegram (file missing, message not buildable,
    /// `enqueueMessages` returned no id). Not retried in this process; the row reads "not sent".
    var refusedCorrelationIds = Set<Int64>()
    /// Main-only working copy of what TelegramCore's upload gate may let through. Published into
    /// `sgCallRecordingUploadGateState`, which the gate's decider reads. See
    /// SGCallRecordingDeliveryUploadGate.swift.
    var uploadSnapshot = SGCallRecordingUploadSnapshot()
    /// The delivery's own durable facts. See `SGCallRecordingDeliveryLedger`.
    let ledger: SGCallRecordingDeliveryLedger

    private var started = false
    private var accountsDisposable: Disposable?

    private init() {
        let storage: SGCallRecordingDeliveryLedgerStorage
        if let directory = SGCallRecordingDeliveryLedgerFile.defaultDirectoryURL() {
            storage = SGCallRecordingDeliveryLedgerFile(directoryURL: directory)
        } else {
            storage = SGCallRecordingDeliveryNoLedgerStorage()
        }
        self.ledger = SGCallRecordingDeliveryLedger(storage: storage)
    }

    // MARK: - Lifecycle

    /// Idempotent; called once from the app delegate, next to `SGAccountCleanup.start`.
    public static func start(sharedContext: SharedAccountContext) {
        assert(Thread.isMainThread)
        SGCallRecordingDelivery.shared.startImpl(sharedContext: sharedContext)
    }

    private func startImpl(sharedContext: SharedAccountContext) {
        if self.started {
            return
        }
        self.started = true

        self.accountsDisposable = (sharedContext.activeAccountContexts
        |> deliverOnMainQueue).startStrict(next: { [weak self] activeAccounts in
            guard let self else {
                return
            }
            var contexts: [Int64: AccountContext] = [:]
            for (_, context, _) in activeAccounts.accounts {
                contexts[context.account.peerId.toInt64()] = context
            }
            self.contexts = contexts
            self.resumeAll()
        })

        // A finished recording is `.complete`: while locked neither the uploader nor the sidecar can
        // read it. The first unlock is exactly when that stops being true.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.resumeAll()
        })
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.resumeAll()
        })
        // A peer moved into the Vault or locked must stop what is in flight now, not at the next
        // foreground: every pass re-validates and revokes the upload gate's allowance.
        NotificationCenter.default.addObserver(forName: SGProtectedStore.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.resumeAll()
        })
    }

    /// Picks every recording with a delivery record back up.
    public func resumeAll() {
        assert(Thread.isMainThread)
        self.ledger.flush()
        self.processOwnerlessRetirementRequest()
        // Retirements a kill interrupted, and deliveries whose recording went away without passing
        // through here (a damaged sidecar, a store-side delete).
        self.resumeRetirements()
        self.retireOrphanEntries()
        for (id, _) in SGCallRecordingStore.shared.pendingSends() {
            self.advance(id: id)
        }
        // `pendingSends` lists readable sidecars only. A cold start while locked (or a corrupt
        // sidecar) still has deliveries on their way that only the ledger knows about.
        self.advanceLedgerOnlyDeliveries()
        // Automatic intents not yet written down. THE GATE IS RE-READ HERE: turning the setting off
        // promises that this stops. Records already written are handled in `advance`.
        guard self.autoSendEnabled else {
            self.pendingAutoSend.removeAll()
            return
        }
        for (id, context) in self.pendingAutoSend {
            self.sendAutomatically(context: context, id: id)
        }
    }

    /// Advances recordings whose sidecar is unreadable or corrupt but whose ledger entry has an
    /// unacknowledged message (`sgCallRecordingLedgerOnlyResumeIds`). `advance` only watches them
    /// from the ledger (and revokes a corrupt one's allowances): nothing is granted, enqueued or
    /// re-sent without a readable sidecar, and no owner is guessed — the ledger entry's own account
    /// and record id must be live.
    private func advanceLedgerOnlyDeliveries() {
        guard let entries = self.ledger.allEntries(), !entries.isEmpty else {
            return
        }
        let store = SGCallRecordingStore.shared
        var sidecars: [(id: String, condition: SGCallRecordingSidecarCondition)] = []
        for id in store.managementOnlyRecordingIds() {
            switch store.readState(id: id) {
            case .unreadable:
                sidecars.append((id, .lockedUnreadable))
            case .corrupt:
                sidecars.append((id, .corrupt))
            case .available, .missing, .deleted, .pendingAccountRemoval:
                break
            }
        }
        for id in sgCallRecordingLedgerOnlyResumeIds(sidecars: sidecars, entries: entries) {
            self.advance(id: id)
        }
    }

    // MARK: - Accounts and privacy

    /// The context for an account — only if it is signed in, not removed, and (when the record id is
    /// known) the very same local database the facts were written in.
    func liveContext(accountPeerId: Int64, accountRecordId: Int64?) -> AccountContext? {
        if self.removedAccountPeerIds.contains(accountPeerId) {
            return nil
        }
        guard let context = self.contexts[accountPeerId] else {
            return nil
        }
        if let accountRecordId, context.account.id.int64 != accountRecordId {
            return nil
        }
        return context
    }

    /// The privacy verdict for a recording, from ITS account and peer — never the screen's account.
    func privacy(of item: SGCallRecordingItem) -> SGCallRecordingDeliveryPrivacy {
        let protectedStore = SGProtectedStore.shared
        let verdict = item.privacy(isProtectionConfigured: protectedStore.isAnyProtectionConfigured, protection: { peerId, accountPeerId in
            switch protectedStore.protection(peerId: peerId, accountPeerId: accountPeerId) {
            case .none:
                return .none
            case .locked, .vaulted:
                return .protected
            case .unknown:
                return .unknown
            }
        })
        switch verdict {
        case .open:
            return .open
        case .protected:
            return .protected
        case .unverifiable:
            return .unverifiable
        }
    }

    /// Whether the list must establish local authorization (and pass a grant) before sending.
    public func manualSendRequiresAuthorization(item: SGCallRecordingItem) -> Bool {
        return self.privacy(of: item) == .protected
    }

    /// The account a NEW delivery goes to: THE ONE THAT MADE THE RECORDING, never the one on screen.
    /// A version-1 sidecar names no account; only for a manual tap on an `.open` recording is the
    /// tapped account the answer. A signed-out or removed owner means nil — refused, never redirected.
    private func destination(item: SGCallRecordingItem, tappedOn context: AccountContext) -> AccountContext? {
        guard let owner = item.accountPeerId else {
            if self.removedAccountPeerIds.contains(context.account.peerId.toInt64()) {
                return nil
            }
            return context
        }
        if self.removedAccountPeerIds.contains(owner) {
            return nil
        }
        if context.account.peerId.toInt64() == owner {
            return context
        }
        return self.contexts[owner]
    }

    // MARK: - Public entry points

    /// Whether the recordings list should offer "Send to Saved Messages" for this row at all.
    public func canSendManually(item: SGCallRecordingItem, tappedOn context: AccountContext) -> Bool {
        assert(Thread.isMainThread)
        if SGCallRecordingStore.shared.isActive(id: item.id) {
            return false
        }
        if self.status(item: item) == .waiting {
            return false
        }
        if self.privacy(of: item) == .unverifiable {
            return false
        }
        if let record = item.send {
            return self.liveContext(accountPeerId: record.accountPeerId, accountRecordId: nil) != nil
        }
        return self.destination(item: item, tappedOn: context) != nil
    }

    /// The status the list shows for one recording.
    public func status(item: SGCallRecordingItem) -> SGCallRecordingSendStatus {
        guard let record = item.send else {
            return .none
        }
        if record.isConfirmed {
            return .waiting
        }
        return self.statuses[item.id] ?? .waiting
    }

    /// The automatic path: a recording just finished being written. Does nothing at all when the
    /// setting is off.
    public func recordingFinished(context: AccountContext, id: String) {
        assert(Thread.isMainThread)
        guard SGCallRecordingGate.sendToSavedMessages else {
            return
        }
        if self.removedAccountPeerIds.contains(context.account.peerId.toInt64()) {
            return
        }
        self.pendingAutoSend[id] = context
        self.sendAutomatically(context: context, id: id)
    }

    var autoSendEnabled: Bool {
        return SGCallRecordingGate.sendToSavedMessages
    }

    /// The manual per-recording action. Works whether or not the setting is on.
    ///
    /// `grant` is honoured only for a protected recording and only when it names exactly that
    /// recording's account and peer; the message then names nobody. A failed delivery is retried in
    /// the account it was queued for — never moved to another one.
    @discardableResult
    public func sendManually(context: AccountContext, id: String, grant: SGCallRecordingExportGrant? = nil) -> SGCallRecordingManualSendResult {
        assert(Thread.isMainThread)
        let item: SGCallRecordingItem
        switch SGCallRecordingStore.shared.readState(id: id) {
        case let .available(value):
            item = value
        case .unreadable:
            return .failed
        case .missing, .deleted, .corrupt, .pendingAccountRemoval:
            return .refused
        }
        if SGCallRecordingStore.shared.isActive(id: id) {
            return .refused
        }
        let grantMatches = sgCallRecordingExportGrantMatches(grant, accountPeerId: item.accountPeerId, peerId: item.peerId)
        let exportAuthorized: Bool
        switch sgCallRecordingManualSendDecision(privacy: self.privacy(of: item), grantMatches: grantMatches) {
        case .requiresAuthorization:
            return .requiresAuthorization
        case .refused:
            return .refused
        case let .send(value):
            exportAuthorized = value
        }
        guard let record = item.send else {
            guard let destination = self.destination(item: item, tappedOn: context) else {
                return .accountUnavailable
            }
            return self.writeRecord(item: item, destination: destination, exportAuthorized: exportAuthorized, isAutomatic: false) ? .queued : .failed
        }
        if record.isConfirmed || self.statuses[id] != .failed || self.resolvingIds.contains(id) || self.enqueuingIds.contains(id) {
            self.advance(id: id)
            return .alreadyInProgress
        }
        // Failed: drop the dead messages and start over — ONLY for the legs still dead, and ONLY in
        // the account the record names. The record INCLUDING every local id the ledger knows, or the
        // discard misses a live message and a second copy follows.
        let effective = self.effectiveRecord(id: id, record)
        guard effective.ledgerKnown else {
            return .failed
        }
        guard let owner = self.liveContext(accountPeerId: effective.record.accountPeerId, accountRecordId: effective.entry?.accountRecordId) else {
            return .accountUnavailable
        }
        self.discardMessages(context: owner, record: effective.record, entry: effective.entry, item: item)
        var retry = effective.record
        var anyToRetry = false
        for index in retry.legs.indices where retry.legs[index].cloudMessageId == nil {
            retry.legs[index].localMessageId = nil
            // A fresh correlation id — and with it a fresh upload resource.
            retry.legs[index].correlationId = Int64.random(in: Int64.min ... Int64.max)
            anyToRetry = true
        }
        self.stopObserving(id: id)
        if !anyToRetry {
            self.advance(id: id)
            return .alreadyInProgress
        }
        let origin = EntryOrigin(accountRecordId: owner.account.id.int64, exportAuthorized: exportAuthorized, isAutomatic: false, isOwnerlessRecording: item.accountPeerId == nil)
        // Ledger first: it is the cancellation handle for whatever is enqueued next.
        guard self.writeLedger(id: id, record: retry, origin: origin) else {
            return .failed
        }
        guard SGCallRecordingStore.shared.setSendRecord(id: id, retry) else {
            return .failed
        }
        self.statuses[id] = .waiting
        self.notifyChanged()
        self.advance(id: id)
        return .queued
    }

    /// Cancels a delivery so the recording can be deleted. Returns whether the caller may now delete
    /// the recording's files. FALSE MEANS "DO NOT DELETE": keeping the audio is always the safe side.
    ///
    /// Works for recordings the list can only show as neutral delete-only rows (corrupt, locked,
    /// pending account removal): a readable ledger carries the cancellation, because every record
    /// this build writes is in the ledger before the sidecar. The ledger entry is marked retiring
    /// DURABLY before true is returned, so a kill between this and the discard still finishes it.
    /// An already-acknowledged message is left alone — it is a real message in the user's own chat.
    @discardableResult
    public func cancelSend(id: String) -> Bool {
        assert(Thread.isMainThread)
        self.pendingAutoSend.removeValue(forKey: id)
        let lookup = self.ledger.lookup(recordingId: id)
        var entry: SGCallRecordingDeliveryEntry?
        var ledgerReadable = false
        if case let .known(value) = lookup {
            entry = value
            ledgerReadable = true
        }
        let readState = SGCallRecordingStore.shared.readState(id: id)
        let condition: SGCallRecordingSidecarCondition
        var item: SGCallRecordingItem?
        switch readState {
        case let .available(value):
            item = value
            condition = .readable(hasSendRecord: value.send != nil)
        case .unreadable:
            condition = .lockedUnreadable
        case .corrupt:
            condition = .corrupt
        case .missing, .deleted, .pendingAccountRemoval:
            condition = .gone
        }
        let inFlight = self.enqueuingIds.contains(id) || self.resolvingIds.contains(id)
        switch sgCallRecordingCancelDecision(sidecar: condition, ledgerReadable: ledgerReadable, hasLedgerEntry: entry != nil, inFlight: inFlight) {
        case .refuse:
            return false
        case .nothingToCancel:
            self.stopObserving(id: id)
            if self.statuses.removeValue(forKey: id) != nil {
                self.notifyChanged()
            }
            return true
        case .retireLedgerEntry:
            guard let entry else {
                return false
            }
            self.stopObserving(id: id)
            self.statuses[id] = nil
            self.notifyChanged()
            return self.beginRetirement(id: id, entry: entry, item: item, revertIfNotDurable: true)
        case .cancelRecord:
            guard let item, let record = item.send else {
                return false
            }
            let merged = self.mergedRecord(record, entry: entry)
            if self.removedAccountPeerIds.contains(merged.accountPeerId) {
                // `accountRemoved` already discarded what it could and purged the ledger; writing
                // anything for that account now would bring its facts back.
                self.stopObserving(id: id)
                SGCallRecordingStore.shared.setSendRecord(id: id, nil)
                self.statuses[id] = nil
                self.notifyChanged()
                return true
            }
            if self.contexts.isEmpty {
                // The account list has not been delivered yet, so "signed out" is not knowable.
                return false
            }
            self.stopObserving(id: id)
            var retiring = self.entry(record: merged, base: entry, origin: nil)
            retiring.isRetiring = true
            guard self.ledger.set(recordingId: id, retiring) else {
                // Not durable: undo it in memory too, so nothing discards the upload of a recording
                // the user was just told was NOT deleted.
                self.ledger.set(recordingId: id, entry)
                return false
            }
            // Its own failure is safe: every caller of a true return deletes the sidecar.
            SGCallRecordingStore.shared.setSendRecord(id: id, nil)
            self.statuses[id] = nil
            self.notifyChanged()
            self.runRetirement(id: id, entry: retiring, item: item)
            return true
        }
    }

    /// Cancels every unacknowledged delivery. Used by "Delete All Recordings" and the full reset.
    /// Visible deliveries go through `cancelSend`; every remaining ledger entry (a recording whose
    /// sidecar cannot be read right now) is retired too. False when anything could not be cancelled.
    @discardableResult
    public func cancelAllSends() -> Bool {
        assert(Thread.isMainThread)
        self.pendingAutoSend.removeAll()
        var all = true
        for (id, _) in SGCallRecordingStore.shared.pendingSends() {
            if !self.cancelSend(id: id) {
                all = false
            }
        }
        if all {
            all = self.retireAllEntries()
        }
        return all
    }

    // MARK: - Queueing

    private func sendAutomatically(context: AccountContext, id: String) {
        switch SGCallRecordingStore.shared.readState(id: id) {
        case .unreadable:
            // The common case the intent exists for: the call ended with the device locked.
            return
        case .missing, .deleted, .corrupt, .pendingAccountRemoval:
            self.pendingAutoSend.removeValue(forKey: id)
            return
        case let .available(item):
            if item.send != nil {
                self.pendingAutoSend.removeValue(forKey: id)
                self.advance(id: id)
                return
            }
            // No account fallback: a recording that does not name its account is never automatic.
            guard let owner = item.accountPeerId, !self.removedAccountPeerIds.contains(owner) else {
                self.pendingAutoSend.removeValue(forKey: id)
                return
            }
            let ownerContext = context.account.peerId.toInt64() == owner ? context : self.contexts[owner]
            guard let ownerContext else {
                self.pendingAutoSend.removeValue(forKey: id)
                return
            }
            switch sgCallRecordingAutoSendDecision(accountPeerId: item.accountPeerId, peerId: item.peerId, privacy: self.privacy(of: item)) {
            case .never:
                self.pendingAutoSend.removeValue(forKey: id)
            case .wait:
                break
            case .send:
                if self.writeRecord(item: item, destination: ownerContext, exportAuthorized: false, isAutomatic: true) {
                    self.pendingAutoSend.removeValue(forKey: id)
                }
            }
        }
    }

    /// THE RECORD IS WRITTEN BEFORE ANYTHING IS ENQUEUED — ledger first, then sidecar. Either write
    /// failing means nothing is enqueued.
    private func writeRecord(item: SGCallRecordingItem, destination: AccountContext, exportAuthorized: Bool, isAutomatic: Bool) -> Bool {
        let id = item.id
        // A retirement still pending for this recording owns the ledger entry.
        switch self.ledger.lookup(recordingId: id) {
        case .unavailable:
            return false
        case let .known(entry):
            if let entry, entry.isRetiring {
                self.beginRetirement(id: id, entry: entry, item: item, revertIfNotDurable: false)
                return false
            }
        }
        var legs: [SGCallRecordingSendLeg] = []
        for path in item.audioPaths {
            legs.append(SGCallRecordingSendLeg(fileName: (path as NSString).lastPathComponent, correlationId: Int64.random(in: Int64.min ... Int64.max)))
        }
        let record = SGCallRecordingSendRecord(accountPeerId: destination.account.peerId.toInt64(), legs: legs)
        let origin = EntryOrigin(accountRecordId: destination.account.id.int64, exportAuthorized: exportAuthorized, isAutomatic: isAutomatic, isOwnerlessRecording: item.accountPeerId == nil)
        guard self.writeLedger(id: id, record: record, origin: origin) else {
            return false
        }
        guard SGCallRecordingStore.shared.setSendRecord(id: id, record) else {
            // Nothing was enqueued; drop this attempt's facts but keep earlier attempts' cache ids.
            self.ledger.update(recordingId: id) { current in
                guard var current else {
                    return nil
                }
                current.retiredCorrelationIds = current.retiredCorrelationIds.filter { retired in !record.legs.contains(where: { $0.correlationId == retired }) }
                current.legs = []
                current.legCount = 0
                return current.retiredCorrelationIds.isEmpty ? nil : current
            }
            return false
        }
        self.statuses[id] = .waiting
        self.notifyChanged()
        self.advance(id: id)
        return true
    }

    /// Moves one recording's delivery as far forward as it can go right now. Safe to call at any
    /// time: it re-reads the sidecar and the ledger.
    func advance(id: String) {
        let readState = SGCallRecordingStore.shared.readState(id: id)
        switch readState {
        case .unreadable, .corrupt:
            // NOT a missing record (audit #70): nothing is sent, nothing is retired on its own, and
            // whatever is already on its way keeps being watched from the ledger so an
            // acknowledgement arriving now is not lost (#68).
            if case .corrupt = readState, case let .known(entry?) = self.ledger.lookup(recordingId: id) {
                // A corrupt sidecar can never prove privacy again: no upload of it may (re)start.
                // A merely locked one keeps the allowance proven earlier in this process.
                self.revokeUploads(correlationIds: entry.allCorrelationIds)
            }
            self.observeFromLedger(id: id)
            return
        case .missing, .deleted, .pendingAccountRemoval:
            self.stopObserving(id: id)
            self.pendingAutoSend.removeValue(forKey: id)
            if self.statuses.removeValue(forKey: id) != nil {
                self.notifyChanged()
            }
            // A recording that is gone must not keep uploading from the media-box copy.
            if case let .known(entry?) = self.ledger.lookup(recordingId: id) {
                self.beginRetirement(id: id, entry: entry, item: nil, revertIfNotDurable: false)
            }
            return
        case let .available(item):
            let lookupEntry: SGCallRecordingDeliveryEntry?
            if case let .known(value) = self.ledger.lookup(recordingId: id) {
                lookupEntry = value
            } else {
                lookupEntry = nil
            }
            guard let sidecarRecord = item.send else {
                self.stopObserving(id: id)
                if self.statuses.removeValue(forKey: id) != nil {
                    self.notifyChanged()
                }
                // The record went (a withdrawal whose ledger update did not land): messages the
                // ledger still names must not keep uploading.
                if let entry = lookupEntry, entry.isRetiring || !entry.unacknowledgedLocalMessageIds.isEmpty {
                    self.beginRetirement(id: id, entry: entry, item: item, revertIfNotDurable: false)
                }
                return
            }
            let effective = self.effectiveRecord(id: id, sidecarRecord)
            let record = effective.record
            if let entry = effective.entry, entry.isRetiring {
                // Cancelled, withdrawn or finished durably while the sidecar kept its record. The
                // cancellation wins; nothing is sent or re-observed.
                self.stopObserving(id: id)
                SGCallRecordingStore.shared.setSendRecord(id: id, nil)
                self.beginRetirement(id: id, entry: entry, item: item, revertIfNotDurable: false)
                return
            }
            // FINISHING COMES FIRST, because it needs no account: every leg is acknowledged.
            if record.isConfirmed {
                self.finish(id: id, record: record, entry: effective.entry)
                return
            }
            guard let context = self.liveContext(accountPeerId: record.accountPeerId, accountRecordId: effective.entry?.accountRecordId) else {
                if self.removedAccountPeerIds.contains(record.accountPeerId) {
                    self.stopObserving(id: id)
                }
                // Not signed in (yet), or another database. The record and the audio stay on disk.
                return
            }
            if record != sidecarRecord {
                // Facts the ledger learned while the sidecar was unreadable, written back now. A
                // failure is harmless: the ledger still holds them and every path merges it.
                _ = SGCallRecordingStore.shared.setSendRecord(id: id, record)
            }
            let anyEnqueued = record.legs.contains(where: { $0.localMessageId != nil || $0.cloudMessageId != nil })
            if sgCallRecordingAutoOffWithdraws(isAutomatic: effective.entry?.isAutomatic ?? false, autoSendEnabled: self.autoSendEnabled, anyLegEnqueued: anyEnqueued) {
                self.withdraw(id: id, record: record)
                return
            }
            // What is already in flight is revalidated too: the other party may have been vaulted or
            // locked since an unauthorized (named) export was queued.
            let privacy = self.privacy(of: item)
            let exportAuthorized = effective.entry?.exportAuthorized ?? false
            let inFlight = record.legs.contains(where: { $0.localMessageId != nil && $0.cloudMessageId == nil })
            if inFlight, sgCallRecordingInFlightDecision(privacy: privacy, exportAuthorized: exportAuthorized) == .withdraw {
                self.withdrawInFlight(id: id, record: record, entry: effective.entry, item: item)
                return
            }
            // The native upload gate's allowance follows CURRENT proof only: owner live (checked
            // above) and privacy open, or protected with this recording's own grant. Without it —
            // including an unverifiable verdict after a locked relaunch — nothing is allowed, a
            // restarted upload is denied, and the leg is re-sent once proof returns.
            if sgCallRecordingUploadMayRun(privacy: privacy, exportAuthorized: exportAuthorized) && effective.entry?.accountRecordId != nil {
                for leg in record.legs where leg.cloudMessageId == nil && leg.localMessageId != nil {
                    self.allowUpload(context: context, correlationId: leg.correlationId, fileName: leg.fileName, localMessageId: leg.localMessageId)
                }
            } else {
                self.revokeUploads(correlationIds: record.legs.map { $0.correlationId })
            }
            if !record.isEnqueued && effective.ledgerKnown {
                // A leg with no known local id is enqueued only when the ledger could be READ: an
                // unreadable ledger may hold the id of a message that already exists.
                self.enqueue(context: context, item: item, record: record, entry: effective.entry)
            }
            // An observer started before proof was back (a locked relaunch: sidecar unreadable,
            // protection unknown) already reported the denied leg's failed message and will not
            // report it again — that message does not change when proof returns. Restarted only
            // when a leg it watches has JUST become re-sendable under the allowance granted above;
            // the restart's first report re-runs `handle`, which re-checks everything at use.
            if self.observers[id] != nil {
                var watched: [SGCallRecordingGateDeniedLeg] = []
                for (index, leg) in record.legs.enumerated() where leg.cloudMessageId == nil && leg.localMessageId != nil && !self.abandonedCorrelationIds.contains(leg.correlationId) {
                    watched.append(self.gateDeniedLeg(leg, legIndex: index, entry: effective.entry))
                }
                if sgCallRecordingUploadGateState.denialRecovery.observerMustReevaluate(watched) {
                    self.stopObserving(id: id)
                }
            }
            self.observe(context: context, id: id, record: record, item: item)
        }
    }

    private func enqueue(context: AccountContext, item: SGCallRecordingItem, record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?) {
        let id = item.id
        if self.enqueuingIds.contains(id) || self.resolvingIds.contains(id) {
            return
        }
        // REVALIDATED HERE, which can be hours after the record was written — privacy, and for an
        // automatic delivery the setting, read now. The provenance is the ledger entry `advance` just
        // read (the only place it is recorded; `enqueue` runs only when the ledger is readable). An
        // entry that is missing even so is not known to be manual: it is treated as automatic.
        let neutral: Bool
        switch sgCallRecordingEnqueueDecision(privacy: self.privacy(of: item), exportAuthorized: entry?.exportAuthorized ?? false, isAutomatic: entry?.isAutomatic ?? true, autoSendEnabled: self.autoSendEnabled) {
        case .wait:
            return
        case .withdraw:
            self.withdraw(id: id, record: record)
            return
        case let .enqueue(value):
            neutral = value
        }
        let store = SGCallRecordingStore.shared
        let lang = SGSimpleSettings.shared.languageCode

        var messages: [EnqueueMessage] = []
        var legIndices: [Int] = []
        var adopted: [Int: Int32] = [:]
        var unbuildable = false
        for (index, leg) in record.legs.enumerated() {
            if leg.localMessageId != nil || leg.cloudMessageId != nil {
                continue
            }
            if self.refusedCorrelationIds.contains(leg.correlationId) {
                unbuildable = true
                continue
            }
            // BEFORE SENDING ANYTHING, ASK WHETHER IT ALREADY WENT.
            if let cloudId = self.confirmedCloudMessageId(context: context, correlationId: leg.correlationId) {
                adopted[index] = cloudId
                continue
            }
            guard let path = store.path(forAudioFileName: leg.fileName), FileManager.default.fileExists(atPath: path) else {
                self.refusedCorrelationIds.insert(leg.correlationId)
                unbuildable = true
                continue
            }
            // A finished recording is `.complete`: while locked it cannot be opened. Wait for the
            // first unlock rather than hand the uploader a file it cannot copy.
            guard sgCallRecordingFileIsReadable(atPath: path) else {
                continue
            }
            guard let message = self.message(item: item, record: record, legIndex: index, path: path, lang: lang, neutral: neutral) else {
                self.refusedCorrelationIds.insert(leg.correlationId)
                unbuildable = true
                continue
            }
            messages.append(message)
            legIndices.append(index)
        }
        if unbuildable && self.statuses[id] != .failed {
            self.statuses[id] = .failed
            self.notifyChanged()
        }
        if !adopted.isEmpty {
            var updated = record
            for (index, cloudId) in adopted where index < updated.legs.count {
                updated.legs[index].cloudMessageId = cloudId
            }
            // NOTHING ELSE HAPPENS UNTIL THE ACKNOWLEDGEMENT IS DURABLE — in the ledger at least.
            guard self.writeLedger(id: id, record: updated, origin: nil) else {
                return
            }
            _ = store.setSendRecord(id: id, updated)
            if messages.isEmpty {
                self.advance(id: id)
                return
            }
        }
        if messages.isEmpty {
            return
        }

        // Saved Messages IS the account's own peer. Nothing else is ever a destination here.
        let peerId = context.account.peerId
        let accountPeerId = peerId.toInt64()
        let correlations = legIndices.map { record.legs[$0].correlationId }
        // The gate answers `false` at once for an unknown resource, so the allowance must be
        // published BEFORE the message exists. Not yet bound to a local id: none is known yet.
        for legIndex in legIndices {
            self.allowUpload(context: context, correlationId: record.legs[legIndex].correlationId, fileName: record.legs[legIndex].fileName, localMessageId: nil)
        }
        self.enqueuingIds.insert(id)
        let _ = (enqueueMessages(account: context.account, peerId: peerId, messages: messages)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] messageIds in
            guard let self else {
                return
            }
            self.enqueuingIds.remove(id)
            var returned: [Int: Int32] = [:]
            for (offset, legIndex) in legIndices.enumerated() {
                guard offset < messageIds.count, let messageId = messageIds[offset] else {
                    // No message to watch: not retried in this process (no hot loop), "not sent".
                    self.refusedCorrelationIds.insert(record.legs[legIndex].correlationId)
                    self.revokeUploads(correlationIds: [record.legs[legIndex].correlationId])
                    self.statuses[id] = .failed
                    continue
                }
                returned[legIndex] = messageId.id
            }
            if self.removedAccountPeerIds.contains(accountPeerId) {
                // The account was removed while this was in flight: what was just queued goes, and
                // nothing is written back for it.
                self.revokeUploads(correlationIds: correlations)
                let _ = self.discardAndClean(context: context, localMessageIds: Array(returned.values), cloudMessageIds: [], correlationIds: correlations, knownGloballyUniqueIds: [], ownedFiles: nil).startStandalone()
                return
            }
            // THE LOCAL IDS ARE THE CANCELLATION HANDLE. The ledger first: it stays writable while
            // the device is locked, the sidecar does not.
            var withIds = record
            for (legIndex, localMessageId) in returned where legIndex < withIds.legs.count {
                withIds.legs[legIndex].localMessageId = localMessageId
            }
            self.writeLedger(id: id, record: withIds, origin: nil)
            // The allowance is now bound to the exact local id (and Retry copies after it) — only
            // if it still exists: a revocation while enqueuing must not be undone here.
            for (legIndex, localMessageId) in returned where legIndex < withIds.legs.count {
                self.rebindUpload(correlationId: withIds.legs[legIndex].correlationId, localMessageId: localMessageId)
            }
            if var updated = store.sendRecord(id: id) {
                for (legIndex, localMessageId) in returned where legIndex < updated.legs.count && updated.legs[legIndex].correlationId == record.legs[legIndex].correlationId {
                    updated.legs[legIndex].localMessageId = localMessageId
                }
                _ = store.setSendRecord(id: id, updated)
            }
            // The persistent acknowledgement proof, recorded now rather than at the first
            // observation, so a kill before that does not lose it.
            self.recordGloballyUniqueIds(context: context, id: id, legs: returned.map { (legIndex: $0.key, correlationId: record.legs[$0.key].correlationId, localMessageId: $0.value) })
            self.notifyChanged()
            self.stopObserving(id: id)
            self.advance(id: id)
        }, completed: { [weak self] in
            // `enqueueMessages` always emits; this belt keeps cancellation from being blocked for the
            // life of the process.
            self?.enqueuingIds.remove(id)
        })
    }

    /// The record goes before any of it was handed to Telegram: the recording stays local. Used when
    /// the other party became protected after an unauthorized send was queued, and when an
    /// automatic record outlives the setting being turned off.
    private func withdraw(id: String, record: SGCallRecordingSendRecord) {
        if record.legs.contains(where: { $0.localMessageId != nil || $0.cloudMessageId != nil }) {
            return
        }
        self.pendingAutoSend.removeValue(forKey: id)
        // Also covers an enqueue still in flight for this record: its upload is denied.
        self.revokeUploads(correlationIds: record.legs.map { $0.correlationId })
        guard SGCallRecordingStore.shared.setSendRecord(id: id, nil) else {
            return
        }
        // Nothing of this attempt was enqueued; earlier attempts' cache ids are kept for cleanup.
        self.ledger.update(recordingId: id) { current in
            guard var current else {
                return nil
            }
            current.legs = []
            current.legCount = 0
            return current.retiredCorrelationIds.isEmpty ? nil : current
        }
        self.stopObserving(id: id)
        self.statuses[id] = nil
        self.notifyChanged()
    }

    /// An unauthorized export is in flight and its verdict is no longer `open`: the unacknowledged
    /// messages (which name the other party) are discarded and their cache copies removed, the audio
    /// is KEPT and the record withdrawn. An acknowledged half of a pre-mix pair cannot be recalled.
    private func withdrawInFlight(id: String, record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?, item: SGCallRecordingItem) {
        self.revokeUploads(correlationIds: record.legs.map { $0.correlationId })
        self.stopObserving(id: id)
        self.pendingAutoSend.removeValue(forKey: id)
        var retiring = self.entry(record: record, base: entry, origin: nil)
        retiring.isRetiring = true
        if !self.ledger.set(recordingId: id, retiring), let context = self.liveContext(accountPeerId: record.accountPeerId, accountRecordId: entry?.accountRecordId) {
            // Not durable: still stop the upload in this process.
            let _ = self.discardAndClean(context: context, localMessageIds: retiring.unacknowledgedLocalMessageIds, cloudMessageIds: [], correlationIds: retiring.allCorrelationIds, knownGloballyUniqueIds: retiring.knownGloballyUniqueIds, ownedFiles: self.ownedFiles(item: item)).startStandalone()
        }
        SGCallRecordingStore.shared.setSendRecord(id: id, nil)
        self.statuses[id] = nil
        self.notifyChanged()
        self.runRetirement(id: id, entry: retiring, item: item)
    }

    // MARK: - Confirmation

    /// Watches every leg that has not been acknowledged yet, by the LOCAL id.
    private func observe(context: AccountContext, id: String, record: SGCallRecordingSendRecord, item: SGCallRecordingItem?) {
        var legs: [(Int, Int32)] = []
        for (index, leg) in record.legs.enumerated() where leg.cloudMessageId == nil && !self.abandonedCorrelationIds.contains(leg.correlationId) {
            if let localMessageId = leg.localMessageId {
                legs.append((index, localMessageId))
            }
        }
        if self.onlyDeadLegsRemain(record), self.statuses[id] != .failed {
            // Nothing left to watch and something did not arrive: the honest state is "not sent".
            self.statuses[id] = .failed
            self.notifyChanged()
        }
        self.observe(context: context, id: id, legs: legs, ownedFiles: self.ownedFiles(item: item))
    }

    /// Every leg not acknowledged was abandoned or refused in this process.
    func onlyDeadLegsRemain(_ record: SGCallRecordingSendRecord) -> Bool {
        let unconfirmed = record.legs.filter { $0.cloudMessageId == nil }
        return !unconfirmed.isEmpty && unconfirmed.allSatisfy { self.abandonedCorrelationIds.contains($0.correlationId) || self.refusedCorrelationIds.contains($0.correlationId) }
    }

    /// The sidecar cannot be read: watch what the ledger says is on its way, so an acknowledgement
    /// that lands now is recorded there instead of lost.
    private func observeFromLedger(id: String) {
        guard self.observers[id] == nil, case let .known(entry?) = self.ledger.lookup(recordingId: id), !entry.isRetiring else {
            return
        }
        guard let context = self.liveContext(accountPeerId: entry.accountPeerId, accountRecordId: entry.accountRecordId) else {
            return
        }
        var legs: [(Int, Int32)] = []
        for facts in entry.legs where facts.cloudMessageId == nil && !self.abandonedCorrelationIds.contains(facts.correlationId) {
            if let localMessageId = facts.localMessageId {
                legs.append((facts.legIndex, localMessageId))
            }
        }
        self.observe(context: context, id: id, legs: legs, ownedFiles: nil)
    }

    private func observe(context: AccountContext, id: String, legs: [(Int, Int32)], ownedFiles: (directory: String, fileNames: [String])?) {
        if self.observers[id] != nil || self.resolvingIds.contains(id) || legs.isEmpty {
            return
        }
        let peerId = context.account.peerId
        var signals: [Signal<(Int, EngineMessage?), NoError>] = []
        for (index, localMessageId) in legs {
            let messageId = EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: localMessageId)
            signals.append(context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> map { message -> (Int, EngineMessage?) in
                return (index, message)
            })
        }
        let disposable = (combineLatest(signals)
        |> deliverOnMainQueue).startStrict(next: { [weak self] values in
            self?.handle(context: context, id: id, values: values, ownedFiles: ownedFiles)
        })
        self.observers[id] = Observer(accountPeerId: peerId.toInt64(), disposable: disposable)
    }

    /// The record `handle` works from: the sidecar merged with the ledger, or — while the sidecar is
    /// unreadable or corrupt — the ledger alone. nil means the recording is gone or being retired.
    func workingRecord(id: String) -> (record: SGCallRecordingSendRecord, sidecarReadable: Bool, entry: SGCallRecordingDeliveryEntry?)? {
        switch SGCallRecordingStore.shared.readState(id: id) {
        case let .available(item):
            guard let record = item.send else {
                return nil
            }
            let effective = self.effectiveRecord(id: id, record)
            if effective.entry?.isRetiring == true {
                return nil
            }
            return (effective.record, true, effective.entry)
        case .unreadable, .corrupt:
            guard case let .known(entry?) = self.ledger.lookup(recordingId: id), !entry.isRetiring else {
                return nil
            }
            return (self.ledgerOnlyRecord(entry), false, entry)
        case .missing, .deleted, .pendingAccountRemoval:
            return nil
        }
    }

    private func handle(context: AccountContext, id: String, values: [(Int, EngineMessage?)], ownedFiles: (directory: String, fileNames: [String])?) {
        if self.removedAccountPeerIds.contains(context.account.peerId.toInt64()) {
            self.stopObserving(id: id)
            return
        }
        guard let working = self.workingRecord(id: id) else {
            self.stopObserving(id: id)
            self.advance(id: id)
            return
        }
        var record = working.record
        var gids: [Int: Int64] = [:]
        var gateDenials: [Int: Bool] = [:]
        var vanished: [Int] = []
        var anyFailed = false
        var gateDenied: [Int] = []
        var changed = false
        let recovery = sgCallRecordingUploadGateState.denialRecovery

        for (index, message) in values {
            guard index < record.legs.count, record.legs[index].cloudMessageId == nil else {
                continue
            }
            let correlationId = record.legs[index].correlationId
            if let message {
                // A message at our local id that does not carry our own upload is NOT ours (another
                // database, a reused id): it proves nothing and is never trusted.
                guard sgCallRecordingMessageIsOwned(message, correlationIds: [correlationId], ownedFiles: ownedFiles) else {
                    vanished.append(index)
                    continue
                }
                let facts = working.entry?.facts(legIndex: index, correlationId: correlationId)
                let failed = message.flags.contains(.Failed)
                // The gate's denial is written down as soon as it shows (the ledger stays writable
                // while locked), so a kill before proof returns does not make it an ordinary failure.
                let durablyDenied = facts?.uploadGateDenied ?? false
                let denial = recovery.durableDenial(correlationId: correlationId, current: durablyDenied, messageFailed: failed)
                if denial != durablyDenied {
                    gateDenials[index] = denial
                }
                // Still local: queued, uploading, waiting for a network, or failed. The file stays.
                if failed {
                    anyFailed = true
                    if recovery.shouldResend(self.gateDeniedLeg(record.legs[index], legIndex: index, entry: working.entry, durablyDenied: denial), messageFailed: true, sidecarReadable: working.sidecarReadable) {
                        gateDenied.append(index)
                    }
                }
                let known = facts?.globallyUniqueId
                if let gid = message.globallyUniqueId, gid != known {
                    gids[index] = gid
                }
                continue
            }
            if let cloudId = self.confirmedCloudMessageId(context: context, correlationId: correlationId) {
                record.legs[index].cloudMessageId = cloudId
                changed = true
            } else {
                vanished.append(index)
            }
        }

        // Durable before anything else is decided: ledger first, then the sidecar if it can be opened.
        if changed || !gids.isEmpty || !gateDenials.isEmpty {
            self.writeLedger(id: id, record: record, origin: nil, gids: gids, gateDenials: gateDenials)
            if changed && working.sidecarReadable {
                _ = SGCallRecordingStore.shared.setSendRecord(id: id, record)
            }
        }

        if !gateDenied.isEmpty {
            // The gate denied these before proof was back (a locked relaunch); it is back now.
            self.resendGateDeniedLegs(context: context, id: id, record: record, entry: working.entry, legIndices: gateDenied, item: nil)
            return
        }
        if !vanished.isEmpty {
            self.stopObserving(id: id)
            self.resolveVanishedLegs(context: context, id: id, record: record, entry: working.entry, legIndices: vanished)
            return
        }
        let status: SGCallRecordingSendStatus = (anyFailed || self.onlyDeadLegsRemain(record)) ? .failed : .waiting
        if self.statuses[id] != status {
            self.statuses[id] = status
            self.notifyChanged()
        }
        if record.isConfirmed && working.sidecarReadable {
            self.finish(id: id, record: record, entry: working.entry)
        }
    }

    /// THE IN-PROCESS CONFIRMATION: our correlation id mapped to the id the server returned, only
    /// for a message the server accepted, in the cloud namespace of this account's Saved Messages.
    func confirmedCloudMessageId(context: AccountContext, correlationId: Int64) -> Int32? {
        guard let messageId = context.engine.messages.synchronouslyLookupCorrelationId(correlationId: correlationId) else {
            return nil
        }
        guard messageId.namespace == Namespaces.Message.Cloud, messageId.peerId == context.account.peerId else {
            return nil
        }
        return messageId.id
    }

    /// Every leg acknowledged: the recording exists in Saved Messages, so the local copy goes —
    /// audio and sidecar — and then the upload's media-cache copy. The retiring mark must be ON DISK
    /// before the store deletes anything, or the cache cleanup could be lost to a kill; when it
    /// cannot be, the audio simply stays until a later pass.
    private func finish(id: String, record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?) {
        self.revokeUploads(correlationIds: record.legs.map { $0.correlationId })
        self.stopObserving(id: id)
        self.pendingAutoSend.removeValue(forKey: id)
        if self.removedAccountPeerIds.contains(record.accountPeerId) {
            // Nothing is written for a removed account; its cache goes with its own cleanup.
            if SGCallRecordingStore.shared.delete(id: id) {
                self.statuses[id] = nil
                self.notifyChanged()
            }
            return
        }
        var retiring = self.entry(record: record, base: entry, origin: nil)
        retiring.isRetiring = true
        guard self.ledger.set(recordingId: id, retiring) else {
            self.ledger.set(recordingId: id, entry)
            return
        }
        guard SGCallRecordingStore.shared.delete(id: id) else {
            // Not gone yet: put the entry back the way it was and retry on the next pass.
            retiring.isRetiring = false
            self.ledger.set(recordingId: id, retiring)
            return
        }
        self.statuses[id] = nil
        self.notifyChanged()
        self.runRetirement(id: id, entry: retiring, item: nil)
    }

    // MARK: - Ledger plumbing

    /// The record as it TRULY stands: the sidecar plus every fact the ledger learned. EVERYTHING
    /// THAT CANCELS OR RE-SENDS MUST GO THROUGH THIS. `ledgerKnown` false means the ledger could not
    /// be read: no decision may treat a missing local id as "never enqueued".
    func effectiveRecord(id: String, _ record: SGCallRecordingSendRecord) -> (record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?, ledgerKnown: Bool) {
        switch self.ledger.lookup(recordingId: id) {
        case .unavailable:
            return (record, nil, false)
        case let .known(entry):
            return (self.mergedRecord(record, entry: entry), entry, true)
        }
    }

    func mergedRecord(_ record: SGCallRecordingSendRecord, entry: SGCallRecordingDeliveryEntry?) -> SGCallRecordingSendRecord {
        let states = record.legs.map { SGCallRecordingDeliveryLegState(correlationId: $0.correlationId, localMessageId: $0.localMessageId, cloudMessageId: $0.cloudMessageId) }
        let merged = sgCallRecordingMergedLegs(sidecar: states, ledger: entry)
        var result = record
        for index in result.legs.indices where index < merged.count {
            result.legs[index].localMessageId = merged[index].localMessageId
            result.legs[index].cloudMessageId = merged[index].cloudMessageId
        }
        return result
    }

    /// A record reconstructed from the ledger alone. File names are unknown and not needed: it is
    /// only ever observed and confirmed, never enqueued or finished. A leg the ledger has no facts
    /// for becomes a placeholder that is never written back.
    func ledgerOnlyRecord(_ entry: SGCallRecordingDeliveryEntry) -> SGCallRecordingSendRecord {
        var legs: [SGCallRecordingSendLeg] = []
        for index in 0 ..< max(entry.legCount, 0) {
            if let facts = entry.legs.first(where: { $0.legIndex == index }) {
                legs.append(SGCallRecordingSendLeg(fileName: "", correlationId: facts.correlationId, localMessageId: facts.localMessageId, cloudMessageId: facts.cloudMessageId))
            } else {
                legs.append(SGCallRecordingSendLeg(fileName: "", correlationId: 0))
            }
        }
        return SGCallRecordingSendRecord(accountPeerId: entry.accountPeerId, legs: legs)
    }

    private func isLedgerPlaceholder(_ leg: SGCallRecordingSendLeg) -> Bool {
        return leg.fileName.isEmpty && leg.correlationId == 0 && leg.localMessageId == nil && leg.cloudMessageId == nil
    }

    /// The ledger entry describing `record` on top of `base`. `origin` (a new attempt) sets the
    /// account binding and provenance; `gids` sets a leg's globallyUniqueId, `gateDenials` its
    /// durable gate-denial mark.
    func entry(record: SGCallRecordingSendRecord, base: SGCallRecordingDeliveryEntry?, origin: EntryOrigin?, gids: [Int: Int64] = [:], gateDenials: [Int: Bool] = [:]) -> SGCallRecordingDeliveryEntry {
        var entry = base ?? SGCallRecordingDeliveryEntry(accountPeerId: record.accountPeerId, exportAuthorized: false, legCount: record.legs.count, legs: [])
        entry.accountPeerId = record.accountPeerId
        entry.legCount = record.legs.count
        if let origin {
            entry.accountRecordId = origin.accountRecordId
            entry.exportAuthorized = origin.exportAuthorized
            entry.isAutomatic = origin.isAutomatic
            entry.isOwnerlessRecording = origin.isOwnerlessRecording
            entry.isRetiring = false
        }
        for (index, leg) in record.legs.enumerated() where !self.isLedgerPlaceholder(leg) {
            entry = entry.updatingLeg(legIndex: index, correlationId: leg.correlationId) { current in
                var facts = current
                if let localMessageId = leg.localMessageId {
                    facts.localMessageId = localMessageId
                }
                if let cloudMessageId = leg.cloudMessageId {
                    facts.cloudMessageId = cloudMessageId
                }
                if let gid = gids[index] {
                    facts.globallyUniqueId = gid
                }
                if let denied = gateDenials[index] {
                    facts.uploadGateDenied = denied
                }
                return facts
            }
        }
        entry.legs = entry.legs.filter { $0.legIndex < record.legs.count }
        return entry
    }

    /// Writes `record`'s facts into the ledger. Returns whether they are on disk. NOTHING is written
    /// for a removed account — that would bring back facts `accountRemoved` just purged.
    @discardableResult
    func writeLedger(id: String, record: SGCallRecordingSendRecord, origin: EntryOrigin?, gids: [Int: Int64] = [:], gateDenials: [Int: Bool] = [:]) -> Bool {
        if self.removedAccountPeerIds.contains(record.accountPeerId) {
            return false
        }
        return self.ledger.update(recordingId: id) { current in
            return self.entry(record: record, base: current, origin: origin, gids: gids, gateDenials: gateDenials)
        }
    }

    /// Records globallyUniqueIds for legs of the attempt they were enqueued for — only for messages
    /// that are ours, and only on facts whose correlation id still matches.
    private func recordGloballyUniqueIds(context: AccountContext, id: String, legs: [(legIndex: Int, correlationId: Int64, localMessageId: Int32)]) {
        if legs.isEmpty {
            return
        }
        let peerId = context.account.peerId
        let ids = Set(legs.map { EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: $0.localMessageId) })
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Messages(ids: ids))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] messages in
            guard let self, !self.removedAccountPeerIds.contains(peerId.toInt64()) else {
                return
            }
            var found: [(Int, Int64, Int64)] = []
            for leg in legs {
                let messageId = EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Local, id: leg.localMessageId)
                guard let message = messages[messageId], let gid = message.globallyUniqueId, sgCallRecordingMessageIsOwned(message, correlationIds: [leg.correlationId], ownedFiles: nil) else {
                    continue
                }
                found.append((leg.legIndex, leg.correlationId, gid))
            }
            if found.isEmpty {
                return
            }
            self.ledger.update(recordingId: id) { current in
                guard var current, !current.isRetiring else {
                    return current
                }
                for (legIndex, correlationId, gid) in found where current.facts(legIndex: legIndex, correlationId: correlationId) != nil {
                    current = current.updatingLeg(legIndex: legIndex, correlationId: correlationId) { facts in
                        var facts = facts
                        facts.globallyUniqueId = gid
                        return facts
                    }
                }
                return current
            }
        })
    }

    func stopObserving(id: String) {
        if let observer = self.observers.removeValue(forKey: id) {
            observer.disposable.dispose()
        }
    }

    func notifyChanged() {
        self.version += 1
        self.versionPromise.set(self.version)
    }
}

/// Used when Application Support cannot be resolved: no durable facts, never "unreadable".
private final class SGCallRecordingDeliveryNoLedgerStorage: SGCallRecordingDeliveryLedgerStorage {
    private var marker = false

    func read() -> SGCallRecordingDeliveryLedgerReadResult {
        return .absent
    }

    func write(_ data: Data) -> Bool {
        return false
    }

    func readMarker() -> Bool {
        return self.marker
    }

    func writeMarker(_ present: Bool) -> Bool {
        self.marker = present
        return false
    }
}
