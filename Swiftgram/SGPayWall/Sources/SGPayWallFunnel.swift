import Foundation
import SGCustomerSyncCore
import SGEntitlement
import SGIAP

// MARK: Zenlygram — the paywall's and the Link screen's analytics, decided purely (design 40 §10.2).
//
// The screens only call these and hand the result to `SGAnalytics`; every mapping from a StoreKit,
// trial, restore or bind outcome to a contract value lives here, so it is tested on the macOS host
// (Tests/run-funnel-tests.sh) without a screen. No event carries a free string: product ids and
// error codes go through the core's validating types, and an id that does not validate drops the
// event instead of sending something else.

/// The paywall's purchase funnel (`pro.*`, contract §3.2).
enum SGPayWallFunnel {
    /// Where one `SGIAP.purchase` ended, as `pro.purchase_success` / `pro.purchase_fail` say it.
    enum PurchaseStep: Equatable {
        case success(trial: Bool)
        case fail(reason: SGAnalyticsPurchaseFailReason, errorCode: SGAnalyticsErrorCode?)
    }

    /// Every purchase result has a step: `.purchasedNeedsHelp` is a purchase (the money moved and Pro
    /// is unlocked locally), a pending Ask to Buy is not yet one.
    static func purchaseStep(_ result: SGIAPPurchaseResult, trial: Bool) -> PurchaseStep {
        switch result {
        case .purchased, .purchasedNeedsHelp:
            return .success(trial: trial)
        case .pending:
            return .fail(reason: .pending, errorCode: nil)
        case .cancelled:
            return .fail(reason: .cancelled, errorCode: nil)
        case .failed(.paymentsUnavailable):
            return .fail(reason: .notAllowed, errorCode: nil)
        case .failed(.productsUnavailable), .failed(.subscriptionsNotOffered):
            return .fail(reason: .unavailable, errorCode: nil)
        case .failed(.noConnection):
            return .fail(reason: .failed, errorCode: .offline)
        case .failed:
            return .fail(reason: .failed, errorCode: nil)
        }
    }

    /// `pro.plan_select`; nil for a product id the contract would refuse.
    static func planSelectEvent(productId: String) -> SGAnalyticsEvent? {
        guard let product = SGAnalyticsProductId(productId) else {
            return nil
        }
        return .proPlanSelect(productId: product, rail: .apple, basePlanId: nil)
    }

    /// `pro.purchase_start`, recorded before `SGIAP.purchase`.
    static func purchaseStartEvent(productId: String) -> SGAnalyticsEvent? {
        guard let product = SGAnalyticsProductId(productId) else {
            return nil
        }
        return .proPurchaseStart(productId: product, rail: .apple, basePlanId: nil)
    }

    /// `pro.purchase_success` / `pro.purchase_fail` for a step.
    static func purchaseEvent(_ step: PurchaseStep, productId: String) -> SGAnalyticsEvent? {
        guard let product = SGAnalyticsProductId(productId) else {
            return nil
        }
        switch step {
        case let .success(trial):
            return .proPurchaseSuccess(productId: product, rail: .apple, basePlanId: nil, trial: trial)
        case let .fail(reason, errorCode):
            return .proPurchaseFail(productId: product, rail: .apple, basePlanId: nil, reason: reason, errorCode: errorCode)
        }
    }

    /// The `error.occurred{domain: purchase}` a step adds, aggregated by the pipeline: only a real
    /// failure — a cancel, Ask to Buy, a refused or unavailable store is not an error.
    static func purchaseError(_ step: PurchaseStep) -> SGAnalyticsErrorCode? {
        guard case let .fail(reason, errorCode) = step, reason == .failed else {
            return nil
        }
        return errorCode ?? .unknown
    }

    /// `pro.restore`; nil for a dismissed password prompt (the user did nothing).
    static func restoreEvent(_ result: SGIAPRestoreResult) -> SGAnalyticsEvent? {
        switch result {
        case .restored:
            return .proRestore(rail: .apple, outcome: .restored, errorCode: nil)
        case .nothingToRestore:
            return .proRestore(rail: .apple, outcome: .nothing, errorCode: nil)
        case .cancelled:
            return nil
        case let .failed(message):
            return .proRestore(rail: .apple, outcome: .failed, errorCode: SGPayWallFunnel.errorCode(message))
        }
    }

