// MARK: Zenlygram — call recording delivery: the decisions, as pure functions.
//
// Everything here is a function of plain values so the rules can be tested without an account, a
// Postbox or a recording on disk. `SGCallRecordingDelivery` maps the real inputs onto these types.

import Foundation

/// Whether the other party of a recording may be named or exported, as established from the
/// RECORDED account and peer (never the account on screen).
public enum SGCallRecordingDeliveryPrivacy: Equatable {
    /// Not vaulted, not locked, and the verdict could be established.
    case open
    /// Vaulted or Chat-Locked for the recording's own account.
    case protected
    /// The verdict cannot be established: identity unknown (legacy sidecar) while protection is
    /// configured, or the protection snapshot is unreadable right now.
    case unverifiable
}

// MARK: - Automatic path

public enum SGCallRecordingAutoSendDecision: Equatable {
    case send
    /// Not now, but possibly later in this process (the protection snapshot was unreadable).
    case wait
    /// Never automatically.
    case never
}

/// The automatic path. Fail closed: it needs the recording's own account AND peer, and an `open`
/// verdict for them. A recording with no peer id is never sent automatically, whatever protection
/// says — "unknown identity" is not "unprotected".
public func sgCallRecordingAutoSendDecision(accountPeerId: Int64?, peerId: Int64?, privacy: SGCallRecordingDeliveryPrivacy) -> SGCallRecordingAutoSendDecision {
    guard accountPeerId != nil, peerId != nil else {
        return .never
    }
    switch privacy {
    case .open:
        return .send
    case .protected:
        return .never
    case .unverifiable:
        return .wait
    }
}

/// An automatic record nothing of which has been handed to Telegram yet is withdrawn as soon as the
/// setting is off: turning it off promises that nothing more is uploaded on its own.
public func sgCallRecordingAutoOffWithdraws(isAutomatic: Bool, autoSendEnabled: Bool, anyLegEnqueued: Bool) -> Bool {
    return isAutomatic && !autoSendEnabled && !anyLegEnqueued
}

// MARK: - Manual path

/// Local authorization the recordings list established for exporting ONE protected recording:
/// bound to that recording's own account and peer, so it cannot be replayed for another.
public struct SGCallRecordingExportGrant: Equatable {
    public let accountPeerId: Int64
    public let peerId: Int64

    public init(accountPeerId: Int64, peerId: Int64) {
        self.accountPeerId = accountPeerId
        self.peerId = peerId
    }
}

/// Whether `grant` was issued for exactly this recording's (account, peer). An identity that is not
/// fully known can never be matched.
public func sgCallRecordingExportGrantMatches(_ grant: SGCallRecordingExportGrant?, accountPeerId: Int64?, peerId: Int64?) -> Bool {
    guard let grant, let accountPeerId, let peerId else {
        return false
    }
    return grant.accountPeerId == accountPeerId && grant.peerId == peerId
}

/// What a tap on "Send to Saved Messages" came to. The list shows something for every case but
/// `queued` / `alreadyInProgress`.
public enum SGCallRecordingManualSendResult: Equatable {
    case queued
    /// A delivery is already on its way; nothing new was queued.
    case alreadyInProgress
    /// Protected recording without a matching grant: establish local authorization, then retry.
    case requiresAuthorization
    /// Never exportable from here: unverifiable identity, a live recording, or gone.
    case refused
    /// The account that made it (or that it was queued for) is not signed in.
    case accountUnavailable
    /// Could not be recorded on disk right now (locked, full): nothing was queued.
    case failed
}

public enum SGCallRecordingManualSendDecision: Equatable {
    /// `exportAuthorized` is what the delivery records for the later revalidations.
    case send(exportAuthorized: Bool)
    case requiresAuthorization
    case refused
}

/// `grantMatches` is `sgCallRecordingExportGrantMatches` for this recording; only honoured for
/// `.protected`.
public func sgCallRecordingManualSendDecision(privacy: SGCallRecordingDeliveryPrivacy, grantMatches: Bool) -> SGCallRecordingManualSendDecision {
    switch privacy {
    case .open:
        return .send(exportAuthorized: false)
    case .protected:
        return grantMatches ? .send(exportAuthorized: true) : .requiresAuthorization
    case .unverifiable:
        // There is no proof to establish, so no authorization can stand in for it.
        return .refused
    }
}

