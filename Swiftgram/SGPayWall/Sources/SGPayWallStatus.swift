import Foundation
import SwiftUI
import UIKit
import Display
import LegacyUI
import TelegramPresentationData
import SGEntitlement
import SGIAP
import SGStrings
import SGSwiftUI
import SwiftSignalKit

// MARK: Zenlygram — what the subscription sells, and what a lapse does NOT take away.
//
// The lapse policy is the owner's, and it is the whole reason this file exists: the user's OWN
// protected data stays fully accessible — open, unhide, unlock, read, delete — forever, offline,
// with the server unreachable and with no subscription at all — and so does reading or removing
// message history Edit History already retained. A subscription gates one thing only, and only in
// paid mode: CREATING new material — new protected items, and new history capture (what someone
// else deletes or edits from now on). A lapse stops new capture; it never deletes or hides what was
// already kept. Free mode has no countdown; the existing first-launch grace is only a fallback after
// the owner enables paid mode.
//
// That promise is worthless if the user does not know about it. A lapsed user who opens the app,
// finds a locked vault and assumes their chats are gone writes a support ticket and a one-star
// review in the same minute, so the copy below is part of the product, not decoration.

/// The four features Zenlygram Pro sells today. The AI Assistant is deliberately absent: this build
/// refuses it (`SGEntitlementCapability.refusedByThisBuild`), and advertising it would sell
/// something the subscription does not deliver.
enum SGProFeatureId: String, Hashable, CaseIterable {
    case vault
    case chatLock
    case tasks
    case editHistory
}

struct SGProFeature: Identifiable {
    let id: SGProFeatureId
    let title: String
    let subtitle: String
    let description: String

    /// The same symbol and colour the feature's own row in Zenlygram Settings uses, so the paywall
    /// looks like the app rather than like an ad for it.
    var iconName: String {
        switch self.id {
        case .vault:
            return "eye.slash.fill"
        case .chatLock:
            return "lock.shield.fill"
        case .tasks:
            return "checklist"
        case .editHistory:
            return "clock.arrow.circlepath"
        }
    }

    var iconColor: Color {
        switch self.id {
        case .vault:
            return .purple
        case .chatLock:
            return .blue
        case .tasks:
            return .blue
        case .editHistory:
            return Color(hex: "30B0C7")
        }
    }
}

func sgProFeatures(lang: String) -> [SGProFeature] {
    return [
        SGProFeature(
            id: .vault,
            title: "PayWall.Vault.Title".i18n(lang),
            subtitle: "PayWall.Vault.Notice".i18n(lang),
            description: "PayWall.Vault.Description".i18n(lang)
        ),
        SGProFeature(
            id: .chatLock,
            title: "PayWall.ChatLock.Title".i18n(lang),
            subtitle: "PayWall.ChatLock.Notice".i18n(lang),
            description: "PayWall.ChatLock.Description".i18n(lang)
        ),
        SGProFeature(
            id: .tasks,
            title: "PayWall.Tasks.Title".i18n(lang),
            subtitle: "PayWall.Tasks.Notice".i18n(lang),
            description: "PayWall.Tasks.Description".i18n(lang)
        ),
        SGProFeature(
            id: .editHistory,
            title: "PayWall.EditHistory.Title".i18n(lang),
            subtitle: "PayWall.EditHistory.Notice".i18n(lang),
            description: "PayWall.EditHistory.Description".i18n(lang)
        )
    ]
}

// MARK: - The monetization mode

/// The signed monetization policy's mode as the Foundation-only rules see it. Synchronous, from the
/// cached and re-verified policy (`SGEntitlement.monetizationMode`), never a network call. Public
/// because `SharedAccountContext` feeds it to `sgProEntryDestination` / `sgProSurfacesVisible` for
/// the Settings row, the deep link and the ZENLYGRAM PRO section.
public func sgPayWallMonetization() -> SGProMonetization {
    return SGEntitlement.shared.offersNewSubscriptions ? .paid : .free
}

/// Whether Pro is free for everyone right now — what the Settings row says instead of a subscription
/// state or a countdown.
public var sgPayWallIsFreeAccess: Bool {
    return SGEntitlement.shared.source == .freeAccess
}

// MARK: - The local grace

/// The formatted end of the local grace — "Free until <date>" — when the grace is what currently
/// grants; nil otherwise (a token or a purchase in front of it, the window over, a signed length
/// of 0 days — `local_grace_days`, under which the grace never grants — an unconfigured build, or
/// the monetization policy free, which never counts down). The date is the window's end at the
/// length the accepted signed policy names, so it moves when a new policy is adopted (every
/// adoption posts `SGEntitlementDidChange`, on which the paywall, the status screen and the
/// Settings row re-read it). Read from the already-cached decision, synchronously, never from a
/// network call. Shared with the Settings row.
public func sgPayWallGraceUntilText(lang: String) -> String? {
    guard SGEntitlement.shared.source == .localGrace, let endsAt = SGEntitlement.shared.localGraceEndsAt else {
        return nil
    }
    return sgPayWallGraceDateFormatter(for: lang).string(from: endsAt)
}

