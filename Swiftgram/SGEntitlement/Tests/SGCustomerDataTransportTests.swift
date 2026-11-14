import XCTest
@testable import SGEntitlement

/// Zenlygram — the customer-data transport's attempt discipline with a scripted origin injected at
/// the `fetch` seam: credentials as headers only, the exact body, the route table, the shared
/// account gate, the single existing retry, the 401 drop applied to the captured credential only,
/// late answers after a credential change, the logout's removed-credential mode and the error
/// fields. The bounded exchange itself runs through the real `URLSession` path
/// (`SGEntitlementPathStubProtocol`).
final class SGCustomerDataTransportTests: XCTestCase {
    private let account: Int64 = 777_000
    private let baseURL = URL(string: "https://customer.zenlygram.test/v1")!
    private let consentBody = Data(#"{"schema_version":1,"events":[{"consent_id":"9f1c2b7e-0000-4000-8000-000000000001","action":"withdraw"}]}"#.utf8)

    /// The mutable outside world one test drives: the stored token, the scripted answers, the clock
    /// and everything the transport reported back.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        private var answers: [Result<SGCustomerDataTransport.HTTPAnswer, SGEntitlementFailureClass>]
        private var nonce = 0
        private(set) var requests: [URLRequest] = []
        private(set) var fetchTimeouts: [TimeInterval] = []
        private(set) var fetchLimits: [Int] = []
        private(set) var applied: [(SGEntitlementRequestError, SGEntitlementSessionCredential)] = []
        private(set) var notedServerTimes: [Date] = []
        private(set) var adoptedOffsets: [Date] = []
        var uptime: TimeInterval = 1_000
        /// Runs inside `fetch`, before the scripted answer is returned (the request is "in flight").
        var duringFetch: ((World) -> Void)?

        init(token: String?, answers: [Result<SGCustomerDataTransport.HTTPAnswer, SGEntitlementFailureClass>]) {
            self.token = token
            self.answers = answers
        }

        func locked<T>(_ body: () -> T) -> T {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return body()
        }

        func setToken(_ value: String?) {
            self.locked { self.token = value }
        }

        func storedToken() -> String? {
            return self.locked { self.token }
        }

        func credentials() -> SGEntitlementDeviceCredentials {
            return self.locked {
                self.nonce += 1
                return SGEntitlementDeviceCredentials(deviceId: "dev-hex", nonce: "nonce-\(self.nonce)", timestamp: 1_800_000_000, signature: "sig-\(self.nonce)")
            }
        }

        /// How many credential sets were signed.
        var signed: Int {
            return self.locked { self.nonce }
        }

        func record(_ request: URLRequest, timeout: TimeInterval, limit: Int) -> Result<SGCustomerDataTransport.HTTPAnswer, SGEntitlementFailureClass> {
            return self.locked {
                self.requests.append(request)
                self.fetchTimeouts.append(timeout)
                self.fetchLimits.append(limit)
                return self.answers.isEmpty ? .failure(.offline(.timeout)) : self.answers.removeFirst()
            }
        }

        func apply(_ error: SGEntitlementRequestError, _ credential: SGEntitlementSessionCredential) {
            self.locked { self.applied.append((error, credential)) }
        }

        func note(_ date: Date) {
            self.locked { self.notedServerTimes.append(date) }
        }

        func adopt(_ date: Date) {
            self.locked { self.adoptedOffsets.append(date) }
        }

        func currentUptime() -> TimeInterval {
            return self.locked { self.uptime }
        }
    }

