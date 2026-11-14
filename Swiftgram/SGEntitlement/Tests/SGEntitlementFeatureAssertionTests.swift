import XCTest
import CryptoKit
@testable import SGEntitlement

/// Zenlygram — the feature-assertion facade (`SGEntitlement.featureAssertion(audience:accountPeerId:)`),
/// the only door a separate first-party service (Lenta) has to the linked Telegram account.
///
/// Driven through the real facade, the real `SGEntitlementClient`, the real per-account gate and the
/// real `apply`, on an instance that owns its store, scheduler and device identity (a software P-256
/// key in the owned store: the simulator is a keychainless build). The origin is scripted
/// (`SGFeatureAssertionOrigin`, a `URLProtocol` on the client's own session) on reserved `.invalid`
/// hosts, so nothing reaches DNS or the network. The live `POST /v1/assertions` is not exercised:
/// the server route does not exist yet.
final class SGEntitlementFeatureAssertionTests: XCTestCase {
    private let account: Int64 = 69_229_542_147
    private let otherAccount: Int64 = 69_229_542_148
    private let audience = "lenta"
    private let origin = "api.assertion.zenlygram.invalid"
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var store: SGEntitlementStore!
    private var identity: SGEntitlementDeviceIdentity!
    private var entitlement: SGEntitlement!

