import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

// SG: retention engine for the fork's local-only message data (Batch 6).
//
// Kept-deleted messages ("Show Deleted Messages", SGSimpleSettings.showDeletedMessages)
// - When the server deletes a message that passes the keep policy (sgShouldRetain), the message is
//   stamped with DeletedMessageAttribute(schema: 1) instead of being deleted. Postbox indexes the
//   stamp under sgKeptDeletedTimestampTag at deletionTimestamp + 30 days (no UserDefaults I/O on
//   the replay path; the old UserDefaults registry is only read once by the legacy migration).
// - At most sgKeptDeletedMaxCountPerAccount are kept per account (oldest removed when stamping).
// - The sweeper deletes stamps older than 30 days and every stamp made before
//   SGSimpleSettings.keptDeletedPurgeBefore (the persisted "turn off and delete" request).
// - Channel posts are never kept, and a supergroup replay that removes sgKeptDeletedChannelBulkThreshold
//   messages of one group, or sgKeptDeletedChannelAuthorBulkThreshold messages of one author in it, is
//   treated as moderation / anti-spam and keeps nothing of that group (audit #18 / review finding #6):
//   content an admin or Telegram removed must not be re-published as "Deleted message" bubbles.
//
// Edit history (SGSimpleSettings.editHistoryEnabled, on by default: registered default + the
// migrated_captureDefaultsOnV1 migration in SimpleSettings.swift; a stored off choice is kept)
// - Captured only while enabled, at most sgEditedMessageHistoryMaxRevisions per message, each
//   revision stamped with its local capture time and indexed under sgEditHistoryTimestampTag.
// - The sweeper rewrites histories dropping revisions older than 30 days or captured before
//   SGSimpleSettings.editHistoryPurgeBefore. An empty result is written as a tombstone because
//   mergeMessageAttributes (sgMergeForkMessageAttributes) restores an attribute removed by omission.
//
// Invariant: no destructive purge is ever derived from a Bool setting (UserDefaults can read as
// false before first unlock). Purges are driven only by the 30-day TTL and the persisted
// *PurgeBefore timestamps (0 = none). Local wall clock only (sgRetentionNow).
// The one exception is the legacy migration's purgeKept: the "Show Deleted" flag is read in the same
// locked section as the legacy marker, whose successful read proves the store readable
// (SGSimpleSettings.legacyRetentionKeptDisabled); an absent marker means "restamp".
// The explicit purge APIs (sgRemoveKeptDeletedMessages, sgDeleteAllEditHistory) only touch data
// stamped/captured at or before the confirmation time.

/// DMs / basic groups: a replay that removes this many local messages of one peer is treated as a
/// history clear, not as someone deleting a message (owner decision D2).
private let sgKeptDeletedBulkThreshold = 50
/// Supergroups: a replay that removes this many local messages of one group is treated as a moderation
/// or anti-spam sweep (an admin or Telegram removing someone's messages), not as single deletions, and
/// nothing of that group is kept from the replay (#6; default pending the owner's confirmation).
private let sgKeptDeletedChannelBulkThreshold = 10
/// Supergroups: the same for this many messages of ONE author removed in one replay ("delete all from
/// user" and spam cleanups name few messages in small groups, but always several of one author).
private let sgKeptDeletedChannelAuthorBulkThreshold = 3
/// Messages per transaction for the sweeper and the explicit purge API.
private let sgRetentionSweepBatchLimit = 256
private let sgRetentionPurgeBatchLimit = 500
/// Messages scanned per transaction by the one-time legacy migration.
private let sgRetentionMigrationChunkLimit = 200
/// Tags a kept-deleted message must not carry (pins, unread mentions/reactions/votes it can no longer clear).
private let sgKeptDeletedStrippedTags: MessageTags = [.pinned, .unseenPersonalMessage, .unseenReaction, .unseenPollVote]

private let sgServiceNotificationsPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(777000))

// MARK: - Helpers

/// Rebuilds a stored message from `message` with new attributes and tags (everything else unchanged).
func sgStoreMessage(from message: Message, attributes: [MessageAttribute], tags: MessageTags) -> StoreMessage {
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: message.author?.id, text: message.text, attributes: attributes, media: message.media)
}

/// Peers the per-replay "clear-like" rule applies to: DMs and basic groups (D2) and supergroups /
/// channels (#6). Secret chats and everything else never reach the keep policy.
private func sgIsClearLikeCandidatePeer(_ peerId: PeerId) -> Bool {
    return peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudChannel
}

