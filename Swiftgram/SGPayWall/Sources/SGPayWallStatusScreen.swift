import Foundation
import SwiftUI
import UIKit
import Display
import SGCustomerSyncCore
import SGEntitlement
import SGIAP
import SGStrings
import SGSwiftUI

// MARK: Zenlygram — the "Zenlygram Pro" status screen.
//
// Split in two on purpose. `SGEntitlementStatusContent` renders decided values
// (`SGProStatusScreen`, SGPayWallStatusRules.swift) and reads no singleton, so the live screen and
// the test-only preview host (`PreviewHost/`) run the same renderer. `SGEntitlementStatusView`
// is the live container: it reads `SGEntitlement` / `SGIAP`, guards the screen's account and runs
// the real Restore.
//
// It is drawn as the paywall is (`SGPayWallDesign.swift`): the same sky, the same hero, the same
// glass cards, night or day from the colour scheme it is given. The live screen gives it the app's
// theme (`SGEntitlementStatusScreen`, SGPayWallStatus.swift); the preview host, the system's.

/// What the status screen's buttons do. Every closure is owned by the container, which re-checks the
/// screen's account before acting; the content only renders and forwards taps.
struct SGEntitlementStatusActions {
    var openPayWall: (() -> Void)?
    var restore: () -> Void
    var openLinkAccount: (() -> Void)?
    var openManageSubscription: (() -> Void)?
}