    override func setUp() {
        super.setUp()
        SGFeatureAssertionOrigin.reset()
        SGPolicyStubProtocol.reset(routes: [:])
        self.storeSuite = "SGEntitlementFeatureAssertionTests.store.\(UUID().uuidString)"
        self.schedulerSuite = "SGEntitlementFeatureAssertionTests.scheduler.\(UUID().uuidString)"
        self.store = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
        self.identity = SGEntitlementDeviceIdentity(store: self.store)
        self.entitlement = SGEntitlement(
            store: self.store,
            identity: self.identity,
            scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite))
        )
    }

    override func tearDown() {
        SGFeatureAssertionOrigin.reset()
        SGPolicyStubProtocol.reset(routes: [:])
        self.store.clearSession(accountPeerId: self.account)
        self.store.clearSession(accountPeerId: self.otherAccount)
        UserDefaults(suiteName: self.storeSuite)?.removePersistentDomain(forName: self.storeSuite)
        UserDefaults(suiteName: self.schedulerSuite)?.removePersistentDomain(forName: self.schedulerSuite)
        self.entitlement = nil
        self.identity = nil
        self.store = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func client(protocolClass: AnyClass = SGFeatureAssertionOrigin.self) -> SGEntitlementClient {
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://\(self.origin)/v1")!, appVersion: "1.0", osVersion: "27.0")
        configuration.protocolClasses = [protocolClass]
        return SGEntitlementClient(configuration: configuration, store: self.store, identity: self.identity)
    }

    private func bind(_ accountPeerId: Int64, refreshToken: String) {
        let written = self.store.updateSession(accountPeerId: accountPeerId) { material in
            material.refreshToken = refreshToken
            material.accountId = "01JB8Q"
            material.deviceId = "01JB8R"
        }
        guard case .success = written else {
            return XCTFail("the owned store could not persist the bind: \(written)")
        }
    }

    private func refreshToken(_ accountPeerId: Int64) -> String? {
        return self.store.session(accountPeerId: accountPeerId).refreshToken
    }

    private static let minted: [String: Any] = [
        "assertion": "eyJhbGciOiJFUzI1NiJ9.eyJhdWQiOiJsZW50YSJ9.c2ln",
        "expires_at": "2026-10-29T12:05:00Z",
        "server_time": "2026-10-29T12:00:00Z"
    ]

    private static func error(_ code: String) -> [String: Any] {
        return ["error": code, "message": code, "server_time": "2026-10-29T12:00:00Z"]
    }

    /// The DeviceAuth signature of `request` verifies under this install's public key.
    private func assertSignedByThisDevice(_ request: URLRequest, file: StaticString = #filePath, line: UInt = #line) {
        guard let deviceId = request.value(forHTTPHeaderField: "X-Device-Id"),
              let nonce = request.value(forHTTPHeaderField: "X-Device-Nonce"),
              let ts = request.value(forHTTPHeaderField: "X-Device-Ts"),
              let sig = request.value(forHTTPHeaderField: "X-Device-Sig").flatMap({ Data(base64Encoded: $0) }) else {
            return XCTFail("the request carries no complete DeviceAuth set", file: file, line: line)
        }
        XCTAssertEqual(deviceId, self.identity.deviceId(), file: file, line: line)
        guard let spki = self.identity.publicKeySPKIBase64().flatMap({ Data(base64Encoded: $0) }),
              let publicKey = try? P256.Signing.PublicKey(derRepresentation: spki),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig) else {
            return XCTFail("no verifiable device key or signature", file: file, line: line)
        }
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data("\(deviceId)\n\(nonce)\n\(ts)".utf8)), "the DeviceAuth signature does not verify", file: file, line: line)
    }

    // MARK: - Shape: Lenta gets the assertion string and nothing else

    func test_aMintedAssertionIsReturnedAsTheBareStringAndTheRequestIsTheContract() async throws {
        self.bind(self.account, refreshToken: "tok-a")
        SGFeatureAssertionOrigin.script([.json(200, Self.minted)])
        let result: Result<String, SGEntitlementRequestError> = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: self.client())

        XCTAssertEqual(try result.get(), Self.minted["assertion"] as? String, "the facade hands out the assertion string only")
        let requests = SGFeatureAssertionOrigin.requests
        XCTAssertEqual(requests.count, 1)
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://\(self.origin)/v1/assertions")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-a")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent.body) as? [String: String], ["audience": self.audience])
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "Idempotency-Key"), "every call mints a new assertion: nothing to de-duplicate")
        self.assertSignedByThisDevice(sent.request)
        XCTAssertEqual(self.refreshToken(self.account), "tok-a", "a mint never touches the session")
    }

    // MARK: - Account gate

    func test_anUnlinkedAccountIsRefusedAndNothingIsSent() async {
        self.bind(self.otherAccount, refreshToken: "tok-other")
        SGFeatureAssertionOrigin.script([.json(200, Self.minted)])
        let result = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: self.client())

        guard case let .failure(error) = result else {
            return XCTFail("an unlinked account got an assertion: \(result)")
        }
        XCTAssertEqual(error.failure, .session(.unauthenticated))
        XCTAssertEqual(error.message, "not linked")
        XCTAssertTrue(SGFeatureAssertionOrigin.requests.isEmpty, "another account's session was presented for this one")
        XCTAssertEqual(self.refreshToken(self.otherAccount), "tok-other")
    }

    func test_eachAccountPresentsOnlyItsOwnSession() async {
        self.bind(self.account, refreshToken: "tok-a")
        self.bind(self.otherAccount, refreshToken: "tok-b")
        SGFeatureAssertionOrigin.script([.json(200, Self.minted), .json(200, Self.minted)])
        let client = self.client()
        _ = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.otherAccount, client: client)
        _ = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: client)
        XCTAssertEqual(SGFeatureAssertionOrigin.requests.map { $0.request.value(forHTTPHeaderField: "Authorization") }, ["Bearer tok-b", "Bearer tok-a"])
    }

    func test_waitsBehindTheAccountGateAndPresentsTheTokenARotationLeft() async throws {
        self.bind(self.account, refreshToken: "tok-old")
        SGFeatureAssertionOrigin.script([.json(200, Self.minted)])
        let client = self.client()
        // A rotation of the same account holds the gate.
        await client.accountGate.acquire(accountPeerId: self.account)
        let entitlement = self.entitlement!
        let audience = self.audience
        let account = self.account
        let pending = Task {
            await entitlement.featureAssertion(audience: audience, accountPeerId: account, client: client)
        }
        let deadline = Date().addingTimeInterval(5.0)
        while client.accountGate.state(accountPeerId: account).waiting == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(client.accountGate.state(accountPeerId: account).waiting, 1, "the mint did not queue behind the rotation")
        XCTAssertTrue(SGFeatureAssertionOrigin.requests.isEmpty, "a mint was sent while a rotation held the account")

        self.bind(self.account, refreshToken: "tok-rotated")
        client.accountGate.release(accountPeerId: account)
        let result = await pending.value

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(SGFeatureAssertionOrigin.requests.map { $0.request.value(forHTTPHeaderField: "Authorization") }, ["Bearer tok-rotated"], "the replaced token was presented")
        XCTAssertEqual(client.accountGate.state(accountPeerId: account).isHeld, false, "the facade left the gate held")
    }

    func test_otherAccountsDoNotWaitForEachOther() async {
        self.bind(self.account, refreshToken: "tok-a")
        SGFeatureAssertionOrigin.script([.json(200, Self.minted)])
        let client = self.client()
        await client.accountGate.acquire(accountPeerId: self.otherAccount)
        let result = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: client)
        client.accountGate.release(accountPeerId: self.otherAccount)
        XCTAssertNoThrow(try result.get())
    }

    // MARK: - Failures land on the presenting session

    func test_aRevokedSessionDropsOnlyThePresentingAccountsToken() async {
        self.bind(self.account, refreshToken: "tok-a")
        self.bind(self.otherAccount, refreshToken: "tok-b")
        SGFeatureAssertionOrigin.script([.json(401, Self.error("session_revoked"))])
        let result = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: self.client())

        guard case let .failure(error) = result else {
            return XCTFail("a revoked session minted: \(result)")
        }
        XCTAssertEqual(error.failure, .session(.sessionRevoked))
        XCTAssertEqual(SGFeatureAssertionOrigin.requests.count, 1, "a revoked session is never retried")
        XCTAssertNil(self.refreshToken(self.account), "the failing session was kept")
        XCTAssertEqual(self.refreshToken(self.otherAccount), "tok-b", "another account's session was dropped")
    }

    func test_aLateFailureNeverDropsTheSessionThatReplacedThePresentedOne() async {
        self.bind(self.account, refreshToken: "tok-presented")
        let store = self.store!
        let account = self.account
        SGFeatureAssertionOrigin.script([.json(401, Self.error("session_revoked"))], onRequest: {
            // A re-bind lands while the mint is in flight.
            _ = store.updateSession(accountPeerId: account) { material in
                material.refreshToken = "tok-rebound"
            }
        })
        let result = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: self.client())

        guard case .failure = result else {
            return XCTFail("a revoked session minted: \(result)")
        }
        XCTAssertEqual(self.refreshToken(self.account), "tok-rebound", "the failure was applied to a session that did not present")
    }

    // MARK: - Every attempt is signed afresh

    func test_aReplayedNonceIsRetriedOnceWithAFreshlySignedCredentialSet() async {
        self.bind(self.account, refreshToken: "tok-a")
        SGFeatureAssertionOrigin.script([.json(401, Self.error("nonce_replayed")), .json(200, Self.minted)])
        let result = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: self.client())

        XCTAssertEqual(try? result.get(), Self.minted["assertion"] as? String)
        let requests = SGFeatureAssertionOrigin.requests.map(\.request)
        XCTAssertEqual(requests.count, 2, "exactly one retry")
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-a", "the retry presented another session")
            self.assertSignedByThisDevice(request)
        }
        let nonces = requests.compactMap { $0.value(forHTTPHeaderField: "X-Device-Nonce") }
        XCTAssertEqual(Set(nonces).count, 2, "the retry re-sent the captured nonce")
        XCTAssertNotEqual(requests.first?.value(forHTTPHeaderField: "X-Device-Sig"), requests.last?.value(forHTTPHeaderField: "X-Device-Sig"))
        XCTAssertEqual(self.refreshToken(self.account), "tok-a", "a recovered nonce failure is not a session failure")
    }

    func test_twoMintsNeverShareACredentialSet() async {
        self.bind(self.account, refreshToken: "tok-a")
        SGFeatureAssertionOrigin.script([.json(200, Self.minted), .json(200, Self.minted)])
        let client = self.client()
        _ = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: client)
        _ = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: client)
        let nonces = SGFeatureAssertionOrigin.requests.compactMap { $0.request.value(forHTTPHeaderField: "X-Device-Nonce") }
        XCTAssertEqual(nonces.count, 2)
        XCTAssertEqual(Set(nonces).count, 2)
    }

    // MARK: - Redirects

    func test_aRedirectIsRefusedAndTheSessionNeverLeavesForTheLocationHost() async {
        self.bind(self.account, refreshToken: "tok-a")
        let elsewhere = "elsewhere.assertion.zenlygram.invalid"
        SGPolicyStubProtocol.reset(routes: [
            self.origin: SGPolicyStubProtocol.Route(status: 307, redirectTo: URL(string: "https://\(elsewhere)/v1/assertions")!),
            elsewhere: SGPolicyStubProtocol.Route(headers: ["Content-Type": "application/json"], chunks: [SGPolicyStubProtocol.json(Self.minted)])
        ])
        let result = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: self.client(protocolClass: SGPolicyStubProtocol.self))

        if case let .success(assertion) = result {
            XCTFail("the redirect target's assertion was accepted: \(assertion)")
        }
        let requests = SGPolicyStubProtocol.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-a", "premise: the origin request was signed and sent")
        XCTAssertEqual(requests.compactMap { $0.url?.host }, [self.origin], "the bearer and DeviceAuth set were replayed to another host")
        XCTAssertEqual(self.refreshToken(self.account), "tok-a")
    }
    // An unchanged control: a feature-purpose refusal is not a revoked Pro session.
    // Uses the real facade/client/apply and the existing owned store + URLProtocol origin.
    func test_codeMatchRequiredPreservesSavedCredentialsAndInstallKey() async throws {
        self.bind(self.account, refreshToken: "tok-presenting")
        self.bind(self.otherAccount, refreshToken: "tok-unrelated")
        let key = try XCTUnwrap(self.identity.publicKeySPKIBase64())
        let presented = self.store.session(accountPeerId: self.account)
        let unrelated = self.store.session(accountPeerId: self.otherAccount)
        SGFeatureAssertionOrigin.script([.json(403, Self.error("code_match_required"))])

        let result = await self.entitlement.featureAssertion(audience: self.audience, accountPeerId: self.account, client: self.client())

        guard case let .failure(error) = result else {
            return XCTFail("the real Core 403 was not surfaced as a refusal")
        }
        XCTAssertEqual(error.status, 403)
        XCTAssertEqual(error.code, "code_match_required")
        XCTAssertEqual(self.store.session(accountPeerId: self.account), presented, "a feature refusal mutated the presenting session")
        XCTAssertEqual(self.store.session(accountPeerId: self.otherAccount), unrelated, "a feature refusal mutated another account")
        XCTAssertEqual(self.identity.publicKeySPKIBase64(), key, "a feature refusal regenerated the install key")
        XCTAssertEqual(SGFeatureAssertionOrigin.requests.count, 1, "a stable refusal was silently retried")
        XCTAssertEqual(SGFeatureAssertionOrigin.requests.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-presenting")
    }

}

/// Zenlygram — a scripted origin answering requests in order from a queue, recording each request
/// with its body (`URLProtocol` sees the body as a stream). An unscripted request fails closed.
final class SGFeatureAssertionOrigin: URLProtocol {
    enum Answer {
        case json(Int, [String: Any])
    }

    struct Recorded {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    private static var answers: [Answer] = []
    private static var recorded: [Recorded] = []
    private static var onRequest: (() -> Void)?

    static func reset() {
        self.script([])
    }

    static func script(_ answers: [Answer], onRequest: (() -> Void)? = nil) {
        self.lock.lock()
        self.answers = answers
        self.recorded = []
        self.onRequest = onRequest
        self.lock.unlock()
    }

    static var requests: [Recorded] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.recorded
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let request = self.request
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        Self.lock.lock()
        Self.recorded.append(Recorded(request: request, body: body))
        let answer = Self.answers.isEmpty ? nil : Self.answers.removeFirst()
        let hook = Self.onRequest
        Self.lock.unlock()
        hook?()

        guard let answer, let url = request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch answer {
        case let .json(status, object):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: SGPolicyStubProtocol.json(object))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
    }

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else {
            return Data()
        }
        stream.open()
        defer {
            stream.close()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
