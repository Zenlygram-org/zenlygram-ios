import XCTest
import Security
@testable import SGEntitlement

/// Zenlygram — the authenticated entitlement client never follows an HTTP redirect, like the policy
/// and Tasks transports (`SGEntitlementBoundedFetch`, `SGTasksBoundedExchange`). A 3xx is itself the
/// answer: no request — no `Authorization: Bearer <refresh token>`, no DeviceAuth headers, no 307/308
/// body with `device_id` / `device_pubkey` / `signed_transaction` — ever leaves for the `Location`
/// host, and nothing the redirect target says (its `server_time` included) is read.
///
/// The client's own session runs against a scripted origin (`SGPolicyStubProtocol`, the real
/// `URLSession` delegate path) through `Configuration.protocolClasses`; both hosts are reserved
/// `.invalid` names, and the stub answers every request itself (an unknown host fails closed), so
/// nothing reaches DNS or the network. A control proves the stub's redirect IS followed by a default
/// session, so a refusal is the client's own doing — and before the refusal exists, the client tests
/// fail by reaching the foreign host, not by missing the stub.
final class SGEntitlementClientRedirectTests: XCTestCase {
    private let origin = "api.redirect.zenlygram.invalid"
    private let elsewhere = "elsewhere.zenlygram.invalid"
    private var suite = ""
    private var store: SGEntitlementStore!

    override func setUp() {
        super.setUp()
        SGPolicyStubProtocol.reset(routes: [:])
        self.suite = "SGEntitlementClientRedirectTests.\(UUID().uuidString)"
        self.store = SGEntitlementStore(
            defaults: UserDefaults(suiteName: self.suite),
            // Every write takes the store's keychainless fallback: nothing reaches the real Keychain.
            keychain: SGEntitlementKeychainAccess(
                read: { _ in .unreadable(errSecMissingEntitlement) },
                write: { _, _ in errSecMissingEntitlement },
                delete: { _ in }
            )
        )
    }

    override func tearDown() {
        SGPolicyStubProtocol.reset(routes: [:])
        UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
        self.store = nil
        super.tearDown()
    }

    private func client() -> SGEntitlementClient {
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://\(self.origin)/v1")!, appVersion: "1.0", osVersion: "27.0")
        configuration.protocolClasses = [SGPolicyStubProtocol.self]
        return SGEntitlementClient(configuration: configuration, store: self.store)
    }

    /// `path` on the origin answers `status` with `Location` on another host, which would answer 2xx.
    private func redirect(_ status: Int, path: String, body: [String: Any]) {
        SGPolicyStubProtocol.reset(routes: [
            self.origin: SGPolicyStubProtocol.Route(status: status, redirectTo: URL(string: "https://\(self.elsewhere)/v1/\(path)")!),
            self.elsewhere: SGPolicyStubProtocol.Route(headers: ["Content-Type": "application/json"], chunks: [SGPolicyStubProtocol.json(body)])
        ])
    }

    private var requestedHosts: [String] {
        return SGPolicyStubProtocol.requests.compactMap { $0.url?.host }
    }

    // MARK: - Control

    func test_control_aDefaultSessionFollowsTheScriptedRedirect() async throws {
        self.redirect(302, path: "health", body: ["ok": true])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SGPolicyStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let (_, response) = try await session.data(for: URLRequest(url: URL(string: "https://\(self.origin)/v1/health")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "premise: the stub's redirect is followable")
        XCTAssertEqual(self.requestedHosts, [self.origin, self.elsewhere], "premise: a default session follows it")
    }

    // MARK: - The client refuses

    func test_anUnauthenticatedRequestIsNeverRedirected() async {
        self.redirect(302, path: "health", body: ["ok": true, "version": "elsewhere"])
        let result = await self.client().health()
        if case let .success(health) = result {
            XCTFail("the redirect target answered: \(health)")
        }
        XCTAssertEqual(self.requestedHosts.first, self.origin, "premise: the client's session reached the stub origin")
        XCTAssertEqual(self.requestedHosts, [self.origin], "a request left for the redirect's host")
    }

    func test_a301NeverCarriesABearerToTheRedirectHost() async {
        // A `.device` (refresh-token) route signs DeviceAuth with `SGEntitlementDeviceIdentity.shared`,
        // which has no injectable seam and cannot mint a device id in the test host — it would fail
        // before sending. `bind/poll` without a registered key carries a bearer and needs no identity;
        // the redirect refusal is the session's, so it covers every route alike.
        let bearer = String(repeating: "b", count: 64)
        self.redirect(301, path: "bind/poll", body: ["status": "pending", "server_time": "2026-01-01T00:00:00Z"])
        _ = await self.client().bindPoll(pollToken: bearer, registeredPublicKey: nil)
        XCTAssertEqual(SGPolicyStubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(bearer)", "premise: the origin request carries the bearer")
        XCTAssertEqual(self.requestedHosts, [self.origin], "the bearer's request was redirected to another host")
    }

    func test_a307BodyAndBearerAreNeverReplayedToTheRedirectHost() async {
        // `bind/poll` with no registered key polls proofless: a JSON body and a bearer, and no device
        // identity is needed, so the request depends on nothing but the stub.
        let pollToken = String(repeating: "p", count: 64)
        self.redirect(307, path: "bind/poll", body: ["status": "pending"])
        _ = await self.client().bindPoll(pollToken: pollToken, registeredPublicKey: nil)
        let first = SGPolicyStubProtocol.requests.first
        XCTAssertEqual(first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(pollToken)", "premise: the origin request carries the poll token")
        XCTAssertEqual(first?.httpMethod, "POST", "premise: a body-carrying request")
        XCTAssertEqual(self.requestedHosts, [self.origin], "the poll token and its body were replayed to another host")
    }

    func test_a308IsNeverFollowedEither() async {
        self.redirect(308, path: "health", body: ["ok": true])
        _ = await self.client().health()
        XCTAssertEqual(self.requestedHosts.first, self.origin, "premise: the client's session reached the stub origin")
        XCTAssertEqual(self.requestedHosts, [self.origin])
    }
}
