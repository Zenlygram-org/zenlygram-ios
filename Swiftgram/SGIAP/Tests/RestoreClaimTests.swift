import Foundation

// Zenlygram — the explicit Restore claim as production runs it: `SGIAPRestoreClaim.run` on the real
// `SGIAPDeliveryCoordinator`, with the client, the session store and StoreKit injected. Nothing here
// models the server's rules; the fakes only record what was presented and answer as scripted.

private struct Credential: Equatable {
    let accountPeerId: Int64
    let refreshToken: String
}

private struct ScriptedFailure: Error {
    let kind: SGIAPRestoreClaimFailureKind
}

private struct Attached {
}

/// What the client holds for each account: the refresh token rotates on every refresh, and a
/// logout removes it. Read synchronously, like `SGEntitlement.sessionCredential(accountPeerId:)`.
private final class Sessions: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int64: String] = [:]

    func set(_ accountPeerId: Int64, _ token: String?) {
        self.lock.lock()
        self.tokens[accountPeerId] = token
        self.lock.unlock()
    }

    func credential(_ accountPeerId: Int64) -> Credential? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.tokens[accountPeerId].map { Credential(accountPeerId: accountPeerId, refreshToken: $0) }
    }
}

/// Everything the effects did, in order.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        self.lock.lock()
        self.entries.append(entry)
        self.lock.unlock()
    }

    var all: [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries
    }

    func count(_ prefix: String) -> Int {
        return self.all.filter { $0.hasPrefix(prefix) }.count
    }
}

/// Holds a request until the test opens it, and tells the test when it has arrived.
private actor Gate {
    private var isOpen = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        self.arrivals += 1
        for waiter in self.arrivalWaiters {
            waiter.resume()
        }
        self.arrivalWaiters.removeAll()
        guard !self.isOpen else {
            return
        }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func waitForArrival() async {
        guard self.arrivals == 0 else {
            return
        }
        await withCheckedContinuation { self.arrivalWaiters.append($0) }
    }

    func open() {
        self.isOpen = true
        for waiter in self.waiters {
            waiter.resume()
        }
        self.waiters.removeAll()
    }
}

@main
struct RestoreClaimTests {
    private static let account: Int64 = 2002
    private static let transactionId = "2000000001"

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    /// The production orchestration with fakes behind every effect. `ordinaryAttach` goes through
    /// the coordinator exactly like `ingest` → `deliver`, so a fallback run inside the exclusive
    /// section would hang this test.
    private static func claim(sessions: Sessions, log: Log, coordinator: SGIAPDeliveryCoordinator, gate: Gate? = nil, answer: Result<Attached, ScriptedFailure>) -> SGIAPRestoreClaim<Credential, Attached, ScriptedFailure> {
        let id = self.transactionId
        return SGIAPRestoreClaim<Credential, Attached, ScriptedFailure>(
            currentCredential: {
                sessions.credential(RestoreClaimTests.account)
            },
            send: { credential in
                log.append("claim-sent:\(credential.refreshToken)")
                if let gate {
                    await gate.pass()
                }
                return answer
            },
            classify: { $0.kind },
            accept: { _, credential in
                log.append("accepted:\(credential.refreshToken)")
            },
            reject: { failure, credential, kind in
                log.append("rejected:\(credential.refreshToken):\(kind)")
            },
            ordinaryAttach: {
                _ = await coordinator.deliver(id: id, operation: {
                    log.append("ordinary-attach")
                    return .deferred
                })
            }
        )
    }