/// Per-replay view of the delete operations, used for the "clear-like" rule.
/// DMs / basic groups (D2): if one replay removes any local OUTGOING message of a peer, or at least
/// sgKeptDeletedBulkThreshold local messages of it, nothing of that peer is kept (a history clear
/// from another device or by the peer, not a single deletion by someone else).
/// Supergroups (#6): if one replay removes at least sgKeptDeletedChannelBulkThreshold local messages of
/// a group, or sgKeptDeletedChannelAuthorBulkThreshold messages of one author in it, nothing of that
/// group is kept (an admin or Telegram anti-spam removing someone's messages). An outgoing message in
/// the replay means nothing there: deleting one's own message in a group is routine and says nothing
/// about the other deletions. Broadcast channels never reach the keep policy (sgShouldRetain).
/// Semantics (owner rule D2, a history clear removes what it names): every id a clear-like replay names
/// is deleted exactly as upstream would delete it, even when it is an already-kept copy. The replay
/// hooks therefore skip clear-like peers before reading their messages (no further getMessage).
final class SGDeletionReplayContext {
    private let operations: [AccountStateMutationOperation]
    private var clearLikePeerIds: Set<PeerId>?

    init(operations: [AccountStateMutationOperation]) {
        self.operations = operations
    }

    /// Computes the clear-like peers once. Called by the replay helpers before their first
    /// retain/delete decision, i.e. before any delete operation of the replay touched the database.
    func prepare(transaction: Transaction) {
        if self.clearLikePeerIds != nil {
            return
        }
        var seen = Set<MessageId>()
        var counts: [PeerId: Int] = [:]
        // Supergroup -> author -> messages of that author the replay removes.
        var authorCounts: [PeerId: [PeerId: Int]] = [:]
        var clearLike = Set<PeerId>()
        let visit: (MessageId) -> Void = { id in
            if id.namespace != Namespaces.Message.Cloud || !sgIsClearLikeCandidatePeer(id.peerId) {
                return
            }
            if seen.contains(id) {
                return
            }
            seen.insert(id)
            // Already decided: the remaining ids of this peer need no message read.
            if clearLike.contains(id.peerId) {
                return
            }
            guard let message = transaction.getMessage(id) else {
                return
            }
            let count = (counts[id.peerId] ?? 0) + 1
            counts[id.peerId] = count
            if id.peerId.namespace == Namespaces.Peer.CloudChannel {
                // Supergroup (#6): volume and per-author volume only, no outgoing-message condition.
                if count >= sgKeptDeletedChannelBulkThreshold {
                    clearLike.insert(id.peerId)
                    return
                }
                if let authorId = message.author?.id {
                    let authorCount = (authorCounts[id.peerId]?[authorId] ?? 0) + 1
                    authorCounts[id.peerId, default: [:]][authorId] = authorCount
                    if authorCount >= sgKeptDeletedChannelAuthorBulkThreshold {
                        clearLike.insert(id.peerId)
                    }
                }
                return
            }
            if !message.flags.contains(.Incoming) {
                clearLike.insert(id.peerId)
            }
            if count >= sgKeptDeletedBulkThreshold {
                clearLike.insert(id.peerId)
            }
        }
        for operation in self.operations {
            switch operation {
            case let .DeleteMessages(ids):
                for id in ids {
                    visit(id)
                }
            case let .DeleteMessagesWithGlobalIds(globalIds):
                for id in transaction.messageIdsForGlobalIds(globalIds) {
                    visit(id)
                }
            default:
                break
            }
        }
        self.clearLikePeerIds = clearLike
    }

    func isClearLike(peerId: PeerId, transaction: Transaction) -> Bool {
        self.prepare(transaction: transaction)
        return self.clearLikePeerIds?.contains(peerId) ?? false
    }
}

/// Keep policy (the flag is checked by the callers). The protocol does not say who deleted a
/// message, so this keeps only incoming messages of others, never in chats where the user can
/// delete everyone's messages, and never for system/ephemeral content.
private func sgShouldRetain(message: Message, transaction: Transaction, accountPeerId: PeerId, context: SGDeletionReplayContext?) -> Bool {
    let id = message.id
    let peerId = id.peerId
    // .DeleteMessages also carries ScheduledCloud / QuickReplyCloud ids.
    if id.namespace != Namespaces.Message.Cloud {
        return false
    }
    if peerId.namespace != Namespaces.Peer.CloudUser && peerId.namespace != Namespaces.Peer.CloudGroup && peerId.namespace != Namespaces.Peer.CloudChannel {
        return false
    }
    if peerId == accountPeerId || peerId.isRepliesOrVerificationCodes || peerId == sgServiceNotificationsPeerId {
        return false
    }
    if !message.flags.contains(.Incoming) {
        return false
    }
    if let author = message.author, author.id == accountPeerId {
        return false
    }
    for media in message.media {
        if media is TelegramMediaAction || media is TelegramMediaExpiredContent {
            return false
        }
    }
    for attribute in message.attributes {
        if attribute is AutoremoveTimeoutMessageAttribute || attribute is AutoclearTimeoutMessageAttribute {
            return false
        }
    }
    if message.containsSecretMedia {
        return false
    }
    if let peer = transaction.getPeer(peerId) {
        if let channel = peer as? TelegramChannel {
            // Channel posts are never kept (#6): the author is the channel itself, a deletion there is
            // editorial or moderation, and a kept copy would re-publish what the channel took down.
            if case .broadcast = channel.info {
                return false
            }
            if channel.hasPermission(.deleteAllMessages) {
                return false
            }
        } else if let group = peer as? TelegramGroup {
            switch group.role {
            case .creator, .admin:
                return false
            case .member:
                break
            }
        }
    }
    // The replay hooks already skip clear-like peers; kept for callers that pass a context without
    // that pre-check. History validation passes nil (no replay, so no clear-like rule: a supergroup
    // moderation sweep discovered only through channels.getMessages is still kept, a known limit).
    if sgIsClearLikeCandidatePeer(peerId), let context, context.isClearLike(peerId: peerId, transaction: transaction) {
        return false
    }
    return true
}