    /// `fetch` nil: the scripted world answers. Otherwise the given seam (the real bounded exchange
    /// against `SGEntitlementPathStubProtocol`), with every request still recorded first.
    private func transport(_ world: World, gate: SGEntitlementAccountGate = SGEntitlementAccountGate(), fetch: SGCustomerDataTransport.Fetch? = nil) -> SGCustomerDataTransport {
        return SGCustomerDataTransport(environment: SGCustomerDataTransport.Environment(
            baseURL: self.baseURL,
            timeout: SGCustomerDataTransport.exchangeTimeout,
            gate: gate,
            storedRefreshToken: { _ in world.storedToken() },
            deviceCredentials: { world.credentials() },
            noteServerTime: { world.note($0) },
            adoptServerOffset: { world.adopt($0) },
            applySessionFailure: { world.apply($0, $1) },
            fetch: { request, timeout, limit in
                world.duringFetch?(world)
                let scripted = world.record(request, timeout: timeout, limit: limit)
                if let fetch {
                    return await fetch(request, timeout, limit)
                }
                return scripted
            },
            uptime: { world.currentUptime() }
        ))
    }

    private static func answer(_ status: Int, _ body: String, retryAfter: Int? = nil) -> Result<SGCustomerDataTransport.HTTPAnswer, SGEntitlementFailureClass> {
        return .success(SGCustomerDataTransport.HTTPAnswer(status: status, body: Data(body.utf8), retryAfter: retryAfter))
    }

    private static func error(_ status: Int, _ code: String, extra: String = "") -> Result<SGCustomerDataTransport.HTTPAnswer, SGEntitlementFailureClass> {
        return self.answer(status, #"{"error":"\#(code)","message":"m","server_time":"2026-10-29T00:00:00Z"\#(extra)}"#)
    }

    private let okBody = #"{"schema_version":1,"results":[],"server_time":"2026-10-29T00:00:01Z"}"#

    private func requestError(_ result: Result<Data, SGEntitlement.CustomerDataFailure>, file: StaticString = #filePath, line: UInt = #line) -> SGEntitlementRequestError? {
        guard case let .failure(.request(error)) = result else {
            XCTFail("expected a request failure, got \(result)", file: file, line: line)
            return nil
        }
        return error
    }

    // MARK: - Credentials and the request

    func test_credentialsTravelOnlyAsHeadersAndTheBodyIsSentExactlyAsGiven() async throws {
        let world = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        let result = await self.transport(world).send(.profileConsents, body: self.consentBody, accountPeerId: self.account)
        XCTAssertEqual(try result.get(), Data(self.okBody.utf8), "the 2xx body is handed back undecoded")
        XCTAssertEqual(world.requests.count, 1)
        let sent = world.requests[0]
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://customer.zenlygram.test/v1/profile/consents")
        XCTAssertEqual(sent.allHTTPHeaderFields, [
            "Accept": "application/json",
            "Authorization": "Bearer tok-1",
            "X-Device-Id": "dev-hex",
            "X-Device-Nonce": "nonce-1",
            "X-Device-Ts": "1800000000",
            "X-Device-Sig": "sig-1",
            "Content-Type": "application/json"
        ], "no app/OS version, no Idempotency-Key, nothing else")
        XCTAssertEqual(sent.httpBody, self.consentBody, "the body is the caller's bytes, unchanged")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isDisjoint(with: ["refresh_token", "device_id", "nonce", "ts", "sig"]), "no credential in the body")
        XCTAssertNil(sent.url?.query, "nothing in the query")
        XCTAssertEqual(world.notedServerTimes, [SGEntitlementTimestamp.parse("2026-10-29T00:00:01Z")!], "a success's server_time feeds the clock")
        XCTAssertTrue(world.applied.isEmpty)
    }

