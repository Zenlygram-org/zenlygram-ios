import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import Display
import TelegramUIPreferences
import AccountContext
// MARK: Swiftgram
import SGChatLock
import SGSecretVault

public enum ChatListNodeLocation: Equatable {
    case initial(count: Int, filter: ChatListFilter?)
    case navigation(index: EngineChatList.Item.Index, filter: ChatListFilter?)
    case scroll(index: EngineChatList.Item.Index, sourceIndex: EngineChatList.Item.Index, scrollPosition: ListViewScrollPosition, animated: Bool, filter: ChatListFilter?)
    
    public var filter: ChatListFilter? {
        switch self {
        case let .initial(_, filter):
            return filter
        case let .navigation(_, filter):
            return filter
        case let .scroll(_, _, _, _, filter):
            return filter
        }
    }
}

public struct ChatListNodeViewUpdate {
    public let list: EngineChatList
    public let type: ViewUpdateType
    public let scrollPosition: ChatListNodeViewScrollPosition?
    
    public init(list: EngineChatList, type: ViewUpdateType, scrollPosition: ChatListNodeViewScrollPosition?) {
        self.list = list
        self.type = type
        self.scrollPosition = scrollPosition
    }
}

private func communityPeerId(item: EngineChatList.Item) -> EnginePeer.Id? {
    guard case let .chatList(peerId) = item.id else {
        return nil
    }
    if let peer = item.renderedPeer.peer, case let .community(community) = peer, community.collapsedInDialogs == true {
        return peerId
    } else {
        return nil
    }
}

private func filteredCommunityChatListItems(_ items: [EngineChatList.Item]) -> [EngineChatList.Item] {
    return items.filter { item in
        if let peer = item.renderedPeer.peer, case let .community(community) = peer {
            return community.collapsedInDialogs == true
        } else {
            return true
        }
    }
}

private func chatListNodeViewUpdateWithCommunitySummaries(account: Account, update: ChatListNodeViewUpdate, excludeLinkedPeerId: ((EnginePeer.Id) -> Bool)?) -> Signal<ChatListNodeViewUpdate, NoError> {
    let baseItems = filteredCommunityChatListItems(update.list.items)
    let baseList = EngineChatList(
        items: baseItems,
        groupItems: update.list.groupItems,
        additionalItems: update.list.additionalItems,
        hasEarlier: update.list.hasEarlier,
        hasLater: update.list.hasLater,
        isLoading: update.list.isLoading
    )
    let baseUpdate = ChatListNodeViewUpdate(list: baseList, type: update.type, scrollPosition: update.scrollPosition)

    let communityIds = baseItems.compactMap { item in
        return communityPeerId(item: item)
    }
    if communityIds.isEmpty {
        return .single(baseUpdate)
    }

    var isFirstSummary = true
    return communityChatListItemSummaries(postbox: account.postbox, communityIds: communityIds, excludeLinkedPeerId: excludeLinkedPeerId)
    |> map { summaries -> ChatListNodeViewUpdate in
        let updatedType: ViewUpdateType
        let updatedScrollPosition: ChatListNodeViewScrollPosition?
        if isFirstSummary {
            updatedType = update.type
            updatedScrollPosition = update.scrollPosition
            isFirstSummary = false
        } else {
            updatedType = .Generic
            updatedScrollPosition = nil
        }

        let items = baseItems.map { item -> EngineChatList.Item in
            guard let communityId = communityPeerId(item: item), let summary = summaries[communityId], summary.hasLinkedPeers else {
                return item
            }
            // SG: Chat Lock / Secret Vault — once a linked chat has been filtered out of the summary, the
            // row must show the newest VISIBLE linked message or nothing at all. Upstream's
            // "no linked message -> show the community's own message" fallback is skipped in that case,
            // otherwise a hidden chat's preview could come back through `item.messages`.
            let messages: [EngineMessage]
            if let topMessage = summary.topMessage {
                messages = [topMessage]
            } else if summary.hasHiddenLinkedPeers {
                messages = []
            } else {
                messages = item.messages
            }
            return item.withUpdatedCommunitySummary(messages: messages, readCounters: summary.readCounters ?? item.readCounters)
        }

        let list = EngineChatList(
            items: items,
            groupItems: baseList.groupItems,
            additionalItems: baseList.additionalItems,
            hasEarlier: baseList.hasEarlier,
            hasLater: baseList.hasLater,
            isLoading: baseList.isLoading
        )
        return ChatListNodeViewUpdate(list: list, type: updatedType, scrollPosition: updatedScrollPosition)
    }
}