/// Stamps a message as kept-deleted (schema 1, indexed). Built from the CURRENT stored message.
private func sgStampKept(transaction: Transaction, id: MessageId, now: Int32) {
    transaction.updateMessage(id, update: { current in
        var attributes = current.attributes.filter { !($0 is DeletedMessageAttribute) }
        attributes.append(DeletedMessageAttribute(deletionTimestamp: now, schema: 1))
        return .update(sgStoreMessage(from: current, attributes: attributes, tags: current.tags.subtracting(sgKeptDeletedStrippedTags)))
    })
}

/// Enforces sgKeptDeletedMaxCountPerAccount (oldest stamps removed first).
func sgEnforceKeptCap(transaction: Transaction, mediaBox: MediaBox) {
    let count = transaction.sgTimestampBasedAttributeCount(tag: sgKeptDeletedTimestampTag)
    if count <= sgKeptDeletedMaxCountPerAccount {
        return
    }
    let entries = transaction.sgTimestampBasedAttributeEntries(tag: sgKeptDeletedTimestampTag, upTo: Int32.max, limit: count - sgKeptDeletedMaxCountPerAccount)
    var ids: [MessageId] = []
    for entry in entries {
        if sgIsKeptDeletedMessage(transaction.getMessage(entry.messageId)) {
            ids.append(entry.messageId)
        } else {
            transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: sgKeptDeletedTimestampTag)
        }
    }
    if !ids.isEmpty {
        _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: ids)
    }
    Logger.shared.log("SGRetention", "kept-deleted cap: removed \(ids.count) of \(count)")
}

// MARK: - Replay hooks (AccountStateManagementUtils.replayFinalState)

/// `.DeleteMessages`: stamps the messages the keep policy retains and returns the ids to really
/// delete (missing and not retained ones). Already-kept messages stay as they are, except in a
/// clear-like peer, where every named id is deleted like upstream (see SGDeletionReplayContext).
func sgRetainDeletedMessages(transaction: Transaction, mediaBox: MediaBox, accountPeerId: PeerId, ids: [MessageId], context: SGDeletionReplayContext) -> [MessageId] {
    if !SGSimpleSettings.shared.showDeletedMessages {
        return ids
    }
    context.prepare(transaction: transaction)
    // Paid mode without a grant stops NEW capture only (`sgRetentionMayCapture`); already-kept copies
    // below are still kept, never deleted by the gate.
    let mayCapture = sgRetentionMayCapture()
    let now = sgRetentionNow()
    var result: [MessageId] = []
    var stamped = false
    for id in ids {
        // Clear-like peer (D2 / supergroup moderation #6): delete as upstream, kept copies included,
        // without reading the message.
        if sgIsClearLikeCandidatePeer(id.peerId) && context.isClearLike(peerId: id.peerId, transaction: transaction) {
            result.append(id)
            continue
        }
        guard let message = transaction.getMessage(id) else {
            result.append(id)
            continue
        }
        if message.sgIsKeptDeleted {
            continue
        }
        if mayCapture && sgShouldRetain(message: message, transaction: transaction, accountPeerId: accountPeerId, context: context) {
            sgStampKept(transaction: transaction, id: id, now: now)
            stamped = true
        } else {
            result.append(id)
        }
    }
    if stamped {
        sgEnforceKeptCap(transaction: transaction, mediaBox: mediaBox)
    }
    return result
}

/// `.DeleteMessagesWithGlobalIds`: same as above; a global id is not deleted if any message it maps to
/// is kept. Messages of a clear-like peer never keep it (D2, see SGDeletionReplayContext).
func sgRetainDeletedMessagesWithGlobalIds(transaction: Transaction, mediaBox: MediaBox, accountPeerId: PeerId, globalIds: [Int32], context: SGDeletionReplayContext) -> [Int32] {
    if !SGSimpleSettings.shared.showDeletedMessages {
        return globalIds
    }
    context.prepare(transaction: transaction)
    let mayCapture = sgRetentionMayCapture()
    let now = sgRetentionNow()
    var result: [Int32] = []
    var stamped = false
    for globalId in globalIds {
        var retain = false
        for id in transaction.messageIdsForGlobalIds([globalId]) {
            // Clear-like peer (D2 / supergroup moderation #6): does not retain the global id, kept copies
            // included; no message read.
            if sgIsClearLikeCandidatePeer(id.peerId) && context.isClearLike(peerId: id.peerId, transaction: transaction) {
                continue
            }
            guard let message = transaction.getMessage(id) else {
                continue
            }
            if message.sgIsKeptDeleted {
                retain = true
            } else if mayCapture && sgShouldRetain(message: message, transaction: transaction, accountPeerId: accountPeerId, context: context) {
                sgStampKept(transaction: transaction, id: id, now: now)
                stamped = true
                retain = true
            }
        }
        if !retain {
            result.append(globalId)
        }
    }
    if stamped {
        sgEnforceKeptCap(transaction: transaction, mediaBox: mediaBox)
    }
    return result
}

