import XCTest
import CryptoKit
import Security
import SGProtectedStore
@testable import SGEntitlement

/// Zenlygram — Manage Subscription for a StoreKit snapshot an earlier build left behind (security L2).
///
/// `SGEntitlement.manageableStoreKitSnapshot` is display-only: it may let Apple's management page appear
/// for existing billing, and never grants or feeds a plan. This origin's own snapshot is preferred; the
/// pre-origin bare snapshot counts only while it is active with a finite expiry still ahead — never
/// refreshed by this build, with no expiry it would read as active forever. The grant side (the bare
/// snapshot grants nothing, a recorded one grants only its own origin) is
/// `SGEntitlementStoreKitSnapshotScopeTests`.
final class SGEntitlementStoreKitManageTests: XCTestCase {
    private let kid = "k2026a"
    private let key = P256.Signing.PrivateKey()
    private let products = ["org.zenlygram.pro.month"]
    private var suites: [String] = []
    private var created: [SGEntitlement] = []
    private var sharedDefaults: UserDefaults? {
        return UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup)
    }
    private var savedBare: Data?

    override func setUp() {
        super.setUp()
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        // Earlier suites adopt fixture tokens into the shared clock, which then holds evaluation time
        // near their fixed issue dates; these cases are written against today's date.
        SGEntitlementClock.shared.resetForTesting()
        // The snapshot lives in the app-group defaults every instance shares: keep what was there.
        self.savedBare = self.sharedDefaults?.data(forKey: SGEntitlement.storeKitSnapshotKey)
    }

    override func tearDown() {
        for entitlement in self.created {
            entitlement.updateStoreKitFallback(nil)
        }
        self.created = []
        if let savedBare = self.savedBare {
            self.sharedDefaults?.set(savedBare, forKey: SGEntitlement.storeKitSnapshotKey)
        } else {
            self.sharedDefaults?.removeObject(forKey: SGEntitlement.storeKitSnapshotKey)
        }
        for suite in self.suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        self.suites = []
        super.tearDown()
    }

    private var ring: SGEntitlementPinnedKeys {
        return SGEntitlementTestToken.pinned(self.key, kid: self.kid)
    }

    /// An authenticated build for `scope` with the Apple backend ENABLED, under a verified PAID
    /// policy, past its local grace, with no token: only the StoreKit fallback could grant.
    private func makeEnabled(scope: SGEntitlementStoreScope) -> SGEntitlement {
        let suite = "SGEntitlementStoreKitManageTests.\(UUID().uuidString)"
        self.suites += [suite, suite + ".scheduler", suite + ".policy"]
        let store = SGEntitlementStore(
            defaults: UserDefaults(suiteName: suite),
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            ),
            scope: scope
        )
        let entitlement = SGEntitlement(
            store: store,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: suite + ".scheduler")),
            policyStore: SGEntitlementPolicyStore(defaults: UserDefaults(suiteName: suite + ".policy")),
            isAuthenticatedEntitlementConfigured: true,
            appleBackend: SGEntitlementAppleBackendConfiguration(isFlagEnabled: true, productIds: self.products)
        )
        self.created.append(entitlement)
        entitlement.overridePinnedKeys(self.ring)
        entitlement.overrideEnforcement(.enforcing)
        entitlement.overridePolicyState(SGEntitlementTestPolicy.state(SGEntitlementTestPolicy.make(key: self.key, kid: self.kid, mode: "paid"), pinned: self.ring))
        entitlement.overrideLocalGrace(nil)
        return entitlement
    }

    private func origin(_ apiUrl: String) throws -> SGEntitlementBackendOrigin {
        return try XCTUnwrap(SGEntitlementBackendOrigin(apiUrl: apiUrl, upstreamDefaultApiUrl: "https://upstream.invalid"))
    }

    /// A snapshot an earlier build left under the bare key.
    private func writeBareLegacySnapshot(expirationDate: Date?) throws {
        let legacy = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: expirationDate)
        self.sharedDefaults?.set(try JSONEncoder().encode(legacy), forKey: SGEntitlement.storeKitSnapshotKey)
    }

    func test_aBoundedBareSnapshotStillShowsManageSubscription_withoutGranting() throws {
        try self.writeBareLegacySnapshot(expirationDate: Date().addingTimeInterval(10 * 86400))
        let entitlement = self.makeEnabled(scope: .origin(try self.origin("https://api.b.zenlygram.test")))
        XCTAssertEqual(entitlement.manageableStoreKitSnapshot?.hasActiveSubscription, true, "existing billing stays manageable")
        XCTAssertNil(entitlement.storeKitFallback, "the grant-scope snapshot (what SGIAP preserves and extends) is this origin's only")
        XCTAssertFalse(entitlement.can(.createTask))
    }

    func test_anUnboundedOrExpiredBareSnapshotIsNotManageableEither() throws {
        // Never refreshed by this build: with no expiry it would read as active forever.
        try self.writeBareLegacySnapshot(expirationDate: nil)
        XCTAssertNil(self.makeEnabled(scope: .origin(try self.origin("https://api.b.zenlygram.test"))).manageableStoreKitSnapshot)
        try self.writeBareLegacySnapshot(expirationDate: Date().addingTimeInterval(-40 * 86400))
        XCTAssertNil(self.makeEnabled(scope: .origin(try self.origin("https://api.b.zenlygram.test"))).manageableStoreKitSnapshot)
    }
}
