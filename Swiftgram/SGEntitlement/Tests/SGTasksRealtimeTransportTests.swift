import XCTest
import CryptoKit
import Security
@testable import SGEntitlement

/// Zenlygram — the two named realtime calls through the REAL Tasks exchange (capture, gate, fresh
/// DeviceAuth per attempt, per-code session handling, credential fence, response bound) with a
/// scripted origin at the `fetch` seam.
final class SGTasksRealtimeTransportTests: XCTestCase {
    private let account: Int64 = 777_000
    private let key = "appkey20charsxyz0123"
    private let channel = "private-tasks." + String(repeating: "Z", count: 43)
    private var auth: String {
        return self.key + ":" + String(repeating: "ab", count: 32)
    }

    private final class Origin: @unchecked Sendable {
        private let lock = NSLock()
        var token: String? = "tok-1"
        var answers: [Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass>] = []
        var duringFetch: (() -> Void)?
        private(set) var requests: [URLRequest] = []
        private(set) var limits: [Int] = []
        private(set) var applied: [SGEntitlementSessionCredential] = []
        private(set) var noted: [Date] = []
        private(set) var proofs = 0
        private var nonce = 0

        func storedToken() -> String? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.token
        }

        func credentials() -> SGEntitlementDeviceCredentials {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.nonce += 1
            return SGEntitlementDeviceCredentials(deviceId: "dev", nonce: "n\(self.nonce)", timestamp: 1_800_000_000, signature: "s\(self.nonce)")
        }

        func fetch(_ request: URLRequest, limit: Int) -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> {
            self.duringFetch?()
            self.lock.lock()
            defer { self.lock.unlock() }
            self.requests.append(request)
            self.limits.append(limit)
            return self.answers.isEmpty ? .failure(.offline(.timeout)) : self.answers.removeFirst()
        }

        func apply(_ credential: SGEntitlementSessionCredential) {
            self.lock.lock()
            self.applied.append(credential)
            self.lock.unlock()
        }

        func note(_ date: Date) {
            self.lock.lock()
            self.noted.append(date)
            self.lock.unlock()
        }

