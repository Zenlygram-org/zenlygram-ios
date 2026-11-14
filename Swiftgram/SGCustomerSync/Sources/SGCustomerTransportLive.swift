import Foundation
import SGEntitlement
import SGCustomerSyncCore

/// Zenlygram — the core's transport over `SGEntitlement.shared.customerData(...)` (design 40 §6.5):
/// one call per route under the account's CURRENT session, its result converted into an
/// `SGCustomerRawAnswer` and nothing else. No classification (`SGCustomerWire.classify` is the only
/// classifier), no decoding of a success body, no logging (the core's `call` logs the typed line;
/// `performIfCleared` does exactly what `call` does, once its exchange was sent). Main app only;
/// SGEntitlement answers `.notConfigured` anywhere else.
///
/// An account's calls go one at a time, first come first served, each holding its turn for the
/// whole exchange — the order SGEntitlement's account gate gives them (`SGEntitlementAccountGate`),
/// taken here first. So a sync or events batch that waited behind another call is checked again
/// once its turn is held (`performIfCleared`): a withdrawal, a deletion or an ended link meanwhile
/// sends nothing. Inside SGEntitlement it can still wait in that gate behind a token rotation or a
/// Cloud Tasks attempt, so the same check travels along as `stillWanted` and is asked again there,
/// right before each attempt is signed (`.notWanted`: not sent either).
final class SGCustomerTransportLive: SGCustomerTransport {
    /// The facade call; `stillWanted` is its post-gate re-check (nil: none).
    typealias Exchange = (_ route: SGEntitlementCustomerDataRoute, _ body: Data?, _ accountPeerId: Int64, _ idempotencyKey: String?, _ stillWanted: (() -> Bool)?) async -> Result<Data, SGEntitlement.CustomerDataFailure>

    /// Every call's turn, per account (above).
    let turns = SGCustomerAccountTurns()
    private let customerData: Exchange
    /// The account's clearance now (`SGCustomerDataGate`: the coordinator publishes it first thing on
    /// a withdrawal, a deletion or an ended link).
    private let clearance: (Int64) -> SGCustomerDataGate.Clearance

    /// - Parameters:
    ///   - customerData: the facade call (tests script it).
    ///   - clearance: the account's published clearance (tests set it).
    init(customerData: @escaping Exchange = { route, body, accountPeerId, idempotencyKey, stillWanted in
        return await SGEntitlement.shared.customerData(route, body: body, accountPeerId: accountPeerId, idempotencyKey: idempotencyKey, stillWanted: stillWanted)
    }, clearance: @escaping (Int64) -> SGCustomerDataGate.Clearance = { accountPeerId in
        return SGCustomerDataGate.shared.clearance(accountPeerId: accountPeerId)
    }) {
        self.customerData = customerData
        self.clearance = clearance
    }

    func consents(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        return await self.exchange(.profileConsents, body: body, accountPeerId: accountPeerId, idempotencyKey: nil)
    }

    func sync(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        return await self.exchange(.profileSync, body: body, accountPeerId: accountPeerId, idempotencyKey: nil)
    }

    func me(accountPeerId: Int64) async -> SGCustomerRawAnswer {
        return await self.exchange(.profileMe, body: nil, accountPeerId: accountPeerId, idempotencyKey: nil)
    }

    func events(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        return await self.exchange(.profileEvents, body: body, accountPeerId: accountPeerId, idempotencyKey: nil)
    }

    func delete(body: Data, idempotencyKey: String, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        return await self.exchange(.accountDelete, body: body, accountPeerId: accountPeerId, idempotencyKey: idempotencyKey)
    }

