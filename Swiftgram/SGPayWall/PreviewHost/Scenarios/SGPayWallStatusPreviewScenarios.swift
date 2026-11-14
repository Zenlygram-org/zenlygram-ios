import Foundation
import SwiftUI
import UIKit
import SGEntitlement
import SGSwiftUI

// MARK: Zenlygram — TEST-ONLY synthetic scenarios for the status screen's real renderer.
//
// Compiled ONLY into `SGPayWallStatusPreviewLib` (Swiftgram/SGPayWall/BUILD) together with the
// unchanged `Sources/`, never into the app. Each scenario is a plain `SGProStatusInputs` value fed to
// the production decisions (`SGProStatusScreen`, `SGProStatusRestoreFlow`) and rendered by the
// production `SGEntitlementStatusContent`. Nothing here creates `SGEntitlement.shared` or an
// `SGIAPManager`, touches StoreKit, the Keychain, the network or any persistence; taps only call
// the host's `onAction` callback. There are no prices anywhere: the status screen shows none.

// The case list and the fixed clock live in `SGPayWallStatusPreviewCatalog.swift` (Foundation only),
// which the UI test bundle compiles too, so the tests launch exactly these scenarios.
extension SGPayWallStatusPreviewScenario {
    private static func days(_ count: Double) -> Date {
        return referenceNow.addingTimeInterval(count * 86_400)
    }

    private static func make(
        active: Bool = true,
        unlocked: Bool,
        source: SGProStatusAccessSource = .none,
        degradation: SGProStatusDegradation? = nil,
        grace: Date? = nil,
        tokenUntil: Date? = nil,
        apple: SGProStatusAppleState? = nil,
        snapshot: Bool? = false,
        snapshotUntil: Date? = nil,
        linked: Bool = false,
        monetization: SGProMonetization = .paid
    ) -> SGProStatusInputs {
        return SGProStatusInputs(
            screenAccountIsActive: active,
            isUnlocked: unlocked,
            source: source,
            degradation: degradation,
            localGraceEndsAt: grace,
            tokenUntil: tokenUntil,
            appleState: apple,
            snapshotHasActiveSubscription: snapshot,
            snapshotExpiration: snapshotUntil,
            isLinked: linked,
            monetization: monetization,
            now: referenceNow
        )
    }

    var inputs: SGProStatusInputs {
        switch self {
        case .notSubscribed, .restoreRunning, .restoreNothing, .restoreInProgressElsewhere, .restoreFailed:
            return Self.make(unlocked: false, degradation: .noAccess)
        case .localGrace:
            return Self.make(unlocked: true, source: .localGrace, grace: Self.days(5))
        case .tokenAccess:
            // A server horizon with no App Store purchase behind it: a trial, a grant or the dark
            // rollout look exactly like this. Access, never "paid".
            return Self.make(unlocked: true, source: .token, tokenUntil: Self.days(30), linked: true)
        case .appStoreRenews:
            return Self.make(unlocked: true, source: .token, tokenUntil: Self.days(30), apple: .live(expiration: Self.days(30), willAutoRenew: true), snapshot: true, linked: true)
        case .appStoreEnds:
            return Self.make(unlocked: true, source: .token, tokenUntil: Self.days(12), apple: .live(expiration: Self.days(12), willAutoRenew: false), snapshot: true, linked: true)
        case .appStoreBillingRetry:
            return Self.make(unlocked: false, degradation: .lapsed, apple: .billingRetry, linked: true)
        case .viaAppStoreSnapshot, .restoreRestored:
            return Self.make(unlocked: true, source: .storeKit, snapshot: true, snapshotUntil: Self.days(20))
        case .unconfiguredBuild:
            return Self.make(unlocked: true, source: .unconfigured, snapshot: nil)
        case .lapsed:
            return Self.make(unlocked: false, degradation: .lapsed, linked: true)
        case .reconnect:
            return Self.make(unlocked: false, degradation: .reconnect, linked: true)
        case .otherAccount:
            return Self.make(active: false, unlocked: true, source: .token, tokenUntil: Self.days(30), apple: .live(expiration: Self.days(30), willAutoRenew: true), snapshot: true, linked: true)
        case .freeAccess, .freeRestoreNothing:
            // The grace record would still be counting down; free mode must not show it.
            return Self.make(unlocked: true, source: .freeAccess, grace: Self.days(5), snapshot: nil, monetization: .free)
        case .freeAppStoreRenews:
            return Self.make(unlocked: true, source: .freeAccess, tokenUntil: Self.days(30), apple: .live(expiration: Self.days(30), willAutoRenew: true), snapshot: true, linked: true, monetization: .free)
        case .freeAppStoreEnds:
            return Self.make(unlocked: true, source: .freeAccess, apple: .live(expiration: Self.days(12), willAutoRenew: false), snapshot: true, linked: true, monetization: .free)
        }
    }

    /// The restore phase, reached by driving the production reducer exactly as the live container
    /// does — not by constructing the phase directly.
    var restorePhase: SGProStatusRestorePhase {
        let outcome: SGProStatusRestoreOutcome?
        switch self {
        case .restoreRunning:
            outcome = nil
        case .restoreRestored:
            outcome = .restored
        case .restoreNothing, .freeRestoreNothing:
            outcome = .nothingToRestore
        case .restoreInProgressElsewhere:
            outcome = .anotherOperationInProgress
        case .restoreFailed:
            outcome = .failed(messageKey: SGEntitlementMessage.noConnection.localizationKey)
        default:
            return .idle
        }
        var flow = SGProStatusRestoreFlow()
        guard let attempt = flow.begin(screenAccountIsActive: true, isAvailable: true) else {
            return .idle
        }
        if let outcome {
            _ = flow.finish(outcome, attempt: attempt, screenAccountIsActive: true)
        }
        return flow.phase
    }

    /// The live container passes the degraded reason only for the active account.
    var degradedReason: SGEntitlementDegradedReason? {
        switch self {
        case .notSubscribed, .restoreRunning, .restoreNothing, .restoreInProgressElsewhere, .restoreFailed:
            return .noToken
        case .lapsed, .appStoreBillingRetry:
            return .lapsed
        case .reconnect:
            return .stale
        default:
            return nil
        }
    }

    var screen: SGProStatusScreen {
        return SGProStatusScreen(inputs: self.inputs, restorePhase: self.restorePhase, isRestoreAvailable: true)
    }
}

/// The production status content for `scenario`, in `lang`. `onAction` receives "paywall",
/// "restore", "link" or "manage" when the matching control is tapped; nothing else happens.
public func sgPayWallStatusPreviewController(scenario: SGPayWallStatusPreviewScenario, lang: String, onAction: @escaping (String) -> Void) -> UIViewController {
    let content = SGEntitlementStatusContent(
        screen: scenario.screen,
        degradedReason: scenario.degradedReason,
        degradedMessage: scenario.degradedReason.map { SGEntitlementMessage.forDegraded($0) },
        actions: SGEntitlementStatusActions(
            openPayWall: { onAction("paywall") },
            restore: { onAction("restore") },
            openLinkAccount: { onAction("link") },
            openManageSubscription: { onAction("manage") }
        )
    )
    let controller = UIHostingController(rootView: content.environment(\.lang, lang))
    controller.title = "\(scenario.rawValue) · \(lang)"
    return controller
}
