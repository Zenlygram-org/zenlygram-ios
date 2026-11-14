import XCTest
import Security
import SGConfig
import SGProtectedStore
@testable import SGEntitlement

/// Zenlygram — origin-bound entitlement storage. A build configured for a new backend origin starts
/// with FRESH sessions, device id, Enclave/software keys and Apple outbox under its own namespace
/// (`base@authority`), and never reads, copies, rewrites or deletes the bare legacy (`.com`-era)
/// items. The clock high-water mark and the two local grace records (first launch, first paid
/// policy — D9) stay install-wide: a new origin neither re-grants the seven days nor re-bases them.
///
/// Every case runs the store's real write-and-read-back path against an injected in-memory
/// Keychain (`SGEntitlementKeychainAccess`) that records every account it is asked about.
final class SGEntitlementOriginIsolationTests: XCTestCase {
    /// An in-memory generic-password table keyed by account, with a journal of every call.
    private final class KeychainFixture {
        private let lock = NSLock()
        private(set) var items: [String: Data] = [:]
        private(set) var reads: [String] = []
        private(set) var writes: [String] = []
        private(set) var deletes: [String] = []

        func seed(_ account: String, _ data: Data) {
            self.lock.lock()
            self.items[account] = data
            self.lock.unlock()
        }

        func value(_ account: String) -> Data? {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.items[account]
        }

        var touched: Set<String> {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return Set(self.reads + self.writes + self.deletes)
        }

        var access: SGEntitlementKeychainAccess {
            return SGEntitlementKeychainAccess(
                read: { [unowned self] account in
                    self.lock.lock()
                    defer {
                        self.lock.unlock()
                    }
                    self.reads.append(account)
                    if let data = self.items[account] {
                        return .present(data)
                    }
                    return .absent
                },
                write: { [unowned self] data, account in
                    self.lock.lock()
                    defer {
                        self.lock.unlock()
                    }
                    self.writes.append(account)
                    self.items[account] = data
                    return errSecSuccess
                },
                delete: { [unowned self] account in
                    self.lock.lock()
                    defer {
                        self.lock.unlock()
                    }
                    self.deletes.append(account)
                    self.items.removeValue(forKey: account)
                }
            )
        }
    }

    private let account: Int64 = 69_229_542_146
    private let upstream = "https://api.swiftgram.app"
    private var suite = ""
    private var keychain: KeychainFixture!
    private var legacy: [String: Data] = [:]

    private var legacySessionAccount: String {
        return "session.v1.\(self.account)"
    }

    /// The bare, origin-bound items an earlier `.com` build left behind.
    private var legacyOriginBoundAccounts: [String] {
        return [self.legacySessionAccount, "device.id.v1", "device.enclave.v1", "device.softkey.v1", "apple.outbox.v1"]
    }

    private func origin(_ raw: String) -> SGEntitlementStoreScope {
        guard let value = SGEntitlementBackendOrigin(apiUrl: raw, upstreamDefaultApiUrl: self.upstream) else {
            XCTFail("premise: \(raw) is a valid origin")
            return .unconfigured
        }
        return .origin(value)
    }

    private var org: SGEntitlementStoreScope {
        return self.origin("https://api.zenlygram.org")
    }

    private var otherOrigin: SGEntitlementStoreScope {
        return self.origin("https://api.zenlygram.org:8443")
    }

    private func makeStore(_ scope: SGEntitlementStoreScope) -> SGEntitlementStore {
        return SGEntitlementStore(defaults: UserDefaults(suiteName: self.suite), keychain: self.keychain.access, scope: scope)
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(value)
    }

    override func setUp() {
        super.setUp()
        self.suite = "SGEntitlementOriginIsolationTests.\(UUID().uuidString)"
        self.keychain = KeychainFixture()
        let legacyOutbox = [
            SGEntitlementOutboxEntry(id: "2000000111111111", signedTransaction: "legacy.com.signed.transaction", idempotencyKey: "legacy-idempotency-key", accountPeerId: self.account),
            SGEntitlementOutboxEntry(id: "2000000222222222", signedTransaction: "legacy.com.stuck.transaction", idempotencyKey: "legacy-stuck-key", accountPeerId: nil, attempts: 7, lastErrorCode: "apple_subscription_conflict", isStuck: true)
        ]
        self.legacy = [
            self.legacySessionAccount: self.encoded(SGEntitlementSessionMaterial(refreshToken: String(repeating: "c", count: 64), entitlement: "legacy.com.jws", accountId: "01LEGACYCOM", deviceId: "01LEGACYDEV", until: "2030-01-01T00:00:00Z", pushTokenDigest: "legacy-receipt")),
            "device.id.v1": Data(String(repeating: "d", count: 64).utf8),
            "device.enclave.v1": Data("legacy-enclave-blob".utf8),
            "device.softkey.v1": Data(repeating: 0x5A, count: 32),
            "apple.outbox.v1": self.encoded(legacyOutbox),
            "clock.mark.v1": Data("{\"legacy\":\"clock\"}".utf8),
            "grace.firstlaunch.v1": Data("{\"legacy\":\"grace\"}".utf8),
            "grace.firstpaid.v1": Data("{\"legacy\":\"paidmark\"}".utf8)
        ]
        for (account, data) in self.legacy {
            self.keychain.seed(account, data)
        }
    }

