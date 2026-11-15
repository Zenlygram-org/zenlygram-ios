import Foundation
import SwiftUI
import UIKit
import SGSwiftUI
import TelegramPresentationData
import LegacyUI
import Display
import BuildConfig
import SGConfig
import SGCustomerSyncCore
import SGEntitlement
import SGIAP
import SGStrings
import SwiftSignalKit

// MARK: Zenlygram — the paywall.
//
// Four rules govern every line below, and three of them are not negotiable:
//
//  1. **No external-purchase call to action, anywhere** (App Store guideline 3.1.3(b)). No "also
//     available on the web", no "cheaper on Telegram", no Mini App button, and no support link that
//     itself leads to a purchase page. The only links that leave this screen are Apple's standard
//     EULA, our privacy policy, and Apple's own subscription-management page.
//  2. **Never a hardcoded price.** Storefronts, currencies and tax-inclusive pricing differ; the
//     only correct price is `product.displayPrice`, and the only correct trial copy is the one
//     StoreKit says this Apple Account is still eligible for.
//  3. **A lapse takes nothing of the user's own away.** The paywall says so in as many words,
//     because the user who lands here after a lapse is asking one question — "are my hidden chats
//     gone?" — and the answer is no, they open with their PIN exactly as before. The one thing a
//     lapse hides (never deletes) is what Edit History captured of OTHER people's deletions and
//     edits, and the copy says that in the same breath. See `SGPayWallStatus.swift`.
//  4. It is a screen the user can always leave. Nothing on it is on the path to their own data.

/// Night or day for the paywall, kept current while it is open.
final class SGPayWallAppearance: ObservableObject {
    @Published var isDark: Bool

    init(isDark: Bool) {
        self.isDark = isDark
    }
}

public func sgPayWallController(
    accountPeerId: Int64?,
    presentationData: PresentationData? = nil,
    updatedPresentationData: Signal<PresentationData, NoError>? = nil,
    pushed: Bool = false,
    SGIAPManager: SGIAPManager?,
    openUrl: @escaping (String, Bool) -> Void, /* url, forceExternal */
    paymentsEnabled: Bool = true,
    openLinkTelegramAccount: @escaping () -> Void,
    openProFeatures: (() -> Void)? = nil
) -> ViewController {
    // Night or day follows the app's theme, and keeps following it while the screen is open. The
    // theme follows the device's appearance unless the user picked one. At night the paywall is the
    // cosmic design as drawn; by day its light counterpart (`SGPayWallPalette`).
    let isDark = presentationData?.theme.overallDarkAppearance ?? (UITraitCollection.current.userInterfaceStyle == .dark)
    let theme = presentationData?.theme ?? (isDark ? defaultDarkColorPresentationTheme : defaultPresentationTheme)
    let strings = presentationData?.strings ?? defaultPresentationStrings
    let appearance = SGPayWallAppearance(isDark: isDark)

    // `pushed` (the Settings row): a navigation screen, so it slides in from the right like every
    // other row there and goes back the same way, by the round back button (`dismiss(animated:)`
    // pops a controller that is on a navigation stack) or the left-edge swipe. The design draws its
    // own back button, so the navigation bar stays hidden. Otherwise a modal that rises from the
    // bottom, with navigation underneath it switched off.
    let legacyController = LegacySwiftUIController(
        presentation: pushed ? .navigation : .modal(animateIn: true),
        theme: theme,
        strings: strings
    )
    legacyController.statusBar.statusBarStyle = isDark ? .White : .Black
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
    // Horizontal swipes on this screen belong to the feature-details pager. With this flag the
    // back swipe keeps only its left-edge start, so swiping through the pages no longer pops a
    // pushed paywall.
    legacyController.view.disablesInteractiveTransitionGestureRecognizer = true
    if pushed {
        legacyController.displayNavigationBar = false
    } else {
        legacyController.attemptNavigation = { _ in return false }
    }

    let swiftUIView = SGSwiftUIView<SGPayWallView>(
        legacyController: legacyController,
        content: {
            SGPayWallView(
                wrapperController: legacyController,
                appearance: appearance,
                accountPeerId: accountPeerId,
                SGIAP: SGIAPManager,
                openUrl: openUrl,
                paymentsEnabled: paymentsEnabled,
                openLinkTelegramAccount: openLinkTelegramAccount,
                openProFeatures: openProFeatures
            )
        }
    )
    let controller = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: controller)

    return legacyController
}

/// Apple's subscription-management page. It is the App Store, not an alternative store, and Apple
/// asks auto-renewable subscriptions to tell the user how to cancel — so this one link is required
/// rather than forbidden.
private let manageSubscriptionsUrl = "https://apps.apple.com/account/subscriptions"

/// Apple's standard EULA, which Apple accepts in place of an app-specific one for an auto-renewable
/// subscription. A constant, not a localized string: it is the same document in every language, and
/// as a string it drifted to `telegram.org/tos` in seven locales.
let sgPayWallTermsURL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"

/// Zenlygram's OWN privacy policy — the hosted copy of `appstore/privacy-policy.html`, which is the
/// document that describes what the entitlement server receives (the device id, the Secure Enclave
/// public key, the device name, app/OS version, the linked Telegram user id, the APNs token and the
/// App Store transaction). Guideline 3.1.2 asks the paywall to link the app's own policy, and
/// 5.1.1(i) asks the App Privacy label to match it; Telegram's policy — which this used to point at
/// — describes none of that and is not ours to present as ours.
///
/// nil when `sg_config.privacy_policy_url` was not filled in. The paywall then shows the disclosure
/// with no hyperlinks rather than link a policy that is not the app's. Hosting the file and setting
/// this value is a submission gate, tracked in `appstore/CHECKLIST.md`.
let sgPayWallPrivacyPolicyURL: String? = {
    guard let value = SG_CONFIG.privacyPolicyUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
        return nil
    }
    return value
}()

/// Zenlygram — this build runs the customer-data pipeline in `required` consent mode: an account is
/// then linked automatically after its consent, which the Link row says instead of "optional"
/// (`SGPayWallFunnel.linkNoticeKey`). The build config is read only while the pipeline is active, so
/// the test-only preview never reads it.
func sgPayWallConsentRequired() -> Bool {
    return SGPayWallFunnel.consentRequired(pipelineActive: SGCustomerDataGate.shared.isPipelineActive, sgConfigJSON: {
        sgPayWallBuildSGConfigJSON
    })
}

private let sgPayWallBuildSGConfigJSON: String? = {
    return BuildConfig(baseAppBundleId: Bundle.main.bundleIdentifier ?? "").sgConfig
}()

struct SGPayWallFeatureDetails: View {
    @Environment(\.lang) var lang: String
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    let dismissAction: () -> Void
    var bottomOffset: CGFloat = 0.0
    let contentHeight: CGFloat = 560.0
    let features: [SGProFeature]

    @State var shownFeature: SGProFeatureId?
    // Add animation states
    @State private var showBackground = false
    @State private var showContent = false

    @State private var dragOffset: CGFloat = 0