// MARK: - Revalidation

public enum SGCallRecordingEnqueueDecision: Equatable {
    /// Build the message; `neutral` means no peer name in caption, file name or audio title.
    case enqueue(neutral: Bool)
    /// Not now; the record stays as it is.
    case wait
    /// The record must be withdrawn before anything is enqueued.
    case withdraw
}

/// Immediately before a message is built, which can be hours after the record was written. Privacy
/// decides first: a protected recording without this recording's grant is withdrawn and an
/// unverifiable one waits, whatever the setting. Then a NEW message of an AUTOMATIC delivery waits
/// while "Send to Saved Messages" is off — a legacy pair with one leg already handed to Telegram is
/// never withdrawn by the setting, and neither is a re-send record saved just before a kill, so
/// this is the last admission for them. A manual delivery is not affected.
public func sgCallRecordingEnqueueDecision(privacy: SGCallRecordingDeliveryPrivacy, exportAuthorized: Bool, isAutomatic: Bool, autoSendEnabled: Bool) -> SGCallRecordingEnqueueDecision {
    let decision: SGCallRecordingEnqueueDecision
    switch privacy {
    case .open:
        decision = .enqueue(neutral: false)
    case .protected:
        decision = exportAuthorized ? .enqueue(neutral: true) : .withdraw
    case .unverifiable:
        decision = .wait
    }
    if case .enqueue = decision, isAutomatic && !autoSendEnabled {
        return .wait
    }
    return decision
}

public enum SGCallRecordingInFlightDecision: Equatable {
    case keep
    /// Discard the unacknowledged messages (which names the other party unless authorized), keep
    /// the audio, withdraw the record.
    case withdraw
}

/// For legs already handed to Telegram and not acknowledged. Fail closed: an unauthorized export
/// whose verdict is no longer `open` is withdrawn — including `unverifiable`, because what is in
/// flight names the other party.
public func sgCallRecordingInFlightDecision(privacy: SGCallRecordingDeliveryPrivacy, exportAuthorized: Bool) -> SGCallRecordingInFlightDecision {
    switch privacy {
    case .open:
        return .keep
    case .protected, .unverifiable:
        return exportAuthorized ? .keep : .withdraw
    }
}

/// Whether TelegramCore's upload gate may let this recording's legs through right now. Requires
/// CURRENT proof: `open`, or `protected` with this recording's own grant. `unverifiable` (an
/// unreadable protection snapshot, e.g. after a locked relaunch) never may — the restarted upload
/// is denied and re-sent once proof returns.
public func sgCallRecordingUploadMayRun(privacy: SGCallRecordingDeliveryPrivacy, exportAuthorized: Bool) -> Bool {
    switch privacy {
    case .open:
        return true
    case .protected:
        return exportAuthorized
    case .unverifiable:
        return false
    }
}

// MARK: - Cancellation

/// The recording's sidecar as the cancellation sees it.
public enum SGCallRecordingSidecarCondition: Equatable {
    case readable(hasSendRecord: Bool)
    /// Exists, cannot be opened right now (locked).
    case lockedUnreadable
    /// Read but undecodable; will never become readable.
    case corrupt
    /// Deleted, missing, or pending account removal.
    case gone
}

public enum SGCallRecordingCancelDecision: Equatable {
    /// Do not delete: something may be in flight that this cannot see or stop right now.
    case refuse
    /// Nothing of this build's delivery exists for it.
    case nothingToCancel
    /// Retire the ledger entry (discard its local messages and cache copies), then delete.
    case retireLedgerEntry
    /// Readable sidecar with a record: cancel that record (ledger-merged), then delete.
    case cancelRecord
}

/// Every record this build writes is in the ledger BEFORE the sidecar, so a READABLE ledger with no
/// entry proves this build has nothing in flight for the recording, whatever the sidecar says.
public func sgCallRecordingCancelDecision(sidecar: SGCallRecordingSidecarCondition, ledgerReadable: Bool, hasLedgerEntry: Bool, inFlight: Bool) -> SGCallRecordingCancelDecision {
    if inFlight || !ledgerReadable {
        return .refuse
    }
    switch sidecar {
    case let .readable(hasSendRecord):
        if hasSendRecord {
            return .cancelRecord
        }
        return hasLedgerEntry ? .retireLedgerEntry : .nothingToCancel
    case .lockedUnreadable, .corrupt, .gone:
        return hasLedgerEntry ? .retireLedgerEntry : .nothingToCancel
    }
}