    override func tearDown() {
        UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
        self.keychain = nil
        super.tearDown()
    }

    /// Every bare origin-bound item is still there, byte for byte.
    private func assertLegacyUntouched(file: StaticString = #filePath, line: UInt = #line) {
        for account in self.legacyOriginBoundAccounts {
            XCTAssertEqual(self.keychain.value(account), self.legacy[account], "legacy \(account) changed", file: file, line: line)
        }
    }

    /// The fresh store never even ASKED about a bare origin-bound item.
    private func assertLegacyNeverAccessed(file: StaticString = #filePath, line: UInt = #line) {
        let touched = self.keychain.touched.intersection(self.legacyOriginBoundAccounts)
        XCTAssertTrue(touched.isEmpty, "legacy items were accessed: \(touched.sorted())", file: file, line: line)
    }

    // MARK: - Wiring

    func test_theSharedStoreUsesTheShippedScope() {
        XCTAssertEqual(SGEntitlementStore.shared.scope, SGEntitlementStoreScope.shipped)
    }

    /// `Configuration.shipped` (and so the client, the legacy policy endpoint, the Apple trust domain
    /// and the store scope) is exactly the validated origin of this build's `api_url`, and nothing
    /// without pinned entitlement keys.
    func test_theShippedConfigurationIsTheValidatedOriginOfApiUrl() {
        let origin = SGEntitlementPinnedKeys.shipped.isEmpty ? nil : SGEntitlementBackendOrigin(apiUrl: SG_CONFIG.apiUrl, upstreamDefaultApiUrl: SGConfig.defaultApiUrl)
        XCTAssertEqual(SGEntitlementClient.Configuration.shipped(appVersion: nil, osVersion: nil)?.baseURL, origin?.baseURL)
        XCTAssertEqual(SGEntitlementClient.Configuration.isShipped, origin != nil)
        XCTAssertEqual(SGEntitlementStoreScope.shipped, origin.map { SGEntitlementStoreScope.origin($0) } ?? .unconfigured)
    }

    // MARK: - Sessions

    func test_aFreshOriginNeverReadsTheLegacySession() {
        let store = self.makeStore(self.org)
        let material = store.session(accountPeerId: self.account)
        XCTAssertTrue(material.isEmpty, "a .com refresh token or JWS surfaced under the new origin")
        XCTAssertFalse(material.isLinked)
        self.assertLegacyNeverAccessed()
        self.assertLegacyUntouched()
    }

    func test_aFreshOriginSessionIsWrittenAndClearedOnlyUnderItsOwnAccount() {
        let store = self.makeStore(self.org)
        let written = store.updateSession(accountPeerId: self.account) { material in
            material.refreshToken = String(repeating: "o", count: 64)
            material.accountId = "01ORG"
        }
        guard case .success = written else {
            return XCTFail("premise: the fixture accepts writes: \(written)")
        }
        let scoped = self.org.scopedKey(self.legacySessionAccount)
        XCTAssertEqual(scoped, "session.v1.\(self.account)@api.zenlygram.org")
        XCTAssertNotNil(self.keychain.value(scoped))
        XCTAssertEqual(Set(self.keychain.writes), [scoped])

        let removed = store.clearSession(accountPeerId: self.account)
        XCTAssertEqual(removed.accountId, "01ORG", "logout presents the origin's own token to /bind/revoke, never the legacy one")
        XCTAssertNil(self.keychain.value(scoped))
        XCTAssertEqual(Set(self.keychain.deletes), [scoped])
        self.assertLegacyNeverAccessed()
        self.assertLegacyUntouched()
    }

    func test_twoOriginsNeverShareASession() {
        let org = self.makeStore(self.org)
        _ = org.updateSession(accountPeerId: self.account) { material in
            material.refreshToken = String(repeating: "o", count: 64)
        }
        let other = self.makeStore(self.otherOrigin)
        XCTAssertTrue(other.session(accountPeerId: self.account).isEmpty)
        other.clearSession(accountPeerId: self.account)
        XCTAssertNotNil(self.keychain.value(self.org.scopedKey(self.legacySessionAccount)), "another origin's logout deleted this origin's session")
        self.assertLegacyUntouched()
    }