    /// `call` (classify + the typed log line) in the account's turn, and for a failed consents, sync
    /// or events call the aggregated `error.occurred` input of design 40 §10.2 (`consent_upload`,
    /// `profile_sync`, `events_upload`; `SGCustomerCoordinatorCore.callError`) for the account it ran
    /// for.
    func perform(_ request: SGCustomerRequest, accountPeerId: Int64) async -> (outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer) {
        await self.turns.acquire(accountPeerId: accountPeerId)
        defer {
            self.turns.release(accountPeerId: accountPeerId)
        }
        return await self.performHoldingTurn(request, accountPeerId: accountPeerId)
    }

    /// `perform`, for the coordinator's calls: nil when, once the account's turn is held, its CURRENT
    /// clearance no longer covers the route (`SGCustomerCoordinatorCore.clearanceToSend`), or no
    /// longer did when SGEntitlement's account gate let the call through (`.notWanted`) — nothing
    /// was sent (`.notSent`).
    func performIfCleared(_ request: SGCustomerRequest, accountPeerId: Int64) async -> (outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer)? {
        await self.turns.acquire(accountPeerId: accountPeerId)
        defer {
            self.turns.release(accountPeerId: accountPeerId)
        }
        let clearance = self.clearance
        let needed = SGCustomerCoordinatorCore.clearanceToSend(request.route)
        let isCleared = {
            return clearance(accountPeerId).isSuperset(of: needed)
        }
        guard isCleared() else {
            return nil
        }
        let parts = SGCustomerTransportLive.exchangeParts(request)
        let result = await self.customerData(parts.route, parts.body, accountPeerId, parts.idempotencyKey, isCleared)
        if case .failure(.notWanted) = result {
            return nil
        }
        // What the core's `call` does with an answer (`SGCustomerTransport.call`): classified by
        // `SGCustomerWire.classify`, then its typed log line.
        let answer = SGCustomerTransportLive.rawAnswer(result)
        let outcome = SGCustomerWire.classify(answer)
        SGCustomerWire.log(outcome, answer: answer, route: request.route)
        self.reportError(request.route, outcome: outcome, answer: answer, accountPeerId: accountPeerId)
        return (outcome, answer)
    }

    private func performHoldingTurn(_ request: SGCustomerRequest, accountPeerId: Int64) async -> (outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer) {
        let result = await self.call(request, accountPeerId: accountPeerId)
        self.reportError(request.route, outcome: result.outcome, answer: result.answer, accountPeerId: accountPeerId)
        return result
    }

    private func reportError(_ route: SGCustomerRoute, outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer, accountPeerId: Int64) {
        if case let .error(domain, code)? = SGCustomerCoordinatorCore.callError(route: route, outcome: outcome, answer: answer) {
            SGAnalytics.error(domain, code, accountPeerId: accountPeerId)
        }
    }

    private func exchange(_ route: SGEntitlementCustomerDataRoute, body: Data?, accountPeerId: Int64, idempotencyKey: String?) async -> SGCustomerRawAnswer {
        let result = await self.customerData(route, body, accountPeerId, idempotencyKey, nil)
        return SGCustomerTransportLive.rawAnswer(result)
    }

    /// What `SGCustomerTransport.send` sends for `request` through the route methods above: the
    /// facade's route, the exact body (none for `me`) and, for `delete` only, the `Idempotency-Key`.
    static func exchangeParts(_ request: SGCustomerRequest) -> (route: SGEntitlementCustomerDataRoute, body: Data?, idempotencyKey: String?) {
        let body = request.body ?? Data()
        switch request.route {
        case .consents:
            return (.profileConsents, body, nil)
        case .sync:
            return (.profileSync, body, nil)
        case .me:
            return (.profileMe, nil, nil)
        case .events:
            return (.profileEvents, body, nil)
        case .delete:
            return (.accountDelete, body, request.idempotencyKey ?? "")
        }
    }

