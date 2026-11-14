// MARK: Swiftgram
import SGLogging
import SGSimpleSettings
import SGStrings
import SGAPIToken
import SGTasks
#if SG_LENTA
import SGFeedUI
import SGFeedStrings
#endif
import SGChatLock
import SGSecretVault
import SGAIAssistant
import SGCallRecording
import SGEntitlement
import SGEntitlementUI
import SGIAP
import SGPayWall
import SGBindAttest
import SGCustomerSync
import SGCustomerSyncCore
import SGAutoProxy
import SGAutoAccept

import SGItemListUI
import SGSettingsCatalog
import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import MtProtoKit
import MessageUI
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AlertComponent
import OverlayStatusController
import AccountContext
import AppBundle
import WebKit
import PeerNameColorScreen
import UndoUI


private enum SGControllerSection: Int32, SGItemListSection {
    case search
    case trending
    case content
    case tabs
    case folders
    case chatList
    case profiles
    case stories
    case translation
    case voiceMessages
    case calls
    case photo
    case stickers
    case videoNotes
    case aiAssistant
    case contextMenu
    case accountColors
    case other
    // MARK: Zenlygram — professional IA sections (order is irrelevant; display order == append order)
    case privacySecurity
    case messages
    case media
    case tools
    case advanced
    case privacyHiddenChats
    case privacyInvisible
    case composing
    case downloads
    case cameraPicker
    // Zenlygram — Edit History gets its own group so it no longer sits under the context-menu placement notice.
    case editHistory
    // Zenlygram — local call recording (behind `sgCallRecordingAvailable`).
    case callRecording
    // Zenlygram — the subscription: status, restore and the sales blurb; shown only while a Pro surface
    // may be (`showsProSurfaces`, D1 2026-11-11).
    case zenlygramPro
    // Zenlygram — the Telegram account the entitlement belongs to, under a neutral header: an identity
    // step for Cloud Tasks and the customer-data consent, needed whether or not Pro is shown.
    case zenlygramAccount
    // Zenlygram — Data & privacy (design 40 §11.1). No screen renders this section today: the consent and
    // privacy-policy rows sit in `.zenlygramAccount` on the hub. Kept for the settings IA spec's fallback F2
    // (a lower block headed `Settings.Data.Header`, should a required hub row ever be clipped on a small
    // phone).
    case zenlygramData
    // Zenlygram — the hub's own blocks (settings IA, 2026-11): MAIN FEATURES and MORE SETTINGS.
    case hubFeatures
    case hubGroups
    // Zenlygram — the Deleted & Edited Messages page: Show Deleted Messages gets a group of its own above
    // the Edit History one (it used to open the Profiles section).
    case deletedMessages
}

private enum SGBoolSetting: String {
    case hidePhoneInSettings
    case showTabNames
    case showContactsTab
    case showCallsTab
    case showTasksTab
    #if SG_LENTA
    case showLentaTab
    #endif
    case wideTabBar
    case foldersAtBottom
    case startTelescopeWithRearCam
    case hideStories
    case uploadSpeedBoost
    case showProfileId
    case warnOnStoriesOpen
    case sendWithReturnKey
    case rememberLastFolder
    case sendLargePhotos
    case disableSwipeToRecordStory
    case disableDeleteChatSwipeOption
    case quickTranslateButton
    case hideReactions
    case showRepostToStory
    case contextShowSelectFromUser
    case contextShowSaveToCloud
    case contextShowHideForwardName
    case contextShowRestrict
    case contextShowReport
    case contextShowReply
    case contextShowPin
    case contextShowSaveMedia
    case contextShowMessageReplies
    case contextShowJson
    case editHistoryEnabled
    case disableScrollToNextChannel
    case disableScrollToNextTopic
    case disableChatSwipeOptions
    case disableGalleryCamera
    case disableGalleryCameraPreview
    case disableSendAsButton
    case disableSnapDeletionEffect
    case stickerTimestamp
    case hideRecordingButton
    case hideTabBar
    case showDC
    case showCreationDate
    case showRegDate
    case compactChatList
    case unlimitedPinnedChats
    case unreadReminderEnabled
    case blockForeignUsers
    case sendRoundVideoFromGallery
    case aiAssistantEnabled
    case compactMessagePreview
    case compactFolderNames
    case allChatsHidden
    case defaultEmojisFirst
    case messageDoubleTapActionOutgoingEdit
    case wideChannelPosts
    case forceEmojiTab
    case forceBuiltInMic
    case secondsInMessages
    case hideChannelBottomButton
    case confirmCalls
    case swipeForVideoPIP
    case enableVoipTcp
    case autoProxyEnabled
    case autoDownloadDisabled
    case autoAcceptRequests
    case showViewFirstMessage
    case showDeletedMessages
    case nyStyleSnow
    case nyStyleLightning
    case tabBarSearchEnabled
    case secretVaultEnabled
    case secretVaultUseSecretCode
    // Zenlygram — local call recording: the optional notice to the other party (default OFF).
    case callRecordingNotifyOtherParty
    // Zenlygram — local call recording: send finished recordings to Saved Messages (default OFF).
    case callRecordingSendToSavedMessages
}

private enum SGOneFromManySetting: String {
    case nyStyle
    case bottomTabStyle
    case downloadSpeedBoost
    case allChatsTitleLengthOverride
//    case allChatsFolderPositionOverride
    case translationBackend
    case transcriptionBackend
}

private enum SGSliderSetting: String {
    case accountColorsSaturation
    case outgoingPhotoQuality
    case stickerSize
}

private enum SGDisclosureLink: String {
    case contentSettings
    case languageSettings
    case helperBots
    case tasks
    #if SG_LENTA
    case lenta
    #endif
    case chatLock
    case secretVaultChangePin
    // Zenlygram — audit #70/#71: only shown while a protection must be set up again on THIS iPhone.
    case protectionRecovery
    case aiAssistantApiKey
    // Zenlygram — the recordings list.
    case callRecordings
    // MARK: Zenlygram — the subscription rows (design §8.3 item 20).
    case proSubscription
    case proRestorePurchases
    case proLinkAccount
    // MARK: Zenlygram — Data & privacy (design 40 §11.1).
    case dataConsent
    case privacyPolicy
    // MARK: Zenlygram — the hub rows that open a page (settings IA, 2026-11). Plain cases on purpose:
    // `String(describing:)` keeps printing the case name for every link, so the NEW-badge keys and the
    // focus keys stay the case names with no custom description to drift; the DEBUG guard checks that each
    // one prints as the catalog's `hubRowKey`.
    case pageSecretVault
    case pageHistory
    case pageCallRecording
    case pageChats
    case pageMessages
    case pageMessageMenu
    case pageTabBar
    case pagePrivacy
    case pageTranslation
    case pageMedia
    case pageColors
    case pageCallsAdvanced

    /// The hub row of a page.
    init(page: SGSettingsPage) {
        switch page {
        case .secretVault:
            self = .pageSecretVault
        case .history:
            self = .pageHistory
        case .callRecording:
            self = .pageCallRecording
        case .chats:
            self = .pageChats
        case .messages:
            self = .pageMessages
        case .messageMenu:
            self = .pageMessageMenu
        case .tabBar:
            self = .pageTabBar
        case .privacy:
            self = .pagePrivacy
        case .translation:
            self = .pageTranslation
        case .media:
            self = .pageMedia
        case .colors:
            self = .pageColors
        case .callsAdvanced:
            self = .pageCallsAdvanced
        }
    }

    /// The page a hub row opens; nil for every other link.
    var page: SGSettingsPage? {
        switch self {
        case .pageSecretVault:
            return .secretVault
        case .pageHistory:
            return .history
        case .pageCallRecording:
            return .callRecording
        case .pageChats:
            return .chats
        case .pageMessages:
            return .messages
        case .pageMessageMenu:
            return .messageMenu
        case .pageTabBar:
            return .tabBar
        case .pagePrivacy:
            return .privacy
        case .pageTranslation:
            return .translation
        case .pageMedia:
            return .media
        case .pageColors:
            return .colors
        case .pageCallsAdvanced:
            return .callsAdvanced
        case .contentSettings, .languageSettings, .helperBots, .tasks, .chatLock, .secretVaultChangePin, .protectionRecovery, .aiAssistantApiKey, .callRecordings, .proSubscription, .proRestorePurchases, .proLinkAccount, .dataConsent, .privacyPolicy:
            return nil
        #if SG_LENTA
        case .lenta:
            return nil
        #endif
        }
    }
}

private struct PeerNameColorScreenState: Equatable {
    var updatedNameColor: PeerNameColor?
    var updatedBackgroundEmojiId: Int64?
}

private struct SGSettingsControllerState: Equatable {
    var searchQuery: String?
    // Zenlygram — retention features whose turn-off confirmation is still open (#50/#68). While pending,
    // the row renders as off (matching the flipped UISwitch); clearing it makes the entry value really
    // change, so the list re-syncs the switch on every exit path (e.g. Cancel snaps it back on).
    var pendingRetentionDisable: Set<SGRetentionFeature> = []
    #if SG_LENTA
    // Zenlygram — what the Lenta tab does while the user never touched its switch (the availability
    // rule for the current account), so the switch shows the tab's real state.
    var lentaTabAutomaticallyVisible = false
    #endif
}

private typealias SGControllerEntry = SGItemListUIEntry<SGControllerSection, SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>

/// Which screen of Settings → Zenlygram a controller is: the hub (the first screen) or one of its pages.
private enum SGSettingsScreen: Equatable {
    case hub
    case page(SGSettingsPage)

    var page: SGSettingsPage? {
        switch self {
        case .hub:
            return nil
        case let .page(page):
            return page
        }
    }

    /// `screen.view` (design 40 §10.2, closed taxonomy — no registry change): the hub; the Deleted & Edited
    /// Messages page under its reserved name; every other page as `zg.preferences`.
    var analyticsScreen: SGAnalyticsScreen {
        switch self {
        case .hub:
            return .zgHub
        case .page(.history):
            return .editHistorySettings
        case .page:
            return .zgPreferences
        }
    }
}

/// Everything one build of a screen's entries reads besides the stores. Computed once per rebuild in the
/// screen's signal and shared by the hub and the twelve page arrays it builds for the NEW roll-ups, so
/// those add no extra keychain or disk reads (invariant I1: the builder is synchronous and never waits).
private struct SGEntryInputs {
    let presentationData: PresentationData
    let callListSettings: CallListSettings
    let experimentalUISettings: ExperimentalUISettings
    let appConfiguration: AppConfiguration
    let nameColors: PeerNameColors
    let state: SGSettingsControllerState
    let accountPeerId: Int64
    let showsProSurfaces: Bool
    /// `ChatPincodeManager.shared.protectionRecoveryStatus()` — a keychain read.
    let protectionStatus: SGProtectionRecoveryStatus
    /// `ChatPincodeManager.shared.isMasterEnabled()`.
    let chatLockArmed: Bool
    /// `!ChatPincodeManager.shared.lockedPeerIds().isEmpty` — the manager's in-memory locked-id cache. With
    /// `chatLockArmed` false this is the Chat Lock screen's LEGACY state: chats locked without a master.
    let chatLockLegacy: Bool
    /// `sgCallRecordingAvailable || SGCallRecordingStore.shared.hasAnyFiles()` — a directory listing.
    let callRecordingVisible: Bool
}

// MARK: - Zenlygram — Settings → Zenlygram is a hub and twelve pages (settings IA, 2026-11).
//
// The hub (`sgHubEntries`) is the first screen: the search field, MAIN FEATURES, ACCOUNT & DATA, the
// ZENLYGRAM PRO block while a Pro surface may be shown, and the MORE SETTINGS rows that open the nine group
// pages. Every other row lives on exactly one page (`sgPageEntries`); the rows moved there unchanged — same
// cases (= SGSimpleSettings keys = NEW-badge keys = focus keys), same titles, same gates, same
// `id.increment` reservations, same controlled switches, same handlers in `makeSGSettingsScreen`.
// `SGSettingsCatalog` holds the same tree as data; the DEBUG guard at the end of this file ties the two.