// MARK: - SG: Chat Lock / Secret Vault — collapsed communities
//
// Upstream 12.9.2 collapses a community's member channels into a single community row: every linked channel is
// forced to `.notIncluded` in the chat list (TelegramCore/Sources/UpdatePeers.swift,
// `isPeerHiddenByCollapsedCommunity`) and the community row borrows their newest message and their combined
// unread count instead. That breaks both fork gates, which key off the row's OWN peer id — for this row that id
// is the community's, never the locked or vaulted channel's. The two helpers below close the resulting holes.

/// Linked peers whose message/unread contribution must be kept off a collapsed community's chat-list row.
/// Chat-Locked chats never contribute a preview to any list. Vaulted chats contribute nowhere except inside the
/// vault screen itself, where the community row is only reachable when the community is vaulted too.
private func sgExcludeCommunityLinkedPeerId(peerId: EnginePeer.Id, accountPeerId: EnginePeer.Id, isVaultView: Bool) -> Bool {
    if ChatLockSession.shared.isProtected(peerId: peerId, accountPeerId: accountPeerId) {
        return true
    }
    if !isVaultView && SecretVaultManager.shared.shouldHide(peerId, accountPeerId: accountPeerId) {
        return true
    }
    return false
}

/// Vaulted peers that a collapsed community currently hides from every Postbox chat-list view.
/// Mirrors `isPeerHiddenByCollapsedCommunity` (channel -> `linkedCommunityId` -> `collapsedInDialogs`), which is
/// internal to TelegramCore, using the peer views the postbox already serves.
private func sgVaultCommunityHiddenPeerIds(postbox: Postbox, vaultPeerIds: Set<EnginePeer.Id>) -> Signal<[EnginePeer.Id], NoError> {
    if vaultPeerIds.isEmpty {
        return .single([])
    }
    let peerIds = vaultPeerIds.sorted()
    let peerKeys: [PostboxViewKey] = peerIds.map { .peer(peerId: $0, components: []) }
    return postbox.combinedView(keys: peerKeys)
    |> map { views -> [EnginePeer.Id: EnginePeer.Id] in
        var result: [EnginePeer.Id: EnginePeer.Id] = [:]
        for peerId in peerIds {
            guard let view = views.views[.peer(peerId: peerId, components: [])] as? PeerView else {
                continue
            }
            if let channel = view.peers[peerId] as? TelegramChannel, let linkedCommunityId = channel.linkedCommunityId {
                result[peerId] = linkedCommunityId
            }
        }
        return result
    }
    |> distinctUntilChanged
    |> mapToSignal { linkedCommunityIds -> Signal<[EnginePeer.Id], NoError> in
        if linkedCommunityIds.isEmpty {
            return .single([])
        }
        let communityIds = Set(linkedCommunityIds.values).sorted()
        let communityKeys: [PostboxViewKey] = communityIds.map { .peer(peerId: $0, components: []) }
        return postbox.combinedView(keys: communityKeys)
        |> map { views -> [EnginePeer.Id] in
            var collapsedCommunityIds = Set<EnginePeer.Id>()
            for communityId in communityIds {
                guard let view = views.views[.peer(peerId: communityId, components: [])] as? PeerView else {
                    continue
                }
                if let community = view.peers[communityId] as? TelegramCommunity, community.collapsedInDialogs == true {
                    collapsedCommunityIds.insert(communityId)
                }
            }
            var hiddenPeerIds: [EnginePeer.Id] = []
            for (peerId, communityId) in linkedCommunityIds where collapsedCommunityIds.contains(communityId) {
                hiddenPeerIds.append(peerId)
            }
            return hiddenPeerIds.sorted()
        }
        |> distinctUntilChanged
    }
}