/// No external purchase call to action of any kind lives here — the only buy button in the app is
/// the paywall's, and the only link that leaves is Apple's own subscription management page
/// (guideline 3.1.3(b)). ACCESS and PAYMENT are separate lines: the pill says whether Pro works
/// here and until when; only the App Store line, built from StoreKit's own evidence, talks about a
/// purchase.
struct SGEntitlementStatusContent: View {
    @Environment(\.lang) var lang: String
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.sizeCategory) private var sizeCategory: ContentSizeCategory
    /// The live screen's container layout; nil in the preview host, where the system insets.
    @Environment(\.containerViewLayout) private var containerViewLayout: ContainerViewLayout?

    let screen: SGProStatusScreen
    /// The active account's degraded reason and its copy; nil when unlocked or for another account.
    let degradedReason: SGEntitlementDegradedReason?
    let degradedMessage: SGEntitlementMessage?
    let actions: SGEntitlementStatusActions
    /// The build links accounts automatically after consent (`sgPayWallConsentRequired`): the Link
    /// row's detail says so instead of "optional".
    var consentRequired: Bool = false

    var body: some View {
        let palette = SGPayWallPalette(self.colorScheme)
        return ZStack {
            // The paywall's sky: near-black with a violet nebula and stars at night, pale
            // violet-white by day. Every card on it is opaque enough to read on its own.
            SGPayWallCosmicBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    hero

                    statusSections
                }
                // The hero shares its top line with the live screen's back button, clear of the
                // status bar; the end of the list clears the home indicator. The side margins are
                // inside the scroll view, which spans the whole width: it clips what it scrolls, and
                // the button's glow and the day cards' shadows reach past the margins.
                .padding(.top, max(16.0, sgPayWallChromeTopInset(containerViewLayout)))
                .padding(.bottom, 24.0 + sgBottomSafeAreaInset(containerViewLayout))
                .padding(.leading, max(16.0, sgLeftSafeAreaInset(containerViewLayout)))
                .padding(.trailing, max(16.0, sgRightSafeAreaInset(containerViewLayout)))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // By day the system's secondary grey sits poorly on the pale sky, so secondary text takes the
        // day ink, as on the paywall. Every block is one of the design's cards, night and day: here
        // the notices and the two lists are most of the screen, and the system's grey beside the
        // dark glass of the account rows read as a different screen.
        .environment(\.sgPayWallSecondaryText, palette.secondaryText)
        .environment(\.sgPayWallGroupedCard, true)
    }

    /// The accessibility text sizes. An explicit list: `isAccessibilityCategory` is iOS 13.4+.
    private var usesAccessibilitySize: Bool {
        return [
            ContentSizeCategory.accessibilityMedium,
            .accessibilityLarge,
            .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge,
            .accessibilityExtraExtraExtraLarge
        ].contains(self.sizeCategory)
    }

    /// The paywall's hero without the offer: the glowing Z mark, "Zenlygram Pro" with its gradient
    /// "Pro", and where Pro stands, in the pill under it.
    private var hero: some View {
        VStack(spacing: 14) {
            SGPayWallHeroMark()
            SGPayWallHeroTitle()
            SGPayWallStatusPill(symbol: accessSymbol, text: accessLine, tint: accessTint)
        }
        .frame(maxWidth: .infinity)
    }

    /// Everything under the hero, in the order it always had: the notices, the App Store line, the
    /// way into the plans, the account rows, Restore's result and what a lapse does not take away.
    @ViewBuilder
    private var statusSections: some View {
        if screen.access == .otherAccount {
            SGPayWallNoticeView(notice: SGPayWallNotice(text: "Entitlement.Status.OtherAccount.Notice".i18n(lang), tone: .info))
        }

        // `.noToken` is skipped, exactly as the paywall and the gate's toast skip it: a user who
        // never subscribed needs the offer, not "link your Telegram account" (linking is optional
        // and buying works without it) and certainly not "nothing was deleted, un-hidden or
        // unlocked", which is about material they never had.
        if let reason = degradedReason, let message = degradedMessage, reason != .noToken {
            SGEntitlementLapseNotice(lang: lang, reason: reason, message: message)
        }

        // Inside the paid-mode local grace: say so, and say when it ends.
        if let graceEndsAt = screen.graceEndsAt {
            SGPayWallGraceNotice(lang: lang, untilText: sgPayWallDateText(graceEndsAt, lang: lang))
        }

        // Free for everyone: say what that means; the account's own genuine horizon, when it has
        // one, as a secondary fact; and about an existing App Store subscription only what StoreKit
        // supports — "renews until cancelled" only when Apple says so.
        if screen.access == .freeAccess {
            SGPayWallNoticeView(notice: SGPayWallNotice(text: "Entitlement.Status.FreeAccess.Notice".i18n(lang), tone: .info))
            if let until = screen.accountAccessUntil {
                SGPayWallNoticeView(notice: SGPayWallNotice(text: "Entitlement.Status.FreeAccess.AccountUntil".i18n(lang, args: sgPayWallDateText(until, lang: lang)), tone: .info))
            }
            switch screen.existingSubscriptionNotice {
            case .renewsUntilCancelled:
                SGPayWallNoticeView(notice: SGPayWallNotice(text: "Entitlement.Status.FreeAccess.ExistingSubscription".i18n(lang), tone: .info))
            case .managedByApple:
                SGPayWallNoticeView(notice: SGPayWallNotice(text: "Entitlement.Status.FreeAccess.ManagedByApple".i18n(lang), tone: .info))
            case nil:
                EmptyView()
            }
        }

        if let plan = screen.plan {
            SGEntitlementPlanLine(text: planLine(plan), symbol: planSymbol(plan), tint: plan == .billingRetry ? Color(.systemOrange) : sgPayWallAccentText)
        }

        // The ONLY way into the paywall's purchase options, so it is shown whenever the screen may
        // act AND paid mode sells anything — unlocked access is not a subscription (the grace, an
        // unenforced build, a server horizon that is a trial or a grant). "View Plans" only when
        // StoreKit shows a subscription to switch. Never while free: there is nothing new to buy.
        // The paywall's own button, since that is where it leads. At the accessibility text sizes
        // the Z tile and the arrow give their width to the title, which otherwise breaks mid-word
        // and is cut ("Оформи / ть подп…" on a 375 pt phone).
        if screen.offersPurchaseEntry, let openPayWall = actions.openPayWall {
            Button(action: openPayWall) {
                SGPayWallCosmicButtonLabel(
                    title: (screen.offersPlansAsSwitch ? "Entitlement.Status.ViewPlans" : "Entitlement.Status.Subscribe").i18n(lang),
                    showsArrow: !usesAccessibilitySize,
                    showsMark: !usesAccessibilitySize
                )
            }
        }

        if screen.showsActions, hasAccountActions {
            accountActions
        }

        if let notice = sgProStatusRestoreNotice(screen.restorePhase) {
            SGPayWallNoticeView(notice: SGPayWallNotice(text: notice.key.i18n(lang), tone: SGPayWallNoticeTone(notice.kind)))
        }

        SGEntitlementLapseExplanation(lang: lang)
    }

    /// The card is drawn only when it has a row: with the Apple backend held (no Restore, no Manage
    /// Subscription) and no Link action there would be an empty card.
    private var hasAccountActions: Bool {
        return screen.showsRestore || actions.openLinkAccount != nil || (screen.showsManageSubscription && actions.openManageSubscription != nil)
    }

    /// Restore and Apple's subscription management (both only in a build that sells through Apple)
    /// and the optional Telegram link, as one glass card, as on the paywall. Every row is at least
    /// 52 pt tall (`SGPayWallActionRow`). Nothing here is a second way to buy.
    private var accountActions: some View {
        VStack(spacing: 0) {
            if screen.showsRestore {
                SGPayWallActionRow(
                    symbol: "arrow.clockwise",
                    title: "PayWall.RestorePurchases".i18n(lang),
                    // While running the words say so too: the row's spinner is hidden from VoiceOver.
                    detail: (screen.restorePhase == .running ? "PayWall.Button.Restoring" : "Entitlement.Status.Restore.Detail").i18n(lang),
                    trailing: .none,
                    isBusy: screen.restorePhase == .running,
                    isEnabled: screen.isRestoreEnabled,
                    action: actions.restore
                )
            }
            if let openLinkAccount = actions.openLinkAccount {
                if screen.showsRestore {
                    SGPayWallRowDivider()
                }
                SGPayWallActionRow(
                    symbol: "link",
                    title: "LinkAccount.Title".i18n(lang),
                    detail: (screen.isLinked ? "Entitlement.Status.Linked" : SGPayWallFunnel.linkNoticeKey(consentRequired: consentRequired)).i18n(lang),
                    action: openLinkAccount
                )
            }
            if screen.showsManageSubscription, let openManageSubscription = actions.openManageSubscription {
                if screen.showsRestore || actions.openLinkAccount != nil {
                    SGPayWallRowDivider()
                }
                // Shown only on evidence of an App Store subscription (`showsManageSubscription`), so
                // the row never needs to say who it is for.
                SGPayWallActionRow(
                    symbol: "creditcard",
                    title: "PayWall.ManageSubscription".i18n(lang),
                    trailing: .external,
                    action: openManageSubscription
                )
            }
        }
        .sgPayWallGlassCard()
    }

    /// A different SHAPE per state, so the pill never says "available" by colour alone. iOS 13
    /// symbols only.
    private var accessSymbol: String {
        switch screen.access {
        case .otherAccount:
            return "person.crop.circle"
        case .freeUntil, .freeAccess:
            return "gift.fill"
        case .availableUntil, .available:
            return "checkmark.circle.fill"
        case .viaAppStore:
            return "checkmark.seal.fill"
        case .unlockedBuild:
            return "lock.open.fill"
        case .reconnect:
            return "exclamationmark.circle"
        case .lapsed, .notActive:
            return "minus.circle"
        }
    }

    private var accessTint: Color {
        switch screen.access {
        case .freeUntil, .freeAccess, .unlockedBuild:
            return sgPayWallAccentText
        case .availableUntil, .available, .viaAppStore:
            return Color(.systemGreen)
        case .reconnect:
            return Color(.systemOrange)
        case .otherAccount, .lapsed, .notActive:
            return .secondary
        }
    }

    private var accessLine: String {
        switch screen.access {
        case .otherAccount:
            return "Entitlement.Status.OtherAccount".i18n(lang)
        case let .freeUntil(date):
            return "Entitlement.Status.FreeUntil".i18n(lang, args: sgPayWallDateText(date, lang: lang))
        case .freeAccess:
            return "Entitlement.Status.FreeAccess".i18n(lang)
        case let .availableUntil(date):
            return "Entitlement.Status.AvailableUntil".i18n(lang, args: sgPayWallDateText(date, lang: lang))
        case .available:
            return "Entitlement.Status.Available".i18n(lang)
        case .viaAppStore:
            return "Entitlement.Status.ViaAppStore".i18n(lang)
        case .unlockedBuild:
            return "Entitlement.Status.UnlockedBuild".i18n(lang)
        case .reconnect:
            return "Entitlement.Status.Reconnect".i18n(lang)
        case .lapsed:
            return "Entitlement.Status.Lapsed".i18n(lang)
        case .notActive:
            return "Entitlement.Status.Inactive".i18n(lang)
        }
    }

    private func planLine(_ plan: SGProStatusPlan) -> String {
        switch plan {
        case let .renews(on: date?):
            return "Entitlement.Plan.RenewsOn".i18n(lang, args: sgPayWallDateText(date, lang: lang))
        case let .ends(on: date?):
            return "Entitlement.Plan.EndsOn".i18n(lang, args: sgPayWallDateText(date, lang: lang))
        case .renews(on: nil), .ends(on: nil), .active:
            return "Entitlement.Plan.Active".i18n(lang)
        case .billingRetry:
            return "Entitlement.Plan.BillingRetry".i18n(lang)
        case .none:
            return "Entitlement.Plan.None".i18n(lang)
        }
    }

    private func planSymbol(_ plan: SGProStatusPlan) -> String {
        switch plan {
        case .billingRetry:
            return "exclamationmark.triangle.fill"
        case .renews, .ends, .active, .none:
            return "creditcard"
        }
    }
}