/// History validation (#34): a message the server CONFIRMED as gone (channels.getMessages answered).
/// Returns true when the message is kept (the caller must skip the delete). Stamped with the
/// discovery time. Already-kept messages return true.
func sgRetainMessageRemovedByValidation(transaction: Transaction, mediaBox: MediaBox, accountPeerId: PeerId, id: MessageId) -> Bool {
    guard let message = transaction.getMessage(id) else {
        return false
    }
    if message.sgIsKeptDeleted {
        return true
    }
    if !SGSimpleSettings.shared.showDeletedMessages || !sgRetentionMayCapture() {
        return false
    }
    if !sgShouldRetain(message: message, transaction: transaction, accountPeerId: accountPeerId, context: nil) {
        return false
    }
    sgStampKept(transaction: transaction, id: id, now: sgRetentionNow())
    sgEnforceKeptCap(transaction: transaction, mediaBox: mediaBox)
    return true
}

/// Whether NEW retained history may be recorded right now: `SGEntitlementGatedAction.createRetainedHistoryRecord`,
/// mirrored into the app-group flag by the app and the Notification Service (`SGEntitlementRetainedHistoryCapture`),
/// since TelegramCore cannot link `SGEntitlement`. The stored sense is "blocked", so an absent key, an unreadable
/// suite and a device before first unlock read "may capture" — the free-first default. Read once per replay hook;
/// the user's own toggles and the keep policy (`sgShouldRetain`) still decide first, and already-retained records
/// are never read through this.
private func sgRetentionMayCapture() -> Bool {
    return !SGSimpleSettings.shared.editHistoryCaptureBlocked
}

// MARK: - Edit history

