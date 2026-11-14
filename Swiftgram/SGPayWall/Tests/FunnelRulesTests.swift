import Foundation
import SGCustomerSyncCore
import SGEntitlement
import SGIAP

/// Zenlygram — `SGPayWallFunnel` / `SGLinkAccountFunnel` (design 40 §10.2): the purchase-funnel
/// mapping, restore, trial, the Link screen's attest gate and its `link.attempt`, and the Link row's
/// required-mode notice. Run by run-funnel-tests.sh on the macOS host.
@main
struct FunnelRulesTests {
    private static func check(_ condition: Bool, _ message: String = "Assertion failed", line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    static func main() {
        purchaseSteps()
        purchaseEvents()
        purchaseErrors()
        restoreEvents()
        trialEvents()
        proMode()
        attestGate()
        linkAttempts()
        linkErrorCodes()
        linkNotice()
        print("FunnelRulesTests: OK")
    }

    private static func purchaseSteps() {
        check(SGPayWallFunnel.purchaseStep(.purchased, trial: true) == .success(trial: true))
        check(SGPayWallFunnel.purchaseStep(.purchased, trial: false) == .success(trial: false))
        check(SGPayWallFunnel.purchaseStep(.purchasedNeedsHelp, trial: false) == .success(trial: false), "a purchase the server has not confirmed is still a purchase")
        check(SGPayWallFunnel.purchaseStep(.pending, trial: true) == .fail(reason: .pending, errorCode: nil))
        check(SGPayWallFunnel.purchaseStep(.cancelled, trial: false) == .fail(reason: .cancelled, errorCode: nil))
        check(SGPayWallFunnel.purchaseStep(.failed(.paymentsUnavailable), trial: false) == .fail(reason: .notAllowed, errorCode: nil))
        check(SGPayWallFunnel.purchaseStep(.failed(.productsUnavailable), trial: false) == .fail(reason: .unavailable, errorCode: nil))
        check(SGPayWallFunnel.purchaseStep(.failed(.subscriptionsNotOffered), trial: false) == .fail(reason: .unavailable, errorCode: nil))
        check(SGPayWallFunnel.purchaseStep(.failed(.noConnection), trial: false) == .fail(reason: .failed, errorCode: .offline))
        for message: SGIAPMessage in [.requiresNewerOS, .storeOperationInProgress, .temporarilyUnavailable, .purchaseCheckFailed, .purchaseCheckBusy, .entitlement(.temporarilyUnavailable)] {
            check(SGPayWallFunnel.purchaseStep(.failed(message), trial: false) == .fail(reason: .failed, errorCode: nil), "\(message)")
        }
    }

    private static func purchaseEvents() {
        let id = "org.zenlygram.pro.monthly"
        guard let product = SGAnalyticsProductId(id) else {
            check(false, "product id")
            return
        }
        check(SGPayWallFunnel.planSelectEvent(productId: id) == .proPlanSelect(productId: product, rail: .apple, basePlanId: nil))
        check(SGPayWallFunnel.purchaseStartEvent(productId: id) == .proPurchaseStart(productId: product, rail: .apple, basePlanId: nil))
        check(SGPayWallFunnel.purchaseEvent(.success(trial: true), productId: id) == .proPurchaseSuccess(productId: product, rail: .apple, basePlanId: nil, trial: true))
        check(SGPayWallFunnel.purchaseEvent(.fail(reason: .failed, errorCode: .offline), productId: id) == .proPurchaseFail(productId: product, rail: .apple, basePlanId: nil, reason: .failed, errorCode: .offline))
        // A product id the contract refuses drops the event; nothing else is sent in its place.
        check(SGPayWallFunnel.planSelectEvent(productId: "bad id with spaces") == nil)
        check(SGPayWallFunnel.purchaseStartEvent(productId: "") == nil)
        check(SGPayWallFunnel.purchaseEvent(.success(trial: false), productId: String(repeating: "a", count: 101)) == nil)
    }

    private static func purchaseErrors() {
        check(SGPayWallFunnel.purchaseError(.success(trial: false)) == nil)
        check(SGPayWallFunnel.purchaseError(.fail(reason: .cancelled, errorCode: nil)) == nil)
        check(SGPayWallFunnel.purchaseError(.fail(reason: .pending, errorCode: nil)) == nil)
        check(SGPayWallFunnel.purchaseError(.fail(reason: .notAllowed, errorCode: nil)) == nil)
        check(SGPayWallFunnel.purchaseError(.fail(reason: .unavailable, errorCode: nil)) == nil)
        check(SGPayWallFunnel.purchaseError(.fail(reason: .failed, errorCode: .offline)) == .offline)
        check(SGPayWallFunnel.purchaseError(.fail(reason: .failed, errorCode: nil)) == .unknown)
    }

    private static func restoreEvents() {
        check(SGPayWallFunnel.restoreEvent(.restored) == .proRestore(rail: .apple, outcome: .restored, errorCode: nil))
        check(SGPayWallFunnel.restoreEvent(.nothingToRestore) == .proRestore(rail: .apple, outcome: .nothing, errorCode: nil))
        check(SGPayWallFunnel.restoreEvent(.cancelled) == nil, "a dismissed password prompt records nothing")
        check(SGPayWallFunnel.restoreEvent(.failed(.noConnection)) == .proRestore(rail: .apple, outcome: .failed, errorCode: .offline))
        check(SGPayWallFunnel.restoreEvent(.failed(.storeOperationInProgress)) == .proRestore(rail: .apple, outcome: .failed, errorCode: nil))
    }

    private static func trialEvents() {
        check(SGPayWallFunnel.trialEvent(.started(endsAt: nil)) == .proTrialStart(outcome: .started, errorCode: nil))
        check(SGPayWallFunnel.trialEvent(.refused(.temporarilyUnavailable)) == .proTrialStart(outcome: .refused, errorCode: nil))
        check(SGPayWallFunnel.trialEvent(.notLinked) == .proTrialStart(outcome: .refused, errorCode: nil))
        check(SGPayWallFunnel.trialEvent(.failed(.noConnection)) == .proTrialStart(outcome: .failed, errorCode: .offline))
        check(SGPayWallFunnel.trialEvent(.failed(.temporarilyUnavailable)) == .proTrialStart(outcome: .failed, errorCode: nil))
    }

    private static func proMode() {
        check(SGPayWallFunnel.proMode(.free) == .free)
        check(SGPayWallFunnel.proMode(.paid) == .paid)
    }

    private static func attestGate() {
        check(SGLinkAccountFunnel.mayAttest(permission: .allowed), "a usable grant attests")
        check(!SGLinkAccountFunnel.mayAttest(permission: .codeOnly), "no grant: the code only, no requestMainWebView")
        check(!SGLinkAccountFunnel.mayAttest(permission: .refused))
    }

    private static func linkAttempts() {
        check(SGLinkAccountFunnel.attemptEvent(attested: true, failure: nil, duration: 4.4) == .linkAttempt(trigger: .manual, method: .attest, outcome: .success, errorCode: nil, durationS: 4))
        check(SGLinkAccountFunnel.attemptEvent(attested: false, failure: nil, duration: 61.6) == .linkAttempt(trigger: .manual, method: .code, outcome: .success, errorCode: nil, durationS: 62))
        check(SGLinkAccountFunnel.attemptEvent(attested: false, failure: .codeExpired, duration: nil) == .linkAttempt(trigger: .manual, method: .code, outcome: .failed, errorCode: SGAnalyticsErrorCode("bind_expired"), durationS: nil))
        check(SGLinkAccountFunnel.attemptEvent(attested: false, failure: .declined, duration: -3) == .linkAttempt(trigger: .manual, method: .code, outcome: .failed, errorCode: SGAnalyticsErrorCode("bind_denied"), durationS: 0), "a clock step never gives a negative duration")
    }

    private static func linkErrorCodes() {
        let coded = SGEntitlementRequestError(failure: .offline(.serverError), status: 503, code: "attest_unavailable")
        check(SGLinkAccountFunnel.errorCode(.request(coded)) == SGAnalyticsErrorCode("attest_unavailable"), "the server's code wins over the class")
        let local = SGEntitlementRequestError(failure: .unknownRefusal(code: "consent_required_local", status: 0), code: "consent_required_local")
        check(SGLinkAccountFunnel.errorCode(.request(local)) == SGAnalyticsErrorCode("consent_required_local"))
        let offline = SGEntitlementRequestError(failure: .offline(.unknown))
        check(SGLinkAccountFunnel.errorCode(.request(offline)) == .offline)
        let uncoded = SGEntitlementRequestError(failure: .unknownRefusal(code: "Not A Code", status: 418), status: 418)
        check(SGLinkAccountFunnel.errorCode(.request(uncoded)) == .unknown, "a malformed code is never sent")
        let status = SGEntitlementRequestError(failure: .rateLimited(retryAfter: 5), status: 429)
        check(SGLinkAccountFunnel.errorCode(.request(status)) == .http(429))
        check(SGLinkAccountFunnel.errorCode(.didNotGoThrough) == .unknown)
        check(SGLinkAccountFunnel.errorCode(.temporarilyUnavailable) == .unknown)
    }

    private static func linkNotice() {
        check(SGPayWallFunnel.linkNoticeKey(consentRequired: true) == "PayWall.LinkAccount.Notice.Required")
        check(SGPayWallFunnel.linkNoticeKey(consentRequired: false) == "PayWall.LinkAccount.Notice")

        var reads = 0
        let inactive = SGPayWallFunnel.consentRequired(pipelineActive: false, sgConfigJSON: {
            reads += 1
            return "{\"consent_mode\":\"required\"}"
        })
        check(!inactive, "no pipeline, no consent requirement")
        check(reads == 0, "the build config is not read while the pipeline is off")

        check(SGPayWallFunnel.consentRequired(pipelineActive: true, sgConfigJSON: { "{\"consent_mode\":\"required\"}" }))
        check(!SGPayWallFunnel.consentRequired(pipelineActive: true, sgConfigJSON: { "{\"consent_mode\":\"optional\"}" }))
        check(SGPayWallFunnel.consentRequired(pipelineActive: true, sgConfigJSON: { "{}" }), "absent = required (C§5.4 default)")
        check(SGPayWallFunnel.consentRequired(pipelineActive: true, sgConfigJSON: { "{\"consent_mode\":7}" }), "mistyped = absent = required")
        check(!SGPayWallFunnel.consentRequired(pipelineActive: true, sgConfigJSON: { "{\"consent_mode\":\"later\"}" }), "an unknown mode fails the pipeline")
        check(SGPayWallFunnel.consentRequired(pipelineActive: true, sgConfigJSON: { nil }))
        check(SGPayWallFunnel.consentRequired(pipelineActive: true, sgConfigJSON: { "not json" }))
    }
}
