// Zenlygram — chat UI helpers for kept-deleted messages ("Show Deleted Messages", audit Batch 6).
// Upstream files call into this file through one-line "// SG:" hooks:
//  - ChatInterfaceStateContextMenus.swift: "Remove All Deleted in This Chat" context item (#44)
//  - ChatController.swift (openMessage): undownloaded media of a kept-deleted copy (#85)
import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import Display
import AppBundle
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import PresentationDataUtils
import UndoUI
import ChatControllerInteraction
import PhotoResources
import SGStrings
import SGSimpleSettings

/// Context menu item shown on a kept-deleted message: removes every kept-deleted copy of this chat
/// from the device after a confirmation that shows how many there are (#44).
func sgRemoveKeptDeletedInChatContextItem(context: AccountContext, peerId: EnginePeer.Id, strings: PresentationStrings, controllerInteraction: ChatControllerInteraction) -> ContextMenuItem {
    let lang = strings.baseLanguageCode
    return .action(ContextMenuActionItem(text: i18n("ContextMenu.KeptDeleted.RemoveAllInChat", lang), textColor: .destructive, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
    }, action: { c, _ in
        c?.dismiss(completion: {
            let _ = (sgKeptDeletedMessageCount(account: context.account, peerId: peerId)
            |> deliverOnMainQueue).startStandalone(next: { count in
                // 0 only while a legacy (pre-index) copy waits for its one-time migration;
                // the per-message Delete still removes it.
                guard count > 0 else {
                    return
                }
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                controllerInteraction.presentController(textAlertController(
                    context: context,
                    title: nil,
                    text: i18n("ContextMenu.KeptDeleted.RemoveAllInChat.Text", lang, "\(count)"),
                    actions: [
                        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                        TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                            let _ = (sgRemoveKeptDeletedMessages(account: context.account, peerId: peerId)
                            |> deliverOnMainQueue).startStandalone(next: { _ in
                                controllerInteraction.displayUndo(.info(title: nil, text: i18n("Settings.Retention.Removed", lang), timeout: nil, customUndoText: nil))
                            })
                        })
                    ]
                ), nil)
            })
        })
    }))
}

/// True when the kept-deleted copy's media can still be opened: it has no photo/file, or its primary
/// resource is fully downloaded. The server copy is gone, so a missing resource can never be fetched (#85).
/// For a photo this checks `largestRepresentationForPhoto` (the progressive / <=1280px size), the same
/// representation the bubble's `chatMessagePhotoStatus` and ChatImageGalleryItem load. The bubble asks for
/// that status with `displayAtSize: nil`, i.e. the whole resource, so `completedResourcePath` agrees with
/// what the bubble shows and no partial-range check is needed. For a file it checks the file resource.
func sgKeptDeletedMediaIsLocal(message: Message, mediaBox: MediaBox) -> Bool {
    for media in message.media {
        if let image = media as? TelegramMediaImage {
            guard let representation = largestRepresentationForPhoto(image) else {
                return false
            }
            return mediaBox.completedResourcePath(representation.resource) != nil
        } else if let file = media as? TelegramMediaFile {
            return mediaBox.completedResourcePath(file.resource) != nil
        }
    }
    return true
}

/// In-chat search: the local fallback of `searchMessages` matches the text of kept-deleted copies, so while the user
/// has "Show Deleted Messages" off (the chat hides them) a search would count, scroll to and list a hit the chat does
/// not show. Same cut as the chat-list search (`ChatListSearchListPaneNode`): the hits leave the result and its count.
/// Remote results never contain kept-deleted copies, so a filtered result is never "incomplete".
func sgFilterHiddenKeptDeletedSearchResults(_ result: SearchMessagesResult) -> SearchMessagesResult {
    guard result.messages.contains(where: { $0.sgIsKeptDeleted }) else {
        return result
    }
    guard !SGSimpleSettings.shared.showDeletedMessages else {
        return result
    }
    let messages = result.messages.filter { !$0.sgIsKeptDeleted }
    let dropped = Int32(result.messages.count - messages.count)
    return SearchMessagesResult(messages: messages, readStates: result.readStates, threadInfo: result.threadInfo, totalCount: max(0, result.totalCount - dropped), completed: result.completed)
}

/// openMessage hook: for a kept-deleted message whose media was never downloaded, shows an
/// "unavailable" toast instead of starting a fetch/gallery that would spin forever. Returns true when handled.
func sgHandleKeptDeletedMediaOpen(message: Message, context: AccountContext, presentationData: PresentationData, present: (ViewController) -> Void) -> Bool {
    guard message.sgIsKeptDeleted, !sgKeptDeletedMediaIsLocal(message: message, mediaBox: context.account.postbox.mediaBox) else {
        return false
    }
    present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: i18n("Chat.KeptDeleted.MediaUnavailable.Text", presentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true }))
    return true
}
