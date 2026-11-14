// MARK: Zenlygram — "Review muted chats" (audit batch 4, item #74)
//
// The Secret Vault mutes every chat it hides (forever, `until == Int32.max`) and remembers which ones it
// muted in an app-private, DEVICE-ONLY keychain blob. After a migration to a new iPhone that bookkeeping is
// gone while the chats are still muted forever on the server, so turning the vault off can no longer unmute
// them by itself — and it must not unmute everything blindly, because the same list also contains chats the
// user muted forever themselves.
//
// This screen shows that list and lets the user pick. NOTHING is pre-selected, and the confirmation names
// the count, exactly because the app can no longer tell the two kinds apart.

import SGChatLock
import SGSimpleSettings

import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import ItemListPeerItem
import AccountContext

// MARK: - Module-local copy
//
// The recovery copy lives in SGChatLock (`SGProtectionStrings`) so every surface shares it. These few lines
// are needed only by SGSettingsUI, so they stay here rather than growing the shared enum — same en/uz/ru
// shape and the same language source, so the whole recovery flow reads in one language.
enum SGProtectionLocalCopy {
    /// The vault credential exists but cannot be read right now (device just booted, protected data still
    /// unavailable): a PIN screen would refuse even the right PIN, so no screen is opened at all.
    static var vaultUnreadableTitle: String {
        localized(
            en: "Try again in a moment",
            uz: "Birozdan so'ng qayta urining",
            ru: "Попробуйте через минуту"
        )
    }

    static var vaultUnreadableText: String {
        localized(
            en: "The vault PIN cannot be checked right now. Unlock this device, wait a moment and try again.",
            uz: "Hozir seyf PIN kodini tekshirib bo'lmaydi. Qurilma qulfini oching, biroz kuting va qayta urinib ko'ring.",
            ru: "Сейчас PIN хранилища нельзя проверить. Разблокируйте устройство, подождите немного и попробуйте снова."
        )
    }

    /// The muted-chat review found nothing muted forever.
    static var mutedReviewEmpty: String {
        localized(
            en: "No chats are muted forever on this account.",
            uz: "Bu akkauntda butunlay ovozsiz qilingan chat yo'q.",
            ru: "В этом аккаунте нет чатов, отключённых навсегда."
        )
    }

    private static func localized(en: String, uz: String, ru: String) -> String {
        switch SGSimpleSettings.shared.languageCode {
        case "uz": return uz
        case "ru": return ru
        default:   return en
        }
    }
}

// MARK: - Arguments

private final class SGVaultMutedChatsArguments {
    let context: AccountContext
    let togglePeer: (EnginePeer.Id) -> Void

    init(context: AccountContext, togglePeer: @escaping (EnginePeer.Id) -> Void) {
        self.context = context
        self.togglePeer = togglePeer
    }
}

// MARK: - Entries

private enum SGVaultMutedChatsSection: Int32 {
    case list
}

private enum SGVaultMutedChatsEntry: ItemListNodeEntry {
    /// (text, isLoading)
    case header(String, Bool)
    /// (order index, peer, isSelected)
    case peer(Int32, EnginePeer, Bool)
    case footer(String)

    var section: ItemListSectionId {
        return SGVaultMutedChatsSection.list.rawValue
    }

    var stableId: Int64 {
        switch self {
        case .header:
            return Int64.min
        case let .peer(_, peer, _):
            return peer.id.toInt64()
        case .footer:
            return Int64.max
        }
    }

    /// Header first, peers in name order, footer last.
    private var sortIndex: Int32 {
        switch self {
        case .header:
            return 0
        case let .peer(index, _, _):
            return 1 + index
        case .footer:
            return Int32.max
        }
    }

    static func == (lhs: SGVaultMutedChatsEntry, rhs: SGVaultMutedChatsEntry) -> Bool {
        switch lhs {
        case let .header(lText, lLoading):
            if case let .header(rText, rLoading) = rhs, lText == rText, lLoading == rLoading {
                return true
            }
            return false
        case let .peer(lIndex, lPeer, lSelected):
            if case let .peer(rIndex, rPeer, rSelected) = rhs, lIndex == rIndex, lPeer == rPeer, lSelected == rSelected {
                return true
            }
            return false
        case let .footer(lText):
            if case let .footer(rText) = rhs, lText == rText {
                return true
            }
            return false
        }
    }