    /// `pro.trial_start` (our own trial, `/v1/trial/start`).
    static func trialEvent(_ result: SGIAPTrialResult) -> SGAnalyticsEvent {
        switch result {
        case .started:
            return .proTrialStart(outcome: .started, errorCode: nil)
        case .refused, .notLinked:
            return .proTrialStart(outcome: .refused, errorCode: nil)
        case let .failed(message):
            return .proTrialStart(outcome: .failed, errorCode: SGPayWallFunnel.errorCode(message))
        }
    }

    /// `pro.screen_view`'s `mode`: the monetization mode the screen opened under.
    static func proMode(_ mode: SGEntitlementPolicyMode) -> SGAnalyticsProMode {
        switch mode {
        case .free:
            return .free
        case .paid:
            return .paid
        }
    }

    /// Only a transport failure has a code of its own; the rest is the outcome alone.
    private static func errorCode(_ message: SGIAPMessage) -> SGAnalyticsErrorCode? {
        if case .noConnection = message {
            return .offline
        }
        return nil
    }

    // MARK: - The Link row's notice

    /// The Link row's detail line: in `required` consent mode an account is linked automatically
    /// after its consent, so "optional" would be untrue there.
    static func linkNoticeKey(consentRequired: Bool) -> String {
        return consentRequired ? "PayWall.LinkAccount.Notice.Required" : "PayWall.LinkAccount.Notice"
    }

    /// Whether this build runs the customer-data pipeline in `required` consent mode, read like
    /// `SGCustomerSyncConfig.consentKeys` reads `sg_config.consent_mode`: absent or mistyped is
    /// `required`; a string other than the two values leaves the pipeline failed (no automatic
    /// link), so it is not `required` here. `sgConfigJSON` is only read when the pipeline is active.
    static func consentRequired(pipelineActive: Bool, sgConfigJSON: () -> String?) -> Bool {
        guard pipelineActive else {
            return false
        }
        guard let text = sgConfigJSON(), let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [])) as? [String: Any] else {
            return true
        }
        guard let mode = object["consent_mode"] as? String else {
            return true
        }
        return mode == "required"
    }
}

/// The manual Link screen's rules (design 40 §8.2, §10.2): when it may attest, and its
/// `link.attempt{trigger: manual}`.
enum SGLinkAccountFunnel {
    /// Why a manual attempt failed without a server error to name it.
    enum FailureReason: Equatable {
        case declined
        case codeExpired
        case didNotGoThrough
        case temporarilyUnavailable
        case request(SGEntitlementRequestError)
    }

    /// The automatic Telegram attestation runs only for an account that may link with it: a
    /// usable grant (`.allowed`). `.codeOnly` and `.refused` never call `requestMainWebView`; the
    /// code flow is all the screen offers then.
    static func mayAttest(permission: SGEntitlementBindPermission) -> Bool {
        return permission == .allowed
    }

    /// `link.attempt{trigger: manual}`. `attested` = the server confirmed this attempt's start from
    /// Telegram's `initData` (`attest`), else the code (`code`); `duration` from `begin()`.
    static func attemptEvent(attested: Bool, failure: FailureReason?, duration: TimeInterval?) -> SGAnalyticsEvent {
        let durationS = duration.map { max(0, Int($0.rounded())) }
        return .linkAttempt(
            trigger: .manual,
            method: attested ? .attest : .code,
            outcome: failure == nil ? .success : .failed,
            errorCode: failure.map(SGLinkAccountFunnel.errorCode),
            durationS: durationS
        )
    }

    /// The attempt's `error_code`: the server's stable code when it sent one, `offline` for a
    /// transport failure, a poll's own answer, else `unknown`.
    static func errorCode(_ failure: FailureReason) -> SGAnalyticsErrorCode {
        switch failure {
        case .declined:
            return SGAnalyticsErrorCode.backend("bind_denied")
        case .codeExpired:
            return SGAnalyticsErrorCode.backend("bind_expired")
        case .didNotGoThrough, .temporarilyUnavailable:
            return .unknown
        case let .request(error):
            if let code = error.code {
                return SGAnalyticsErrorCode.backend(code)
            }
            if case .offline = error.failure, error.status == nil {
                return .offline
            }
            if case let .unknownRefusal(code, _) = error.failure {
                return SGAnalyticsErrorCode.backend(code)
            }
            if let status = error.status {
                return SGAnalyticsErrorCode.http(status)
            }
            return .unknown
        }
    }
}