    func test_everyRouteHasItsPathMethodBoundAndWholeExchangeTimeout() async throws {
        let expected: [(SGEntitlementCustomerDataRoute, String, String, TimeInterval, Int)] = [
            (.profileConsents, "POST", "/v1/profile/consents", 10, 65536),
            (.profileSync, "POST", "/v1/profile/sync", 10, 65536),
            (.profileMe, "GET", "/v1/profile/me", 10, 1 << 20),
            (.profileEvents, "POST", "/v1/profile/events", 20, 65536),
            (.accountDelete, "POST", "/v1/account/delete", 10, 65536)
        ]
        XCTAssertEqual(SGEntitlementCustomerDataRoute.allCases.count, expected.count)
        for (route, method, path, timeout, limit) in expected {
            let world = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
            let body: Data? = route == .profileMe ? nil : Data(#"{"schema_version":1}"#.utf8)
            let result = await self.transport(world).send(route, body: body, accountPeerId: self.account)
            XCTAssertNoThrow(try result.get(), "\(route)")
            let sent = try XCTUnwrap(world.requests.first)
            XCTAssertEqual(route.method, method)
            XCTAssertEqual(sent.httpMethod, method, "\(route)")
            XCTAssertEqual(sent.url?.path, path, "\(route)")
            XCTAssertEqual(world.fetchTimeouts, [timeout], "\(route): the whole exchange")
            XCTAssertEqual(sent.timeoutInterval, timeout / 2.0, "\(route): the idle bound is half of it")
            XCTAssertEqual(world.fetchLimits, [limit], "\(route): the response bound")
            if route == .profileMe {
                XCTAssertNil(sent.httpBody)
                XCTAssertNil(sent.value(forHTTPHeaderField: "Content-Type"), "no body, no content type")
            } else {
                XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
            }
        }
    }

    func test_onlyTheDeleteCarriesTheIdempotencyKey() async throws {
        let key = "5d3c8f0e-1111-4222-8333-444455556666"
        let delete = World(token: "tok-1", answers: [Self.answer(200, #"{"schema_version":1,"state":"erased"}"#)])
        _ = await self.transport(delete).send(.accountDelete, body: Data(#"{"schema_version":1,"confirm":"delete_account"}"#.utf8), accountPeerId: self.account, idempotencyKey: key)
        XCTAssertEqual(delete.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"), key)

        let consents = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        _ = await self.transport(consents).send(.profileConsents, body: self.consentBody, accountPeerId: self.account, idempotencyKey: key)
        XCTAssertNil(consents.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"), "no profile route uses IdempotencyKey")

        let unkeyed = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        _ = await self.transport(unkeyed).send(.accountDelete, body: Data(#"{"schema_version":1,"confirm":"delete_account"}"#.utf8), accountPeerId: self.account)
        XCTAssertNil(unkeyed.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func test_aBodyCarryingACredentialKeyOrAGetBodyIsNeverSent() async throws {
        for key in ["refresh_token", "device_id", "nonce", "ts", "sig"] {
            let world = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
            let body = SGEntitlementPathStubProtocol.json(["schema_version": 1, key: "x"])
            let result = await self.transport(world).send(.profileSync, body: body, accountPeerId: self.account)
            XCTAssertEqual(self.requestError(result)?.failure, .refused(.invalidRequest), key)
            XCTAssertTrue(world.requests.isEmpty, "\(key): a body credential is never sent")
        }
        // Only the top level is where the guards look; a nested descriptive value is the caller's.
        let nested = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        let body = SGEntitlementPathStubProtocol.json(["schema_version": 1, "device": ["model": "iPhone"]])
        _ = await self.transport(nested).send(.profileSync, body: body, accountPeerId: self.account)
        XCTAssertEqual(nested.requests.count, 1)

        let get = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        let result = await self.transport(get).send(.profileMe, body: Data("{}".utf8), accountPeerId: self.account)
        XCTAssertEqual(self.requestError(result)?.failure, .refused(.invalidRequest))
        XCTAssertTrue(get.requests.isEmpty)
    }

    func test_withoutASessionNothingIsSent() async {
        let gate = SGEntitlementAccountGate()
        let world = World(token: nil, answers: [Self.answer(200, self.okBody)])
        let result = await self.transport(world, gate: gate).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)
        XCTAssertEqual(result, .failure(.notLinked))
        XCTAssertTrue(world.requests.isEmpty)
        XCTAssertFalse(gate.state(accountPeerId: self.account).isHeld)
    }

    // MARK: - The account gate and the token re-check

    func test_aCallWaitsForTheAccountGateAndIsAbandonedWhenTheTokenRotatedMeanwhile() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        let transport = self.transport(world, gate: gate)
        let account = self.account
        let body = self.consentBody
        await gate.acquire(accountPeerId: account) // a rotation is in flight
        let call = Task {
            await transport.send(.profileConsents, body: body, accountPeerId: account)
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        XCTAssertTrue(world.requests.isEmpty, "nothing is sent while the rotation holds the gate")
        world.setToken("tok-2") // the rotation stored its successor
        gate.release(accountPeerId: account)
        let result = await call.value
        XCTAssertEqual(result, .failure(.credentialChanged))
        XCTAssertTrue(world.requests.isEmpty, "the replaced token is never presented")
        XCTAssertFalse(gate.state(accountPeerId: account).isHeld, "the abandoned call releases the gate")
    }

    func test_aCallQueuedBehindAnUnchangedSessionProceeds() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        let transport = self.transport(world, gate: gate)
        let account = self.account
        let body = self.consentBody
        await gate.acquire(accountPeerId: account)
        let call = Task {
            await transport.send(.profileConsents, body: body, accountPeerId: account)
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        gate.release(accountPeerId: account)
        let result = await call.value
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(world.requests.count, 1)
    }

    // MARK: - The caller's condition once the gate is held

    /// A sync queued behind the account's gate — a rotation or a Tasks attempt holds it — whose
    /// caller's condition turned false meanwhile (a withdrawal): it is asked only once the gate is
    /// held, and then nothing is signed or sent, no session state changes and the gate is free again.
    func test_aCallQueuedBehindTheGateThatIsNoLongerWantedIsNotSent() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        let transport = self.transport(world, gate: gate)
        let account = self.account
        let wanted = SGCustomerDataTestCondition(true)
        await gate.acquire(accountPeerId: account) // a rotation or a Tasks attempt is in flight
        let call = Task {
            await transport.send(.profileSync, body: Data(#"{"schema_version":1}"#.utf8), accountPeerId: account, stillWanted: { wanted.ask() })
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        XCTAssertEqual(wanted.asked, 0, "not asked while the call waits")
        wanted.set(false) // the user withdraws meanwhile
        gate.release(accountPeerId: account)
        let result = await call.value
        XCTAssertEqual(result, .failure(.notWanted))
        XCTAssertEqual(wanted.asked, 1, "asked once its turn came")
        XCTAssertTrue(world.requests.isEmpty, "no request reached the origin")
        XCTAssertEqual(world.signed, 0, "nothing was signed")
        XCTAssertTrue(world.applied.isEmpty)
        XCTAssertEqual(world.storedToken(), "tok-1", "the session is untouched")
        XCTAssertFalse(gate.state(accountPeerId: account).isHeld, "the refused call releases the gate")
    }

    /// Still wanted when its turn comes: sent as usual. The condition is asked again before the one
    /// correction retry: a withdrawal while the first attempt was out stops the retry.
    func test_aCallStillWantedIsSentAndTheConditionIsAskedBeforeEachAttempt() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.okBody)])
        let transport = self.transport(world, gate: gate)
        let account = self.account
        let wanted = SGCustomerDataTestCondition(true)
        await gate.acquire(accountPeerId: account)
        let call = Task {
            await transport.send(.profileEvents, body: Data(#"{"schema_version":1}"#.utf8), accountPeerId: account, stillWanted: { wanted.ask() })
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        gate.release(accountPeerId: account)
        let sent = await call.value
        XCTAssertEqual(try sent.get(), Data(self.okBody.utf8))
        XCTAssertEqual(world.requests.count, 1)
        XCTAssertEqual(wanted.asked, 1)

        let skewed = World(token: "tok-1", answers: [Self.error(401, "clock_skew"), Self.answer(200, self.okBody)])
        let condition = SGCustomerDataTestCondition(true)
        skewed.duringFetch = { _ in
            condition.set(false) // withdrawn while the first attempt was out
        }
        let retried = await self.transport(skewed).send(.profileSync, body: Data("{}".utf8), accountPeerId: account, stillWanted: { condition.ask() })
        XCTAssertEqual(retried, .failure(.notWanted))
        XCTAssertEqual(skewed.requests.count, 1, "the correction retry was not sent")
        XCTAssertEqual(condition.asked, 2)
        XCTAssertTrue(skewed.applied.isEmpty)
    }

    func test_anAnswerThatOutlivedItsSessionIsCredentialChangedAndNeverApplied() async throws {
        for answer in [Self.answer(200, self.okBody), Self.error(401, "invalid_token"), Self.error(422, "invalid_request")] {
            let world = World(token: "tok-1", answers: [answer])
            world.duringFetch = { world in
                world.setToken("tok-2") // a logout and re-bind while the request was out
            }
            let result = await self.transport(world).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)
            XCTAssertEqual(result, .failure(.credentialChanged))
            XCTAssertTrue(world.applied.isEmpty, "the old session's 401 is not this account's anymore")
        }
        let offline = World(token: "tok-1", answers: [.failure(.offline(.timeout))])
        offline.duringFetch = { world in
            world.setToken(nil)
        }
        let result = await self.transport(offline).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)
        XCTAssertEqual(result, .failure(.credentialChanged))
    }

    // MARK: - Retries and the session

    func test_clockSkewResignsOnceWithTheServerTime() async throws {
        let world = World(token: "tok-1", answers: [Self.error(401, "clock_skew"), Self.answer(200, self.okBody)])
        let result = await self.transport(world).send(.profileEvents, body: Data("{}".utf8), accountPeerId: self.account)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(world.requests.count, 2)
        XCTAssertEqual(world.adoptedOffsets, [SGEntitlementTimestamp.parse("2026-10-29T00:00:00Z")!])
        XCTAssertEqual(world.requests.map { $0.value(forHTTPHeaderField: "X-Device-Nonce") }, ["nonce-1", "nonce-2"], "every attempt signs afresh")
        XCTAssertTrue(world.applied.isEmpty, "a recovered skew is not a session failure")
    }

    func test_nonceReplayedAndABare401RetryOnceWithFreshCredentials() async throws {
        let replayed = World(token: "tok-1", answers: [Self.error(401, "nonce_replayed"), Self.answer(200, self.okBody)])
        let recovered = await self.transport(replayed).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)
        XCTAssertNoThrow(try recovered.get())
        XCTAssertEqual(replayed.requests.count, 2)
        XCTAssertTrue(replayed.applied.isEmpty)

        let bare = World(token: "tok-1", answers: [Self.answer(401, ""), Self.answer(401, "")])
        let result = await self.transport(bare).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)
        XCTAssertEqual(self.requestError(result)?.failure, .session(.unauthenticated))
        XCTAssertEqual(bare.requests.count, 2, "exactly one retry")
        XCTAssertEqual(bare.applied.count, 1, "the exhausted 401 reaches the session machinery once")
    }

    func test_aDropFamily401IsAppliedToTheCapturedCredentialOnlyAndNeverRetried() async throws {
        let world = World(token: "tok-1", answers: [Self.error(401, "invalid_token", extra: #","reason":"account_erased""#)])
        let result = await self.transport(world).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)
        let error = try XCTUnwrap(self.requestError(result))
        XCTAssertEqual(error.failure, .session(.invalidToken))
        XCTAssertEqual(error.status, 401)
        XCTAssertEqual(error.code, "invalid_token")
        XCTAssertEqual(error.reason, "account_erased")
        XCTAssertEqual(world.requests.count, 1, "a drop is never retried")
        XCTAssertEqual(world.applied.count, 1)
        XCTAssertEqual(world.applied.first?.1, SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1"))
        XCTAssertEqual(world.applied.first?.0.reason, "account_erased", "the reason reaches the session end")
    }

    func test_aDeviceAuthCodeUnderAnotherStatusIsNeverAppliedAsASession() async throws {
        let world = World(token: "tok-1", answers: [Self.error(403, "invalid_token"), Self.error(502, "session_revoked")])
        let forbidden = self.requestError(await self.transport(world).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account))
        XCTAssertEqual(forbidden?.failure, .unknownRefusal(code: "invalid_token", status: 403))
        let gateway = self.requestError(await self.transport(world).send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account))
        XCTAssertEqual(gateway?.failure, .offline(.serverError))
        XCTAssertTrue(world.applied.isEmpty)
        XCTAssertEqual(world.requests.count, 2, "neither is retried")
    }

    // MARK: - Error fields

    func test_errorsKeepTheirStatusCodeReasonAndBody() async throws {
        let consentRequired = #"{"error":"consent_required","message":"m","reason":"withdrawn","consent":{"state":"withdrawn"},"server_time":"2026-10-29T00:00:00Z"}"#
        let world = World(token: "tok-1", answers: [
            Self.answer(403, consentRequired),
            Self.answer(503, #"{"error":"profile_unavailable","retry_after":120,"server_time":"2026-10-29T00:00:00Z"}"#),
            Self.answer(429, #"{"error":"rate_limited","retry_after":7}"#, retryAfter: 30),
            Self.answer(409, #"{"error":"idempotency_in_flight"}"#),
            Self.answer(422, #"{"error":"invalid_request","field":"x","pad":"\#(String(repeating: "p", count: SGEntitlementRequestError.maxResponseBodyBytes))"}"#)
        ])
        let transport = self.transport(world)
        let refusedResult = await transport.send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)
        let refused = try XCTUnwrap(self.requestError(refusedResult))
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(refused.code, "consent_required")
        XCTAssertEqual(refused.reason, "withdrawn")
        XCTAssertEqual(refused.failure, .unknownRefusal(code: "consent_required", status: 403))
        XCTAssertEqual(refused.responseBody, Data(consentRequired.utf8), "the caller decodes the consent block itself")
        XCTAssertNil(refused.message, "the server's message is never read")

        let unavailableResult = await transport.send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)

        let unavailable = try XCTUnwrap(self.requestError(unavailableResult))
        XCTAssertEqual(unavailable.failure, .offline(.serverError))
        XCTAssertEqual(unavailable.code, "profile_unavailable", "the coded 503 keeps its code")
        XCTAssertEqual(unavailable.retryAfter, 120)

        let limitedResult = await transport.send(.profileEvents, body: Data("{}".utf8), accountPeerId: self.account)

        let limited = try XCTUnwrap(self.requestError(limitedResult))
        XCTAssertEqual(limited.failure, .rateLimited(retryAfter: 30), "Retry-After wins over the body")
        XCTAssertEqual(limited.retryAfter, 30)

        let inFlightResult = await transport.send(.accountDelete, body: Data("{}".utf8), accountPeerId: self.account, idempotencyKey: "k")

        let inFlight = try XCTUnwrap(self.requestError(inFlightResult))
        XCTAssertEqual(inFlight.failure, .refused(.idempotencyInFlight))

        let largeResult = await transport.send(.profileSync, body: Data("{}".utf8), accountPeerId: self.account)

        let large = try XCTUnwrap(self.requestError(largeResult))
        XCTAssertEqual(large.code, "invalid_request")
        XCTAssertNil(large.responseBody, "an error body over 16 KiB is not kept")

        XCTAssertEqual(world.requests.count, 5, "none of these is retried")
        XCTAssertTrue(world.applied.isEmpty)
        XCTAssertEqual(world.notedServerTimes.count, 2, "every error body's server_time feeds the clock")
    }

    func test_aTransportFailureIsOfflineWithNoStatusAndNoRetry() async throws {
        let world = World(token: "tok-1", answers: [.failure(.offline(.timeout))])
        let errorResult = await self.transport(world).send(.profileEvents, body: Data("{}".utf8), accountPeerId: self.account)
        let error = try XCTUnwrap(self.requestError(errorResult))
        XCTAssertEqual(error.failure, .offline(.timeout))
        XCTAssertNil(error.status)
        XCTAssertNil(error.code)
        XCTAssertEqual(world.requests.count, 1)
    }

    // MARK: - The logout's removed credential

    func test_theRemovedCredentialIsPresentedWithoutRecheckOrGateAndNothingIsApplied() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: nil, answers: [Self.error(401, "invalid_token")])
        await gate.acquire(accountPeerId: self.account) // whatever holds it, the final send does not wait
        defer {
            gate.release(accountPeerId: self.account)
        }
        let removed = SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "removed-token")
        let result = await self.transport(world, gate: gate).sendPresentingRemovedCredential(.profileConsents, body: self.consentBody, credential: removed, deadline: world.uptime + 10)
        let error = try XCTUnwrap(self.requestError(result))
        XCTAssertEqual(error.failure, .session(.invalidToken), "the answer is reported, never credentialChanged")
        XCTAssertEqual(world.requests.count, 1)
        XCTAssertEqual(world.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer removed-token")
        XCTAssertEqual(world.requests.first?.httpBody, self.consentBody)
        XCTAssertTrue(world.applied.isEmpty, "nothing is applied to a session that no longer exists")
    }

    func test_theRemovedCredentialKeepsToTheDeadline() async throws {
        let removed = SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "removed-token")
        let late = World(token: nil, answers: [Self.answer(200, self.okBody)])
        let expired = self.requestError(await self.transport(late).sendPresentingRemovedCredential(.profileConsents, body: self.consentBody, credential: removed, deadline: late.uptime))
        XCTAssertEqual(expired?.failure, .offline(.timeout))
        XCTAssertTrue(late.requests.isEmpty, "an attempt that would start at the deadline is not sent")

        let tight = World(token: nil, answers: [Self.answer(200, self.okBody)])
        _ = await self.transport(tight).sendPresentingRemovedCredential(.profileConsents, body: self.consentBody, credential: removed, deadline: tight.uptime + 4)
        XCTAssertEqual(tight.fetchTimeouts, [4], "the exchange never outlives the budget")

        let retried = World(token: nil, answers: [Self.error(401, "nonce_replayed"), Self.answer(200, self.okBody)])
        retried.duringFetch = { world in
            world.locked { world.uptime += 3 }
        }
        _ = await self.transport(retried).sendPresentingRemovedCredential(.profileConsents, body: self.consentBody, credential: removed, deadline: 1_000 + 5)
        XCTAssertEqual(retried.fetchTimeouts, [5, 2], "the one retry gets only what is left")
    }

    // MARK: - The real exchange

    func test_theRealExchangeBoundsTheAnswerPerRouteAndSendsTheBodyBytes() async throws {
        defer {
            SGEntitlementPathStubProtocol.reset()
        }
        let fetch: SGCustomerDataTransport.Fetch = { request, timeout, limit in
            let answer = await SGTasksBoundedExchange.perform(request, timeout: timeout / 2.0, limit: limit, protocolClasses: [SGEntitlementPathStubProtocol.self])
            return answer.map { SGCustomerDataTransport.HTTPAnswer(status: $0.status, body: $0.body, retryAfter: $0.retryAfter) }
        }
        let oversized = Data(repeating: 0x20, count: SGCustomerDataTransport.defaultResponseLimit + 1)
        SGEntitlementPathStubProtocol.reset([
            "/v1/profile/sync": [SGEntitlementPathStubProtocol.Response(body: oversized)],
            "/v1/profile/me": [SGEntitlementPathStubProtocol.Response(body: oversized)]
        ])
        let world = World(token: "tok-1", answers: [])
        let transport = self.transport(world, fetch: fetch)
        let body = Data(#"{"schema_version":1,"profile":{"first_name":"Абдурашид"}}"#.utf8)
        let sync = self.requestError(await transport.send(.profileSync, body: body, accountPeerId: self.account))
        XCTAssertEqual(sync?.failure, .offline(.malformedResponse), "64 KiB is the bound of every route but profile/me")
        let me = await transport.send(.profileMe, body: nil, accountPeerId: self.account)
        XCTAssertEqual(try me.get(), oversized, "profile/me may answer up to 1 MiB")
        let recorded = SGEntitlementPathStubProtocol.recorded(path: "/v1/profile/sync")
        XCTAssertEqual(recorded.first?.body, body, "the bytes on the wire are the caller's")
        XCTAssertNil(SGEntitlementPathStubProtocol.recorded(path: "/v1/profile/me").first?.body)
    }

    func test_theRealExchangeNeverFollowsARedirect() async throws {
        defer {
            SGEntitlementPathStubProtocol.reset()
        }
        let fetch: SGCustomerDataTransport.Fetch = { request, timeout, limit in
            let answer = await SGTasksBoundedExchange.perform(request, timeout: timeout / 2.0, limit: limit, protocolClasses: [SGEntitlementPathStubProtocol.self])
            return answer.map { SGCustomerDataTransport.HTTPAnswer(status: $0.status, body: $0.body, retryAfter: $0.retryAfter) }
        }
        SGEntitlementPathStubProtocol.reset([
            "/v1/profile/consents": [SGEntitlementPathStubProtocol.Response(status: 307, redirectTo: URL(string: "https://elsewhere.zenlygram.test/v1/collect")!)],
            "/v1/collect": [SGEntitlementPathStubProtocol.Response.json(200, ["ok": true])]
        ])
        let world = World(token: "tok-1", answers: [])
        let error = self.requestError(await self.transport(world, fetch: fetch).send(.profileConsents, body: self.consentBody, accountPeerId: self.account))
        XCTAssertEqual(error?.status, 307, "the 3xx itself is the answer")
        XCTAssertEqual(SGEntitlementPathStubProtocol.recorded.map(\.path), ["/v1/profile/consents"], "nothing left for the Location host")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0 ..< 2000 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition never became true")
    }
}

/// A caller's `stillWanted`, set by the test, counting how often it was asked.
private final class SGCustomerDataTestCondition: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private var count = 0

    init(_ value: Bool) {
        self.value = value
    }

    func set(_ value: Bool) {
        self.lock.lock()
        self.value = value
        self.lock.unlock()
    }

    func ask() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.count += 1
        return self.value
    }

    var asked: Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.count
    }
}

// The facade reads the real store, which the Bazel targets always link (see
// `SGEntitlementTestSupport.swift`).
#if canImport(SGProtectedStore)
/// `SGEntitlement.customerData` hands its caller's condition to the transport: a call whose
/// condition no longer holds once the account's gate is held answers `.notWanted` and reaches no
/// origin.
final class SGCustomerDataStillWantedFacadeTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var store: SGEntitlementStore!

    override func setUp() {
        super.setUp()
        SGEntitlementPathStubProtocol.reset()
        self.storeSuite = "SGCustomerDataStillWantedFacadeTests.store.\(UUID().uuidString)"
        self.schedulerSuite = "SGCustomerDataStillWantedFacadeTests.scheduler.\(UUID().uuidString)"
        self.store = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
    }

    override func tearDown() {
        self.store.clearSession(accountPeerId: self.account)
        UserDefaults(suiteName: self.storeSuite)?.removePersistentDomain(forName: self.storeSuite)
        UserDefaults(suiteName: self.schedulerSuite)?.removePersistentDomain(forName: self.schedulerSuite)
        SGEntitlementPathStubProtocol.reset()
        self.store = nil
        super.tearDown()
    }

    func test_theFacadeHandsTheConditionToTheTransport() async {
        let entitlement = SGEntitlement(store: self.store, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)), isExtensionProcess: false)
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://api.customer-data.zenlygram.invalid/v1")!)
        configuration.protocolClasses = [SGEntitlementPathStubProtocol.self]
        entitlement.installClientForTesting(SGEntitlementClient(configuration: configuration, store: self.store))
        let seeded = self.store.updateSession(accountPeerId: self.account) { stored in
            stored = SGEntitlementSessionMaterial(refreshToken: "tok-1", entitlement: "jws", accountId: "01JB8Q", deviceId: "01JB8R")
        }
        guard case .success = seeded else {
            return XCTFail("the owned store could not persist the seed: \(seeded)")
        }
        let result = await entitlement.customerData(.profileSync, body: Data(#"{"schema_version":1}"#.utf8), accountPeerId: self.account, stillWanted: { false })
        XCTAssertEqual(result, .failure(.notWanted))
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded.isEmpty, "nothing reached the origin")
        XCTAssertEqual(self.store.session(accountPeerId: self.account).refreshToken, "tok-1", "the session is untouched")
    }
}
#endif