    /// The page dots by day. The system's are white, made for dark content, and vanish on the white
    /// sheet; at night the system draws them, as before.
    @ViewBuilder
    private var dayPageDots: some View {
        if colorScheme != .dark {
            HStack(spacing: 8) {
                ForEach(features) { feature in
                    Circle()
                        .fill(SGPayWallPalette(colorScheme).pageDot.opacity(feature.id == shownFeature ? 1.0 : 0.25))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 10)
            .accessibility(hidden: true)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background overlay
            if showBackground {
                Color.black.opacity(0.4)
                    .zIndex(0)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        dismissWithAnimation()
                    }
                    .transition(.opacity)
            }

            // Bottom sheet content
            if showContent {
                VStack {
                    if #available(iOS 14.0, *) {
                        TabView(selection: $shownFeature) {
                            ForEach(features) { feature in
                                ScrollView(showsIndicators: false) {
                                    SGProFeatureView(
                                        feature: feature
                                    )
                                    Color.clear.frame(height: 8.0) // paginator padding
                                }
                                .tag(feature.id)
                                .scrollBounceBehaviorIfAvailable(.basedOnSize)
                            }
                        }
                        // By day the sheet draws its own dots (`dayPageDots`); at night the system's,
                        // as drawn (`.automatic` is what `.page` uses).
                        .tabViewStyle(PageTabViewStyle(indexDisplayMode: colorScheme == .dark ? .automatic : .never))
                        .overlay(dayPageDots, alignment: .bottom)
                        .padding(.bottom, bottomOffset - 8.0)
                    }

                    // Spacer for purchase buttons
                    if !bottomOffset.isZero {
                        Color.clear.frame(height: bottomOffset)
                    }
                }
                .zIndex(1)
                .frame(maxHeight: contentHeight)
                .background(Color(.systemBackground))
                .cornerRadius(8, corners: [.topLeft, .topRight])
                .overlay(closeButtonView)
                .offset(y: max(0, dragOffset))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // Only track downward movement
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            // If dragged down more than 150 points or with significant velocity, dismiss
                            if value.translation.height > 150 || value.predictedEndTranslation.height > 200 {
                                dismissWithAnimation()
                            } else {
                                // Otherwise, reset position
                                withAnimation(.spring()) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .onAppear {
            appearWithAnimation()
        }
    }

    private func appearWithAnimation() {
        withAnimation(.easeIn(duration: 0.2)) {
            showBackground = true
        }

        withAnimation(.spring(duration: 0.3)) {
            showContent = true
        }
    }

    private func dismissWithAnimation() {
        withAnimation(.spring()) {
            showContent = false
            dragOffset = 0
        }

        withAnimation(.easeOut(duration: 0.2).delay(0.1)) {
            showBackground = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            dismissAction()
        }
    }

    private var closeButtonView: some View {
        Button(action: {
            dismissWithAnimation()
        }) {
            SGPayWallCloseGlyph()
        }
        .accessibility(label: Text("Common.Close".i18n(lang)))
        .opacity(showContent ? 1.0 : 0.0)
        .padding([.top, .trailing], 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}



struct SGProFeatureView: View {
    @Environment(\.sgPayWallSecondaryText) private var secondaryText: Color

    let feature: SGProFeature

    var body: some View {
        VStack(spacing: 16) {
            // SG: the fork's own settings icon for this feature, enlarged — not a screenshot. The
            // four Pro features are privacy features; screenshotting them would mean screenshotting
            // somebody's hidden chats. Decorative: the title below names the feature.
            Image(systemName: feature.iconName)
                .font(.system(size: 40, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 88, height: 88)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(feature.iconColor)
                )
                .padding(.top, 40)
                .accessibility(hidden: true)

            VStack(alignment: .center, spacing: 8) {
                Text(feature.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibility(addTraits: .isHeader)
                Text(feature.description)
                    .font(.body)
                    .foregroundColor(secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)

            Spacer()
        }
    }
}



struct SGPayWallView: View {
    @Environment(\.containerViewLayout) var containerViewLayout: ContainerViewLayout?
    @Environment(\.lang) var lang: String
    @Environment(\.sizeCategory) var sizeCategory: ContentSizeCategory

    weak var wrapperController: LegacyController?
    @ObservedObject var appearance: SGPayWallAppearance
    let accountPeerId: Int64?
    /// The money path. `SGEntitlement` decides what the user MAY do; this decides only what the App
    /// Store will sell, and it is nil on a build where the manager was never created.
    let SGIAP: SGIAPManager?
    let openUrl: (String, Bool) -> Void // url, forceExternal
    let paymentsEnabled: Bool
    /// Opens "Link Telegram Account" for the paywall's account. The caller holds that account's
    /// context, which the link screen needs (`SGLinkAccountTelegram`); the paywall has none.
    let openLinkTelegramAccount: () -> Void
    let openProFeatures: (() -> Void)?

    private enum PayWallState: Equatable {
        case ready
        case restoring
        case purchasing
        case startingTrial
    }

    private enum PrimaryAction: Equatable {
        case buy(String)
        /// A plan change is already queued with Apple: keeping, undoing or changing it happens on
        /// Apple's subscription page, so that is what the button opens instead of a second purchase.
        case manageSubscription
        case openPro
        case unavailable
    }

    // State management
    @State private var products: [SGIAPProduct] = []
    @State private var productsState: SGIAPProductsState = .idle
    @State private var selectedProductId: String?
    @State private var state: PayWallState = .ready
    @State private var entitlementState: SGEntitlementState = SGEntitlement.shared.state
    @State private var degradedMessage: SGEntitlementMessage? = SGEntitlement.shared.degradedMessage
    /// Non-nil while the local grace is what grants (`SGEntitlementLocalGrace`); never under a
    /// 0-day signed policy, where that grace does not grant at all.
    /// Initialized to nil because @Environment(\.lang) is not available at @State init time;
    /// set in onAppear and refreshed on entitlement changes.
    @State private var graceUntilText: String? = nil
    @State private var isLinked: Bool = false
    /// The signed monetization mode, re-read on every entitlement change: while free the paywall
    /// sells nothing (`SGPayWallOffer`), and a purchase started from a screen that missed the change
    /// is refused again inside `SGIAP`.
    @State private var monetization: SGProMonetization = sgPayWallMonetization()
    /// The server's own trial the signed policy offers (`SGEntitlement.serverTrialDays`), re-read
    /// with the mode on every entitlement change: the ONLY thing that may put our trial button on
    /// screen, and the length it names. nil while free, under a v1 policy and while the operator
    /// has not enabled the trial — then the button is simply absent, with nothing to explain.
    @State private var serverTrialDays: Int? = SGEntitlement.shared.serverTrialDays
    @State private var trialAffordance = SGIAPTrialAffordance(isAppleIntroOfferAvailable: false, isServerTrialAvailable: false, serverTrialRefusal: nil)
    /// A refusal or a result shown NEXT TO the purchase options — never a dead end, never an alert
    /// the user has to dismiss before they can buy (design §7 row 11).
    @State private var inlineNotice: SGPayWallNotice?
    @State private var showConfetti: Bool = false
    @State private var showDetails: Bool = false
    @State private var shownFeature: SGProFeatureId?
    @State private var hapticFeedback: HapticFeedback?
    @State private var purchaseSectionSize: CGSize = .zero
    @State private var accountWasInvalidated = false
    /// `zg.paywall` + `pro.screen_view` are recorded once per presentation, not on every re-appear.
    @State private var didRecordScreenView = false
    @State private var consentRequired = false

    private let entitlementPub = NotificationCenter.default.publisher(for: SGEntitlement.didChangeNotification, object: nil)
    private let iapPub = NotificationCenter.default.publisher(for: .SGIAPStateDidChangeNotification, object: nil)
    private let becameActivePub = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification, object: nil)
    private let confettiDuration: Double = 5.0

    private var offer: SGPayWallOffer {
        return Self.makeOffer(for: monetization, serverTrialDays: serverTrialDays)
    }

    /// The offer under `monetization` in THIS build: a held Apple backend (`apple_backend_enabled`
    /// false — a build without the product pair, which sells nothing through Apple) shows no Restore
    /// and no Manage Subscription row, whatever the mode; `serverTrialDays` is the signed policy's
    /// trial as this screen last read it (`SGEntitlement.serverTrialDays`).
    private static func makeOffer(for monetization: SGProMonetization, serverTrialDays: Int?) -> SGPayWallOffer {
        return SGPayWallOffer(monetization: monetization, isAppleBackendEnabled: SGEntitlement.shared.isAppleBackendEnabled, serverTrialDays: serverTrialDays)
    }

    private var features: [SGProFeature] {
        return sgProFeatures(lang: lang)
    }

    var body: some View {
        ZStack {
            // The cosmic canvas: near-black with a violet nebula and faint stars behind the hero
            // (`SGPayWallDesign.swift`). Every card on it is opaque enough to read on its own.
            SGPayWallCosmicBackground()

            ZStack(alignment: .bottom) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        headerSection

                        if let reason = entitlementState.degradedReason, let message = degradedMessage, reason != .noToken {
                            SGEntitlementLapseNotice(lang: lang, reason: reason, message: message)
                        }

                        // Free for everyone: nothing to buy, and no countdown. Said once, plainly.
                        if offer.showsFreeAccess {
                            SGPayWallNoticeView(notice: SGPayWallNotice(text: "PayWall.FreeAccess.Notice".i18n(lang), tone: .info))
                        }

                        // Inside the paid-mode local grace: everything is already unlocked, and the
                        // purchase section below still sells the plan that continues it. The grace
                        // notice hides when an App Store subscription is what grants: the user is
                        // a paying customer, not someone in a free window.
                        if let graceUntilText, !hasAppStoreSubscription {
                            SGPayWallGraceNotice(lang: lang, untilText: graceUntilText)
                        }

                        // The plans sit right under the hero, before the features: the price is
                        // the first thing compared. The button that buys the selected plan stays
                        // pinned below.
                        if offer.offersPurchase && showsPlanPicker {
                            planPicker
                        }

                        VStack(spacing: 24) {
                            featuresSection

                            // Restore, the Telegram link and Apple's subscription management sit
                            // right under what is sold, as full-width rows rather than small links.
                            accountSection

                            // While free there is no purchase footer, which is where the paid
                            // paywall shows Restore's result: show it here, under the row that
                            // started it.
                            if !offer.offersPurchase, let notice = inlineNotice ?? persistentNotice {
                                SGPayWallNoticeView(notice: notice)
                            }

                            lapsePolicySection

                            aboutSection

                            // At the accessibility text sizes the notice and the purchase terms scroll
                            // with the rest, directly above the auto-renewal disclosure and the
                            // EULA/Privacy links; only the button stays pinned.
                            if usesAccessibilityLayout, offer.offersPurchase {
                                VStack(spacing: 12) {
                                    purchaseNoticeView
                                    purchaseCaptionView
                                }
                            }

                            // The auto-renewal disclosure belongs to a purchase; there is none
                            // while free.
                            if offer.offersPurchase {
                                legalSection
                            }
                        }
                    }
                    // The header shares its top line with the close button, clear of the status bar.
                    .padding(.top, max(16.0, closeButtonTopInset))
                    // Bottom padding clears the pinned purchase footer; no spacer needed.
                    .padding(.bottom, (offer.offersPurchase ? purchaseSectionSize.height : 0) + 16)
                }
                .padding(.leading, max(16.0, sgLeftSafeAreaInset(containerViewLayout)))
                .padding(.trailing, max(16.0, sgRightSafeAreaInset(containerViewLayout)))

                if showDetails {
                    SGPayWallFeatureDetails(
                        dismissAction: dismissDetails,
                        bottomOffset: (purchaseSectionSize.height / 2.0) * 0.9, // reduced offset for paginator
                        features: features,
                        shownFeature: shownFeature)
                }

                if offer.offersPurchase {
                    purchaseSection
                        .trackSize($purchaseSectionSize)
                }
            }
        }
        .confetti(isActive: $showConfetti, duration: confettiDuration)
        .overlay(closeButtonView)
        // Night or day, from the app's theme. Every colour below follows it: the design's own through
        // `SGPayWallPalette`, the system ones (notices, sheets, secondary text) by themselves.
        .colorScheme(appearance.isDark ? .dark : .light)
        // By day the system's secondary grey and grouped grey sit poorly on the pale sky: secondary
        // text takes the day ink and grouped blocks become white cards. At night both are the system
        // values, the same as on every screen that never sets them.
        .environment(\.sgPayWallSecondaryText, SGPayWallPalette(isDark: appearance.isDark).secondaryText)
        .environment(\.sgPayWallGroupedCard, !appearance.isDark)
        .onAppear {
            guard ensureCurrentAccount() else {
                return
            }
            hapticFeedback = HapticFeedback()
            entitlementState = SGEntitlement.shared.state
            degradedMessage = SGEntitlement.shared.degradedMessage
            graceUntilText = sgPayWallGraceUntilText(lang: lang)
            consentRequired = sgPayWallConsentRequired()
            if !didRecordScreenView {
                didRecordScreenView = true
                SGAnalytics.screen(.zgPaywall, accountPeerId: accountPeerId)
                SGAnalytics.record(.proScreenView(source: SGAnalytics.takePaywallEntry(), mode: SGPayWallFunnel.proMode(SGEntitlement.shared.monetizationMode)), accountPeerId: accountPeerId)
            }
            let current = sgPayWallMonetization()
            monetization = current
            serverTrialDays = SGEntitlement.shared.serverTrialDays
            refreshLocalState()
            // Opening the paywall asks for the current monetization policy (60 s cooldown); a
            // change — of the mode or of the trial alone — arrives as `SGEntitlementDidChange` below.
            SGEntitlement.shared.refreshMonetizationPolicy()
            if Self.makeOffer(for: current, serverTrialDays: serverTrialDays).loadsProducts {
                loadProducts()
            }
        }
        .onReceive(entitlementPub) { _ in
            guard ensureCurrentAccount() else {
                return
            }
            let wasUnlocked = entitlementState.isUnlocked
            let wasPaid = monetization == .paid
            let current = sgPayWallMonetization()
            entitlementState = SGEntitlement.shared.state
            degradedMessage = SGEntitlement.shared.degradedMessage
            graceUntilText = sgPayWallGraceUntilText(lang: lang)
            monetization = current
            // Every adopted policy posts this change, a change of `trial_days` alone included: the
            // trial button and its length follow the signed policy within one refresh.
            serverTrialDays = SGEntitlement.shared.serverTrialDays
            refreshLocalState()
            if !wasPaid && Self.makeOffer(for: current, serverTrialDays: serverTrialDays).loadsProducts {
                // Paid mode was just enabled while this screen is open: now there is something to
                // show. Nothing is bought until the user picks a plan and confirms with Apple.
                loadProducts()
            }
            // Celebrate a purchase or a restore — not free access arriving, which bought nothing.
            if !wasUnlocked && entitlementState.isUnlocked && SGEntitlement.shared.source != .freeAccess {
                celebrate()
            }
        }
        .onReceive(iapPub) { _ in
            refreshLocalState()
        }
        .onReceive(becameActivePub) { _ in
            ensureCurrentAccount()
        }
    }

    // MARK: - Sections

    /// The hero: the glowing Z mark with its orbit, "Zenlygram Pro" with a gradient "Pro", the
    /// one-sentence offer, and the stats strip (PREMIUM · +N features · unlimited freedom).
    private var headerSection: some View {
        VStack(spacing: 14) {
            SGPayWallHeroMark()

            VStack(spacing: 8) {
                SGPayWallHeroTitle()

                Text("PayWall.Hero.Subtitle".i18n(lang))
                    .font(.callout)
                    .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).heroSubtitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }

            // The count is the real number of features below, never a marketing figure.
            SGPayWallStatsStrip(
                premiumLabel: "PayWall.Hero.Premium".i18n(lang),
                featureCountTitle: "+\(features.count)",
                featureCountSubtitle: "PayWall.Hero.Features".i18n(lang),
                freedomTitle: "PayWall.Hero.Unlimited".i18n(lang),
                freedomSubtitle: "PayWall.Hero.Freedom".i18n(lang),
                isCompact: usesCompactStatsStrip
            )
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    /// The four features as one glass card; each row opens its details page (iOS 14+).
    private var featuresSection: some View {
        let features = self.features
        let firstId = features.first?.id
        return VStack(spacing: 0) {
            ForEach(features) { feature in
                if feature.id != firstId {
                    SGPayWallCosmicDivider(leadingInset: SGPayWallCosmicFeatureRow.dividerInset)
                }
                SGPayWallCosmicFeatureRow(feature: feature, action: {
                    showDetailsForFeature(feature.id)
                })
            }
        }
        .sgPayWallGlassCard()
    }

    /// The single most important paragraph on this screen. It is here even when the user is not
    /// lapsed, because "what happens if I stop paying" is the question that stops a purchase.
    private var lapsePolicySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entitlementState.isUnlocked {
                HStack {
                    Text("PayWall.LapsePolicy.Short".i18n(lang))
                        .font(.footnote)
                        .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            } else {
                SGEntitlementLapseExplanation(lang: lang)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SGPayWallSectionHeader(title: "PayWall.About.Title".i18n(lang))

            Text("PayWall.About.Notice".i18n(lang))
                .font(.subheadline)
                .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // MARK: Zenlygram — upstream author signature (@Kylmakalle) removed: wrong
            // identity for this fork's About/credits copy.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// Restore, the Telegram link and Apple's subscription management. Nothing here leaves the App
    /// Store's payment rails, and nothing here is a second way to buy.
    private var accountSection: some View {
        // A held Apple backend refuses Restore (no StoreKit work at all): no dead row — and no
        // Manage Subscription row below either (`SGPayWallOffer`).
        let showsRestore = offer.showsRestore
        let showsLink = !isLinked && accountPeerId != nil
        return VStack(spacing: 0) {
            if showsRestore {
                SGPayWallActionRow(
                    symbol: "arrow.clockwise",
                    title: "PayWall.RestorePurchases".i18n(lang),
                    trailing: .none,
                    isBusy: state == .restoring,
                    isEnabled: state == .ready && SGIAP != nil,
                    action: handleRestorePurchases
                )
            }

            if showsLink {
                if showsRestore {
                    SGPayWallRowDivider()
                }
                SGPayWallActionRow(
                    symbol: "link",
                    title: "LinkAccount.Title".i18n(lang),
                    detail: SGPayWallFunnel.linkNoticeKey(consentRequired: consentRequired).i18n(lang),
                    action: {
                        presentLinkTelegramAccount()
                    }
                )
            }

            // A live subscription or an Apple billing retry can be managed — in either mode: free
            // access stops nothing Apple bills. Unlocked access alone (free access, local grace,
            // server trial) is not evidence of a purchase, and without evidence the row is not shown
            // (`SGPayWallOffer.showsManageSubscription`), so it never needs to say who it is for.
            if offer.showsManageSubscription(hasAppStoreSubscription: hasExistingAppStoreSubscription, isInBillingRetry: SGIAP?.subscriptionStatus?.state == .inBillingRetry) {
                if showsRestore || showsLink {
                    SGPayWallRowDivider()
                }
                SGPayWallActionRow(
                    symbol: "creditcard",
                    title: "PayWall.ManageSubscription".i18n(lang),
                    trailing: .external,
                    action: {
                        guard ensureCurrentAccount() else {
                            return
                        }
                        openUrl(manageSubscriptionsUrl, true)
                    }
                )
            }
        }
        .sgPayWallGlassCard()
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PayWall.Disclosure".i18n(lang))
                .font(.caption)
                .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            legalLinks
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// The subscription's legal disclosure (guideline 3.1.2), with the two links Apple requires.
    ///
    /// Both URLs are CONSTANTS, not localized strings: a URL is a deployment fact, and as a string
    /// it drifted — seven locales still shipped `telegram.org/tos` behind a "Zenlygram Terms of
    /// Service" label. With no privacy policy configured the link-free sentence is shown instead;
    /// an app that has nothing of its own to link must not link somebody else's policy.
    private var legalLinks: some View {
        Group {
            if #available(iOS 15.0, *), let privacyURL = sgPayWallPrivacyPolicyURL {
                Text(LocalizedStringKey("PayWall.Notice.Markdown".i18n(lang, args: sgPayWallTermsURL, privacyURL)))
                    .font(.footnote)
                    .tint(sgPayWallAccentText)
                    .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        openUrl(url.absoluteString, false)
                        return .handled
                    })
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PayWall.Notice.Raw".i18n(lang))
                        .font(.footnote)
                        .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .center, spacing: 20) {
                        legalLinkButton(title: "PayWall.EULA".i18n(lang), action: {
                            openUrl(sgPayWallTermsURL, true)
                        })
                        if let privacyURL = sgPayWallPrivacyPolicyURL {
                            legalLinkButton(title: "PayWall.Privacy".i18n(lang), action: {
                                openUrl(privacyURL, true)
                            })
                        }
                    }
                }
            }
        }
    }

    private func legalLinkButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundColor(sgPayWallAccentText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - The purchase section

    /// Is the text at one of the accessibility sizes (Larger Accessibility Sizes)?
    ///
    /// There the pinned purchase section, sized like the default layout, grows past the height of
    /// the screen: the scroll view above it — Restore Purchases, the auto-renewal disclosure and the
    /// EULA/Privacy links (guideline 3.1.2) — is left with no visible area at all. So at these sizes
    /// only the buttons stay pinned, and the plans, the notice and the caption move into the scroll
    /// view. An explicit list because `ContentSizeCategory.isAccessibilityCategory` needs iOS 13.4.
    private var usesAccessibilityLayout: Bool {
        return SGPayWallView.accessibilitySizeCategories.contains(sizeCategory)
    }

    /// Under 375 pt (the 320 pt iPhone SE, Display Zoom, Slide Over) the stats strip fits on one line
    /// in no language, so it stacks.
    private var usesCompactStatsStrip: Bool {
        guard let width = containerViewLayout?.size.width else {
            return false
        }
        return width < 375.0
    }

    private static let accessibilitySizeCategories: [ContentSizeCategory] = [
        .accessibilityMedium,
        .accessibilityLarge,
        .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge,
        .accessibilityExtraExtraExtraLarge
    ]

    /// The button that buys the selected plan, the notice that goes with it, and the terms of that
    /// purchase directly under it. Pinned over a fade into the backdrop, so the list scrolls away
    /// beneath it. The plans themselves scroll with the content, right under the hero.
    private var purchaseSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if !usesAccessibilityLayout {
                    purchaseNoticeView
                }

                Button(action: handlePrimaryAction) {
                    SGPayWallCosmicButtonLabel(title: buttonTitle, isBusy: isPrimaryBusy)
                }
                .disabled(!isPurchaseButtonEnabled)
                // "Start Free Trial" names neither the plan nor what follows the free days; the
                // caption does, and VoiceOver reads it with the button wherever it is drawn.
                .accessibility(hint: Text(purchaseCaption ?? ""))

                // The caption sits directly under the button it describes. It carries the paid terms
                // ("N days free, then %@. Cancel any time."), and below the trial button it read as
                // the terms of the control that charges nothing.
                if !usesAccessibilityLayout {
                    purchaseCaptionView
                }

                if isTrialButtonVisible, let days = serverTrialDays {
                    Button(action: handleStartTrial) {
                        // The signed `trial_days`, never a guess, in its plural form: "Try 7 days free", "Try 1 day free".
                        Text(serverTrialButtonTitle(days: days))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(sgPayWallAccentText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(state != .ready)
                    .opacity(state == .ready ? 1.0 : 0.5)
                    // "Try N days free" names neither who gives the trial nor what ends with it;
                    // the caption does, and VoiceOver reads it with the button.
                    .accessibility(hint: Text(serverTrialDisclosure(days: days)))

                    // Directly under the button it describes: Zenlygram's own trial, not an App
                    // Store offer — no payment details, nothing charged when it ends — and what a
                    // subscription is needed for afterwards.
                    Text(serverTrialDisclosure(days: days))
                        .font(.footnote)
                        .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 24)
            .padding(.leading, max(16.0, sgLeftSafeAreaInset(containerViewLayout)))
            .padding(.trailing, max(16.0, sgRightSafeAreaInset(containerViewLayout)))
            .padding(.bottom, sgBottomSafeAreaInset(containerViewLayout) + 8.0)
        }
        .background(
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: SGPayWallPalette(isDark: appearance.isDark).backdrop.opacity(0.0), location: 0.0),
                    .init(color: SGPayWallPalette(isDark: appearance.isDark).backdrop.opacity(0.92), location: 0.3),
                    .init(color: SGPayWallPalette(isDark: appearance.isDark).backdrop, location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// The primary button shows a spinner exactly while its title says something is under way:
    /// purchasing, restoring, confirming the trial, or "Contacting App Store…".
    private var isPrimaryBusy: Bool {
        if state != .ready {
            return true
        }
        if case .unavailable = primaryAction {
            return isContactingAppStore
        }
        return false
    }

    /// True on exactly the rung of `purchaseUnavailableReason` that answers "Contacting App Store…".
    private var isContactingAppStore: Bool {
        guard let SGIAP, SGIAP.isPurchaseSupported, paymentsEnabled, SGIAP.canMakePayments else {
            return false
        }
        switch productsState {
        case .idle, .loading:
            return true
        case .loaded, .failed:
            return false
        }
    }

    /// A refusal or a result of the purchase flow: pinned above the button by default, scrolled at
    /// the accessibility sizes (`usesAccessibilityLayout`).
    @ViewBuilder
    private var purchaseNoticeView: some View {
        if let notice = inlineNotice ?? persistentNotice {
            SGPayWallNoticeView(notice: notice)
        }
    }

    @ViewBuilder
    private var purchaseCaptionView: some View {
        if let caption = purchaseCaption {
            Text(caption)
                .font(.footnote)
                .foregroundColor(SGPayWallPalette(isDark: appearance.isDark).secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    /// The plans as rows in one glass card, the selected one outlined in the brand gradient. Rows
    /// stack at every text size, so a price always has the full width it needs.
    private var planPicker: some View {
        VStack(spacing: 4) {
            ForEach(products, id: \.id) { product in
                SGPayWallPlanRow(
                    title: planRowTitle(product),
                    badge: badge(for: product),
                    summary: planRowSummary(product),
                    price: planRowPrice(product),
                    isSelected: product.id == selectedProduct?.id,
                    stacksPrice: usesAccessibilityLayout,
                    action: {
                        selectedProductId = product.id
                        inlineNotice = nil
                        if let event = SGPayWallFunnel.planSelectEvent(productId: product.id) {
                            SGAnalytics.record(event, accountPeerId: accountPeerId)
                        }
                    }
                )
            }
        }
        .padding(6)
        .sgPayWallGlassCard()
    }

    /// The round back button in the top-leading corner; it closes the paywall.
    private var closeButtonView: some View {
        Button(action: {
            wrapperController?.dismiss(animated: true)
        }) {
            SGPayWallBackGlyph()
        }
        .accessibility(label: Text("Common.Close".i18n(lang)))
        .accessibility(hidden: showDetails)
        .disabled(showDetails)
        .opacity(showDetails ? 0.0 : 1.0)
        .padding(.top, max(16.0, closeButtonTopInset))
        .padding(.leading, max(16.0, sgLeftSafeAreaInset(containerViewLayout)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The hosting controller ignores the safe area so the background can bleed under the status
    /// bar, which leaves the close button to clear the status bar / Dynamic Island itself: a fixed
    /// 16 pt put its 44 pt target inside the status-bar region, where a tap did not dismiss. The
    /// controller's own layout carries the inset (`statusBarHeight` for a modal; `safeInsets` /
    /// `intrinsicInsets` otherwise), so take the largest.
    private var closeButtonTopInset: CGFloat {
        guard let layout = containerViewLayout else {
            return 0.0
        }
        return max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top + layout.intrinsicInsets.top)
    }

    // MARK: - Derived state

    private var selectedProduct: SGIAPProduct? {
        if let selectedProductId, let match = products.first(where: { $0.id == selectedProductId }) {
            return match
        }
        return defaultProduct
    }

    /// The yearly plan leads, because it is the one that is cheaper per month; the monthly plan is
    /// one tap away and is never hidden.
    private var defaultProduct: SGIAPProduct? {
        return products.first(where: { ($0.period?.months ?? 0) >= 12 }) ?? products.first
    }

    /// Does an App Store subscription actually exist?
    ///
    /// **`entitlementState.isUnlocked` does NOT answer this**, and reading it as if it did is the
    /// bug this property exists to prevent. Unlocked is also true while the monetization policy is
    /// free, during the paid-mode local grace and in a build that cannot enforce. In all of them the
    /// user has paid nothing. docs/entitlement.md §11.10 states the rule: do not read "unlocked" as
    /// "subscribed" anywhere in the UI.
    private var hasAppStoreSubscription: Bool {
        return SGIAP?.subscriptionStatus?.isActive ?? false
    }

    /// `hasAppStoreSubscription`, or — when StoreKit's detailed status is unknown, as it is while
    /// free (no product query) — the entitlement's manageable StoreKit snapshot up to its own
    /// effective expiry (`SGEntitlement.manageableStoreKitSnapshot`: this origin's, else a
    /// still-current one an earlier build left). Only for offering Apple's management page, never
    /// for selling.
    private var hasExistingAppStoreSubscription: Bool {
        if hasAppStoreSubscription {
            return true
        }
        guard SGIAP?.subscriptionStatus == nil, let snapshot = SGEntitlement.shared.manageableStoreKitSnapshot, snapshot.hasActiveSubscription else {
            return false
        }
        guard let expiration = snapshot.effectiveExpirationDate else {
            return true
        }
        return SGEntitlement.shared.entitlementClock.effectiveNow() < expiration
    }

    /// Plans are on screen whenever there is something to buy — which includes the grace and the
    /// dark rollout, and includes a live subscriber, so monthly ↔ yearly stays reachable. The only
    /// reason to hide them is that no purchase is possible at all (one product, StoreKit
    /// unavailable, products failed to load, iOS too old).
    private var showsPlanPicker: Bool {
        return products.count > 1 && canPurchase
    }

    private var planChange: SGIAPPlanChange {
        guard let SGIAP, let product = selectedProduct else {
            return .subscribe
        }
        return SGIAP.planChange(for: product.id)
    }

    private var primaryAction: PrimaryAction {
        if let product = selectedProduct, canPurchase {
            switch planChange {
            case .subscribe, .upgrade, .downgrade:
                return .buy(product.id)
            case .scheduled, .currentUntilRenewal:
                return .manageSubscription
            case .current:
                break
            }
        }
        // Reached only when nothing is purchasable. `isUnlocked` is the right question HERE: the
        // user does have the features right now, whatever is paying for them.
        if entitlementState.isUnlocked {
            return .openPro
        }
        return .unavailable
    }

    private var canPurchase: Bool {
        guard let SGIAP, paymentsEnabled, SGIAP.isPurchaseSupported, SGIAP.canMakePayments else {
            return false
        }
        if case .loaded = productsState {
            return selectedProduct != nil
        }
        return false
    }

    private var isPurchaseButtonEnabled: Bool {
        guard state == .ready else {
            return false
        }
        return primaryAction != .unavailable
    }

    /// Exactly one trial affordance is ever on screen, and ours only when the signed policy offers it.
    ///
    /// Our trial exists only while the accepted monetization policy is paid and names a non-zero
    /// `trial_days` (`SGPayWallOffer.serverTrialDays`): never from an unverified token, never while
    /// free, and never as purchase admission. Apple's introductory offer is carried by the PURCHASE
    /// button's own copy, which uses the "Start Free Trial" words — so when Apple is offering free
    /// days, ours steps aside. The two conditions are otherwise independent (`isServerTrialAvailable`
    /// reads only our ledger, `isEligibleForIntroOffer` only Apple's) and design §5.6 expects users
    /// eligible for both, which is exactly how two identically-labelled buttons ended up side by side
    /// — one of them enrolling a paid auto-renewing subscription. `isAppleIntroOfferAvailable` exists
    /// for this and was until now never read.
    private var isTrialButtonVisible: Bool {
        // Not `!isUnlocked`: the paid-mode local grace is an unlocked state in which a server trial
        // is still worth offering. Never while free (`SGPayWallOffer`).
        return offer.showsServerTrial(hasAppStoreSubscription: hasAppStoreSubscription, isServerTrialAvailable: trialAffordance.isServerTrialAvailable, isAppleIntroOfferAvailable: trialAffordance.isAppleIntroOfferAvailable)
    }

    /// The plural form of our trial's copy for the signed `days` (`trial_days` is 1…30): the
    /// `.One` / `.Few` / `.Many` key by `SGCustomerPlural` — en "1 day" / "N days", ru день / дня /
    /// дней, uz one form — the `DataConsent.Withdraw.Confirm.Unsent.*` convention (SGStrings has no
    /// plural API).
    private func serverTrialKey(_ base: String, days: Int) -> String {
        let form: String
        switch SGCustomerPlural.category(days, languageCode: lang) {
        case .one:
            form = "One"
        case .few:
            form = "Few"
        case .many:
            form = "Many"
        }
        return "\(base).\(form)"
    }

    /// Our trial button's title: "Try %@ days free" in the plural form of `days`.
    private func serverTrialButtonTitle(days: Int) -> String {
        return serverTrialKey("PayWall.ServerTrial.Button", days: days).i18n(lang, args: "\(days)")
    }

    /// The caption under our trial button, and its accessibility hint: the signed length, that the
    /// trial is Zenlygram's own and not an App Store offer (no payment details, nothing charged when
    /// it ends), and what a subscription is needed for afterwards. Not the Apple-intro caption
    /// (`purchaseCaption`'s "N days free, then %@"), which belongs to the purchase button and a
    /// StoreKit offer; the "link your account" case is `handleStartTrial`'s `.notLinked` notice.
    private func serverTrialDisclosure(days: Int) -> String {
        return serverTrialKey("PayWall.ServerTrial.Disclosure", days: days).i18n(lang, args: "\(days)")
    }

    /// Shown when nothing more urgent is: a paid transaction the server refused in a way no retry
    /// fixes. Pro is already unlocked locally — this asks for help, it does not sell anything.
    private var persistentNotice: SGPayWallNotice? {
        if SGIAP?.needsPurchaseHelp == true {
            return SGPayWallNotice(text: SGEntitlementMessage.purchaseNeedsHelp.localizationKey.i18n(lang), tone: .warning)
        }
        // Our trial's refusal explains why OUR trial button is missing — so it is shown only while the
        // signed policy offers a trial the ledger is the reason for hiding, and nothing else is on
        // offer in its place (`SGPayWallOffer.explainsServerTrialRefusal`): with no trial on offer the
        // button is absent for everyone and a remembered refusal explains nothing; next to Apple's own
        // "Start Free Trial" it reads as a contradiction of the button right under it; and while Pro
        // is unlocked there is nothing missing to explain.
        if let refusal = trialAffordance.serverTrialRefusal, offer.explainsServerTrialRefusal(hasAppStoreSubscription: hasAppStoreSubscription, isAppleIntroOfferAvailable: trialAffordance.isAppleIntroOfferAvailable, isUnlocked: entitlementState.isUnlocked) {
            return SGPayWallNotice(text: refusal.localizationKey.i18n(lang), tone: .info)
        }
        return nil
    }

    /// A purchase-flow failure as a notice. Another App Store operation that has not returned yet
    /// is a wait, not a fault, and gets the pending symbol; everything else needs attention.
    private func failureNotice(_ message: SGIAPMessage) -> SGPayWallNotice {
        let isWait = message == .storeOperationInProgress || message == .purchaseCheckBusy
        return SGPayWallNotice(text: message.localizationKey.i18n(lang), tone: isWait ? .pending : .warning)
    }

    private var buttonTitle: String {
        switch state {
        case .purchasing:
            return "PayWall.Button.Purchasing".i18n(lang)
        case .restoring:
            return "PayWall.Button.Restoring".i18n(lang)
        case .startingTrial:
            return "PayWall.Button.Validating".i18n(lang)
        case .ready:
            break
        }
        // The label comes from the same decision as the action. With nothing purchasable the
        // button opens Pro for an unlocked user (the grace, the dark rollout), and a label from
        // the StoreKit ladder below ("Contacting App Store…") would promise something else; the
        // reason nothing is purchasable moves to the caption instead.
        if case .openPro = primaryAction {
            return "PayWall.Button.OpenPro".i18n(lang)
        }
        if case .manageSubscription = primaryAction {
            return "PayWall.ManageSubscription".i18n(lang)
        }
        if let reason = purchaseUnavailableReason {
            return reason
        }
        guard let product = selectedProduct else {
            return "PayWall.Button.PaymentsUnavailable".i18n(lang)
        }
        switch planChange {
        case .current:
            // `.current` with an unlocked user is `.openPro`, handled above.
            return "PayWall.Button.CurrentPlan".i18n(lang)
        case .currentUntilRenewal, .scheduled:
            // `.manageSubscription`, handled above whenever a purchase is possible at all.
            return "PayWall.ManageSubscription".i18n(lang)
        case .upgrade:
            return "PayWall.Button.Upgrade".i18n(lang, args: product.displayPrice)
        case .downgrade:
            return "PayWall.Button.SwitchPlan".i18n(lang)
        case .subscribe:
            if hasFreeTrial(product) {
                return "PayWall.Button.StartTrial".i18n(lang)
            }
            // The button reads "Get Zenlygram Pro"; what it charges is on the selected plan row
            // and, as the billed amount with its own period, in the caption directly under it
            // (`purchaseCaption`, built from `periodPrice` — StoreKit's own period, never a
            // translation's guess at it). At the accessibility sizes that caption scrolls with the
            // content instead of staying under the button, so the button names the amount itself.
            if usesAccessibilityLayout {
                return "PayWall.Button.Subscribe".i18n(lang, args: periodPrice(product))
            }
            return "PayWall.Button.GoPro".i18n(lang)
        }
    }

    /// Why nothing can be bought right now, or nil when the App Store will sell the selected plan.
    private var purchaseUnavailableReason: String? {
        guard let SGIAP else {
            return "PayWall.Button.PaymentsUnavailable".i18n(lang)
        }
        guard SGIAP.isPurchaseSupported else {
            // StoreKit 2 needs iOS 15. Say so plainly instead of offering a button that cannot work;
            // everything the user already saved keeps working, because the gate is the entitlement.
            return "Common.UpdateOS".i18n(lang)
        }
        if !paymentsEnabled || !SGIAP.canMakePayments {
            return "PayWall.Button.PaymentsUnavailable".i18n(lang)
        }
        switch productsState {
        case .idle, .loading:
            return "PayWall.Button.ContactingAppStore".i18n(lang)
        case .failed:
            return "PayWall.Button.PaymentsUnavailable".i18n(lang)
        case .loaded:
            break
        }
        guard selectedProduct != nil else {
            return "PayWall.Button.PaymentsUnavailable".i18n(lang)
        }
        return nil
    }

    /// The line under the button: the trial's real length, the real price that follows it, or what a
    /// plan switch actually does — all of it out of StoreKit, none of it invented here.
    private var purchaseCaption: String? {
        if case .openPro = primaryAction, !canPurchase {
            // The button opens Pro; this line says why there is no plan to pick.
            if case let .failed(message) = productsState {
                return message.localizationKey.i18n(lang)
            }
            return purchaseUnavailableReason
        }
        guard let product = selectedProduct else {
            if case let .failed(message) = productsState {
                return message.localizationKey.i18n(lang)
            }
            return nil
        }
        switch planChange {
        case .current:
            guard let status = SGIAP?.subscriptionStatus, let expiry = status.expirationDate else {
                return nil
            }
            let date = localizedDateString(from: expiry)
            return (status.willAutoRenew ? "PayWall.Plan.Renews" : "PayWall.Plan.Ends").i18n(lang, args: date)
        case .currentUntilRenewal:
            // Not "Renews on …": what renews on that date is the OTHER plan.
            guard let status = SGIAP?.subscriptionStatus, let expiry = status.expirationDate, let queuedProductId = status.queuedRenewalProductId else {
                return "PayWall.Plan.DowngradeNotice".i18n(lang)
            }
            let queuedTitle = products.first(where: { $0.id == queuedProductId }).map({ periodTitle($0) }) ?? "PayWall.Plan.Other".i18n(lang)
            return "PayWall.Plan.ChangesAtRenewal".i18n(lang, args: localizedDateString(from: expiry), queuedTitle)
        case .scheduled:
            guard let expiry = SGIAP?.subscriptionStatus?.expirationDate else {
                return "PayWall.Plan.DowngradeNotice".i18n(lang)
            }
            return "PayWall.Plan.ScheduledNotice".i18n(lang, args: localizedDateString(from: expiry))
        case .downgrade:
            return "PayWall.Plan.DowngradeNotice".i18n(lang)
        case .upgrade:
            return "PayWall.Disclosure.Short".i18n(lang)
        case .subscribe:
            if hasFreeTrial(product), let days = trialDays(product) {
                return "PayWall.Trial.Notice".i18n(lang, args: "\(days)", periodPrice(product))
            }
            // The billed amount and its period, right under the button that charges it.
            return "PayWall.Disclosure.WithPrice".i18n(lang, args: periodPrice(product))
        }
    }

    /// Format a date using the user's selected app language, not the system locale. This ensures
    /// dates like "Oct 15" appear in Uzbek as "15 Okt" when the app is in Uzbek, even if the device
    /// system language is English. DateFormatter is cached per lang (low-frequency creation).
    private func localizedDateString(from date: Date) -> String {
        return Self.dateFormatter(for: lang).string(from: date)
    }

    private static var _dateFormatterCache: [String: DateFormatter] = [:]
    private static func dateFormatter(for lang: String) -> DateFormatter {
        if let cached = _dateFormatterCache[lang] { return cached }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: lang)
        _dateFormatterCache[lang] = formatter
        return formatter
    }

    private func hasFreeTrial(_ product: SGIAPProduct) -> Bool {
        return product.isEligibleForIntroOffer && (product.introductoryOffer?.isFreeTrial ?? false)
    }

    private func trialDays(_ product: SGIAPProduct) -> Int? {
        guard let offer = product.introductoryOffer, offer.isFreeTrial else {
            return nil
        }
        let perPeriod: Int
        switch offer.period.unit {
        case .day:
            perPeriod = offer.period.value
        case .week:
            perPeriod = offer.period.value * 7
        case .month:
            perPeriod = offer.period.value * 30
        case .year:
            perPeriod = offer.period.value * 365
        }
        return perPeriod * max(offer.periodCount, 1)
    }

    private func periodTitle(_ product: SGIAPProduct) -> String {
        switch product.period?.months {
        case .some(1):
            return "PayWall.Plan.Monthly".i18n(lang)
        case .some(12):
            return "PayWall.Plan.Yearly".i18n(lang)
        default:
            return "PayWall.Plan.Other".i18n(lang)
        }
    }

    private func periodPrice(_ product: SGIAPProduct) -> String {
        switch product.period?.months {
        case .some(1):
            return "PayWall.Plan.PerMonth".i18n(lang, args: product.displayPrice)
        case .some(12):
            return "PayWall.Plan.PerYear".i18n(lang, args: product.displayPrice)
        default:
            return product.displayPrice
        }
    }

    /// "Yearly" / "Monthly" as the plan row says it; any other period keeps the generic title.
    private func planRowTitle(_ product: SGIAPProduct) -> String {
        switch product.period?.months {
        case .some(1):
            return "PayWall.Plan.Monthly.Short".i18n(lang)
        case .some(12):
            return "PayWall.Plan.Yearly.Short".i18n(lang)
        default:
            return periodTitle(product)
        }
    }

    /// The line under a multi-month plan's title: its length and what it comes to per month
    /// ("12 months • 1.25 US$/mo"), in the footnote style under the billed amount, which stays the
    /// row's most prominent price (guideline 3.1.2). StoreKit formats the per-month figure; we never
    /// divide a price ourselves. A monthly plan, or one StoreKit gives no per-month figure for, has
    /// no summary.
    private func planRowSummary(_ product: SGIAPProduct) -> String? {
        guard let months = product.period?.months, months > 1, let perMonth = product.displayPricePerMonth else {
            return nil
        }
        return "PayWall.Plan.Summary".i18n(lang, args: "\(months)", "PayWall.Plan.PerMonth.Compact".i18n(lang, args: perMonth))
    }

    /// The trailing price of a plan row: the amount Apple bills, with its period ("29.99 US$/yr",
    /// "3.99 US$/mo"). Guideline 3.1.2 requires the billed amount to be the most prominent price; the
    /// per-month comparison is the summary line under the title.
    private func planRowPrice(_ product: SGIAPProduct) -> String {
        switch product.period?.months {
        case .some(1):
            return "PayWall.Plan.PerMonth.Compact".i18n(lang, args: product.displayPrice)
        case .some(12):
            return "PayWall.Plan.PerYear.Compact".i18n(lang, args: product.displayPrice)
        default:
            return periodPrice(product)
        }
    }

    /// "7 days free" beats "Save 37%" on the card, because it is the offer the user actually gets.
    /// While a plan change is queued, both cards say which is which instead: the one running now and
    /// the one that takes over at renewal.
    private func badge(for product: SGIAPProduct) -> String? {
        switch SGIAP?.planChange(for: product.id) {
        case .current:
            // The active plan shows "Current" even when no change is queued.
            return "PayWall.Plan.Badge.Current".i18n(lang)
        case .currentUntilRenewal:
            return "PayWall.Plan.Badge.Current".i18n(lang)
        case .scheduled:
            return "PayWall.Plan.Badge.Scheduled".i18n(lang)
        default:
            break
        }
        if hasFreeTrial(product), let days = trialDays(product) {
            return "PayWall.Plan.Trial".i18n(lang, args: "\(days)")
        }
        guard let months = product.period?.months, months > 1,
              let monthly = products.first(where: { $0.period?.months == 1 })
        else {
            return nil
        }
        let comparable = NSDecimalNumber(decimal: monthly.price).doubleValue * Double(months)
        let actual = NSDecimalNumber(decimal: product.price).doubleValue
        guard comparable > 0.0, actual < comparable else {
            return nil
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        guard let saving = formatter.string(from: NSNumber(value: 1.0 - actual / comparable)) else {
            return nil
        }
        return "PayWall.Plan.Discount".i18n(lang, args: saving)
    }

    // MARK: - Actions

    /// This sheet renders the active account's entitlement but attributes operations to the account
    /// captured when it opened. Close it when those diverge, including while a StoreKit sheet is up.
    /// Already-started purchases still finish for their original account in SGIAP.
    @discardableResult
    private func ensureCurrentAccount() -> Bool {
        guard !accountWasInvalidated else {
            return false
        }
        guard accountPeerId == SGEntitlement.shared.activeAccountPeerId else {
            accountWasInvalidated = true
            showConfetti = false
            wrapperController?.dismiss(animated: true)
            return false
        }
        return true
    }

    private func showDetailsForFeature(_ featureId: SGProFeatureId) {
        if #available(iOS 14.0, *) {
            shownFeature = featureId
            showDetails = true
        } // pagination is not available on iOS 13
    }

    private func dismissDetails() {
        showDetails = false
    }

    /// A user whose degraded copy says "link your Telegram account" must always have a way to do it
    /// from here; the caller opens the link screen for this paywall's account.
    private func presentLinkTelegramAccount() {
        guard ensureCurrentAccount() else {
            return
        }
        openLinkTelegramAccount()
    }

    private func refreshLocalState() {
        guard ensureCurrentAccount() else {
            return
        }
        if let accountPeerId {
            isLinked = SGEntitlement.shared.isLinked(accountPeerId: accountPeerId)
        } else {
            isLinked = false
        }
        guard let SGIAP else {
            return
        }
        products = SGIAP.availableProducts
        productsState = SGIAP.productsState
        trialAffordance = SGIAP.trialAffordance(accountPeerId: accountPeerId)
        if selectedProductId == nil {
            selectedProductId = defaultProduct?.id
        }
    }

    /// Products are loaded when the paywall opens, never at launch.
    private func loadProducts() {
        guard ensureCurrentAccount() else {
            return
        }
        guard let SGIAP else {
            productsState = .failed(.temporarilyUnavailable)
            return
        }
        if case .loading = SGIAP.productsState {
            return
        }
        productsState = .loading
        Task { @MainActor in
            guard ensureCurrentAccount() else {
                return
            }
            _ = await SGIAP.loadProducts()
            refreshLocalState()
        }
    }

    private func handlePrimaryAction() {
        guard ensureCurrentAccount() else {
            return
        }
        switch primaryAction {
        case let .buy(productId):
            buy(productId: productId)
        case .manageSubscription:
            openUrl(manageSubscriptionsUrl, true)
        case .openPro:
            openProFeatures?()
            wrapperController?.dismiss(animated: true)
        case .unavailable:
            break
        }
    }

    private func buy(productId: String) {
        guard ensureCurrentAccount(), let SGIAP, state == .ready else {
            return
        }
        inlineNotice = nil
        state = .purchasing
        Task { @MainActor in
            guard ensureCurrentAccount() else {
                return
            }
            // The paywall's own account, fixed when it was built — never the active one, which can
            // change while the App Store sheet is up.
            let product = products.first(where: { $0.id == productId })
            if let event = SGPayWallFunnel.purchaseStartEvent(productId: productId) {
                SGAnalytics.record(event, accountPeerId: accountPeerId)
            }
            let result = await SGIAP.purchase(productId: productId, accountPeerId: accountPeerId)
            // Recorded for the paywall's account whatever happened to the screen meanwhile.
            let step = SGPayWallFunnel.purchaseStep(result, trial: product.map { hasFreeTrial($0) } ?? false)
            if let event = SGPayWallFunnel.purchaseEvent(step, productId: productId) {
                SGAnalytics.record(event, accountPeerId: accountPeerId)
            }
            if let code = SGPayWallFunnel.purchaseError(step) {
                SGAnalytics.error(.purchase, code, accountPeerId: accountPeerId)
            }
            guard ensureCurrentAccount() else {
                return
            }
            state = .ready
            switch result {
            case .purchased:
                // The confetti is fired by the entitlement change, so a purchase that only the local
                // StoreKit snapshot knows about still counts.
                inlineNotice = nil
            case .purchasedNeedsHelp:
                // Paid, StoreKit-verified, and already unlocked locally from the snapshot — only our
                // server has not confirmed it. Do NOT dress that up as a failed purchase: the money
                // moved, Pro works, and `persistentNotice` raises it only if the local unlock stops
                // carrying them. Every App Review purchase lands here (a Sandbox transaction against
                // a Production-only server), and "we couldn't confirm your purchase" right after a
                // charge is the wrong sentence in the wrong place.
                inlineNotice = nil
            case .pending:
                inlineNotice = SGPayWallNotice(text: SGIAPMessage.purchasePending.localizationKey.i18n(lang), tone: .pending)
            case .cancelled:
                inlineNotice = nil
            case let .failed(message):
                inlineNotice = failureNotice(message)
            }
            refreshLocalState()
        }
    }

    private func handleRestorePurchases() {
        guard ensureCurrentAccount(), let SGIAP, state == .ready else {
            return
        }
        inlineNotice = nil
        state = .restoring
        Task { @MainActor in
            guard ensureCurrentAccount() else {
                return
            }
            let result = await SGIAP.restore(accountPeerId: accountPeerId)
            if let event = SGPayWallFunnel.restoreEvent(result) {
                SGAnalytics.record(event, accountPeerId: accountPeerId)
            }
            guard ensureCurrentAccount() else {
                return
            }
            state = .ready
            switch result {
            case .restored:
                inlineNotice = SGPayWallNotice(text: SGIAPMessage.restoreCompleted.localizationKey.i18n(lang), tone: .success)
            case .nothingToRestore:
                inlineNotice = SGPayWallNotice(text: SGIAPMessage.nothingToRestore.localizationKey.i18n(lang), tone: .info)
            case .cancelled:
                inlineNotice = nil
            case let .failed(message):
                inlineNotice = failureNotice(message)
            }
            refreshLocalState()
        }
    }

    private func handleStartTrial() {
        guard ensureCurrentAccount(), let SGIAP, state == .ready else {
            return
        }
        inlineNotice = nil
        state = .startingTrial
        Task { @MainActor in
            guard ensureCurrentAccount() else {
                return
            }
            let result = await SGIAP.startServerTrial(accountPeerId: accountPeerId)
            SGAnalytics.record(SGPayWallFunnel.trialEvent(result), accountPeerId: accountPeerId)
            guard ensureCurrentAccount() else {
                return
            }
            state = .ready
            switch result {
            case .started:
                inlineNotice = nil
            case let .refused(message):
                // A refusal is shown next to the purchase options and takes the affordance away. It
                // is never a dead end: the plans stay exactly where they were.
                inlineNotice = SGPayWallNotice(text: message.localizationKey.i18n(lang), tone: .info)
            case .notLinked:
                inlineNotice = SGPayWallNotice(text: SGEntitlementMessage.notLinked.localizationKey.i18n(lang), tone: .info)
            case let .failed(message):
                inlineNotice = failureNotice(message)
            }
            refreshLocalState()
        }
    }

    private func celebrate() {
        DispatchQueue.main.async {
            guard ensureCurrentAccount() else {
                return
            }
            hapticFeedback?.success()
            showConfetti = true
            DispatchQueue.main.asyncAfter(deadline: .now() + confettiDuration + 1.0) {
                showConfetti = false
            }
        }
    }
}



// Confetti

struct ConfettiType {
    let color: Color
    let shape: ConfettiShape

    static func random() -> ConfettiType {
        let colors: [Color] = [.red, .blue, .green, .yellow, .pink, .purple, .orange]
        return ConfettiType(
            color: colors.randomElement() ?? .blue,
            shape: ConfettiShape.allCases.randomElement() ?? .circle
        )
    }
}


enum ConfettiShape: CaseIterable {
    case circle
    case triangle
    case square
    case slimRectangle
    case roundedCross

    @ViewBuilder
    func view(color: Color) -> some View {
        switch self {
        case .circle:
            Circle().fill(color)
        case .triangle:
            Triangle().fill(color)
        case .square:
            Rectangle().fill(color)
        case .slimRectangle:
            SlimRectangle().fill(color)
        case .roundedCross:
            RoundedCross().fill(color)
        }
    }
}


struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}


public struct SlimRectangle: Shape {
    public func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: 4*rect.maxY/5))
        path.addLine(to: CGPoint(x: rect.maxX, y: 4*rect.maxY/5))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

        return path
    }
}


public struct RoundedCross: Shape {
    public func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY/3))
        path.addQuadCurve(to: CGPoint(x: rect.maxX/3, y: rect.minY), control: CGPoint(x: rect.maxX/3, y: rect.maxY/3))
        path.addLine(to: CGPoint(x: 2*rect.maxX/3, y: rect.minY))

        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY/3), control: CGPoint(x: 2*rect.maxX/3, y: rect.maxY/3))
        path.addLine(to: CGPoint(x: rect.maxX, y: 2*rect.maxY/3))