/// The hub's rows. `searchMode` (a non-empty query) drops the MORE SETTINGS block — the hub's search lists
/// every page's rows behind the hub's instead (`SGControllerEntries`) — and reserves its ids. `pageHasNew`
/// is the NEW-badge roll-up of a page row, computed from the page's built entries (§2.4): a gated row that
/// is hidden cannot raise a pill, and the pill goes when every child was used or its 30 days passed.
private func sgHubEntries(_ inputs: SGEntryInputs, id: SGItemListCounter, searchMode: Bool, pageHasNew: (SGSettingsPage) -> Bool) -> [SGControllerEntry] {
    let presentationData = inputs.presentationData
    let lang = presentationData.strings.baseLanguageCode
    let strings = presentationData.strings
    let state = inputs.state
    let showsProSurfaces = inputs.showsProSurfaces
    let protectionStatus = inputs.protectionStatus
    let accountPeerId = inputs.accountPeerId
    var entries: [SGControllerEntry] = []

    // MARK: Search (pinned anchor)
    entries.append(.searchInput(id: id.count, section: .search, title: NSAttributedString(string: "🔍"), text: state.searchQuery ?? "", placeholder: strings.Common_Search))

    // MARK: Zenlygram — MAIN FEATURES: the flagship features, each one tap from the first screen.
    entries.append(.header(id: id.count, section: .hubFeatures, text: i18n("Settings.Hub.Features.Header", lang), badge: nil))
    // The Secret Vault row reads the state the page's switch reads: On while the vault is usable, "Needs
    // setup" while it waits for recovery (audit #70/#71), else Off. Its NEW pill rolls up from the page.
    // While the pill is up the On/Off value is left out — the history row's rule (spec §2.1): the pill's
    // 62 pt reserve leaves the 19-character ru title ≈34 pt for the value, so "Выкл" drew as "…"; the
    // page's switch shows the state. "Needs setup" stays in every state: it is an alert, not a status.
    let vaultIsUsable = SGSimpleSettings.shared.secretVaultEnabled && !protectionStatus.vaultNeedsRecovery
    let vaultIsNew = pageHasNew(.secretVault)
    let secretVaultValue: String
    if vaultIsUsable {
        secretVaultValue = vaultIsNew ? "" : i18n("Settings.ChatLock.On", lang)
    } else if protectionStatus.vaultNeedsRecovery && SGSimpleSettings.shared.secretVaultEnabled {
        secretVaultValue = SGProtectionStrings.needsSetup
    } else {
        secretVaultValue = vaultIsNew ? "" : i18n("Settings.ChatLock.Off", lang)
    }
    entries.append(.iconDisclosure(id: id.count, section: .hubFeatures, link: .pageSecretVault, title: i18n("Settings.SecretVault.Title", lang), value: secretVaultValue, iconName: "eye.slash.fill", iconColor: .purple, isNew: vaultIsNew))
    // Chat Lock cannot report "On" while its credentials are gone (isMasterEnabled() is already false then),
    // so say what the user has to do instead of the plain "Off" that hides the problem. LEGACY (locked chats,
    // no master) reads "On" like the Chat Lock screen it opens, which lists those chats and offers "Turn off
    // Chat Lock"; "Needs setup" still wins while recovery is pending.
    let chatLockValue: String
    if inputs.chatLockArmed {
        chatLockValue = i18n("Settings.ChatLock.On", lang)
    } else if protectionStatus.chatLockNeedsRecovery {
        chatLockValue = SGProtectionStrings.needsSetup
    } else if inputs.chatLockLegacy {
        chatLockValue = i18n("Settings.ChatLock.On", lang)
    } else {
        chatLockValue = i18n("Settings.ChatLock.Off", lang)
    }
    entries.append(.iconDisclosure(id: id.count, section: .hubFeatures, link: .chatLock, title: i18n("Settings.ChatLock", lang), value: chatLockValue, iconName: "lock.shield.fill", iconColor: .blue, isNew: SGNewBadgeTracker.shouldShow("chatLock")))
    // Only the Chat Lock half of the recovery block lives here: the vault's half is on the Secret Vault page
    // (both rows open the same sheet).
    if protectionStatus.chatLockNeedsRecovery {
        entries.append(.notice(id: id.count, section: .hubFeatures, text: SGProtectionStrings.recoveryNotice))
        entries.append(.iconDisclosure(id: id.count, section: .hubFeatures, link: .protectionRecovery, title: SGProtectionStrings.restoreProtectionRow, value: SGProtectionStrings.needsSetup, iconName: "exclamationmark.shield.fill", iconColor: .orange, isNew: false))
    } else {
        // Same stableId balancing as the vault branches on the Secret Vault page: the two recovery rows must
        // not shift the list below when they appear or disappear.
        id.increment(2)
    }
    entries.append(.iconDisclosure(id: id.count, section: .hubFeatures, link: .tasks, title: i18n("Settings.Tasks", lang), value: "", iconName: "checklist", iconColor: .blue, isNew: SGNewBadgeTracker.shouldShow("tasks")))
    entries.append(.iconDisclosure(id: id.count, section: .hubFeatures, link: .pageHistory, title: i18n("Settings.Hub.History", lang), value: "", iconName: "clock.arrow.circlepath", iconColor: .teal, isNew: pageHasNew(.history)))
    // Reachable only while recordings can be made or old ones exist (the gate the call-recording block had),
    // so the page itself needs no gate.
    if inputs.callRecordingVisible {
        entries.append(.iconDisclosure(id: id.count, section: .hubFeatures, link: .pageCallRecording, title: i18n("Settings.Hub.CallRecording", lang), value: "", iconName: "waveform", iconColor: .red, isNew: false))
    } else {
        id.increment(1)
    }
    #if SG_LENTA
    entries.append(.iconDisclosure(id: id.count, section: .hubFeatures, link: .lenta, title: SGFeedStrings.SGFeedL10n.string("SGFeedUI.Tools.Lenta", lang), value: "", iconName: "rectangle.stack", iconColor: .violet, isNew: false))
    #endif

    // MARK: Zenlygram — ACCOUNT & DATA: the Telegram account the entitlement belongs to (an identity step for
    // Cloud Tasks and the customer-data consent, needed whether or not Pro is shown — it is never a purchase
    // path), this account's consent and the privacy policy (design 40 §11.1). The link state is the cached
    // `SGEntitlement` decision — synchronous, no network (invariant I1, see the Pro block below).
    let entitlementState = SGEntitlement.shared.state
    let isEntitlementLinked = SGEntitlement.shared.activeAccountPeerId.map { SGEntitlement.shared.isLinked(accountPeerId: $0) } ?? false
    entries.append(.header(id: id.count, section: .zenlygramAccount, text: i18n("Settings.AccountData.Header", lang), badge: nil))
    entries.append(.iconDisclosure(id: id.count, section: .zenlygramAccount, link: .proLinkAccount, title: i18n("Settings.Pro.LinkAccount", lang), value: isEntitlementLinked ? i18n("Settings.Pro.LinkAccount.Linked", lang) : i18n("Settings.Pro.LinkAccount.NotLinked", lang), iconName: "person.badge.key.fill", iconColor: .blue, isNew: false))
    // The consent row exists only while the customer-data pipeline runs; its value is read locally
    // (the consent store, no network) and the list is rebuilt whenever a consent summary or the
    // entitlement changes (see `customerDataChanges` below). The privacy policy stays reachable
    // whenever the build carries a valid https URL (Apple 5.1.1(i)), with or without the pipeline.
    let customerSync = SGCustomerSync.shared
    let consentRowValue: String?
    if customerSync.isActive {
        if let consentSummary = customerSync.consentSummary(accountPeerId: accountPeerId) {
            let stateKey: String
            switch consentSummary {
            case .granted:
                stateKey = "Settings.Data.State.Granted"
            case .none:
                stateKey = "Settings.Data.State.None"
            case .declined:
                stateKey = "Settings.Data.State.Declined"
            case .withdrawn:
                stateKey = "Settings.Data.State.Withdrawn"
            case .review:
                stateKey = "Settings.Data.State.Review"
            }
            consentRowValue = i18n(stateKey, lang)
        } else {
            // The store cannot be read yet (a launch before the first unlock): the row stays, blank.
            consentRowValue = ""
        }
    } else {
        consentRowValue = nil
    }
    let hasPrivacyPolicy = customerSync.privacyPolicyURL != nil
    if let consentRowValue = consentRowValue {
        entries.append(.iconDisclosure(id: id.count, section: .zenlygramAccount, link: .dataConsent, title: i18n("Settings.Data.Consent", lang), value: consentRowValue, iconName: "hand.raised.fill", iconColor: .blue, isNew: false))
    } else {
        id.increment(1)
    }
    if hasPrivacyPolicy {
        entries.append(.iconDisclosure(id: id.count, section: .zenlygramAccount, link: .privacyPolicy, title: i18n("Settings.Data.PrivacyPolicy", lang), value: "", iconName: "doc.text.fill", iconColor: .gray, isNew: false))
    } else {
        id.increment(1)
    }

    // MARK: Zenlygram Pro — the subscription, the restore and the sales blurb (the Telegram account the
    // entitlement belongs to is in ACCOUNT & DATA above, so hiding this block never takes it along).
    //
    // Every value here comes from the already-cached decision: `SGEntitlement.shared.state` and
    // `isLinked` are synchronous, never touch the network, and never block. Building this list must
    // not become the one place in the app that waits on a server (invariant I1).
    //
    // Nothing in this section may carry a link or a call to action to a purchase outside the App
    // Store (guideline 3.1.3(b)): no "cheaper on Telegram", no Mini App button, no support link that
    // leads to one. Linking a Telegram account is an IDENTITY step, not a purchase path.
    //
    // The ZENLYGRAM PRO section exists only while a Pro surface may be shown (`showsProSurfaces` =
    // `sharedContext.sgProEntryIsVisible`, the same predicate as the main Settings row; D1,
    // 2026-11-11): with the Apple backend on, while the signed policy is PAID or this account holds
    // Pro. In free mode a non-holder sees neither the header, the Subscription row, Restore nor the
    // sales blurb — nothing is sold, so there is nothing to brand — and the list is rebuilt when
    // the policy flips (`customerDataChanges` below). A build whose Apple backend is held keeps it.
    if showsProSurfaces {
        entries.append(.header(id: id.count, section: .zenlygramPro, text: i18n("Settings.Pro.Header", lang), badge: nil))
        // While the signed monetization policy is free the row says "Free" — no countdown and no
        // subscription claim. Inside the paid-mode local grace it says "Free until <date>" rather than
        // "Active": the user did nothing to get Pro and should know when it ends. Same cached decision,
        // no network, no waiting.
        let proStatusValue: String
        if sgPayWallIsFreeAccess {
            proStatusValue = i18n("Settings.Pro.Status.Free", lang)
        } else if entitlementState.isUnlocked, let graceUntilText = sgPayWallGraceUntilText(lang: lang) {
            proStatusValue = "Settings.Pro.Status.FreeUntil".i18n(lang, args: graceUntilText)
        } else {
            proStatusValue = entitlementState.isUnlocked ? i18n("Entitlement.Status.Available", lang) : i18n("Settings.Pro.Status.Inactive", lang)
        }
        entries.append(.iconDisclosure(id: id.count, section: .zenlygramPro, link: .proSubscription, title: i18n("Settings.Pro.Subscription", lang), value: proStatusValue, iconName: "star.circle.fill", iconColor: .gold, isNew: SGNewBadgeTracker.shouldShow("proSubscription")))
        // A held Apple backend refuses Restore (no StoreKit work at all): no dead row.
        if SGEntitlement.shared.isAppleBackendEnabled {
            entries.append(.iconDisclosure(id: id.count, section: .zenlygramPro, link: .proRestorePurchases, title: i18n("Settings.Pro.Restore", lang), value: "", iconName: "arrow.clockwise", iconColor: .teal, isNew: false))
        } else {
            // Reserved so the notice below keeps its id whether or not Restore is shown.
            id.increment(1)
        }
        // The degraded reason, when there is one, replaces the generic blurb: "your subscription ended"
        // and "reconnect to restore Pro" are different problems and must not be flattened into one line.
        // Nothing here is ever an error or a retry loop — the row above is always the way forward.
        // `.noToken` falls through to the blurb on purpose. It is the state of every fresh install, and
        // "link your Telegram account to use Zenlygram Pro" is the wrong answer there twice over: linking
        // is optional (buying works without it), and what a non-subscriber needs is what Pro IS. Without
        // this the sales blurb was structurally unreachable — `degradedMessage` is nil only while
        // unlocked, so the only readers of `Settings.Pro.Notice` were people who already had Pro.
        let entitlementDegradedReason = entitlementState.degradedReason
        if entitlementDegradedReason != nil, entitlementDegradedReason != SGEntitlementDegradedReason.noToken, let degradedMessage = SGEntitlement.shared.degradedMessage {
            entries.append(.notice(id: id.count, section: .zenlygramPro, text: degradedMessage.localizationKey.i18n(lang)))
        } else {
            entries.append(.notice(id: id.count, section: .zenlygramPro, text: i18n("Settings.Pro.Notice", lang)))
        }
    } else {
        // The block's four slots stay reserved, so the MORE SETTINGS rows keep their ids in every state.
        id.increment(4)
    }

    // MARK: Zenlygram — MORE SETTINGS: the nine group pages. Omitted while the search field holds a query —
    // the hub's search lists every page's rows instead (`SGControllerEntries`) — with its ten slots reserved.
    if searchMode {
        id.increment(10)
    } else {
        entries.append(.header(id: id.count, section: .hubGroups, text: i18n("Settings.Hub.Groups.Header", lang), badge: nil))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageChats, title: i18n("Settings.Hub.Chats", lang), value: "", iconName: "list.bullet.rectangle.fill", iconColor: .lightBlue, isNew: pageHasNew(.chats)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageMessages, title: i18n("Settings.Hub.Messages", lang), value: "", iconName: "text.bubble.fill", iconColor: .blue, isNew: pageHasNew(.messages)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageMessageMenu, title: i18n("Settings.Hub.MessageMenu", lang), value: "", iconName: "ellipsis.circle.fill", iconColor: .orange, isNew: pageHasNew(.messageMenu)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageTabBar, title: i18n("Settings.Hub.TabBar", lang), value: "", iconName: "rectangle.bottomthird.inset.filled", iconColor: .teal, isNew: pageHasNew(.tabBar)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pagePrivacy, title: i18n("Settings.Hub.Privacy", lang), value: "", iconName: "person.text.rectangle.fill", iconColor: .green, isNew: pageHasNew(.privacy)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageTranslation, title: i18n("Settings.Hub.Translation", lang), value: "", iconName: "character.book.closed.fill", iconColor: .pink, isNew: pageHasNew(.translation)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageMedia, title: i18n("Settings.Hub.Media", lang), value: "", iconName: "photo.on.rectangle.angled", iconColor: .orange, isNew: pageHasNew(.media)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageColors, title: i18n("Settings.Hub.Colors", lang), value: "", iconName: "paintpalette.fill", iconColor: .violet, isNew: pageHasNew(.colors)))
        entries.append(.iconDisclosure(id: id.count, section: .hubGroups, link: .pageCallsAdvanced, title: i18n("Settings.Hub.CallsAdvanced", lang), value: "", iconName: "gearshape.2.fill", iconColor: .gray, isNew: pageHasNew(.callsAdvanced)))
    }

    return entries
}