    // MARK: - Explicit logout privacy

    /// An explicit logout keeps the privacy it always had: the signed-out account's bare `.com`
    /// session item is DELETED locally — never read, returned, revoked or sent anywhere — and only
    /// that account's. Nothing else legacy is touched, and no other path (launch, a new empty origin,
    /// reading a session) ever deletes it.
    func test_explicitLogoutDiscardsOnlyThatAccountsLegacySessionWithoutReadingIt() {
        let otherAccount: Int64 = 777_000_111
        let otherLegacy = Data("other-account-legacy-session".utf8)
        self.keychain.seed("session.v1.\(otherAccount)", otherLegacy)
        let store = self.makeStore(self.org)
        // A launch, a fresh origin and every ordinary read leave it in place.
        _ = store.session(accountPeerId: self.account)
        _ = store.ensureDeviceId()
        XCTAssertEqual(self.keychain.value(self.legacySessionAccount), self.legacy[self.legacySessionAccount])

        store.discardLegacySession(accountPeerId: self.account)
        XCTAssertNil(self.keychain.value(self.legacySessionAccount), "an explicit logout left the account's .com refresh token behind")
        XCTAssertFalse(self.keychain.reads.contains(self.legacySessionAccount), "the legacy session was read")
        XCTAssertEqual(self.keychain.deletes.filter { !$0.contains("@") }, [self.legacySessionAccount], "exactly one bare item deleted")
        XCTAssertEqual(self.keychain.value("session.v1.\(otherAccount)"), otherLegacy, "another account's legacy session was deleted")
        for account in ["device.id.v1", "device.enclave.v1", "device.softkey.v1", "apple.outbox.v1", "clock.mark.v1", "grace.firstlaunch.v1", "grace.firstpaid.v1"] {
            XCTAssertEqual(self.keychain.value(account), self.legacy[account], "logout touched legacy \(account)")
        }
    }

    // MARK: - Device identity