/// Ledger keys whose recording no longer exists (and that are not already retiring).
public func sgCallRecordingOrphanLedgerKeys(entries: [String: SGCallRecordingDeliveryEntry], knownRecordingIds: Set<String>) -> [String] {
    let knownKeys = Set(knownRecordingIds.map { SGCallRecordingDeliveryLedger.key(recordingId: $0) })
    return entries.compactMap { key, entry in
        (!entry.isRetiring && !knownKeys.contains(key)) ? key : nil
    }.sorted()
}

/// Recordings whose sidecar cannot be read (locked) or decoded (corrupt) but whose delivery the
/// ledger says is on its way: a readable ledger entry, not retiring, with an unacknowledged local
/// message. `resumeAll` advances exactly these too, so a cold start while locked watches them from
/// the ledger (an acknowledgement or a gate denial is recorded) instead of not at all. Advancing
/// such a recording grants nothing — the locked branch only observes, the corrupt one also revokes;
/// the owner, account database and removal are re-checked there. `entries` nil (ledger unreadable)
/// means nothing. Each id at most once, in input order.
public func sgCallRecordingLedgerOnlyResumeIds(sidecars: [(id: String, condition: SGCallRecordingSidecarCondition)], entries: [String: SGCallRecordingDeliveryEntry]?) -> [String] {
    guard let entries else {
        return []
    }
    var seen = Set<String>()
    var result: [String] = []
    for (id, condition) in sidecars {
        switch condition {
        case .lockedUnreadable, .corrupt:
            break
        case .readable, .gone:
            continue
        }
        guard let entry = entries[SGCallRecordingDeliveryLedger.key(recordingId: id)], !entry.isRetiring, entry.legs.contains(where: { $0.cloudMessageId == nil && $0.localMessageId != nil }) else {
            continue
        }
        if seen.insert(id).inserted {
            result.append(id)
        }
    }
    return result
}

// MARK: - Legs

/// A leg as the sidecar records it, reduced to what the confirmation logic needs.
public struct SGCallRecordingDeliveryLegState: Equatable {
    public var correlationId: Int64
    public var localMessageId: Int32?
    public var cloudMessageId: Int32?

    public init(correlationId: Int64, localMessageId: Int32?, cloudMessageId: Int32?) {
        self.correlationId = correlationId
        self.localMessageId = localMessageId
        self.cloudMessageId = cloudMessageId
    }
}

/// The legs as they TRULY stand: the sidecar plus whatever the ledger learned. A fact is applied
/// only to the leg with the same index AND correlation id. A cloud id is never removed and a cloud
/// id from the ledger always wins over a local one. A ledger local id wins over the sidecar's: every
/// local id is written to the ledger FIRST, so the ledger is never older — and after Telegram's
/// Retry the leg is re-bound to the replacement message, which the sidecar may not have taken.
public func sgCallRecordingMergedLegs(sidecar: [SGCallRecordingDeliveryLegState], ledger: SGCallRecordingDeliveryEntry?) -> [SGCallRecordingDeliveryLegState] {
    guard let ledger else {
        return sidecar
    }
    var result = sidecar
    for index in result.indices {
        guard let facts = ledger.facts(legIndex: index, correlationId: result[index].correlationId) else {
            continue
        }
        if result[index].cloudMessageId == nil, let cloudId = facts.cloudMessageId {
            result[index].cloudMessageId = cloudId
        }
        if result[index].cloudMessageId == nil, let localId = facts.localMessageId {
            result[index].localMessageId = localId
        }
    }
    return result
}

/// What became of a leg whose local message disappeared, in order of evidence strength.
public enum SGCallRecordingLegResolution: Equatable {
    /// The server acknowledged it: this is the cloud id.
    case confirmed(cloudMessageId: Int32)
    /// Telegram's own Retry replaced it (same owned media resource).
    case rebound(localMessageId: Int32, globallyUniqueId: Int64?)
    /// No evidence either way.
    case abandoned
}