/// One page's rows, built on `id`: a fresh counter for the page's own screen, one on the page's
/// `searchIdBase` when the hub's search appends it. The bodies are the blocks of the former flat list, moved
/// as they were (sections included), so every stable id, reservation and handler is the one it was.
private func sgPageEntries(_ page: SGSettingsPage, _ inputs: SGEntryInputs, id: SGItemListCounter) -> [SGControllerEntry] {
    let presentationData = inputs.presentationData
    let lang = presentationData.strings.baseLanguageCode
    let strings = presentationData.strings
    let callListSettings = inputs.callListSettings
    let experimentalUISettings = inputs.experimentalUISettings
    let appConfiguration = inputs.appConfiguration
    let nameColors = inputs.nameColors
    let state = inputs.state
    let showsProSurfaces = inputs.showsProSurfaces
    let protectionStatus = inputs.protectionStatus
    var entries: [SGControllerEntry] = []

    switch page {
    case .secretVault:
        // MARK: Zenlygram — Privacy: Hidden & Locked Chats (flagship)
        // Zenlygram — audit #70/#71: a protection whose credential did not come along with a device migration is
        // never silently downgraded. The toggle then reads OFF (there is no usable vault behind it), a notice and
        // a "Restore protection" row appear, and turning the feature off lives in that row's action sheet.
        let vaultIsUsable = SGSimpleSettings.shared.secretVaultEnabled && !protectionStatus.vaultNeedsRecovery
        entries.append(.header(id: id.count, section: .privacyHiddenChats, text: i18n("Settings.SecretVault.Title", lang).uppercased(), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .privacyHiddenChats, settingName: .secretVaultEnabled, value: vaultIsUsable, title: i18n("Settings.SecretVault.Title", lang), description: i18n("Settings.SecretVault.Desc", lang), iconName: "eye.slash.fill", iconColor: .purple, isNew: SGNewBadgeTracker.shouldShow("secretVaultEnabled"), enabled: true, enableInteractiveChanges: false))
        if vaultIsUsable {
            // Keep the retired Open entry's position so the remaining rows retain their stable ids.
            id.increment(1)
            entries.append(.iconToggle(id: id.count, section: .privacyHiddenChats, settingName: .secretVaultUseSecretCode, value: SGSimpleSettings.shared.secretVaultUseSecretCode, title: i18n("Settings.SecretVault.UseSecretCode", lang), description: i18n("Settings.SecretVault.UseSecretCode.Desc", lang), iconName: "character.cursor.ibeam", iconColor: .teal, isNew: SGNewBadgeTracker.shouldShow("secretVaultUseSecretCode"), enabled: true, enableInteractiveChanges: false))
            entries.append(.iconDisclosure(id: id.count, section: .privacyHiddenChats, link: .secretVaultChangePin, title: i18n("Settings.SecretVault.ChangePin", lang), value: "", iconName: "key.fill", iconColor: .gray, isNew: SGNewBadgeTracker.shouldShow("secretVaultChangePin")))
            entries.append(.notice(id: id.count, section: .privacyHiddenChats, text: i18n("Settings.SecretVault.UseSecretCode.Notice", lang)))
        } else if protectionStatus.vaultNeedsRecovery && SGSimpleSettings.shared.secretVaultEnabled {
            // Zenlygram — audit batch 4 (the post-migration dead search, Settings half): while the vault waits
            // for recovery this row used to DISAPPEAR, so nothing on screen connected a chat search that no
            // longer searches to the vault, and a user who dismissed the launch notice with "Later" had no
            // discoverable explanation. The row stays — not as a switch that cannot be armed, but as a disclosure
            // that says why it is paused and opens the recovery sheet. (The toast on a refused Search tap is the
            // chat-list side of this report and lives in the search gate, not here.)
            entries.append(.iconDisclosure(id: id.count, section: .privacyHiddenChats, link: .protectionRecovery, title: i18n("Settings.SecretVault.UseSecretCode", lang), value: SGProtectionStrings.secretCodePausedValue, iconName: "character.cursor.ibeam", iconColor: .gray, isNew: false))
            entries.append(.notice(id: id.count, section: .privacyHiddenChats, text: SGProtectionStrings.secretCodePausedNotice(searchPaused: SGSimpleSettings.shared.secretVaultUseSecretCode)))
            // Keep the same four-position span, including the retired Open slot.
            id.increment(2)
        } else {
            entries.append(.notice(id: id.count, section: .privacyHiddenChats, text: i18n("Settings.SecretVault.Notice", lang)))
            // Reserve the retired Open slot, secret-code toggle, Change PIN and notice in every state.
            // Stable ids include the entry kind, so a notice and a disclosure at the same
            // position cannot reuse incompatible list nodes.
            id.increment(3)
        }
        // Only the vault's half of the recovery block lives here: the Chat Lock row and its recovery row are
        // on the hub (both rows open the same sheet).
        if protectionStatus.vaultNeedsRecovery {
            entries.append(.notice(id: id.count, section: .privacyHiddenChats, text: SGProtectionStrings.recoveryNotice))
            entries.append(.iconDisclosure(id: id.count, section: .privacyHiddenChats, link: .protectionRecovery, title: SGProtectionStrings.restoreProtectionRow, value: SGProtectionStrings.needsSetup, iconName: "exclamationmark.shield.fill", iconColor: .orange, isNew: false))
        } else {
            // Same stableId balancing as the vault branches above: the two recovery rows must not shift the
            // list below when they appear or disappear.
            id.increment(2)
        }
    case .history:
        // MARK: Zenlygram — Deleted & Edited Messages: the local retention features (#50/#68), each a
        // user's consent to keep data on this device, never a billing gate.
        entries.append(.header(id: id.count, section: .deletedMessages, text: i18n("Settings.DeletedMessages.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .deletedMessages, settingName: .showDeletedMessages, value: SGSimpleSettings.shared.showDeletedMessages && !state.pendingRetentionDisable.contains(.keptDeleted), title: i18n("Settings.ShowDeletedMessages", lang), description: i18n(showsProSurfaces ? "Settings.ShowDeletedMessages.Desc" : "Settings.ShowDeletedMessages.Desc.Free", lang), iconName: "trash.slash.fill", iconColor: .orange, isNew: SGNewBadgeTracker.shouldShow("showDeletedMessages"), enabled: true))
        entries.append(.notice(id: id.count, section: .deletedMessages, text: i18n("Settings.ShowDeletedMessages.Notice", lang)))
        // MARK: Edit History
        // Zenlygram — opt-in local edit history (#50); a new key, off by default (the old contextShowEditedHistory defaulted to true).
        // A feature switch, not a menu-placement toggle, so it has its own group right above the Message Menu
        // instead of sitting under the "Disabled entries … sub-menu" notice.
        entries.append(.header(id: id.count, section: .editHistory, text: i18n("ContextMenu.EditedHistory", lang).uppercased(), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .editHistory, settingName: .editHistoryEnabled, value: SGSimpleSettings.shared.editHistoryEnabled && !state.pendingRetentionDisable.contains(.editHistory), title: i18n("Settings.EditHistory", lang), description: i18n(showsProSurfaces ? "Settings.EditHistory.Desc" : "Settings.EditHistory.Desc.Free", lang), iconName: "clock.arrow.circlepath", iconColor: .teal, isNew: SGNewBadgeTracker.shouldShow("editHistoryEnabled"), enabled: true))
    case .callRecording:
        // MARK: Zenlygram — local call recording.
        //
        // Keep old recordings manageable even in a build that cannot create new ones. The optional
        // notification and upload settings belong only to builds with recording enabled. The page is
        // reached only through the hub's Call Recording row, which carries the "recordings possible or
        // present" gate the block used to have.
        entries.append(.header(id: id.count, section: .callRecording, text: i18n("Settings.Hub.CallRecording", lang).uppercased(), badge: nil))
        entries.append(.iconDisclosure(id: id.count, section: .callRecording, link: .callRecordings, title: i18n("CallRecording.List.Title", lang), value: "", iconName: "waveform", iconColor: .red, isNew: false))
        if sgCallRecordingAvailable {
            entries.append(.iconToggle(id: id.count, section: .callRecording, settingName: .callRecordingNotifyOtherParty, value: SGSimpleSettings.shared.callRecordingNotifyOtherParty, title: i18n("Settings.CallRecording.Notify", lang), description: i18n("Settings.CallRecording.Notify.Desc", lang), iconName: "bell.badge", iconColor: .orange, isNew: false, enabled: true))
            // This opt-in uploads to a Telegram cloud chat, not an end-to-end encrypted backup.
            entries.append(.iconToggle(id: id.count, section: .callRecording, settingName: .callRecordingSendToSavedMessages, value: SGSimpleSettings.shared.callRecordingSendToSavedMessages, title: i18n("Settings.CallRecording.SendToSaved", lang), description: i18n("Settings.CallRecording.SendToSaved.Desc", lang), iconName: "bookmark", iconColor: .blue, isNew: false, enabled: true))
        } else {
            // The same slot reservation as every other gated block (spec §1.2), so the notice keeps its
            // stable id. The gate is a compile-time constant today, so this branch never runs; it is here
            // for the day it becomes a runtime value.
            id.increment(2)
        }
        entries.append(.notice(id: id.count, section: .callRecording, text: i18n(sgCallRecordingAvailable ? "Settings.CallRecording.Notice" : "CallRecording.Unavailable.Text", lang)))
    case .chats:
        // MARK: Chat List
        entries.append(.header(id: id.count, section: .chatList, text: i18n("Settings.ChatList.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .chatList, settingName: .compactChatList, value: SGSimpleSettings.shared.compactChatList, title: i18n("Settings.CompactChatList", lang), description: i18n("Settings.CompactChatList.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "rectangle.compress.vertical", iconColor: .lightBlue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .chatList, settingName: .compactMessagePreview, value: SGSimpleSettings.shared.chatListLines != SGSimpleSettings.ChatListLines.three.rawValue, title: i18n("Settings.CompactMessagePreview", lang), description: i18n("Settings.CompactMessagePreview.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "text.alignleft", iconColor: .teal, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .chatList, settingName: .unlimitedPinnedChats, value: SGSimpleSettings.shared.unlimitedPinnedChats, title: i18n("Settings.UnlimitedPinnedChats", lang), description: i18n("Settings.UnlimitedPinnedChats.Notice", lang), iconName: "pin.circle.fill", iconColor: .orange, isNew: SGNewBadgeTracker.shouldShow("unlimitedPinnedChats"), enabled: true))
        entries.append(.iconToggle(id: id.count, section: .chatList, settingName: .disableChatSwipeOptions, value: !SGSimpleSettings.shared.disableChatSwipeOptions, title: i18n("Settings.ChatSwipeOptions", lang), description: i18n("Settings.ChatSwipeOptions.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "hand.draw.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .chatList, settingName: .disableDeleteChatSwipeOption, value: !SGSimpleSettings.shared.disableDeleteChatSwipeOption, title: i18n("Settings.DeleteChatSwipeOption", lang), description: i18n("Settings.DeleteChatSwipeOption.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "trash.fill", iconColor: .red, isNew: false, enabled: !SGSimpleSettings.shared.disableChatSwipeOptions))

        // MARK: Chat Folders
        entries.append(.header(id: id.count, section: .folders, text: strings.Settings_ChatFolders.uppercased(), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .folders, settingName: .foldersAtBottom, value: experimentalUISettings.foldersTabAtBottom, title: i18n("Settings.Folders.BottomTab", lang), description: i18n("Settings.Folders.BottomTab.Desc", lang), iconName: "dock.rectangle", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .folders, settingName: .rememberLastFolder, value: SGSimpleSettings.shared.rememberLastFolder, title: i18n("Settings.Folders.RememberLast", lang), description: i18n("Settings.Folders.RememberLast.Desc", lang), iconName: "bookmark.fill", iconColor: .orange, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .folders, text: i18n("Settings.Folders.RememberLast.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .folders, settingName: .allChatsHidden, value: SGSimpleSettings.shared.allChatsHidden, title: i18n("Settings.Folders.AllChatsHidden", lang, strings.ChatList_Tabs_AllChats), description: i18n("Settings.Folders.AllChatsHidden.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "eye.slash", iconColor: .gray, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .folders, settingName: .compactFolderNames, value: SGSimpleSettings.shared.compactFolderNames, title: i18n("Settings.Folders.CompactNames", lang), description: i18n("Settings.Folders.CompactNames.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "textformat.size.smaller", iconColor: .teal, isNew: false, enabled: true))
        entries.append(.oneFromManySelector(id: id.count, section: .folders, settingName: .allChatsTitleLengthOverride, text: i18n("Settings.Folders.AllChatsTitle", lang), value: i18n("Settings.Folders.AllChatsTitle.\(SGSimpleSettings.shared.allChatsTitleLengthOverride)", lang), enabled: true))

        // MARK: Stories
        entries.append(.header(id: id.count, section: .stories, text: strings.AutoDownloadSettings_Stories.uppercased(), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .stories, settingName: .hideStories, value: SGSimpleSettings.shared.hideStories, title: i18n("Settings.Stories.Hide", lang), description: i18n("Settings.Stories.Hide.Desc", lang), iconName: "circle.dashed", iconColor: .violet, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .stories, settingName: .disableSwipeToRecordStory, value: SGSimpleSettings.shared.disableSwipeToRecordStory, title: i18n("Settings.Stories.DisableSwipeToRecord", lang), description: i18n("Settings.Stories.DisableSwipeToRecord.Desc", lang), iconName: "hand.draw.fill", iconColor: .pink, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .stories, settingName: .showRepostToStory, value: SGSimpleSettings.shared.showRepostToStoryV2, title: strings.Share_RepostToStory.replacingOccurrences(of: "\n", with: " "), description: i18n("Settings.Stories.RepostToStory.Desc", lang), iconName: "square.and.arrow.up.circle.fill", iconColor: .teal, isNew: false, enabled: true))
        // SG: the client-side story "Stealth Mode" toggle was removed — it suppressed the view
        // receipt (read-receipt tampering, ToS §1.4) and risked the fork's api_id. Telegram's
        // official server-honored stealth mode remains available natively.

        // MARK: Reminders
        entries.append(.header(id: id.count, section: .tools, text: i18n("Settings.Reminders.Header", lang), badge: nil))
        // MARK: Zenlygram — Helper Bots hidden for now. The curated list currently ships placeholder
        // usernames that don't resolve, so the whole feature is a dead end. Re-enable by restoring the
        // row below once real Zenlygram helper bots exist. The .helperBots link handler and
        // sgHelperBotsController are kept intact so this is a one-line revert. When revived the row belongs on
        // the hub's MAIN FEATURES block (`sgHubEntries`), not here.
        // entries.append(.iconDisclosure(id: id.count, section: .tools, link: .helperBots, title: i18n("Settings.HelperBots", lang), value: "", iconName: "bolt.circle.fill", iconColor: .teal, isNew: SGNewBadgeTracker.shouldShow("helperBots")))
        entries.append(.iconToggle(id: id.count, section: .tools, settingName: .unreadReminderEnabled, value: SGSimpleSettings.shared.unreadReminderEnabled, title: i18n("Settings.UnreadReminder", lang), description: i18n("Settings.UnreadReminder.Desc", lang), iconName: "bell.badge.fill", iconColor: .orange, isNew: SGNewBadgeTracker.shouldShow("unreadReminderEnabled"), enabled: true))
        entries.append(.notice(id: id.count, section: .tools, text: i18n("Settings.UnreadReminder.Notice", lang)))
    case .messages:
        // MARK: Messages & Bubbles
        entries.append(.header(id: id.count, section: .messages, text: i18n("Settings.Messages.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .messages, settingName: .hideReactions, value: SGSimpleSettings.shared.hideReactions, title: i18n("Settings.HideReactions", lang), description: i18n("Settings.HideReactions.Desc", lang), iconName: "heart.slash.fill", iconColor: .red, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .messages, settingName: .secondsInMessages, value: SGSimpleSettings.shared.secondsInMessages, title: i18n("Settings.secondsInMessages", lang), description: i18n("Settings.secondsInMessages.Desc", lang), iconName: "clock.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .messages, settingName: .wideChannelPosts, value: SGSimpleSettings.shared.wideChannelPosts, title: i18n("Settings.wideChannelPosts", lang), description: i18n("Settings.wideChannelPosts.Desc", lang), iconName: "arrow.left.and.right.square.fill", iconColor: .orange, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .messages, settingName: .hideChannelBottomButton, value: !SGSimpleSettings.shared.hideChannelBottomButton, title: i18n("Settings.showChannelBottomButton", lang), description: i18n("Settings.showChannelBottomButton.Desc", lang), iconName: "rectangle.bottomthird.inset.filled", iconColor: .teal, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .messages, settingName: .disableSnapDeletionEffect, value: !SGSimpleSettings.shared.disableSnapDeletionEffect, title: i18n("Settings.SnapDeletionEffect", lang), description: i18n("Settings.SnapDeletionEffect.Desc", lang), iconName: "sparkles", iconColor: .purple, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .messages, settingName: .disableScrollToNextChannel, value: !SGSimpleSettings.shared.disableScrollToNextChannel, title: i18n("Settings.PullToNextChannel", lang), description: i18n("Settings.PullToNextChannel.Desc", lang), iconName: "arrow.down.circle.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .messages, settingName: .disableScrollToNextTopic, value: !SGSimpleSettings.shared.disableScrollToNextTopic, title: i18n("Settings.PullToNextTopic", lang), description: i18n("Settings.PullToNextTopic.Desc", lang), iconName: "arrow.down.to.line.circle.fill", iconColor: .lightBlue, isNew: false, enabled: true))

        // MARK: Composing & Input
        entries.append(.header(id: id.count, section: .composing, text: i18n("Settings.Composing.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .composing, settingName: .sendWithReturnKey, value: SGSimpleSettings.shared.sendWithReturnKey, title: i18n("Settings.SendWithReturnKey", lang), description: i18n("Settings.SendWithReturnKey.Desc", lang), iconName: "return", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .composing, settingName: .messageDoubleTapActionOutgoingEdit, value: SGSimpleSettings.shared.messageDoubleTapActionOutgoing == SGSimpleSettings.MessageDoubleTapAction.edit.rawValue, title: i18n("Settings.messageDoubleTapActionOutgoingEdit", lang), description: i18n("Settings.messageDoubleTapActionOutgoingEdit.Desc", lang), iconName: "hand.tap.fill", iconColor: .purple, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .composing, settingName: .disableSendAsButton, value: !SGSimpleSettings.shared.disableSendAsButton, title: i18n("Settings.SendAsButton", lang, strings.Conversation_SendMesageAs), description: i18n("Settings.SendAsButton.Desc", lang), iconName: "person.crop.circle.badge.checkmark", iconColor: .teal, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .composing, settingName: .hideRecordingButton, value: !SGSimpleSettings.shared.hideRecordingButton, title: i18n("Settings.RecordingButton", lang), description: i18n("Settings.RecordingButton.Desc", lang), iconName: "mic.circle.fill", iconColor: .red, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .composing, settingName: .forceEmojiTab, value: SGSimpleSettings.shared.forceEmojiTab, title: i18n("Settings.ForceEmojiTab", lang), description: i18n("Settings.ForceEmojiTab.Desc", lang), iconName: "face.smiling.fill", iconColor: .yellow, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .composing, settingName: .defaultEmojisFirst, value: SGSimpleSettings.shared.defaultEmojisFirst, title: i18n("Settings.DefaultEmojisFirst", lang), description: i18n("Settings.DefaultEmojisFirst.Desc", lang), iconName: "face.smiling", iconColor: .gold, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .composing, text: i18n("Settings.DefaultEmojisFirst.Notice", lang)))
    case .messageMenu:
        // MARK: Message Menu (inline — common → moderation → developer, JSON last)
        entries.append(.header(id: id.count, section: .contextMenu, text: i18n("Settings.ContextMenu", lang), badge: nil))
        entries.append(.notice(id: id.count, section: .contextMenu, text: i18n("Settings.ContextMenu.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowSaveToCloud, value: SGSimpleSettings.shared.contextShowSaveToCloud, title: i18n("ContextMenu.SaveToCloud", lang), description: i18n("ContextMenu.SaveToCloud.Desc", lang), iconName: "icloud.and.arrow.down.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowSaveMedia, value: SGSimpleSettings.shared.contextShowSaveMedia, title: strings.Conversation_SaveToFiles, description: i18n("Settings.ContextShowSaveMedia.Desc", lang), iconName: "square.and.arrow.down.fill", iconColor: .green, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowReply, value: SGSimpleSettings.shared.contextShowReply, title: strings.Conversation_ContextMenuReply, description: i18n("Settings.ContextShowReply.Desc", lang), iconName: "arrowshape.turn.up.left.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowPin, value: SGSimpleSettings.shared.contextShowPin, title: strings.Conversation_Pin, description: i18n("Settings.ContextShowPin.Desc", lang), iconName: "pin.fill", iconColor: .orange, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowSelectFromUser, value: SGSimpleSettings.shared.contextShowSelectFromUser, title: i18n("ContextMenu.SelectFromUser", lang), description: i18n("ContextMenu.SelectFromUser.Desc", lang), iconName: "person.crop.circle.badge.checkmark", iconColor: .teal, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowMessageReplies, value: SGSimpleSettings.shared.contextShowMessageReplies, title: strings.Conversation_ContextViewThread, description: i18n("Settings.ContextShowMessageReplies.Desc", lang), iconName: "bubble.left.and.bubble.right.fill", iconColor: .purple, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowHideForwardName, value: SGSimpleSettings.shared.contextShowHideForwardName, title: strings.Conversation_ForwardOptions_HideSendersNames, description: i18n("Settings.ContextShowHideForwardName.Desc", lang), iconName: "person.fill.xmark", iconColor: .orange, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowReport, value: SGSimpleSettings.shared.contextShowReport, title: strings.Conversation_ContextMenuReport, description: i18n("Settings.ContextShowReport.Desc", lang), iconName: "exclamationmark.bubble.fill", iconColor: .orange, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowRestrict, value: SGSimpleSettings.shared.contextShowRestrict, title: strings.Conversation_ContextMenuBan, description: i18n("Settings.ContextShowRestrict.Desc", lang), iconName: "nosign", iconColor: .red, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .contextMenu, settingName: .contextShowJson, value: SGSimpleSettings.shared.contextShowJson, title: "JSON", description: i18n("Settings.ContextShowJson.Desc", lang), iconName: "curlybraces", iconColor: .gray, isNew: false, enabled: true))
        /* entries.append(.toggle(id: id.count, section: .contextMenu, settingName: .contextShowRestrict, value: SGSimpleSettings.shared.contextShowRestrict, text: strings.Conversation_ContextMenuBan)) */
    case .tabBar:
        // MARK: Tab Bar
        entries.append(.header(id: id.count, section: .tabs, text: i18n("Settings.Tabs.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .hideTabBar, value: SGSimpleSettings.shared.hideTabBar, title: i18n("Settings.Tabs.HideTabBar", lang), description: i18n("Settings.Tabs.HideTabBar.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "rectangle.bottomthird.inset.filled", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .showTabNames, value: SGSimpleSettings.shared.showTabNames, title: i18n("Settings.Tabs.ShowNames", lang), description: i18n("Settings.Tabs.ShowNames.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "textformat", iconColor: .teal, isNew: false, enabled: !SGSimpleSettings.shared.hideTabBar))
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .tabBarSearchEnabled, value: SGSimpleSettings.shared.tabBarSearchEnabled, title: i18n("Settings.Tabs.SearchButton", lang), description: i18n("Settings.Tabs.SearchButton.Desc", lang), iconName: "magnifyingglass", iconColor: .blue, isNew: false, enabled: !SGSimpleSettings.shared.hideTabBar))
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .showContactsTab, value: callListSettings.showContactsTab, title: i18n("Settings.Tabs.ShowContacts", lang), description: i18n("Settings.Tabs.ShowContacts.Desc", lang), iconName: "person.2.fill", iconColor: .green, isNew: false, enabled: !SGSimpleSettings.shared.hideTabBar))
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .showCallsTab, value: callListSettings.showTab, title: strings.CallSettings_TabIcon, description: i18n("Settings.Tabs.ShowCalls.Desc", lang), iconName: "phone.fill", iconColor: .green, isNew: false, enabled: !SGSimpleSettings.shared.hideTabBar))
        // Zenlygram — local Tasks tab visibility; the hub's Tasks row stays reachable while the tab is hidden.
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .showTasksTab, value: callListSettings.showTasksTab, title: i18n("Settings.Tabs.ShowTasks", lang), description: i18n("Settings.Tabs.ShowTasks.Desc", lang), iconName: "checklist", iconColor: .blue, isNew: false, enabled: !SGSimpleSettings.shared.hideTabBar))
        #if SG_LENTA
        // Zenlygram — Lenta tab: an explicit choice here overrides the availability rule; the hub's Lenta row
        // stays reachable while the tab is hidden.
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .showLentaTab, value: callListSettings._showLentaTab ?? state.lentaTabAutomaticallyVisible, title: SGFeedStrings.SGFeedL10n.string("SGFeedUI.Settings.ShowTab", lang), description: SGFeedStrings.SGFeedL10n.string("SGFeedUI.Settings.ShowTab.Desc", lang), iconName: "rectangle.stack", iconColor: .violet, isNew: false, enabled: !SGSimpleSettings.shared.hideTabBar))
        #endif
        entries.append(.iconToggle(id: id.count, section: .tabs, settingName: .wideTabBar, value: SGSimpleSettings.shared.wideTabBar, title: i18n("Settings.Tabs.WideTabBar", lang), description: i18n("Settings.Tabs.WideTabBar.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "arrow.left.and.right", iconColor: .purple, isNew: false, enabled: !SGSimpleSettings.shared.hideTabBar))
        entries.append(.notice(id: id.count, section: .tabs, text: i18n("Settings.Tabs.WideTabBar.Notice", lang)))
    case .privacy:
        // MARK: Zenlygram — Privacy: Who Can Reach You (reuses existing Settings.PrivacySecurity.Header + .privacySecurity case)
        entries.append(.header(id: id.count, section: .privacySecurity, text: i18n("Settings.PrivacySecurity.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .privacySecurity, settingName: .blockForeignUsers, value: SGSimpleSettings.shared.blockForeignUsers, title: i18n("Settings.BlockForeignUsers", lang), description: i18n("Settings.BlockForeignUsers.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "person.crop.circle.badge.xmark", iconColor: .orange, isNew: SGNewBadgeTracker.shouldShow("blockForeignUsers"), enabled: true))
        entries.append(.notice(id: id.count, section: .privacySecurity, text: i18n("Settings.BlockForeignUsers.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .privacySecurity, settingName: .autoAcceptRequests, value: SGSimpleSettings.shared.autoAcceptRequests, title: i18n("Settings.AutoAcceptRequests", lang), description: i18n("Settings.AutoAcceptRequests.Desc", lang), iconName: "checkmark.circle.fill", iconColor: .green, isNew: SGNewBadgeTracker.shouldShow("autoAcceptRequests"), enabled: true))
        entries.append(.iconToggle(id: id.count, section: .privacySecurity, settingName: .confirmCalls, value: SGSimpleSettings.shared.confirmCalls, title: i18n("Settings.CallConfirmation", lang), description: i18n("Settings.CallConfirmation.Desc", lang), iconName: "phone.badge.checkmark", iconColor: .orange, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .privacySecurity, text: i18n("Settings.CallConfirmation.Notice", lang)))

        // MARK: Zenlygram — Privacy: Stay Invisible
        entries.append(.header(id: id.count, section: .privacyInvisible, text: i18n("Settings.Privacy.Invisible.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .privacyInvisible, settingName: .hidePhoneInSettings, value: SGSimpleSettings.shared.hidePhoneInSettings, title: i18n("Settings.HidePhoneInSettingsUI", lang), description: i18n("Settings.HidePhoneInSettingsUI.Desc", lang) + i18n("Settings.RestartRequiredHint", lang), iconName: "phone.down.fill", iconColor: .gray, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .privacyInvisible, text: i18n("Settings.HidePhoneInSettingsUI.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .privacyInvisible, settingName: .warnOnStoriesOpen, value: SGSimpleSettings.shared.warnOnStoriesOpen, title: i18n("Settings.Stories.WarnBeforeView", lang), description: i18n("Settings.Stories.WarnBeforeView.Desc", lang), iconName: "exclamationmark.triangle.fill", iconColor: .yellow, isNew: false, enabled: true))

        // MARK: Reveal & Profile Intelligence (reuses existing Settings.Profiles.Header + .profiles case)
        entries.append(.header(id: id.count, section: .profiles, text: i18n("Settings.Profiles.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .profiles, settingName: .showRegDate, value: SGSimpleSettings.shared.showRegDate, title: i18n("Settings.ShowRegDate", lang), description: i18n("Settings.ShowRegDate.Desc", lang), iconName: "calendar.badge.clock", iconColor: .green, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.ShowRegDate.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .profiles, settingName: .showCreationDate, value: SGSimpleSettings.shared.showCreationDate, title: i18n("Settings.ShowCreationDate", lang), description: i18n("Settings.ShowCreationDate.Desc", lang), iconName: "calendar.badge.plus", iconColor: .lightBlue, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.ShowCreationDate.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .profiles, settingName: .showDC, value: SGSimpleSettings.shared.showDC, title: i18n("Settings.ShowDC", lang), description: i18n("Settings.ShowDC.Desc", lang), iconName: "server.rack", iconColor: .teal, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .profiles, settingName: .showProfileId, value: SGSimpleSettings.shared.showProfileId, title: i18n("Settings.ShowProfileID", lang), description: i18n("Settings.ShowProfileID.Desc", lang), iconName: "number.circle.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .profiles, settingName: .showViewFirstMessage, value: SGSimpleSettings.shared.showViewFirstMessage, title: i18n("Settings.ViewFirstMessage", lang), description: i18n("Settings.ViewFirstMessage.Desc", lang), iconName: "arrow.up.to.line", iconColor: .blue, isNew: SGNewBadgeTracker.shouldShow("showViewFirstMessage"), enabled: true))
    case .translation:
        // MARK: Translation & Voice-to-Text (merged translation + transcription + voice into one .translation box)
        entries.append(.header(id: id.count, section: .translation, text: strings.Localization_TranslateMessages.uppercased(), badge: nil))
        entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationBackend, text: i18n("Settings.Translation.Backend", lang), value: i18n("Settings.Translation.Backend.\(SGSimpleSettings.shared.translationBackend)", lang), enabled: true))
        if SGSimpleSettings.shared.translationBackendEnum != .gtranslate {
            entries.append(.notice(id: id.count, section: .translation, text: i18n("Settings.Translation.Backend.Notice", lang, "Settings.Translation.Backend.\(SGSimpleSettings.TranslationBackend.gtranslate.rawValue)".i18n(lang))))
        } else {
            entries.append(.notice(id: id.count, section: .translation, text: i18n("Settings.Translation.Backend.Notice.Google", lang))) // Zenlygram — #60: say what goes to Google (same id slot)
        }
        entries.append(.iconToggle(id: id.count, section: .translation, settingName: .quickTranslateButton, value: SGSimpleSettings.shared.quickTranslateButton, title: i18n("Settings.Translation.QuickTranslateButton", lang), description: i18n("Settings.Translation.QuickTranslateButton.Desc", lang), iconName: "character.bubble.fill", iconColor: .pink, isNew: false, enabled: true))
        entries.append(.iconDisclosure(id: id.count, section: .translation, link: .languageSettings, title: strings.Localization_TranslateEntireChat, value: "", iconName: "globe", iconColor: .pink, isNew: false))
        // Zenlygram — #60: honest whole-chat translation notice (was "You don't need Telegram Premium!").
        entries.append(.notice(id: id.count, section: .translation, text: i18n("Settings.Translation.EntireChat.Notice", lang, strings.Settings_Premium)))
        entries.append(.header(id: id.count, section: .translation, text: "Settings.Transcription.Header".i18n(lang), badge: nil))
        entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .transcriptionBackend, text: i18n("Settings.Transcription.Backend", lang), value: i18n("Settings.Transcription.Backend.\(SGSimpleSettings.shared.transcriptionBackend)", lang), enabled: true))
        if SGSimpleSettings.shared.transcriptionBackendEnum != .apple {
            entries.append(.notice(id: id.count, section: .translation, text: i18n("Settings.Transcription.Backend.Notice", lang, "Settings.Transcription.Backend.\(SGSimpleSettings.TranscriptionBackend.apple.rawValue)".i18n(lang))))
        } else {
            id.increment(1)
        }
        entries.append(.header(id: id.count, section: .translation, text: strings.Privacy_VoiceMessages.uppercased(), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .translation, settingName: .forceBuiltInMic, value: SGSimpleSettings.shared.forceBuiltInMic, title: i18n("Settings.forceBuiltInMic", lang), description: i18n("Settings.forceBuiltInMic.Desc", lang), iconName: "mic.fill", iconColor: .red, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .translation, text: i18n("Settings.forceBuiltInMic.Notice", lang)))
    case .media:
        // MARK: Downloads & Speed (reuses existing Settings.Media.Header)
        entries.append(.header(id: id.count, section: .downloads, text: i18n("Settings.Media.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .downloads, settingName: .autoDownloadDisabled, value: SGSimpleSettings.shared.autoDownloadDisabled, title: i18n("Settings.DisableAutoDownload", lang), description: i18n("Settings.DisableAutoDownload.Desc", lang), iconName: "arrow.down.circle.fill", iconColor: .orange, isNew: SGNewBadgeTracker.shouldShow("autoDownloadDisabled"), enabled: true))
        entries.append(.oneFromManySelector(id: id.count, section: .downloads, settingName: .downloadSpeedBoost, text: i18n("Settings.DownloadsBoost", lang), value: i18n("Settings.DownloadsBoost.\(SGSimpleSettings.shared.downloadSpeedBoost)", lang), enabled: true))
        entries.append(.notice(id: id.count, section: .downloads, text: i18n("Settings.DownloadsBoost.Notice", lang) + i18n("Settings.RestartRequiredHint", lang)))
        entries.append(.iconToggle(id: id.count, section: .downloads, settingName: .uploadSpeedBoost, value: SGSimpleSettings.shared.uploadSpeedBoost, title: i18n("Settings.UploadsBoost", lang), description: i18n("Settings.UploadsBoost.Desc", lang), iconName: "arrow.up.circle.fill", iconColor: .green, isNew: false, enabled: true))

        // MARK: Photos & Stickers (merged photo + stickers into one .photo box)
        entries.append(.header(id: id.count, section: .photo, text: strings.NetworkUsageSettings_MediaImageDataSection, badge: nil))
        entries.append(.header(id: id.count, section: .photo, text: strings.PhotoEditor_QualityTool.uppercased(), badge: nil))
        entries.append(.percentageSlider(id: id.count, section: .photo, settingName: .outgoingPhotoQuality, value: SGSimpleSettings.shared.outgoingPhotoQuality))
        entries.append(.notice(id: id.count, section: .photo, text: i18n("Settings.Photo.Quality.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .photo, settingName: .sendLargePhotos, value: SGSimpleSettings.shared.sendLargePhotos, title: i18n("Settings.Photo.SendLarge", lang), description: i18n("Settings.Photo.SendLarge.Desc", lang), iconName: "photo.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .photo, text: i18n("Settings.Photo.SendLarge.Notice", lang)))
        entries.append(.header(id: id.count, section: .photo, text: strings.StickerPacksSettings_Title.uppercased(), badge: nil))
        entries.append(.header(id: id.count, section: .photo, text: i18n("Settings.Stickers.Size", lang), badge: nil))
        entries.append(.percentageSlider(id: id.count, section: .photo, settingName: .stickerSize, value: SGSimpleSettings.shared.stickerSize))
        entries.append(.iconToggle(id: id.count, section: .photo, settingName: .stickerTimestamp, value: SGSimpleSettings.shared.stickerTimestamp, title: i18n("Settings.Stickers.Timestamp", lang), description: i18n("Settings.Stickers.Timestamp.Desc", lang), iconName: "clock.badge.fill", iconColor: .teal, isNew: false, enabled: true))

        // MARK: Video & Round Video (reuses existing Settings.VideoNotes.Header; merges video PIP + round video into .videoNotes)
        entries.append(.header(id: id.count, section: .videoNotes, text: i18n("Settings.VideoNotes.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .videoNotes, settingName: .swipeForVideoPIP, value: SGSimpleSettings.shared.videoPIPSwipeDirection == SGSimpleSettings.VideoPIPSwipeDirection.up.rawValue, title: i18n("Settings.swipeForVideoPIP", lang), description: i18n("Settings.swipeForVideoPIP.Desc", lang), iconName: "pip.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .videoNotes, text: i18n("Settings.swipeForVideoPIP.Notice", lang)))
        entries.append(.iconToggle(id: id.count, section: .videoNotes, settingName: .startTelescopeWithRearCam, value: SGSimpleSettings.shared.startTelescopeWithRearCam, title: i18n("Settings.VideoNotes.StartWithRearCam", lang), description: i18n("Settings.VideoNotes.StartWithRearCam.Desc", lang), iconName: "camera.rotate.fill", iconColor: .blue, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .videoNotes, settingName: .sendRoundVideoFromGallery, value: SGSimpleSettings.shared.sendRoundVideoFromGallery, title: i18n("Settings.RoundVideoFromGallery", lang), description: i18n("Settings.RoundVideoFromGallery.Desc", lang), iconName: "video.circle.fill", iconColor: .blue, isNew: SGNewBadgeTracker.shouldShow("sendRoundVideoFromGallery"), enabled: true))

        // MARK: Camera & Gallery Picker
        entries.append(.header(id: id.count, section: .cameraPicker, text: i18n("Settings.CameraPicker.Header", lang), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .cameraPicker, settingName: .disableGalleryCamera, value: !SGSimpleSettings.shared.disableGalleryCamera, title: i18n("Settings.GalleryCamera", lang), description: i18n("Settings.GalleryCamera.Desc", lang), iconName: "camera.fill", iconColor: .gray, isNew: false, enabled: true))
        entries.append(.iconToggle(id: id.count, section: .cameraPicker, settingName: .disableGalleryCameraPreview, value: !SGSimpleSettings.shared.disableGalleryCameraPreview, title: i18n("Settings.GalleryCameraPreview", lang), description: i18n("Settings.GalleryCameraPreview.Desc", lang), iconName: "camera.viewfinder", iconColor: .gray, isNew: false, enabled: !SGSimpleSettings.shared.disableGalleryCamera))
    case .colors:
        // MARK: Appearance — Name Colors
        entries.append(.header(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Header", lang), badge: nil))
        entries.append(.header(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Saturation", lang), badge: nil))
        let accountColorSaturation = SGSimpleSettings.shared.accountColorsSaturation
        entries.append(.percentageSlider(id: id.count, section: .accountColors, settingName: .accountColorsSaturation, value: accountColorSaturation))
        if accountColorSaturation == 0 {
            id.increment(100)
            entries.append(.peerColorDisclosurePreview(id: id.count, section: .accountColors, name: "\(strings.UserInfo_FirstNamePlaceholder) \(strings.UserInfo_LastNamePlaceholder)", color:         presentationData.theme.chat.message.incoming.accentTextColor))
        } else {
            id.increment(200)
            for index in nameColors.displayOrder.prefix(3) {
                let color: PeerNameColor = PeerNameColor(rawValue: index)
                let colors = nameColors.get(color, dark: presentationData.theme.overallDarkAppearance)
                entries.append(.peerColorDisclosurePreview(id: id.count, section: .accountColors, name: "\(strings.UserInfo_FirstNamePlaceholder) \(strings.UserInfo_LastNamePlaceholder)", color: colors.main))
            }
        }
        entries.append(.notice(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Saturation.Notice", lang)))

        // MARK: Zenlygram — seasonal (New Year) styles at the bottom.
        if SGSimpleSettings.shared.canUseNY {
            entries.append(.header(id: id.count, section: .trending, text: i18n("Settings.NY.Header", lang), badge: nil))
            entries.append(.toggle(id: id.count, section: .trending, settingName: .nyStyleSnow, value: SGSimpleSettings.shared.nyStyle == SGSimpleSettings.NYStyle.snow.rawValue, text: i18n("Settings.NY.Style.snow", lang), enabled: true))
            entries.append(.toggle(id: id.count, section: .trending, settingName: .nyStyleLightning, value: SGSimpleSettings.shared.nyStyle == SGSimpleSettings.NYStyle.lightning.rawValue, text: i18n("Settings.NY.Style.lightning", lang), enabled: true))
            entries.append(.notice(id: id.count, section: .trending, text: i18n("Settings.NY.Notice", lang)))
        } else {
            id.increment(3)
        }
    case .callsAdvanced:
        // MARK: Calls & Voice
        entries.append(.header(id: id.count, section: .calls, text: strings.Calls_TabTitle.uppercased(), badge: nil))
        entries.append(.iconToggle(id: id.count, section: .calls, settingName: .enableVoipTcp, value: experimentalUISettings.enableVoipTcp, title: i18n("Settings.ForceTCP", lang), description: i18n("Settings.ForceTCP.Desc", lang), iconName: "network", iconColor: .green, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .calls, text: "Common.KnowWhatYouDo".i18n(lang)))

        // MARK: Advanced (contentSettings gated by appConfiguration, then autoProxy — hidden while the
        // bundled proxy list ships empty; the header goes too when the whole section would be empty)
        let autoProxyAvailable = SGAutoProxyManager.shared.isAvailable
        if appConfiguration.sgWebSettings.global.canEditSettings || autoProxyAvailable {
            entries.append(.header(id: id.count, section: .advanced, text: i18n("Settings.Advanced.Header", lang), badge: nil))
        } else {
            id.increment(1)
        }
        if appConfiguration.sgWebSettings.global.canEditSettings {
            entries.append(.iconDisclosure(id: id.count, section: .advanced, link: .contentSettings, title: i18n("Settings.ContentSettings", lang), value: "", iconName: "eye.trianglebadge.exclamationmark.fill", iconColor: .red, isNew: false))
        } else {
            id.increment(1)
        }
        if autoProxyAvailable {
            entries.append(.iconToggle(id: id.count, section: .advanced, settingName: .autoProxyEnabled, value: SGSimpleSettings.shared.autoProxyEnabled, title: i18n("Settings.AutoProxy", lang), description: i18n("Settings.AutoProxy.Desc", lang), iconName: "lock.shield", iconColor: .green, isNew: SGNewBadgeTracker.shouldShow("autoProxyEnabled"), enabled: true))
            entries.append(.notice(id: id.count, section: .advanced, text: i18n("Settings.AutoProxy.Notice", lang)))
        } else {
            id.increment(2)
        }

        // MARK: AI Assistant
        // MARK: Zenlygram — the AI Assistant is refused by this build: `has(.ai)` stays false while `.ai`
        // is in `SGEntitlementCapability.refusedByThisBuild`, whatever the server sends. It ships only in
        // a release that removes `.ai` from that set and updates the privacy documents in the same release.
        if SGEntitlement.has(.ai) {
            entries.append(.header(id: id.count, section: .aiAssistant, text: i18n("Settings.AiAssistant", lang), badge: nil))
            entries.append(.iconToggle(id: id.count, section: .aiAssistant, settingName: .aiAssistantEnabled, value: SGSimpleSettings.shared.aiAssistantEnabled, title: i18n("Settings.AiAssistant.Enable", lang), description: i18n("Settings.AiAssistant.Enable.Desc", lang), iconName: "sparkles", iconColor: .purple, isNew: SGNewBadgeTracker.shouldShow("aiAssistantEnabled"), enabled: true))
            entries.append(.iconDisclosure(id: id.count, section: .aiAssistant, link: .aiAssistantApiKey, title: i18n("Settings.AiAssistant.ApiKey", lang), value: "", iconName: "key.fill", iconColor: .gray, isNew: false))
            entries.append(.notice(id: id.count, section: .aiAssistant, text: i18n("Settings.AiAssistant.Notice", lang)))
        } else {
            // Same stableId balancing as the vault and recovery blocks on the Secret Vault page: the four rows'
            // ids stay reserved so the release that stops refusing `.ai` slides them in without shifting the
            // stableId of every row below.
            id.increment(4)
        }
    }

    return entries
}

/// The entries of one screen. The hub builds every page too — for the NEW roll-up of its page rows and,
/// while the search field holds a query, to list every page's rows behind its own (§2.2): each page on its
/// own id base (`SGSettingsPage.searchIdBase`), so the ids stay strictly increasing across the whole list
/// (`ItemListControllerNode` asserts that) and a page whose row count varies never shifts another page's
/// stable ids. The unchanged `filterSGItemListUIEntrires` then runs over the whole array — today's
/// cross-section search over every setting — and only after it a surviving group-page header is prefixed
/// with its page title ("TAB BAR — TABS", multiline for ru/uz). Display only: no prefix reaches the filter,
/// so a page name never pulls a whole page into the results. Feature pages keep their headers verbatim.
private func SGControllerEntries(screen: SGSettingsScreen, inputs: SGEntryInputs) -> [SGControllerEntry] {
    switch screen {
    case let .page(page):
        return sgPageEntries(page, inputs, id: SGItemListCounter())
    case .hub:
        let pages = SGSettingsPage.allCases.map { page in
            sgPageEntries(page, inputs, id: SGItemListCounter(base: page.searchIdBase))
        }
        let pageHasNew: (SGSettingsPage) -> Bool = { page in
            pages[page.index].contains { $0.isNew }
        }
        let searchQuery = inputs.state.searchQuery
        let searching = !(searchQuery ?? "").isEmpty
        var entries = sgHubEntries(inputs, id: SGItemListCounter(), searchMode: searching, pageHasNew: pageHasNew)
        #if DEBUG
        if !searching {
            sgAssertCatalogMatchesBuilder(hub: entries, pages: pages)
        }
        #endif
        if searching {
            entries += pages.flatMap { $0 }
        }
        entries = filterSGItemListUIEntrires(entries: entries, by: searchQuery)
        if searching {
            // The filter keeps every header of a section with a match, and some sections carry several
            // sub-headers (Translation & Voice three, Media four): the ones no row follows would read,
            // prefixed, as broken sections ("TRANSLATION & VOICE — VOICE MESSAGES" over nothing). Display
            // only, before the prefix: the filter's semantics and the stable ids are untouched.
            entries = removeSGItemListUIHeadersWithoutRows(entries: entries)
            let lang = inputs.presentationData.strings.baseLanguageCode
            let allPages = SGSettingsPage.allCases
            entries = entries.map { entry -> SGControllerEntry in
                guard case let .header(id, section, text, badge, _) = entry, id >= 1000 else {
                    return entry
                }
                // The page a header came from is its id base (`searchIdBase` = (index + 1) * 1000).
                let pageIndex = id / 1000 - 1
                guard pageIndex >= 0, pageIndex < allPages.count, allPages[pageIndex].isGroup else {
                    return entry
                }
                // An em dash, never "›": VoiceOver reads the glyph.
                return .header(id: id, section: section, text: "\(i18n(allPages[pageIndex].titleKey, lang).uppercased()) — \(text)", badge: badge, multiline: true)
            }
        }
        return entries
    }
}

// MARK: Zenlygram — local retention features (Show Deleted Messages, Edit History), Batch 6 (#50/#68)
private enum SGRetentionFeature {
    case keptDeleted
    case editHistory
}

/// Turning a retention feature off also deletes what it stored on this device. Counts the stored data
/// over every active account; with nothing stored it just turns off, otherwise it asks first
/// (Cancel keeps the feature on). The persisted purge request covers accounts that are not loaded
/// and a crash mid-purge (the TelegramCore sweeper finishes it on the next launch).
private func sgConfirmRetentionDisable(_ feature: SGRetentionFeature, context: AccountContext, present: @escaping (ViewController) -> Void, refresh: @escaping () -> Void) {
    let countSignal: (Account) -> Signal<Int, NoError> = { account in
        switch feature {
        case .keptDeleted:
            return sgKeptDeletedMessageCount(account: account)
        case .editHistory:
            return sgEditHistoryMessageCount(account: account)
        }
    }
    let purgeSignal: (Account) -> Signal<Int, NoError> = { account in
        switch feature {
        case .keptDeleted:
            return sgRemoveKeptDeletedMessages(account: account)
        case .editHistory:
            return sgDeleteAllEditHistory(account: account)
        }
    }
    // Order matters: the flag first (stops new captures), then the persisted purge request, then the purge.
    let turnOff: () -> Void = {
        switch feature {
        case .keptDeleted:
            SGSimpleSettings.shared.showDeletedMessages = false
            SGSimpleSettings.shared.requestKeptDeletedPurge()
        case .editHistory:
            SGSimpleSettings.shared.editHistoryEnabled = false
            SGSimpleSettings.shared.requestEditHistoryPurge()
        }
    }

    let _ = (context.sharedContext.activeAccountContexts
    |> take(1)
    |> mapToSignal { activeAccounts -> Signal<([Account], Int), NoError> in
        let accounts = activeAccounts.accounts.map { $0.1.account }
        return combineLatest(accounts.map(countSignal))
        |> map { counts -> ([Account], Int) in
            return (accounts, counts.reduce(0, +))
        }
    }
    |> deliverOnMainQueue).startStandalone(next: { accounts, total in
        guard total > 0 else {
            turnOff()
            refresh()
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let keyPrefix: String
        switch feature {
        case .keptDeleted:
            keyPrefix = "Settings.ShowDeletedMessages.Disable"
        case .editHistory:
            keyPrefix = "Settings.EditHistory.Disable"
        }
        // Every exit path must refresh exactly once: an action runs before the alert dismisses,
        // and the dismissed hook below fires after it, so the guard turns the hook into a no-op then.
        var didRefresh = false
        let refreshOnce: () -> Void = {
            if didRefresh {
                return
            }
            didRefresh = true
            refresh()
        }
        // No outside-tap dismissal. Esc/Cmd+W on a hardware keyboard still dismiss without an action, so the dismissed hook also refreshes (at most once).
        let alert = textAlertController(context: context, title: i18n(keyPrefix + ".Title", lang), text: i18n(keyPrefix + ".Text", lang, "\(total)"), actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {
                // Snaps the optimistic toggle back on.
                refreshOnce()
            }),
            TextAlertAction(type: .destructiveAction, title: i18n(keyPrefix + ".Action", lang), action: {
                turnOff()
                refreshOnce()
                let _ = (combineLatest(accounts.map(purgeSignal))
                |> deliverOnMainQueue).startStandalone(next: { _ in
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: i18n("Settings.Retention.Removed", presentationData.strings.baseLanguageCode), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true }))
                })
            })
        ], actionLayout: .vertical, dismissOnOutsideTap: false)
        // Esc / Cmd+W (iPad keyboard) dismiss without running an action: nothing was turned off,
        // so clear the pending state and let the row snap back ON to match the still-enabled setting.
        (alert as? AlertScreen)?.dismissed = { _ in
            refreshOnce()
        }
        present(alert)
    })
}

// MARK: - Zenlygram — Secret Vault / Chat Lock protection helpers (audit batch 4: #27, #41, #70, #71, #74)

/// Presents the standard Settings vault-PIN screen.
///
/// Audit #27/#90: every vault check made from Settings goes through exactly this setup —
/// `verifyVaultCredential` (SCREENS ONLY: `ChatPincodeViewController` does the throttle bookkeeping for its
/// own screen, so calling `checkVault` here would count every wrong entry twice) and the `.vault` throttle
/// scope, so these switches and the chat-list secret-code gate share ONE brute-force budget.
private func sgPresentVaultVerify(context: AccountContext, presentPincode: ((UIViewController) -> Void)?, onSuccess: @escaping () -> Void, onForgot: (() -> Void)?, onCancel: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let meta = ChatPincodeManager.shared.getVaultMetadata()
    let controller = ChatPincodeViewController(mode: .verify(passwordType: meta.passwordType, biometricEnabled: meta.biometricEnabled, onVerify: { code in
        ChatPincodeManager.shared.verifyVaultCredential(code)
    }, onSuccess: onSuccess, onForgot: onForgot), presentationData: presentationData, throttleScope: .vault)
    controller.onCancel = onCancel
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.setNavigationBarHidden(true, animated: false)
    navigationController.modalPresentationStyle = .fullScreen
    presentPincode?(navigationController)
}

/// Shared Secret Vault teardown, reached by verifying the vault PIN, by the "Forgot" recovery, or — when the
/// credential is gone entirely — by device-owner authentication in the recovery sheet.
///
/// SG: Secret Vault (design §8.3) — close every open vault (evicts its screens), drop the credential, restore
/// the notifications the vault muted in EVERY account through that account's engine (pending until an
/// inactive account is active again), then clear the per-account sets and the flags.
private func sgPerformVaultDisable(context: AccountContext, refresh: @escaping () -> Void) {
    ChatLockSession.shared.closeVault(accountPeerId: nil, reason: .vaultChanged)
    ChatPincodeManager.shared.removeVault()
    let muteRecords = SecretVaultManager.shared.vaultMuteRecords()
    let unassignedLegacyRecords = SecretVaultManager.shared.unassignedMuteRecordPeerIds()
    let _ = (context.sharedContext.activeAccountContexts
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { contexts in
        var engines: [EnginePeer.Id: TelegramEngine] = [:]
        for (_, accountContext, _) in contexts.accounts {
            engines[accountContext.account.peerId] = accountContext.engine
        }
        // Zenlygram — audit #74: after a device migration the per-account mute records are gone (they lived
        // in a device-only keychain blob) while the chats are still muted forever on the server. Vault
        // members with no record left are treated as legacy records, so they are unmuted only while they are
        // still muted forever. Captured HERE, before `clearVault()` below empties the membership.
        var missingRecords: [EnginePeer.Id: Set<PeerId>] = [:]
        for accountPeerId in engines.keys {
            let missing = SecretVaultManager.shared.vaultMembersMissingMuteRecords(accountPeerId: accountPeerId)
            if !missing.isEmpty {
                missingRecords[accountPeerId] = missing
            }
        }
        // Unmutes a chat the vault muted; a legacy (pre-per-account, or record-less) entry only while it is
        // still muted forever, so a mute the user set meanwhile is kept.
        let restore: (TelegramEngine, EnginePeer.Id, Bool) -> Void = { engine, peerId, isLegacy in
            if !isLegacy {
                let _ = engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 0).startStandalone()
                return
            }
            let _ = (engine.data.get(TelegramEngine.EngineData.Item.Peer.NotificationSettings(id: peerId))
            |> mapToSignal { settings -> Signal<Void, NoError> in
                if case let .muted(until) = settings.muteState, until == Int32.max {
                    return engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 0)
                }
                return .complete()
            }).startStandalone()
        }
        for (accountPeerId, records) in muteRecords {
            if let engine = engines[accountPeerId] {
                for (peerId, record) in records {
                    restore(engine, peerId, record.isLegacy)
                }
            } else {
                SecretVaultManager.shared.addPendingUnmutes(Set(records.keys), accountPeerId: accountPeerId)
            }
        }
        for (accountPeerId, engine) in engines {
            for peerId in unassignedLegacyRecords where peerId != accountPeerId {
                restore(engine, peerId, true)
            }
        }
        for (accountPeerId, peerIds) in missingRecords {
            if let engine = engines[accountPeerId] {
                for peerId in peerIds where peerId != accountPeerId {
                    restore(engine, peerId, true)
                }
            }
        }
        // Emptied last: the membership above is what tells which chats still have to be unmuted.
        SecretVaultManager.shared.clearVault()
    })
    // The reveal gesture goes back to the long press: a secret code without a vault behind it would keep
    // holding whatever is typed into the chat-list search (audit #27/#73).
    SGSimpleSettings.shared.secretVaultUseSecretCode = false
    SGSimpleSettings.shared.secretVaultEnabled = false
    SecretVaultManager.shared.invalidateFeatureEnabledCache()
    refresh()
}

/// Offers the "Review muted chats" screen after a vault teardown that could not unmute anything itself
/// (audit #74: the membership did not survive the migration, so only the user can tell which chats to
/// unmute).
private func sgOfferMutedChatsReview(context: AccountContext, present: @escaping (ViewController, ViewControllerPresentationArguments?) -> Void, push: @escaping (ViewController) -> Void) {
    present(textAlertController(context: context, title: SGProtectionStrings.mutedReviewTitle, text: SGProtectionStrings.mutedReviewFooter, actions: [
        TextAlertAction(type: .genericAction, title: SGProtectionStrings.later, action: {}),
        TextAlertAction(type: .defaultAction, title: SGProtectionStrings.reviewMutedChats, action: {
            push(sgVaultMutedChatsController(context: context))
        })
    ]), nil)
}

/// Zenlygram — audit batch 4: every protection-recovery action proves device ownership first, and an iPhone
/// with neither a passcode nor an enrolled biometric has nothing to prove it WITH. The flows report
/// `.unavailable` instead of a silent cancel; this is the alert that says what to do about it. Module-internal:
/// the Chat Lock screen (SGChatLockController.swift) reuses it for its RECOVERY / LEGACY rows.
func sgPresentDeviceAuthUnavailable(context: AccountContext, present: @escaping (ViewController, ViewControllerPresentationArguments?) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present(textAlertController(context: context, title: SGProtectionStrings.deviceAuthUnavailableTitle, text: SGProtectionStrings.deviceAuthUnavailableText, actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ]), nil)
}

/// The recovery action sheet (audit #70/#71): only the rows the current state actually needs, each one behind
/// device-owner authentication — the old credential no longer exists, so device ownership is the only proof
/// left. Opening the sheet acknowledges the recovery state, so the one-time chat-list notice stops repeating.
private func sgPresentProtectionRecovery(context: AccountContext, present: @escaping (ViewController, ViewControllerPresentationArguments?) -> Void, push: @escaping (ViewController) -> Void, presentPincode: ((UIViewController) -> Void)?, refresh: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let status = ChatPincodeManager.shared.protectionRecoveryStatus()
    let actionSheet = ActionSheetController(presentationData: presentationData)
    var items: [ActionSheetItem] = []
    // Audit batch 4, belt and braces: with no passcode and no biometrics these rows can never succeed, so
    // they are rendered disabled under one explanatory line instead of as live buttons that do nothing. The
    // completions below still handle `.unavailable` — this check can go stale while the sheet is open.
    let deviceAuthAvailable = ChatLockSession.shared.canAuthenticateDeviceOwner
    // Appended once, directly under whichever explanation comes first, so it sits above the rows it accounts
    // for. Pre-set when authentication IS available: there is then nothing to explain.
    var didAppendAuthHint = deviceAuthAvailable
    let appendAuthHintIfNeeded: () -> Void = {
        guard !didAppendAuthHint else {
            return
        }
        didAppendAuthHint = true
        items.append(ActionSheetTextItem(title: SGProtectionStrings.deviceAuthUnavailableHint))
    }

    if status.vaultNeedsRecovery {
        items.append(ActionSheetTextItem(title: status.vaultUnverifiable
            ? SGProtectionStrings.vaultUnverifiableText
            : SGProtectionStrings.vaultLostText(count: status.vaultMembershipLost ? status.lastKnownVaultMemberCount : 0)))
        appendAuthHintIfNeeded()
        items.append(ActionSheetButtonItem(title: SGProtectionStrings.setNewVaultPin, color: .accent, enabled: deviceAuthAvailable, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            // The core helper authenticates the device owner first, then runs the normal "set a PIN" screen.
            ChatLockSession.shared.runSetNewPinRecovery(.vault, presentationData: presentationData, present: { controller in
                presentPincode?(controller)
            }, completion: { result in
                switch result {
                case .success:
                    // The feature flag survived the migration, but a vault that was turned off through the
                    // sheet and set up again here has to be switched back on.
                    SGSimpleSettings.shared.secretVaultEnabled = true
                    SecretVaultManager.shared.invalidateFeatureEnabledCache()
                case .cancelled:
                    break
                case .unavailable:
                    sgPresentDeviceAuthUnavailable(context: context, present: present)
                }
                refresh()
            })
        }))
        items.append(ActionSheetButtonItem(title: SGProtectionStrings.turnOffVault, color: .destructive, enabled: deviceAuthAvailable, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            // Read before the teardown: clearing the vault also clears the count the offer below needs.
            let memberCount = status.lastKnownVaultMemberCount
            ChatLockSession.shared.authenticateDeviceOwner(reason: SGProtectionStrings.authReason, completion: { result in
                guard case .success = result else {
                    if case .unavailable = result {
                        sgPresentDeviceAuthUnavailable(context: context, present: present)
                    }
                    refresh()
                    return
                }
                sgPerformVaultDisable(context: context, refresh: refresh)
                if memberCount > 0 {
                    sgOfferMutedChatsReview(context: context, present: present, push: push)
                }
            })
        }))
    }

    if status.chatLockNeedsRecovery {
        items.append(ActionSheetTextItem(title: SGProtectionStrings.chatLockLostText(count: status.pendingLockedChatCount)))
        appendAuthHintIfNeeded()
        items.append(ActionSheetButtonItem(title: SGProtectionStrings.setNewChatLockPin, color: .accent, enabled: deviceAuthAvailable, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            ChatLockSession.shared.runSetNewPinRecovery(.chatLock, presentationData: presentationData, present: { controller in
                presentPincode?(controller)
            }, completion: { result in
                if case .unavailable = result {
                    sgPresentDeviceAuthUnavailable(context: context, present: present)
                }
                refresh()
            })
        }))
        items.append(ActionSheetButtonItem(title: SGProtectionStrings.turnOffChatLock, color: .destructive, enabled: deviceAuthAvailable, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            ChatLockSession.shared.runTurnOffChatLockRecovery(completion: { result in
                if case .unavailable = result {
                    sgPresentDeviceAuthUnavailable(context: context, present: present)
                }
                refresh()
            })
        }))
    }

    // The muted-chat list is Telegram's own notification-exception list, not a protected surface, so it needs
    // no authentication of its own. Only offered next to a real recovery row — on its own it would be a
    // baffling answer to a tapped switch.
    if !items.isEmpty && status.lastKnownVaultMemberCount > 0 {
        items.append(ActionSheetButtonItem(title: SGProtectionStrings.reviewMutedChats, color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            push(sgVaultMutedChatsController(context: context))
        }))
    }

    guard !items.isEmpty else {
        // Nothing to recover: the credential simply cannot be read right now (device just booted, keychain
        // busy, protected data unavailable). Say so instead of showing an empty sheet.
        present(textAlertController(context: context, title: SGProtectionLocalCopy.vaultUnreadableTitle, text: SGProtectionLocalCopy.vaultUnreadableText, actions: [
            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
        ]), nil)
        refresh()
        return
    }

    // Shown to the user now, so the one-time launch notice does not repeat for these bits.
    ChatPincodeManager.shared.acknowledgeProtectionRecovery()

    actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
        ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        })
    ])])
    present(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
}

/// Builds one screen of Settings → Zenlygram — the hub or one page — from the same state, arguments and
/// handlers. `screen` decides only the title, which entries are built, which `focus` row can land here, the
/// `screen.view` name, and (on the hub) the page a page-row focus opens. Every closure below
/// (`presentControllerImpl`, `pushControllerImpl`, `presentPincodeControllerImpl`, `askForRestart`) is bound to
/// THIS screen's controller, so PIN modals, confirm alerts, purge and restart toasts present from the screen
/// the user is looking at. The paywall keeps presenting on the main window.
private func makeSGSettingsScreen(context: AccountContext, screen: SGSettingsScreen, focus: SGSettingsFocus?) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    // MARK: Swiftgram — presents a UIKit modal (Chat Lock pincode nav) over the key window.
    var presentPincodeControllerImpl: ((UIViewController) -> Void)?
//    var getRootControllerImpl: (() -> UIViewController?)?
//    var getNavigationControllerImpl: (() -> NavigationController?)?
    var askForRestart: (() -> Void)?

    // Zenlygram — the row a deep link names, when it is on THIS screen (§2.3): on the hub a hub key — or
    // an unknown one, which finds no row and lands on the plain hub; on a page that page's own key. A page
    // key given to the hub is handled in `didAppear` below: the hub pushes the page.
    let localFocusKey: String?
    if let focus = focus, SGSettingsCatalog.page(containing: focus.rawValue) == screen.page {
        localFocusKey = focus.rawValue
    } else {
        localFocusKey = nil
    }
    
    #if SG_LENTA
    var initialState = SGSettingsControllerState()
    initialState.lentaTabAutomaticallyVisible = SGFeedAvailability.allowsAutomaticTab(accountPeerId: context.account.peerId.toInt64())
    #else
    let initialState = SGSettingsControllerState()
    #endif
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((SGSettingsControllerState) -> SGSettingsControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    
//    let sliderPromise = ValuePromise(SGSimpleSettings.shared.accountColorsSaturation, ignoreRepeated: true)
//    let sliderStateValue = Atomic(value: SGSimpleSettings.shared.accountColorsSaturation)
//    let _: ((Int32) -> Int32) -> Void = { f in
//        sliderPromise.set(sliderStateValue.modify( {f($0)}))
//    }
    
    let simplePromise = ValuePromise(true, ignoreRepeated: false)

    // MARK: Zenlygram — analytics (design 40 §10.2), owned by this screen's account. Every call is a
    // no-op without the sink (the pipeline is not active) or the account's `recordEvents` clearance.
    let analyticsAccountPeerId = context.account.peerId.toInt64()
    // `feature.toggle`, sent only once the setting really changed (confirmed paths only).
    let recordFeatureToggle: (SGAnalyticsFeature, Bool) -> Void = { feature, enabled in
        SGAnalytics.featureToggled(feature, enabled: enabled, accountPeerId: analyticsAccountPeerId)
    }
    
    let arguments = SGItemListArguments<SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>(
        context: context,
        /*updatePeerColor: { color in
          updateState { state in
              var updatedState = state
              updatedState.updatedNameColor = color
              return updatedState
          }
        },*/ setBoolValue: { setting, value in
        // MARK: Zenlygram — toggling a row retires its NEW badge (key == the case name used at the entry site).
        SGNewBadgeTracker.markInteracted(String(describing: setting))
        switch setting {
        case .hidePhoneInSettings:
            SGSimpleSettings.shared.hidePhoneInSettings = value
            askForRestart?()
        case .secretVaultEnabled:
            let vaultPresentationData = context.sharedContext.currentPresentationData.with { $0 }
            // Refreshes the list, which re-reads SGSimpleSettings. A rebuild alone can NOT move a UISwitch
            // the user already flipped: on a cancelled / refused path the entries come out identical, the
            // diff applies nothing, and the switch stayed flipped against the real value (QA 10004: Vault
            // drawn Off while it was On). That is why this row and the secret-code row are controlled
            // switches (`enableInteractiveChanges: false`): a tap only asks, and the switch moves when the
            // setting does.
            let refreshVaultRows: () -> Void = {
                SecretVaultManager.shared.invalidateFeatureEnabledCache()
                simplePromise.set(true)
            }
            if value {
                let enableVault: () -> Void = {
                    SGSimpleSettings.shared.secretVaultEnabled = true
                    refreshVaultRows()
                    recordFeatureToggle(.vault, true)
                }
                let revertVault: () -> Void = {
                    SGSimpleSettings.shared.secretVaultEnabled = false
                    refreshVaultRows()
                }
                // Zenlygram — audit batch 4: while the vault waits for recovery (a restored iPhone — the
                // credential did not come along) this switch RENDERS off although the feature flag is still
                // on, so a tap arrives here as `value == true`. The credential then reads `.absent`, and
                // that branch below opens a bare "set a PIN" screen with no device-owner authentication —
                // the one recovery entry point that proved nothing. Worse, the PIN it sets clears the
                // recovery bits, so the "Restore protection" row and its "Review muted chats" action
                // disappear and the chats the old vault muted forever stay muted with no way to find them
                // (audit #74). Check for recovery FIRST and run the same helper as every other entry point.
                let vaultRecoveryStatus = ChatPincodeManager.shared.protectionRecoveryStatus()
                if vaultRecoveryStatus.vaultNeedsRecovery {
                    // Read BEFORE the new credential is set: `setVaultPincode` clears the recovery state
                    // this count is kept next to.
                    let lostMemberCount = vaultRecoveryStatus.lastKnownVaultMemberCount
                    ChatLockSession.shared.runSetNewPinRecovery(.vault, presentationData: vaultPresentationData, present: { controller in
                        presentPincodeControllerImpl?(controller)
                    }, completion: { result in
                        switch result {
                        case .success:
                            enableVault()
                            if lostMemberCount > 0 {
                                // The old vault's mute bookkeeping did not survive the migration either, so
                                // only the user can say which chats it had silenced (audit #74). Offered
                                // here because the recovery row that used to offer it is now gone.
                                sgOfferMutedChatsReview(context: context, present: { c, a in presentControllerImpl?(c, a) }, push: { c in pushControllerImpl?(c) })
                            }
                        case .cancelled:
                            // NOT `revertVault()`: the feature flag is what keeps this vault in recovery
                            // rather than silently off (audit #70), and the secret-code search gate fails
                            // closed on it (#73). The switch already renders OFF while recovery is pending,
                            // so a rebuild is all the UI needs.
                            refreshVaultRows()
                        case .unavailable:
                            sgPresentDeviceAuthUnavailable(context: context, present: { c, a in presentControllerImpl?(c, a) })
                            refreshVaultRows()
                        }
                    })
                    break
                }
                // Zenlygram — audit #41: turning the vault back ON when a credential already exists (it
                // survives delete + reinstall, and a vault turned off without removing it) must PROVE that
                // credential — otherwise anyone holding the phone could re-enable the vault and then use the
                // "Reveal with a secret code" switch below it. Which prompt is right depends on whether the
                // stored credential can be checked at all.
                switch ChatPincodeManager.shared.vaultCredentialHealth() {
                case .ready:
                    if ChatLockSession.shared.hasRecentVaultCredentialProof {
                        // The PIN was entered less than a minute ago (e.g. the user just turned the vault
                        // off): do not ask twice in a row.
                        enableVault()
                    } else {
                        sgPresentVaultVerify(context: context, presentPincode: presentPincodeControllerImpl, onSuccess: {
                            enableVault()
                        }, onForgot: {
                            // The "Forgot" ladder already proved device ownership (or the Chat Lock master
                            // PIN) on the screen itself.
                            enableVault()
                        }, onCancel: {
                            revertVault()
                        })
                    }
                case .unverifiable:
                    // Audit #41: a record from an older build whose UserDefaults-only salt is gone — even the
                    // right PIN would be refused, so offer a new one behind device-owner authentication
                    // instead of an endless "Wrong code" loop. (Reached only when the recovery bits were
                    // never written; the branch above handles the ordinary post-migration case.)
                    ChatLockSession.shared.runSetNewPinRecovery(.vault, presentationData: vaultPresentationData, present: { controller in
                        presentPincodeControllerImpl?(controller)
                    }, completion: { result in
                        switch result {
                        case .success:
                            enableVault()
                        case .cancelled:
                            revertVault()
                        case .unavailable:
                            sgPresentDeviceAuthUnavailable(context: context, present: { c, a in presentControllerImpl?(c, a) })
                            revertVault()
                        }
                    })
                case .unreadable:
                    // Fail closed: enabling now would arm a vault whose PIN nothing can check.
                    presentControllerImpl?(textAlertController(context: context, title: SGProtectionLocalCopy.vaultUnreadableTitle, text: SGProtectionLocalCopy.vaultUnreadableText, actions: [TextAlertAction(type: .defaultAction, title: vaultPresentationData.strings.Common_OK, action: {})]), nil)
                    revertVault()
                case .absent:
                    // MARK: Zenlygram — the Secret Vault's CREATE path in Settings: there is no credential
                    // yet, so this is a first-time setup, not a return to chats the user already hid. The
                    // `.ready` / `.unverifiable` / recovery branches above are deliberately NOT gated —
                    // they restore access to existing hidden chats, and invariant I1 says the server is
                    // never on that path.
                    guard sgEntitlementGate(.createVaultEntry, context: context, present: { c in presentControllerImpl?(c, nil) }) else {
                        revertVault()
                        break
                    }
                    // No credential yet: create one now and only enable after the PIN is set (revert on cancel).
                    let pincodeVC = ChatPincodeViewController(mode: .set(onSuccess: { code, passwordType, biometricEnabled in
                        ChatPincodeManager.shared.setVaultPincode(code, type: passwordType, biometricEnabled: biometricEnabled)
                        enableVault()
                        // One-time explainer: the reveal gesture is otherwise invisible after its
                        // single teaching, so tell the user exactly how to bring hidden chats back,
                        // matching whichever reveal method is currently active.
                        let vaultLang = vaultPresentationData.strings.baseLanguageCode
                        let revealHintText = SGSimpleSettings.shared.secretVaultUseSecretCode
                            ? i18n("Settings.SecretVault.RevealHint.SecretCode", vaultLang)
                            : i18n("Settings.SecretVault.RevealHint.LongTap", vaultLang)
                        presentControllerImpl?(textAlertController(context: context, title: i18n("Settings.SecretVault.RevealHint.Title", vaultLang), text: revealHintText, actions: [TextAlertAction(type: .defaultAction, title: vaultPresentationData.strings.Common_OK, action: {})]), nil)
                    }), presentationData: vaultPresentationData)
                    pincodeVC.onCancel = {
                        revertVault()
                    }
                    let navVC = UINavigationController(rootViewController: pincodeVC)
                    navVC.setNavigationBarHidden(true, animated: false)
                    navVC.modalPresentationStyle = .fullScreen
                    presentPincodeControllerImpl?(navVC)
                }
            } else {
                // Turning OFF requires the vault PIN, then clears the credential and un-hides
                // every vaulted chat so it never silently strands the user's hidden chats.
                if ChatPincodeManager.shared.vaultCredentialHealth() == .ready {
                    sgPresentVaultVerify(context: context, presentPincode: presentPincodeControllerImpl, onSuccess: {
                        sgPerformVaultDisable(context: context, refresh: refreshVaultRows)
                        recordFeatureToggle(.vault, false)
                    }, onForgot: {
                        // Runs on a verified PIN OR the screen's recovery ladder, so a forgotten PIN never
                        // strands the user's hidden chats.
                        sgPerformVaultDisable(context: context, refresh: refreshVaultRows)
                        recordFeatureToggle(.vault, false)
                    }, onCancel: {
                        // Keep it enabled; the next rebuild snaps the toggle back ON.
                        refreshVaultRows()
                    })
                } else {
                    // Zenlygram — audit #70/#74: the credential is gone or cannot be checked (typically after
                    // a migration onto a new iPhone), so there is nothing to verify. Device ownership is the
                    // only proof left, and it IS required: the hidden chats are otherwise a stranger's to
                    // reveal.
                    let memberCount = ChatPincodeManager.shared.protectionRecoveryStatus().lastKnownVaultMemberCount
                    ChatLockSession.shared.authenticateDeviceOwner(reason: SGProtectionStrings.authReason, completion: { result in
                        guard case .success = result else {
                            if case .unavailable = result {
                                // Audit batch 4: no passcode and no biometrics — the tap could otherwise
                                // only ever snap the switch back with no explanation.
                                sgPresentDeviceAuthUnavailable(context: context, present: { c, a in presentControllerImpl?(c, a) })
                            }
                            refreshVaultRows()
                            return
                        }
                        sgPerformVaultDisable(context: context, refresh: refreshVaultRows)
                        recordFeatureToggle(.vault, false)
                        if memberCount > 0 {
                            // The mute bookkeeping did not survive either, so only the user can say which
                            // chats the vault had silenced (audit #74).
                            sgOfferMutedChatsReview(context: context, present: { c, a in presentControllerImpl?(c, a) }, push: { c in pushControllerImpl?(c) })
                        }
                    })
                }
            }
        case .secretVaultUseSecretCode:
            // Zenlygram — audit #27: this switch changes HOW the vault is opened (typing the PIN into the
            // chat-list search), so BOTH directions must prove the vault PIN. It used to apply for free,
            // which let anyone holding the phone arm or disarm the secret code.
            let applySecretCode: () -> Void = {
                SGSimpleSettings.shared.secretVaultUseSecretCode = value
                simplePromise.set(true)
            }
            if ChatLockSession.shared.hasRecentVaultCredentialProof {
                applySecretCode()
            } else if ChatPincodeManager.shared.vaultCredentialHealth() != .ready {
                // No PIN screen could be satisfied right now: send the user to the recovery sheet (or the
                // "cannot be read" alert) instead of a dead end. The switch snaps back.
                sgPresentProtectionRecovery(context: context, present: { c, a in presentControllerImpl?(c, a) }, push: { c in pushControllerImpl?(c) }, presentPincode: presentPincodeControllerImpl, refresh: { simplePromise.set(true) })
                simplePromise.set(true)
            } else {
                // Zenlygram — audit batch 4: `onForgot: nil` hides the screen's Forgot button entirely
                // (`ChatPincodeViewController.syncVisibility`), so a user who forgot the vault PIN had NO
                // rung at all here: the secret code could not be disarmed, and every wrong try fed the
                // shared `.vault` budget until the screen locked out. The screen's own ladder (biometrics,
                // then the gated master rung, then an honest refusal) is the way out, exactly as at the
                // enable/disable and Change-PIN call sites.
                sgPresentVaultVerify(context: context, presentPincode: presentPincodeControllerImpl, onSuccess: {
                    applySecretCode()
                }, onForgot: {
                    applySecretCode()
                }, onCancel: {
                    simplePromise.set(true)
                })
            }
        // MARK: Swiftgram
        case .autoProxyEnabled:
            SGAutoProxyManager.shared.setEnabled(value, sharedContext: context.sharedContext)
        case .autoDownloadDisabled:
            SGSimpleSettings.shared.autoDownloadDisabled = value
            // When on, disable auto-download on every network; off restores it.
            let _ = updateMediaDownloadSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
                var updated = current
                updated.cellular.enabled = !value
                updated.wifi.enabled = !value
                return updated
            }).start()
        case .autoAcceptRequests:
            SGSimpleSettings.shared.autoAcceptRequests = value
            if value {
                SGAutoAcceptManager.startGlobalMonitor(context: context)
            } else {
                SGAutoAcceptManager.stopGlobalMonitor()
            }
        case .showViewFirstMessage:
            SGSimpleSettings.shared.showViewFirstMessage = value
        case .showDeletedMessages:
            // Zenlygram — turning off deletes the kept copies after a confirmation (#68).
            // The pending flag keeps the row off while the alert is open; refresh clears it (see pendingRetentionDisable).
            if value {
                updateState { var s = $0; s.pendingRetentionDisable.remove(.keptDeleted); return s }
                SGSimpleSettings.shared.showDeletedMessages = true
                recordFeatureToggle(.deletedMessages, true)
            } else {
                updateState { var s = $0; s.pendingRetentionDisable.insert(.keptDeleted); return s }
                sgConfirmRetentionDisable(.keptDeleted, context: context, present: { presentControllerImpl?($0, nil) }, refresh: {
                    updateState { var s = $0; s.pendingRetentionDisable.remove(.keptDeleted); return s }
                    simplePromise.set(true)
                    // `refresh` also runs on Cancel: only a confirmed turn-off is a toggle.
                    if !SGSimpleSettings.shared.showDeletedMessages {
                        recordFeatureToggle(.deletedMessages, false)
                    }
                })
            }
        case .showTabNames:
            SGSimpleSettings.shared.showTabNames = value
            askForRestart?()
        case .showContactsTab:
            let _ = (
                updateCallListSettingsInteractively(
                    accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowContactsTab(value) }
                )
            ).start()
        case .showCallsTab:
            let _ = (
                updateCallListSettingsInteractively(
                    accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowTab(value) }
                )
            ).start()
        case .showTasksTab:
            let _ = (
                updateCallListSettingsInteractively(
                    accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowTasksTab(value) }
                )
            ).start()
        #if SG_LENTA
        case .showLentaTab:
            let _ = (
                updateCallListSettingsInteractively(
                    accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowLentaTab(value) }
                )
            ).start()
        #endif
        case .tabBarSearchEnabled:
            SGSimpleSettings.shared.tabBarSearchEnabled = value
        case .wideTabBar:
            SGSimpleSettings.shared.wideTabBar = value
            askForRestart?()
        case .foldersAtBottom:
            let _ = (
                updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.foldersTabAtBottom = value
                        return settings
                    }
                )
            ).start()
        case .startTelescopeWithRearCam:
            SGSimpleSettings.shared.startTelescopeWithRearCam = value
        case .hideStories:
            SGSimpleSettings.shared.hideStories = value
        case .showProfileId:
            SGSimpleSettings.shared.showProfileId = value
        case .warnOnStoriesOpen:
            SGSimpleSettings.shared.warnOnStoriesOpen = value
            recordFeatureToggle(.storyConfirmation, value)
        case .sendWithReturnKey:
            SGSimpleSettings.shared.sendWithReturnKey = value
        case .rememberLastFolder:
            SGSimpleSettings.shared.rememberLastFolder = value
        case .sendLargePhotos:
            SGSimpleSettings.shared.sendLargePhotos = value
        case .disableSwipeToRecordStory:
            SGSimpleSettings.shared.disableSwipeToRecordStory = value
        case .quickTranslateButton:
            SGSimpleSettings.shared.quickTranslateButton = value
            recordFeatureToggle(.translation, value)
        case .uploadSpeedBoost:
            SGSimpleSettings.shared.uploadSpeedBoost = value
        case .hideReactions:
            SGSimpleSettings.shared.hideReactions = value
        case .showRepostToStory:
            SGSimpleSettings.shared.showRepostToStoryV2 = value
        case .contextShowSelectFromUser:
            SGSimpleSettings.shared.contextShowSelectFromUser = value
        case .contextShowSaveToCloud:
            SGSimpleSettings.shared.contextShowSaveToCloud = value
        case .editHistoryEnabled:
            // Zenlygram — turning off deletes the stored revisions after a confirmation (#50).
            // The pending flag keeps the row off while the alert is open; refresh clears it (see pendingRetentionDisable).
            if value {
                // MARK: Zenlygram — this toggle is the user's consent, not a billing gate. In paid mode
                // without a grant, NEW capture is stopped in the replay (`createRetainedHistoryRecord`,
                // mirrored to `editHistoryCaptureBlocked`); what was retained stays readable. Turning the
                // feature OFF (the branch below, which also offers to delete it) is never gated either.
                updateState { var s = $0; s.pendingRetentionDisable.remove(.editHistory); return s }
                SGSimpleSettings.shared.editHistoryEnabled = true
                recordFeatureToggle(.editHistory, true)
            } else {
                updateState { var s = $0; s.pendingRetentionDisable.insert(.editHistory); return s }
                sgConfirmRetentionDisable(.editHistory, context: context, present: { presentControllerImpl?($0, nil) }, refresh: {
                    updateState { var s = $0; s.pendingRetentionDisable.remove(.editHistory); return s }
                    simplePromise.set(true)
                    // `refresh` also runs on Cancel: only a confirmed turn-off is a toggle.
                    if !SGSimpleSettings.shared.editHistoryEnabled {
                        recordFeatureToggle(.editHistory, false)
                    }
                })
            }
        case .contextShowRestrict:
            SGSimpleSettings.shared.contextShowRestrict = value
        case .contextShowHideForwardName:
            SGSimpleSettings.shared.contextShowHideForwardName = value
        case .disableScrollToNextChannel:
            SGSimpleSettings.shared.disableScrollToNextChannel = !value
        case .disableScrollToNextTopic:
            SGSimpleSettings.shared.disableScrollToNextTopic = !value
        case .disableChatSwipeOptions:
            SGSimpleSettings.shared.disableChatSwipeOptions = !value
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
            askForRestart?()
        case .disableDeleteChatSwipeOption:
            SGSimpleSettings.shared.disableDeleteChatSwipeOption = !value
            askForRestart?()
        case .disableGalleryCamera:
            SGSimpleSettings.shared.disableGalleryCamera = !value
            simplePromise.set(true)
        case .disableGalleryCameraPreview:
            SGSimpleSettings.shared.disableGalleryCameraPreview = !value
        case .disableSendAsButton:
            SGSimpleSettings.shared.disableSendAsButton = !value
        case .disableSnapDeletionEffect:
            SGSimpleSettings.shared.disableSnapDeletionEffect = !value
        case .contextShowReport:
            SGSimpleSettings.shared.contextShowReport = value
        case .contextShowReply:
            SGSimpleSettings.shared.contextShowReply = value
        case .contextShowPin:
            SGSimpleSettings.shared.contextShowPin = value
        case .contextShowSaveMedia:
            SGSimpleSettings.shared.contextShowSaveMedia = value
        case .contextShowMessageReplies:
            SGSimpleSettings.shared.contextShowMessageReplies = value
        case .stickerTimestamp:
            SGSimpleSettings.shared.stickerTimestamp = value
        case .contextShowJson:
            SGSimpleSettings.shared.contextShowJson = value
        case .hideRecordingButton:
            SGSimpleSettings.shared.hideRecordingButton = !value
        case .hideTabBar:
            SGSimpleSettings.shared.hideTabBar = value
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
            askForRestart?()
        case .showDC:
            SGSimpleSettings.shared.showDC = value
        case .showCreationDate:
            SGSimpleSettings.shared.showCreationDate = value
        case .showRegDate:
            SGSimpleSettings.shared.showRegDate = value
        case .compactChatList:
            SGSimpleSettings.shared.compactChatList = value
            askForRestart?()
        case .unlimitedPinnedChats:
            SGSimpleSettings.shared.unlimitedPinnedChats = value
        case .unreadReminderEnabled:
            SGSimpleSettings.shared.unreadReminderEnabled = value
            recordFeatureToggle(.unreadReminder, value)
        case .blockForeignUsers:
            SGSimpleSettings.shared.blockForeignUsers = value
            recordFeatureToggle(.foreignUserBlock, value)
            askForRestart?()
        case .sendRoundVideoFromGallery:
            SGSimpleSettings.shared.sendRoundVideoFromGallery = value
            recordFeatureToggle(.roundVideoFromGallery, value)
        case .callRecordingNotifyOtherParty:
            // Zenlygram — no confirmation and no consequences: this only decides whether starting a
            // recording also sends the other party a message and plays a tone locally.
            SGSimpleSettings.shared.callRecordingNotifyOtherParty = value
        case .callRecordingSendToSavedMessages:
            // Zenlygram — turning this ON is the moment a recording gains a way off the device, and
            // the row's own description (right under the switch) is what says so. Nothing is
            // uploaded retroactively: it decides what happens to recordings made from now on, and
            // turning it off stops that and leaves anything already sent where it is.
            SGSimpleSettings.shared.callRecordingSendToSavedMessages = value
        case .aiAssistantEnabled:
            let aiPresentationData = context.sharedContext.currentPresentationData.with { $0 }
            let aiLang = aiPresentationData.strings.baseLanguageCode
            let presentApiKeyEntryIfNeeded: () -> Void = {
                if !SGAIAssistantKeychain.hasApiKey {
                    presentAIAssistantApiKeyEntry(
                        title: i18n("Settings.AiAssistant.ApiKey", aiLang),
                        message: i18n("Settings.AiAssistant.Notice", aiLang),
                        saveTitle: i18n("Settings.AiAssistant.Save", aiLang),
                        clearTitle: i18n("Settings.AiAssistant.Clear", aiLang),
                        cancelTitle: i18n("Settings.AiAssistant.Cancel", aiLang),
                        errorTitle: i18n("AiAssistant.KeychainError.Title", aiLang),
                        saveErrorText: i18n("AiAssistant.KeychainError.Save", aiLang),
                        clearErrorText: i18n("AiAssistant.KeychainError.Clear", aiLang),
                        okTitle: aiPresentationData.strings.Common_OK
                    )
                }
            }
            if value && !SGSimpleSettings.shared.aiAssistantDisclosureAccepted {
                // One-time App Store data-collection disclosure: the feature only
                // turns on after the user confirms that selected message text is
                // sent to Anthropic and the API key stays in the local Keychain.
                // Cancel aborts enabling.
                presentControllerImpl?(textAlertController(context: context, title: i18n("Chat.ContextMenu.AiAssistant", aiLang), text: i18n("AiAssistant.Disclosure.Text", aiLang), actions: [
                    TextAlertAction(type: .genericAction, title: aiPresentationData.strings.Common_Cancel, action: {
                        SGSimpleSettings.shared.aiAssistantEnabled = false
                        simplePromise.set(true)
                    }),
                    TextAlertAction(type: .defaultAction, title: i18n("AiAssistant.Disclosure.Continue", aiLang), action: {
                        SGSimpleSettings.shared.aiAssistantDisclosureAccepted = true
                        SGSimpleSettings.shared.aiAssistantEnabled = true
                        simplePromise.set(true)
                        presentApiKeyEntryIfNeeded()
                    })
                ]), nil)
                // Snap the switch back OFF until the user confirms (also covers
                // dismissing the alert without picking an action).
                simplePromise.set(true)
            } else {
                SGSimpleSettings.shared.aiAssistantEnabled = value
                if value {
                    presentApiKeyEntryIfNeeded()
                }
            }
        case .compactMessagePreview:
            SGSimpleSettings.shared.chatListLines = value ? SGSimpleSettings.ChatListLines.one.rawValue : SGSimpleSettings.ChatListLines.three.rawValue
            askForRestart?()
        case .compactFolderNames:
            SGSimpleSettings.shared.compactFolderNames = value
            askForRestart?()
        case .allChatsHidden:
            SGSimpleSettings.shared.allChatsHidden = value
            askForRestart?()
        case .defaultEmojisFirst:
            SGSimpleSettings.shared.defaultEmojisFirst = value
        case .messageDoubleTapActionOutgoingEdit:
            SGSimpleSettings.shared.messageDoubleTapActionOutgoing = value ? SGSimpleSettings.MessageDoubleTapAction.edit.rawValue : SGSimpleSettings.MessageDoubleTapAction.default.rawValue
        case .wideChannelPosts:
            SGSimpleSettings.shared.wideChannelPosts = value
        case .forceEmojiTab:
            SGSimpleSettings.shared.forceEmojiTab = value
        case .forceBuiltInMic:
            SGSimpleSettings.shared.forceBuiltInMic = value
        case .hideChannelBottomButton:
            SGSimpleSettings.shared.hideChannelBottomButton = !value
        case .secondsInMessages:
            SGSimpleSettings.shared.secondsInMessages = value
        case .confirmCalls:
            SGSimpleSettings.shared.confirmCalls = value
        case .swipeForVideoPIP:
            SGSimpleSettings.shared.videoPIPSwipeDirection = value ? SGSimpleSettings.VideoPIPSwipeDirection.up.rawValue : SGSimpleSettings.VideoPIPSwipeDirection.none.rawValue
        case .enableVoipTcp:
            let _ = (
                updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.enableVoipTcp = value
                        return settings
                    }
                )
            ).start()
        case .nyStyleSnow:
            SGSimpleSettings.shared.nyStyle = value ? SGSimpleSettings.NYStyle.snow.rawValue : SGSimpleSettings.NYStyle.default.rawValue
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
        case .nyStyleLightning:
            SGSimpleSettings.shared.nyStyle = value ? SGSimpleSettings.NYStyle.lightning.rawValue : SGSimpleSettings.NYStyle.default.rawValue
            simplePromise.set(true) // Trigger update for 'enabled' field of other toggles
        }
        // The retired NEW badge only disappears on an entries rebuild; not every branch above
        // pings simplePromise, so force one (duplicate emissions are deduped by entry equality).
        simplePromise.set(true)
    }, updateSliderValue: { setting, value in
        switch (setting) {
            case .accountColorsSaturation:
                if SGSimpleSettings.shared.accountColorsSaturation != value {
                    SGSimpleSettings.shared.accountColorsSaturation = value
                    simplePromise.set(true)
                }
            case .outgoingPhotoQuality:
                if SGSimpleSettings.shared.outgoingPhotoQuality != value {
                    SGSimpleSettings.shared.outgoingPhotoQuality = value
                    simplePromise.set(true)
                }
            case .stickerSize:
                if SGSimpleSettings.shared.stickerSize != value {
                    SGSimpleSettings.shared.stickerSize = value
                    simplePromise.set(true)
                }
        }

    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        
        switch (setting) {
            case .downloadSpeedBoost:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.downloadSpeedBoost = value
                    
                    let enableDownloadX: Bool
                    switch (value) {
                        case SGSimpleSettings.DownloadSpeedBoostValues.none.rawValue:
                            enableDownloadX = false
                        default:
                            enableDownloadX = true
                    }
                    
                    // Updating controller
                    simplePromise.set(true)

                    let _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { settings in
                        var settings = settings
                        settings.useExperimentalDownload = enableDownloadX
                        return settings
                    }).start(completed: {
                        Queue.mainQueue().async {
                            askForRestart?()
                        }
                    })
                }

                for value in SGSimpleSettings.DownloadSpeedBoostValues.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("Settings.DownloadsBoost.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .bottomTabStyle:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.bottomTabStyle = value
                    simplePromise.set(true)
                }

                for value in SGSimpleSettings.BottomTabStyleValues.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("Settings.Folders.BottomTabStyle.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .allChatsTitleLengthOverride:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.allChatsTitleLengthOverride = value
                    simplePromise.set(true)
                }

                for value in SGSimpleSettings.AllChatsTitleLengthOverride.allCases {
                    let title: String
                    switch (value) {
                        case SGSimpleSettings.AllChatsTitleLengthOverride.short:
                            title = "\"\(presentationData.strings.ChatList_Tabs_All)\""
                        case SGSimpleSettings.AllChatsTitleLengthOverride.long:
                            title = "\"\(presentationData.strings.ChatList_Tabs_AllChats)\""
                        default:
                            title = i18n("Settings.Folders.AllChatsTitle.none", presentationData.strings.baseLanguageCode)
                    }
                    items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
//        case .allChatsFolderPositionOverride:
//            let setAction: (String) -> Void = { value in
//                SGSimpleSettings.shared.allChatsFolderPositionOverride = value
//                simplePromise.set(true)
//            }
//
//            for value in SGSimpleSettings.AllChatsFolderPositionOverride.allCases {
//                items.append(ActionSheetButtonItem(title: i18n("Settings.Folders.AllChatsTitle.\(value)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
//                    actionSheet?.dismissAnimated()
//                    setAction(value.rawValue)
//                }))
//            }
            case .translationBackend:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.translationBackend = value
                    simplePromise.set(true)
                }

                for value in SGSimpleSettings.TranslationBackend.allCases {
                    if value == .system {
                        if #available(iOS 18.0, *) {
                        } else {
                            continue // System translation is not available on iOS 17 and below
                        }
                    }
                    items.append(ActionSheetButtonItem(title: i18n("Settings.Translation.Backend.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .transcriptionBackend:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.transcriptionBackend = value
                    simplePromise.set(true)
                }

                for value in SGSimpleSettings.TranscriptionBackend.allCases {
                    if #available(iOS 13.0, *) {
                    } else {
                        if value == .apple {
                            continue // Apple recognition is not available on iOS 12
                        }
                    }
                    items.append(ActionSheetButtonItem(title: i18n("Settings.Transcription.Backend.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        setAction(value.rawValue)
                    }))
                }
            case .nyStyle:
                let setAction: (String) -> Void = { value in
                    SGSimpleSettings.shared.nyStyle = value
                    simplePromise.set(true)
                }

                for value in SGSimpleSettings.NYStyle.allCases {
                    items.append(ActionSheetButtonItem(title: i18n("Settings.NY.Style.\(value.rawValue)", presentationData.strings.baseLanguageCode), color: .accent, action: { [weak actionSheet] in
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
        // MARK: Zenlygram — opening a disclosure retires its NEW badge (key == the case name used at the entry site).
        SGNewBadgeTracker.markInteracted(String(describing: link))
        // Rebuild while the pushed controller is up so the badge is gone when the user returns.
        simplePromise.set(true)
        switch (link) {
            // MARK: Zenlygram — the hub rows that open a page (settings IA). `markInteracted` above retires only
            // the page row's own (unread) key; the page's rows keep their badges until they are used.
            case .pageSecretVault, .pageHistory, .pageCallRecording, .pageChats, .pageMessages, .pageMessageMenu, .pageTabBar, .pagePrivacy, .pageTranslation, .pageMedia, .pageColors, .pageCallsAdvanced:
                if let page = link.page {
                    pushControllerImpl?(sgSettingsPageController(context: context, page: page, focus: nil))
                }
            case .languageSettings:
                pushControllerImpl?(context.sharedContext.makeLocalizationListController(context: context))
            case .contentSettings:
                let _ = (getSGSettingsURL(context: context) |> deliverOnMainQueue).start(next: { [weak context = context] url in
                    guard let strongContext = context else {
                        return
                    }
                    strongContext.sharedContext.applicationBindings.openUrl(url)
                })
            case .helperBots:
                pushControllerImpl?(sgHelperBotsController(context: context))
            case .tasks:
                // MARK: Zenlygram — opening Tasks is unrestricted, as are editing, completing,
                // deleting and Undo. Quick-add and new-list actions enforce the CREATE gate.
                pushControllerImpl?(tasksTabController(context: context))
            #if SG_LENTA
            case .lenta:
                // Zenlygram — always reachable; shows E41 when the server refused this account.
                pushControllerImpl?(lentaTabController(context: context))
            #endif
            case .chatLock:
                // Zenlygram — audit #71: while the Chat Lock credentials are gone (the row reads "Needs
                // setup"), a plain "set a master pincode" screen would leave every still-covered chat with a
                // per-chat pincode nobody can enter. The recovery sheet is the only flow that replaces them
                // all at once (or turns Chat Lock off).
                if ChatPincodeManager.shared.protectionRecoveryStatus().chatLockNeedsRecovery {
                    sgPresentProtectionRecovery(context: context, present: { c, a in presentControllerImpl?(c, a) }, push: { c in pushControllerImpl?(c) }, presentPincode: presentPincodeControllerImpl, refresh: { simplePromise.set(true) })
                    break
                }
                // MARK: Zenlygram — Chat Lock Center (wf14-chatlock spec §1 E1, §9): the row pushes the Chat
                // Lock screen. Arming, changing and turning off the master pincode, locking a chat and managing
                // its pincode all happen there through SGChatLockFlows — including Chat Lock's only CREATE gates
                // (a new per-chat code, the first master); change / remove / unlock / disable are never gated.
                // The row's "On"/"Off" is read from ChatPincodeManager while the list is built and nothing
                // else rebuilds it, so the screen reports every change back.
                pushControllerImpl?(sgChatLockController(context: context, onChanged: { simplePromise.set(true) }))
            case .protectionRecovery:
                // Zenlygram — audit #70/#71: everything the user can do about a protection whose credential
                // did not come along with a device migration lives here.
                sgPresentProtectionRecovery(context: context, present: { c, a in presentControllerImpl?(c, a) }, push: { c in pushControllerImpl?(c) }, presentPincode: presentPincodeControllerImpl, refresh: { simplePromise.set(true) })
            case .secretVaultChangePin:
                let changePresentationData = context.sharedContext.currentPresentationData.with { $0 }
                // Present the "set a new vault PIN" screen. Reached by verifying the current PIN, by the
                // screen's own recovery ladder (when the current PIN is forgotten), or straight away when
                // there is no current PIN to verify.
                let presentSetNewVaultPin: () -> Void = {
                    let setVC = ChatPincodeViewController(mode: .set(onSuccess: { code, passwordType, biometricEnabled in
                        ChatPincodeManager.shared.setVaultPincode(code, type: passwordType, biometricEnabled: biometricEnabled)
                    }), presentationData: changePresentationData)
                    let setNav = UINavigationController(rootViewController: setVC)
                    setNav.setNavigationBarHidden(true, animated: false)
                    setNav.modalPresentationStyle = .fullScreen
                    presentPincodeControllerImpl?(setNav)
                }
                // Zenlygram — audit #70/#41: a vault waiting for recovery has no PIN that could be verified,
                // so route to the recovery sheet instead of a screen nothing can satisfy.
                if ChatPincodeManager.shared.protectionRecoveryStatus().vaultNeedsRecovery {
                    sgPresentProtectionRecovery(context: context, present: { c, a in presentControllerImpl?(c, a) }, push: { c in pushControllerImpl?(c) }, presentPincode: presentPincodeControllerImpl, refresh: { simplePromise.set(true) })
                    break
                }
                switch ChatPincodeManager.shared.vaultCredentialHealth() {
                case .ready:
                    if ChatLockSession.shared.hasRecentVaultCredentialProof {
                        // Proven less than a minute ago (e.g. the switch above was just verified).
                        presentSetNewVaultPin()
                    } else {
                        // Audit #27/#90: `verifyVaultCredential` + the `.vault` scope, like every other
                        // vault check.
                        sgPresentVaultVerify(context: context, presentPincode: presentPincodeControllerImpl, onSuccess: {
                            presentSetNewVaultPin()
                        }, onForgot: {
                            presentSetNewVaultPin()
                        }, onCancel: {})
                    }
                case .absent:
                    // Reachable only where recovery detection is skipped (keychain-less DEBUG / simulator
                    // builds): there is nothing to verify, so go straight to setting a PIN.
                    presentSetNewVaultPin()
                case .unverifiable, .unreadable:
                    presentControllerImpl?(textAlertController(context: context, title: SGProtectionLocalCopy.vaultUnreadableTitle, text: SGProtectionLocalCopy.vaultUnreadableText, actions: [TextAlertAction(type: .defaultAction, title: changePresentationData.strings.Common_OK, action: {})]), nil)
                }
            // MARK: Zenlygram — the three subscription rows (design §8.3 item 20).
            case .proSubscription:
                let proPresentationData = context.sharedContext.currentPresentationData.with { $0 }
                pushControllerImpl?(sgEntitlementStatusController(
                    accountPeerId: context.account.peerId.toInt64(),
                    presentationData: proPresentationData,
                    // Night or day follows the app's theme while the screen is open, as the
                    // paywall's does.
                    updatedPresentationData: context.sharedContext.presentationData,
                    SGIAPManager: context.sharedContext.SGIAP,
                    openPayWall: {
                        // Presented, not pushed: the paywall is built as `.modal(animateIn: true)`
                        // and draws its own close button, so a navigation push would give it both a
                        // nav bar and an X.
                        if let payWallController = context.sharedContext.makeSGPayWallController(context: context) {
                            // Presented on the main window, not through `presentControllerImpl`: by
                            // the time this runs the status screen has been pushed over the Settings
                            // list, so the Settings controller that `presentControllerImpl` presents
                            // from is no longer in the window.
                            context.sharedContext.mainWindow?.present(payWallController, on: .root)
                        }
                    },
                    openLinkAccount: {
                        pushControllerImpl?(sgLinkTelegramAccountController(
                            accountPeerId: context.account.peerId.toInt64(),
                            // Read at tap time: the status screen follows the theme while it is
                            // open, so the value read when the row was tapped may be the old one.
                            presentationData: context.sharedContext.currentPresentationData.with { $0 },
                            telegram: sgLinkAccountTelegram(context: context),
                            // Same predicate as the section that led here (D1): the status screen is
                            // reachable while free only for a holder, for whom the Pro copy is true.
                            showsProSurfaces: context.sharedContext.sgProEntryIsVisible(context: context)
                        ))
                    },
                    openManageSubscription: {
                        // Apple's own subscription management, which Apple REQUIRES an auto-renewable
                        // to link to. It is the App Store, so it is not the external-purchase CTA that
                        // guideline 3.1.3(b) forbids.
                        context.sharedContext.applicationBindings.openUrl("https://apps.apple.com/account/subscriptions")
                    }
                ))
            case .proLinkAccount:
                // Linking a Telegram account is an IDENTITY step, never a purchase path: the app
                // obtains Telegram-signed Mini App data for this account silently, or the bot only
                // confirms the code (the client sends `src: "ios"`, which is what keeps price, plan
                // keyboard and Mini App button out of its reply). Nothing the user already saved
                // depends on the outcome.
                let linkPresentationData = context.sharedContext.currentPresentationData.with { $0 }
                pushControllerImpl?(sgLinkTelegramAccountController(
                    accountPeerId: context.account.peerId.toInt64(),
                    presentationData: linkPresentationData,
                    telegram: sgLinkAccountTelegram(context: context),
                    // The row lives under the neutral ACCOUNT & DATA header so a non-holder keeps it while
                    // the policy is free (D1); the screen's copy must then be identity-only too.
                    showsProSurfaces: context.sharedContext.sgProEntryIsVisible(context: context)
                ))
            case .proRestorePurchases:
                let restorePresentationData = context.sharedContext.currentPresentationData.with { $0 }
                let restoreLang = restorePresentationData.strings.baseLanguageCode
                guard let iap = context.sharedContext.SGIAP else {
                    presentControllerImpl?(UndoOverlayController(presentationData: restorePresentationData, content: .info(title: nil, text: SGEntitlementMessage.temporarilyUnavailable.localizationKey.i18n(restoreLang), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true }), nil)
                    break
                }
                let restoreToast: (String) -> Void = { text in
                    presentControllerImpl?(UndoOverlayController(presentationData: restorePresentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return true }), nil)
                }
                restoreToast(i18n("Settings.Pro.Restore.InProgress", restoreLang))
                // This screen's account, captured now: a transaction the restore finds for the first
                // time is attached for IT, whatever account is active by the time App Store answers.
                let restoreAccountPeerId = context.account.peerId.toInt64()
                Task { @MainActor in
                    // Restoring re-delivers the transactions and re-attaches them; the entitlement
                    // adopts whatever they prove. A restore that finds nothing is NOT an error and
                    // never says "expired" — the usual cause is a different Apple Account.
                    let outcome = await iap.restore(accountPeerId: restoreAccountPeerId)
                    SGEntitlement.shared.storeKitTransactionsDidChange()
                    simplePromise.set(true)
                    switch outcome {
                    case .restored:
                        SGAnalytics.record(.proRestore(rail: .apple, outcome: .restored, errorCode: nil), accountPeerId: restoreAccountPeerId)
                        restoreToast(i18n("Settings.Pro.Restore.Done", restoreLang))
                    case .nothingToRestore:
                        SGAnalytics.record(.proRestore(rail: .apple, outcome: .nothing, errorCode: nil), accountPeerId: restoreAccountPeerId)
                        restoreToast(i18n("Settings.Pro.Restore.NothingFound", restoreLang))
                    case .cancelled:
                        // The user dismissed the App Store password prompt. Say nothing (and no
                        // `pro.restore` event, design 40 §10.2).
                        break
                    case let .failed(message):
                        SGAnalytics.record(.proRestore(rail: .apple, outcome: .failed, errorCode: message == .noConnection ? .offline : nil), accountPeerId: restoreAccountPeerId)
                        restoreToast(message.localizationKey.i18n(restoreLang))
                    }
                }
            case .callRecordings:
                pushControllerImpl?(sgCallRecordingsController(context: context))
            case .dataConsent:
                // Zenlygram — design 40 §11.1/§11.2: this account's consent status, the text, My data,
                // withdrawal and deletion. The row exists only while the pipeline is active.
                guard SGCustomerSync.shared.isActive else {
                    break
                }
                pushControllerImpl?(SGCustomerSync.shared.dataAndConsentController(context: context))
            case .privacyPolicy:
                if let url = SGCustomerSync.shared.privacyPolicyURL {
                    context.sharedContext.applicationBindings.openUrl(url.absoluteString)
                }
            case .aiAssistantApiKey:
                let aiPresentationData = context.sharedContext.currentPresentationData.with { $0 }
                let aiLang = aiPresentationData.strings.baseLanguageCode
                presentAIAssistantApiKeyEntry(
                    title: i18n("Settings.AiAssistant.ApiKey", aiLang),
                    message: i18n("Settings.AiAssistant.Notice", aiLang),
                    saveTitle: i18n("Settings.AiAssistant.Save", aiLang),
                    clearTitle: i18n("Settings.AiAssistant.Clear", aiLang),
                    cancelTitle: i18n("Settings.AiAssistant.Cancel", aiLang),
                    errorTitle: i18n("AiAssistant.KeychainError.Title", aiLang),
                    saveErrorText: i18n("AiAssistant.KeychainError.Save", aiLang),
                    clearErrorText: i18n("AiAssistant.KeychainError.Clear", aiLang),
                    okTitle: aiPresentationData.strings.Common_OK
                )
        }
    }, searchInput: { searchQuery in
        updateState { state in
            var updatedState = state
            updatedState.searchQuery = searchQuery
            return updatedState
        }
    })
    
    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings])
    let preferences = context.account.postbox.preferencesView(keys: [PreferencesKeys.appConfiguration])
    let updatedContentSettingsConfiguration = contentSettingsConfiguration(network: context.account.network)
    |> map(Optional.init)
    let contentSettingsConfiguration = Promise<ContentSettingsConfiguration?>()
    contentSettingsConfiguration.set(.single(nil)
    |> then(updatedContentSettingsConfiguration))
    
    // Zenlygram — Data & privacy (design 40 §11.1): the consent row's value changes as soon as a
    // grant, withdrawal or remote change lands, or the entitlement (link state) changes. The same
    // rebuild shows or hides the ZENLYGRAM PRO section (`showsProSurfaces`): an adopted monetization
    // policy posts `SGEntitlement.didChangeNotification` even when the access decision stayed, and a
    // purchase or Restore that makes this account a holder posts `SGIAPStateDidChangeNotification`
    // (in free mode that is what brings the status screen back). The observers live exactly as long
    // as the list's state subscription, i.e. until the controller goes.
    let customerDataChanges: Signal<Void, NoError> = Signal { subscriber in
        subscriber.putNext(Void())
        let center = NotificationCenter.default
        let observers = [SGCustomerSync.consentSummaryDidChangeNotification, SGEntitlement.didChangeNotification, Notification.Name.SGIAPStateDidChangeNotification].map { name in
            return center.addObserver(forName: name, object: nil, queue: .main, using: { _ in
                subscriber.putNext(Void())
            })
        }
        return ActionDisposable {
            for observer in observers {
                center.removeObserver(observer)
            }
        }
    }

    let signal = combineLatest(simplePromise.get(), customerDataChanges, /*sliderPromise.get(),*/ statePromise.get(), context.sharedContext.presentationData, sharedData, preferences, contentSettingsConfiguration.get(),
        context.engine.accountData.observeAvailableColorOptions(scope: .replies),
        context.engine.accountData.observeAvailableColorOptions(scope: .profile)
    )
    |> map { _, _, /*sliderValue,*/ state, presentationData, sharedData, view, contentSettingsConfiguration, availableReplyColors, availableProfileColors ->  (ItemListControllerState, (ItemListNodeState, Any)) in
        
        let appConfiguration: AppConfiguration = view.values[PreferencesKeys.appConfiguration]?.get(AppConfiguration.self) ?? AppConfiguration.defaultValue
        let callListSettings: CallListSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings
        let experimentalUISettings: ExperimentalUISettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
        
        // Zenlygram — the same predicate as the main Settings row "Zenlygram Pro" (D1, 2026-11-11):
        // a cached, synchronous read, re-evaluated on every rebuild (`customerDataChanges`).
        let showsProSurfaces = context.sharedContext.sgProEntryIsVisible(context: context)
        // Read once per rebuild and shared by the hub and the twelve page arrays it builds for the NEW
        // roll-ups, so those add no extra keychain or disk reads (invariant I1).
        let inputs = SGEntryInputs(
            presentationData: presentationData,
            callListSettings: callListSettings,
            experimentalUISettings: experimentalUISettings,
            appConfiguration: appConfiguration,
            nameColors: PeerNameColors.with(availableReplyColors: availableReplyColors, availableProfileColors: availableProfileColors),
            state: state,
            accountPeerId: analyticsAccountPeerId,
            showsProSurfaces: showsProSurfaces,
            protectionStatus: ChatPincodeManager.shared.protectionRecoveryStatus(),
            chatLockArmed: ChatPincodeManager.shared.isMasterEnabled(),
            chatLockLegacy: !ChatPincodeManager.shared.lockedPeerIds().isEmpty,
            callRecordingVisible: sgCallRecordingAvailable || SGCallRecordingStore.shared.hasAnyFiles()
        )
        let entries = SGControllerEntries(screen: screen, inputs: inputs)

        // The hub keeps its literal name; a page is titled as its hub row is.
        let title: String
        switch screen {
        case .hub:
            title = "Zenlygram"
        case let .page(page):
            title = i18n(page.titleKey, presentationData.strings.baseLanguageCode)
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))

        // Zenlygram — the focused row (§2.3): scrolled to the top on the first state only
        // (`initialScrollToItem`, ItemListControllerNode), kept visible by its tag, and flashed once by
        // `afterTransactionCompleted` below. A key no built row carries — hidden in this state, or unknown —
        // finds no index: the plain screen, no error. Sliders have a tag key but their item takes no tag, so
        // they scroll into place without the flash.
        var scrollToItem: ListViewScrollToItem?
        if let localFocusKey = localFocusKey, let index = entries.firstIndex(where: { $0.tagKey == localFocusKey }) {
            scrollToItem = ListViewScrollToItem(index: index, position: .top(0.0), animated: false, curve: .Default(duration: 0.0), directionHint: .Up)
        }

        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: localFocusKey.map { SGItemListRowTag(key: $0) }, initialScrollToItem: scrollToItem)
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { firstTime in
        // Zenlygram — analytics `screen.view` on every appearance (design 40 §10.2): `zg.hub`,
        // `edit_history.settings` for the Deleted & Edited Messages page, `zg.preferences` for every other
        // page. Destination screens keep their own names.
        SGAnalytics.screen(screen.analyticsScreen, accountPeerId: analyticsAccountPeerId)
        // Coming back from a page or a modal re-reads SGSimpleSettings, ChatPincodeManager and the NEW-badge
        // tracker: values and the hub's roll-up pills refresh without reopening Settings.
        simplePromise.set(true)
        // A page-row focus given to the hub: the hub shows first, then the page slides in with its row
        // scrolled and flashed (§2.3 b). Once, on the first appearance only.
        if firstTime, case .hub = screen, let focus = focus, let page = SGSettingsCatalog.page(containing: focus.rawValue) {
            pushControllerImpl?(sgSettingsPageController(context: context, page: page, focus: focus))
        }
    }
    // Zenlygram — the focus flash (the NotificationsPeerCategoryController recipe): the first transaction
    // whose item nodes include the focused row highlights it, once.
    if let localFocusKey = localFocusKey {
        let focusTag = SGItemListRowTag(key: localFocusKey)
        var didFocusOnItem = false
        controller.afterTransactionCompleted = { [weak controller] in
            if !didFocusOnItem, let controller = controller {
                controller.forEachItemNode { itemNode in
                    if let itemNode = itemNode as? ItemListItemNode, let tag = itemNode.tag, tag.isEqual(to: focusTag) {
                        didFocusOnItem = true
                        itemNode.displayHighlight()
                    }
                }
            }
        }
    }
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentPincodeControllerImpl = { [weak controller] navVC in
        controller?.view.window?.rootViewController?.present(navVC, animated: true)
    }
//    getRootControllerImpl = { [weak controller] in
//        return controller?.view.window?.rootViewController
//    }
//    getNavigationControllerImpl = { [weak controller] in
//        return controller?.navigationController as? NavigationController
//    }
    askForRestart = { [weak context] in
        guard let context = context else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(
            UndoOverlayController(
                presentationData: presentationData, 
                content: .info(title: nil, // i18n("Common.RestartRequired", presentationData.strings.baseLanguageCode),
                    text: i18n("Common.RestartRequired", presentationData.strings.baseLanguageCode),
                    timeout: nil,
                    customUndoText: i18n("Common.RestartNow", presentationData.strings.baseLanguageCode) //presentationData.strings.Common_Yes
                ),
                elevatedLayout: false,
                action: { action in if action == .undo { exit(0) }; return true }
            ),
            nil
        )
    }
    return controller

}

/// Settings → Zenlygram: the hub. `focus` names a row to scroll to and flash — a hub row directly, a page row
/// by opening its page first (§2.3); a key that is hidden in the current state, or unknown, lands on the
/// plain hub.
public func sgSettingsController(context: AccountContext, focus: SGSettingsFocus? = nil) -> ViewController {
    return makeSGSettingsScreen(context: context, screen: .hub, focus: focus)
}

/// `sgSettingsController(context:focus:)` by raw row key — the `?row=` query of `tg://sg/settings` — so a
/// caller needs no SGSettingsCatalog import.
public func sgSettingsController(context: AccountContext, focusRowKey: String?) -> ViewController {
    return sgSettingsController(context: context, focus: focusRowKey.map { SGSettingsFocus(rawValue: $0) })
}

/// One page of the hub, pushed by its hub row (or by the hub itself for a page-row focus).
func sgSettingsPageController(context: AccountContext, page: SGSettingsPage, focus: SGSettingsFocus?) -> ViewController {
    return makeSGSettingsScreen(context: context, screen: .page(page), focus: focus)
}

#if DEBUG
/// Ties the data-only `SGSettingsCatalog` to the real builder, once per process, on the hub's first
/// (non-search) build: every row the builder emits is in the catalog; every catalog row this build omits is
/// one the catalog declares gated; every page emits only its own rows (plus the shared recovery row); and
/// every page row's link case prints as the page's `hubRowKey`. The two Lenta rows are compiled behind the
/// flag and are never in the catalog. If it trips, fix the catalog or the builder — never the assert.
private let sgSettingsCatalogGuardDidRun = Atomic<Bool>(value: false)

private func sgAssertCatalogMatchesBuilder(hub: [SGControllerEntry], pages: [[SGControllerEntry]]) {
    guard !sgSettingsCatalogGuardDidRun.swap(true) else {
        return
    }
    let lentaRowKeys: Set<String>
    #if SG_LENTA
    lentaRowKeys = ["lenta", "showLentaTab"]
    #else
    lentaRowKeys = []
    #endif
    var built = Set(hub.compactMap { $0.tagKey })
    for page in pages {
        built.formUnion(page.compactMap { $0.tagKey })
    }
    built.subtract(lentaRowKeys)
    let catalog = Set(SGSettingsCatalog.allRowKeys)
    assert(built.isSubset(of: catalog), "Settings rows the catalog does not list: \(built.subtracting(catalog).sorted())")
    let omitted = catalog.subtracting(built)
    assert(omitted.isSubset(of: SGSettingsCatalog.gatedRowKeys), "Catalog rows this build never emits and the catalog does not declare gated: \(omitted.subtracting(SGSettingsCatalog.gatedRowKeys).sorted())")
    for page in SGSettingsPage.allCases {
        let pageBuilt = Set(pages[page.index].compactMap { $0.tagKey }).subtracting(lentaRowKeys)
        let allowed = Set(SGSettingsCatalog.rowKeys(on: page)).union(SGSettingsCatalog.sharedRowKeys)
        assert(pageBuilt.isSubset(of: allowed), "Rows built on the \(page.rawValue) page that the catalog places elsewhere: \(pageBuilt.subtracting(allowed).sorted())")
        assert(SGDisclosureLink(page: page).rawValue == page.hubRowKey, "The \(page.rawValue) page's hub row prints as \(SGDisclosureLink(page: page).rawValue); the catalog expects \(page.hubRowKey)")
    }
}
#endif