    func test_theDeviceIdIsMintedFreshPerOriginAndNeverReused() {
        let store = self.makeStore(self.org)
        XCTAssertNil(store.deviceId(), "the .com device id surfaced under the new origin")
        guard let minted = store.ensureDeviceId() else {
            return XCTFail("premise: the fixture accepts writes")
        }
        XCTAssertEqual(minted.count, 64)
        XCTAssertTrue(minted.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(Data(minted.utf8), self.legacy["device.id.v1"])
        XCTAssertEqual(self.keychain.value(self.org.scopedKey("device.id.v1")), Data(minted.utf8))
        XCTAssertEqual(self.makeStore(self.org).deviceId(), minted, "stable within its origin")

        let other = self.makeStore(self.otherOrigin)
        XCTAssertNil(other.deviceId())
        XCTAssertNotEqual(other.ensureDeviceId(), minted, "two origins must not share a device identity")
        self.assertLegacyNeverAccessed()
        self.assertLegacyUntouched()
    }

    func test_deviceKeysAreNeverReusedOrDeletedAcrossOrigins() {
        let store = self.makeStore(self.org)
        XCTAssertNil(store.enclaveKeyBlob(), "the .com Enclave key surfaced under the new origin")
        XCTAssertNil(store.softwareKeyBlob(), "the .com software key surfaced under the new origin")

        let fresh = Data(repeating: 0x0F, count: 32)
        XCTAssertTrue(store.setSoftwareKeyBlob(fresh))
        XCTAssertEqual(self.keychain.value(self.org.scopedKey("device.softkey.v1")), fresh)
        XCTAssertTrue(store.setEnclaveKeyBlob(Data("org-enclave".utf8)))
        XCTAssertEqual(self.keychain.value(self.org.scopedKey("device.enclave.v1")), Data("org-enclave".utf8))

        // `regenerateKeyPair` clears both blobs: only this origin's.
        store.setEnclaveKeyBlob(nil)
        store.setSoftwareKeyBlob(nil)
        XCTAssertEqual(Set(self.keychain.deletes), [self.org.scopedKey("device.enclave.v1"), self.org.scopedKey("device.softkey.v1")])
        self.assertLegacyNeverAccessed()
        self.assertLegacyUntouched()
    }

    // MARK: - Apple outbox

    func test_aFreshOriginOutboxNeverSeesSendsOrRemovesLegacyEntries() {
        let outbox = SGEntitlementOutbox(store: self.makeStore(self.org))
        XCTAssertTrue(outbox.entries().isEmpty, "a .com attach would be sent to the new origin")
        XCTAssertTrue(outbox.dueEntries(now: Date.distantFuture).isEmpty)
        XCTAssertTrue(outbox.stuckEntries().isEmpty)

        // What a drain/Restore would do to entries it cannot see: nothing.
        outbox.remove(id: "2000000111111111")
        outbox.recordFailure(id: "2000000111111111", failure: .offline(.unknown), retryAfter: nil)
        outbox.clearStuckFlags()
        self.assertLegacyUntouched()

        let entry = outbox.enqueue(signedTransaction: "org.signed.transaction", transactionId: "2000000333333333", accountPeerId: self.account)
        XCTAssertNotEqual(entry.idempotencyKey, "legacy-idempotency-key")
        let scoped = self.org.scopedKey("apple.outbox.v1")
        XCTAssertEqual(scoped, "apple.outbox.v1@api.zenlygram.org")
        let stored = try? JSONDecoder().decode([SGEntitlementOutboxEntry].self, from: self.keychain.value(scoped) ?? Data())
        XCTAssertEqual(stored?.map { $0.id }, ["2000000333333333"], "the fresh outbox holds only its own entry")
        XCTAssertTrue(SGEntitlementOutbox(store: self.makeStore(self.otherOrigin)).entries().isEmpty)
        self.assertLegacyNeverAccessed()
        self.assertLegacyUntouched()
    }

    // MARK: - Install-wide items

    func test_theClockMarkAndLocalGraceStayInstallWide() {
        let org = self.makeStore(self.org)
        let other = self.makeStore(self.otherOrigin)
        XCTAssertEqual(org.clockMarkData(), self.legacy["clock.mark.v1"], "a new origin must not reset the clock high-water mark")
        XCTAssertEqual(other.clockMarkData(), self.legacy["clock.mark.v1"])
        XCTAssertEqual(org.localGraceData(), self.legacy["grace.firstlaunch.v1"], "a new origin must not re-grant the local 7 days")
        XCTAssertEqual(other.localGraceData(), self.legacy["grace.firstlaunch.v1"])
        // D9: the paid-policy mark is the second half of the same window. Scoped by origin it would
        // re-base the seven days — a fresh grace — for every new backend origin.
        XCTAssertEqual(org.paidModeMarkRecord(), .present(self.legacy["grace.firstpaid.v1"]!), "a new origin must not re-base the paid-mode grace")
        XCTAssertEqual(other.paidModeMarkRecord(), .present(self.legacy["grace.firstpaid.v1"]!))

        let mark = Data("{\"moved\":true}".utf8)
        XCTAssertTrue(org.setClockMarkData(mark))
        XCTAssertEqual(self.keychain.value("clock.mark.v1"), mark)
        XCTAssertEqual(other.clockMarkData(), mark)
        let paidMark = Data("{\"paid\":true}".utf8)
        XCTAssertTrue(org.setPaidModeMarkData(paidMark))
        XCTAssertEqual(self.keychain.value("grace.firstpaid.v1"), paidMark, "the mark is written under its bare, install-wide name")
        XCTAssertEqual(other.paidModeMarkRecord(), .present(paidMark), "another origin reads the same mark")
        for account in ["clock.mark.v1", "grace.firstlaunch.v1", "grace.firstpaid.v1"] {
            XCTAssertNil(self.keychain.value(self.org.scopedKey(account)), "\(account) was written under an origin scope")
        }
        self.assertLegacyUntouched()
    }

    // MARK: - The whole surface at once

    func test_noFreshOriginOperationEverAccessesABareOriginBoundItem() {
        let store = self.makeStore(self.org)
        _ = store.session(accountPeerId: self.account)
        _ = store.updateSession(accountPeerId: self.account) { $0.refreshToken = String(repeating: "o", count: 64) }
        store.invalidateCache()
        _ = store.session(accountPeerId: self.account)
        _ = store.deviceId()
        _ = store.ensureDeviceId()
        _ = store.enclaveKeyBlob()
        _ = store.softwareKeyBlob()
        store.setEnclaveKeyBlob(nil)
        store.setSoftwareKeyBlob(nil)
        let outbox = SGEntitlementOutbox(store: store)
        _ = outbox.entries()
        outbox.enqueue(signedTransaction: "org.signed", transactionId: "2000000444444444", accountPeerId: nil)
        outbox.remove(id: "2000000444444444")
        _ = store.localGraceRecord()
        _ = store.paidModeMarkRecord()
        store.setPaidModeMarkData(Data("{\"paid\":true}".utf8))
        store.clearSession(accountPeerId: self.account)
        self.assertLegacyNeverAccessed()
        self.assertLegacyUntouched()
        // Exactly these three items are install-wide and written bare; everything else is scoped.
        let installWide: Set<String> = ["clock.mark.v1", "grace.firstlaunch.v1", "grace.firstpaid.v1"]
        for account in self.keychain.writes + self.keychain.deletes {
            XCTAssertTrue(account.hasSuffix("@api.zenlygram.org") || installWide.contains(account), "unscoped write/delete: \(account)")
        }
    }
}
