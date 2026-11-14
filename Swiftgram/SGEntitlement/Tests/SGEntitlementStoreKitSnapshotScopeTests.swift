import XCTest
import CryptoKit
import Security
import SGProtectedStore
@testable import SGEntitlement

/// Zenlygram — the cached StoreKit snapshot after a manual Apple enable (security L2).
///
/// The snapshot (`zg.ent.storekit.v1`) was install-wide and bare. A snapshot an earlier build left
/// behind — possibly a legacy aggregate with no receipts and no expiry, which grants until replaced —
/// granted creation on the very first recompute after `apple_backend_enabled` was switched on for a
/// new origin, before this build's SGIAP had refreshed anything. A grant may only come from a snapshot
/// this build's enabled Apple backend recorded for the CURRENT origin. The old bytes stay exactly as
/// they are (never deleted, never rewritten as inactive). Whether they may still show Manage
/// Subscription is `SGEntitlementStoreKitManageTests`.
final class SGEntitlementStoreKitSnapshotScopeTests: XCTestCase {
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
        let suite = "SGEntitlementStoreKitSnapshotScopeTests.\(UUID().uuidString)"
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

    /// A snapshot an earlier build left under the bare key. By default a legacy aggregate: active, no
    /// receipts, no expiry — the shape that granted forever.
    @discardableResult
    private func writeBareLegacySnapshot(expirationDate: Date? = nil) throws -> Data {
        let legacy = SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: expirationDate)
        let data = try JSONEncoder().encode(legacy)
        self.sharedDefaults?.set(data, forKey: SGEntitlement.storeKitSnapshotKey)
        return data
    }

    func test_aBareSnapshotFromAnEarlierBuild_grantsNothingOnTheFirstRecomputeAfterEnable() throws {
        let bare = try self.writeBareLegacySnapshot()
        let entitlement = self.makeEnabled(scope: .origin(try self.origin("https://api.b.zenlygram.test")))
        XCTAssertTrue(entitlement.isAppleBackendEnabled, "premise: Apple manually enabled")

        XCTAssertNotEqual(entitlement.source, .storeKit, "a snapshot this build never recorded must not grant")
        XCTAssertFalse(entitlement.can(.createTask))
        XCTAssertFalse(entitlement.can(.createRetainedHistoryRecord))
        XCTAssertEqual(self.sharedDefaults?.data(forKey: SGEntitlement.storeKitSnapshotKey), bare, "the old bytes are neither deleted nor rewritten")
    }

    func test_aSnapshotThisBuildRecords_grantsForItsOriginOnly_andLeavesTheBareBytes() throws {
        let bare = try self.writeBareLegacySnapshot()
        let b = try self.origin("https://api.b.zenlygram.test")
        let onB = self.makeEnabled(scope: .origin(b))
        onB.updateStoreKitFallback(SGEntitlementStoreKitSnapshot(hasActiveSubscription: true, expirationDate: Date().addingTimeInterval(30 * 86400)))
        XCTAssertEqual(onB.source, .storeKit)
        XCTAssertTrue(onB.can(.createTask))
        XCTAssertEqual(self.sharedDefaults?.data(forKey: SGEntitlement.storeKitSnapshotKey), bare, "recording B's snapshot leaves the bare bytes alone")

        // Another origin on the same install has recorded nothing of its own.
        let onA = self.makeEnabled(scope: .origin(try self.origin("https://api.a.zenlygram.test")))
        XCTAssertNotEqual(onA.source, .storeKit)
        XCTAssertFalse(onA.can(.createTask))

        // Clearing B's snapshot clears B's only.
        onB.updateStoreKitFallback(nil)
        XCTAssertEqual(self.sharedDefaults?.data(forKey: SGEntitlement.storeKitSnapshotKey), bare)
    }
}