    static func main() async {
        // H1. The refresh token rotates while the App Store sheet is up (a refresh after
        // `didBecomeActive`, a `Transaction.updates` refresh). The claim presents the session the
        // account holds WHEN IT IS SENT — never the token read when Restore was pressed, which the
        // server would see as `refresh_reuse` and answer by revoking the whole binding.
        do {
            let sessions = Sessions()
            let log = Log()
            let coordinator = SGIAPDeliveryCoordinator()
            sessions.set(self.account, "rt-at-press")
            sessions.set(self.account, "rt-rotated")
            let outcome = await self.claim(sessions: sessions, log: log, coordinator: coordinator, answer: .success(Attached())).run(transactionId: self.transactionId, deliveries: coordinator)
            check(outcome == .claimed, "a successful claim was not reported as claimed")
            check(log.all == ["claim-sent:rt-rotated", "accepted:rt-rotated"], "the claim did not present the current session: \(log.all)")
            check(!log.all.contains(where: { $0.contains("rt-at-press") }), "the stale press-time refresh token was presented")
            check(SGIAPRestoreClaimSummary(outcomes: [outcome]) == .restored, "every claim succeeded, yet Restore did not report restored")
            print("PASS: the claim presents the session held at send time, not at Restore press")
        }

        // H1 + M2. An ordinary attach of the same transaction is in flight with its own captured
        // account; the claim waits for it, and only then reads the session — which rotated
        // meanwhile.
        do {
            let sessions = Sessions()
            let log = Log()
            let coordinator = SGIAPDeliveryCoordinator()
            let ordinaryGate = Gate()
            sessions.set(self.account, "rt-1")
            let ordinary = Task {
                await coordinator.deliver(id: self.transactionId, operation: {
                    log.append("ordinary-in-flight")
                    await ordinaryGate.pass()
                    return .deferred
                })
            }
            await ordinaryGate.waitForArrival()
            let claim = Task {
                await self.claim(sessions: sessions, log: log, coordinator: coordinator, answer: .success(Attached())).run(transactionId: self.transactionId, deliveries: coordinator)
            }
            while await coordinator.joinedCallers(id: self.transactionId) < 1 {
                await Task.yield()
            }
            check(log.count("claim-sent") == 0, "the claim was sent beside an ordinary attach of the same transaction")
            sessions.set(self.account, "rt-2")
            await ordinaryGate.open()
            check(await ordinary.value == .deferred, "the ordinary attach lost its own outcome")
            check(await claim.value == .claimed, "the claim did not run after the ordinary attach settled")
            check(log.all == ["ordinary-in-flight", "claim-sent:rt-2", "accepted:rt-2"], "order or session wrong: \(log.all)")
            print("PASS: the claim waits for an in-flight ordinary attach and then uses the current session")
        }

        // M2. While the claim is in flight, an ordinary attach of the same transaction (another
        // `Transaction.updates` delivery, a drain on becoming active) is HELD, then runs its own
        // request — it neither runs beside the claim nor is answered from it.
        do {
            let sessions = Sessions()
            let log = Log()
            let coordinator = SGIAPDeliveryCoordinator()
            let claimGate = Gate()
            sessions.set(self.account, "rt-1")
            let claim = Task {
                await self.claim(sessions: sessions, log: log, coordinator: coordinator, gate: claimGate, answer: .success(Attached())).run(transactionId: self.transactionId, deliveries: coordinator)
            }
            await claimGate.waitForArrival()
            let ordinary = Task {
                await coordinator.deliver(id: self.transactionId, operation: {
                    log.append("ordinary-attach")
                    return .needsHelp
                })
            }
            while await coordinator.heldBehindExclusive(id: self.transactionId) < 1 {
                await Task.yield()
            }
            check(log.count("ordinary-attach") == 0, "an ordinary attach started while the claim was in flight")
            await claimGate.open()
            check(await claim.value == .claimed, "the claim failed")
            check(await ordinary.value == .needsHelp, "the held attach was answered from the claim instead of its own request")
            check(log.all == ["claim-sent:rt-1", "accepted:rt-1", "ordinary-attach"], "order wrong: \(log.all)")
            check(await coordinator.heldBehindExclusive(id: self.transactionId) == 0, "a held delivery leaked")
            print("PASS: an ordinary attach arriving during the claim is held, then sends its own request")
        }

        // The session is gone when the claim is due (logged out during the sheet): nothing is sent
        // under any account, the ordinary attach keeps the payment proof, and Restore is NOT success.
        do {
            let sessions = Sessions()
            let log = Log()
            let coordinator = SGIAPDeliveryCoordinator()
            sessions.set(self.account, nil)
            let outcome = await self.claim(sessions: sessions, log: log, coordinator: coordinator, answer: .success(Attached())).run(transactionId: self.transactionId, deliveries: coordinator)
            check(outcome == .noSession, "a missing session was not reported")
            check(log.all == ["ordinary-attach"], "expected only the ordinary attach: \(log.all)")
            check(SGIAPRestoreClaimSummary(outcomes: [outcome]) == .notClaimed(.unavailable), "Restore reported success with no session to claim under")
            print("PASS: no session at send time → no claim, ordinary attach, Restore not reported as success")
        }

        // H2 + M1. Every failure of the claim: never success; the ordinary attach only where a later
        // retry can still succeed — never after a definitive refusal, which would leave a stuck entry
        // ("could not confirm your purchase") for a receipt the server already holds.
        let failures: [(SGIAPRestoreClaimFailureKind, SGIAPRestoreClaimOutcome, Int, SGIAPRestoreClaimShortfall)] = [
            (.retryable, .retryable, 1, .noConnection),
            (.sessionRejected, .sessionRejected, 1, .unavailable),
            (.conflict, .conflict, 0, .needsHelp),
            (.refused, .refused, 0, .needsHelp)
        ]
        for (kind, expected, ordinaryAttaches, shortfall) in failures {
            let sessions = Sessions()
            let log = Log()
            let coordinator = SGIAPDeliveryCoordinator()
            sessions.set(self.account, "rt-1")
            let outcome = await self.claim(sessions: sessions, log: log, coordinator: coordinator, answer: .failure(ScriptedFailure(kind: kind))).run(transactionId: self.transactionId, deliveries: coordinator)
            check(outcome == expected, "\(kind) produced \(outcome)")
            check(log.count("rejected:rt-1:\(kind)") == 1, "\(kind): the failure's consequences were not applied to the session that sent it: \(log.all)")
            check(log.count("accepted") == 0, "\(kind): a failed claim was accepted")
            check(log.count("ordinary-attach") == ordinaryAttaches, "\(kind): expected \(ordinaryAttaches) ordinary attach(es): \(log.all)")
            check(SGIAPRestoreClaimSummary(outcomes: [outcome]) == .notClaimed(shortfall), "\(kind): Restore summary wrong")
            check(SGIAPRestoreClaimSummary(outcomes: [.claimed, outcome]) == .notClaimed(shortfall), "\(kind): one failed claim among successes was reported as restored")
        }
        print("PASS: a failed or offline bound claim never reports Restore success; no fallback after a definitive refusal")

        // The summary's own rules.
        check(SGIAPRestoreClaimSummary(outcomes: []) == .nothingToRestore, "no claims must be nothing to restore")
        check(SGIAPRestoreClaimSummary(outcomes: [.claimed, .claimed]) == .restored, "all claimed must be restored")
        check(SGIAPRestoreClaimSummary(outcomes: [.retryable, .conflict]) == .notClaimed(.needsHelp), "a refusal outranks a transport failure")
        check(SGIAPRestoreClaimSummary(outcomes: [.retryable, .noSession]) == .notClaimed(.unavailable), "a missing session outranks a transport failure")
        print("PASS: Restore summary precedence")
    }
}