/// `.EditMessage` (#50): records the previous version when edit history is enabled and the text or
/// the non-webpage media changed. Drops expired/purged and legacy revisions, keeps the newest 20.
///
/// MARK: Zenlygram — recording a NEW revision is the create `createRetainedHistoryRecord` gates
/// (monetization policy `saved_history`), read here through `sgRetentionMayCapture`; revisions already
/// retained stay readable and are carried across re-saves by `sgMergeForkMessageAttributes`, and nothing
/// here ever deletes a revision on a billing event.
func sgCaptureEditHistory(previousMessage: Message, updatedText: String, updatedMedia: [Media], attributes: inout [MessageAttribute]) {
    if !SGSimpleSettings.shared.editHistoryEnabled || !sgRetentionMayCapture() || previousMessage.id.namespace != Namespaces.Message.Cloud {
        return
    }
    // Webpage previews are excluded: preview loading/updating is also delivered as EditMessage.
    let previousMedia = previousMessage.media.filter { !($0 is TelegramMediaWebpage) }
    let newMedia = updatedMedia.filter { !($0 is TelegramMediaWebpage) }
    if previousMessage.text == updatedText && previousMedia.map({ $0.id }) == newMedia.map({ $0.id }) {
        return
    }
    let now = sgRetentionNow()
    let previousAttribute = previousMessage.attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute
    var history = previousAttribute?.sgVisibleHistory(now: now, purgeBefore: SGSimpleSettings.shared.editHistoryPurgeBefore) ?? []
    let previousVersionTimestamp = (previousMessage.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? previousMessage.timestamp
    history.append(EditedMessageHistoryEntry(timestamp: previousVersionTimestamp, text: previousMessage.text, entities: previousMessage.textEntitiesAttribute?.entities ?? [], media: previousMedia, capturedAt: now))
    if history.count > sgEditedMessageHistoryMaxRevisions {
        history.removeFirst(history.count - sgEditedMessageHistoryMaxRevisions)
    }
    attributes.removeAll(where: { $0 is EditedMessageHistoryAttribute })
    attributes.append(EditedMessageHistoryAttribute(history: history))
}

/// Seed `mergeMessageAttributes` (#35): a server re-save of a message (reactions, bot keyboard,
/// file-reference revalidation, hole refill, validation) carries no fork attributes; keep the
/// current-format edit history. Pure and cheap: runs on every message update. Tombstones, legacy
/// history and DeletedMessageAttribute are deliberately NOT carried.
func sgMergeForkMessageAttributes(_ previous: [MessageAttribute], _ updated: inout [MessageAttribute]) {
    var previousHistory: EditedMessageHistoryAttribute?
    for attribute in previous {
        if let attribute = attribute as? EditedMessageHistoryAttribute {
            previousHistory = attribute
            break
        }
    }
    guard let previousHistory, previousHistory.isCurrentFormat else {
        return
    }
    for attribute in updated {
        if attribute is EditedMessageHistoryAttribute {
            return
        }
    }
    updated.append(previousHistory)
}

// MARK: - Sweeper

private final class SGRetentionSweepHelper {
    private var entry: (TimestampBasedMessageAttributesEntry, MetaDisposable)?

    func update(_ head: TimestampBasedMessageAttributesEntry?) -> (disposeOperations: [Disposable], beginOperations: [(TimestampBasedMessageAttributesEntry, MetaDisposable)]) {
        var disposeOperations: [Disposable] = []
        var beginOperations: [(TimestampBasedMessageAttributesEntry, MetaDisposable)] = []
        if self.entry?.0.index != head?.index {
            if let (_, disposable) = self.entry {
                self.entry = nil
                disposeOperations.append(disposable)
            }
            if let head {
                let disposable = MetaDisposable()
                self.entry = (head, disposable)
                beginOperations.append((head, disposable))
            }
        }
        return (disposeOperations, beginOperations)
    }

    func reset() -> [Disposable] {
        if let entry = self.entry {
            self.entry = nil
            return [entry.1]
        } else {
            return []
        }
    }
}

/// Index timestamps (stamp time + 30 days) at or below this value are due.
private func sgRetentionThreshold(now: Int32, purgeBefore: Int32) -> Int32 {
    return max(now, purgeBefore > 0 ? purgeBefore &+ sgRetentionMaxAgeSeconds : 0)
}

/// Watches the head of a retention index and processes due entries in batches. Each batch changes
/// the head (entries are deleted, rewritten or cleared), so the view re-emits and the loop continues.
private func sgManagedRetentionIndexSweep(postbox: Postbox, tag: UInt16, purgeBefore: @escaping () -> Int32, process: @escaping (Transaction, [TimestampBasedMessageAttributesEntry], Int32, Int32) -> Void) -> Signal<Void, NoError> {
    return Signal { _ in
        let helper = Atomic(value: SGRetentionSweepHelper())
        let disposable = postbox.timestampBasedMessageAttributesView(tag: tag).start(next: { view in
            let (disposeOperations, beginOperations) = helper.with { helper in
                return helper.update(view.head)
            }
            for disposable in disposeOperations {
                disposable.dispose()
            }
            for (head, headDisposable) in beginOperations {
                let now = sgRetentionNow()
                let delay: Double
                if head.timestamp <= sgRetentionThreshold(now: now, purgeBefore: purgeBefore()) {
                    delay = 0.0
                } else {
                    delay = Double(head.timestamp - now) + 1.0
                }
                // Minute granularity is plenty for a 30-day retention and avoids a 4 s wake-up timer.
                let signal = Signal<Void, NoError>.complete()
                |> suspendAwareDelay(delay, granularity: 60.0, queue: Queue.concurrentDefaultQueue())
                |> then(postbox.transaction { transaction -> Void in
                    let now = sgRetentionNow()
                    let currentPurgeBefore = purgeBefore()
                    // The head is due when this runs; never process less than it (timer jitter).
                    let threshold = max(sgRetentionThreshold(now: now, purgeBefore: currentPurgeBefore), head.timestamp)
                    let entries = transaction.sgTimestampBasedAttributeEntries(tag: tag, upTo: threshold, limit: sgRetentionSweepBatchLimit)
                    if !entries.isEmpty {
                        process(transaction, entries, now, currentPurgeBefore)
                    }
                })
                headDisposable.set(signal.start())
            }
        })
        return ActionDisposable {
            disposable.dispose()
            let disposables = helper.with { helper -> [Disposable] in
                return helper.reset()
            }
            for disposable in disposables {
                disposable.dispose()
            }
        }
    }
}

private func sgManagedKeptDeletedSweep(postbox: Postbox) -> Signal<Void, NoError> {
    return sgManagedRetentionIndexSweep(postbox: postbox, tag: sgKeptDeletedTimestampTag, purgeBefore: {
        return SGSimpleSettings.shared.keptDeletedPurgeBefore
    }, process: { transaction, entries, _, _ in
        var ids: [MessageId] = []
        var stale = 0
        for entry in entries {
            if let message = transaction.getMessage(entry.messageId), let attribute = message.attributes.first(where: { $0 is DeletedMessageAttribute }) as? DeletedMessageAttribute, attribute.automaticTimestampBasedAttribute?.1 == entry.timestamp {
                ids.append(entry.messageId)
            } else {
                // Stale entry (loop guard).
                transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: sgKeptDeletedTimestampTag)
                stale += 1
            }
        }
        if !ids.isEmpty {
            _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: ids)
        }
        Logger.shared.log("SGRetention", "kept-deleted sweep: deleted \(ids.count), cleared \(stale) stale index entries")
    })
}

