import Foundation

/// Zenlygram — a NEW App Store purchase is admitted only by a FRESH, verified PAID monetization
/// policy fetched for this purchase (never a cached one), then — for a linked account only — a
/// successful `prepare` for this exact product, with the local paid mode re-checked after every
/// await. An unlinked install may still buy (no `appAccountToken`): linking stays optional.
///
/// Exercised through the same `SGIAPPurchaseAdmission.run` the StoreKit engine routes
/// `product.purchase(options:)` through: the `purchase` closure stands where StoreKit's sheet is
/// invoked, and the tests assert on whether it was ever called and with which token.
private actor CallLog {
    private(set) var authorizations = 0
    private(set) var prepares = 0
    private(set) var purchases: [UUID?] = []

    func authorized() {
        self.authorizations += 1
    }

    func prepared() {
        self.prepares += 1
    }

    func purchased(_ token: UUID?) {
        self.purchases.append(token)
    }
}

/// The local mode, flipped by a test while an await is suspended.
private final class Mode: @unchecked Sendable {
    private let lock = NSLock()
    private var paid: Bool

    init(paid: Bool) {
        self.paid = paid
    }

    var isPaid: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.paid
    }

    func set(paid: Bool) {
        self.lock.lock()
        self.paid = paid
        self.lock.unlock()
    }
}

@main
struct PurchaseAdmissionTests {
    private typealias Admission = SGIAPPurchaseAdmission

    private static func check(_ condition: Bool, _ message: String = "Assertion failed", line: Int = #line) {
        precondition(condition, "line \(line): \(message)")
    }

    private static let product = "org.zenlygram.ios.pro.yearly"
    private static let token = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private struct Run {
        let outcome: Admission.Outcome<String>
        let authorizations: Int
        let prepares: Int
        let purchases: [UUID?]
    }

    /// `prepare == nil` is an unlinked install: there is no session to prepare under.
    private static func run(
        local: Mode = Mode(paid: true),
        authorization: Admission.Authorization = .paid,
        duringAuthorization: @escaping () -> Void = {},
        prepare: Admission.Prepare?,
        duringPrepare: @escaping () -> Void = {}
    ) async -> Run {
        let log = CallLog()
        let prepareStep: (() async -> Admission.Prepare)? = prepare.map { answer in
            return {
                await log.prepared()
                duringPrepare()
                return answer
            }
        }
        let outcome = await Admission.run(
            productId: product,
            isOfferedLocally: { local.isPaid },
            authorize: {
                await log.authorized()
                duringAuthorization()
                return authorization
            },
            prepare: prepareStep,
            purchase: { appAccountToken in
                await log.purchased(appAccountToken)
                return "purchased"
            }
        )
        return Run(outcome: outcome, authorizations: await log.authorizations, prepares: await log.prepares, purchases: await log.purchases)
    }

    static func main() async {
        await unlinkedPaidPurchasesWithoutAToken()
        await freshAuthorizationIsRequiredEveryTime()
        await linkedPurchaseUsesItsMatchedPrepareToken()
        await linkedPrepareFailuresNeverFallBackToUnbound()
        await localFreeShortCircuitsEverything()
        await turningFreeDuringAnyAwaitStopsThePurchase()
        prepareMapping()
        print("PASS: purchase admission")
    }

    private static func unlinkedPaidPurchasesWithoutAToken() async {
        // Linking is optional (App Review): a freshly authorized paid policy is enough.
        let result = await run(prepare: nil)
        check(result.outcome == .admitted("purchased"), "An unlinked install could not buy in paid mode")
        check(result.authorizations == 1)
        check(result.prepares == 0)
        check(result.purchases == [nil], "An unlinked purchase carries no appAccountToken")
    }

