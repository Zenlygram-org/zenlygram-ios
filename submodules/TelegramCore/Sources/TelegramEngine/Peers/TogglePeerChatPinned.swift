import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

public enum TogglePeerChatPinnedLocation {
    case group(PeerGroupId)
    case filter(Int32)
}

public enum TogglePeerChatPinnedResult {
    case done
    case limitExceeded(count: Int, limit: Int)
}

func _internal_toggleItemPinned(postbox: Postbox, accountPeerId: PeerId, location: TogglePeerChatPinnedLocation, itemId: PinnedItemId) -> Signal<TogglePeerChatPinnedResult, NoError> {
    return postbox.transaction { transaction -> TogglePeerChatPinnedResult in
        let isPremium = transaction.getPeer(accountPeerId)?.isPremium ?? false
        
        let appConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? .defaultValue
        let userLimitsConfiguration = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: isPremium)
        
        switch location {
        case let .group(groupId):
            var itemIds = transaction.getPinnedItemIds(groupId: groupId)
            if itemIds.firstIndex(of: itemId) == nil {
                switch itemId {
                case let .peer(peerId):
                    if let community = transaction.getPeer(peerId) as? TelegramCommunity, community.collapsedInDialogs != true {
                        return .done
                    }
                }
            }
            let sameKind = itemIds.filter { item in
                switch itemId {
                    case let .peer(lhsPeerId):
                        if case let .peer(rhsPeerId) = item {
                            return (lhsPeerId.namespace == Namespaces.Peer.SecretChat) == (rhsPeerId.namespace == Namespaces.Peer.SecretChat) && lhsPeerId != rhsPeerId
                        } else {
                            return false
                        }
                }
                
            }
            
            let additionalCount: Int
            if let _ = itemIds.firstIndex(of: itemId) {
                additionalCount = -1
            } else {
                additionalCount = 1
            }
            
            var limitCount: Int
            if case .root = groupId {
                limitCount = Int(userLimitsConfiguration.maxPinnedChatCount)
            } else {
                limitCount = Int(userLimitsConfiguration.maxArchivedPinnedChatCount)
            }
            // Zenlygram — #33: the real Telegram limit, kept before the local cap is raised below.
            let sgServerLimitCount = limitCount
            // MARK: Swiftgram
            if SGSimpleSettings.shared.unlimitedPinnedChats {
                limitCount = 1000
            }
            // Zenlygram — #33: pins above Telegram's limit that live only on this device. Entries
            // that are no longer pinned locally (e.g. the chat was deleted) are stale: drop them
            // first so re-pinning that chat behaves normally.
            let sgStoredExtras = sgLocalExtraPins(transaction: transaction, groupId: groupId)
            let sgExtras = sgStoredExtras.filter { itemIds.contains($0) }
            if sgExtras != sgStoredExtras {
                sgSetLocalExtraPins(transaction: transaction, groupId: groupId, sgExtras)
            }
            
            let count = sameKind.count + additionalCount
            if count > limitCount, itemIds.firstIndex(of: itemId) == nil {
                return .limitExceeded(count: sameKind.count, limit: limitCount)
            } else {
                // Zenlygram — #33: device-local over-limit pins are never sent to Telegram (no
                // synchronize operation), so the server never receives a list above its limit.
                if sgExtras.contains(itemId), let index = itemIds.firstIndex(of: itemId) {
                    // Unpinning a device-local extra: purely local.
                    itemIds.remove(at: index)
                    sgSetLocalExtraPins(transaction: transaction, groupId: groupId, sgExtras.filter { $0 != itemId })
                    transaction.setPinnedItemIds(groupId: groupId, itemIds: itemIds)
                    return .done
                }
                if itemIds.firstIndex(of: itemId) == nil, SGSimpleSettings.shared.unlimitedPinnedChats, case let .peer(peerId) = itemId, peerId.namespace != Namespaces.Peer.SecretChat, sameKind.filter({ !sgExtras.contains($0) }).count + 1 > sgServerLimitCount {
                    // Pinning above Telegram's limit: keep it on this device, below the synced pins.
                    itemIds.append(itemId)
                    sgSetLocalExtraPins(transaction: transaction, groupId: groupId, sgExtras + [itemId])
                    transaction.setPinnedItemIds(groupId: groupId, itemIds: itemIds)
                    return .done
                }
                if let index = itemIds.firstIndex(of: itemId) {
                    itemIds.remove(at: index)
                } else {
                    itemIds.insert(itemId, at: 0)
                }
                addSynchronizePinnedChatsOperation(transaction: transaction, groupId: groupId)
                transaction.setPinnedItemIds(groupId: groupId, itemIds: itemIds)
                return .done
            }
        case let .filter(filterId):
            var result: TogglePeerChatPinnedResult = .done
            _internal_updateChatListFiltersInteractively(transaction: transaction, { filters in
                var filters = filters
                if let index = filters.firstIndex(where: { $0.id == filterId }), case let .filter(id, title, emoticon, data) = filters[index] {
                    switch itemId {
                    case let .peer(peerId):
                        var updatedData = data
                        if updatedData.includePeers.pinnedPeers.contains(peerId) {
                            updatedData.includePeers.removePinnedPeer(peerId)
                        } else {
                            let _ = updatedData.includePeers.addPinnedPeer(peerId)
                            if updatedData.includePeers.peers.count > userLimitsConfiguration.maxFolderChatsCount {
                                result = .limitExceeded(count: updatedData.includePeers.peers.count, limit: Int(userLimitsConfiguration.maxFolderChatsCount))
                                updatedData = data
                            }
                        }
                        filters[index] = .filter(id: id, title: title, emoticon: emoticon, data: updatedData)
                    }
                }
                return filters
            })
            return result
        }
    }
}