        path.addQuadCurve(to: CGPoint(x: 2*rect.maxX/3, y: rect.maxY), control: CGPoint(x: 2*rect.maxX/3, y: 2*rect.maxY/3))
        path.addLine(to: CGPoint(x: rect.maxX/3, y: rect.maxY))

        path.addQuadCurve(to: CGPoint(x: 2*rect.minX/3, y: 2*rect.maxY/3), control: CGPoint(x: rect.maxX/3, y: 2*rect.maxY/3))

        return path
    }
}


struct ConfettiModifier: ViewModifier {
    @Binding var isActive: Bool
    let duration: Double

    func body(content: Content) -> some View {
        // Zenlygram — iPad: the pieces are spread over the view's own size, not `UIScreen.main.bounds`,
        // which in Split View, Slide Over or Stage Manager is wider and taller than this window.
        content.overlay(
            GeometryReader { proxy in
                ZStack {
                    if isActive {
                        ForEach(0..<70) { _ in
                            ConfettiPiece(
                                confettiType: .random(),
                                duration: duration,
                                containerSize: proxy.size
                            )
                        }
                    }
                }
            }
        )
    }
}


struct ConfettiPiece: View {
    let confettiType: ConfettiType
    let duration: Double
    let containerSize: CGSize

    @State private var isAnimating = false
    @State private var rotation = Double.random(in: 0...1080)
    /// Fixed per piece, so a relayout (rotation, window resize) rescales it instead of re-rolling it.
    @State private var horizontalFraction = CGFloat.random(in: 0...1)

