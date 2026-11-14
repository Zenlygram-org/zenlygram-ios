import XCTest
@testable import SGEntitlement

/// Zenlygram — the Tasks transport's attempt discipline with a scripted origin injected at the
/// `fetch` seam: exact credential transport, the shared rotation gate, the single existing retry,
/// session-vs-Tasks error routing and late answers after a credential change. The bounded exchange
/// itself runs through the real `URLSession` path (`SGPolicyStubProtocol`).
final class SGTasksTransportTests: XCTestCase {
    private let account: Int64 = 777_000
    private let baseURL = URL(string: "https://tasks.zenlygram.test/v1")!

    /// The mutable outside world one test drives: the stored token, the scripted answers and
    /// everything the transport reported back.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        private var answers: [Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass>]
        private(set) var requests: [URLRequest] = []
        /// The idle timeout and response bound `fetch` got for each request.
        private(set) var timeouts: [TimeInterval] = []
        private(set) var limits: [Int] = []
        private(set) var applied: [(SGEntitlementRequestError, SGEntitlementSessionCredential)] = []
        private(set) var notedServerTimes: [Date] = []
        private(set) var adoptedOffsets: [Date] = []
        private(set) var proofsIssued = 0
        private var nonce = 0
        var proof: String? = nil
        /// Runs inside `fetch`, before the scripted answer is returned (the request is "in flight").
        var duringFetch: ((World) -> Void)?

