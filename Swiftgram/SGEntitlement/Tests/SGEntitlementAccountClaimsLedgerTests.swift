import XCTest
@testable import SGEntitlement

/// Zenlygram — the paid-mode "this token has no account claims, ask for one that does" request
/// (fallback review M1). A request is only spent when the scheduler actually ADMITS it: a skip, a
/// wait or a transport failure keeps it due, so a server-paid user holding a fresh legacy token is
/// never left degraded until the token is a day old. Nothing is due before the first idle window
/// after launch (invariant I1).
final class SGEntitlementAccountClaimsLedgerTests: XCTestCase {
    private let a: Int64 = 1001
    private let b: Int64 = 1002

    private func request(_ peer: Int64, _ token: String) -> SGEntitlementAccountClaimsRequest {
        return SGEntitlementAccountClaimsRequest(accountPeerId: peer, token: token)
    }

    func test_nothingIsDueBeforeTheFirstIdleWindow() {
        var ledger = SGEntitlementAccountClaimsLedger()
        ledger.noteMissing(accountPeerId: self.a, token: "legacy-a")
        XCTAssertEqual(ledger.due(firstIdlePassed: false), [], "the launch path never reaches the network")
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [self.request(self.a, "legacy-a")], "…and it is asked right after it")
    }

    func test_aRequestThatWasNotAdmittedStaysDue() {
        var ledger = SGEntitlementAccountClaimsLedger()
        ledger.noteMissing(accountPeerId: self.a, token: "legacy-a")
        // The scheduler answered skip / wait (in flight, 60 s collapse, budget, backoff): nothing
        // was sent, so nothing may be marked as asked.
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [self.request(self.a, "legacy-a")])
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [self.request(self.a, "legacy-a")], "asking for the due list spends nothing")
    }

    func test_anAdmittedRequestIsAskedOnce_andAFailureMakesItDueAgain() {
        var ledger = SGEntitlementAccountClaimsLedger()
        ledger.noteMissing(accountPeerId: self.a, token: "legacy-a")
        ledger.admitted(self.request(self.a, "legacy-a"))
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [], "one request per legacy token")
        ledger.noteMissing(accountPeerId: self.a, token: "legacy-a")
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [], "re-deciding with the same token asks nothing new")

        ledger.failed(self.request(self.a, "legacy-a"))
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [self.request(self.a, "legacy-a")], "a failed request did not deliver the claims")
    }

    func test_aFailureOfAnOlderTokenDoesNotReopenANewerOne() {
        var ledger = SGEntitlementAccountClaimsLedger()
        ledger.noteMissing(accountPeerId: self.a, token: "legacy-1")
        ledger.admitted(self.request(self.a, "legacy-1"))
        ledger.noteMissing(accountPeerId: self.a, token: "legacy-2")
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [self.request(self.a, "legacy-2")], "a new legacy token is a new question")
        ledger.admitted(self.request(self.a, "legacy-2"))
        ledger.failed(self.request(self.a, "legacy-1"))
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [])
    }

    func test_aTokenWithAccountClaimsSettlesTheAccount() {
        var ledger = SGEntitlementAccountClaimsLedger()
        ledger.noteMissing(accountPeerId: self.a, token: "legacy-a")
        ledger.noteMissing(accountPeerId: self.b, token: "legacy-b")
        ledger.noteSatisfied(accountPeerId: self.a)
        XCTAssertEqual(ledger.due(firstIdlePassed: true), [self.request(self.b, "legacy-b")], "accounts are independent")
    }
}