/// Where a screen drawn edge to edge starts its top line — the round back button and the hero —
/// clear of the status bar / Dynamic Island. The hosting controller ignores the safe area so the
/// sky bleeds under the status bar, so the inset comes from the controller's own layout:
/// `statusBarHeight`, or `safeInsets` / `intrinsicInsets`, whichever is larger (the paywall's rule).
/// 0 without a layout (the preview host), where the system insets the content itself.
func sgPayWallChromeTopInset(_ layout: ContainerViewLayout?) -> CGFloat {
    guard let layout else {
        return 0.0
    }
    return max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top + layout.intrinsicInsets.top)
}

/// The App Store line: one symbol and the words StoreKit's evidence supports.
struct SGEntitlementPlanLine: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundColor(tint)
                .frame(minWidth: 24)
                .accessibility(hidden: true)
            Text(text)
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

extension SGPayWallNoticeTone {
    init(_ kind: SGProStatusNoticeKind) {
        switch kind {
        case .success:
            self = .success
        case .info:
            self = .info
        case .pending:
            self = .pending
        case .warning:
            self = .warning
        }
    }
}

// MARK: - The live container

/// Reads `SGEntitlement` / `SGIAP` into `SGProStatusInputs`, re-reads on every entitlement,
/// StoreKit or foreground change, and owns the one Restore this screen may run.
///
/// `accountPeerId` is the account the screen was built for; `SGEntitlement`'s decision is the
/// ACTIVE account's. When they diverge the content shows the other-account state and every action
/// is refused — at render time, again at tap time, and for a Restore result that comes back later.
struct SGEntitlementStatusView: View {
    @Environment(\.lang) var lang: String