    /// The facade's result as the core reads it: a 2xx body; an error answer with its status, code,
    /// reason, body (≤ 16 KiB) and `Retry-After`; or, when no answer arrived, why nothing did.
    static func rawAnswer(_ result: Result<Data, SGEntitlement.CustomerDataFailure>) -> SGCustomerRawAnswer {
        switch result {
        case let .success(body):
            return SGCustomerRawAnswer(transport: .ok, status: 200, body: body)
        case .failure(.notConfigured):
            return SGCustomerRawAnswer(transport: .notConfigured)
        case .failure(.notLinked):
            return SGCustomerRawAnswer(transport: .notLinked)
        case .failure(.credentialChanged):
            return SGCustomerRawAnswer(transport: .credentialChanged)
        case .failure(.notWanted):
            // Nothing was signed or sent. `performIfCleared`, the only caller with a re-check,
            // reports it as not sent before it gets here.
            return SGCustomerRawAnswer(transport: .notConfigured)
        case let .failure(.request(error)):
            if let status = error.status {
                return SGCustomerRawAnswer(transport: .ok, status: status, code: error.code, reason: error.reason, body: error.responseBody ?? Data(), retryAfter: error.retryAfter.map { TimeInterval($0) })
            }
            switch error.failure {
            case .offline(.timeout):
                return SGCustomerRawAnswer(transport: .timeout)
            case .offline:
                return SGCustomerRawAnswer(transport: .offline)
            case .rateLimited, .session, .refused, .unknownRefusal:
                // No answer was received: a local refusal sent nothing.
                return SGCustomerRawAnswer(transport: .notConfigured)
            }
        }
    }
}

/// Zenlygram — one customer-data exchange per account at a time, waiters served first in, first
/// out, the holder keeping its turn for the whole exchange (`SGCustomerTransportLive`). A copy of
/// SGEntitlement's internal `SGEntitlementAccountGate`, which this module cannot reach; holding this
/// turn while that gate is awaited inside the exchange cannot deadlock, as nothing that holds the
/// gate ever waits here. Different accounts never wait for each other. `acquire` suspends instead of
/// blocking; the lock is only taken in synchronous code.
final class SGCustomerAccountTurns: @unchecked Sendable {
    private let lock = NSLock()
    private var holders = Set<Int64>()
    private var waiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(accountPeerId: Int64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.enqueueOrTake(accountPeerId: accountPeerId, continuation: continuation) {
                continuation.resume()
            }
        }
    }

    /// Hands the turn to the account's next waiter, or frees it.
    func release(accountPeerId: Int64) {
        self.lock.lock()
        guard var queue = self.waiters[accountPeerId], !queue.isEmpty else {
            self.waiters[accountPeerId] = nil
            self.holders.remove(accountPeerId)
            self.lock.unlock()
            return
        }
        let next = queue.removeFirst()
        self.waiters[accountPeerId] = queue.isEmpty ? nil : queue
        self.lock.unlock()
        // The account stays held: nobody slips in between.
        next.resume()
    }

    /// Tests: how many calls of the account wait for their turn.
    func waiting(accountPeerId: Int64) -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.waiters[accountPeerId]?.count ?? 0
    }

    /// True when the caller took the free turn; false when it was queued.
    private func enqueueOrTake(accountPeerId: Int64, continuation: CheckedContinuation<Void, Never>) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.holders.contains(accountPeerId) {
            self.waiters[accountPeerId, default: []].append(continuation)
            return false
        }
        self.holders.insert(accountPeerId)
        return true
    }
}

/// Zenlygram — hands what a task produced (an answer, an outcome and the closure that takes it) to
/// the main queue. The pair is immutable once boxed and only read there, which is what makes the
/// unchecked `Sendable` true; the core's value types stay as they are.
enum SGMainQueue {
    private final class Delivery<Value>: @unchecked Sendable {
        let value: Value
        let body: (Value) -> Void

        init(value: Value, body: @escaping (Value) -> Void) {
            self.value = value
            self.body = body
        }
    }

    static func deliver<Value>(_ value: Value, to body: @escaping (Value) -> Void) {
        let delivery = Delivery(value: value, body: body)
        DispatchQueue.main.async {
            delivery.body(delivery.value)
        }
    }
}