        func proof() -> String? {
            self.lock.lock()
            self.proofs += 1
            self.lock.unlock()
            return "never-sent"
        }
    }

    private func transport(_ origin: Origin) -> SGTasksTransport {
        return SGTasksTransport(environment: SGTasksTransport.Environment(
            baseURL: URL(string: "https://tasks.zenlygram.test/v1")!,
            timeout: 5,
            gate: SGEntitlementAccountGate(),
            storedRefreshToken: { _ in origin.storedToken() },
            deviceCredentials: { origin.credentials() },
            noteServerTime: { origin.note($0) },
            adoptServerOffset: { _ in },
            creationProof: { _ in origin.proof() },
            applySessionFailure: { _, credential in origin.apply(credential) },
            fetch: { request, _, limit in origin.fetch(request, limit: limit) }
        ))
    }

    private static func answer(_ status: Int, _ body: String, retryAfter: Int? = nil) -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> {
        return .success(SGTasksTransport.HTTPAnswer(status: status, body: Data(body.utf8), retryAfter: retryAfter))
    }

    private static func error(_ status: Int, _ code: String) -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> {
        return self.answer(status, #"{"error":"\#(code)","message":"m","server_time":"2026-10-25T00:00:00Z"}"#)
    }

    private var enabledBody: String {
        return #"{"schema_version":1,"enabled":true,"ws_url":"wss://tasks.zenlygram.test/realtime/app/\#(self.key)","activity_timeout":30,"server_time":"2026-10-25T00:00:01Z"}"#
    }

    private var authBody: String {
        return #"{"schema_version":1,"channel":"\#(self.channel)","auth":"\#(self.auth)","server_time":"2026-10-25T00:00:02Z"}"#
    }

    private let socketId = SGTasksRealtime.SocketId("123.456")!

    // MARK: - GET /v1/tasks/realtime

    func test_theMetadataGetIsExactlyTheDeviceAuthReadWithNoQueryOrBody() async throws {
        let origin = Origin()
        origin.answers = [Self.answer(200, self.enabledBody)]
        let metadata = try await self.transport(origin).realtimeMetadata(accountPeerId: self.account).get()
        guard case let .enabled(endpoint) = metadata.availability else {
            return XCTFail("enabled")
        }
        XCTAssertEqual(endpoint.origin, "https://tasks.zenlygram.test")
        let request = try XCTUnwrap(origin.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://tasks.zenlygram.test/v1/tasks/realtime")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Accept": "application/json",
            "Authorization": "Bearer tok-1",
            "X-Device-Id": "dev",
            "X-Device-Nonce": "n1",
            "X-Device-Ts": "1800000000",
            "X-Device-Sig": "s1",
            // `x-wire-negotiation`: an R4 client sends it on every /v1/tasks/* request, realtime included.
            "X-Tasks-Wire": "4"
        ], "no Content-Type, Idempotency-Key, app/OS version or refresh-token fallback")
        XCTAssertEqual(origin.limits, [SGTasksRealtime.responseLimit])
        XCTAssertEqual(origin.noted, [SGTasksWire.Instant("2026-10-25T00:00:01Z")!.date], "the existing exchange's clock handling is unchanged")
        XCTAssertEqual(origin.proofs, 0)
    }

    func test_aMetadataEndpointOffTheApiOriginIsMalformedNeverLive() async {
        for wsURL in ["wss://evil.test/realtime/app/\(self.key)", "wss://tasks.zenlygram.test:8443/realtime/app/\(self.key)", "wss://tasks.zenlygram.test/realtime/app/\(self.key)?x=1"] {
            let origin = Origin()
            origin.answers = [Self.answer(200, self.enabledBody.replacingOccurrences(of: "wss://tasks.zenlygram.test/realtime/app/\(self.key)", with: wsURL))]
            let result = await self.transport(origin).realtimeMetadata(accountPeerId: self.account)
            XCTAssertEqual(result.failureKind, .malformedResponse, wsURL)
        }
        let disabledWithURL = Origin()
        disabledWithURL.answers = [Self.answer(200, self.enabledBody.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":false"#))]
        let refused = await self.transport(disabledWithURL).realtimeMetadata(accountPeerId: self.account)
        XCTAssertEqual(refused.failureKind, .malformedResponse)
    }

    func test_theKillSwitchIsDisabledNotAFailure() async throws {
        let origin = Origin()
        origin.answers = [Self.answer(200, #"{"schema_version":1,"enabled":false,"ws_url":null,"activity_timeout":30,"server_time":"2026-10-25T00:00:01Z"}"#)]
        let metadata = try await self.transport(origin).realtimeMetadata(accountPeerId: self.account).get()
        XCTAssertEqual(metadata.availability, .disabled)
        let outage = Origin()
        outage.answers = [Self.error(503, "tasks_unavailable")]
        let result = await self.transport(outage).realtimeMetadata(accountPeerId: self.account)
        guard case let .failure(error) = result else {
            return XCTFail("a broken service is a 503, never disabled")
        }
        XCTAssertEqual(error.kind, .unavailable)
        XCTAssertFalse(error.outcomeUnknown, "a read commits nothing")
    }

    // MARK: - POST /v1/tasks/realtime/auth

    func test_theAuthPostCarriesExactlyTheSocketIdAndIsBoundToIt() async throws {
        let origin = Origin()
        origin.answers = [Self.answer(200, self.authBody)]
        let subscription = try await self.transport(origin).realtimeAuth(socketId: self.socketId, accountPeerId: self.account).get()
        XCTAssertEqual(subscription.socketId, self.socketId)
        XCTAssertEqual(subscription.channel, self.channel)
        let request = try XCTUnwrap(origin.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://tasks.zenlygram.test/v1/tasks/realtime/auth", "empty query")
        XCTAssertEqual(request.httpBody, Data(#"{"socket_id":"123.456"}"#.utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"), "a read-budget call, not a mutation")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(origin.proofs, 0, "never creation evidence")
    }

    func test_everyAuthorizationIsAFreshSignedRequest() async throws {
        let origin = Origin()
        origin.answers = [Self.answer(200, self.authBody), Self.answer(200, self.authBody)]
        let transport = self.transport(origin)
        _ = try await transport.realtimeAuth(socketId: self.socketId, accountPeerId: self.account).get()
        _ = try await transport.realtimeAuth(socketId: SGTasksRealtime.SocketId("9.9")!, accountPeerId: self.account).get()
        XCTAssertEqual(origin.requests.map { $0.value(forHTTPHeaderField: "X-Device-Nonce") }, ["n1", "n2"])
        XCTAssertEqual(origin.requests.map { $0.httpBody }, [Data(#"{"socket_id":"123.456"}"#.utf8), Data(#"{"socket_id":"9.9"}"#.utf8)])
    }

    func test_aMalformedAuthAnswerIsRefused() async {
        let variants = [
            self.authBody.replacingOccurrences(of: self.channel, with: "private-tasks.short"),
            self.authBody.replacingOccurrences(of: String(repeating: "ab", count: 32), with: String(repeating: "AB", count: 32)),
            self.authBody.replacingOccurrences(of: #""schema_version":1"#, with: #""schema_version":2"#),
            self.authBody.replacingOccurrences(of: "}", with: #","socket_id":"9.9"}"#)
        ]
        for body in variants {
            let origin = Origin()
            origin.answers = [Self.answer(200, body)]
            let result = await self.transport(origin).realtimeAuth(socketId: self.socketId, accountPeerId: self.account)
            XCTAssertEqual(result.failureKind, .malformedResponse, body)
        }
    }

    // MARK: - Refusals keep the existing per-code semantics

    func test_anUnlinkedAccountPausesTasksOnlyAndTouchesNoSession() async {
        let origin = Origin()
        origin.answers = [Self.error(403, "tasks_account_not_linked")]
        let result = await self.transport(origin).realtimeAuth(socketId: self.socketId, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .accountNotLinked)
        XCTAssertTrue(origin.applied.isEmpty, "a valid (e.g. Apple-only) session and key are never dropped")
        XCTAssertEqual(origin.storedToken(), "tok-1")
    }

    func test_aDeviceAuthRefusalIsAppliedToTheCapturedSessionOnly() async {
        let origin = Origin()
        origin.answers = [Self.error(401, "device_revoked")]
        let result = await self.transport(origin).realtimeMetadata(accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .session(.deviceRevoked))
        XCTAssertEqual(origin.applied, [SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1")])
    }

    func test_rateLimitAndValidationRefusalsAreTyped() async {
        let throttled = Origin()
        throttled.answers = [Self.answer(429, #"{"error":"tasks_rate_limited","message":"","server_time":"2026-10-25T00:00:00Z"}"#, retryAfter: 17)]
        let limited = await self.transport(throttled).realtimeAuth(socketId: self.socketId, accountPeerId: self.account)
        guard case let .failure(error) = limited else {
            return XCTFail("429")
        }
        XCTAssertEqual(error.kind, .rateLimited)
        XCTAssertEqual(error.retryAfter, 17)

        for status in [422, 415] {
            let origin = Origin()
            origin.answers = [Self.error(status, "tasks_invalid_request")]
            let result = await self.transport(origin).realtimeAuth(socketId: self.socketId, accountPeerId: self.account)
            XCTAssertEqual(result.failureKind, .invalidRequest, "\(status)")
        }
    }

    func test_anAnswerThatOutlivedItsSessionIsCredentialChanged() async {
        let origin = Origin()
        origin.answers = [Self.answer(200, self.authBody)]
        origin.duringFetch = {
            origin.token = "tok-2"
        }
        let result = await self.transport(origin).realtimeAuth(socketId: self.socketId, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .credentialChanged, "a subscription signed under a replaced session is never handed out")
    }

    func test_noSessionSendsNothing() async {
        let origin = Origin()
        origin.token = nil
        let result = await self.transport(origin).realtimeMetadata(accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .notSignedIn)
        XCTAssertTrue(origin.requests.isEmpty)
    }
}

/// A store of the test's own: an owned defaults suite and a Keychain answering
/// `errSecMissingEntitlement`, so every write takes the keychainless fallback with its real
/// read-back (the same fixture as `SGEntitlementOwnedStore`, kept here so the focused realtime target
/// needs no other test file).
private enum SGTasksRealtimeOwnedStore {
    static func make(suiteName: String) -> SGEntitlementStore {
        return SGEntitlementStore(
            defaults: UserDefaults(suiteName: suiteName),
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            )
        )
    }
}

/// The realtime owner revalidates its socket on `didChangeNotification` when the session marker
/// moved. Re-adopting the SAME grant under a NEW stored session (same account, device and grant, a
/// new refresh token — what a same-principal bind or a rotation leaves behind) must post that notice
/// even though the entitlement state is unchanged: `adopt` resets the cached decision, so its
/// recompute posts. Driven through the real store write and the real `adopt`; `completeBind` itself
/// (whose bind-attempt check needs the networked `beginBind`) is not exercised here.
final class SGTasksRealtimeSessionNoticeTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private let key = P256.Signing.PrivateKey()
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var store: SGEntitlementStore!
    private var entitlement: SGEntitlement!

    override func setUp() {
        super.setUp()
        self.storeSuite = "SGTasksRealtimeSessionNoticeTests.store.\(UUID().uuidString)"
        self.schedulerSuite = "SGTasksRealtimeSessionNoticeTests.scheduler.\(UUID().uuidString)"
        self.store = SGTasksRealtimeOwnedStore.make(suiteName: self.storeSuite)
        self.entitlement = SGEntitlement(store: self.store, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)))
        SGEntitlementTokenVerifier.resetKeyCacheForTesting()
        self.entitlement.overridePinnedKeys(SGEntitlementTestToken.pinned(self.key, kid: "k2026a"))
    }

    override func tearDown() {
        self.store.clearSession(accountPeerId: self.account)
        UserDefaults(suiteName: self.storeSuite)?.removePersistentDomain(forName: self.storeSuite)
        UserDefaults(suiteName: self.schedulerSuite)?.removePersistentDomain(forName: self.schedulerSuite)
        self.entitlement = nil
        self.store = nil
        super.tearDown()
    }

    private func bind(refreshToken: String) {
        let written = self.store.updateSession(accountPeerId: self.account) { material in
            material.refreshToken = refreshToken
            material.accountId = "01JB8Q"
            material.deviceId = "01JB8R"
            material.pushTokenDigest = nil
        }
        guard case .success = written else {
            return XCTFail("the owned store could not persist the bind: \(written)")
        }
    }

    func test_reAdoptingTheSameGrantUnderANewSessionNotifiesAndMovesTheMarker() {
        let token = SGEntitlementTestToken.make(key: self.key, payload: SGEntitlementTestToken.claims())
        self.bind(refreshToken: "bound-1")
        let first = self.expectation(forNotification: SGEntitlement.didChangeNotification, object: nil)
        XCTAssertTrue(self.entitlement.adopt(entitlement: token, credential: SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "bound-1")))
        self.wait(for: [first], timeout: 2)
        let before = self.entitlement.tasksRealtimeSessionMarker(accountPeerId: self.account)
        let principal = self.entitlement.tasksPrincipal(accountPeerId: self.account)
        let state = self.entitlement.state

        // Every notice the first adoption queued on main is delivered before the second expectation
        // exists, so only the re-adoption below can fulfil it.
        let drained = self.expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        self.wait(for: [drained], timeout: 2)

        // A new stored session with the same account, device and grant, then re-adoption.
        self.bind(refreshToken: "bound-2")
        let notice = self.expectation(forNotification: SGEntitlement.didChangeNotification, object: nil)
        XCTAssertTrue(self.entitlement.adopt(entitlement: token, credential: SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "bound-2")))
        self.wait(for: [notice], timeout: 2)

        XCTAssertEqual(self.entitlement.state, state, "fixture: the re-bind is entitlement-neutral")
        XCTAssertEqual(self.entitlement.tasksPrincipal(accountPeerId: self.account), principal, "same principal")
        let after = self.entitlement.tasksRealtimeSessionMarker(accountPeerId: self.account)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(after, before, "the realtime owner sees a changed session and revalidates its channel")
    }

    func test_logoutClearsTheMarker() {
        self.bind(refreshToken: "bound-1")
        XCTAssertNotNil(self.entitlement.tasksRealtimeSessionMarker(accountPeerId: self.account))
        self.store.clearSession(accountPeerId: self.account)
        XCTAssertNil(self.entitlement.tasksRealtimeSessionMarker(accountPeerId: self.account))
    }
}

private extension Result where Failure == SGTasksError {
    var failureKind: SGTasksError.Kind? {
        if case let .failure(error) = self {
            return error.kind
        }
        return nil
    }
}