// MARK: Zenlygram — #33 device-local over-limit pins
//
// With "Unlimited Pinned Chats" on, pins above Telegram's server limit are kept only on this
// device. They are stored in the account Postbox as a preferences entry per chat-list group (so
// they are per account, written in the same transaction as setPinnedItemIds, and shared with the
// app extensions). They are never included in messages.reorderPinnedDialogs, and are re-appended
// below the synced pins after every pinned sync (ManagedSynchronizePinnedChatsOperations),
// chat-list refetch (Holes) and state reset (ResetState). The store is the source of truth: the
// toggle only gates creating new extras (main app); turning it off keeps existing extras until
// they are unpinned (a local-only unpin). With an empty store, behaviour is exactly upstream.

private struct SGLocalExtraPinsEntry: Codable {
    var peerIds: [Int64]
}

private func sgLocalExtraPinsKey(groupId: PeerGroupId) -> ValueBoxKey {
    let key = ValueBoxKey(length: 8)
    key.setInt32(0, value: 0x5A470021) // "ZG"+#33; outside PreferencesKeyValues (0...49) and applicationSpecific (1000+)
    key.setInt32(4, value: groupId.rawValue)
    return key
}

/// The raw store of device-local extra pins for `groupId`, in pin order.
func sgLocalExtraPins(transaction: Transaction, groupId: PeerGroupId) -> [PinnedItemId] {
    guard let entry = transaction.getPreferencesEntry(key: sgLocalExtraPinsKey(groupId: groupId))?.get(SGLocalExtraPinsEntry.self) else {
        return []
    }
    return entry.peerIds.map { PinnedItemId.peer(PeerId($0)) }
}

/// Replaces the store for `groupId`. Every removal from the store goes through here, so ids that
/// stop being device-local are also scrubbed from pending pinned-sync operations (see below).
func sgSetLocalExtraPins(transaction: Transaction, groupId: PeerGroupId, _ items: [PinnedItemId]) {
    let previous = sgLocalExtraPins(transaction: transaction, groupId: groupId)
    if previous == items {
        return
    }
    let peerIds: [Int64] = items.map { item in
        switch item {
        case let .peer(peerId):
            return peerId.toInt64()
        }
    }
    transaction.setPreferencesEntry(key: sgLocalExtraPinsKey(groupId: groupId), value: items.isEmpty ? nil : PreferencesEntry(SGLocalExtraPinsEntry(peerIds: peerIds)))
    
    // A pending SynchronizePinnedChats operation snapshots the pinned list (extras included) in
    // previousItemIds. Once an id leaves the store the sync no longer filters it out, so that
    // stale snapshot would make it look "removed remotely" and silently unpin it later (e.g. a
    // former extra that is re-pinned normally). Drop such ids from the snapshots, in place (same
    // tagLocalIndex), so an operation that is being processed can still be removed afterwards.
    let removed = Set(previous).subtracting(items)
    if removed.isEmpty {
        return
    }
    let opPeerId = PeerId(namespace: PeerId.Namespace._internalFromInt32Value(0), id: PeerId.Id._internalFromInt64Value(Int64(groupId.rawValue)))
    var updates: [(Int32, [PinnedItemId])] = []
    transaction.operationLogEnumerateEntries(peerId: opPeerId, tag: OperationLogTags.SynchronizePinnedChats, { entry in
        if let operation = entry.contents as? SynchronizePinnedChatsOperation, operation.previousItemIds.contains(where: { removed.contains($0) }) {
            updates.append((entry.tagLocalIndex, operation.previousItemIds.filter { !removed.contains($0) }))
        }
        return true
    })
    for (tagLocalIndex, itemIds) in updates {
        transaction.operationLogUpdateEntry(peerId: opPeerId, tag: OperationLogTags.SynchronizePinnedChats, tagLocalIndex: tagLocalIndex, { _ in
            return PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .update(SynchronizePinnedChatsOperation(previousItemIds: itemIds)))
        })
    }
}

