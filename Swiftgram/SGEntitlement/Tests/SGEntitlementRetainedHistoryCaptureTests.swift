import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — retained message history under the monetization policy
/// (`x-client-state.saved_history`): what was already retained stays readable and removable in
/// every mode, and only NEW capture is a paid create. Pure rules only — runs on the macOS host
/// through `run-policy-core-tests.sh`, no Keychain, no App Group.
final class SGEntitlementRetainedHistoryCaptureTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private let iat: Int64 = 1_790_000_000
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
    }

    private func at(_ offset: TimeInterval) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(self.iat) + offset)
    }

    private func token(account: SGEntitlementTestToken.AccountClaims) -> SGEntitlementCachedToken {
        let jws = SGEntitlementTestToken.make(
            key: self.key,
            kid: self.kid,
            payload: SGEntitlementTestToken.claims(until: "2030-01-01T00:00:00Z", iat: self.iat, exp: self.iat + 72 * 3600, account: account)
        )
        return SGEntitlementCachedToken(jws: jws, boundDeviceId: "01JB8R")
    }

    private func captureAllowed(_ mode: SGEntitlementPolicyMode, cached: SGEntitlementCachedToken? = nil, localGrace: SGEntitlementLocalGrace? = nil, enforcement: SGEntitlementEnforcement = .enforcing, now: Date) -> Bool {
        let decision = SGEntitlementEvaluator.evaluate(cached: cached, storeKit: nil, pinnedKeys: self.pinned, now: now, enforcement: enforcement, localGrace: localGrace, monetization: mode)
        return decision.state.allows(.createRetainedHistoryRecord)
    }

    // MARK: - The action

    func test_newCaptureIsGatedOnTheEditHistoryCapability() {
        XCTAssertEqual(SGEntitlementGatedAction.createRetainedHistoryRecord.capability, .editHistory)
        XCTAssertTrue(SGEntitlementState.unlocked(capabilities: ["edithistory"]).allows(.createRetainedHistoryRecord))
        XCTAssertFalse(SGEntitlementState.unlocked(capabilities: ["vault", "chatlock", "tasks"]).allows(.createRetainedHistoryRecord), "another feature's grant is not a capture grant")
        XCTAssertFalse(SGEntitlementState.degraded(reason: .lapsed).allows(.createRetainedHistoryRecord))
    }

    // MARK: - Per mode

    func test_free_capturesNewHistory_forEveryInstall() {
        XCTAssertTrue(self.captureAllowed(.free, now: self.at(60)), "never bound")
        XCTAssertTrue(self.captureAllowed(.free, localGrace: SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400)), now: self.at(0)), "past the local grace")
        XCTAssertTrue(self.captureAllowed(.free, cached: self.token(account: .explicit(ent: [], until: nil)), now: self.at(60)), "a lapsed paid grant changes nothing while free")
    }

    func test_paid_withoutAGenuineGrant_stopsNewCapture() {
        XCTAssertFalse(self.captureAllowed(.paid, now: self.at(60)), "never bound, no grace")
        XCTAssertFalse(self.captureAllowed(.paid, localGrace: SGEntitlementLocalGrace(firstLaunchAt: self.at(-30 * 86400)), now: self.at(0)), "past the local grace")
        XCTAssertFalse(self.captureAllowed(.paid, cached: self.token(account: .explicit(ent: ["vault", "tasks"], until: "2030-01-01T00:00:00Z")), now: self.at(60)), "a grant without edithistory")
        XCTAssertFalse(self.captureAllowed(.paid, cached: self.token(account: .explicit(ent: [], until: nil)), now: self.at(60)), "a lapsed grant")
    }

    func test_paid_aGenuineGrantCaptures_untilItLapses() {
        let grant = self.token(account: .explicit(ent: ["edithistory"], until: "2030-01-01T00:00:00Z"))
        XCTAssertTrue(self.captureAllowed(.paid, cached: grant, now: self.at(60)))
        XCTAssertFalse(self.captureAllowed(.paid, cached: grant, now: self.at(400 * 86400)), "past exp + grace: a lapse stops new capture")
    }

    func test_paid_insideTheLocalGrace_captures() {
        XCTAssertTrue(self.captureAllowed(.paid, localGrace: SGEntitlementLocalGrace(firstLaunchAt: self.at(-86400)), now: self.at(0)))
    }

    func test_anUnconfiguredBuildCapturesInEitherMode() {
        let unconfigured = SGEntitlementEnforcement(canVerifyTokens: false, knowsProducts: false)
        XCTAssertTrue(self.captureAllowed(.paid, enforcement: unconfigured, now: self.at(60)))
        XCTAssertTrue(self.captureAllowed(.free, enforcement: unconfigured, now: self.at(60)))
    }

    // MARK: - The app-group flag the Postbox replay reads

    func test_theReplayFlag_allowsWheneverCaptureIsAllowed() {
        XCTAssertEqual(SGEntitlementRetainedHistoryCapture.blockedFlag(captureAllowed: true, isDecisionKnown: true), false)
        XCTAssertEqual(SGEntitlementRetainedHistoryCapture.blockedFlag(captureAllowed: true, isDecisionKnown: false), false, "unblocking is always safe: FREE-first")
    }

    func test_theReplayFlag_blocksOnlyAKnownRefusal() {
        XCTAssertEqual(SGEntitlementRetainedHistoryCapture.blockedFlag(captureAllowed: false, isDecisionKnown: true), true)
        XCTAssertNil(SGEntitlementRetainedHistoryCapture.blockedFlag(captureAllowed: false, isDecisionKnown: false), "an unknown decision leaves the stored flag alone")
    }
}