private func sgManagedEditHistorySweep(postbox: Postbox) -> Signal<Void, NoError> {
    return sgManagedRetentionIndexSweep(postbox: postbox, tag: sgEditHistoryTimestampTag, purgeBefore: {
        return SGSimpleSettings.shared.editHistoryPurgeBefore
    }, process: { transaction, entries, now, purgeBefore in
        var rewritten = 0
        var stale = 0
        for entry in entries {
            guard let message = transaction.getMessage(entry.messageId), let attribute = message.attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute, attribute.automaticTimestampBasedAttribute?.1 == entry.timestamp else {
                transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: sgEditHistoryTimestampTag)
                stale += 1
                continue
            }
            // Evaluate at least at the entry's due time so its oldest revision is always dropped.
            let updatedAttribute = EditedMessageHistoryAttribute(history: attribute.sgVisibleHistory(now: max(now, entry.timestamp), purgeBefore: purgeBefore))
            if updatedAttribute.automaticTimestampBasedAttribute?.1 == entry.timestamp {
                // Nothing would change (loop guard).
                transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: sgEditHistoryTimestampTag)
                Logger.shared.log("SGRetention", "edit-history sweep: no-op rewrite for \(entry.messageId), index entry cleared")
                stale += 1
                continue
            }
            // Written as a tombstone when empty: removing the attribute by omission would be undone by the merge.
            transaction.updateMessage(entry.messageId, update: { current in
                var attributes = current.attributes.filter { !($0 is EditedMessageHistoryAttribute) }
                attributes.append(updatedAttribute)
                return .update(sgStoreMessage(from: current, attributes: attributes, tags: current.tags))
            })
            rewritten += 1
        }
        Logger.shared.log("SGRetention", "edit-history sweep: rewrote \(rewritten), cleared \(stale) stale index entries")
    })
}

// MARK: - Legacy migration (pre-Batch 6 builds)

/// One chunk of one peer (at most sgRetentionMigrationChunkLimit cloud messages, newest first, below
/// `before`; nil = from the newest): restamps legacy kept messages younger than 30 days as schema 1
/// (indexes them), deletes the other legacy kept messages and drops legacy (schema 0) edit history.
/// With `purgeKept` ("Show Deleted Messages" was off, see sgLegacyRetentionMigration) every legacy kept
/// message is deleted and none is restamped. Returns the cursor of the next chunk (nil = peer done).
private func sgMigrateLegacyRetention(transaction: Transaction, mediaBox: MediaBox, peerId: PeerId, before: MessageIndex?, purgeKept: Bool) -> (restamped: Int, deleted: Int, historyDropped: Int, next: MessageIndex?) {
    var legacyKept: [MessageId: Int32] = [:]
    var legacyHistory = Set<MessageId>()
    let next = transaction.sgScanMessageAttributes(peerId: peerId, namespace: Namespaces.Message.Cloud, before: before, limit: sgRetentionMigrationChunkLimit, { id, attributes in
        for attribute in attributes {
            if let attribute = attribute as? DeletedMessageAttribute, attribute.schema < 1 {
                legacyKept[id] = attribute.deletionTimestamp
            } else if let attribute = attribute as? EditedMessageHistoryAttribute, attribute.schema < 1 {
                legacyHistory.insert(id)
            }
        }
    })
    if legacyKept.isEmpty && legacyHistory.isEmpty {
        return (0, 0, 0, next)
    }

    let now = sgRetentionNow()
    var restamp: [MessageId: Int32] = [:]
    var deleteIds: [MessageId] = []
    for (id, deletionTimestamp) in legacyKept {
        if !purgeKept && deletionTimestamp > 0 && deletionTimestamp <= now + 60 && now - deletionTimestamp < sgRetentionMaxAgeSeconds {
            restamp[id] = deletionTimestamp
        } else {
            deleteIds.append(id)
        }
    }
    let deleteSet = Set(deleteIds)
    var historyDropped = 0
    for id in Set(restamp.keys).union(legacyHistory) {
        if deleteSet.contains(id) {
            continue
        }
        if legacyHistory.contains(id) {
            historyDropped += 1
        }
        let restampTimestamp = restamp[id]
        transaction.updateMessage(id, update: { current in
            var attributes: [MessageAttribute] = []
            for attribute in current.attributes {
                if let attribute = attribute as? EditedMessageHistoryAttribute, attribute.schema < 1 {
                    continue
                }
                if let attribute = attribute as? DeletedMessageAttribute, attribute.schema < 1 {
                    continue
                }
                attributes.append(attribute)
            }
            var tags = current.tags
            if let restampTimestamp {
                attributes.append(DeletedMessageAttribute(deletionTimestamp: restampTimestamp, schema: 1))
                tags.subtract(sgKeptDeletedStrippedTags)
            }
            return .update(sgStoreMessage(from: current, attributes: attributes, tags: tags))
        })
    }
    if !deleteIds.isEmpty {
        _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: deleteIds)
    }
    return (restamp.count, deleteIds.count, historyDropped, next)
}