/// The namespace a message id resolved to, from the delivery's point of view.
public enum SGCallRecordingResolvedMessage: Equatable {
    case cloud(id: Int32)
    case local(id: Int32)
    /// Resolved to another chat or namespace (scheduled, quick reply): not "in Saved Messages".
    case other
}

public func sgCallRecordingResolveLeg(
    correlationCloudId: Int32?,
    globallyUniqueIdResolution: SGCallRecordingResolvedMessage?,
    retryReplacement: (localMessageId: Int32, globallyUniqueId: Int64?)?,
    vanishedLocalMessageId: Int32?
) -> SGCallRecordingLegResolution {
    if let correlationCloudId {
        return .confirmed(cloudMessageId: correlationCloudId)
    }
    switch globallyUniqueIdResolution {
    case let .some(.cloud(id)):
        return .confirmed(cloudMessageId: id)
    case let .some(.local(id)) where id != vanishedLocalMessageId:
        return .rebound(localMessageId: id, globallyUniqueId: nil)
    default:
        break
    }
    if let retryReplacement, retryReplacement.localMessageId != vanishedLocalMessageId {
        return .rebound(localMessageId: retryReplacement.localMessageId, globallyUniqueId: retryReplacement.globallyUniqueId)
    }
    return .abandoned
}

/// How many local ids after a known one are searched for Telegram's Retry replacement. Local ids are
/// allocated per chat, so this is "the next N messages queued to Saved Messages".
public let sgCallRecordingRetryScanWindow: Int32 = 256

/// The local ids searched after `localMessageId`, without overflowing.
public func sgCallRecordingRetryScanIds(after localMessageId: Int32, window: Int32 = sgCallRecordingRetryScanWindow) -> [Int32] {
    guard window > 0, localMessageId < Int32.max else {
        return []
    }
    let upper = localMessageId > Int32.max - window ? Int32.max : localMessageId + window
    return Array((localMessageId + 1) ... upper)
}

// MARK: - Ownership

/// The media resource `randomId` a leg's upload uses. Derived from the correlation id (itself a
/// fresh random 64-bit value per attempt) so the resource — and therefore its media-cache copy — is
/// identifiable from the record alone, after a relaunch, and across Telegram's Retry, which keeps
/// the message's media as is.
public func sgCallRecordingResourceRandomId(correlationId: Int64) -> Int64 {
    return correlationId
}

/// Whether `path` is exactly `fileName` inside `directory`. Compares standardized paths
/// component-wise, so neither `..` nor a sibling directory sharing a prefix can pass.
public func sgCallRecordingIsOwnedAudioPath(_ path: String, directory: String, fileName: String) -> Bool {
    guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
        return false
    }
    let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let expected = URL(fileURLWithPath: directory).appendingPathComponent(fileName).standardizedFileURL.resolvingSymlinksInPath().pathComponents
    return !candidate.isEmpty && candidate == expected
}

/// A local-file resource found on a message.
public struct SGCallRecordingLocalResource: Equatable {
    public let randomId: Int64
    public let path: String

    public init(randomId: Int64, path: String) {
        self.randomId = randomId
        self.path = path
    }
}

/// THE OWNERSHIP TEST for a local message: outgoing, and carrying one of this delivery's own upload
/// resources — derived from one of `correlationIds`, or (records written before the derivation) a
/// path that is exactly one of the recording's own audio files. A bare local id proves nothing: it
/// only means something inside one account database, and nothing is deleted or trusted on it alone.
public func sgCallRecordingIsOwnedMessage(isIncoming: Bool, resources: [SGCallRecordingLocalResource], correlationIds: [Int64], ownedDirectory: String?, ownedFileNames: [String]) -> Bool {
    if isIncoming {
        return false
    }
    let randomIds = Set(correlationIds.map { sgCallRecordingResourceRandomId(correlationId: $0) })
    for resource in resources {
        if randomIds.contains(resource.randomId) {
            return true
        }
        if let ownedDirectory, ownedFileNames.contains(where: { sgCallRecordingIsOwnedAudioPath(resource.path, directory: ownedDirectory, fileName: $0) }) {
            return true
        }
    }
    return false
}
