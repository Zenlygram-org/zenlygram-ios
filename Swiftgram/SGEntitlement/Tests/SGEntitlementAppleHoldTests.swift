import XCTest
import CryptoKit
import Security
import SGConfig
@testable import SGEntitlement

/// Zenlygram — the Apple hold at the entitlement decision (`SGEntitlement.isAppleBackendEnabled`).
///
/// Apple work — and the StoreKit FALLBACK grant — happens only when the build explicitly sets
/// `apple_backend_enabled` AND ships the authenticated configuration AND a non-empty product list AND
/// is not public-policy-only. An authenticated build whose `sg_config` already lists product ids, and
/// whose install still caches an ACTIVE StoreKit snapshot from an earlier build, grants nothing from
/// that snapshot while held. A verified server grant is unaffected.
final class SGEntitlementAppleHoldTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private let kid = "k2026a"
    private let key = P256.Signing.PrivateKey()
    private let products = ["org.zenlygram.pro.month", "org.zenlygram.pro.year"]
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var policySuite = ""
    private var store: SGEntitlementStore!
    private var created: [SGEntitlement] = []

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        let unique = UUID().uuidString
        self.storeSuite = "SGEntitlementAppleHoldTests.store.\(unique)"
        self.schedulerSuite = "SGEntitlementAppleHoldTests.scheduler.\(unique)"
        self.policySuite = "SGEntitlementAppleHoldTests.policy.\(unique)"
        self.store = SGEntitlementStore(
            defaults: UserDefaults(suiteName: self.storeSuite),
            // Every write takes the store's keychainless fallback: nothing reaches the real Keychain.
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            )
        )
    }

    override func tearDown() {
        // The StoreKit snapshot lives in the app-group defaults every instance shares.
        self.created.first?.updateStoreKitFallback(nil)
        self.created = []
        self.store.clearSession(accountPeerId: self.account)
        for suite in [self.storeSuite, self.schedulerSuite, self.policySuite] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        self.store = nil
        super.tearDown()
    }

    private var ring: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    /// An authenticated build under a verified PAID policy, past its local grace, so only a genuine
    /// grant (a token or the StoreKit fallback) can unlock.
    private func makeEntitlement(appleBackend: SGEntitlementAppleBackendConfiguration, publicOnly: Bool = false) async -> SGEntitlement {
        let now = Date()
        let entitlement = SGEntitlement(
            store: self.store,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)),
            policyStore: SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: self.policySuite)),
            policyClock: { now },
            isPublicPolicyRequested: publicOnly,
            isAuthenticatedEntitlementConfigured: !publicOnly,
            appleBackend: appleBackend
        )
        self.created.append(entitlement)
        entitlement.overridePinnedKeys(self.ring)
        entitlement.overrideEnforcement(.enforcing)
        entitlement.overrideLocalGrace(SGEntitlementLocalGrace(firstLaunchAt: now.addingTimeInterval(-60 * 86400)))
        if !publicOnly {
            // Instances in one test share the policy suite: the second launch already holds this
            // exact PAID (`.unchanged`, not `.adopted`). What matters is the verified PAID state.
            let paid = SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid", revision: 1, iat: Int64(now.timeIntervalSince1970))
            _ = await entitlement.performPolicyRefresh(transport: SGEntitlementPolicyTransport(fetch: { .success(paid) }), uptime: 1_000)
            XCTAssertEqual(entitlement.monetizationMode, .paid, "premise: a verified PAID policy")
        }
        return entitlement
    }

    private var activeSnapshot: SGEntitlementStoreKitSnapshot {
        return SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: Date().addingTimeInterval(30 * 86400))
    }

    // MARK: - The predicate on the live coordinator

    func test_aTestInstanceDefaultsToHeldEvenWhenAuthenticated() {
        let entitlement = SGEntitlement(store: self.store, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)), isAuthenticatedEntitlementConfigured: true)
        self.created.append(entitlement)
        XCTAssertFalse(entitlement.isAppleBackendEnabled)
    }

    func test_theCoordinatorAppliesTheSinglePredicate() async {
        let enabled = SGEntitlementAppleBackendConfiguration(isFlagEnabled: true, productIds: self.products)
        let authenticated = await self.makeEntitlement(appleBackend: enabled)
        XCTAssertTrue(authenticated.isAppleBackendEnabled)
        let unflagged = await self.makeEntitlement(appleBackend: SGEntitlementAppleBackendConfiguration(isFlagEnabled: false, productIds: self.products))
        XCTAssertFalse(unflagged.isAppleBackendEnabled, "auth + a pre-existing SKU list is not activation authority")
        let noProducts = await self.makeEntitlement(appleBackend: SGEntitlementAppleBackendConfiguration(isFlagEnabled: true, productIds: []))
        XCTAssertFalse(noProducts.isAppleBackendEnabled)
        let publicOnly = await self.makeEntitlement(appleBackend: enabled, publicOnly: true)
        XCTAssertTrue(publicOnly.isPublicPolicyOnly, "premise")
        XCTAssertFalse(publicOnly.isAppleBackendEnabled)
    }

    func test_theSharedInstanceFollowsTheShippedBuildConstants() {
        XCTAssertEqual(SGEntitlementAppleBackendConfiguration.shipped.isFlagEnabled, SG_CONFIG.appleBackendEnabled)
        XCTAssertEqual(SGEntitlementAppleBackendConfiguration.shipped.productIds, SG_CONFIG.iaps)
        let expected = SGEntitlementAppleBackendConfiguration.shipped.isEnabled(
            isAuthenticatedEntitlementConfigured: SGEntitlementClient.Configuration.isShipped,
            isPublicPolicyOnly: SGEntitlement.shared.isPublicPolicyOnly
        )
        XCTAssertEqual(SGEntitlement.shared.isAppleBackendEnabled, expected)
    }

    // MARK: - The cached StoreKit grant

    func test_heldWithAuthAndACatalogWithholdsAnActiveCachedStoreKitGrant() async {
        let held = await self.makeEntitlement(appleBackend: SGEntitlementAppleBackendConfiguration(isFlagEnabled: false, productIds: self.products))
        held.setActiveAccount(peerId: self.account)
        held.updateStoreKitFallback(self.activeSnapshot)
        XCTAssertNotEqual(held.source, .storeKit, "a held build granted from the cached StoreKit snapshot")
        XCTAssertFalse(held.state.isUnlocked, "nothing but the snapshot could unlock here")
        XCTAssertFalse(held.has(.vault))
    }

    func test_control_theSameSnapshotGrantsOnceAppleIsEnabled() async {
        let enabled = await self.makeEntitlement(appleBackend: SGEntitlementAppleBackendConfiguration(isFlagEnabled: true, productIds: self.products))
        enabled.setActiveAccount(peerId: self.account)
        enabled.updateStoreKitFallback(self.activeSnapshot)
        XCTAssertEqual(enabled.source, .storeKit, "premise: the fixture's snapshot is a genuine grant")
        XCTAssertTrue(enabled.state.isUnlocked)
    }

    // MARK: - Server grants stay valid

    func test_heldKeepsAVerifiedServerAccountGrant() async {
        let held = await self.makeEntitlement(appleBackend: .held)
        let iat = Int64(Date().timeIntervalSince1970) - 60
        let jws = SGEntitlementTestToken.make(key: self.key, kid: self.kid, payload: SGEntitlementTestToken.claims(dev: "01JB8R", until: "2030-01-01T00:00:00Z", iat: iat, exp: iat + 72 * 3600))
        // Persisted through the store's real write path (its keychainless fallback), not the
        // in-memory seed: `invalidate()` drops the store's session cache and re-reads storage.
        let seeded = self.store.updateSession(accountPeerId: self.account) { material in
            material = SGEntitlementSessionMaterial(refreshToken: String(repeating: "a", count: 64), entitlement: jws, accountId: "01JB8Q", deviceId: "01JB8R")
        }
        guard case .success = seeded else {
            return XCTFail("premise: the owned store persists the session: \(seeded)")
        }
        held.setActiveAccount(peerId: self.account)
        held.updateStoreKitFallback(self.activeSnapshot)
        held.invalidate()
        XCTAssertEqual(held.source, .token, "the hold withdrew a verified server grant")
        XCTAssertTrue(held.has(.vault))
    }
}
