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

// Optional
import SGSimpleSettings
import SGLogging
import SGIAP
import SGPayWall
import SGEntitlement
import SGAppUpdateUI
import OverlayStatusController
#if DEBUG
import FLEX
#endif


private enum SGDebugControllerSection: Int32, SGItemListSection {
    case base
    case notifications
}

private enum SGDebugDisclosureLink: String {
    case sessionBackupManager
    case messageFilter
    case debugIAP
}

private enum SGDebugActions: String {
    case flexing
    case fileManager
    case clearRegDateCache
    case clearOutgoingTranslationLanguageCache
    case restorePurchases
    case setIAP
    case resetIAP
}

private enum SGDebugToggles: String {
    case forceImmediateShareSheet
    case legacyNotificationsFix
    case inputToolbar
}


private enum SGDebugOneFromManySetting: String {
    case pinnedMessageNotifications
    case mentionsAndRepliesNotifications
    /// Zenlygram — the QA override of the app-update decision (update_policy_spec §4h).
    case appUpdateOverride
}

private typealias SGDebugControllerEntry = SGItemListUIEntry<SGDebugControllerSection, SGDebugToggles, AnyHashable, SGDebugOneFromManySetting, SGDebugDisclosureLink, SGDebugActions>

private func SGDebugControllerEntries(presentationData: PresentationData) -> [SGDebugControllerEntry] {
    var entries: [SGDebugControllerEntry] = []
    
    let id = SGItemListCounter()
    #if DEBUG
    entries.append(.action(id: id.count, section: .base, actionType: .flexing, text: "FLEX", kind: .generic))
    entries.append(.action(id: id.count, section: .base, actionType: .fileManager, text: "FileManager", kind: .generic))
    #endif

    entries.append(.action(id: id.count, section: .base, actionType: .clearRegDateCache, text: "Clear Regdate cache", kind: .generic))
    entries.append(.action(id: id.count, section: .base, actionType: .clearOutgoingTranslationLanguageCache, text: "Clear Outgoing Translation cache", kind: .generic))
    entries.append(.toggle(id: id.count, section: .base, settingName: .forceImmediateShareSheet, value: SGSimpleSettings.shared.forceSystemSharing, text: "Force System Share Sheet", enabled: true))
    // MARK: Zenlygram — the QA override of the app-update decision (update_policy_spec §4h): none / remind / block.
    // Compiled into non-store builds only (`SG_APP_UPDATE_DEBUG_OVERRIDE`, from the build configuration's
    // `is_appstore_build` — Swiftgram/SGAppUpdate/debug_override.bzl); the runtime guard is the belt, and the
    // presenter ignores the value in a store build too. It replaces the decision only and never writes a signed
    // policy. `SGSimpleSettings.appUpdateDebugOverride` documents the `defaults write` form.
    #if SG_APP_UPDATE_DEBUG_OVERRIDE
    if !GlobalExperimentalSettings.isAppStoreBuild {
        entries.append(.oneFromManySelector(id: id.count, section: .base, settingName: .appUpdateOverride, text: "App update override", value: SGSimpleSettings.shared.appUpdateDebugOverride, enabled: true))
    }
    #endif
    
    entries.append(.action(id: id.count, section: .base, actionType: .restorePurchases, text: "PayWall.RestorePurchases".i18n(presentationData.strings.baseLanguageCode), kind: .generic))
    #if DEBUG
    entries.append(.action(id: id.count, section: .base, actionType: .setIAP, text: "Set Pro", kind: .generic))
    // MARK: Zenlygram — DEBUG only (design §8.3 item 16). It used to ship in RELEASE and to force
    // `status = SGStatus.default.status`, which is now a no-op: `SGStatus` is upstream Swiftgram's
    // own Pro flag and is permanently clamped to Pro here. Zenlygram Pro is `SGEntitlement`, and a
    // subscription cannot be reset from the device anyway — the App Store owns
    // `Transaction.currentEntitlements`. What this row does reset is the LOCAL purchase-flow state.
    entries.append(.action(id: id.count, section: .base, actionType: .resetIAP, text: "Reset purchase state", kind: .destructive))
    #endif

    entries.append(.toggle(id: id.count, section: .notifications, settingName: .legacyNotificationsFix, value: SGSimpleSettings.shared.legacyNotificationsFix, text: "[OLD] Fix empty notifications", enabled: true))
    return entries
}
private func okUndoController(_ text: String, _ presentationData: PresentationData) -> UndoOverlayController {
    return UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false })
}


