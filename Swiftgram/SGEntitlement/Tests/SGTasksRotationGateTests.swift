import XCTest
@testable import SGEntitlement

/// Zenlygram — refresh-token rotation takes the same per-account gate as the Tasks transport
/// (`SGEntitlementClient.accountGate`): a rotation queued behind an in-flight Tasks attempt waits,
/// and one whose session changed meanwhile sends nothing (`.sessionChanged`).
final class SGTasksRotationGateTests: XCTestCase {
    private let account: Int64 = 777_000
    private var suite = ""
    private var store: SGEntitlementStore!

    override func setUp() {
        super.setUp()
        self.suite = "SGTasksRotationGateTests.\(UUID().uuidString)"
        self.store = SGEntitlementOwnedStore.make(suiteName: self.suite)
        let seeded = self.store.updateSession(accountPeerId: self.account) { material in
            material = SGEntitlementSessionMaterial(refreshToken: "tok-1", accountId: "01JB8Q", deviceId: "01JB8R")
        }
        guard case .success = seeded else {
            return XCTFail("the owned store could not persist the seed: \(seeded)")
        }
    }

    override func tearDown() {
        self.store.clearSession(accountPeerId: self.account)
        UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
        self.store = nil
        super.tearDown()
    }

    func test_aRotationWaitsForTheTasksAttemptAndDropsAReplacedSession() async throws {
        // An unroutable origin: the test passes only if the rotation never reaches the network.
        let client = SGEntitlementClient(configuration: SGEntitlementClient.Configuration(baseURL: URL(string: "https://rotation.zenlygram.invalid/v1")!), store: self.store)
        let gate = client.accountGate
        let account = self.account
        await gate.acquire(accountPeerId: account) // a Tasks attempt is presenting tok-1
        let rotation = Task {
            await client.rotateEntitlement(credential: SGEntitlementSessionCredential(accountPeerId: account, refreshToken: "tok-1"), pushToken: nil)
        }
        for _ in 0 ..< 2000 where gate.state(accountPeerId: account).waiting == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(gate.state(accountPeerId: account).waiting, 1, "the rotation waits behind the Tasks attempt")
        // Meanwhile a re-bind stored another session.
        _ = self.store.updateSession(accountPeerId: account) { material in
            material.refreshToken = "rebound"
        }
        gate.release(accountPeerId: account)
        let outcome = await rotation.value
        XCTAssertEqual(outcome, .sessionChanged)
        XCTAssertEqual(self.store.session(accountPeerId: account).refreshToken, "rebound")
        XCTAssertFalse(gate.state(accountPeerId: account).isHeld)
    }
}