/// Minimal chat-list rows for peers the postbox refuses to list (see above): peer, newest message, unread state
/// and mute flag. Everything the vault screen does not need for "open / un-vault this chat" stays at its
/// neutral value — a draft or typing preview would be wrong on a vaulted row anyway.
private func sgStandaloneChatListItems(postbox: Postbox, peerIds: [EnginePeer.Id]) -> Signal<[EngineChatList.Item], NoError> {
    if peerIds.isEmpty {
        return .single([])
    }
    let topMessageKey: PostboxViewKey = .topChatMessage(peerIds: peerIds)
    let peerKeys: [PostboxViewKey] = peerIds.map { .peer(peerId: $0, components: []) }
    let keys: [PostboxViewKey] = [topMessageKey] + peerKeys
    let readCounts = postbox.unreadMessageCountsView(items: peerIds.map { peerId in
        return .peer(id: peerId, handleThreads: true)
    })
    return combineLatest(postbox.combinedView(keys: keys), readCounts)
    |> map { views, readCountsView -> [EngineChatList.Item] in
        var topMessages: [EnginePeer.Id: Message] = [:]
        if let view = views.views[topMessageKey] as? TopChatMessageView {
            topMessages = view.messages
        }
        var readStates: [EnginePeer.Id: CombinedPeerReadState] = [:]
        for entry in readCountsView.entries {
            switch entry {
            case let .peer(peerId, state):
                if let state {
                    readStates[peerId] = state
                }
            case .total, .totalInGroup:
                break
            }
        }

        var items: [EngineChatList.Item] = []
        for peerId in peerIds {
            guard let peerView = views.views[.peer(peerId: peerId, components: [])] as? PeerView, let peer = peerView.peers[peerId] else {
                continue
            }
            let topMessage = topMessages[peerId]
            let isMuted = peerView.notificationSettings?.isRemovedFromTotalUnreadCount(default: false) ?? false
            // With no message yet, sort the row at the very bottom of the list rather than dropping it —
            // reaching the row at all is the point of this escape hatch.
            let messageIndex = topMessage?.index ?? MessageIndex(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: 1), timestamp: 1)
            items.append(EngineChatList.Item(
                id: .chatList(peerId),
                index: .chatList(ChatListIndex(pinningIndex: nil, messageIndex: messageIndex)),
                messages: topMessage.map { [EngineMessage($0)] } ?? [],
                readCounters: readStates[peerId].map { EnginePeerReadCounters(state: $0, isMuted: isMuted) },
                isMuted: isMuted,
                draft: nil,
                threadData: nil,
                renderedPeer: EngineRenderedPeer(peer: EnginePeer(peer)),
                presence: nil,
                hasUnseenMentions: false,
                hasUnseenReactions: false,
                hasUnseenPollVotes: false,
                forumTopicData: nil,
                topForumTopicItems: [],
                hasFailed: false,
                isContact: false,
                autoremoveTimeout: nil,
                storyStats: nil,
                displayAsTopicList: false,
                isPremiumRequiredToMessage: false,
                mediaDraftContentType: nil
            ))
        }
        return items
    }
}

/// Unions the rebuilt rows into the vault screen's filtered view, so a vaulted chat that a collapsed community
/// hid from Postbox is still listed (and therefore still openable and un-vaultable). A no-op for every other
/// list, and for a vault that has no such chat.
private func sgChatListNodeViewUpdateWithVaultCommunityHiddenItems(postbox: Postbox, update: ChatListNodeViewUpdate, vaultPeerIds: Set<EnginePeer.Id>?) -> Signal<ChatListNodeViewUpdate, NoError> {
    guard let vaultPeerIds, !vaultPeerIds.isEmpty else {
        return .single(update)
    }
    let existingIds = Set(update.list.items.map { $0.id })
    var isFirstUpdate = true
    return sgVaultCommunityHiddenPeerIds(postbox: postbox, vaultPeerIds: vaultPeerIds)
    |> mapToSignal { hiddenPeerIds -> Signal<[EngineChatList.Item], NoError> in
        let missingPeerIds = hiddenPeerIds.filter { !existingIds.contains(.chatList($0)) }
        return sgStandaloneChatListItems(postbox: postbox, peerIds: missingPeerIds)
    }
    |> map { extraItems -> ChatListNodeViewUpdate in
        // Only the first emission may carry the caller's update type and scroll target; later ones replay the
        // same base view and must not re-apply a stale scroll position (same rule as the community summaries).
        let updatedType: ViewUpdateType
        let updatedScrollPosition: ChatListNodeViewScrollPosition?
        if isFirstUpdate {
            updatedType = update.type
            updatedScrollPosition = update.scrollPosition
            isFirstUpdate = false
        } else {
            updatedType = .Generic
            updatedScrollPosition = nil
        }
        if extraItems.isEmpty {
            return ChatListNodeViewUpdate(list: update.list, type: updatedType, scrollPosition: updatedScrollPosition)
        }
        var items = update.list.items
        items.append(contentsOf: extraItems)
        // The list is ordered ascending by index (newest chat last), as the chat-list node expects.
        items.sort(by: { $0.index < $1.index })
        let list = EngineChatList(
            items: items,
            groupItems: update.list.groupItems,
            additionalItems: update.list.additionalItems,
            hasEarlier: update.list.hasEarlier,
            hasLater: update.list.hasLater,
            isLoading: update.list.isLoading
        )
        return ChatListNodeViewUpdate(list: list, type: updatedType, scrollPosition: updatedScrollPosition)
    }
}