public func sgDebugController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let simplePromise = ValuePromise(true, ignoreRepeated: false)
    
    let arguments = SGItemListArguments<SGDebugToggles, AnyHashable, SGDebugOneFromManySetting, SGDebugDisclosureLink, SGDebugActions>(context: context, setBoolValue: { toggleName, value in
        switch toggleName {
            case .forceImmediateShareSheet:
                SGSimpleSettings.shared.forceSystemSharing = value
            case .legacyNotificationsFix:
                SGSimpleSettings.shared.legacyNotificationsFix = value
                SGSimpleSettings.shared.synchronizeShared()
            case .inputToolbar:
                SGSimpleSettings.shared.inputToolbar = value
        }
    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []

        switch setting {
        case .appUpdateOverride:
            // Zenlygram — none: the signed policy decides; remind: one "Update available" alert per launch; block: the
            // full-screen "Update required" overlay (update_policy_spec §4h). The presenter re-decides at once — through
            // its own override hook, not `decisionDidChange`: an adopted signed policy never offers the reminder
            // mid-session, a QA override does. Non-store builds only (the row above is compiled out with it).
            #if SG_APP_UPDATE_DEBUG_OVERRIDE
            for value in SGAppUpdateDebugOverride.allCases {
                items.append(ActionSheetButtonItem(title: value.rawValue, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    SGSimpleSettings.shared.appUpdateDebugOverride = value.rawValue
                    SGAppUpdate.shared.debugOverrideDidChange()
                    simplePromise.set(true)
                }))
            }
            #else
            break
            #endif
        case .pinnedMessageNotifications, .mentionsAndRepliesNotifications:
            break
        }

        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }, openDisclosureLink: { _ in
    }, action: { actionType in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        switch actionType {
            case .clearRegDateCache:
                SGLogger.shared.log("SGDebug", "Regdate cache cleanup init")
                
                /*
                let spinner = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))

                presentControllerImpl?(spinner, nil)
                */
                SGSimpleSettings.shared.regDateCache.drop()
                SGLogger.shared.log("SGDebug", "Regdate cache cleanup succesfull")
                presentControllerImpl?(okUndoController("OK: Regdate cache cleaned", presentationData), nil)
                /*
                Queue.mainQueue().async() { [weak spinner] in
                    spinner?.dismiss()
                }
                */
            case .clearOutgoingTranslationLanguageCache:
                SGLogger.shared.log("SGDebug", "Outgoing translation language cache cleanup init")
                SGSimpleSettings.shared.outgoingLanguageTranslation.drop()
                SGLogger.shared.log("SGDebug", "Outgoing translation language cache cleanup succesfull")
                presentControllerImpl?(okUndoController("OK: Outgoing translation language cache cleaned", presentationData), nil)
        case .flexing:
            #if DEBUG
            FLEXManager.shared.toggleExplorer()
            #endif
        case .fileManager:
            #if DEBUG
            let baseAppBundleId = Bundle.main.bundleIdentifier!
            let appGroupName = "group.\(baseAppBundleId)"
            let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
            if let maybeAppGroupUrl = maybeAppGroupUrl {
                if let fileManager = FLEXFileBrowserController(path: maybeAppGroupUrl.path) {
                    FLEXManager.shared.showExplorer()
                    let flexNavigation = FLEXNavigationController(rootViewController: fileManager)
                    FLEXManager.shared.presentTool({ return flexNavigation })
                }
            } else {
                presentControllerImpl?(UndoOverlayController(
                    presentationData: presentationData,
                    content: .info(title: nil, text: "Empty path", timeout: nil, customUndoText: nil),
                    elevatedLayout: false,
                    action: { _ in return false }
                ),
                nil)
            }
            #endif
        case .restorePurchases:
            // The locale argument used to be passed as a FORMAT ARGUMENT (`i18n(args:)`), so this
            // toast always rendered in English. It is the locale.
            let lang = presentationData.strings.baseLanguageCode
            presentControllerImpl?(UndoOverlayController(
                presentationData: presentationData,
                content: .info(title: nil, text: "PayWall.Button.Restoring".i18n(lang), timeout: nil, customUndoText: nil),
                elevatedLayout: false,
                action: { _ in return false }
            ),
            nil)
            context.sharedContext.SGIAP?.restore(accountPeerId: context.account.peerId.toInt64(), completion: { result in
                switch result {
                case .cancelled:
                    // The user dismissed the App Store's password prompt. Say nothing.
                    break
                case .restored:
                    presentControllerImpl?(okUndoController(SGIAPMessage.restoreCompleted.localizationKey.i18n(lang), presentationData), nil)
                case .nothingToRestore:
                    presentControllerImpl?(okUndoController(SGIAPMessage.nothingToRestore.localizationKey.i18n(lang), presentationData), nil)
                case let .failed(message):
                    presentControllerImpl?(okUndoController(message.localizationKey.i18n(lang), presentationData), nil)
                }
            })
        case .setIAP:
            #if DEBUG
            #endif
        case .resetIAP:
            #if DEBUG
            // Clears the local purchase-flow caches — the product list, the trial-ledger memory and
            // the attach outbox — so the paywall and the attach path can be exercised again. It
            // cannot take a subscription away: the next snapshot refresh reads
            // `Transaction.currentEntitlements` straight back from the App Store.
            context.sharedContext.SGIAP?.resetLocalPurchaseStateForDebug()
            presentControllerImpl?(okUndoController("OK: local purchase state reset", presentationData), nil)
            #else
            break
            #endif
        }
    })
    
    let signal = combineLatest(context.sharedContext.presentationData, simplePromise.get())
    |> map { presentationData, _ ->  (ItemListControllerState, (ItemListNodeState, Any)) in
        
        let entries = SGDebugControllerEntries(presentationData: presentationData)
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Zenlygram Debug"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        
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