    let SGIAP: SGIAPManager?
    let accountPeerId: Int64?
    let openPayWall: (() -> Void)?
    let openLinkAccount: (() -> Void)?
    let openManageSubscription: (() -> Void)?

    @State private var snapshot: SGEntitlementStatusSnapshot
    @State private var restoreFlow = SGProStatusRestoreFlow()
    @State private var consentRequired = false

    private let changePub = NotificationCenter.default.publisher(for: SGEntitlement.didChangeNotification, object: nil)
    private let iapPub = NotificationCenter.default.publisher(for: .SGIAPStateDidChangeNotification, object: nil)
    private let becameActivePub = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification, object: nil)

    init(SGIAP: SGIAPManager?, accountPeerId: Int64?, openPayWall: (() -> Void)?, openLinkAccount: (() -> Void)?, openManageSubscription: (() -> Void)?) {
        self.SGIAP = SGIAP
        self.accountPeerId = accountPeerId
        self.openPayWall = openPayWall
        self.openLinkAccount = openLinkAccount
        self.openManageSubscription = openManageSubscription
        self._snapshot = State(initialValue: SGEntitlementStatusSnapshot.read(accountPeerId: accountPeerId, SGIAP: SGIAP))
    }

    var body: some View {
        SGEntitlementStatusContent(
            // A held Apple backend hides the Apple rows altogether (`snapshot.inputs.isAppleBackendEnabled`);
            // a missing manager only disables Restore.
            screen: SGProStatusScreen(inputs: snapshot.inputs, restorePhase: restoreFlow.phase, isRestoreAvailable: SGIAP != nil),
            degradedReason: snapshot.degradedReason,
            degradedMessage: snapshot.degradedMessage,
            actions: SGEntitlementStatusActions(
                openPayWall: guarded(openPayWall.map { open -> (() -> Void) in
                    return {
                        // A deep-linked paywall (`.deeplink`, noted ≤ 10 s ago) keeps its source.
                        if SGAnalytics.peekPaywallEntry() == nil {
                            SGAnalytics.notePaywallEntry(.settings)
                        }
                        open()
                    }
                }),
                restore: startRestore,
                openLinkAccount: guarded(openLinkAccount),
                openManageSubscription: guarded(openManageSubscription)
            ),
            consentRequired: consentRequired
        )
        .onAppear {
            reload()
            consentRequired = sgPayWallConsentRequired()
            SGAnalytics.screen(.zgPro, accountPeerId: accountPeerId)
            // Opening the Pro screen asks for the current monetization policy (same 60 s cooldown
            // as launch / foreground); a change arrives as `SGEntitlementDidChange`, which reloads.
            SGEntitlement.shared.refreshMonetizationPolicy()
            // Re-query StoreKit's status (once products are loaded; it never loads them). Its
            // answer arrives as `SGIAPStateDidChange`, which reloads; until then the settled status
            // is nil and the App Store line falls back to the expiry-checked snapshot.
            SGIAP?.refreshSubscriptionStatus()
        }
        .onReceive(changePub) { _ in reload() }
        .onReceive(iapPub) { _ in reload() }
        .onReceive(becameActivePub) { _ in reload() }
    }

    private var isScreenAccountActive: Bool {
        return SGEntitlement.shared.activeAccountPeerId == accountPeerId
    }

    private func reload() {
        let fresh = SGEntitlementStatusSnapshot.read(accountPeerId: accountPeerId, SGIAP: SGIAP)
        if !fresh.inputs.screenAccountIsActive {
            restoreFlow.invalidate()
        }
        snapshot = fresh
    }

    /// An action runs only while the screen's account is still the active one; otherwise the tap
    /// re-renders the other-account state instead.
    private func guarded(_ action: (() -> Void)?) -> (() -> Void)? {
        guard let action else {
            return nil
        }
        return {
            guard isScreenAccountActive else {
                reload()
                return
            }
            action()
        }
    }

    /// The real Restore — `AppStore.sync()` plus the account-scoped claim in `SGIAP` — for THIS
    /// screen's account, never whichever account is active when the App Store answers. `SGIAP`
    /// refuses a second App Store operation itself (`.storeOperationInProgress`); the flow refuses a
    /// second tap here before that.
    private func startRestore() {
        // A held Apple backend has no Restore row, and `SGIAP` would refuse the call anyway.
        guard let SGIAP, let attempt = restoreFlow.begin(screenAccountIsActive: isScreenAccountActive, isAvailable: SGEntitlement.shared.isAppleBackendEnabled) else {
            reload()
            return
        }
        let accountPeerId = self.accountPeerId
        let lang = self.lang
        Task { @MainActor in
            let result = await SGIAP.restore(accountPeerId: accountPeerId)
            if let event = SGPayWallFunnel.restoreEvent(result) {
                SGAnalytics.record(event, accountPeerId: accountPeerId)
            }
            let stillActive = SGEntitlement.shared.activeAccountPeerId == accountPeerId
            if restoreFlow.finish(SGEntitlementStatusView.outcome(of: result), attempt: attempt, screenAccountIsActive: stillActive), let notice = sgProStatusRestoreNotice(restoreFlow.phase) {
                UIAccessibility.post(notification: .announcement, argument: notice.key.i18n(lang))
            }
            reload()
        }
    }

    private static func outcome(of result: SGIAPRestoreResult) -> SGProStatusRestoreOutcome {
        switch result {
        case .restored:
            return .restored
        case .nothingToRestore:
            return .nothingToRestore
        case .cancelled:
            return .cancelled
        case .failed(.storeOperationInProgress):
            return .anotherOperationInProgress
        case let .failed(message):
            return .failed(messageKey: message.localizationKey)
        }
    }
}