    private static func freshAuthorizationIsRequiredEveryTime() async {
        let refusals: [(Admission.Authorization, Admission.Refusal)] = [
            (.free, .notOffered),
            (.unavailable, .unavailable),
            (.busy, .busy)
        ]
        for (authorization, refusal) in refusals {
            for prepare in [nil, Admission.Prepare.prepared(appAccountToken: token, productId: product)] {
                let result = await run(authorization: authorization, prepare: prepare)
                check(result.outcome == .refused(refusal), "\(authorization) must refuse with \(refusal)")
                check(result.prepares == 0, "\(authorization): prepare ran without a fresh paid policy")
                check(result.purchases.isEmpty, "\(authorization): StoreKit was invoked without a fresh paid policy (no cached-paid fallback)")
            }
        }
    }

    private static func linkedPurchaseUsesItsMatchedPrepareToken() async {
        let result = await run(prepare: .prepared(appAccountToken: token, productId: product))
        check(result.outcome == .admitted("purchased"))
        check(result.authorizations == 1 && result.prepares == 1)
        check(result.purchases == [token], "A linked purchase must carry the token prepare minted")
    }

    private static func linkedPrepareFailuresNeverFallBackToUnbound() async {
        let cases: [(Admission.Prepare, Admission.Refusal)] = [
            (.monetizationDisabled, .notOffered),
            (.unavailable, .unavailable),
            (.offline, .noConnection),
            (.prepared(appAccountToken: token, productId: "org.zenlygram.ios.pro.monthly"), .unavailable)
        ]
        for (answer, refusal) in cases {
            let result = await run(prepare: answer)
            check(result.outcome == .refused(refusal), "\(answer) must refuse with \(refusal)")
            check(result.prepares == 1)
            check(result.purchases.isEmpty, "\(answer): a linked purchase fell back to an unbound StoreKit purchase")
        }
    }

    private static func localFreeShortCircuitsEverything() async {
        let result = await run(local: Mode(paid: false), prepare: .prepared(appAccountToken: token, productId: product))
        check(result.outcome == .refused(.notOffered))
        check(result.authorizations == 0 && result.prepares == 0 && result.purchases.isEmpty, "Free locally: nothing may be asked or bought")
    }

    private static func turningFreeDuringAnyAwaitStopsThePurchase() async {
        let duringAuthorization = Mode(paid: true)
        let afterAuthorization = await run(local: duringAuthorization, duringAuthorization: { duringAuthorization.set(paid: false) }, prepare: nil)
        check(afterAuthorization.outcome == .refused(.notOffered), "The local re-check after the authorization await was skipped")
        check(afterAuthorization.purchases.isEmpty)

        let duringPrepare = Mode(paid: true)
        let afterPrepare = await run(local: duringPrepare, prepare: .prepared(appAccountToken: token, productId: product), duringPrepare: { duringPrepare.set(paid: false) })
        check(afterPrepare.outcome == .refused(.notOffered), "The local re-check after the prepare await was skipped")
        check(afterPrepare.purchases.isEmpty)
    }

    private static func prepareMapping() {
        let lower = token.uuidString.lowercased()
        check(Admission.Prepare(status: 200, appAccountToken: lower, productId: product, errorCode: nil) == .prepared(appAccountToken: token, productId: product))
        // 2xx without a usable token is not an admission.
        check(Admission.Prepare(status: 200, appAccountToken: nil, productId: product, errorCode: nil) == .unavailable)
        check(Admission.Prepare(status: 200, appAccountToken: "not-a-uuid", productId: product, errorCode: nil) == .unavailable)
        check(Admission.Prepare(status: 200, appAccountToken: lower, productId: nil, errorCode: nil) == .unavailable)
        check(Admission.Prepare(status: 409, appAccountToken: nil, productId: nil, errorCode: "monetization_disabled") == .monetizationDisabled)
        check(Admission.Prepare(status: 503, appAccountToken: nil, productId: nil, errorCode: "monetization_unavailable") == .unavailable)
        check(Admission.Prepare(status: 409, appAccountToken: nil, productId: nil, errorCode: "something_else") == .unavailable)
        check(Admission.Prepare(status: 401, appAccountToken: nil, productId: nil, errorCode: "unauthenticated") == .unavailable)
        check(Admission.Prepare(status: nil, appAccountToken: nil, productId: nil, errorCode: nil) == .offline, "A transport failure is offline")
    }
}