/// Runs once on devices that ran a pre-Batch 6 build (legacy UserDefaults marker present). The base
/// build recorded schema-0 edit history for every user, so every chat is scanned; the scan is split
/// into bounded chunks, one transaction per chunk (sgRetentionMigrationChunkLimit messages), peer by
/// peer. The next chunk is queued only after the previous one completed, so other Postbox transactions
/// run in between. Then the cap, then the legacy UserDefaults state is removed. Interrupted runs restart
/// from scratch on the next launch (already migrated rows are skipped; each chunk stays bounded).
private func sgLegacyRetentionMigration(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let accountId = accountPeerId.toInt64()
    let migrate = Signal<Void, NoError> { subscriber in
        let disposable = MetaDisposable()
        let counters = Atomic<(restamped: Int, deleted: Int, historyDropped: Int)>(value: (0, 0, 0))
        // Decided once per run. true only when the marker and the flag were read together (same lock)
        // and "Show Deleted Messages" was off: the legacy kept copies are then deleted, not restamped.
        // nil (marker gone) or an unreadable store counts as false: restamp, the 30-day TTL still applies,
        // so no purge is ever derived from a Bool read that may predate first unlock.
        let purgeKept = SGSimpleSettings.shared.legacyRetentionKeptDisabled(accountId: accountId) == true
        Logger.shared.log("SGRetention", "legacy migration: \(purgeKept ? "Show Deleted off, deleting" : "restamping") legacy kept messages")

        func finish() {
            disposable.set((postbox.transaction { transaction -> Void in
                sgEnforceKeptCap(transaction: transaction, mediaBox: postbox.mediaBox)
            }).start(completed: {
                SGSimpleSettings.shared.removeLegacyRetentionState(accountId: accountId)
                let result = counters.with { $0 }
                Logger.shared.log("SGRetention", "legacy migration done: restamped \(result.restamped), deleted \(result.deleted), dropped \(result.historyDropped) legacy edit histories")
                subscriber.putCompletion()
            }))
        }

        // One chunk (peer `index`, below `cursor`) per transaction. Transactions complete asynchronously
        // on the Postbox queue, so this does not grow the stack.
        func step(_ peerIds: [PeerId], _ index: Int, _ cursor: MessageIndex?) {
            if index >= peerIds.count {
                finish()
                return
            }
            let peerId = peerIds[index]
            var nextCursor: MessageIndex?
            disposable.set((postbox.transaction { transaction -> (restamped: Int, deleted: Int, historyDropped: Int, next: MessageIndex?) in
                return sgMigrateLegacyRetention(transaction: transaction, mediaBox: postbox.mediaBox, peerId: peerId, before: cursor, purgeKept: purgeKept)
            }).start(next: { result in
                nextCursor = result.next
                let _ = counters.modify { current in
                    return (current.restamped + result.restamped, current.deleted + result.deleted, current.historyDropped + result.historyDropped)
                }
            }, completed: {
                if let nextCursor {
                    step(peerIds, index, nextCursor)
                } else {
                    step(peerIds, index + 1, nil)
                }
            }))
        }

        let legacyPeerIds = SGSimpleSettings.shared.legacyRetentionPeerIds(accountId: accountId)
        disposable.set((postbox.transaction { transaction -> [PeerId] in
            var peerIds = transaction.chatListGetAllPeerIds()
            var seen = Set(peerIds)
            for value in legacyPeerIds.sorted() {
                let peerId = PeerId(value)
                if !seen.contains(peerId) {
                    seen.insert(peerId)
                    peerIds.append(peerId)
                }
            }
            return peerIds
        }).start(next: { peerIds in
            step(peerIds, 0, nil)
        }))

        return disposable
    }
    return Signal<Void, NoError>.complete()
    |> suspendAwareDelay(10.0, queue: Queue.concurrentDefaultQueue())
    |> then(migrate)
}

/// Account.swift entry point (main app only): kept-deleted sweeper + edit-history sweeper + the
/// one-time legacy migration.
func sgManagedDeletedMessagesRetentionSweep(postbox: Postbox, accountPeerId: PeerId) -> Signal<Void, NoError> {
    return Signal { _ in
        let disposables = DisposableSet()
        disposables.add(sgManagedKeptDeletedSweep(postbox: postbox).start())
        disposables.add(sgManagedEditHistorySweep(postbox: postbox).start())
        if SGSimpleSettings.shared.hasLegacyRetentionState(accountId: accountPeerId.toInt64()) {
            disposables.add(sgLegacyRetentionMigration(postbox: postbox, accountPeerId: accountPeerId).start())
        }
        return disposables
    }
}

// MARK: - Public API (Settings / chat UI)

/// Number of indexed kept-deleted messages of the account (optionally of one chat).
public func sgKeptDeletedMessageCount(account: Account, peerId: EnginePeer.Id? = nil) -> Signal<Int, NoError> {
    return account.postbox.transaction { transaction -> Int in
        if let peerId {
            var count = 0
            for entry in transaction.sgTimestampBasedAttributeEntries(tag: sgKeptDeletedTimestampTag, upTo: Int32.max, limit: 0) {
                if entry.messageId.peerId == peerId {
                    count += 1
                }
            }
            return count
        } else {
            return transaction.sgTimestampBasedAttributeCount(tag: sgKeptDeletedTimestampTag)
        }
    }
}

