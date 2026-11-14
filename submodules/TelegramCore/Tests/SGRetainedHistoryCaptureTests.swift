import Foundation
import XCTest
import Postbox
import SwiftSignalKit
import SGSimpleSettings
@testable import TelegramCore

/// Zenlygram — retained message history on the real Postbox replay path
/// (`x-client-state.saved_history`). The app-group flag `SGSimpleSettings.editHistoryCaptureBlocked`
/// is the entitlement's only reach into TelegramCore (written by the app / the Notification Service
/// from `SGEntitlement`): while it is set, NO entrypoint records anything new — the delete replay, the
/// global-id delete replay, history validation and the edit replay — and every record retained before
/// stays readable and is never deleted by the gate. While it is clear (free mode, a paid grant, an
/// unknown decision) capture is subject only to the user's own toggles and the existing privacy rules.
/// The supergroup / channel cases (#6) pin the keep policy's moderation rules: channel posts are never
/// kept, and a supergroup replay removing many messages, or several of one author, keeps nothing.
final class SGRetainedHistoryCaptureTests: XCTestCase {
    private let accountPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1000))
    private let otherPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(2001))

    // Fixture ownership: ONE on-disk Postbox for the whole test process, opened on first use and never
    // closed or unlinked by the tests. Postbox has no public close/drain API, so a test cannot prove its
    // SQLite connection is gone before deleting the files. The previous fixture opened one Postbox per test
    // and deleted its directory in `tearDown` while that connection (and its deferred lifetime on the Postbox
    // queue) was still alive; the third setup then failed `PRAGMA journal_mode=WAL` (SqliteValueBox.swift:458).
    // The open subscription, the Postbox and its directory are therefore held until the process exits; the
    // directory lives in this test process's own temporary directory, which the runner's fresh simulator
    // discards. Every test uses its own message ids, so the cases do not interact through the shared store.
    private static var sharedPostbox: Postbox?
    private static var sharedOpenDisposable: Disposable?

    private var postbox: Postbox! {
        return SGRetainedHistoryCaptureTests.sharedPostbox
    }
    private var savedShowDeleted = false
    private var savedEditHistoryEnabled = false
    private var savedCaptureBlocked = false

    override func setUp() {
        super.setUp()
        initializeAccountManagement()

        let settings = SGSimpleSettings.shared
        self.savedShowDeleted = settings.showDeletedMessages
        self.savedEditHistoryEnabled = settings.editHistoryEnabled
        self.savedCaptureBlocked = settings.editHistoryCaptureBlocked
        settings.showDeletedMessages = true
        settings.editHistoryEnabled = true
        settings.editHistoryCaptureBlocked = false

        if SGRetainedHistoryCaptureTests.sharedPostbox == nil {
            self.openSharedPostbox()
        }
        XCTAssertNotNil(self.postbox, "premise: a real temporary Postbox")
    }

    override func tearDown() {
        let settings = SGSimpleSettings.shared
        settings.showDeletedMessages = self.savedShowDeleted
        settings.editHistoryEnabled = self.savedEditHistoryEnabled
        settings.editHistoryCaptureBlocked = self.savedCaptureBlocked
        super.tearDown()
    }

    private func openSharedPostbox() {
        let basePath = NSTemporaryDirectory() + "sg-retained-history-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        let opened = self.expectation(description: "postbox opened")
        let encryption = ValueBoxEncryptionParameters(
            forceEncryptionIfNoSet: false,
            key: ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32))!,
            salt: ValueBoxEncryptionParameters.Salt(data: Data(repeating: 9, count: 16))!
        )
        SGRetainedHistoryCaptureTests.sharedOpenDisposable = (openPostbox(
            basePath: basePath,
            seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: encryption,
            timestampForAbsoluteTimeBasedOperations: sgRetentionNow(),
            isMainProcess: true,
            isTemporary: false,
            isReadOnly: false,
            useCopy: false,
            useCaches: true,
            removeDatabaseOnError: true
        )
        |> filter { result in
            if case .postbox = result {
                return true
            }
            return false
        }
        |> take(1)).start(next: { result in
            if case let .postbox(postbox) = result {
                SGRetainedHistoryCaptureTests.sharedPostbox = postbox
            }
            opened.fulfill()
        })
        self.wait(for: [opened], timeout: 30.0)
    }

    // MARK: - Fixtures

    private func transaction<T>(_ f: @escaping (Transaction) -> T) -> T {
        var value: T?
        let done = self.expectation(description: "transaction")
        let _ = self.postbox.transaction({ transaction -> T in
            return f(transaction)
        }).start(next: { result in
            value = result
            done.fulfill()
        })
        self.wait(for: [done], timeout: 30.0)
        return value!
    }

    private func messageId(_ id: Int32) -> MessageId {
        return MessageId(peerId: self.otherPeerId, namespace: Namespaces.Message.Cloud, id: id)
    }

    /// An incoming message someone else sent in a one-to-one chat: the case the keep policy retains.
    private func addIncoming(_ id: Int32, text: String = "hello", attributes: [MessageAttribute] = []) {
        let message = StoreMessage(
            id: self.messageId(id), customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: sgRetentionNow() - 60, flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: self.otherPeerId, text: text, attributes: attributes, media: []
        )
        let _ = self.transaction { transaction in
            transaction.addMessages([message], location: .Random)
        }
    }

    private func stored(_ id: Int32) -> Message? {
        return self.transaction { transaction in
            transaction.getMessage(self.messageId(id))
        }
    }

    private func deleteReplay(_ ids: [Int32]) -> [MessageId] {
        let messageIds = ids.map(self.messageId)
        return self.transaction { transaction in
            let context = SGDeletionReplayContext(operations: [.DeleteMessages(messageIds)])
            return sgRetainDeletedMessages(transaction: transaction, mediaBox: self.postbox.mediaBox, accountPeerId: self.accountPeerId, ids: messageIds, context: context)
        }
    }

    private func globalIdDeleteReplay(_ ids: [Int32]) -> [Int32] {
        return self.transaction { transaction in
            let context = SGDeletionReplayContext(operations: [.DeleteMessagesWithGlobalIds(ids)])
            return sgRetainDeletedMessagesWithGlobalIds(transaction: transaction, mediaBox: self.postbox.mediaBox, accountPeerId: self.accountPeerId, globalIds: ids, context: context)
        }
    }

    private func validationRemoval(_ id: Int32) -> Bool {
        return self.transaction { transaction in
            sgRetainMessageRemovedByValidation(transaction: transaction, mediaBox: self.postbox.mediaBox, accountPeerId: self.accountPeerId, id: self.messageId(id))
        }
    }

    private var alreadyRetained: [MessageAttribute] {
        return [DeletedMessageAttribute(deletionTimestamp: sgRetentionNow() - 3600, schema: 1)]
    }

    private func edited(text: String, history: [EditedMessageHistoryEntry]) -> Message {
        var attributes: [MessageAttribute] = []
        if !history.isEmpty {
            attributes.append(EditedMessageHistoryAttribute(history: history))
        }
        return Message(
            stableId: 1, stableVersion: 0, id: self.messageId(500), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil,
            threadId: nil, timestamp: sgRetentionNow() - 600, flags: [.Incoming], tags: [], globalTags: [], localTags: [],
            customTags: [], forwardInfo: nil, author: nil, text: text, attributes: attributes, media: [],
            peers: SimpleDictionary(), associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:],
            associatedThreadInfo: nil, associatedStories: [:]
        )
    }

    // MARK: - Supergroup / channel fixtures (#6)

    private func channelPeerId(_ id: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(id))
    }

    private func userPeerId(_ id: Int64) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id))
    }

    /// A supergroup or a broadcast channel the account is a plain member of, unless `adminRights` says otherwise.
    private func storeChannel(_ peerId: PeerId, info: TelegramChannelInfo, adminRights: TelegramChatAdminRights? = nil) {
        let channel = TelegramChannel(
            id: peerId, accessHash: nil, title: "channel", username: nil, photo: [], creationDate: 0, version: 0,
            participationStatus: .member, info: info, flags: [], restrictionInfo: nil, adminRights: adminRights,
            bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil,
            backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil,
            approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
            sendPaidMessageStars: nil, linkedMonoforumId: nil
        )
        let _ = self.transaction { transaction in
            transaction.updatePeersInternal([channel], update: { _, updated in updated })
        }
    }

    /// Stored so that `Message.author` resolves: the per-author rule reads `message.author?.id`.
    private func storeUser(_ peerId: PeerId) {
        let user = TelegramUser(
            id: peerId, accessHash: nil, firstName: "member", lastName: nil, username: nil, phone: nil, photo: [],
            botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil
        )
        let _ = self.transaction { transaction in
            transaction.updatePeersInternal([user], update: { _, updated in updated })
        }
    }

    private func addMessage(_ id: MessageId, from authorId: PeerId, outgoing: Bool = false) {
        let message = StoreMessage(
            id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: sgRetentionNow() - 60, flags: outgoing ? [] : [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
            authorId: authorId, text: "hello", attributes: [], media: []
        )
        let _ = self.transaction { transaction in
            transaction.addMessages([message], location: .Random)
        }
    }

    private func storedMessage(_ id: MessageId) -> Message? {
        return self.transaction { transaction in
            transaction.getMessage(id)
        }
    }

    private func keptCount(_ ids: [MessageId]) -> Int {
        return ids.filter { self.storedMessage($0)?.sgIsKeptDeleted == true }.count
    }

    private func deleteReplay(ids: [MessageId]) -> [MessageId] {
        return self.transaction { transaction in
            let context = SGDeletionReplayContext(operations: [.DeleteMessages(ids)])
            return sgRetainDeletedMessages(transaction: transaction, mediaBox: self.postbox.mediaBox, accountPeerId: self.accountPeerId, ids: ids, context: context)
        }
    }

    private func validationRemoval(id: MessageId) -> Bool {
        return self.transaction { transaction in
            sgRetainMessageRemovedByValidation(transaction: transaction, mediaBox: self.postbox.mediaBox, accountPeerId: self.accountPeerId, id: id)
        }
    }

    private func cloudIds(in peerId: PeerId, _ range: ClosedRange<Int32>) -> [MessageId] {
        return range.map { MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: $0) }
    }

    // MARK: - Delete replay (`.DeleteMessages`)

    func test_free_deleteReplay_keepsANewCopy() {
        self.addIncoming(1)
        XCTAssertEqual(self.deleteReplay([1]), [], "kept, so nothing is really deleted")
        XCTAssertEqual(self.stored(1)?.sgIsKeptDeleted, true)
    }

    func test_paid_deleteReplay_capturesNothingNew() {
        SGSimpleSettings.shared.editHistoryCaptureBlocked = true
        self.addIncoming(2)
        XCTAssertEqual(self.deleteReplay([2]), [self.messageId(2)], "without a grant the deletion goes through as upstream")
        XCTAssertNotEqual(self.stored(2)?.sgIsKeptDeleted, true, "no new kept-deleted record")
    }

    func test_paid_deleteReplay_neverDeletesWhatWasAlreadyRetained() {
        self.addIncoming(3, text: "kept before the lapse", attributes: self.alreadyRetained)
        SGSimpleSettings.shared.editHistoryCaptureBlocked = true
        XCTAssertEqual(self.deleteReplay([3]), [], "a lapse never erases retained history")
        XCTAssertEqual(self.stored(3)?.text, "kept before the lapse", "and it stays readable")
        XCTAssertEqual(self.stored(3)?.sgIsKeptDeleted, true)
    }

    // MARK: - Global-id delete replay (`.DeleteMessagesWithGlobalIds`)

    func test_free_globalIdDeleteReplay_keepsANewCopy() {
        self.addIncoming(4)
        XCTAssertEqual(self.globalIdDeleteReplay([4]), [])
        XCTAssertEqual(self.stored(4)?.sgIsKeptDeleted, true)
    }

    func test_paid_globalIdDeleteReplay_capturesNothingNew() {
        SGSimpleSettings.shared.editHistoryCaptureBlocked = true
        self.addIncoming(5)
        XCTAssertEqual(self.globalIdDeleteReplay([5]), [5])
        XCTAssertNotEqual(self.stored(5)?.sgIsKeptDeleted, true)
    }

    func test_paid_globalIdDeleteReplay_neverDeletesWhatWasAlreadyRetained() {
        self.addIncoming(6, text: "kept before the lapse", attributes: self.alreadyRetained)
        SGSimpleSettings.shared.editHistoryCaptureBlocked = true
        XCTAssertEqual(self.globalIdDeleteReplay([6]), [])
        XCTAssertEqual(self.stored(6)?.text, "kept before the lapse")
    }

    // MARK: - History validation (a removal the server confirmed)

    func test_free_validation_keepsANewCopy() {
        self.addIncoming(7)
        XCTAssertTrue(self.validationRemoval(7))
        XCTAssertEqual(self.stored(7)?.sgIsKeptDeleted, true)
    }

    func test_paid_validation_capturesNothingNew() {
        SGSimpleSettings.shared.editHistoryCaptureBlocked = true
        self.addIncoming(8)
        XCTAssertFalse(self.validationRemoval(8), "the caller deletes it as upstream")
        XCTAssertNotEqual(self.stored(8)?.sgIsKeptDeleted, true)
    }

    func test_paid_validation_keepsWhatWasAlreadyRetained() {
        self.addIncoming(9, attributes: self.alreadyRetained)
        SGSimpleSettings.shared.editHistoryCaptureBlocked = true
        XCTAssertTrue(self.validationRemoval(9))
    }

    // MARK: - Edit replay (`.EditMessage`)

    func test_free_editReplay_recordsTheRevision() {
        var attributes: [MessageAttribute] = []
        sgCaptureEditHistory(previousMessage: self.edited(text: "v1", history: []), updatedText: "v2", updatedMedia: [], attributes: &attributes)
        let history = (attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute)?.history ?? []
        XCTAssertEqual(history.map { $0.text }, ["v1"])
    }

    func test_paid_editReplay_recordsNoNewRevision_andKeepsTheRetainedOnes() {
        SGSimpleSettings.shared.editHistoryCaptureBlocked = true
        let retained = EditedMessageHistoryEntry(timestamp: sgRetentionNow() - 900, text: "v0", entities: [], media: [], capturedAt: sgRetentionNow() - 600)
        let previous = self.edited(text: "v1", history: [retained])
        var attributes: [MessageAttribute] = []
        sgCaptureEditHistory(previousMessage: previous, updatedText: "v2", updatedMedia: [], attributes: &attributes)
        XCTAssertFalse(attributes.contains(where: { $0 is EditedMessageHistoryAttribute }), "no revision is recorded without a grant")
        // The re-save carries the retained revisions over unchanged: still readable, never locked.
        sgMergeForkMessageAttributes(previous.attributes, &attributes)
        let history = (attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute)?.history ?? []
        XCTAssertEqual(history.map { $0.text }, ["v0"])
    }

    // MARK: - The user's own toggles and the privacy rules still decide in free mode

    func test_free_theUsersOwnTogglesStillDecide() {
        SGSimpleSettings.shared.showDeletedMessages = false
        self.addIncoming(10)
        XCTAssertEqual(self.deleteReplay([10]), [self.messageId(10)])
        XCTAssertFalse(self.validationRemoval(10))

        SGSimpleSettings.shared.editHistoryEnabled = false
        var attributes: [MessageAttribute] = []
        sgCaptureEditHistory(previousMessage: self.edited(text: "v1", history: []), updatedText: "v2", updatedMedia: [], attributes: &attributes)
        XCTAssertTrue(attributes.isEmpty)
    }

    func test_free_selfDestructingMessagesAreNeverKept() {
        self.addIncoming(11, attributes: [AutoremoveTimeoutMessageAttribute(timeout: 30, countdownBeginTime: nil)])
        XCTAssertEqual(self.deleteReplay([11]), [self.messageId(11)])
        XCTAssertNotEqual(self.stored(11)?.sgIsKeptDeleted, true)
    }

    // MARK: - Supergroups and channels (#6): channel posts and moderation sweeps are not kept

    func test_free_broadcastChannelPostsAreNeverKept() {
        let channel = self.channelPeerId(4001)
        self.storeChannel(channel, info: .broadcast(TelegramChannelBroadcastInfo(flags: [])))
        let posts = self.cloudIds(in: channel, 1...2)
        for post in posts {
            self.addMessage(post, from: channel)
        }
        XCTAssertEqual(self.deleteReplay(ids: [posts[0]]), [posts[0]], "a deleted channel post goes through as upstream")
        XCTAssertNotEqual(self.storedMessage(posts[0])?.sgIsKeptDeleted, true)
        XCTAssertFalse(self.validationRemoval(id: posts[1]), "history validation keeps no channel post either")
        XCTAssertNotEqual(self.storedMessage(posts[1])?.sgIsKeptDeleted, true)
    }

    func test_free_supergroup_singleDeletionsAreStillKept() {
        let group = self.channelPeerId(4101)
        self.storeChannel(group, info: .group(TelegramChannelGroupInfo(flags: [])))
        let members = [self.userPeerId(5101), self.userPeerId(5102)]
        members.forEach(self.storeUser)
        let ids = self.cloudIds(in: group, 1...2)
        self.addMessage(ids[0], from: members[0])
        self.addMessage(ids[1], from: members[1])
        XCTAssertEqual(self.deleteReplay(ids: ids), [], "two deletions by two members are ordinary deletions")
        XCTAssertEqual(self.keptCount(ids), 2)
    }

    func test_free_supergroup_bulkDeletionIsNotKept() {
        // Ten messages of ten members removed in one replay: a moderation sweep, nothing is kept …
        let swept = self.channelPeerId(4102)
        self.storeChannel(swept, info: .group(TelegramChannelGroupInfo(flags: [])))
        let sweptIds = self.cloudIds(in: swept, 1...10)
        for (index, id) in sweptIds.enumerated() {
            let member = self.userPeerId(5200 + Int64(index))
            self.storeUser(member)
            self.addMessage(id, from: member)
        }
        XCTAssertEqual(self.deleteReplay(ids: sweptIds), sweptIds, "a bulk deletion in a supergroup goes through as upstream")
        XCTAssertEqual(self.keptCount(sweptIds), 0)
        // … while nine of nine members stay below the threshold and are kept.
        let below = self.channelPeerId(4103)
        self.storeChannel(below, info: .group(TelegramChannelGroupInfo(flags: [])))
        let belowIds = self.cloudIds(in: below, 1...9)
        for (index, id) in belowIds.enumerated() {
            let member = self.userPeerId(5300 + Int64(index))
            self.storeUser(member)
            self.addMessage(id, from: member)
        }
        XCTAssertEqual(self.deleteReplay(ids: belowIds), [])
        XCTAssertEqual(self.keptCount(belowIds), 9)
    }

    func test_free_supergroup_repeatedDeletionsOfOneAuthorAreNotKept() {
        // Three messages of one member removed in one replay ("delete all from user", anti-spam): nothing of
        // the group is kept from that replay, a bystander's message named in it included.
        let group = self.channelPeerId(4104)
        self.storeChannel(group, info: .group(TelegramChannelGroupInfo(flags: [])))
        let spammer = self.userPeerId(5401)
        let bystander = self.userPeerId(5402)
        self.storeUser(spammer)
        self.storeUser(bystander)
        let ids = self.cloudIds(in: group, 1...4)
        for id in ids.prefix(3) {
            self.addMessage(id, from: spammer)
        }
        self.addMessage(ids[3], from: bystander)
        XCTAssertEqual(self.deleteReplay(ids: ids), ids)
        XCTAssertEqual(self.keptCount(ids), 0)
        // Two of one member are still ordinary deletions.
        let other = self.channelPeerId(4105)
        self.storeChannel(other, info: .group(TelegramChannelGroupInfo(flags: [])))
        let member = self.userPeerId(5403)
        self.storeUser(member)
        let twoIds = self.cloudIds(in: other, 1...2)
        for id in twoIds {
            self.addMessage(id, from: member)
        }
        XCTAssertEqual(self.deleteReplay(ids: twoIds), [])
        XCTAssertEqual(self.keptCount(twoIds), 2)
    }

    func test_free_supergroup_ownDeletedMessageIsNoClearLikeSignal() {
        // Unlike a DM (D2), deleting one's own message in a group says nothing about the other deletions.
        let group = self.channelPeerId(4106)
        self.storeChannel(group, info: .group(TelegramChannelGroupInfo(flags: [])))
        let member = self.userPeerId(5501)
        self.storeUser(member)
        let ids = self.cloudIds(in: group, 1...2)
        self.addMessage(ids[0], from: self.accountPeerId, outgoing: true)
        self.addMessage(ids[1], from: member)
        XCTAssertEqual(self.deleteReplay(ids: ids), [ids[0]], "the own message is deleted, the member's is kept")
        XCTAssertEqual(self.storedMessage(ids[1])?.sgIsKeptDeleted, true)
    }

    func test_free_supergroup_whereTheUserCanDeleteOthersMessagesNothingIsKept() {
        let group = self.channelPeerId(4107)
        self.storeChannel(group, info: .group(TelegramChannelGroupInfo(flags: [])), adminRights: TelegramChatAdminRights(rights: [.canDeleteMessages]))
        let member = self.userPeerId(5601)
        self.storeUser(member)
        let ids = self.cloudIds(in: group, 1...1)
        self.addMessage(ids[0], from: member)
        XCTAssertEqual(self.deleteReplay(ids: ids), ids)
        XCTAssertNotEqual(self.storedMessage(ids[0])?.sgIsKeptDeleted, true)
    }

    func test_free_basicGroup_rulesAreUnchanged() {
        // Neither the supergroup threshold nor the per-author rule applies to a basic group: ten messages
        // of one member are kept (D2's 50-message clear threshold stays).
        let group = PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(4201))
        let member = self.userPeerId(5701)
        self.storeUser(member)
        let ids = self.cloudIds(in: group, 1...10)
        for id in ids {
            self.addMessage(id, from: member)
        }
        XCTAssertEqual(self.deleteReplay(ids: ids), [])
        XCTAssertEqual(self.keptCount(ids), 10)
    }
}