/// One synchronous read of the cached decision, the stored session and StoreKit's last answer —
/// never a network call.
struct SGEntitlementStatusSnapshot {
    var inputs: SGProStatusInputs
    var degradedReason: SGEntitlementDegradedReason?
    var degradedMessage: SGEntitlementMessage?

    static func read(accountPeerId: Int64?, SGIAP: SGIAPManager?) -> SGEntitlementStatusSnapshot {
        let entitlement = SGEntitlement.shared
        let isActive = entitlement.activeAccountPeerId == accountPeerId
        let state = entitlement.state
        let tokenUntil = accountPeerId.flatMap { entitlement.genuineGrantUntil(accountPeerId: $0) }
        let storeKitSnapshot = entitlement.storeKitFallback
        let inputs = SGProStatusInputs(
            screenAccountIsActive: isActive,
            isUnlocked: state.isUnlocked,
            source: accessSource(entitlement.source),
            degradation: state.degradedReason.map(degradation),
            localGraceEndsAt: entitlement.localGraceEndsAt,
            tokenUntil: tokenUntil,
            appleState: SGIAP?.settledSubscriptionStatus.map(appleState),
            snapshotHasActiveSubscription: storeKitSnapshot?.hasActiveSubscription,
            snapshotExpiration: storeKitSnapshot?.expirationDate,
            isLinked: accountPeerId.map { entitlement.isLinked(accountPeerId: $0) } ?? false,
            monetization: entitlement.monetizationMode == .free ? .free : .paid,
            // Apple backend held (`apple_backend_enabled` false — a build without the product pair,
            // which sells nothing through Apple): no Apple row, nothing said about a purchase.
            isAppleBackendEnabled: entitlement.isAppleBackendEnabled,
            // Manage only: a still-current snapshot an earlier build left, while this origin has none.
            hasManageableLegacySubscription: storeKitSnapshot == nil && entitlement.manageableStoreKitSnapshot != nil,
            now: entitlement.entitlementClock.effectiveNow()
        )
        return SGEntitlementStatusSnapshot(
            inputs: inputs,
            degradedReason: isActive ? state.degradedReason : nil,
            degradedMessage: isActive ? entitlement.degradedMessage : nil
        )
    }

    private static func accessSource(_ source: SGEntitlementSource) -> SGProStatusAccessSource {
        switch source {
        case .none:
            return .none
        case .token:
            return .token
        case .storeKit:
            return .storeKit
        case .unconfigured:
            return .unconfigured
        case .localGrace:
            return .localGrace
        case .freeAccess:
            return .freeAccess
        }
    }

    private static func degradation(_ reason: SGEntitlementDegradedReason) -> SGProStatusDegradation {
        switch reason {
        case .noToken:
            return .noAccess
        case .lapsed:
            return .lapsed
        case .stale, .unverifiable, .provisional:
            return .reconnect
        }
    }

    private static func appleState(_ status: SGIAPSubscriptionStatus) -> SGProStatusAppleState {
        switch status.state {
        case .subscribed, .inGracePeriod:
            return .live(expiration: status.expirationDate, willAutoRenew: status.willAutoRenew)
        case .inBillingRetry:
            return .billingRetry
        case .expired, .revoked:
            return .ended
        case .unknown:
            return .unknown
        }
    }
}