private let _graceDateFormatterLock = NSLock()
private var _graceDateFormatterCache: [String: DateFormatter] = [:]
private func sgPayWallGraceDateFormatter(for lang: String) -> DateFormatter {
    _graceDateFormatterLock.lock()
    defer { _graceDateFormatterLock.unlock() }
    if let cached = _graceDateFormatterCache[lang] { return cached }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    formatter.locale = Locale(identifier: lang)
    _graceDateFormatterCache[lang] = formatter
    return formatter
}

/// A date in the user's selected app language, from the same cached formatter as the grace line.
func sgPayWallDateText(_ date: Date, lang: String) -> String {
    return sgPayWallGraceDateFormatter(for: lang).string(from: date)
}

/// One line for the paywall and the status screen while the grace grants: what is free, until when,
/// and that a subscription is what continues it — an App Store subscription, nothing else.
struct SGPayWallGraceNotice: View {
    let lang: String
    let untilText: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gift.fill")
                .font(.headline)
                .foregroundColor(sgPayWallAccentText)
                .frame(minWidth: 24)
                .accessibility(hidden: true)
            Text("PayWall.Grace.Notice".i18n(lang, args: untilText))
                .font(.footnote)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .sgPayWallGrouped()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Degraded mode

/// One line at the top of a degraded paywall: what happened, and the reassurance in the same breath.
///
/// The reason picks the sentence; nothing else about the rendering changes. A 5xx or a timeout is
/// "reconnect", never "your subscription ended" — the client contract is explicit that no transport
/// outcome may ever read as a lapse.
struct SGEntitlementLapseNotice: View {
    let lang: String
    let reason: SGEntitlementDegradedReason
    let message: SGEntitlementMessage

    var body: some View {
        // A lapse needs the user's attention; every other degraded reason is a reconnect, which the
        // app retries on its own. Different symbols, and the words say which.
        SGPayWallNoticeView(notice: SGPayWallNotice(
            text: message.localizationKey.i18n(lang),
            detail: "PayWall.Degraded.Reassurance".i18n(lang),
            tone: reason == .lapsed ? .warning : .info
        ))
    }
}

/// The long form: the two lists that answer "what did I just lose?" with "nothing you already have".
struct SGEntitlementLapseExplanation: View {
    @Environment(\.sgPayWallSecondaryText) private var secondaryText: Color

    let lang: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            listSection(
                title: "PayWall.Degraded.StillWorks.Title".i18n(lang),
                symbol: "checkmark.circle.fill",
                color: Color(.systemGreen),
                rows: [
                    "PayWall.Degraded.StillWorks.Vault".i18n(lang),
                    "PayWall.Degraded.StillWorks.ChatLock".i18n(lang),
                    "PayWall.Degraded.StillWorks.Tasks".i18n(lang),
                    "PayWall.Degraded.StillWorks.EditHistory".i18n(lang)
                ]
            )

            listSection(
                title: "PayWall.Degraded.Blocked.Title".i18n(lang),
                symbol: "lock.fill",
                color: .secondary,
                rows: [
                    "PayWall.Degraded.Blocked.Vault".i18n(lang),
                    "PayWall.Degraded.Blocked.ChatLock".i18n(lang),
                    "PayWall.Degraded.Blocked.Tasks".i18n(lang),
                    "PayWall.Degraded.Blocked.EditHistory".i18n(lang)
                ]
            )

