import XCTest
@testable import SGEntitlement

/// Zenlygram — the customer-data facade and the bind changes behind it, on an instance that owns its
/// store and scheduler: the guards (extension, no client, no session), the per-binding receipts and
/// session end, the pure material transforms, the `/bind/start` consent (body, decision, fallback),
/// the local permission refusal, bind attempts and the logout's final-send capture. Nothing here
/// needs a device identity or reaches a network: the client, when installed, points at a scripted
/// origin (`SGEntitlementPathStubProtocol`) that answers nothing it was not given.
final class SGEntitlementCustomerDataTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private let origin = "api.customer-data.zenlygram.invalid"
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var store: SGEntitlementStore!
    private var scheduler: SGEntitlementScheduler!

    /// What a hook or a fake `send` saw.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            self.lock.lock()
            self.values.append(value)
            self.lock.unlock()
        }

        var all: [String] {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.values
        }
    }

    override func setUp() {
        super.setUp()
        SGEntitlementPathStubProtocol.reset()
        self.storeSuite = "SGEntitlementCustomerDataTests.store.\(UUID().uuidString)"
        self.schedulerSuite = "SGEntitlementCustomerDataTests.scheduler.\(UUID().uuidString)"
        self.store = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
        self.scheduler = SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite))
    }

    override func tearDown() {
        self.store.clearSession(accountPeerId: self.account)
        UserDefaults(suiteName: self.storeSuite)?.removePersistentDomain(forName: self.storeSuite)
        UserDefaults(suiteName: self.schedulerSuite)?.removePersistentDomain(forName: self.schedulerSuite)
        SGEntitlementPathStubProtocol.reset()
        self.scheduler = nil
        self.store = nil
        super.tearDown()
    }

    private func entitlement(isExtensionProcess: Bool = false, withClient: Bool = true, store: SGEntitlementStore? = nil, identity: SGEntitlementDeviceIdentity = .shared) -> SGEntitlement {
        let store = store ?? self.store!
        let entitlement = SGEntitlement(store: store, identity: identity, scheduler: self.scheduler, isExtensionProcess: isExtensionProcess)
        if withClient {
            var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://\(self.origin)/v1")!)
            configuration.protocolClasses = [SGEntitlementPathStubProtocol.self]
            entitlement.installClientForTesting(SGEntitlementClient(configuration: configuration, store: store, identity: identity))
        }
        return entitlement
    }

    private func seed(_ material: SGEntitlementSessionMaterial, account: Int64? = nil) {
        let seeded = self.store.updateSession(accountPeerId: account ?? self.account) { stored in
            stored = material
        }
        guard case .success = seeded else {
            return XCTFail("the owned store could not persist the seed: \(seeded)")
        }
    }

    private var linked: SGEntitlementSessionMaterial {
        return SGEntitlementSessionMaterial(refreshToken: "tok-1", entitlement: "jws", accountId: "01JB8Q", deviceId: "01JB8R")
    }

    private func body(_ route: SGEntitlementCustomerDataRoute) -> Data? {
        return route == .profileMe ? nil : Data(#"{"schema_version":1}"#.utf8)
    }

    // MARK: - Guards

    func test_inAnExtensionEveryCallAnswersNotConfiguredWithoutARequest() async {
        let entitlement = self.entitlement(isExtensionProcess: true)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        self.seed(SGEntitlementSessionMaterial(refreshToken: "tok-1", accountId: "01JB8Q", deviceId: "01JB8R", profileSyncDigest: "digest", profileSyncedAt: at, sessionEnd: SGEntitlementSessionEnd(code: "invalid_token", reason: nil, at: at, deviceId: "01JB8R")))
        for route in SGEntitlementCustomerDataRoute.allCases {
            let result = await entitlement.customerData(route, body: self.body(route), accountPeerId: self.account, idempotencyKey: "k")
            XCTAssertEqual(result, .failure(.notConfigured), "\(route)")
        }
        let attested = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in
            XCTFail("an extension never asks Telegram")
            return .unavailable(reason: "unexpected")
        })
        XCTAssertEqual(attested, .notConfigured)
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded.isEmpty, "an .appex sends nothing")
        XCTAssertNil(entitlement.profileSyncReceipt(accountPeerId: self.account))
        XCTAssertNil(entitlement.sessionEnd(accountPeerId: self.account))
        XCTAssertFalse(entitlement.recordProfileSync(accountPeerId: self.account, credential: SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1"), digest: "other", at: at))
        XCTAssertEqual(self.store.session(accountPeerId: self.account).profileSyncDigest, "digest", "nothing was written")

        entitlement.bindPermissionProvider = { _ in .refused }
        entitlement.bindConsentProvider = { _ in ["consent_id": "c"] }
        entitlement.preRevokeUploadsProvider = { _ in [Data()] }
        entitlement.bindConsentRefused = { _, _ in }
        XCTAssertNil(entitlement.bindPermissionProvider, "the hooks stay nil in an extension")
        XCTAssertNil(entitlement.bindConsentProvider)
        XCTAssertNil(entitlement.preRevokeUploadsProvider)
        XCTAssertNil(entitlement.bindConsentRefused)
        XCTAssertEqual(entitlement.bindPermission(accountPeerId: self.account), .allowed)
    }

    func test_withoutAClientEveryCallIsNotConfigured() async {
        let entitlement = self.entitlement(withClient: false)
        self.seed(self.linked)
        for route in SGEntitlementCustomerDataRoute.allCases {
            let result = await entitlement.customerData(route, body: self.body(route), accountPeerId: self.account)
            XCTAssertEqual(result, .failure(.notConfigured), "\(route)")
        }
        let attested = await entitlement.bindWithTelegramAttestation(accountPeerId: self.account, attest: { _ in .unavailable(reason: "unexpected") })
        XCTAssertEqual(attested, .notConfigured)
    }

    func test_withoutASessionEveryCallIsNotLinked() async {
        let entitlement = self.entitlement()
        for route in SGEntitlementCustomerDataRoute.allCases {
            let result = await entitlement.customerData(route, body: self.body(route), accountPeerId: self.account)
            XCTAssertEqual(result, .failure(.notLinked), "\(route)")
        }
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded.isEmpty)
    }

    /// With a client and a session the call reaches the transport. Whether this test host can sign
    /// at all is its own business; whatever leaves carries the credential as a header only.
    func test_aLinkedCallReachesTheTransportAndOnlyCarriesHeaderCredentials() async {
        let entitlement = self.entitlement()
        self.seed(self.linked)
        let body = Data(#"{"schema_version":1,"events":[]}"#.utf8)
        let result = await entitlement.customerData(.profileConsents, body: body, accountPeerId: self.account)
        guard case .failure(.request) = result else {
            return XCTFail("the scripted origin answers nothing: \(result)")
        }
        for recorded in SGEntitlementPathStubProtocol.recorded {
            XCTAssertEqual(recorded.path, "/v1/profile/consents")
            XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
            XCTAssertEqual(recorded.body, body)
        }
    }

    func test_theAuthenticatedBackendFlagIsTheBuildConstant() {
        XCTAssertTrue(SGEntitlement(store: self.store, scheduler: self.scheduler, isAuthenticatedEntitlementConfigured: true).isAuthenticatedBackendConfigured)
        XCTAssertFalse(SGEntitlement(store: self.store, scheduler: self.scheduler, isAuthenticatedEntitlementConfigured: false).isAuthenticatedBackendConfigured, "independent of configure(...) and of any client")
    }

    func test_theAuthorityAndStorageTokenFollowTheStoreScope() throws {
        XCTAssertNil(self.entitlement().customerDataAuthority, "a build without the backend has no authority")
        XCTAssertNil(self.entitlement().customerDataStorageToken)
        let origin = try XCTUnwrap(SGEntitlementBackendOrigin(apiUrl: "https://api.zenlygram.test", upstreamDefaultApiUrl: "https://api.swiftgram.app"))
        let suite = "SGEntitlementCustomerDataTests.scoped.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let scoped = SGEntitlementOwnedStore.make(suiteName: suite, scope: .origin(origin))
        XCTAssertEqual(self.entitlement(store: scoped).customerDataAuthority, "api.zenlygram.test")
        XCTAssertEqual(self.entitlement(store: scoped).customerDataStorageToken, SGEntitlementStoreScope.origin(origin).storageToken)
        XCTAssertNil(self.entitlement(isExtensionProcess: true, store: scoped).customerDataAuthority)
        XCTAssertNil(self.entitlement(isExtensionProcess: true, store: scoped).customerDataStorageToken)
    }

    // MARK: - Receipts and the session end

    func test_recordProfileSyncRefusesAReplacedSession() {
        let entitlement = self.entitlement()
        self.seed(self.linked)
        let current = SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(entitlement.recordProfileSync(accountPeerId: self.account, credential: current, digest: "digest-1", at: at))
        XCTAssertEqual(entitlement.profileSyncReceipt(accountPeerId: self.account)?.digest, "digest-1")
        XCTAssertEqual(entitlement.profileSyncReceipt(accountPeerId: self.account)?.at, at)

        self.store.updateSession(accountPeerId: self.account) { material in
            material.refreshToken = "tok-2" // a rotation: same binding, new session
        }
        XCTAssertFalse(entitlement.recordProfileSync(accountPeerId: self.account, credential: current, digest: "digest-2", at: at.addingTimeInterval(60)))
        XCTAssertEqual(entitlement.profileSyncReceipt(accountPeerId: self.account)?.digest, "digest-1", "the stale write changed nothing; the rotation kept the receipt")
        let other = SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-2")
        XCTAssertFalse(entitlement.recordProfileSync(accountPeerId: self.account + 1, credential: other, digest: "digest-3", at: at), "a credential of another account")

        entitlement.clearProfileSyncReceipt(accountPeerId: self.account)
        XCTAssertNil(entitlement.profileSyncReceipt(accountPeerId: self.account))
        XCTAssertEqual(self.store.session(accountPeerId: self.account).refreshToken, "tok-2", "clearing the receipt keeps the session")

        XCTAssertTrue(entitlement.recordProfileSync(accountPeerId: self.account, credential: other, digest: "digest-4", at: at))
        entitlement.logout(accountPeerId: self.account)
        XCTAssertNil(entitlement.profileSyncReceipt(accountPeerId: self.account), "gone with the session")
    }

    func test_theMaterialTransformsOfABindAndAServerDrop() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let before = SGEntitlementSessionMaterial(
            refreshToken: "old", entitlement: "jws-old", accountId: "acc-old", deviceId: "dev-old", until: "2029-01-01T00:00:00Z",
            pushTokenDigest: "push", profileSyncDigest: "digest", profileSyncedAt: at,
            sessionEnd: SGEntitlementSessionEnd(code: "session_revoked", reason: nil, at: at, deviceId: "dev-old")
        )
        let confirmation = SGEntitlementBindConfirmation(
            refreshToken: "new",
            entitlement: "jws-new",
            account: SGEntitlementBindAccount(id: "acc-new", tgUserId: 9_100_000_001, status: "paid", until: "2030-01-01T00:00:00Z"),
            device: SGEntitlementBindDevice(id: "dev-new"),
            mergeConflict: nil
        )
        let bound = before.afterBind(confirmation)
        XCTAssertEqual(bound.refreshToken, "new")
        XCTAssertEqual(bound.accountId, "acc-new")
        XCTAssertEqual(bound.deviceId, "dev-new")
        XCTAssertEqual(bound.until, "2030-01-01T00:00:00Z")
        XCTAssertNil(bound.pushTokenDigest)
        XCTAssertNil(bound.profileSyncDigest)
        XCTAssertNil(bound.profileSyncedAt)
        XCTAssertNil(bound.sessionEnd, "a new binding never carries a session end")
        XCTAssertEqual(bound.entitlement, "jws-old", "a governing token is replaced only by adopt, after verification")
        XCTAssertEqual(SGEntitlementSessionMaterial().afterBind(confirmation).entitlement, "jws-new", "an empty slot takes the bind's token")

        let dropped = bound.afterServerDrop(code: "invalid_token", reason: "account_erased", at: at)
        XCTAssertNil(dropped.refreshToken)
        XCTAssertFalse(dropped.isLinked)
        XCTAssertEqual(dropped.sessionEnd, SGEntitlementSessionEnd(code: "invalid_token", reason: "account_erased", at: at, deviceId: "dev-new"))
        XCTAssertEqual(dropped.entitlement, "jws-old", "the JWS keeps governing")
        XCTAssertEqual(dropped.accountId, "acc-new")
    }

    func test_anOldSessionItemDecodesWithoutTheNewFieldsAndTheNewOnesRoundTrip() throws {
        let old = Data(#"{"refreshToken":"tok","entitlement":"jws","accountId":"a","deviceId":"d","pushTokenDigest":"p"}"#.utf8)
        let decoded = try JSONDecoder().decode(SGEntitlementSessionMaterial.self, from: old)
        XCTAssertEqual(decoded.refreshToken, "tok")
        XCTAssertNil(decoded.profileSyncDigest)
        XCTAssertNil(decoded.profileSyncedAt)
        XCTAssertNil(decoded.sessionEnd)

        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let material = SGEntitlementSessionMaterial(refreshToken: nil, entitlement: "jws", profileSyncDigest: "digest", profileSyncedAt: at, sessionEnd: SGEntitlementSessionEnd(code: "device_revoked", reason: "account_erased", at: at, deviceId: "d"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try JSONDecoder().decode(SGEntitlementSessionMaterial.self, from: encoder.encode(material)), material)
    }

    func test_aServerDropAlwaysLeavesASessionEndAndALogoutNever() throws {
        let entitlement = self.entitlement(withClient: false)
        let current = SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1")
        for cause in [SGEntitlementSessionFailure.invalidToken, .expiredToken, .sessionRevoked, .deviceRevoked, .refreshReuse] {
            self.seed(self.linked)
            entitlement.apply(SGEntitlementRequestError(failure: .session(cause), status: 401, code: cause.rawValue, reason: "account_erased"), credential: SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-0"))
            XCTAssertEqual(self.store.session(accountPeerId: self.account).refreshToken, "tok-1", "\(cause): another session's 401 changes nothing")
            XCTAssertNil(entitlement.sessionEnd(accountPeerId: self.account))

            entitlement.apply(SGEntitlementRequestError(failure: .session(cause), status: 401, code: cause.rawValue, reason: "account_erased"), credential: current)
            let material = self.store.session(accountPeerId: self.account)
            XCTAssertNil(material.refreshToken, "\(cause)")
            XCTAssertEqual(material.entitlement, "jws", "\(cause): the token keeps governing")
            let end = try XCTUnwrap(entitlement.sessionEnd(accountPeerId: self.account), "\(cause): a dropped token always leaves a session end")
            XCTAssertEqual(end.code, cause.rawValue)
            XCTAssertEqual(end.reason, "account_erased")
            XCTAssertEqual(end.deviceId, "01JB8R")
        }

        self.seed(self.linked)
        entitlement.apply(SGEntitlementRequestError(failure: .session(.clockSkew), status: 401, code: "clock_skew"), credential: current)
        XCTAssertEqual(self.store.session(accountPeerId: self.account).refreshToken, "tok-1", "a recoverable 401 drops nothing")
        XCTAssertNil(entitlement.sessionEnd(accountPeerId: self.account))

        entitlement.logout(accountPeerId: self.account)
        XCTAssertNil(entitlement.sessionEnd(accountPeerId: self.account), "a logout never leaves a session end")
        XCTAssertFalse(entitlement.isLinked(accountPeerId: self.account))
    }

    func test_forgettingAnErasedAccountRemovesTheSessionAndItsRecords() {
        let entitlement = self.entitlement(withClient: false)
        self.seed(self.linked)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(entitlement.recordProfileSync(accountPeerId: self.account, credential: SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1"), digest: "digest", at: at))
        entitlement.apply(SGEntitlementRequestError(failure: .session(.invalidToken), status: 401, code: "invalid_token", reason: "account_erased"), credential: SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1"))
        XCTAssertNotNil(entitlement.sessionEnd(accountPeerId: self.account))
        let asked = Recorder()
        entitlement.preRevokeUploadsProvider = { account in
            asked.append("\(account)")
            return [Data()]
        }
        _ = entitlement.newBindAttempt(accountPeerId: self.account, purpose: .auto)

        entitlement.forgetErasedAccount(accountPeerId: self.account)
        XCTAssertNil(entitlement.sessionEnd(accountPeerId: self.account))
        XCTAssertNil(entitlement.profileSyncReceipt(accountPeerId: self.account))
        XCTAssertTrue(self.store.session(accountPeerId: self.account).isEmpty)
        XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "its bind attempt ended")
        XCTAssertTrue(asked.all.isEmpty, "no final send for an erased account")
    }

    /// The client's own routes keep the error's status, code, reason and body too: a coded 503 is
    /// "offline" by class, yet its code survives. (No `server_time` in these bodies: the client feeds
    /// it to the shared clock, which other tests in the same process read.)
    func test_theClientKeepsTheStatusCodeReasonAndBodyOfAnError() async throws {
        let unavailable = SGEntitlementPathStubProtocol.json(["error": "attest_unavailable", "message": "m", "retry_after": 5])
        let erased = SGEntitlementPathStubProtocol.json(["error": "invalid_token", "message": "m", "reason": "account_erased"])
        let large = SGEntitlementPathStubProtocol.json(["error": "invalid_request", "pad": String(repeating: "p", count: SGEntitlementRequestError.maxResponseBodyBytes)])
        SGEntitlementPathStubProtocol.reset(["/v1/health": [
            SGEntitlementPathStubProtocol.Response(status: 503, body: unavailable),
            SGEntitlementPathStubProtocol.Response(status: 401, body: erased),
            SGEntitlementPathStubProtocol.Response(status: 422, body: large)
        ]])
        let client = try XCTUnwrap(self.entitlement().client)

        guard case let .failure(first) = await client.health() else {
            return XCTFail("a 503 is a failure")
        }
        XCTAssertEqual(first.failure, .offline(.serverError))
        XCTAssertEqual(first.status, 503)
        XCTAssertEqual(first.code, "attest_unavailable")
        XCTAssertEqual(first.retryAfter, 5)
        XCTAssertEqual(first.responseBody, unavailable)

        guard case let .failure(second) = await client.health() else {
            return XCTFail("a 401 is a failure")
        }
        XCTAssertEqual(second.failure, .session(.invalidToken))
        XCTAssertEqual(second.status, 401)
        XCTAssertEqual(second.reason, "account_erased")

        guard case let .failure(third) = await client.health() else {
            return XCTFail("a 422 is a failure")
        }
        XCTAssertEqual(third.code, "invalid_request")
        XCTAssertNil(third.responseBody, "an error body over 16 KiB is not kept")
        XCTAssertEqual(SGEntitlementPathStubProtocol.recorded.count, 3, "none of them is retried")

        guard case let .failure(offline) = await client.health() else {
            return XCTFail("nothing scripted is left: no answer")
        }
        XCTAssertNil(offline.status, "no answer, no status")
        XCTAssertNil(offline.code)
    }

    // MARK: - /bind/start consent

    func test_theBindStartBodyCarriesTheConsentOnlyWhenGiven() throws {
        let base = SGEntitlementClient.bindStartBody(deviceId: "dev", publicKey: "pk", platform: "ios", deviceName: "iPhone", appVersion: "12.0.1", osVersion: "27.0", consent: nil)
        XCTAssertEqual(Set(base.keys), ["device_id", "device_pubkey", "platform", "device_name", "src", "app_version", "os_version"])
        XCTAssertEqual(base["src"] as? String, "ios")

        let consent: [String: Any] = [
            "consent_id": "9f1c2b7e-0000-4000-8000-000000000001", "tg_user_id": 555_000_111, "action": "grant",
            "scopes": ["link", "profile", "statistics", "tasks_sync"], "text_version": 1, "text_sha256": String(repeating: "a", count: 64),
            "locale": "uz", "consent_mode": "required", "age_confirmed": true, "recorded_at": "2026-10-29T10:00:00Z",
            "platform": "ios", "app_version": "12.0.1"
        ]
        let withConsent = SGEntitlementClient.bindStartBody(deviceId: "dev", publicKey: "pk", platform: "ios", deviceName: "iPhone", appVersion: "12.0.1", osVersion: "27.0", consent: consent)
        XCTAssertEqual(Set(withConsent.keys), Set(base.keys).union(["consent"]))
        XCTAssertEqual(withConsent["consent"] as? NSDictionary, consent as NSDictionary)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: withConsent))

        let unserializable = SGEntitlementClient.bindStartBody(deviceId: "dev", publicKey: "pk", platform: "ios", deviceName: "iPhone", appVersion: nil, osVersion: nil, consent: ["recorded_at": Date()])
        XCTAssertNil(unserializable["consent"], "a consent that is not a JSON object is left out, never a crash")
        XCTAssertEqual(Set(unserializable.keys), ["device_id", "device_pubkey", "platform", "device_name", "src"])
    }

    func test_theConsentIsAttachedOnlyWhileThePermissionIsAllowed() {
        let asked = Recorder()
        let provider: (Int64) -> [String: Any]? = { account in
            asked.append("\(account)")
            return ["consent_id": "c-1"]
        }
        XCTAssertEqual(SGEntitlement.bindConsent(permission: .allowed, provider: provider, accountPeerId: self.account)?["consent_id"] as? String, "c-1")
        XCTAssertEqual(asked.all, ["\(self.account)"])
        XCTAssertNil(SGEntitlement.bindConsent(permission: .codeOnly, provider: provider, accountPeerId: self.account))
        XCTAssertNil(SGEntitlement.bindConsent(permission: .refused, provider: provider, accountPeerId: self.account))
        XCTAssertEqual(asked.all.count, 1, "a code-only account is never even asked for a grant")
        XCTAssertNil(SGEntitlement.bindConsent(permission: .allowed, provider: nil, accountPeerId: self.account), "no grant, no consent")
        XCTAssertNil(SGEntitlement.bindConsent(permission: .allowed, provider: { _ in nil }, accountPeerId: self.account))
    }

    private func refusal(_ status: Int, _ code: String) -> SGEntitlementRequestError {
        return SGEntitlementRequestError(failure: SGEntitlementFailureMapping.classify(status: status, code: code, retryAfter: nil), status: status, code: code)
    }

    /// Drives `startWithConsentFallback` with scripted answers; the "start" is a plain string.
    private func fallback(consent: [String: Any]?, purpose: SGEntitlementBindPurpose, answers: [Result<String, SGEntitlementRequestError>]) async -> (result: Result<String, SGEntitlementRequestError>, sent: [String], refused: [String]) {
        let sent = Recorder()
        let refused = Recorder()
        var remaining = answers
        let result: Result<String, SGEntitlementRequestError> = await SGEntitlement.startWithConsentFallback(consent: consent, purpose: purpose, send: { consent in
            sent.append((consent?["consent_id"] as? String) ?? "none")
            return remaining.isEmpty ? .failure(SGEntitlementRequestError(failure: .offline(.timeout))) : remaining.removeFirst()
        }, refused: { consentId in
            refused.append(consentId)
        })
        return (result, sent.all, refused.all)
    }

    func test_anInvalidConsentIsReportedAndTheSameStartRetriedOnceWithoutIt() async {
        let consent: [String: Any] = ["consent_id": "c-1", "action": "grant"]
        for purpose in [SGEntitlementBindPurpose.manual, .auto] {
            let run = await self.fallback(consent: consent, purpose: purpose, answers: [.failure(self.refusal(422, "invalid_consent")), .success("start")])
            XCTAssertEqual(run.result, .success("start"), "\(purpose)")
            XCTAssertEqual(run.sent, ["c-1", "none"], "\(purpose): once with, once without")
            XCTAssertEqual(run.refused, ["c-1"], "\(purpose): the store learns which consent was refused")
        }
        let twice = await self.fallback(consent: consent, purpose: .manual, answers: [.failure(self.refusal(422, "invalid_consent")), .failure(self.refusal(422, "invalid_consent"))])
        XCTAssertEqual(twice.sent, ["c-1", "none"], "exactly one retry")
        XCTAssertEqual(twice.result, .failure(self.refusal(422, "invalid_consent")))
    }

    func test_aStaleConsentRetriesOnlyAManualStart() async {
        let consent: [String: Any] = ["consent_id": "c-1", "action": "grant"]
        let manual = await self.fallback(consent: consent, purpose: .manual, answers: [.failure(self.refusal(409, "consent_stale")), .success("start")])
        XCTAssertEqual(manual.result, .success("start"))
        XCTAssertEqual(manual.sent, ["c-1", "none"])
        XCTAssertTrue(manual.refused.isEmpty, "a stale consent is not a malformed one")

        let auto = await self.fallback(consent: consent, purpose: .auto, answers: [.failure(self.refusal(409, "consent_stale")), .success("start")])
        XCTAssertEqual(auto.result, .failure(self.refusal(409, "consent_stale")), "the automatic link stops until a new grant")
        XCTAssertEqual(auto.sent, ["c-1"])
    }

    func test_nothingElseIsRetriedAndNoConsentMeansNoFallback() async {
        let consent: [String: Any] = ["consent_id": "c-1"]
        for answer in [self.refusal(429, "rate_limited"), self.refusal(503, "bind_paused"), self.refusal(422, "invalid_request")] {
            let run = await self.fallback(consent: consent, purpose: .manual, answers: [.failure(answer), .success("start")])
            XCTAssertEqual(run.sent, ["c-1"], "\(answer.code ?? "")")
            XCTAssertEqual(run.result, .failure(answer))
        }
        let bare = await self.fallback(consent: nil, purpose: .manual, answers: [.failure(self.refusal(422, "invalid_consent")), .success("start")])
        XCTAssertEqual(bare.sent, ["none"])
        XCTAssertTrue(bare.refused.isEmpty)
        let fine = await self.fallback(consent: consent, purpose: .auto, answers: [.success("start")])
        XCTAssertEqual(fine.sent, ["c-1"])
    }

    /// `mayRetry` (`beginBind`: an automatic start reads its permission again) is asked once a 422
    /// `invalid_consent` came back, BEFORE `refused`: false still reports the refused consent, but
    /// nothing more is sent and the answer is the local refusal; true is today's one retry.
    func test_anInvalidConsentIsRetriedOnlyWhileMayRetryAllowsIt() async {
        let consent: [String: Any] = ["consent_id": "c-1", "action": "grant"]
        for allowed in [false, true] {
            let steps = Recorder()
            var remaining: [Result<String, SGEntitlementRequestError>] = [.failure(self.refusal(422, "invalid_consent")), .success("start")]
            let result: Result<String, SGEntitlementRequestError> = await SGEntitlement.startWithConsentFallback(consent: consent, purpose: .auto, send: { consent in
                steps.append("send:\((consent?["consent_id"] as? String) ?? "none")")
                return remaining.isEmpty ? .failure(SGEntitlementRequestError(failure: .offline(.timeout))) : remaining.removeFirst()
            }, refused: { consentId in
                steps.append("refused:\(consentId)")
            }, mayRetry: {
                steps.append("mayRetry?")
                return allowed
            })
            if allowed {
                XCTAssertEqual(steps.all, ["send:c-1", "mayRetry?", "refused:c-1", "send:none"], "still permitted: once with the consent, once without")
                XCTAssertEqual(result, .success("start"))
                continue
            }
            XCTAssertEqual(steps.all, ["send:c-1", "mayRetry?", "refused:c-1"], "asked before the refusal is reported; sent once, with the consent")
            guard case let .failure(error) = result else {
                XCTFail("no retry: the local refusal")
                continue
            }
            XCTAssertEqual(error.failure, .unknownRefusal(code: "consent_required_local", status: 0))
            XCTAssertEqual(error.code, SGEntitlement.consentRequiredLocalCode)
            XCTAssertNil(error.status, "the retry was not sent")
        }
    }

    func test_aRefusedPermissionSendsNothingAndBeginsNoAttempt() async {
        let entitlement = self.entitlement()
        let asked = Recorder()
        entitlement.bindPermissionProvider = { _ in .refused }
        entitlement.bindConsentProvider = { account in
            asked.append("\(account)")
            return ["consent_id": "c-1"]
        }
        XCTAssertEqual(entitlement.bindPermission(accountPeerId: self.account), .refused)
        let result = await entitlement.beginBind(accountPeerId: self.account)
        guard case let .failure(error) = result else {
            return XCTFail("a refused account never starts a bind")
        }
        XCTAssertEqual(error.failure, .unknownRefusal(code: "consent_required_local", status: 0))
        XCTAssertEqual(error.code, "consent_required_local")
        XCTAssertNil(error.status, "nothing was sent")
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded.isEmpty)
        XCTAssertTrue(asked.all.isEmpty)
        XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account))

        entitlement.bindPermissionProvider = nil
        XCTAssertEqual(entitlement.bindPermission(accountPeerId: self.account), .allowed, "no provider: every account may link, as before")
    }

    // MARK: - bindConsentStale

    private let bindStartPath = "/v1/bind/start"

    private var staleAnswer: SGEntitlementPathStubProtocol.Response {
        return .json(409, ["error": "consent_stale", "message": "m"])
    }

    private var startAnswer: SGEntitlementPathStubProtocol.Response {
        return .json(200, ["code": "ABCDEFGH", "poll_token": "p", "expires_at": "2030-01-01T00:00:00Z"])
    }

    /// The `consent` object each `/bind/start` that reached the origin carried (nil: none).
    private func sentConsents() -> [NSDictionary?] {
        return SGEntitlementPathStubProtocol.recorded(path: self.bindStartPath).map { recorded in
            guard let body = recorded.body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return nil
            }
            return object["consent"] as? NSDictionary
        }
    }

    /// An entitlement whose `/bind/start` is scripted and whose account may link with `consent`.
    private func staleEntitlement(consent: [String: Any]?, answers: [SGEntitlementPathStubProtocol.Response], hook: Recorder) throws -> SGEntitlement {
        // `beginBind` signs nothing but needs the install key for `device_pubkey`. The logic-test host
        // has no keychain (`errSecNotAvailable`), so the key lives in an identity over the owned store.
        let identity = SGEntitlementDeviceIdentity.forTesting(store: self.store)
        _ = try XCTUnwrap(identity.publicKeySPKIBase64(), "the owned store could not hold an install key")
        SGEntitlementPathStubProtocol.reset([self.bindStartPath: answers])
        let entitlement = self.entitlement(identity: identity)
        entitlement.bindPermissionProvider = { _ in consent == nil ? .codeOnly : .allowed }
        entitlement.bindConsentProvider = { _ in consent }
        entitlement.bindConsentStale = { account, consentId in
            hook.append("\(account):\(consentId ?? "nil")")
        }
        return entitlement
    }

    func test_aManualStaleStartTellsTheHookOnceAndRetriesWithoutTheConsent() async throws {
        let hook = Recorder()
        let consent: [String: Any] = ["consent_id": "c-1", "action": "grant"]
        let entitlement = try self.staleEntitlement(consent: consent, answers: [self.staleAnswer, self.startAnswer], hook: hook)
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        guard case let .success(start) = result else {
            return XCTFail("the retry without the consent starts the bind: \(result)")
        }
        XCTAssertEqual(start.code, "ABCDEFGH")
        XCTAssertEqual(hook.all, ["\(self.account):c-1"], "exactly once, with the account and the consent_id")
        let sent = self.sentConsents()
        XCTAssertEqual(sent.count, 2, "the stale start and its one retry")
        XCTAssertEqual(sent.first??["consent_id"] as? String, "c-1")
        XCTAssertNil(sent.last ?? nil, "the retry carries no consent")
        XCTAssertTrue(entitlement.isBindInProgress(accountPeerId: self.account))
    }

    func test_aStaleConsentWithoutAnIdTellsTheHookNil() async throws {
        let hook = Recorder()
        let entitlement = try self.staleEntitlement(consent: ["action": "grant"], answers: [self.staleAnswer, self.startAnswer], hook: hook)
        _ = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        XCTAssertEqual(hook.all, ["\(self.account):nil"])
    }

    func test_aManualRetryThatIsStaleAgainNeverTellsTheHookTwice() async throws {
        let hook = Recorder()
        let entitlement = try self.staleEntitlement(consent: ["consent_id": "c-1"], answers: [self.staleAnswer, self.staleAnswer], hook: hook)
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        guard case let .failure(error) = result else {
            return XCTFail("both starts were refused")
        }
        XCTAssertEqual(error.code, "consent_stale")
        XCTAssertEqual(hook.all, ["\(self.account):c-1"], "the retry carried no consent, so it reports nothing")
        XCTAssertEqual(self.sentConsents().count, 2, "exactly one retry")
        XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account))
    }

    func test_anAutomaticStaleStartNeverTellsTheHook() async throws {
        let hook = Recorder()
        let entitlement = try self.staleEntitlement(consent: ["consent_id": "c-1"], answers: [self.staleAnswer, self.startAnswer], hook: hook)
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .auto)
        guard case let .failure(error) = result else {
            return XCTFail("the automatic link stops until a new grant")
        }
        XCTAssertEqual(error.code, "consent_stale")
        XCTAssertTrue(hook.all.isEmpty, ".auto reports through bindWithTelegramAttestation's .consentStale instead")
        XCTAssertEqual(self.sentConsents().count, 1, "no retry")
    }

    func test_aStartWithoutAConsentNeverTellsTheHook() async throws {
        let hook = Recorder()
        let entitlement = try self.staleEntitlement(consent: nil, answers: [self.staleAnswer, self.startAnswer], hook: hook)
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        if case .success = result {
            XCTFail("no consent attached, no fallback")
        }
        XCTAssertTrue(hook.all.isEmpty, "a code-only start attached no consent that could be stale")
        XCTAssertEqual(self.sentConsents().count, 1)
        XCTAssertNil(self.sentConsents().first ?? nil)
    }

    func test_theStaleHookStaysNilAndSilentInAnExtension() async {
        let hook = Recorder()
        SGEntitlementPathStubProtocol.reset([self.bindStartPath: [self.staleAnswer, self.startAnswer]])
        let entitlement = self.entitlement(isExtensionProcess: true)
        entitlement.bindConsentProvider = { _ in ["consent_id": "c-1"] }
        entitlement.bindConsentStale = { account, consentId in
            hook.append("\(account):\(consentId ?? "nil")")
        }
        XCTAssertNil(entitlement.bindConsentStale, "an extension never installs the hook")
        _ = await entitlement.beginBind(accountPeerId: self.account, purpose: .manual)
        XCTAssertTrue(hook.all.isEmpty, "and so is never told")

        let app = self.entitlement()
        let installed: (Int64, String?) -> Void = { _, _ in }
        app.bindConsentStale = installed
        XCTAssertNotNil(app.bindConsentStale, "the main app keeps it")
        app.bindConsentStale = nil
        XCTAssertNil(app.bindConsentStale)
    }

    // MARK: - Bind attempts

    func test_anEndedAttemptIsNeitherCurrentNorInProgress() {
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        var attempts = SGEntitlementBindAttempts()
        let attempt = attempts.begin(accountPeerId: self.account, purpose: .manual, now: began)
        XCTAssertTrue(attempts.isCurrent(attempt))
        XCTAssertTrue(attempts.isInProgress(accountPeerId: self.account, now: began))
        XCTAssertTrue(attempts.end(attempt))
        XCTAssertFalse(attempts.isCurrent(attempt), "its late confirmation can no longer be stored")
        XCTAssertFalse(attempts.isInProgress(accountPeerId: self.account, now: began))
        XCTAssertFalse(attempts.end(attempt), "ending twice changes nothing")
        XCTAssertEqual(attempts.record(accountPeerId: self.account)?.ended, true)
    }

    func test_anAttemptIsInProgressUntilItsStartExpires() {
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        var attempts = SGEntitlementBindAttempts()
        let attempt = attempts.begin(accountPeerId: self.account, purpose: .manual, now: began)
        XCTAssertTrue(attempts.isInProgress(accountPeerId: self.account, now: began.addingTimeInterval(299)))
        XCTAssertFalse(attempts.isInProgress(accountPeerId: self.account, now: began.addingTimeInterval(300)), "unknown expiry: the server's default bind TTL")
        attempts.setExpiresAt(began.addingTimeInterval(600), for: attempt)
        XCTAssertEqual(attempts.record(accountPeerId: self.account)?.expiresAt, began.addingTimeInterval(600))
        XCTAssertTrue(attempts.isInProgress(accountPeerId: self.account, now: began.addingTimeInterval(599)))
        XCTAssertFalse(attempts.isInProgress(accountPeerId: self.account, now: began.addingTimeInterval(600)))
        XCTAssertTrue(attempts.isCurrent(attempt), "an expired attempt is still the current one; it is simply not live")
    }

    func test_endingOrDatingAnOlderAttemptNeverTouchesTheNewerOne() {
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        var attempts = SGEntitlementBindAttempts()
        let older = attempts.begin(accountPeerId: self.account, purpose: .auto, now: began)
        let newer = attempts.begin(accountPeerId: self.account, purpose: .manual, now: began.addingTimeInterval(5))
        XCTAssertFalse(attempts.end(older))
        attempts.setExpiresAt(began.addingTimeInterval(10), for: older)
        XCTAssertTrue(attempts.isCurrent(newer))
        XCTAssertNil(attempts.record(accountPeerId: self.account)?.expiresAt)
        XCTAssertEqual(attempts.record(accountPeerId: self.account)?.purpose, .manual)
        XCTAssertTrue(attempts.isInProgress(accountPeerId: self.account, now: began.addingTimeInterval(60)))
        attempts.invalidate(accountPeerId: self.account)
        XCTAssertFalse(attempts.isCurrent(newer))
        XCTAssertNil(attempts.record(accountPeerId: self.account))
    }

    func test_aFailedAutoAttemptDoesNotBlockTheNextOne() async {
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        var attempts = SGEntitlementBindAttempts()
        let failed = attempts.begin(accountPeerId: self.account, purpose: .auto, now: began)
        attempts.end(failed) // its /bind/start failed at 0 s
        XCTAssertFalse(attempts.isInProgress(accountPeerId: self.account, now: began.addingTimeInterval(60)))
        let next = attempts.begin(accountPeerId: self.account, purpose: .auto, now: began.addingTimeInterval(60))
        XCTAssertTrue(attempts.isCurrent(next))
        XCTAssertTrue(attempts.isInProgress(accountPeerId: self.account, now: began.addingTimeInterval(60)))

        // The same through the entitlement: a start that cannot be sent ends its own attempt.
        let entitlement = self.entitlement(withClient: false)
        let result = await entitlement.beginBind(accountPeerId: self.account, purpose: .auto)
        if case .success = result {
            XCTFail("no client, no start")
        }
        XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account), "a failed start never blocks the next attempt")
        let attempt = entitlement.newBindAttempt(accountPeerId: self.account, purpose: .auto)
        XCTAssertTrue(entitlement.isBindInProgress(accountPeerId: self.account))
        XCTAssertTrue(entitlement.isCurrentBindAttempt(attempt))
        entitlement.endBindAttempt(attempt)
        XCTAssertFalse(entitlement.isBindInProgress(accountPeerId: self.account))
    }

    // MARK: - Logout's final send

    func test_logoutAsksForTheFinalUploadsOnceBeforeAnythingIsRemoved() {
        let entitlement = self.entitlement(withClient: false)
        self.seed(self.linked)
        let asked = Recorder()
        entitlement.preRevokeUploadsProvider = { [weak entitlement] account in
            let linked = entitlement?.isLinked(accountPeerId: account) ?? false
            asked.append("\(account):\(linked)")
            return [Data("{}".utf8)]
        }
        entitlement.logout(accountPeerId: self.account)
        XCTAssertEqual(asked.all, ["\(self.account):true"], "captured synchronously while the session still existed")
        XCTAssertFalse(entitlement.isLinked(accountPeerId: self.account))
    }

    func test_theFinalSendDeliversAtMostThreeBodiesWithinItsDeadline() async {
        let bodies = (0 ..< 5).map { Data("{\"n\":\($0)}".utf8) }
        let sent = Recorder()
        await SGEntitlement.sendFinalUploads(bodies, deadline: 10, uptime: { 0 }, send: { body in
            sent.append(String(decoding: body, as: UTF8.self))
        })
        XCTAssertEqual(sent.all, ["{\"n\":0}", "{\"n\":1}", "{\"n\":2}"], "at most three, in order")

        let slow = Recorder()
        var clock: TimeInterval = 0
        await SGEntitlement.sendFinalUploads(bodies, deadline: 10, uptime: { clock }, send: { body in
            slow.append(String(decoding: body, as: UTF8.self))
            clock += 6
        })
        XCTAssertEqual(slow.all, ["{\"n\":0}", "{\"n\":1}"], "none starts past the 10 s budget")
        XCTAssertEqual(SGEntitlement.logoutFinalUploadLimit, 3)
        XCTAssertEqual(SGEntitlement.logoutFinalUploadBudget, 10)
    }
}
