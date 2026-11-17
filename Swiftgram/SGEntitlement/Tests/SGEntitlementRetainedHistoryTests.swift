import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — retained message history through `SGEntitlement` and the App Group mirror
/// (`x-client-state.saved_history`): only NEW capture is gated (`createRetainedHistoryRecord`, the
/// install-wide union like tasks and chat lock); nothing gates reading or removing what was
/// already retained, and an unknown decision never blocks capture (FREE-first).
final class SGEntitlementRetainedHistoryTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let kid = "k2026a"
    private var pinned: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }
    private let day: TimeInterval = 86400

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        let shared = SGEntitlement.shared
        // A CONFIGURED build with nothing granting, after the owner enabled paid: keys pinned,
        // enforcement on, a signed paid policy, no account, no StoreKit snapshot, and no grace
        // record (pinned to nil so the test host never mints one).
        // The app's instance never enforces paid mode in a build that cannot sell through the App
        // Store (`paidModeRequiresAppleBackend`), and the test host ships no product list: the
        // rule is lifted here so the paid-mode capture rules themselves can be exercised.
        shared.overridePaidModeRequiresAppleBackend(false)
        shared.overridePinnedKeys(self.pinned)
        shared.overrideEnforcement(.enforcing)
        shared.overridePolicyState(SGEntitlementTestPolicy.state(SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid"), pinned: self.pinned))
        shared.overrideLocalGrace(nil)
        shared.setActiveAccount(peerId: nil)
        shared.updateStoreKitFallback(nil)
    }

    override func tearDown() {
        let shared = SGEntitlement.shared
        shared.setActiveAccount(peerId: nil)
        shared.updateStoreKitFallback(nil)
        shared.overridePinnedKeys(.shipped)
        shared.overrideEnforcement(.shipped)
        shared.resetPolicyForTesting()
        shared.resetLocalGraceForTesting()
        shared.overridePaidModeRequiresAppleBackend(true)
        super.tearDown()
    }

    // MARK: - Through `SGEntitlement`

    func test_paidWithNothingGranting_stopsNewCapture_andGatesNothingElseAboutHistory() {
        XCTAssertEqual(SGEntitlement.shared.state, .degraded(reason: .noToken))
        XCTAssertFalse(SGEntitlement.can(.createRetainedHistoryRecord))
        XCTAssertEqual(SGEntitlement.gate(.createRetainedHistoryRecord), .blocked(reason: .noToken))
        // The user's own material is untouched.
        for action in SGEntitlementUnrestrictedAction.allCases {
            XCTAssertTrue(SGEntitlement.can(action), "\(action.rawValue)")
        }
    }

    func test_freePolicy_capturesWithNoAccountAndNoToken() {
        SGEntitlement.shared.overridePolicyState(SGEntitlementTestPolicy.state(SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "free", revision: 2), pinned: self.pinned))
        XCTAssertEqual(SGEntitlement.shared.source, .freeAccess)
        XCTAssertTrue(SGEntitlement.can(.createRetainedHistoryRecord))
        XCTAssertEqual(SGEntitlement.shared.retainedHistoryCaptureBlockedFlag, false, "free mode unblocks the replay even before any account is known")
    }

    func test_anUnconfiguredBuildCaptures() {
        SGEntitlement.shared.overrideEnforcement(SGEntitlementEnforcement(canVerifyTokens: false, knowsProducts: false))
        XCTAssertEqual(SGEntitlement.shared.source, .unconfigured)
        XCTAssertTrue(SGEntitlement.can(.createRetainedHistoryRecord))
        XCTAssertEqual(SGEntitlement.shared.retainedHistoryCaptureBlockedFlag, false)
    }

    func test_theLocalGraceCapturesForSevenDays_thenStops() {
        let now = SGEntitlementClock.shared.effectiveNow()
        SGEntitlement.shared.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: now.addingTimeInterval(-3 * self.day)))
        XCTAssertEqual(SGEntitlement.shared.source, .localGrace)
        XCTAssertTrue(SGEntitlement.can(.createRetainedHistoryRecord))

        SGEntitlement.shared.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: now.addingTimeInterval(-7 * self.day - 60)))
        XCTAssertFalse(SGEntitlement.can(.createRetainedHistoryRecord))
    }

    func test_aStoreKitSubscriptionCaptures_onlyWhileTheAppleBackendIsEnabled() {
        let suite = "SGEntitlementRetainedHistoryTests.\(UUID().uuidString)"
        defer {
            for name in [suite, suite + ".scheduler", suite + ".policy"] {
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }
        // Keychainless: nothing reaches the real Keychain.
        let store = SGEntitlementStore(
            defaults: UserDefaults(suiteName: suite),
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            )
        )
        let make: (SGEntitlementAppleBackendConfiguration) -> SGEntitlement = { appleBackend in
            let entitlement = SGEntitlement(
                store: store,
                scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: suite + ".scheduler")),
                policyStore: SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: suite + ".policy")),
                isAuthenticatedEntitlementConfigured: true,
                appleBackend: appleBackend
            )
            entitlement.overridePinnedKeys(self.pinned)
            entitlement.overrideEnforcement(.enforcing)
            entitlement.overridePolicyState(SGEntitlementTestPolicy.state(SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid"), pinned: self.pinned))
            entitlement.overrideLocalGrace(nil)
            return entitlement
        }
        let snapshot = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: nil)

        let enabled = make(SGEntitlementAppleBackendConfiguration(isFlagEnabled: true, productIds: ["org.zenlygram.pro.month"]))
        // The StoreKit snapshot lives in the app-group defaults every instance shares.
        defer { enabled.updateStoreKitFallback(nil) }
        XCTAssertTrue(enabled.isAppleBackendEnabled)
        XCTAssertFalse(enabled.can(.createRetainedHistoryRecord), "premise: paid, nothing granting yet")
        enabled.updateStoreKitFallback(snapshot)
        XCTAssertEqual(enabled.source, .storeKit)
        XCTAssertTrue(enabled.can(.createRetainedHistoryRecord))

        // A held Apple backend: the same cached snapshot grants nothing, so new capture stays stopped.
        let held = make(.held)
        XCTAssertFalse(held.isAppleBackendEnabled)
        XCTAssertFalse(held.can(.createRetainedHistoryRecord))
    }

    func test_theReplayFlag_isLeftAloneWhileNoAccountIsKnown_andBlocksOnceOneIs() {
        // Paid, nothing granting. Before the accounts load the decision is not yet the user's:
        // a Telegram-bot / Atmos payer is `.noToken` here for a moment, so the flag is left alone.
        XCTAssertNil(SGEntitlement.shared.retainedHistoryCaptureBlockedFlag)
        SGEntitlement.shared.setActiveAccount(peerId: 990_010)
        XCTAssertEqual(SGEntitlement.shared.retainedHistoryCaptureBlockedFlag, true)
    }

    func test_theDeviceWideUnion_anotherAccountsTokenCapturesForTheWholeInstall() {
        // The replay flag is one per install, so new capture follows the union like tasks and chat lock.
        let a: Int64 = 990_001
        let b: Int64 = 990_002
        let store = SGEntitlementStore.shared
        store.clearSession(accountPeerId: a)
        store.clearSession(accountPeerId: b)
        defer {
            SGEntitlement.shared.setActiveAccount(peerId: nil)
            store.clearSession(accountPeerId: a)
            store.clearSession(accountPeerId: b)
        }
        let iat = Int64(Date().timeIntervalSince1970) - 60
        let jws = SGEntitlementTestToken.make(
            key: self.key,
            kid: self.kid,
            payload: SGEntitlementTestToken.claims(dev: "dev-b", iat: iat, exp: iat + 72 * 3600, account: .explicit(ent: ["edithistory"], until: "2030-01-01T00:00:00Z"))
        )
        store.seedSessionForTesting(accountPeerId: b, SGEntitlementSessionMaterial(refreshToken: "rt-b", entitlement: jws, accountId: "01JB8Q", deviceId: "dev-b"))
        SGEntitlement.shared.setAccounts(SGEntitlementAccounts(primary: a, all: [a, b]))

        XCTAssertFalse(SGEntitlement.shared.has(.editHistory), "A itself holds nothing")
        XCTAssertTrue(SGEntitlement.can(.createRetainedHistoryRecord))
        XCTAssertEqual(SGEntitlement.shared.retainedHistoryCaptureBlockedFlag, false)
        XCTAssertFalse(SGEntitlement.can(.createVaultEntry), "the vault is account-scoped: no union")
    }

    func test_anotherAccountsLapse_stopsNewCapture_andPostsDidChange() {
        let a: Int64 = 990_003
        let b: Int64 = 990_004
        let store = SGEntitlementStore.shared
        store.clearSession(accountPeerId: a)
        store.clearSession(accountPeerId: b)
        defer {
            SGEntitlement.shared.setActiveAccount(peerId: nil)
            store.clearSession(accountPeerId: a)
            store.clearSession(accountPeerId: b)
        }
        let now = SGEntitlementClock.shared.effectiveNow()
        let iat = Int64(now.timeIntervalSince1970) - 60
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let until = formatter.string(from: now.addingTimeInterval(2.5))
        let jws = SGEntitlementTestToken.make(
            key: self.key,
            kid: self.kid,
            payload: SGEntitlementTestToken.claims(dev: "dev-b", until: until, iat: iat, exp: iat + 72 * 3600, account: .explicit(ent: ["edithistory"], until: until))
        )
        store.seedSessionForTesting(accountPeerId: b, SGEntitlementSessionMaterial(refreshToken: "rt-b", entitlement: jws, accountId: "01JB8Q", deviceId: "dev-b"))

        let lapsed = self.expectation(forNotification: SGEntitlement.didChangeNotification, object: nil, handler: { _ in
            return !SGEntitlement.can(.createRetainedHistoryRecord)
        })
        SGEntitlement.shared.setAccounts(SGEntitlementAccounts(primary: a, all: [a, b]))
        XCTAssertTrue(SGEntitlement.can(.createRetainedHistoryRecord), "B grants for a moment more")

        self.wait(for: [lapsed], timeout: 10.0)
        XCTAssertEqual(SGEntitlement.gate(.createRetainedHistoryRecord), .blocked(reason: .noToken), "A itself never had a token")
        XCTAssertEqual(SGEntitlement.shared.retainedHistoryCaptureBlockedFlag, true, "a lapse stops new capture; nothing is erased or locked")
    }

    // MARK: - The App Group mirror (Notification Service: the replay runs there while the app sleeps)

    private let iat: Int64 = 1_790_000_000

    private func date(_ unix: Int64) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    private func mirrorFlag(_ mirror: SGEntitlementMirror?, at unix: Int64, enforcement: SGEntitlementEnforcement = .enforcing) -> Bool? {
        return SGEntitlementMirrorStore.retainedHistoryCaptureBlockedFlag(mirror: mirror, storedLedger: nil, now: self.date(unix), enforcement: enforcement)
    }

    func test_mirror_noMirrorIsUnknown_andLeavesTheFlagAlone() {
        XCTAssertNil(self.mirrorFlag(nil, at: self.iat))
    }

    func test_mirror_freeAccessNeverBlocks_evenLongAfterItWasWritten() {
        let free = SGEntitlementMirror(capabilities: ["vault", "chatlock", "tasks", "edithistory"], until: nil, exp: nil, graceDays: 14, source: SGEntitlementSource.freeAccess.rawValue, degradedReason: nil, updatedAt: self.iat)
        XCTAssertEqual(self.mirrorFlag(free, at: self.iat + 400 * 86400), false)
    }

    func test_mirror_aPaidGrantLapsingWhileTheAppSleeps_blocksNewCapture() {
        let until = self.iat + 30 * 86400
        let paid = SGEntitlementMirror(capabilities: ["edithistory"], until: until, exp: until, graceDays: 14, source: SGEntitlementSource.token.rawValue, degradedReason: nil, updatedAt: self.iat)
        XCTAssertEqual(self.mirrorFlag(paid, at: until - 1), false)
        XCTAssertEqual(self.mirrorFlag(paid, at: until), true)
    }

    func test_mirror_aGrantWithoutEditHistoryBlocks() {
        let partial = SGEntitlementMirror(capabilities: ["vault", "tasks"], until: self.iat + 86400, exp: self.iat + 86400, graceDays: 14, source: SGEntitlementSource.token.rawValue, degradedReason: nil, updatedAt: self.iat)
        XCTAssertEqual(self.mirrorFlag(partial, at: self.iat), true)
    }

    func test_mirror_aClosedLocalGraceBlocks() {
        let graceEnd = self.iat + 7 * 86400
        let grace = SGEntitlementMirror(capabilities: ["vault", "chatlock", "tasks", "edithistory"], until: graceEnd, exp: nil, graceDays: 14, source: SGEntitlementSource.localGrace.rawValue, degradedReason: nil, updatedAt: self.iat)
        XCTAssertEqual(self.mirrorFlag(grace, at: graceEnd - 1), false)
        XCTAssertEqual(self.mirrorFlag(grace, at: graceEnd), true)
    }

    func test_mirror_anUnconfiguredBuildNeverBlocks() {
        let unconfigured = SGEntitlementEnforcement(canVerifyTokens: false, knowsProducts: false)
        let lapsed = SGEntitlementMirror(capabilities: [], until: nil, exp: nil, graceDays: 14, source: SGEntitlementSource.token.rawValue, degradedReason: SGEntitlementDegradedReason.lapsed.rawValue, updatedAt: self.iat)
        XCTAssertEqual(self.mirrorFlag(lapsed, at: self.iat, enforcement: unconfigured), false)
        XCTAssertEqual(self.mirrorFlag(nil, at: self.iat, enforcement: unconfigured), false)
    }
}

/// Zenlygram — a capability this build refuses must stay refused, whatever the server says.
final class SGEntitlementRefusedCapabilityTests: XCTestCase {
    func test_aiIsRefusedEvenWhenTheServerGrantsIt() {
        let state = SGEntitlementState.unlocked(capabilities: ["vault", "ai"])

        XCTAssertTrue(state.has(.vault))
        XCTAssertFalse(state.has(.ai), "the server granting ai must not switch on a data-collecting feature in a shipped build")
    }

    func test_aiIsRefusedEvenUnderTheWildcard() {
        // `["*"]` is the operator escape hatch. It may rescue a paying user; it may not change
        // what leaves the device.
        let state = SGEntitlementState.unlocked(capabilities: [SGEntitlementCapability.wildcard])

        XCTAssertTrue(state.has(.vault))
        XCTAssertFalse(state.has(.ai))
    }
}