/// Removes `itemIds` from the store: Telegram now counts them as pinned (pinned from another
/// device), so they become normal synced pins. No-op when the store is empty.
func sgForgetLocalExtraPins(transaction: Transaction, groupId: PeerGroupId, itemIds: [PinnedItemId]) {
    let stored = sgLocalExtraPins(transaction: transaction, groupId: groupId)
    if stored.isEmpty {
        return
    }
    let forget = Set(itemIds)
    sgSetLocalExtraPins(transaction: transaction, groupId: groupId, stored.filter { !forget.contains($0) })
}

/// Returns `serverItemIds` followed by the still-valid device-local extra pins, in their current
/// local order, and prunes the store. Must be called before `setPinnedItemIds` replaces the list
/// (and before any inclusion update that clears pinning indices), so the current local order is
/// still readable. Returns `serverItemIds` unchanged when the store is empty. Deliberately does
/// not read the "Unlimited Pinned Chats" toggle: this also runs in app extensions, where the
/// per-process setting reads its default and would wipe the shared store.
func sgPinnedItemIdsAppendingLocalExtras(transaction: Transaction, accountPeerId: PeerId, groupId: PeerGroupId, serverItemIds: [PinnedItemId]) -> [PinnedItemId] {
    let stored = sgLocalExtraPins(transaction: transaction, groupId: groupId)
    if stored.isEmpty {
        return serverItemIds
    }
    let storedSet = Set(stored)
    let serverSet = Set(serverItemIds)
    // Only extras that are still pinned locally are kept. An extra that left the local pinned
    // list (chat deleted/left, or unpinned by a remote update) is dropped, so it does not come
    // back pinned when the chat reappears later. An extra that Telegram now reports as pinned
    // (pinned on another device) becomes a normal synced pin.
    let kept = transaction.getPinnedItemIds(groupId: groupId).filter { item in
        guard storedSet.contains(item), !serverSet.contains(item) else {
            return false
        }
        switch item {
        case let .peer(peerId):
            return transaction.getPeer(peerId) != nil && transaction.getPeerChatListInclusion(peerId) != .notIncluded
        }
    }
    sgSetLocalExtraPins(transaction: transaction, groupId: groupId, kept)
    return serverItemIds + kept
}

func _internal_getPinnedItemIds(transaction: Transaction, location: TogglePeerChatPinnedLocation) -> [PinnedItemId] {
    switch location {
    case let .group(groupId):
        return transaction.getPinnedItemIds(groupId: groupId)
    case let .filter(filterId):
        var itemIds: [PinnedItemId] = []
        let _ = _internal_updateChatListFiltersInteractively(transaction: transaction, { filters in
            if let index = filters.firstIndex(where: { $0.id == filterId }), case let .filter(_, _, _, data) = filters[index] {
                itemIds = data.includePeers.pinnedPeers.map { peerId in
                    return .peer(peerId)
                }
            }
            return filters
        })
        return itemIds
    }
}

func _internal_reorderPinnedItemIds(transaction: Transaction, location: TogglePeerChatPinnedLocation, itemIds: [PinnedItemId]) -> Bool {
    switch location {
    case let .group(groupId):
        if transaction.getPinnedItemIds(groupId: groupId) != itemIds {
            transaction.setPinnedItemIds(groupId: groupId, itemIds: itemIds)
            addSynchronizePinnedChatsOperation(transaction: transaction, groupId: groupId)
            return true
        } else {
            return false
        }
    case let .filter(filterId):
        var result: Bool = false
        _internal_updateChatListFiltersInteractively(transaction: transaction, { filters in
            var filters = filters
            if let index = filters.firstIndex(where: { $0.id == filterId }), case let .filter(id, title, emoticon, data) = filters[index] {
                let peerIds: [PeerId] = itemIds.map { itemId -> PeerId in
                    switch itemId {
                    case let .peer(peerId):
                        return peerId
                    }
                }
                
                var updatedData = data
                if updatedData.includePeers.pinnedPeers != peerIds {
                    updatedData.includePeers.reorderPinnedPeers(peerIds)
                    filters[index] = .filter(id: id, title: title, emoticon: emoticon, data: updatedData)
                    result = true
                }
            }
            return filters
        })
        return result
    }
}