    var body: some View {
        confettiType.shape.view(color: confettiType.color)
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(rotation))
            .position(
                x: horizontalFraction * containerSize.width,
                y: 0 //-20
            )
            .modifier(FallingModifier(distance: containerSize.height + 20, duration: duration))
            .opacity(isAnimating ? 0 : 1)
            .onAppear {
                withAnimation(.linear(duration: duration)) {
                    isAnimating = true
                }
            }
    }
}


struct FallingModifier: ViewModifier {
    let distance: CGFloat
    let duration: Double

    func body(content: Content) -> some View {
        content.modifier(
            MoveModifier(
                offset: CGSize(
                    width: .random(in: -100...100),
                    height: distance
                ),
                duration: duration
            )
        )
    }
}


struct MoveModifier: ViewModifier {
    let offset: CGSize
    let duration: Double

    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content.offset(
            x: isAnimating ? offset.width : 0,
            y: isAnimating ? offset.height : 0
        )
        .onAppear {
            withAnimation(
                .linear(duration: duration)
                .speed(.random(in: 0.5...2.5))
            ) {
                isAnimating = true
            }
        }
    }
}

// Extension to make it easier to use

extension View {
    func confetti(isActive: Binding<Bool>, duration: Double = 2.0) -> some View {
        modifier(ConfettiModifier(isActive: isActive, duration: duration))
    }
}