public func chatListFilterPredicate(filter: ChatListFilterData, accountPeerId: EnginePeer.Id) -> ChatListFilterPredicate {
    var includePeers = Set(filter.includePeers.peers)
    var excludePeers = Set(filter.excludePeers)
    
    if !filter.includePeers.pinnedPeers.isEmpty {
        includePeers.subtract(filter.includePeers.pinnedPeers)
        excludePeers.subtract(filter.includePeers.pinnedPeers)
    }
    
    var includeAdditionalPeerGroupIds: [PeerGroupId] = []
    if !filter.excludeArchived {
        includeAdditionalPeerGroupIds.append(Namespaces.PeerGroup.archive)
    }
    
    var messageTagSummary: ChatListMessageTagSummaryResultCalculation?
    if filter.excludeRead || filter.excludeMuted {
        messageTagSummary = ChatListMessageTagSummaryResultCalculation(addCount: ChatListMessageTagSummaryResultComponent(tag: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud), subtractCount: ChatListMessageTagActionsSummaryResultComponent(type: PendingMessageActionType.consumeUnseenPersonalMessage, namespace: Namespaces.Message.Cloud))
    }
    return ChatListFilterPredicate(includePeerIds: includePeers, excludePeerIds: excludePeers, pinnedPeerIds: filter.includePeers.pinnedPeers, messageTagSummary: messageTagSummary, includeAdditionalPeerGroupIds: includeAdditionalPeerGroupIds, include: { peer, isMuted, isUnread, isContact, messageTagSummaryResult in
        if filter.excludeRead {
            var effectiveUnread = isUnread
            if let messageTagSummaryResult = messageTagSummaryResult, messageTagSummaryResult {
                effectiveUnread = true
            }
            if !effectiveUnread {
                return false
            }
        }
        if filter.excludeMuted {
            if isMuted {
                if let messageTagSummaryResult = messageTagSummaryResult, messageTagSummaryResult {
                } else {
                    return false
                }
            }
        }
        if !filter.categories.contains(.contacts) && isContact {
            if let user = peer as? TelegramUser {
                if user.botInfo == nil && !user.flags.contains(.isSupport) {
                    return false
                }
            } else if let _ = peer as? TelegramSecretChat {
                return false
            }
        }
        if !filter.categories.contains(.nonContacts) && (!isContact && peer.id != accountPeerId) {
            if let user = peer as? TelegramUser {
                if user.botInfo == nil {
                    return false
                }
            } else if let _ = peer as? TelegramSecretChat {
                return false
            }
        }
        if filter.categories.contains(.nonContacts) && peer.id == accountPeerId {
            return false
        }
        if !filter.categories.contains(.bots) {
            if let user = peer as? TelegramUser {
                if user.botInfo != nil || user.flags.contains(.isSupport) {
                    return false
                }
            }
        }
        if !filter.categories.contains(.groups) {
            if let _ = peer as? TelegramGroup {
                return false
            } else if let channel = peer as? TelegramChannel {
                if case .group = channel.info {
                    return false
                }
            } else if let _ = peer as? TelegramCommunity {
                return false
            }
        }
        if !filter.categories.contains(.channels) {
            if let channel = peer as? TelegramChannel {
                if case .broadcast = channel.info {
                    return false
                }
            }
        }
        return true
    })
}

