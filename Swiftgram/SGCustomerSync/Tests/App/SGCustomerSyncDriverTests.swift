// App-side only (see SGCustomerSyncConfigTests.swift): compiles to nothing in `run-core-tests.sh`.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
import SGEntitlement
@testable import SGCustomerSync
@testable import SGCustomerSyncCore

/// Zenlygram — the driver's second safeguards behind the reducer (design 40 §6.5, §9.3; contract §6.7): an
/// account's calls go one at a time, and a sync or events batch that waited its turn — here, or inside
/// SGEntitlement's account gate — sends nothing once the account is no longer cleared for it
/// (`SGCustomerTransportLive.performIfCleared`); a cleared receipt forgets the snapshot in flight
/// (`SGCustomerSyncReceipts`). The facade is scripted: nothing reaches SGEntitlement or the network.
final class SGCustomerSyncDriverTests: XCTestCase {
    private let account: Int64 = 555_000_111
    private let otherAccount: Int64 = 555_000_222
    private let full: SGCustomerDataGate.Clearance = [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync]
    private let stored = Data(#"{"schema_version":1,"ingest":"stored"}"#.utf8)
    private let body = Data(#"{"schema_version":1}"#.utf8)

    // MARK: - A call that waited its turn

    func test_aSyncThatWaitedItsTurnSendsNothingOnceTheAccountIsNoLongerCleared() async throws {
        let gate = SGCustomerTestClearance(self.full)
        let server = SGCustomerTestServer(holding: 1, answer: self.stored)
        let transport = SGCustomerTransportLive(customerData: server.exchange, clearance: gate.read)
        let account = self.account
        let body = self.body
        let stored = self.stored
        // An events batch holds the account's turn: its answer is slow.
        let events = Task { () -> Bool? in
            return await transport.performIfCleared(.events(body), accountPeerId: account).map { $0.outcome == .ok(stored) }
        }
        try await self.waitUntil { server.routes.count == 1 }
        // The sync planned meanwhile waits behind it.
        let sync = Task { () -> Bool? in
            return await transport.performIfCleared(.sync(body), accountPeerId: account).map { $0.outcome == .ok(stored) }
        }
        try await self.waitUntil { transport.turns.waiting(accountPeerId: account) == 1 }
        // The user withdraws: the coordinator publishes `[]` first thing.
        gate.set([])
        server.release()
        let eventsAnswered = await events.value
        let syncAnswered = await sync.value
        XCTAssertEqual(eventsAnswered, true, "the batch already sent is answered as usual")
        XCTAssertNil(syncAnswered, "nothing sent: no receipt, no failure (`.notSent`)")
        XCTAssertEqual(server.routes, [.profileEvents], "the sync never reached SGEntitlement")
    }

    func test_aCallThatWaitedItsTurnGoesWhileTheAccountIsStillCleared() async throws {
        let gate = SGCustomerTestClearance(self.full)
        let server = SGCustomerTestServer(holding: 1, answer: self.stored)
        let transport = SGCustomerTransportLive(customerData: server.exchange, clearance: gate.read)
        let account = self.account
        let otherAccount = self.otherAccount
        let body = self.body
        let stored = self.stored
        let sync = Task { () -> Bool? in
            return await transport.performIfCleared(.sync(body), accountPeerId: account).map { $0.outcome == .ok(stored) }
        }
        try await self.waitUntil { server.routes.count == 1 }
        let events = Task { () -> Bool? in
            return await transport.performIfCleared(.events(body), accountPeerId: account).map { $0.outcome == .ok(stored) }
        }
        try await self.waitUntil { transport.turns.waiting(accountPeerId: account) == 1 }
        // Another account never waits for this one.
        let other = await transport.performIfCleared(.sync(body), accountPeerId: otherAccount)
        XCTAssertEqual(other?.outcome, .ok(stored))
        XCTAssertEqual(server.routes, [.profileSync, .profileSync], "the other account's sync went at once")
        server.release()
        let syncAnswered = await sync.value
        let eventsAnswered = await events.value
        XCTAssertEqual(syncAnswered, true)
        XCTAssertEqual(eventsAnswered, true, "still cleared: sent in its turn")
        XCTAssertEqual(server.routes, [.profileSync, .profileSync, .profileEvents], "one at a time, in order")
        XCTAssertEqual(transport.turns.waiting(accountPeerId: account), 0)
    }

    func test_onlySyncAndEventsNeedAClearanceToBeSent() async {
        let gate = SGCustomerTestClearance([])
        let server = SGCustomerTestServer(holding: 0, answer: self.stored)
        let transport = SGCustomerTransportLive(customerData: server.exchange, clearance: gate.read)
        let syncWithoutClearance = await transport.performIfCleared(.sync(self.body), accountPeerId: self.account)
        let eventsWithoutClearance = await transport.performIfCleared(.events(self.body), accountPeerId: self.account)
        XCTAssertNil(syncWithoutClearance)
        XCTAssertNil(eventsWithoutClearance)
        XCTAssertEqual(server.routes, [], "nothing sent")
        // The withdraw (consents), My data and the deletion go in every consent state.
        let withdraw = await transport.performIfCleared(.consents(self.body), accountPeerId: self.account)
        let delete = await transport.performIfCleared(.delete(idempotencyKey: "7c9e6679-7425-40de-944b-e07fc1f90ae7"), accountPeerId: self.account)
        let me = await transport.perform(.me, accountPeerId: self.account)
        XCTAssertNotNil(withdraw)
        XCTAssertNotNil(delete)
        XCTAssertEqual(me.outcome, .ok(self.stored))
        XCTAssertEqual(server.routes, [.profileConsents, .accountDelete, .profileMe])
        // Linked and its grant acked, the profile not synced yet: the sync goes, events wait for its receipt.
        gate.set([.recordEvents, .uploadProfile])
        let sync = await transport.performIfCleared(.sync(self.body), accountPeerId: self.account)
        let events = await transport.performIfCleared(.events(self.body), accountPeerId: self.account)
        XCTAssertNotNil(sync)
        XCTAssertNil(events)
        XCTAssertEqual(server.routes, [.profileConsents, .accountDelete, .profileMe, .profileSync])
    }

    // MARK: - A call that waited in SGEntitlement's account gate

    /// Its turn here is held, but inside SGEntitlement the call still waits in the account's gate behind a
    /// token rotation or a Cloud Tasks attempt, and the user withdraws meanwhile. The clearance check went
    /// along (`stillWanted`) and is asked again there: nothing is sent, and the call reports not sent, as one
    /// that waited its turn here does.
    func test_aSyncOrEventsBatchThatWaitedInSGEntitlementsGateSendsNothingOnceTheAccountIsNoLongerCleared() async throws {
        for request in [SGCustomerRequest.sync(self.body), .events(self.body)] {
            let gate = SGCustomerTestClearance(self.full)
            let server = SGCustomerTestServer(holding: 0, answer: self.stored, gateHolds: 1)
            let transport = SGCustomerTransportLive(customerData: server.exchange, clearance: gate.read)
            let account = self.account
            let call = Task { () -> Bool in
                return await transport.performIfCleared(request, accountPeerId: account) != nil
            }
            try await self.waitUntil { server.waitingInGate == 1 }
            XCTAssertEqual(server.arrivals.map(\.checked), [true], "\(request.route): the clearance check went along")
            // The user withdraws: the coordinator publishes `[]` first thing.
            gate.set([])
            server.openGate()
            let sent = await call.value
            XCTAssertFalse(sent, "\(request.route): nothing sent, no receipt, no failure (`.notSent`)")
            XCTAssertEqual(server.routes, [], "\(request.route): nothing went past SGEntitlement's gate")
            XCTAssertEqual(server.notWanted.count, 1, "\(request.route)")
            XCTAssertEqual(transport.turns.waiting(accountPeerId: account), 0, "\(request.route)")
        }
    }

    func test_aCallThatWaitedInSGEntitlementsGateGoesWhileTheAccountIsStillCleared() async throws {
        let gate = SGCustomerTestClearance(self.full)
        let server = SGCustomerTestServer(holding: 0, answer: self.stored, gateHolds: 1)
        let transport = SGCustomerTransportLive(customerData: server.exchange, clearance: gate.read)
        let account = self.account
        let body = self.body
        let stored = self.stored
        let sync = Task { () -> Bool? in
            return await transport.performIfCleared(.sync(body), accountPeerId: account).map { $0.outcome == .ok(stored) }
        }
        try await self.waitUntil { server.waitingInGate == 1 }
        // The clearance changed, but still covers the sync.
        gate.set([.recordEvents, .uploadProfile])
        server.openGate()
        let answered = await sync.value
        XCTAssertEqual(answered, true, "still cleared: sent and answered as usual")
        XCTAssertEqual(server.routes, [.profileSync])
        XCTAssertEqual(server.notWanted, [])
    }

    /// The re-check travels only with the coordinator's calls (`performIfCleared`), which send exactly what
    /// the core's `call` sends through the route methods: the same route, body and key.
    func test_theCheckedPathSendsWhatTheCorePathSends() async {
        let gate = SGCustomerTestClearance(self.full)
        let core = SGCustomerTestServer(holding: 0, answer: self.stored)
        let checked = SGCustomerTestServer(holding: 0, answer: self.stored)
        let viaCore = SGCustomerTransportLive(customerData: core.exchange, clearance: gate.read)
        let viaCheck = SGCustomerTransportLive(customerData: checked.exchange, clearance: gate.read)
        let key = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        let events = Data(#"{"schema_version":1,"events":[]}"#.utf8)
        let requests: [SGCustomerRequest] = [.consents(Data(#"{"schema_version":1,"consents":[]}"#.utf8)), .sync(self.body), .me, .events(events), .delete(idempotencyKey: key)]
        for request in requests {
            _ = await viaCore.perform(request, accountPeerId: self.account)
            _ = await viaCheck.performIfCleared(request, accountPeerId: self.account)
        }
        XCTAssertEqual(core.arrivals.map(\.checked), [false, false, false, false, false], "`perform` carries no re-check")
        XCTAssertEqual(checked.arrivals.map(\.checked), [true, true, true, true, true])
        let sentByCheck = checked.arrivals.map { SGCustomerTestServer.Arrival(route: $0.route, body: $0.body, idempotencyKey: $0.idempotencyKey, checked: false) }
        XCTAssertEqual(sentByCheck, core.arrivals, "the same route, body and key")
        XCTAssertEqual(core.routes, [.profileConsents, .profileSync, .profileMe, .profileEvents, .accountDelete])
        XCTAssertNil(core.arrivals[2].body, "me carries no body")
        XCTAssertEqual(core.arrivals[4].idempotencyKey, key, "only the delete carries its key")
        XCTAssertEqual(core.arrivals.compactMap(\.idempotencyKey), [key])
    }

    // MARK: - The receipt of a sync in flight

    func test_aClearedReceiptForgetsTheSnapshotInFlight() {
        var written: [String] = []
        var cleared: [Int64] = []
        let receipts = SGCustomerSyncReceipts(record: { _, _, digest, _ in
            written.append(digest)
        }, clear: { accountPeerId in
            cleared.append(accountPeerId)
        })
        let credential = SGEntitlementSessionCredential(accountPeerId: self.account, refreshToken: "test-refresh-token")
        let now = Date(timeIntervalSince1970: 1_793_527_200)
        receipts.willSend(account: self.account, digest: "digest-1", credential: credential)
        // The user withdraws while the sync is in flight (`.clearReceipt`), then a late `.recordSyncReceipt`.
        receipts.clear(account: self.account)
        receipts.record(account: self.account, at: now)
        XCTAssertEqual(cleared, [self.account])
        XCTAssertEqual(written, [], "it went under the grant just withdrawn: nothing is recorded")

        receipts.willSend(account: self.account, digest: "digest-2", credential: credential)
        receipts.record(account: self.account, at: now)
        receipts.record(account: self.account, at: now)
        XCTAssertEqual(written, ["digest-2"], "a delivered snapshot is recorded once")

        receipts.willSend(account: self.account, digest: "digest-3", credential: credential)
        receipts.forget(account: self.account)
        receipts.record(account: self.account, at: now)
        XCTAssertEqual(written, ["digest-2"], "a snapshot that was not sent is never recorded")
        receipts.willSend(account: self.account, digest: "digest-4", credential: nil)
        receipts.record(account: self.account, at: now)
        XCTAssertEqual(written, ["digest-2"], "no session to record it under")
    }

    // MARK: - Helpers

    private struct TimedOut: Error {}

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

/// The clearance the coordinator published (`SGCustomerDataGate`), set by the test.
private final class SGCustomerTestClearance: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SGCustomerDataGate.Clearance

    init(_ value: SGCustomerDataGate.Clearance) {
        self.value = value
    }

    func set(_ value: SGCustomerDataGate.Clearance) {
        self.lock.lock()
        self.value = value
        self.lock.unlock()
    }

    func read(_ accountPeerId: Int64) -> SGCustomerDataGate.Clearance {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.value
    }
}

/// SGEntitlement's customer-data facade, scripted: it records every route asked of it, holds the first
/// `holding` exchanges until `release()` and answers each with `answer`. The first `gateHolds` exchanges
/// first wait in the account's gate — a token rotation or a Cloud Tasks attempt holds it — until
/// `openGate()`; then, as the facade does, an exchange goes only while its `stillWanted` holds, else it
/// answers `.notWanted` with nothing sent.
private final class SGCustomerTestServer: @unchecked Sendable {
    /// What reached the facade: the route, the exact body and key, and whether a re-check came along.
    struct Arrival: Equatable {
        let route: SGEntitlementCustomerDataRoute
        let body: Data?
        let idempotencyKey: String?
        let checked: Bool
    }

    private let lock = NSLock()
    private let answer: Data
    private var sent: [SGEntitlementCustomerDataRoute] = []
    private var arrived: [Arrival] = []
    private var refused: [SGEntitlementCustomerDataRoute] = []
    private var toHold: Int
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var gateHolds: Int
    private var inGate: [CheckedContinuation<Void, Never>] = []
    private var gateOpen = false

    init(holding: Int, answer: Data, gateHolds: Int = 0) {
        self.toHold = holding
        self.answer = answer
        self.gateHolds = gateHolds
    }

    /// The routes sent: past the gate and still wanted.
    var routes: [SGEntitlementCustomerDataRoute] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sent
    }

    var arrivals: [Arrival] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.arrived
    }

    /// The routes refused once their turn came (`.notWanted`).
    var notWanted: [SGEntitlementCustomerDataRoute] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.refused
    }

    var waitingInGate: Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.inGate.count
    }

    func exchange(_ route: SGEntitlementCustomerDataRoute, _ body: Data?, _ accountPeerId: Int64, _ idempotencyKey: String?, _ stillWanted: (() -> Bool)?) async -> Result<Data, SGEntitlement.CustomerDataFailure> {
        if self.arrive(Arrival(route: route, body: body, idempotencyKey: idempotencyKey, checked: stillWanted != nil)) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                let resumeNow = self.gateOpen
                if !resumeNow {
                    self.inGate.append(continuation)
                }
                self.lock.unlock()
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        if let stillWanted, !stillWanted() {
            self.refuse(route)
            return .failure(.notWanted)
        }
        if self.receive(route) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                let resumeNow = self.released
                if !resumeNow {
                    self.held.append(continuation)
                }
                self.lock.unlock()
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        return .success(self.answer)
    }

    /// Records the arrival; true when it waits in the gate. The lock is only taken in synchronous code.
    private func arrive(_ arrival: Arrival) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.arrived.append(arrival)
        let wait = self.gateHolds > 0 && !self.gateOpen
        if wait {
            self.gateHolds -= 1
        }
        return wait
    }

    private func refuse(_ route: SGEntitlementCustomerDataRoute) {
        self.lock.lock()
        self.refused.append(route)
        self.lock.unlock()
    }

    /// The rotation or the Tasks attempt ends: every exchange waiting in the gate goes on.
    func openGate() {
        self.lock.lock()
        self.gateOpen = true
        let waiting = self.inGate
        self.inGate = []
        self.lock.unlock()
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// Records `route`; true when its exchange is held. The lock is only taken in synchronous code.
    private func receive(_ route: SGEntitlementCustomerDataRoute) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.sent.append(route)
        let hold = self.toHold > 0 && !self.released
        if hold {
            self.toHold -= 1
        }
        return hold
    }

    func release() {
        self.lock.lock()
        self.released = true
        let waiting = self.held
        self.held = []
        self.lock.unlock()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
#endif
