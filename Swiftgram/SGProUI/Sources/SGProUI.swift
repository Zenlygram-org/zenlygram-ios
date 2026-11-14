import Foundation
import UniformTypeIdentifiers
import SGItemListUI
import UndoUI
import AccountContext
import Display
import TelegramCore
import Postbox
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import TelegramUIPreferences
import SettingsUI

// Optional
import SGSimpleSettings
import SGLogging


private enum SGProControllerSection: Int32, SGItemListSection {
    case base
    case appearance
    case notifications
    case footer
}

private enum SGProDisclosureLink: String {
    case sessionBackupManager
    case messageFilter
    case appIcons
    case appBages
}

private enum SGProToggles: String {
    case inputToolbar
}

private enum SGProOneFromManySetting: String {
    case pinnedMessageNotifications
    case mentionsAndRepliesNotifications
}

// MARK: Zenlygram — no actions on this screen.
//
// It used to carry a "Reset Pro" row whose handler forced `status = SGStatus.default.status`
// (design §8.3 item 16). Two things make that wrong here. It was a DEBUG-only row wired to a
// handler that was compiled into RELEASE, and `SGStatus` is not the Zenlygram subscription at all —
// it is upstream Swiftgram's own Pro flag, permanently clamped to Pro because those extras are free
// here. Zenlygram Pro is `SGEntitlement`, and the one debug affordance that resets the local
// purchase state now lives in `SGDebugUI` under `#if DEBUG`, where a debug affordance belongs.
//
// The enum stays (caseless) because `SGItemListArguments` is generic over it; its `action:` closure
// now takes its default no-op.
private enum SGProAction: Hashable {
}

private typealias SGProControllerEntry = SGItemListUIEntry<SGProControllerSection, SGProToggles, AnyHashable, SGProOneFromManySetting, SGProDisclosureLink, SGProAction>

// MARK: Zenlygram — the pinned-message and mentions/replies notification settings are applied
// only by the NotificationService extension, which never runs: Telegram doesn't deliver APNs pushes
// to the custom bundle. The rows are hidden so the screen shows no settings without an effect
// (Guideline 2.1). Flipping this to true restores them; the settings and handlers are unchanged.
private let sgProNotificationSettingsAvailable: Bool = false

private func SGProControllerEntries(presentationData: PresentationData) -> [SGProControllerEntry] {
    var entries: [SGProControllerEntry] = []
    let lang = presentationData.strings.baseLanguageCode
    
    let id = SGItemListCounter()
    
    entries.append(.disclosure(id: id.count, section: .base, link: .sessionBackupManager, text: "SessionBackup.Title".i18n(lang)))
    entries.append(.disclosure(id: id.count, section: .base, link: .messageFilter, text: "MessageFilter.Title".i18n(lang)))
    entries.append(.toggle(id: id.count, section: .base, settingName: .inputToolbar, value: SGSimpleSettings.shared.inputToolbar, text: "InputToolbar.Title".i18n(lang), enabled: true))
    
    if sgProNotificationSettingsAvailable {
        entries.append(.header(id: id.count, section: .notifications, text: presentationData.strings.Notifications_Title.uppercased(), badge: nil))
        entries.append(.oneFromManySelector(id: id.count, section: .notifications, settingName: .pinnedMessageNotifications, text: "Notifications.PinnedMessages.Title".i18n(lang), value: "Notifications.PinnedMessages.value.\(SGSimpleSettings.shared.pinnedMessageNotifications)".i18n(lang), enabled: true))
        entries.append(.oneFromManySelector(id: id.count, section: .notifications, settingName: .mentionsAndRepliesNotifications, text: "Notifications.MentionsAndReplies.Title".i18n(lang), value: "Notifications.MentionsAndReplies.value.\(SGSimpleSettings.shared.mentionsAndRepliesNotifications)".i18n(lang), enabled: true))
    }
    entries.append(.header(id: id.count, section: .appearance, text: presentationData.strings.Appearance_Title.uppercased(), badge: nil))
    entries.append(.disclosure(id: id.count, section: .appearance, link: .appIcons, text: presentationData.strings.Appearance_AppIcon))
    entries.append(.disclosure(id: id.count, section: .appearance, link: .appBages, text: "AppBadge.Title".i18n(lang)))
    entries.append(.notice(id: id.count, section: .appearance, text: "AppBadge.Notice".i18n(lang)))

    return entries
}

public func okUndoController(_ text: String, _ presentationData: PresentationData) -> UndoOverlayController {
    return UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false })
}

public func sgProController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let simplePromise = ValuePromise(true, ignoreRepeated: false)
    
    let arguments = SGItemListArguments<SGProToggles, AnyHashable, SGProOneFromManySetting, SGProDisclosureLink, SGProAction>(context: context, setBoolValue: { toggleName, value in
        switch toggleName {
            case .inputToolbar:
                SGSimpleSettings.shared.inputToolbar = value
        }
    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        
        switch (setting) {
            case .pinnedMessageNotifications:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.pinnedMessageNotifications = value
                    SGSimpleSettings.shared.synchronizeShared()
                    simplePromise.set(true)
                }

                for value in SGSimpleSettings.PinnedMessageNotificationsSettings.allCases {
                    items.append(ActionSheetButtonItem(title: "Notifications.PinnedMessages.value.\(value.rawValue)".i18n(lang), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .mentionsAndRepliesNotifications:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.mentionsAndRepliesNotifications = value
                    SGSimpleSettings.shared.synchronizeShared()
                    simplePromise.set(true)
                }

                for value in SGSimpleSettings.MentionsAndRepliesNotificationsSettings.allCases {
                    items.append(ActionSheetButtonItem(title: "Notifications.MentionsAndReplies.value.\(value.rawValue)".i18n(lang), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
        }
        
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }, openDisclosureLink: { link in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        switch (link) {
            case .sessionBackupManager:
                pushControllerImpl?(sgSessionBackupManagerController(context: context, presentationData: presentationData))
            case .messageFilter:
                pushControllerImpl?(sgMessageFilterController(presentationData: presentationData))
            case .appIcons:
                pushControllerImpl?(themeSettingsController(context: context, focusOnItemTag: .icon))
            case .appBages:
                if #available(iOS 14.0, *) {
                    pushControllerImpl?(sgAppBadgeSettingsController(context: context, presentationData: presentationData))
                } else {
                    presentControllerImpl?(context.sharedContext.makeSGUpdateIOSController(), nil)
                }
        }
    })
    
    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ ->  (ItemListControllerState, (ItemListNodeState, Any)) in
        
        let entries = SGProControllerEntries(presentationData: presentationData)
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Zenlygram Pro"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: /*focusOnItemTag*/ nil, initialScrollToItem: nil /* scrollToItem*/ )
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    // Workaround
    let _ = pushControllerImpl
    
    return controller
}