public func chatListViewForLocation(chatListLocation: ChatListControllerLocation, location: ChatListNodeLocation, account: Account, shouldLoadCanMessagePeer: Bool, fenixVaultPeerIds: Set<EnginePeer.Id>? = nil) -> Signal<ChatListNodeViewUpdate, NoError> { // SG: Secret Vault — audit #31
    let accountPeerId = account.peerId
    
    switch chatListLocation {
    case let .chatList(groupId):
        // SG: Chat Lock / Secret Vault — gates for upstream 12.9.2's collapsed-community rows (see the helpers
        // above). `isVaultView` is the vault screen; the injection of community-hidden vault rows is limited to
        // the root group so the same row cannot be added twice if an archive view is ever requested with a
        // vault set.
        let sgIsVaultView = fenixVaultPeerIds != nil
        let sgExcludeCommunityLinkedPeer: (EnginePeer.Id) -> Bool = { peerId in
            return sgExcludeCommunityLinkedPeerId(peerId: peerId, accountPeerId: accountPeerId, isVaultView: sgIsVaultView)
        }
        let sgVaultCommunityEscapePeerIds: Set<EnginePeer.Id>?
        if case .root = groupId {
            sgVaultCommunityEscapePeerIds = fenixVaultPeerIds
        } else {
            sgVaultCommunityEscapePeerIds = nil
        }

        let filterPredicate: ChatListFilterPredicate?
        if let fenixVaultPeerIds {
            // SG: Secret Vault — audit #31: the vault screen is a real filtered view, so paging,
            // hasEarlier/hasLater and the requested count all apply to vaulted chats only.
            //
            // The membership test lives in the `include` closure and keys off the row's OWN peer id.
            // `includePeerIds` is deliberately left empty: `ChatListFilterPredicate.includes` resolves it
            // against `peer.associatedPeerId` whenever `peer.associatedPeerOverridesIdentity` (always true
            // for `TelegramSecretChat`), while the vault stores the chat-list row's peer id — i.e. the
            // secret-chat peer id. Routing the test through `includePeerIds` would therefore both drop
            // vaulted secret chats (their regular-user id is not in the set) and wrongly admit a
            // NON-vaulted secret chat whenever the ordinary chat with the same user is vaulted.
            // One Set lookup per row is cheap; correctness is not.
            //
            // `includes` still short-circuits on `groupId != .root` before consulting the closure, so
            // `includeAdditionalPeerGroupIds` must keep the archive group for vaulted archived chats.
            filterPredicate = ChatListFilterPredicate(
                includePeerIds: Set(),
                excludePeerIds: Set(),
                // No pinned lane inside the vault. Any filtered view is built with `.includePinnedAsUnpinned`
                // (Postbox/Sources/ChatListView.swift:623,626), which strips every pinning index, so the vault
                // sorts strictly by date. That matches the product rule rather than fighting it: adding a chat
                // to the vault unpins it from the main list and removing it re-pins it (SGChatLockUI/Sources/
                // SecretVaultTelegramUIIntegration.swift, `unpinFromMainList` / `repairPinnedVaultChats`), so a
                // pinned-AND-vaulted row is only a transient state. The vault screen is `.chatList(.root)`,
                // which offers no Pin swipe action (ChatListItem.swift `revealOptions`), and `sgVaultBlocksPin`
                // (ChatListUI/Sources/ChatContextMenus.swift) hides Pin in its context menu — nothing offers
                // the user an action that an empty `pinnedPeerIds` would silently turn into a no-op.
                pinnedPeerIds: [],
                messageTagSummary: nil,
                includeAdditionalPeerGroupIds: [Namespaces.PeerGroup.archive],
                include: { peer, _, _, _, _ in return fenixVaultPeerIds.contains(peer.id) }
            )
        } else if let filter = location.filter, case let .filter(_, _, _, data) = filter {
            filterPredicate = chatListFilterPredicate(filter: data, accountPeerId: account.peerId)
        } else {
            filterPredicate = nil
        }
        
        switch location {
        case let .initial(count, _):
            let signal: Signal<(ChatListView, ViewUpdateType), NoError>
            signal = account.viewTracker.tailChatListView(groupId: groupId._asGroup(), filterPredicate: filterPredicate, count: count, shouldLoadCanMessagePeer: shouldLoadCanMessagePeer)
            return signal
            |> map { view, updateType -> ChatListNodeViewUpdate in
                return ChatListNodeViewUpdate(list: EngineChatList(view, accountPeerId: accountPeerId), type: updateType, scrollPosition: nil)
            }
            |> mapToSignal { update -> Signal<ChatListNodeViewUpdate, NoError> in
                return chatListNodeViewUpdateWithCommunitySummaries(account: account, update: update, excludeLinkedPeerId: sgExcludeCommunityLinkedPeer) // SG: Chat Lock / Secret Vault
            }
            |> mapToSignal { update -> Signal<ChatListNodeViewUpdate, NoError> in
                return sgChatListNodeViewUpdateWithVaultCommunityHiddenItems(postbox: account.postbox, update: update, vaultPeerIds: sgVaultCommunityEscapePeerIds) // SG: Secret Vault
            }
        case let .navigation(index, _):
            guard case let .chatList(index) = index else {
                return .never()
            }
            var first = true
            return account.viewTracker.aroundChatListView(groupId: groupId._asGroup(), filterPredicate: filterPredicate, index: index, count: 80, shouldLoadCanMessagePeer: shouldLoadCanMessagePeer)
            |> map { view, updateType -> ChatListNodeViewUpdate in
                let genericType: ViewUpdateType
                if first {
                    first = false
                    genericType = ViewUpdateType.UpdateVisible
                } else {
                    genericType = updateType
                }
                return ChatListNodeViewUpdate(list: EngineChatList(view, accountPeerId: accountPeerId), type: genericType, scrollPosition: nil)
            }
            |> mapToSignal { update -> Signal<ChatListNodeViewUpdate, NoError> in
                return chatListNodeViewUpdateWithCommunitySummaries(account: account, update: update, excludeLinkedPeerId: sgExcludeCommunityLinkedPeer) // SG: Chat Lock / Secret Vault
            }
            |> mapToSignal { update -> Signal<ChatListNodeViewUpdate, NoError> in
                return sgChatListNodeViewUpdateWithVaultCommunityHiddenItems(postbox: account.postbox, update: update, vaultPeerIds: sgVaultCommunityEscapePeerIds) // SG: Secret Vault
            }
        case let .scroll(index, sourceIndex, scrollPosition, animated, _):
            guard case let .chatList(index) = index else {
                return .never()
            }
            
            let directionHint: ListViewScrollToItemDirectionHint = sourceIndex > .chatList(index) ? .Down : .Up
            let chatScrollPosition: ChatListNodeViewScrollPosition = .index(index: index, position: scrollPosition, directionHint: directionHint, animated: animated)
            var first = true
            return account.viewTracker.aroundChatListView(groupId: groupId._asGroup(), filterPredicate: filterPredicate, index: index, count: 80, shouldLoadCanMessagePeer: shouldLoadCanMessagePeer)
            |> map { view, updateType -> ChatListNodeViewUpdate in
                let genericType: ViewUpdateType
                let scrollPosition: ChatListNodeViewScrollPosition? = first ? chatScrollPosition : nil
                if first {
                    first = false
                    genericType = ViewUpdateType.UpdateVisible
                } else {
                    genericType = updateType
                }
                return ChatListNodeViewUpdate(list: EngineChatList(view, accountPeerId: accountPeerId), type: genericType, scrollPosition: scrollPosition)
            }
            |> mapToSignal { update -> Signal<ChatListNodeViewUpdate, NoError> in
                return chatListNodeViewUpdateWithCommunitySummaries(account: account, update: update, excludeLinkedPeerId: sgExcludeCommunityLinkedPeer) // SG: Chat Lock / Secret Vault
            }
            |> mapToSignal { update -> Signal<ChatListNodeViewUpdate, NoError> in
                return sgChatListNodeViewUpdateWithVaultCommunityHiddenItems(postbox: account.postbox, update: update, vaultPeerIds: sgVaultCommunityEscapePeerIds) // SG: Secret Vault
            }
        }
    case let .forum(peerId):
        let viewKey: PostboxViewKey = .messageHistoryThreadIndex(
            id: peerId,
            summaryComponents: ChatListEntrySummaryComponents(
                components: [
                    ChatListEntryMessageTagSummaryKey(
                        tag: .unseenPersonalMessage,
                        actionType: PendingMessageActionType.consumeUnseenPersonalMessage
                    ): ChatListEntrySummaryComponents.Component(
                        tagSummary: ChatListEntryMessageTagSummaryComponent(namespace: Namespaces.Message.Cloud),
                        actionsSummary: ChatListEntryPendingMessageActionsSummaryComponent(namespace: Namespaces.Message.Cloud)
                    ),
                    ChatListEntryMessageTagSummaryKey(
                        tag: .unseenReaction,
                        actionType: PendingMessageActionType.readReactionOrPollVote
                    ): ChatListEntrySummaryComponents.Component(
                        tagSummary: ChatListEntryMessageTagSummaryComponent(namespace: Namespaces.Message.Cloud),
                        actionsSummary: ChatListEntryPendingMessageActionsSummaryComponent(namespace: Namespaces.Message.Cloud)
                    ),
                    ChatListEntryMessageTagSummaryKey(
                        tag: .unseenPollVote,
                        actionType: PendingMessageActionType.readReactionOrPollVote
                    ): ChatListEntrySummaryComponents.Component(
                        tagSummary: ChatListEntryMessageTagSummaryComponent(namespace: Namespaces.Message.Cloud),
                        actionsSummary: ChatListEntryPendingMessageActionsSummaryComponent(namespace: Namespaces.Message.Cloud)
                    )
                ]
            )
        )
        
        let readStateKey: PostboxViewKey = .combinedReadState(peerId: peerId, handleThreads: false)
        
        var isFirst = false
        return account.postbox.combinedView(keys: [viewKey, readStateKey])
        |> map { views -> ChatListNodeViewUpdate in
            guard let view = views.views[viewKey] as? MessageHistoryThreadIndexView else {
                preconditionFailure()
            }
            guard let readStateView = views.views[readStateKey] as? CombinedReadStateView else {
                preconditionFailure()
            }
            
            var maxReadId: Int32 = 0
            if let state = readStateView.state?.states.first(where: { $0.0 == Namespaces.Message.Cloud }) {
                if case let .idBased(maxIncomingReadId, _, _, _, _) = state.1 {
                    maxReadId = maxIncomingReadId
                }
            }
            
            var items: [EngineChatList.Item] = []
            for item in view.items {
                guard let peer = view.peer else {
                    continue
                }
                guard let data = item.info.get(MessageHistoryThreadData.self) else {
                    continue
                }
                
                let defaultPeerNotificationSettings: TelegramPeerNotificationSettings = (view.peerNotificationSettings as? TelegramPeerNotificationSettings) ?? .defaultSettings
                
                var hasUnseenMentions = false
                
                var isMuted = false
                switch data.notificationSettings.muteState {
                case .muted:
                    isMuted = true
                case .unmuted:
                    isMuted = false
                case .default:
                    if case .default = data.notificationSettings.muteState {
                        if case .muted = defaultPeerNotificationSettings.muteState {
                            isMuted = true
                        }
                    }
                }
                
                if let info = item.tagSummaryInfo[ChatListEntryMessageTagSummaryKey(
                    tag: .unseenPersonalMessage,
                    actionType: PendingMessageActionType.consumeUnseenPersonalMessage
                )] {
                    hasUnseenMentions = (info.tagSummaryCount ?? 0) > (info.actionsSummaryCount ?? 0)
                }
                
                var hasUnseenReactions = false
                if let info = item.tagSummaryInfo[ChatListEntryMessageTagSummaryKey(
                    tag: .unseenReaction,
                    actionType: PendingMessageActionType.readReactionOrPollVote
                )] {
                    hasUnseenReactions = (info.tagSummaryCount ?? 0) != 0
                }
                
                var hasUnseenPollVotes = false
                if let info = item.tagSummaryInfo[ChatListEntryMessageTagSummaryKey(
                    tag: .unseenPollVote,
                    actionType: PendingMessageActionType.readReactionOrPollVote
                )] {
                    hasUnseenPollVotes = (info.tagSummaryCount ?? 0) != 0
                }
                
                let pinnedIndex: EngineChatList.Item.PinnedIndex
                if let index = item.pinnedIndex {
                    pinnedIndex = .index(index)
                } else {
                    pinnedIndex = .none
                }
                
                var topicMaxIncomingReadId = data.maxIncomingReadId
                if data.maxIncomingReadId == 0 && maxReadId != 0 && Int64(maxReadId) <= item.id {
                    topicMaxIncomingReadId = max(topicMaxIncomingReadId, maxReadId)
                }
                
                let readCounters = EnginePeerReadCounters(state: CombinedPeerReadState(states: [(Namespaces.Message.Cloud, .idBased(maxIncomingReadId: topicMaxIncomingReadId, maxOutgoingReadId: data.maxOutgoingReadId, maxKnownId: 1, count: data.incomingUnreadCount, markedUnread: false))]), isMuted: false)
                
                var draft: EngineChatList.Draft?
                if let embeddedState = item.embeddedInterfaceState, let _ = embeddedState.overrideChatTimestamp {
                    if let opaqueState = _internal_decodeStoredChatInterfaceState(state: embeddedState) {
                        if let text = opaqueState.synchronizeableInputState?.text {
                            draft = EngineChatList.Draft(text: text, entities: opaqueState.synchronizeableInputState?.entities ?? [])
                        }
                    }
                }
                
                items.append(EngineChatList.Item(
                    id: .forum(item.id),
                    index: .forum(pinnedIndex: pinnedIndex, timestamp: item.index.timestamp, threadId: item.id, namespace: item.index.id.namespace, id: item.index.id.id),
                    messages: item.topMessage.flatMap { [EngineMessage($0)] } ?? [],
                    readCounters: readCounters,
                    isMuted: isMuted,
                    draft: draft,
                    threadData: data,
                    renderedPeer: EngineRenderedPeer(peer: EnginePeer(peer)),
                    presence: nil,
                    hasUnseenMentions: hasUnseenMentions,
                    hasUnseenReactions: hasUnseenReactions,
                    hasUnseenPollVotes: hasUnseenPollVotes,
                    forumTopicData: nil,
                    topForumTopicItems: [],
                    hasFailed: false,
                    isContact: false,
                    autoremoveTimeout: nil,
                    storyStats: nil,
                    displayAsTopicList: false,
                    isPremiumRequiredToMessage: false,
                    mediaDraftContentType: nil
                ))
            }
            
            let list = EngineChatList(
                items: items.reversed(),
                groupItems: [],
                additionalItems: [],
                hasEarlier: false,
                hasLater: false,
                isLoading: view.isLoading
            )
            
            let type: ViewUpdateType
            if isFirst {
                type = .Initial
            } else {
                type = .Generic
            }
            isFirst = false
            return ChatListNodeViewUpdate(list: list, type: type, scrollPosition: nil)
        }
    case let .savedMessagesChats(peerId):
        let viewKey: PostboxViewKey = .savedMessagesIndex(peerId: peerId)
        let interfaceStateKey: PostboxViewKey = .chatInterfaceState(peerId: peerId)
        
        var isFirst = true
        return account.postbox.combinedView(keys: [viewKey, interfaceStateKey])
        |> map { views -> ChatListNodeViewUpdate in
            guard let view = views.views[viewKey] as? MessageHistorySavedMessagesIndexView else {
                preconditionFailure()
            }
            
            var draft: EngineChatList.Draft?
            if let interfaceStateView = views.views[interfaceStateKey] as? ChatInterfaceStateView {
                if let embeddedState = interfaceStateView.value, let _ = embeddedState.overrideChatTimestamp {
                    if let opaqueState = _internal_decodeStoredChatInterfaceState(state: embeddedState) {
                        if let text = opaqueState.synchronizeableInputState?.text {
                            draft = EngineChatList.Draft(text: text, entities: opaqueState.synchronizeableInputState?.entities ?? [])
                        }
                    }
                }
            }
             
            var items: [EngineChatList.Item] = []
            for item in view.items {
                guard let sourcePeer = item.peer else {
                    continue
                }
                
                let sourceId = PeerId(item.id)
                
                var messages: [EngineMessage] = []
                if let topMessage = item.topMessage {
                    messages.append(EngineMessage(topMessage))
                }
                
                let mappedMessageIndex = MessageIndex(id: MessageId(peerId: sourceId, namespace: item.index.id.namespace, id: item.index.id.id), timestamp: item.index.timestamp)
                
                let readCounters = EnginePeerReadCounters(state: CombinedPeerReadState(states: [(Namespaces.Message.Cloud, .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 0, count: Int32(item.unreadCount), markedUnread: item.markedUnread))]), isMuted: false)
                
                var itemDraft: EngineChatList.Draft?
                if let embeddedState = item.embeddedInterfaceState, let _ = embeddedState.overrideChatTimestamp {
                    if let opaqueState = _internal_decodeStoredChatInterfaceState(state: embeddedState) {
                        if let text = opaqueState.synchronizeableInputState?.text {
                            itemDraft = EngineChatList.Draft(text: text, entities: opaqueState.synchronizeableInputState?.entities ?? [])
                        }
                    }
                }
                
                items.append(EngineChatList.Item(
                    id: .chatList(sourceId),
                    index: .chatList(ChatListIndex(pinningIndex: item.pinnedIndex.flatMap(UInt16.init), messageIndex: mappedMessageIndex)),
                    messages: messages,
                    readCounters: readCounters,
                    isMuted: false,
                    draft: sourceId == accountPeerId ? draft : itemDraft,
                    threadData: nil,
                    renderedPeer: EngineRenderedPeer(peer: EnginePeer(sourcePeer)),
                    presence: nil,
                    hasUnseenMentions: false,
                    hasUnseenReactions: false,
                    hasUnseenPollVotes: false,
                    forumTopicData: nil,
                    topForumTopicItems: [],
                    hasFailed: false,
                    isContact: false,
                    autoremoveTimeout: nil,
                    storyStats: nil,
                    displayAsTopicList: false,
                    isPremiumRequiredToMessage: false,
                    mediaDraftContentType: nil
                ))
            }
            
            let list = EngineChatList(
                items: items.reversed(),
                groupItems: [],
                additionalItems: [],
                hasEarlier: false,
                hasLater: false,
                isLoading: view.isLoading
            )
            
            let type: ViewUpdateType
            if isFirst {
                type = .Initial
            } else {
                type = .Generic
            }
            isFirst = false
            return ChatListNodeViewUpdate(list: list, type: type, scrollPosition: nil)
        }
    }
}