    static func < (lhs: SGVaultMutedChatsEntry, rhs: SGVaultMutedChatsEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGVaultMutedChatsArguments
        switch self {
        case let .header(text, isLoading):
            return ItemListSectionHeaderItem(
                presentationData: presentationData,
                text: text,
                multiline: true,
                activityIndicator: isLoading ? ItemListSectionHeaderActivityIndicator.left : ItemListSectionHeaderActivityIndicator.none,
                sectionId: self.section
            )
        case let .peer(_, peer, isSelected):
            return ItemListPeerItem(
                presentationData: presentationData,
                dateTimeFormat: presentationData.dateTimeFormat,
                nameDisplayOrder: presentationData.nameDisplayOrder,
                context: arguments.context,
                peer: peer,
                presence: nil,
                text: .none,
                label: .none,
                editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false),
                switchValue: ItemListPeerItemSwitch(value: isSelected, style: .check),
                enabled: true,
                selectable: true,
                sectionId: self.section,
                action: {
                    arguments.togglePeer(peer.id)
                },
                setPeerIdWithRevealedOptions: { _, _ in },
                removePeer: { _ in }
            )
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

// MARK: - State

private struct SGVaultMutedChatsState: Equatable {
    var selectedPeerIds: Set<EnginePeer.Id> = []
    /// True while the unmute requests are in flight, so the button cannot be tapped twice.
    var isApplying: Bool = false
}

private func sgVaultMutedChatsEntries(peers: [EnginePeer]?, state: SGVaultMutedChatsState) -> [SGVaultMutedChatsEntry] {
    var entries: [SGVaultMutedChatsEntry] = []
    guard let peers = peers else {
        entries.append(.header(SGProtectionStrings.mutedReviewHeader(count: 0), true))
        entries.append(.footer(SGProtectionStrings.mutedReviewFooter))
        return entries
    }
    // The header counts what is actually on screen: these ARE the chats muted forever right now.
    entries.append(.header(SGProtectionStrings.mutedReviewHeader(count: peers.count), false))
    if peers.isEmpty {
        entries.append(.footer(SGProtectionLocalCopy.mutedReviewEmpty))
        return entries
    }
    for (index, peer) in peers.enumerated() {
        entries.append(.peer(Int32(index), peer, state.selectedPeerIds.contains(peer.id)))
    }
    entries.append(.footer(SGProtectionStrings.mutedReviewFooter))
    return entries
}

// MARK: - Controller

/// Lists the chats of the current account that are muted forever, so the user can turn notifications back on
/// for the ones the vault had silenced (audit #74). Reached from the "Restore protection" action sheet and
/// offered right after a vault teardown that could not unmute anything itself.
func sgVaultMutedChatsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var dismissImpl: (() -> Void)?

    let initialState = SGVaultMutedChatsState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((SGVaultMutedChatsState) -> SGVaultMutedChatsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let applyDisposable = MetaDisposable()

    let arguments = SGVaultMutedChatsArguments(context: context, togglePeer: { peerId in
        updateState { current in
            var updated = current
            if updated.selectedPeerIds.contains(peerId) {
                updated.selectedPeerIds.remove(peerId)
            } else {
                updated.selectedPeerIds.insert(peerId)
            }
            return updated
        }
    })

    // nil = still loading (the list is a network request).
    let exceptionsPromise = Promise<NotificationExceptionsList?>()
    exceptionsPromise.set(Signal<NotificationExceptionsList?, NoError>.single(nil)
    |> then(context.engine.peers.notificationExceptionsList() |> map(Optional.init)))

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), exceptionsPromise.get())
    |> map { presentationData, state, exceptions -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var peers: [EnginePeer]?
        if let exceptions = exceptions {
            var result: [EnginePeer] = []
            for (peerId, settings) in exceptions.settings {
                // Only "muted forever" — that is what the vault applies; a timed mute is always the user's own.
                guard case let .muted(until) = settings.muteState, until == Int32.max else {
                    continue
                }
                guard peerId != context.account.peerId, let peer = exceptions.peers[peerId] else {
                    continue
                }
                result.append(peer)
            }
            result.sort { lhs, rhs in
                let lhsTitle = lhs.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                let rhsTitle = rhs.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                if lhsTitle != rhsTitle {
                    return lhsTitle < rhsTitle
                }
                return lhs.id < rhs.id
            }
            peers = result
        }

        let selectedCount = state.selectedPeerIds.count
        let rightNavigationButton = ItemListNavigationButton(
            content: .text(SGProtectionStrings.mutedReviewUnmuteSelected(count: selectedCount)),
            style: .bold,
            enabled: selectedCount > 0 && !state.isApplying,
            action: {
                let peerIds = stateValue.with { $0.selectedPeerIds }
                guard !peerIds.isEmpty else {
                    return
                }
                // The list also contains chats the user muted themselves, so the confirmation names the count.
                presentControllerImpl?(textAlertController(context: context, title: SGProtectionStrings.mutedReviewTitle, text: SGProtectionStrings.mutedReviewConfirmText(count: peerIds.count), actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .defaultAction, title: SGProtectionStrings.mutedReviewUnmuteSelected(count: peerIds.count), action: {
                        updateState { current in
                            var updated = current
                            updated.isApplying = true
                            return updated
                        }
                        let signals = peerIds.map { peerId in
                            context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 0)
                        }
                        applyDisposable.set((combineLatest(signals)
                        |> deliverOnMainQueue).startStrict(completed: {
                            dismissImpl?()
                        }))
                    })
                ]), nil)
            }
        )

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(SGProtectionStrings.mutedReviewTitle),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: sgVaultMutedChatsEntries(peers: peers, state: state),
            style: .blocks
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        applyDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    dismissImpl = { [weak controller] in
        // The screen is pushed (from Settings or from the recovery sheet), so it pops.
        guard let controller = controller else {
            return
        }
        if let navigationController = controller.navigationController as? NavigationController {
            navigationController.filterController(controller, animated: true)
        } else {
            controller.dismiss()
        }
    }
    return controller
}