            Text("PayWall.Degraded.Nothing".i18n(lang))
                .font(.footnote)
                .foregroundColor(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// One list per card: a heading, then rows whose symbol SHAPE (a check, a lock) carries the
    /// meaning the colour only repeats.
    private func listSection(title: String, symbol: String, color: Color, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SGPayWallSectionHeader(title: title)
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .font(Font.footnote.weight(.semibold))
                        .foregroundColor(color)
                        .frame(minWidth: 18)
                        .accessibility(hidden: true)
                    Text(row)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sgPayWallGrouped()
    }
}

// MARK: - The Settings row "Zenlygram Pro"

/// Does Settings ▸ Zenlygram Pro open the status screen rather than the paywall?
///
/// Whoever has nothing to manage gets the paywall: free access, the local grace, a lapsed or
/// never-bought subscription. Someone who already HOLDS Pro gets the status screen. That is a
/// verified grant (bought under another Apple ID and linked, a VIP grant, a server trial) or an App
/// Store purchase StoreKit verified. So does someone Apple is billing on this Apple ID, billing
/// retry included. The status screen says what they have and links Apple's management page, where
/// the paywall would only offer them a second subscription. While the policy is free, an account
/// with a genuine grant horizon of its own also gets it, because only the status screen quotes that
/// horizon. A build that cannot enforce (`.unconfigured`) holds nothing and gets the paywall.
///
/// Also the `holdsPro` of `sgProSurfacesVisible`, so it runs on the main thread on every Settings
/// rebuild and every entitlement / StoreKit change: everything it reads is cached — the decision,
/// the policy mode, StoreKit's last answer, and the grant horizon through
/// `SGEntitlement.cachedGrantUntil`, never a Keychain read or a signature check of its own.
public func sgProSettingsRowOpensStatus(accountPeerId: Int64, SGIAPManager: SGIAPManager?) -> Bool {
    let entitlement = SGEntitlement.shared
    switch entitlement.source {
    case .token, .storeKit:
        if entitlement.state.isUnlocked {
            return true
        }
    case .none, .unconfigured, .localGrace, .freeAccess:
        break
    }
    let now = entitlement.entitlementClock.effectiveNow()
    if let status = SGIAPManager?.subscriptionStatus {
        if status.isActive || status.state == .inBillingRetry {
            return true
        }
    } else if let snapshot = entitlement.manageableStoreKitSnapshot, snapshot.hasActiveSubscription {
        // No StoreKit answer (always so while free): the snapshot up to its effective expiry, the
        // same evidence the paywall uses to offer Apple's management page.
        if snapshot.effectiveExpirationDate.map({ now < $0 }) ?? true {
            return true
        }
    }
    if !entitlement.offersNewSubscriptions, let until = entitlement.cachedGrantUntil(accountPeerId: accountPeerId), now < until {
        return true
    }
    return false
}

// MARK: - The standalone status screen (rendered by `SGEntitlementStatusView`, SGPayWallStatusScreen.swift)

public func sgEntitlementStatusController(
    accountPeerId: Int64?,
    presentationData: PresentationData? = nil,
    updatedPresentationData: Signal<PresentationData, NoError>? = nil,
    SGIAPManager: SGIAPManager?,
    openPayWall: (() -> Void)? = nil,
    openLinkAccount: (() -> Void)? = nil,
    openManageSubscription: (() -> Void)? = nil
) -> ViewController {
    // Drawn as the paywall is, and night or day by the paywall's rule: the app's theme, followed
    // while the screen is open (`sgPayWallController`). The theme follows the device's appearance
    // unless the user picked one.
    let isDark = presentationData?.theme.overallDarkAppearance ?? (UITraitCollection.current.userInterfaceStyle == .dark)
    let theme = presentationData?.theme ?? (isDark ? defaultDarkColorPresentationTheme : defaultPresentationTheme)
    let strings = presentationData?.strings ?? defaultPresentationStrings
    let appearance = SGPayWallAppearance(isDark: isDark)

    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: theme,
        strings: strings
    )
    legacyController.statusBar.statusBarStyle = isDark ? .White : .Black
    legacyController.title = "Zenlygram Pro"
    // The design draws its own round back button, as the pushed paywall does, so the navigation bar
    // stays hidden; the back swipe still pops the screen.
    legacyController.displayNavigationBar = false
    if let updatedPresentationData {
        legacyController.disposables.add((updatedPresentationData
        |> map { presentationData -> Bool in
            return presentationData.theme.overallDarkAppearance
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak legacyController] isDark in
            appearance.isDark = isDark
            legacyController?.statusBar.statusBarStyle = isDark ? .White : .Black
        }))
    }

    let swiftUIView = SGSwiftUIView<SGEntitlementStatusScreen>(
        legacyController: legacyController,
        content: {
            SGEntitlementStatusScreen(
                wrapperController: legacyController,
                appearance: appearance,
                backTitle: strings.Common_Back,
                status: SGEntitlementStatusView(
                    SGIAP: SGIAPManager,
                    accountPeerId: accountPeerId,
                    openPayWall: openPayWall,
                    openLinkAccount: openLinkAccount,
                    openManageSubscription: openManageSubscription
                )
            )
        }
    )
    let controller = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: controller)

    return legacyController
}

/// The live status screen as Settings pushes it: the status view in the app's night or day, with
/// the paywall's round back button over its top-leading corner in place of a navigation bar.
struct SGEntitlementStatusScreen: View {
    @Environment(\.containerViewLayout) private var containerViewLayout: ContainerViewLayout?

    weak var wrapperController: LegacyController?
    @ObservedObject var appearance: SGPayWallAppearance
    /// The app's own "Back", for VoiceOver.
    let backTitle: String
    let status: SGEntitlementStatusView

    var body: some View {
        status
            .overlay(backButton)
            // Every colour on the screen follows this: the design's own through `SGPayWallPalette`,
            // the system ones (notices, rows, secondary text) by themselves.
            .colorScheme(appearance.isDark ? .dark : .light)
    }

    /// Pops the screen: `dismiss(animated:)` on a controller in a navigation stack goes back.
    private var backButton: some View {
        Button(action: {
            wrapperController?.dismiss(animated: true)
        }) {
            SGPayWallBackGlyph()
        }
        .accessibility(label: Text(backTitle))
        .padding(.top, max(16.0, sgPayWallChromeTopInset(containerViewLayout)))
        .padding(.leading, max(16.0, sgLeftSafeAreaInset(containerViewLayout)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