        init(token: String?, answers: [Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass>]) {
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

        func issueProof() -> String? {
            return self.locked {
                self.proofsIssued += 1
                return self.proof.map { "\($0)-\(self.proofsIssued)" }
            }
        }

        func record(_ request: URLRequest, timeout: TimeInterval, limit: Int) -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> {
            return self.locked {
                self.requests.append(request)
                self.timeouts.append(timeout)
                self.limits.append(limit)
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
    }

    /// `fetch` nil: the scripted world answers. Otherwise the given seam (e.g. the real bounded
    /// exchange against `SGPolicyStubProtocol`), with every request still recorded first.
    private func transport(_ world: World, gate: SGEntitlementAccountGate = SGEntitlementAccountGate(), fetch: SGTasksTransport.Fetch? = nil, requestWire: Int = SGTasksWire.wireRevision) -> SGTasksTransport {
        return SGTasksTransport(environment: SGTasksTransport.Environment(
            baseURL: self.baseURL,
            timeout: 5,
            gate: gate,
            storedRefreshToken: { _ in world.storedToken() },
            deviceCredentials: { world.credentials() },
            noteServerTime: { world.note($0) },
            adoptServerOffset: { world.adopt($0) },
            creationProof: { _ in world.issueProof() },
            applySessionFailure: { world.apply($0, $1) },
            fetch: { request, timeout, limit in
                world.duringFetch?(world)
                let scripted = world.record(request, timeout: timeout, limit: limit)
                if let fetch {
                    return await fetch(request, timeout, limit)
                }
                return scripted
            },
            requestWire: requestWire
        ))
    }

    private static func answer(_ status: Int, _ body: String, retryAfter: Int? = nil, serverWire: Int? = nil) -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> {
        return .success(SGTasksTransport.HTTPAnswer(status: status, body: Data(body.utf8), retryAfter: retryAfter, serverWire: serverWire))
    }

    private static func error(_ status: Int, _ code: String) -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> {
        return self.answer(status, #"{"error":"\#(code)","message":"m","server_time":"2026-10-24T00:00:00Z"}"#)
    }

    private let snapshotBody = #"{"schema_version":1,"items":[],"next_cursor":null,"changes_cursor":"c1","server_time":"2026-10-24T00:00:00Z"}"#

    private func receiptBody(mutationId: String, operation: String, kind: String, id: String) -> String {
        return #"{"schema_version":1,"receipt":{"mutation_id":"\#(mutationId)","operation":"\#(operation)","outcome":"committed","resource_kind":"\#(kind)","resource_id":"\#(id)","resource_revision":"1","committed_at":"2026-10-24T00:00:00Z"},"server_time":"2026-10-24T00:00:01Z"}"#
    }

    private let listId = SGTasksWire.UUID("22222222-2222-4222-8222-222222222222")!
    private let mutationId = SGTasksWire.UUID("11111111-1111-4111-8111-111111111111")!

    private func listCreate() throws -> SGTasksWire.MutationRequest {
        return try SGTasksWire.MutationRequest(mutationId: self.mutationId, operation: .listCreate(SGTasksWire.ListCreate(listId: self.listId, title: "Ishlar", sortOrder: 0, createdAt: nil)))
    }

    private func listDelete() throws -> SGTasksWire.MutationRequest {
        return try SGTasksWire.MutationRequest(mutationId: self.mutationId, operation: .listDelete(SGTasksWire.ListDelete(listId: self.listId, baseRevision: SGTasksWire.Revision("3")!)))
    }

    private func body(_ request: URLRequest) -> String {
        return String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    // MARK: - Credential transport

    func test_aMutationCarriesExactlyDeviceAuthAndTheSealedBytes() async throws {
        let request = try self.listDelete()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.receiptBody(mutationId: self.mutationId.rawValue, operation: "list.delete", kind: "list", id: self.listId.rawValue))])
        world.proof = "sponsor"
        let result = await self.transport(world).mutate(request, accountPeerId: self.account)
        XCTAssertEqual(try result.get().receipt.mutationId, self.mutationId)
        XCTAssertEqual(world.requests.count, 1)
        let sent = world.requests[0]
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://tasks.zenlygram.test/v1/tasks/mutations")
        XCTAssertEqual(sent.allHTTPHeaderFields, [
            "Accept": "application/json",
            "Authorization": "Bearer tok-1",
            "X-Device-Id": "dev-hex",
            "X-Device-Nonce": "nonce-1",
            "X-Device-Ts": "1800000000",
            "X-Device-Sig": "sig-1",
            "X-Tasks-Wire": "4",
            "Content-Type": "application/json",
            "Idempotency-Key": self.mutationId.rawValue
        ], "no app/OS version, no X-Refresh-Token, nothing else")
        XCTAssertEqual(self.body(sent), "{\"mutation\":" + String(decoding: request.wireJSON, as: UTF8.self) + "}", "R3 bytes unchanged")
        XCTAssertEqual(world.proofsIssued, 0, "a non-create never asks for, nor carries, creation evidence")
        XCTAssertEqual(world.notedServerTimes, [SGTasksWire.Instant("2026-10-24T00:00:01Z")!.date])
    }

    func test_aCreateReselectsItsProofAndCredentialsPerAttemptWithTheSameBusinessBytes() async throws {
        let request = try self.listCreate()
        let world = World(token: "tok-1", answers: [
            Self.error(401, "nonce_replayed"),
            Self.answer(200, self.receiptBody(mutationId: self.mutationId.rawValue, operation: "list.create", kind: "list", id: self.listId.rawValue))
        ])
        world.proof = "sponsor"
        let result = await self.transport(world).mutate(request, accountPeerId: self.account)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(world.requests.count, 2)
        let sealed = String(decoding: request.wireJSON, as: UTF8.self)
        XCTAssertEqual(self.body(world.requests[0]), #"{"mutation":\#(sealed),"creation_proof":{"jws":"sponsor-1"}}"#)
        XCTAssertEqual(self.body(world.requests[1]), #"{"mutation":\#(sealed),"creation_proof":{"jws":"sponsor-2"}}"#)
        XCTAssertEqual(world.requests.map { $0.value(forHTTPHeaderField: "X-Device-Nonce") }, ["nonce-1", "nonce-2"])
        XCTAssertTrue(world.applied.isEmpty, "the recovered nonce failure is not a session failure")
    }

    func test_aCreateWithoutAnySponsorIsSentWithoutProof() async throws {
        let request = try self.listCreate()
        let world = World(token: "tok-1", answers: [Self.error(403, "tasks_creation_not_permitted")])
        let result = await self.transport(world).mutate(request, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .creationNotPermitted)
        XCTAssertFalse(self.body(world.requests[0]).contains("creation_proof"))
        XCTAssertEqual(world.requests.count, 1, "a creation refusal is never resent automatically")
    }

    func test_readsSendOnlyCursorAndLimitPercentEncoded() async throws {
        let world = World(token: "tok-1", answers: [Self.answer(200, self.snapshotBody)])
        _ = await self.transport(world).snapshot(cursor: SGTasksWire.Cursor("a+b/c=d é&x"), limit: 20, accountPeerId: self.account)
        let sent = world.requests[0]
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.absoluteString, "https://tasks.zenlygram.test/v1/tasks/snapshot?cursor=a%2Bb%2Fc%3Dd%20%C3%A9%26x&limit=20")
        XCTAssertNil(sent.httpBody)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(sent.value(forHTTPHeaderField: "Idempotency-Key"))

        let first = World(token: "tok-1", answers: [Self.answer(200, self.snapshotBody)])
        _ = await self.transport(first).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(first.requests[0].url?.absoluteString, "https://tasks.zenlygram.test/v1/tasks/snapshot")
    }

    func test_outOfBoundsLimitAndMissingSessionSendNothing() async {
        let world = World(token: "tok-1", answers: [])
        let low = await self.transport(world).changes(cursor: SGTasksWire.Cursor("c")!, limit: 0, accountPeerId: self.account)
        let high = await self.transport(world).snapshot(cursor: nil, limit: 101, accountPeerId: self.account)
        XCTAssertEqual(low.failureKind, .invalidLocalRequest)
        XCTAssertEqual(high.failureKind, .invalidLocalRequest)
        world.setToken(nil)
        let unbound = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(unbound.failureKind, .notSignedIn)
        XCTAssertTrue(world.requests.isEmpty)
    }

    // MARK: - Rotation gate

    func test_anAttemptQueuedBehindARotationIsAbandonedWhenTheTokenRotated() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.snapshotBody)])
        let transport = self.transport(world, gate: gate)
        let account = self.account
        await gate.acquire(accountPeerId: account) // the rotation is in flight
        let call = Task {
            await transport.snapshot(cursor: nil, limit: nil, accountPeerId: account)
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        world.setToken("tok-2") // the rotation stored its successor
        gate.release(accountPeerId: account)
        let result = await call.value
        XCTAssertEqual(result.failureKind, .credentialChanged)
        XCTAssertTrue(world.requests.isEmpty, "the replaced token is never presented")
        XCTAssertFalse(gate.state(accountPeerId: account).isHeld, "the abandoned attempt releases the gate")
    }

    func test_anAttemptQueuedBehindAnUnchangedSessionProceedsAndOtherAccountsNeverWait() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.snapshotBody), Self.answer(200, self.snapshotBody)])
        let transport = self.transport(world, gate: gate)
        let account = self.account
        await gate.acquire(accountPeerId: account)
        let other = await transport.snapshot(cursor: nil, limit: nil, accountPeerId: account + 1)
        XCTAssertNoThrow(try other.get(), "a held gate for one account never blocks another")
        let call = Task {
            await transport.snapshot(cursor: nil, limit: nil, accountPeerId: account)
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        XCTAssertEqual(world.requests.count, 1, "nothing is sent while the rotation holds the gate")
        gate.release(accountPeerId: account)
        let queued = await call.value
        XCTAssertNoThrow(try queued.get())
        XCTAssertEqual(world.requests.count, 2)
    }

    /// A create queued behind the account's gate — a rotation or a customer-data call holds it —
    /// whose caller's condition (its consent permission) turned false meanwhile: asked only once the
    /// gate is held, then nothing is signed, no sponsor proof is chosen and nothing is sent. It ends
    /// exactly like a call cancelled while it waited.
    func test_anAttemptQueuedBehindTheGateThatIsNoLongerWantedSendsNothing() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.receiptBody(mutationId: self.mutationId.rawValue, operation: "list.create", kind: "list", id: self.listId.rawValue))])
        world.proof = "sponsor"
        let transport = self.transport(world, gate: gate)
        let request = try self.listCreate()
        let account = self.account
        let wanted = SGTasksTestCondition(true)
        await gate.acquire(accountPeerId: account)
        let call = Task {
            await transport.mutate(request, accountPeerId: account, stillWanted: { wanted.ask() })
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        XCTAssertEqual(wanted.asked, 0, "not asked while the call waits")
        wanted.set(false) // the consent was withdrawn meanwhile
        gate.release(accountPeerId: account)
        let result = await call.value
        guard case let .failure(error) = result else {
            return XCTFail("a call no longer wanted must not be sent")
        }
        XCTAssertEqual(error, SGTasksError(kind: .transport(.cancelled), outcomeUnknown: false), "nothing was sent")
        XCTAssertEqual(wanted.asked, 1, "asked once its turn came")
        XCTAssertTrue(world.requests.isEmpty)
        XCTAssertEqual(world.signed, 0, "nothing was signed")
        XCTAssertEqual(world.proofsIssued, 0, "no sponsor proof was chosen")
        XCTAssertTrue(world.applied.isEmpty)
        XCTAssertFalse(gate.state(accountPeerId: account).isHeld, "the refused call releases the gate")
    }

    /// Every Tasks call asks the condition once its turn comes: refused, none sends anything;
    /// still wanted, each goes as usual.
    func test_everyTasksCallAsksTheConditionOnceItsTurnComes() async throws {
        let refused = World(token: "tok-1", answers: [])
        let transport = self.transport(refused)
        let account = self.account
        let no = SGTasksTestCondition(false)
        let cursor = SGTasksWire.Cursor("c1")!
        let socketId = SGTasksRealtime.SocketId("123.456")!
        let notSent = SGTasksError(kind: .transport(.cancelled), outcomeUnknown: false)
        let mutation = await transport.mutate(try self.listDelete(), accountPeerId: account, stillWanted: { no.ask() })
        let batch = await transport.mutateBatch(try self.batch(), accountPeerId: account, stillWanted: { no.ask() })
        let snapshot = await transport.snapshot(cursor: nil, limit: nil, accountPeerId: account, stillWanted: { no.ask() })
        let changes = await transport.changes(cursor: cursor, limit: nil, accountPeerId: account, stillWanted: { no.ask() })
        let metadata = await transport.realtimeMetadata(accountPeerId: account, stillWanted: { no.ask() })
        let authorization = await transport.realtimeAuth(socketId: socketId, accountPeerId: account, stillWanted: { no.ask() })
        XCTAssertEqual(mutation.failure, notSent)
        XCTAssertEqual(batch.failure, notSent)
        XCTAssertEqual(snapshot.failure, notSent)
        XCTAssertEqual(changes.failure, notSent)
        XCTAssertEqual(metadata.failure, notSent)
        XCTAssertEqual(authorization.failure, notSent)
        XCTAssertEqual(no.asked, 6)
        XCTAssertTrue(refused.requests.isEmpty, "no route sent anything")
        XCTAssertEqual(refused.signed, 0)

        let wanted = World(token: "tok-1", answers: [Self.answer(200, self.snapshotBody)])
        let yes = SGTasksTestCondition(true)
        let page = await self.transport(wanted).snapshot(cursor: nil, limit: nil, accountPeerId: account, stillWanted: { yes.ask() })
        XCTAssertNoThrow(try page.get())
        XCTAssertEqual(wanted.requests.count, 1)
        XCTAssertEqual(yes.asked, 1)
    }

    func test_theGateServesWaitersInOrder() async throws {
        let gate = SGEntitlementAccountGate()
        let log = SGTasksOrderLog()
        await gate.acquire(accountPeerId: 1)
        let first = Task {
            await gate.acquire(accountPeerId: 1)
            log.append(1)
            gate.release(accountPeerId: 1)
        }
        try await self.waitUntil { gate.state(accountPeerId: 1).waiting == 1 }
        let second = Task {
            await gate.acquire(accountPeerId: 1)
            log.append(2)
            gate.release(accountPeerId: 1)
        }
        try await self.waitUntil { gate.state(accountPeerId: 1).waiting == 2 }
        gate.release(accountPeerId: 1)
        await first.value
        await second.value
        XCTAssertEqual(log.values, [1, 2])
        XCTAssertFalse(gate.state(accountPeerId: 1).isHeld)
    }

    // MARK: - Retries and session routing

    func test_clockSkewResignsOnceWithTheServerTime() async throws {
        let world = World(token: "tok-1", answers: [Self.error(401, "clock_skew"), Self.error(401, "clock_skew")])
        let result = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .session(.clockSkew))
        XCTAssertEqual(world.requests.count, 2, "exactly one correction retry")
        XCTAssertEqual(world.adoptedOffsets, [SGTasksWire.Instant("2026-10-24T00:00:00Z")!.date])
        XCTAssertEqual(world.applied.count, 1)
        XCTAssertEqual(world.applied.first?.1, SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1"))
    }

    func test_aTokenChangedBeforeTheRetryAbandonsIt() async throws {
        let world = World(token: "tok-1", answers: [Self.error(401, "nonce_replayed"), Self.answer(200, self.snapshotBody)])
        world.duringFetch = { world in
            world.setToken("tok-2")
        }
        let result = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .credentialChanged)
        XCTAssertEqual(world.requests.count, 1, "no retry with a credential the store no longer holds")
    }

    func test_aRevokedSessionIsAppliedToTheCapturedCredentialOnly() async throws {
        let world = World(token: "tok-1", answers: [Self.error(401, "invalid_token")])
        let result = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .session(.invalidToken))
        XCTAssertEqual(world.requests.count, 1)
        XCTAssertEqual(world.applied.map { $0.0.failure }, [.session(.invalidToken)])
        XCTAssertEqual(world.applied.map { $0.1 }, [SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1")])
    }

    func test_unlinkedAccountChangesNoSessionState() async throws {
        let world = World(token: "tok-1", answers: [Self.error(403, "tasks_account_not_linked")])
        let result = await self.transport(world).mutate(try self.listCreate(), accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .accountNotLinked)
        XCTAssertTrue(world.applied.isEmpty, "never routed to SGEntitlement.apply")
        XCTAssertEqual(world.storedToken(), "tok-1")
        XCTAssertEqual(world.requests.count, 1, "no automatic retry")
        XCTAssertEqual(world.notedServerTimes.count, 1, "the body's server_time still feeds the clock")
    }

    func test_tasksRefusalsAreNeverRetriedOrApplied() async throws {
        for code in ["tasks_not_found", "tasks_resync_required", "tasks_mutation_in_flight", "tasks_invalid_request", "tasks_mutation_mismatch", "tasks_unavailable"] {
            let world = World(token: "tok-1", answers: [Self.error(code == "tasks_unavailable" ? 503 : 409, code), Self.answer(200, self.snapshotBody)])
            _ = await self.transport(world).changes(cursor: SGTasksWire.Cursor("c")!, limit: nil, accountPeerId: self.account)
            XCTAssertEqual(world.requests.count, 1, code)
            XCTAssertTrue(world.applied.isEmpty, code)
        }
    }

    // MARK: - Answers

    func test_aMalformedSuccessOfAReplacedSessionIsCredentialChanged() async throws {
        let unparseable = World(token: "tok-1", answers: [Self.answer(200, "{not json")])
        unparseable.duringFetch = { world in
            world.setToken("tok-2")
        }
        let first = await self.transport(unparseable).mutate(try self.listDelete(), accountPeerId: self.account)
        guard case let .failure(parseError) = first else {
            return XCTFail("unparseable 200")
        }
        XCTAssertEqual(parseError, SGTasksError(kind: .credentialChanged, outcomeUnknown: true), "the mutation may still have committed")

        let foreign = World(token: "tok-1", answers: [Self.answer(200, self.receiptBody(mutationId: "99999999-9999-4999-8999-999999999999", operation: "list.delete", kind: "list", id: self.listId.rawValue))])
        foreign.duringFetch = { world in
            world.setToken(nil)
        }
        let second = await self.transport(foreign).mutate(try self.listDelete(), accountPeerId: self.account)
        guard case let .failure(decodeError) = second else {
            return XCTFail("foreign receipt")
        }
        XCTAssertEqual(decodeError, SGTasksError(kind: .credentialChanged, outcomeUnknown: true))

        let read = World(token: "tok-1", answers: [Self.answer(200, "[]")])
        read.duringFetch = { world in
            world.setToken("tok-2")
        }
        let page = await self.transport(read).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        guard case let .failure(readError) = page else {
            return XCTFail("malformed page")
        }
        XCTAssertEqual(readError, SGTasksError(kind: .credentialChanged, outcomeUnknown: false))
    }

    func test_aSuccessThatOutlivedItsSessionIsDiscarded() async throws {
        let world = World(token: "tok-1", answers: [Self.answer(200, self.snapshotBody)])
        world.duringFetch = { world in
            world.setToken(nil) // logged out while the request was in flight
        }
        let result = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .credentialChanged)
    }

    func test_aReceiptForAnotherMutationIsMalformed() async throws {
        let world = World(token: "tok-1", answers: [Self.answer(200, self.receiptBody(mutationId: "99999999-9999-4999-8999-999999999999", operation: "list.delete", kind: "list", id: self.listId.rawValue))])
        let result = await self.transport(world).mutate(try self.listDelete(), accountPeerId: self.account)
        guard case let .failure(error) = result else {
            return XCTFail("a foreign receipt is not this mutation's outcome")
        }
        XCTAssertEqual(error.kind, .malformedResponse)
        XCTAssertTrue(error.outcomeUnknown, "the server answered 200: the same mutation must be resolved by resending it")
    }

    func test_aReceiptForAnotherResourceIsMalformed() async throws {
        let world = World(token: "tok-1", answers: [Self.answer(200, self.receiptBody(mutationId: self.mutationId.rawValue, operation: "list.delete", kind: "list", id: "88888888-8888-4888-8888-888888888888"))])
        let result = await self.transport(world).mutate(try self.listDelete(), accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .malformedResponse)
    }

    func test_aTimedOutMutationMayHaveCommitted() async throws {
        let world = World(token: "tok-1", answers: [.failure(.offline(.timeout))])
        let result = await self.transport(world).mutate(try self.listDelete(), accountPeerId: self.account)
        guard case let .failure(error) = result else {
            return XCTFail("timeout")
        }
        XCTAssertEqual(error.kind, .transport(.timeout))
        XCTAssertTrue(error.outcomeUnknown)
        XCTAssertEqual(world.requests.count, 1, "the transport never resends on its own")
    }

    func test_aNon200SuccessStatusIsMalformedAndMayHaveCommitted() async throws {
        for status in [201, 202, 204] {
            let world = World(token: "tok-1", answers: [Self.answer(status, "")])
            let result = await self.transport(world).mutate(try self.listDelete(), accountPeerId: self.account)
            guard case let .failure(error) = result else {
                return XCTFail("\(status) is not the wire's success")
            }
            XCTAssertEqual(error.kind, .malformedResponse, "\(status)")
            XCTAssertTrue(error.outcomeUnknown, "\(status): resolve by resending the SAME mutation, never a new id")
            XCTAssertEqual(world.requests.count, 1)
        }
        let read = World(token: "tok-1", answers: [Self.answer(204, "")])
        let page = await self.transport(read).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        guard case let .failure(error) = page else {
            return XCTFail("204 is not a page")
        }
        XCTAssertEqual(error, SGTasksError(kind: .malformedResponse, outcomeUnknown: false))
    }

    // MARK: - Credential changed during the request

    func test_aSessionFailureOfAReplacedSessionIsNotAppliedNorReported() async throws {
        let world = World(token: "tok-1", answers: [Self.error(401, "invalid_token")])
        world.duringFetch = { world in
            world.setToken("tok-2") // a re-bind landed while the request was out
        }
        let result = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .credentialChanged)
        XCTAssertTrue(world.applied.isEmpty, "the old session's 401 never reaches the session machinery")
        XCTAssertEqual(world.storedToken(), "tok-2")
    }

    func test_aTransportFailureOfAReplacedSessionKeepsTheUnknownOutcome() async throws {
        let world = World(token: "tok-1", answers: [.failure(.offline(.timeout))])
        world.duringFetch = { world in
            world.setToken(nil)
        }
        let result = await self.transport(world).mutate(try self.listDelete(), accountPeerId: self.account)
        guard case let .failure(error) = result else {
            return XCTFail("timeout")
        }
        XCTAssertEqual(error, SGTasksError(kind: .credentialChanged, outcomeUnknown: true))
    }

    func test_aTasksRefusalOfAReplacedSessionIsCredentialChanged() async throws {
        let world = World(token: "tok-1", answers: [Self.error(503, "tasks_unavailable")])
        world.duringFetch = { world in
            world.setToken("tok-2")
        }
        let result = await self.transport(world).mutate(try self.listDelete(), accountPeerId: self.account)
        guard case let .failure(error) = result else {
            return XCTFail("503")
        }
        XCTAssertEqual(error.kind, .credentialChanged)
        XCTAssertTrue(error.outcomeUnknown)
    }

    // MARK: - Session codes outside 401

    func test_aSessionCodeUnderAnotherStatusNeverDropsTheSession() async throws {
        let world = World(token: "tok-1", answers: [Self.answer(403, #"{"error":"invalid_token"}"#)])
        let forbidden = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(forbidden.failureKind, .rejected(status: 403))
        XCTAssertTrue(world.applied.isEmpty)
        XCTAssertEqual(world.requests.count, 1, "and no session retry")

        let proxy = World(token: "tok-1", answers: [Self.answer(503, #"{"error":"device_revoked"}"#)])
        let unavailable = await self.transport(proxy).mutate(try self.listDelete(), accountPeerId: self.account)
        guard case let .failure(error) = unavailable else {
            return XCTFail("503")
        }
        XCTAssertEqual(error.kind, .unavailable)
        XCTAssertTrue(error.outcomeUnknown)
        XCTAssertTrue(proxy.applied.isEmpty)

        let nonce = World(token: "tok-1", answers: [Self.answer(409, #"{"error":"nonce_replayed"}"#), Self.answer(200, self.snapshotBody)])
        _ = await self.transport(nonce).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(nonce.requests.count, 1, "the fresh-credential retry belongs to the 401 family only")
    }

    // MARK: - Cancellation

    func test_aCallCancelledWhileQueuedSendsNothing() async throws {
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.receiptBody(mutationId: self.mutationId.rawValue, operation: "list.delete", kind: "list", id: self.listId.rawValue))])
        let transport = self.transport(world, gate: gate)
        let request = try self.listDelete()
        let account = self.account
        await gate.acquire(accountPeerId: account)
        let call = Task {
            await transport.mutate(request, accountPeerId: account)
        }
        try await self.waitUntil { gate.state(accountPeerId: account).waiting == 1 }
        call.cancel()
        gate.release(accountPeerId: account)
        let result = await call.value
        guard case let .failure(error) = result else {
            return XCTFail("a cancelled call must not deliver a sent outcome")
        }
        XCTAssertEqual(error, SGTasksError(kind: .transport(.cancelled), outcomeUnknown: false), "nothing was sent")
        XCTAssertTrue(world.requests.isEmpty)
        XCTAssertFalse(gate.state(accountPeerId: account).isHeld)
    }

    /// Through the real exchange: a hanging response is abandoned as soon as the call is cancelled,
    /// the gate is free again, and the mutation is reported as possibly committed.
    func test_aCallCancelledInFlightReturnsPromptlyAndKeepsTheUnknownOutcome() async throws {
        let host = "tasks.zenlygram.test"
        SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(20, of: 16), chunkInterval: 0.5)])
        defer {
            SGPolicyStubProtocol.reset(routes: [:])
        }
        let gate = SGEntitlementAccountGate()
        let world = World(token: "tok-1", answers: [])
        let transport = self.transport(world, gate: gate, fetch: { request, timeout, limit in
            return await SGTasksBoundedExchange.perform(request, timeout: timeout, limit: limit, protocolClasses: [SGPolicyStubProtocol.self])
        })
        let request = try self.listDelete()
        let account = self.account
        let call = Task {
            await transport.mutate(request, accountPeerId: account)
        }
        try await self.waitUntil { SGPolicyStubProtocol.requests.count == 1 }
        let cancelledAt = Date()
        call.cancel()
        let result = await call.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2.0, "not held until the 10 s exchange bound")
        guard case let .failure(error) = result else {
            return XCTFail("cancelled")
        }
        XCTAssertEqual(error, SGTasksError(kind: .transport(.cancelled), outcomeUnknown: true))
        XCTAssertFalse(gate.state(accountPeerId: account).isHeld)
    }

    func test_theExchangeHonoursACancellationThatArrivedFirst() async {
        let host = "tasks-precancel.zenlygram.test"
        SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(20, of: 16), chunkInterval: 0.5)])
        defer {
            SGPolicyStubProtocol.reset(routes: [:])
        }
        let url = URL(string: "https://\(host)/v1/tasks/snapshot")!
        let call = Task { () -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> in
            withUnsafeCurrentTask { $0?.cancel() }
            return await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: 1024, protocolClasses: [SGPolicyStubProtocol.self])
        }
        let result = await call.value
        guard case .failure(.offline(.cancelled)) = result else {
            return XCTFail("an already-cancelled caller gets no answer")
        }
    }

    // MARK: - Bounded exchange (real URLSession path)

    func test_theExchangeReportsRetryAfterAndBoundsTheBody() async {
        let host = "tasks-exchange.zenlygram.test"
        let url = URL(string: "https://\(host)/v1/tasks/snapshot")!
        SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(status: 429, headers: ["Retry-After": "17"], chunks: [Data("{}".utf8)])])
        let throttled = await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: 1024, protocolClasses: [SGPolicyStubProtocol.self])
        XCTAssertEqual(try? throttled.get(), SGTasksTransport.HTTPAnswer(status: 429, body: Data("{}".utf8), retryAfter: 17))

        SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(3, of: 512))])
        let oversized = await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: 1024, protocolClasses: [SGPolicyStubProtocol.self])
        guard case .failure(.offline(.malformedResponse)) = oversized else {
            return XCTFail("a body past the bound is refused while it arrives")
        }

        SGPolicyStubProtocol.reset(routes: [
            host: SGPolicyStubProtocol.Route(status: 307, redirectTo: URL(string: "https://elsewhere.zenlygram.test/v1/tasks/snapshot")!),
            "elsewhere.zenlygram.test": SGPolicyStubProtocol.Route(chunks: [Data(self.snapshotBody.utf8)])
        ])
        _ = await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: 1024, protocolClasses: [SGPolicyStubProtocol.self])
        XCTAssertEqual(SGPolicyStubProtocol.requests.compactMap { $0.url?.host }, [host], "no redirect is followed")
        SGPolicyStubProtocol.reset(routes: [:])
    }

    // MARK: - Page bound

    /// A legal full page whose text the server sends entirely as `\uXXXX` escapes (no assumption
    /// of unescaped Unicode) is past an 8 MiB guess and must still be accepted under the cap.
    func test_aFullyEscapedLegalPageOfAHundredMaximalTasksIsAccepted() async throws {
        // Legal at every R3 ceiling at once: "a" + N × U+0301 + "b" is 2 graphemes (well under the
        // 200 / 4096 / 256 grapheme limits) and exactly at the UTF-8 byte ceiling, and each 2-byte
        // combining mark travels as a 6-byte `\u0301` escape.
        func escaped(marks: Int) -> String {
            return #"\u0061"# + String(repeating: #"\u0301"#, count: marks) + #"\u0062"#
        }
        let title = escaped(marks: 4095) // 8192 UTF-8 bytes
        let description = escaped(marks: 8191) // 16384 UTF-8 bytes
        let name = escaped(marks: 2047) // 4096 UTF-8 bytes
        var rows: [String] = []
        for index in 0 ..< 100 {
            let suffix = String(index)
            let id = "33333333-3333-4333-8333-" + String(repeating: "0", count: 12 - suffix.count) + suffix
            rows.append(#"{"kind":"task","id":"\#(id)","revision":"1","owner_tg_id":"777000","viewer_role":"owner","content":{"list_id":null,"title":"\#(title)","description":"\#(description)","due_at":null,"priority":0,"sort_order":\#(index),"annotation":{"telegram_user_id":"42","display_name":"\#(name)"}},"is_completed":false,"completed_at":null,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z","assignment":null}"#)
        }
        let body = #"{"schema_version":1,"items":[\#(rows.joined(separator: ","))],"next_cursor":"n","changes_cursor":"c","server_time":"2026-10-24T00:00:00Z"}"#
        XCTAssertGreaterThan(body.utf8.count, 8 << 20, "the fixture must exceed the old guess to mean anything")
        XCTAssertLessThanOrEqual(body.utf8.count, SGTasksTransport.readResponseLimit)
        let world = World(token: "tok-1", answers: [Self.answer(200, body)])
        let page = try await self.transport(world).snapshot(cursor: nil, limit: 100, accountPeerId: self.account).get()
        XCTAssertEqual(page.items.count, 100)
        guard case let .task(first) = page.items[0] else {
            return XCTFail("the page is tasks")
        }
        XCTAssertEqual(first.content.title.utf8.count, 8192)
        XCTAssertEqual(first.content.description?.utf8.count, 16384)
        XCTAssertEqual(first.content.annotation?.displayName.utf8.count, 4096)
        XCTAssertEqual(first.content.title.count, 2)
        XCTAssertEqual(first.content.description?.count, 2)
        XCTAssertEqual(first.content.annotation?.displayName.count, 2)
        // The fixture is a row a client could have sealed: the full native rules accept it.
        XCTAssertNoThrow(try SGTasksWireValidation.check(first.content.title, SGTasksWireValidation.taskTitle, level: .sealing, path: "title"))
        XCTAssertNoThrow(try SGTasksWireValidation.check(first.content.description ?? "", SGTasksWireValidation.description, level: .sealing, path: "description"))
        XCTAssertNoThrow(try SGTasksWireValidation.check(first.content.annotation?.displayName ?? "", SGTasksWireValidation.displayName, level: .sealing, path: "display_name"))
    }

    /// Through the real `URLSession` path: exactly the cap is accepted, a stream past it is refused
    /// while it arrives, not after buffering all of it.
    func test_aPageStreamPastTheCapIsCutOffWhileItArrives() async {
        let host = "tasks-cap.zenlygram.test"
        let url = URL(string: "https://\(host)/v1/tasks/snapshot")!
        let megabyte = 1 << 20
        XCTAssertEqual(SGTasksTransport.readResponseLimit, 32 * megabyte)

        SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(32, of: megabyte), chunkInterval: 0.005)])
        let accepted = await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: SGTasksTransport.readResponseLimit, protocolClasses: [SGPolicyStubProtocol.self])
        XCTAssertEqual(try? accepted.get().body.count, SGTasksTransport.readResponseLimit)

        let over = SGPolicyStubProtocol.chunks(40, of: megabyte)
        SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(chunks: over, chunkInterval: 0.005)])
        let refused = await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: SGTasksTransport.readResponseLimit, protocolClasses: [SGPolicyStubProtocol.self])
        guard case .failure(.offline(.malformedResponse)) = refused else {
            SGPolicyStubProtocol.reset(routes: [:])
            return XCTFail("a page past 32 MiB must be refused")
        }
        XCTAssertLessThan(SGPolicyStubProtocol.deliveredChunks, over.count, "cancelled during the stream")
        SGPolicyStubProtocol.reset(routes: [:])
    }

    // MARK: - Wire R4

    private let taskId = SGTasksWire.UUID("33333333-3333-4333-8333-333333333333")!
    private let batchId = SGTasksWire.UUID("99999999-9999-4999-8999-999999999999")!

    private func patch() throws -> SGTasksWire.PatchRequest {
        return try SGTasksWire.PatchRequest(mutationId: SGTasksWire.UUID("66666666-6666-4666-8666-666666666666")!, patch: SGTasksWire.TaskPatch(
            taskId: self.taskId,
            set: [.title: .title("Hisobot 2")],
            expect: [.title: .title("Hisobot")]
        ))
    }

    /// A migration create, then a user patch.
    private func batch() throws -> SGTasksWire.MutationBatchRequest {
        return try SGTasksWire.MutationBatchRequest(batchId: self.batchId, items: [.init(.mutation(try self.listCreate()), origin: .migration), .init(.patch(try self.patch()))])
    }

    private func batchBody(results: [String], retryAfter: String = "null") -> String {
        return #"{"schema_version":1,"batch_id":"\#(self.batchId.rawValue)","results":[\#(results.joined(separator: ","))],"retry_after":\#(retryAfter),"server_time":"2026-10-24T00:00:02Z"}"#
    }

    private var createReceiptResult: String {
        return #"{"mutation_id":"\#(self.mutationId.rawValue)","status":200,"receipt":\#(self.receiptJSON(mutationId: self.mutationId.rawValue, operation: "list.create", kind: "list", id: self.listId.rawValue))}"#
    }

    private var patchReceiptResult: String {
        return #"{"mutation_id":"66666666-6666-4666-8666-666666666666","status":200,"receipt":\#(self.receiptJSON(mutationId: "66666666-6666-4666-8666-666666666666", operation: "task.patch", kind: "task", id: self.taskId.rawValue))}"#
    }

    private func receiptJSON(mutationId: String, operation: String, kind: String, id: String) -> String {
        return #"{"mutation_id":"\#(mutationId)","operation":"\#(operation)","outcome":"committed","resource_kind":"\#(kind)","resource_id":"\#(id)","resource_revision":"1","committed_at":"2026-10-24T00:00:00Z"}"#
    }

    func test_everyTasksCallCarriesExactlyOneWireHeader() async throws {
        let world = World(token: "tok-1", answers: [])
        let transport = self.transport(world)
        _ = await transport.mutate(try self.listDelete(), accountPeerId: self.account)
        _ = await transport.mutate(.patch(try self.patch()), accountPeerId: self.account)
        _ = await transport.mutateBatch(try self.batch(), accountPeerId: self.account)
        _ = await transport.snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        _ = await transport.changes(cursor: SGTasksWire.Cursor("c")!, limit: nil, accountPeerId: self.account)
        _ = await transport.realtimeMetadata(accountPeerId: self.account)
        _ = await transport.realtimeAuth(socketId: SGTasksRealtime.SocketId("123.456")!, accountPeerId: self.account)
        XCTAssertEqual(world.requests.map { $0.url?.path }, ["/v1/tasks/mutations", "/v1/tasks/mutations", "/v1/tasks/mutations/batch", "/v1/tasks/snapshot", "/v1/tasks/changes", "/v1/tasks/realtime", "/v1/tasks/realtime/auth"])
        for request in world.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tasks-Wire"), "4", request.url?.path ?? "")
            XCTAssertEqual(request.allHTTPHeaderFields?.keys.filter { $0.caseInsensitiveCompare("X-Tasks-Wire") == .orderedSame }.count, 1, request.url?.path ?? "")
        }
    }

    /// wf15 §8.2: the header is the build's request wire — 4 for every build made for today's production
    /// (`sg_config.tasks_wire` absent) and 5 only for a build made for a wire-5 backend; never probed.
    func test_theWireHeaderIsTheBuildsRequestWireOnEveryCall() async throws {
        for wire in [SGTasksWire.wireRevision, SGTasksWire.maximumWire] {
            let world = World(token: "tok-1", answers: [])
            let transport = self.transport(world, requestWire: wire)
            _ = await transport.mutate(try self.listDelete(), accountPeerId: self.account)
            _ = await transport.mutate(.patch(try self.patch()), accountPeerId: self.account)
            _ = await transport.mutateBatch(try self.batch(), accountPeerId: self.account)
            _ = await transport.snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
            _ = await transport.changes(cursor: SGTasksWire.Cursor("c")!, limit: nil, accountPeerId: self.account)
            _ = await transport.realtimeMetadata(accountPeerId: self.account)
            _ = await transport.realtimeAuth(socketId: SGTasksRealtime.SocketId("123.456")!, accountPeerId: self.account)
            XCTAssertEqual(world.requests.count, 7, "wire \(wire)")
            for request in world.requests {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tasks-Wire"), String(wire), "wire \(wire): \(request.url?.path ?? "")")
                XCTAssertEqual(request.allHTTPHeaderFields?.keys.filter { $0.caseInsensitiveCompare("X-Tasks-Wire") == .orderedSame }.count, 1, request.url?.path ?? "")
            }
        }
    }

    /// Production builds the environment without naming the wire: it is the shipped one, within 4 ... 5.
    func test_theEnvironmentDefaultsToTheShippedRequestWire() {
        let environment = SGTasksTransport.Environment(
            baseURL: self.baseURL,
            timeout: 5,
            gate: SGEntitlementAccountGate(),
            storedRefreshToken: { _ in nil },
            deviceCredentials: { nil },
            noteServerTime: { _ in },
            adoptServerOffset: { _ in },
            creationProof: { _ in nil },
            applySessionFailure: { _, _ in },
            fetch: { _, _, _ in .failure(.offline(.timeout)) }
        )
        XCTAssertEqual(environment.requestWire, SGTasksShippedWire.requestWire)
        XCTAssertGreaterThanOrEqual(SGTasksShippedWire.requestWire, SGTasksWire.wireRevision)
        XCTAssertLessThanOrEqual(SGTasksShippedWire.requestWire, SGTasksWire.maximumWire)
    }

    func test_theBatchCallPostsItsSealedItemsUnderTheBatchIdWithItsOwnBudget() async throws {
        let batch = try self.batch()
        let world = World(token: "tok-1", answers: [Self.answer(200, self.batchBody(results: [self.createReceiptResult, self.patchReceiptResult]), serverWire: 4), Self.answer(200, self.snapshotBody)])
        world.proof = "sponsor"
        let result = await self.transport(world).mutateBatch(batch, accountPeerId: self.account)
        let response = try result.get()
        XCTAssertEqual(response.results.count, 2)
        XCTAssertEqual(response.serverWire, 4)
        let sent = world.requests[0]
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://tasks.zenlygram.test/v1/tasks/mutations/batch")
        XCTAssertEqual(sent.allHTTPHeaderFields, [
            "Accept": "application/json",
            "Authorization": "Bearer tok-1",
            "X-Device-Id": "dev-hex",
            "X-Device-Nonce": "nonce-1",
            "X-Device-Ts": "1800000000",
            "X-Device-Sig": "sig-1",
            "X-Tasks-Wire": "4",
            "Content-Type": "application/json",
            "Idempotency-Key": self.batchId.rawValue
        ])
        let create = String(decoding: try self.listCreate().wireJSON, as: UTF8.self)
        let patch = String(decoding: try self.patch().wireJSON, as: UTF8.self)
        var expected = #"{"schema_version":1,"batch_id":"99999999-9999-4999-8999-999999999999","mutations":[{"origin":"migration","#
        expected += String(create.dropFirst()) + "," + patch
        expected += #"],"creation_proof":{"jws":"sponsor-1"}}"#
        XCTAssertEqual(self.body(sent), expected, "sealed bytes byte for byte; one proof, because a create is in the batch")
        XCTAssertEqual(world.limits.first, SGTasksTransport.batchResponseLimit)
        XCTAssertEqual(SGTasksTransport.batchResponseLimit, 262144)
        XCTAssertEqual(world.timeouts.first, 10, "the batch call alone waits 10 s idle (20 s whole)")
        XCTAssertEqual(sent.timeoutInterval, 10)

        _ = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(world.timeouts.last, 5, "every other call keeps 5 s / 10 s")
        XCTAssertEqual(world.requests.last?.timeoutInterval, 5)

        let userOnly = try SGTasksWire.MutationBatchRequest(batchId: self.batchId, items: [.init(.patch(try self.patch()))])
        let noCreate = World(token: "tok-1", answers: [])
        noCreate.proof = "sponsor"
        _ = await self.transport(noCreate).mutateBatch(userOnly, accountPeerId: self.account)
        XCTAssertEqual(self.body(noCreate.requests[0]), #"{"schema_version":1,"batch_id":"99999999-9999-4999-8999-999999999999","mutations":["# + patch + "]}")
        XCTAssertEqual(noCreate.proofsIssued, 0, "no create, no sponsor asked")
    }

    func test_aBatchAnswerIsCheckedAgainstItsRequest() async throws {
        let foreignBatch = World(token: "tok-1", answers: [Self.answer(200, self.batchBody(results: [self.createReceiptResult, self.patchReceiptResult]).replacingOccurrences(of: self.batchId.rawValue, with: "99999999-9999-4999-8999-999999999998"))])
        guard case let .failure(error) = await self.transport(foreignBatch).mutateBatch(try self.batch(), accountPeerId: self.account) else {
            return XCTFail("another batch's answer")
        }
        XCTAssertEqual(error, SGTasksError(kind: .malformedResponse, outcomeUnknown: true), "a 200 that broke the wire may still have committed")

        let foreignReceipt = World(token: "tok-1", answers: [Self.answer(200, self.batchBody(results: [self.createReceiptResult, self.patchReceiptResult.replacingOccurrences(of: #""operation":"task.patch""#, with: #""operation":"task.update""#)]))])
        let swapped = await self.transport(foreignReceipt).mutateBatch(try self.batch(), accountPeerId: self.account)
        XCTAssertEqual(swapped.failureKind, .malformedResponse, "a patch is answered as a patch")

        let skipped = World(token: "tok-1", answers: [Self.answer(200, self.batchBody(results: [self.createReceiptResult, #"{"mutation_id":"66666666-6666-4666-8666-666666666666","status":null,"skipped":true}"#]))])
        let partial = try await self.transport(skipped).mutateBatch(try self.batch(), accountPeerId: self.account).get()
        XCTAssertEqual(partial.results.last, .skipped)
        XCTAssertNil(partial.serverWire, "no echo, no wire")
    }

    func test_batchEnvelopeRefusalsStayDistinguishable() async throws {
        let time = #""server_time":"2026-10-24T00:00:00Z""#
        let cases: [(Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass>, SGTasksError.Kind, SGTasksError.Refinement?, Bool)] = [
            (Self.answer(404, #"{"error":"not_found","message":"m",\#(time)}"#), .rejected(status: 404), nil, false),
            (Self.answer(413, #"{"error":"tasks_invalid_request","message":"m",\#(time)}"#), .rejected(status: 413), nil, false),
            (Self.answer(422, #"{"error":"tasks_invalid_request","message":"m",\#(time)}"#), .invalidRequest, nil, false),
            (Self.answer(503, #"{"error":"tasks_unavailable","message":"m",\#(time),"reason":"batch_disabled"}"#), .unavailable, .batchDisabled, false),
            (Self.answer(503, #"{"error":"tasks_unavailable","message":"m",\#(time)}"#), .unavailable, nil, true),
            (Self.answer(403, #"{"error":"tasks_account_not_linked","message":"m",\#(time)}"#), .accountNotLinked, nil, false)
        ]
        for (answer, kind, refinement, unknown) in cases {
            let world = World(token: "tok-1", answers: [answer, Self.answer(200, self.snapshotBody)])
            guard case let .failure(error) = await self.transport(world).mutateBatch(try self.batch(), accountPeerId: self.account) else {
                XCTFail("\(kind) is a refusal")
                continue
            }
            XCTAssertEqual(error.kind, kind)
            XCTAssertEqual(error.refinement, refinement, "\(kind)")
            XCTAssertEqual(error.outcomeUnknown, unknown, "\(kind)")
            XCTAssertEqual(world.requests.count, 1, "\(kind): never resent by the transport")
            XCTAssertTrue(world.applied.isEmpty, "\(kind)")
        }
    }

    func test_theConsentFenceIsNeverASessionMatter() async throws {
        let fence = #"{"error":"tasks_consent_required","message":"m","reason":"withdrawn","effective_at":"2026-10-30T12:00:00Z","server_time":"2026-10-31T00:00:00Z"}"#
        let read = World(token: "tok-1", answers: [Self.answer(403, fence)])
        guard case let .failure(error) = await self.transport(read).snapshot(cursor: nil, limit: nil, accountPeerId: self.account) else {
            return XCTFail("fenced")
        }
        XCTAssertEqual(error, SGTasksError(kind: .rejected(status: 403), serverTime: SGTasksWire.Instant("2026-10-31T00:00:00Z")?.date, refinement: .consentRequired(effectiveAt: "2026-10-30T12:00:00Z")))
        XCTAssertTrue(read.applied.isEmpty)
        XCTAssertEqual(read.storedToken(), "tok-1")
        XCTAssertEqual(read.requests.count, 1)

        let item = #"{"mutation_id":"\#(self.mutationId.rawValue)","status":403,"error":{"error":"tasks_consent_required","message":"m","reason":"withdrawn","effective_at":"2026-10-30T12:00:00Z"}}"#
        let skipped = #"{"mutation_id":"66666666-6666-4666-8666-666666666666","status":null,"skipped":true}"#
        let batch = World(token: "tok-1", answers: [Self.answer(200, self.batchBody(results: [item, skipped]), serverWire: 4)])
        let response = try await self.transport(batch).mutateBatch(try self.batch(), accountPeerId: self.account).get()
        XCTAssertEqual(response.results, [.error(status: 403, SGTasksError(kind: .rejected(status: 403), serverTime: SGTasksWire.Instant("2026-10-24T00:00:02Z")?.date, refinement: .consentRequired(effectiveAt: "2026-10-30T12:00:00Z"))), .skipped])
        XCTAssertTrue(batch.applied.isEmpty)
    }

    func test_anItem401IsAppliedOnceToTheCapturedCredentialAndTheAnswerDelivered() async throws {
        let revoked = #"{"mutation_id":"\#(self.mutationId.rawValue)","status":401,"error":{"error":"device_revoked","message":"m"}}"#
        let alsoRevoked = #"{"mutation_id":"66666666-6666-4666-8666-666666666666","status":401,"error":{"error":"device_revoked","message":"m"}}"#
        let world = World(token: "tok-1", answers: [Self.answer(200, self.batchBody(results: [revoked, alsoRevoked]))])
        let response = try await self.transport(world).mutateBatch(try self.batch(), accountPeerId: self.account).get()
        XCTAssertEqual(response.results.map { result -> SGTasksError.Kind? in
            if case let .error(_, error) = result {
                return error.kind
            }
            return nil
        }, [.session(.deviceRevoked), .session(.deviceRevoked)])
        XCTAssertEqual(world.applied.count, 1, "one binding, one apply")
        XCTAssertEqual(world.applied.first?.0, SGEntitlementRequestError(failure: .session(.deviceRevoked), serverTime: SGTasksWire.Instant("2026-10-24T00:00:02Z")?.date, status: 401, code: "device_revoked"))
        XCTAssertEqual(world.applied.first?.1, SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "tok-1"))
        XCTAssertEqual(world.requests.count, 1, "an item 401 is never retried: other items may have committed")

        let replaced = World(token: "tok-1", answers: [Self.answer(200, self.batchBody(results: [revoked, alsoRevoked]))])
        replaced.duringFetch = { world in
            world.setToken("tok-2")
        }
        let late = await self.transport(replaced).mutateBatch(try self.batch(), accountPeerId: self.account)
        XCTAssertEqual(late.failureKind, .credentialChanged)
        XCTAssertTrue(replaced.applied.isEmpty, "the old binding's item 401 is not this account's anymore")
    }

    /// Carry-forward from the customer-data transport: the DeviceAuth 401's body `reason` (an erased
    /// account's `account_erased`) reaches `apply`, which records it on the session end.
    func test_anEnvelope401HandsItsReasonToTheSession() async throws {
        let world = World(token: "tok-1", answers: [Self.answer(401, #"{"error":"invalid_token","message":"m","reason":"account_erased","server_time":"2026-10-24T00:00:00Z"}"#)])
        let result = await self.transport(world).snapshot(cursor: nil, limit: nil, accountPeerId: self.account)
        XCTAssertEqual(result.failureKind, .session(.invalidToken))
        XCTAssertEqual(world.applied.map { $0.0 }, [SGEntitlementRequestError(failure: .session(.invalidToken), serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, status: 401, code: "invalid_token", reason: "account_erased")])
    }

    func test_everyRestResultRecordsTheWireEcho() async throws {
        let echoed = World(token: "tok-1", answers: [
            Self.answer(200, self.receiptBody(mutationId: self.mutationId.rawValue, operation: "list.delete", kind: "list", id: self.listId.rawValue), serverWire: 4),
            Self.answer(200, self.snapshotBody, serverWire: 4),
            Self.answer(200, #"{"schema_version":1,"changes":[],"next_cursor":"c2","has_more":false,"server_time":"2026-10-24T00:00:00Z"}"#, serverWire: 4)
        ])
        let transport = self.transport(echoed)
        let mutation = try await transport.mutate(try self.listDelete(), accountPeerId: self.account).get()
        let snapshot = try await transport.snapshot(cursor: nil, limit: nil, accountPeerId: self.account).get()
        let changes = try await transport.changes(cursor: SGTasksWire.Cursor("c")!, limit: nil, accountPeerId: self.account).get()
        XCTAssertEqual(mutation.serverWire, 4)
        XCTAssertEqual(snapshot.serverWire, 4)
        XCTAssertEqual(changes.serverWire, 4)

        let silent = World(token: "tok-1", answers: [
            Self.answer(200, self.receiptBody(mutationId: self.mutationId.rawValue, operation: "list.delete", kind: "list", id: self.listId.rawValue)),
            Self.answer(200, self.snapshotBody)
        ])
        let r3 = self.transport(silent)
        let r3Mutation = try await r3.mutate(try self.listDelete(), accountPeerId: self.account).get()
        let r3Snapshot = try await r3.snapshot(cursor: nil, limit: nil, accountPeerId: self.account).get()
        XCTAssertNil(r3Mutation.serverWire, "an R3 server's 2xx: the downgrade signal")
        XCTAssertNil(r3Snapshot.serverWire)
    }

    func test_aPatchTravelsTheSingleRouteAsItsSealedBytes() async throws {
        let patch = try self.patch()
        let world = World(token: "tok-1", answers: [
            Self.answer(200, #"{"schema_version":1,"receipt":\#(self.receiptJSON(mutationId: patch.mutationId.rawValue, operation: "task.patch", kind: "task", id: self.taskId.rawValue)),"server_time":"2026-10-24T00:00:01Z"}"#),
            Self.answer(200, #"{"schema_version":1,"receipt":\#(self.receiptJSON(mutationId: patch.mutationId.rawValue, operation: "task.update", kind: "task", id: self.taskId.rawValue)),"server_time":"2026-10-24T00:00:01Z"}"#)
        ])
        world.proof = "sponsor"
        let response = try await self.transport(world).mutate(.patch(patch), accountPeerId: self.account).get()
        XCTAssertEqual(response.receipt.operation, .taskPatch)
        XCTAssertEqual(self.body(world.requests[0]), "{\"mutation\":" + String(decoding: patch.wireJSON, as: UTF8.self) + "}")
        XCTAssertEqual(world.requests[0].value(forHTTPHeaderField: "Idempotency-Key"), patch.mutationId.rawValue)
        XCTAssertEqual(world.proofsIssued, 0, "a patch is no create")
        let misanswered = await self.transport(world).mutate(.patch(patch), accountPeerId: self.account)
        XCTAssertEqual(misanswered.failureKind, .malformedResponse, "a task.update receipt does not answer a patch")
    }

    /// Through the real `URLSession` path: the echo is read from the response header, exactly.
    func test_theExchangeReadsTheWireEcho() async {
        let host = "tasks-wire.zenlygram.test"
        let url = URL(string: "https://\(host)/v1/tasks/snapshot")!
        defer {
            SGPolicyStubProtocol.reset(routes: [:])
        }
        for (header, expected) in [("4", 4), ("04", nil), ("4, 4", nil), ("", nil)] as [(String, Int?)] {
            SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(headers: ["X-Tasks-Wire": header], chunks: [Data(self.snapshotBody.utf8)])])
            let answer = try? await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: 1024, protocolClasses: [SGPolicyStubProtocol.self]).get()
            XCTAssertEqual(answer?.status, 200, header)
            XCTAssertEqual(answer?.serverWire, expected, header)
        }
        SGPolicyStubProtocol.reset(routes: [host: SGPolicyStubProtocol.Route(chunks: [Data(self.snapshotBody.utf8)])])
        let silent = try? await SGTasksBoundedExchange.perform(URLRequest(url: url), timeout: 5, limit: 1024, protocolClasses: [SGPolicyStubProtocol.self]).get()
        XCTAssertEqual(silent?.status, 200)
        XCTAssertNil(silent?.serverWire)
        XCTAssertEqual(SGTasksBoundedExchange.serverWire(" 4 "), 4)
        XCTAssertNil(SGTasksBoundedExchange.serverWire("-4"))
        XCTAssertNil(SGTasksBoundedExchange.serverWire("4.0"))
        XCTAssertNil(SGTasksBoundedExchange.serverWire(nil))
    }

    // MARK: - Helpers

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

private extension Result where Failure == SGTasksError {
    var failureKind: SGTasksError.Kind? {
        if case let .failure(error) = self {
            return error.kind
        }
        return nil
    }

    var failure: SGTasksError? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}

/// A caller's `stillWanted`, set by the test, counting how often it was asked.
private final class SGTasksTestCondition: @unchecked Sendable {
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

private final class SGTasksOrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int] = []

    func append(_ value: Int) {
        self.lock.lock()
        self.entries.append(value)
        self.lock.unlock()
    }

    var values: [Int] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries
    }
}

// The binding marker reads the real store, which the Bazel targets always link (see
// `SGEntitlementTestSupport.swift`).
#if canImport(SGProtectedStore)
/// `tasksBindingMarker`: lowercase hex SHA-256 of `accountId` NUL `deviceId` of the stored session —
/// stable across refresh rotation, new with a new binding, gone without a session.
final class SGTasksBindingMarkerTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var store: SGEntitlementStore!
    private var entitlement: SGEntitlement!

    override func setUp() {
        super.setUp()
        self.storeSuite = "SGTasksBindingMarkerTests.store.\(UUID().uuidString)"
        self.schedulerSuite = "SGTasksBindingMarkerTests.scheduler.\(UUID().uuidString)"
        self.store = SGEntitlementOwnedStore.make(suiteName: self.storeSuite)
        self.entitlement = SGEntitlement(store: self.store, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)))
    }

    override func tearDown() {
        self.store.clearSession(accountPeerId: self.account)
        UserDefaults(suiteName: self.storeSuite)?.removePersistentDomain(forName: self.storeSuite)
        UserDefaults(suiteName: self.schedulerSuite)?.removePersistentDomain(forName: self.schedulerSuite)
        self.entitlement = nil
        self.store = nil
        super.tearDown()
    }

    private func bind(refreshToken: String, deviceId: String) {
        let written = self.store.updateSession(accountPeerId: self.account) { material in
            material.refreshToken = refreshToken
            material.accountId = "01JB8Q"
            material.deviceId = deviceId
        }
        guard case .success = written else {
            return XCTFail("the owned store could not persist the bind: \(written)")
        }
    }

    func test_theMarkerNamesTheBindingAndNothingElse() {
        XCTAssertNil(self.entitlement.tasksBindingMarker(accountPeerId: self.account), "no session, no marker")
        self.bind(refreshToken: "bound-1", deviceId: "01JB8R")
        // sha256("01JB8Q\0" + "01JB8R"), computed independently.
        XCTAssertEqual(self.entitlement.tasksBindingMarker(accountPeerId: self.account), "db9d4d3a0840e1469ca57393cac93214d2ea89d5f7f159fb3b515649d1ef3d0b")
        let realtime = self.entitlement.tasksRealtimeSessionMarker(accountPeerId: self.account)

        self.bind(refreshToken: "bound-2", deviceId: "01JB8R")
        XCTAssertEqual(self.entitlement.tasksBindingMarker(accountPeerId: self.account), "db9d4d3a0840e1469ca57393cac93214d2ea89d5f7f159fb3b515649d1ef3d0b", "a refresh rotation keeps the binding")
        XCTAssertNotEqual(self.entitlement.tasksRealtimeSessionMarker(accountPeerId: self.account), realtime, "while the session marker moves")

        self.bind(refreshToken: "bound-3", deviceId: "01JB8S")
        XCTAssertEqual(self.entitlement.tasksBindingMarker(accountPeerId: self.account), "7a3f8ae4e8a8fd97e4b18c1eaf253ea118f79e5692ff27c47c58980947b6ba56", "a new binding, a new marker")

        self.store.clearSession(accountPeerId: self.account)
        XCTAssertNil(self.entitlement.tasksBindingMarker(accountPeerId: self.account), "logged out")
        XCTAssertEqual(SGEntitlement.tasksBindingMarker(accountId: "01JB8Q", deviceId: "01JB8R"), "db9d4d3a0840e1469ca57393cac93214d2ea89d5f7f159fb3b515649d1ef3d0b")
    }
}

/// The Tasks facade hands its caller's condition to every named call: refused once the account's
/// gate is held, none reaches the origin and each ends like a call cancelled while it waited.
final class SGTasksStillWantedFacadeTests: XCTestCase {
    private let account: Int64 = 69_229_542_146
    private var storeSuite = ""
    private var schedulerSuite = ""
    private var store: SGEntitlementStore!

    override func setUp() {
        super.setUp()
        SGEntitlementPathStubProtocol.reset()
        self.storeSuite = "SGTasksStillWantedFacadeTests.store.\(UUID().uuidString)"
        self.schedulerSuite = "SGTasksStillWantedFacadeTests.scheduler.\(UUID().uuidString)"
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

    func test_theFacadeHandsTheConditionToEveryTasksCall() async throws {
        let entitlement = SGEntitlement(store: self.store, scheduler: SGEntitlementScheduler(defaults: UserDefaults(suiteName: self.schedulerSuite)), isExtensionProcess: false)
        var configuration = SGEntitlementClient.Configuration(baseURL: URL(string: "https://api.tasks-facade.zenlygram.invalid/v1")!)
        configuration.protocolClasses = [SGEntitlementPathStubProtocol.self]
        entitlement.installClientForTesting(SGEntitlementClient(configuration: configuration, store: self.store))
        let seeded = self.store.updateSession(accountPeerId: self.account) { stored in
            stored = SGEntitlementSessionMaterial(refreshToken: "tok-1", entitlement: "jws", accountId: "01JB8Q", deviceId: "01JB8R")
        }
        guard case .success = seeded else {
            return XCTFail("the owned store could not persist the seed: \(seeded)")
        }
        let create = try SGTasksWire.MutationRequest(mutationId: SGTasksWire.UUID("11111111-1111-4111-8111-111111111111")!, operation: .listCreate(SGTasksWire.ListCreate(listId: SGTasksWire.UUID("22222222-2222-4222-8222-222222222222")!, title: "Ishlar", sortOrder: 0, createdAt: nil)))
        let batch = try SGTasksWire.MutationBatchRequest(batchId: SGTasksWire.UUID("99999999-9999-4999-8999-999999999999")!, items: [.init(.mutation(create))])
        let refuse: () -> Bool = { false }
        let mutation = await entitlement.tasksMutation(create, accountPeerId: self.account, stillWanted: refuse)
        let batched = await entitlement.tasksMutationBatch(batch, accountPeerId: self.account, stillWanted: refuse)
        let snapshot = await entitlement.tasksSnapshot(accountPeerId: self.account, cursor: nil, stillWanted: refuse)
        let changes = await entitlement.tasksChanges(accountPeerId: self.account, cursor: SGTasksWire.Cursor("c1")!, stillWanted: refuse)
        let metadata = await entitlement.tasksRealtimeMetadata(accountPeerId: self.account, stillWanted: refuse)
        let authorization = await entitlement.tasksRealtimeAuthorize(accountPeerId: self.account, socketId: SGTasksRealtime.SocketId("123.456")!, stillWanted: refuse)
        let notSent = SGTasksError(kind: .transport(.cancelled), outcomeUnknown: false)
        XCTAssertEqual(mutation.failure, notSent)
        XCTAssertEqual(batched.failure, notSent)
        XCTAssertEqual(snapshot.failure, notSent)
        XCTAssertEqual(changes.failure, notSent)
        XCTAssertEqual(metadata.failure, notSent)
        XCTAssertEqual(authorization.failure, notSent)
        XCTAssertTrue(SGEntitlementPathStubProtocol.recorded.isEmpty, "nothing reached the origin")
        XCTAssertEqual(self.store.session(accountPeerId: self.account).refreshToken, "tok-1", "the session is untouched")
    }
}
#endif