/// Deletes every indexed kept-deleted message of the account (optionally of one chat) that was stamped
/// at or before the moment this function is called, at most sgRetentionPurgeBatchLimit per transaction,
/// until none is left. Emits the total deleted, then completes.
/// Callers build the signal inside their destructive-confirm action, so the call time is the confirmation
/// time: copies kept after the user confirmed (Show Deleted still on, new deletions arriving during the
/// purge) are not removed, and the loop cannot chase an ever-refilled index.
public func sgRemoveKeptDeletedMessages(account: Account, peerId: EnginePeer.Id? = nil) -> Signal<Int, NoError> {
    let postbox = account.postbox
    // Index value = deletionTimestamp + 30 days, so this selects exactly the copies stamped at or before `cutoff`.
    let cutoff = sgRetentionNow()
    let upTo = cutoff &+ sgRetentionMaxAgeSeconds
    func step(total: Int) -> Signal<Int, NoError> {
        return postbox.transaction { transaction -> (processed: Int, deleted: Int) in
            var entries: [TimestampBasedMessageAttributesEntry]
            if let peerId {
                entries = []
                for entry in transaction.sgTimestampBasedAttributeEntries(tag: sgKeptDeletedTimestampTag, upTo: upTo, limit: 0) {
                    if entry.messageId.peerId == peerId {
                        entries.append(entry)
                        if entries.count >= sgRetentionPurgeBatchLimit {
                            break
                        }
                    }
                }
            } else {
                entries = transaction.sgTimestampBasedAttributeEntries(tag: sgKeptDeletedTimestampTag, upTo: upTo, limit: sgRetentionPurgeBatchLimit)
            }
            // Every selected entry is either deleted with its message or cleared as stale, so each
            // transaction shrinks the selected range and the loop terminates.
            var ids: [MessageId] = []
            for entry in entries {
                if sgIsKeptDeletedMessage(transaction.getMessage(entry.messageId)) {
                    ids.append(entry.messageId)
                } else {
                    transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: sgKeptDeletedTimestampTag)
                }
            }
            if !ids.isEmpty {
                _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: ids)
            }
            return (entries.count, ids.count)
        }
        |> mapToSignal { result -> Signal<Int, NoError> in
            if result.processed == 0 {
                return .single(total)
            }
            return step(total: total + result.deleted)
        }
    }
    return step(total: 0)
}

/// Number of messages of the account with stored (indexed) edit history.
public func sgEditHistoryMessageCount(account: Account) -> Signal<Int, NoError> {
    return account.postbox.transaction { transaction -> Int in
        return transaction.sgTimestampBasedAttributeCount(tag: sgEditHistoryTimestampTag)
    }
}

/// Deletes the edit-history revisions of the account captured at or before the moment this function is
/// called, at most sgRetentionPurgeBatchLimit messages per transaction. Emits the number of messages
/// whose history was rewritten, then completes.
/// The caller builds the signal inside its destructive-confirm action (call time = confirmation time).
/// Revisions captured after that survive; a history left empty is written as a tombstone.
public func sgDeleteAllEditHistory(account: Account) -> Signal<Int, NoError> {
    let postbox = account.postbox
    // Index value = min(capturedAt) + 30 days: selects every history holding a revision captured at or before `cutoff`.
    let cutoff = sgRetentionNow()
    let upTo = cutoff &+ sgRetentionMaxAgeSeconds
    func step(total: Int) -> Signal<Int, NoError> {
        return postbox.transaction { transaction -> (processed: Int, cleared: Int) in
            let entries = transaction.sgTimestampBasedAttributeEntries(tag: sgEditHistoryTimestampTag, upTo: upTo, limit: sgRetentionPurgeBatchLimit)
            let now = sgRetentionNow()
            var cleared = 0
            for entry in entries {
                // Same loop guards as the sweeper: a stale entry, or a rewrite that would not move the
                // index, is cleared instead (otherwise it would be selected again forever).
                guard let message = transaction.getMessage(entry.messageId), let attribute = message.attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute, attribute.automaticTimestampBasedAttribute?.1 == entry.timestamp else {
                    transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: sgEditHistoryTimestampTag)
                    continue
                }
                // Drops every revision captured at or before `cutoff` (and expired ones). The rest keeps
                // an index above `upTo`, so it is not selected again; an empty result is a schema-1 tombstone.
                let updatedAttribute = EditedMessageHistoryAttribute(history: attribute.sgVisibleHistory(now: now, purgeBefore: cutoff))
                if updatedAttribute.automaticTimestampBasedAttribute?.1 == entry.timestamp {
                    transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: sgEditHistoryTimestampTag)
                    continue
                }
                transaction.updateMessage(entry.messageId, update: { current in
                    var attributes = current.attributes.filter { !($0 is EditedMessageHistoryAttribute) }
                    attributes.append(updatedAttribute)
                    return .update(sgStoreMessage(from: current, attributes: attributes, tags: current.tags))
                })
                cleared += 1
            }
            return (entries.count, cleared)
        }
        |> mapToSignal { result -> Signal<Int, NoError> in
            if result.processed == 0 {
                return .single(total)
            }
            return step(total: total + result.cleared)
        }
    }
    return step(total: 0)
}
