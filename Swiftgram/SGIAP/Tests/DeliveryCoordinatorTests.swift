import Foundation

private actor ControlledAttach {
    private var calls = 0
    private var wasCancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<SGIAPAttachOutcome, Never>?

    func run() async -> SGIAPAttachOutcome {
        self.calls += 1
        self.wasCancelled = Task.isCancelled
        for waiter in self.startWaiters {
            waiter.resume()
        }
        self.startWaiters.removeAll()
        return await withCheckedContinuation { self.completion = $0 }
    }

    func waitUntilStarted() async {
        guard self.calls == 0 else { return }
        await withCheckedContinuation { self.startWaiters.append($0) }
    }

    func complete(_ outcome: SGIAPAttachOutcome) {
        self.completion?.resume(returning: outcome)
        self.completion = nil
    }

    func state() -> (calls: Int, wasCancelled: Bool) {
        return (self.calls, self.wasCancelled)
    }
}

/// Drain passes that each block until the test releases them, in order.
private actor ControlledPasses {
    private var started = 0
    private var completed = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func run() async {
        self.started += 1
        let ready = self.startWaiters.filter { $0.0 <= self.started }
        self.startWaiters.removeAll(where: { $0.0 <= self.started })
        for waiter in ready {
            waiter.1.resume()
        }
        await withCheckedContinuation { self.releases.append($0) }
        self.completed += 1
    }

    func waitUntilStarted(_ count: Int) async {
        guard self.started < count else { return }
        await withCheckedContinuation { self.startWaiters.append((count, $0)) }
    }

    func release() {
        guard !self.releases.isEmpty else { return }
        self.releases.removeFirst().resume()
    }

    func startedCount() -> Int { self.started }
    func completedCount() -> Int { self.completed }
}

private actor Counter {
    var value = 0
    func increment() { self.value += 1 }
}

@main
struct DeliveryCoordinatorTests {
    private static func check(_ condition: Bool, _ message: String = "Assertion failed") {
        precondition(condition, message)
    }

    static func main() async {
        // Fail deterministically instead of hanging forever if a continuation regression stalls.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !Task.isCancelled {
                fatalError("StoreKit delivery regression tests timed out")
            }
        }
        defer { watchdog.cancel() }

        let coordinator = SGIAPDeliveryCoordinator()
        let attach = ControlledAttach()
        let deliveries = (0..<100).map { _ in
            Task {
                await coordinator.deliver(id: "same-payment", operation: { await attach.run() })
            }
        }
        await attach.waitUntilStarted()

        // One slow server request must not block a different payment.
        let independent = await coordinator.deliver(id: "other-payment", operation: { .attached })
        check(independent == .attached)
        await attach.complete(.attached)
        for delivery in deliveries {
            check(await delivery.value == .attached)
        }
        let firstState = await attach.state()
        check(firstState.calls == 1, "Duplicate deliveries issued multiple server requests")

        let unexpected = Counter()
        let duplicate = await coordinator.deliver(id: "same-payment", operation: {
            await unexpected.increment()
            return .deferred
        })
        check(duplicate == .attached)
        check(await unexpected.value == 0, "Completed payment was attached again before StoreKit finish")

        // Failures are not permanently cached: backoff and manual recovery remain the outbox's job.
        let attempts = Counter()
        let failure = await coordinator.deliver(id: "retryable", operation: {
            await attempts.increment()
            return .deferred
        })
        check(failure == .deferred)
        let retry = await coordinator.deliver(id: "retryable", operation: {
            await attempts.increment()
            return .attached
        })
        check(retry == .attached)
        check(await attempts.value == 2)
        let stuck = await coordinator.deliver(id: "manual-recovery", operation: { .needsHelp })
        check(stuck == .needsHelp)
        let recovered = await coordinator.deliver(id: "manual-recovery", operation: { .attached })
        check(recovered == .attached)

        // Closing the first caller must not cancel delivery owed to another caller.
        let cancellableAttach = ControlledAttach()
        let caller = Task {
            await coordinator.deliver(id: "closed-paywall", operation: { await cancellableAttach.run() })
        }
        await cancellableAttach.waitUntilStarted()
        caller.cancel()
        let secondCaller = Task {
            await coordinator.deliver(id: "closed-paywall", operation: { .deferred })
        }
        // Barrier: only complete once the second caller has actually joined, or it could arrive
        // after completion, be answered by the memo, and prove nothing about coalescing.
        while await coordinator.joinedCallers(id: "closed-paywall") < 1 {
            await Task.yield()
        }
        await cancellableAttach.complete(.attached)
        check(await caller.value == .attached)
        check(await secondCaller.value == .attached)
        let cancellationState = await cancellableAttach.state()
        check(cancellationState.calls == 1 && !cancellationState.wasCancelled)
        print("PASS: delivery coalescing, independent payments, retry, manual recovery, caller cancellation")

        // Restore Purchases is the user's explicit re-attach (e.g. bought unbound, then linked
        // Telegram in the same session). It must reach the server again for a transaction this
        // process already delivered, instead of being answered from the duplicate memo.
        let restoreCoordinator = SGIAPDeliveryCoordinator()
        let restoreAttempts = Counter()
        let firstAttach = await restoreCoordinator.deliver(id: "bought-unbound", operation: {
            await restoreAttempts.increment()
            return .attached
        })
        check(firstAttach == .attached)
        await restoreCoordinator.forgetDeliveries()
        let restoredAttach = await restoreCoordinator.deliver(id: "bought-unbound", operation: {
            await restoreAttempts.increment()
            return .attached
        })
        check(restoredAttach == .attached)
        check(await restoreAttempts.value == 2, "Restore was answered from memory without re-attaching")

        // Forgetting completed deliveries must not break coalescing of one still in flight: the same
        // Idempotency-Key is never sent twice concurrently.
        let inFlightAttach = ControlledAttach()
        let inFlight = Task {
            await restoreCoordinator.deliver(id: "in-flight", operation: { await inFlightAttach.run() })
        }
        await inFlightAttach.waitUntilStarted()
        await restoreCoordinator.forgetDeliveries()
        let concurrentAttempts = Counter()
        let joined = Task {
            await restoreCoordinator.deliver(id: "in-flight", operation: {
                await concurrentAttempts.increment()
                return .needsHelp
            })
        }
        // Deterministic: the joiner is suspended on the in-flight attach BEFORE it completes. If
        // `forgetDeliveries` had dropped `pending`, the joiner would have started its own attach
        // (attempts 1, `.needsHelp`) and never registered as joined — the watchdog then fails.
        while await restoreCoordinator.joinedCallers(id: "in-flight") < 1 {
            await Task.yield()
        }
        await inFlightAttach.complete(.attached)
        check(await inFlight.value == .attached)
        check(await joined.value == .attached, "Joiner did not receive the in-flight attach's own outcome")
        check(await concurrentAttempts.value == 0, "Restore duplicated an attach that was still in flight")
        check((await inFlightAttach.state()).calls == 1)
        check(await restoreCoordinator.joinedCallers(id: "in-flight") == 0)
        print("PASS: restore re-attaches delivered payments, in-flight attach still coalesced")

        // An explicit Restore claim (`exclusive`) runs only AFTER an ordinary attach of the same
        // transaction has settled, and waiting for it neither starts nor re-attributes a delivery.
        let settleCoordinator = SGIAPDeliveryCoordinator()
        let ordinaryAttach = ControlledAttach()
        let ordinary = Task {
            await settleCoordinator.deliver(id: "settle", operation: { await ordinaryAttach.run() })
        }
        await ordinaryAttach.waitUntilStarted()
        let settled = Task { () -> Int in
            await settleCoordinator.exclusive(id: "settle", operation: {
                return (await ordinaryAttach.state()).calls
            })
        }
        while await settleCoordinator.joinedCallers(id: "settle") < 1 {
            await Task.yield()
        }
        await ordinaryAttach.complete(.deferred)
        check(await settled.value == 1, "the claim ran before the ordinary attach settled, or started its own attach")
        check(await ordinary.value == .deferred)
        // Nothing pending: the claim runs at once, and does not consult or create the memo.
        _ = await settleCoordinator.exclusive(id: "nothing-in-flight", operation: { 0 })
        let afterSettle = Counter()
        check(await settleCoordinator.deliver(id: "nothing-in-flight", operation: {
            await afterSettle.increment()
            return .attached
        }) == .attached)
        check(await afterSettle.value == 1)
        print("PASS: explicit restore waits for an in-flight ordinary attach without joining its intent")

        // A drain requested while another drain is running (Restore right after clearing the stuck
        // flags) must not return until a pass that began after its request has finished: Restore
        // reports and refreshes the snapshot only after the entries it made retryable were tried.
        let runner = SGIAPDrainRunner()
        let passes = ControlledPasses()
        let firstDrain = Task {
            await runner.drain({ await passes.run() })
        }
        await passes.waitUntilStarted(1)
        let secondDrain = Task { () -> Int in
            await runner.drain({ await passes.run() })
            return await passes.completedCount()
        }
        while await runner.waitingCallers() < 1 {
            await Task.yield()
        }
        await passes.release()
        await passes.waitUntilStarted(2)
        check(await passes.completedCount() == 1)
        await passes.release()
        check(await secondDrain.value == 2, "A waiting drain caller returned before its own pass ran")
        await firstDrain.value
        check(await passes.startedCount() == 2, "Concurrent drain requests did not coalesce into one rerun")
        check(await runner.waitingCallers() == 0)
        let idleDrain = Task {
            await runner.drain({ await passes.run() })
        }
        await passes.waitUntilStarted(3)
        await passes.release()
        await idleDrain.value
        check(await passes.startedCount() == 3, "An idle drain reran without a request")
        print("PASS: a drain requested during a drain waits for its own pass, requests coalesce")

        var gate = SGIAPDrainGate()
        check(gate.begin())
        check(!gate.begin(), "Two drains ran concurrently")
        check(!gate.begin())
        check(gate.finishPass(), "A drain requested during a running drain was dropped")
        check(!gate.finishPass(), "Several requests during one pass must coalesce into one rerun")
        check(gate.begin(), "Drain gate stayed closed after the drain finished")
        check(!gate.finishPass(), "A pass with no concurrent request reran")
        check(gate.begin())
        print("PASS: drain requests during a running drain coalesce into one rerun")

        var snapshots = SGIAPSnapshotRefreshState()
        check(snapshots.preservesPreviousOnEmpty)
        let firstRefresh = snapshots.beginRefresh()
        let newerRefresh = snapshots.beginRefresh()
        check(!snapshots.completeRefresh(firstRefresh), "Old enumeration overwrote newer snapshot")
        check(snapshots.completeRefresh(newerRefresh))

        let beforeRefund = snapshots.beginRefresh()
        snapshots.recordRevocation(transactionId: 42)
        check(!snapshots.preservesPreviousOnEmpty, "Refund kept the old offline subscription")
        check(!snapshots.completeRefresh(beforeRefund), "Pre-refund enumeration restored refunded access")
        check(!snapshots.preservesPreviousOnEmpty, "Stale completion consumed refund invalidation")
        check(snapshots.isRevoked(transactionId: 42))
        check(!snapshots.isRevoked(transactionId: 43), "Refund invalidated another subscription")

        let afterRefund = snapshots.beginRefresh()
        check(!snapshots.preservesPreviousOnEmpty)
        check(snapshots.completeRefresh(afterRefund))
        check(snapshots.preservesPreviousOnEmpty, "Successful refresh permanently disabled offline allowance")
        check(snapshots.isRevoked(transactionId: 42), "Old transaction could grant again from stale StoreKit cache")

        // A refund for an older period cannot have supplied a snapshot with a later maximum expiry.
        let oldExpiry = Date(timeIntervalSince1970: 100)
        let newExpiry = Date(timeIntervalSince1970: 200)
        var newerSubscription = SGIAPSnapshotRefreshState()
        let beforeOldRefund = newerSubscription.beginRefresh()
        newerSubscription.recordRevocation(transactionId: 42, expirationDate: oldExpiry, retainedExpirationDate: newExpiry)
        check(newerSubscription.preservesPreviousOnEmpty, "An old refund removed a later subscription while offline")
        check(newerSubscription.isRevoked(transactionId: 42))
        check(!newerSubscription.completeRefresh(beforeOldRefund), "Old refund allowed a stale enumeration to publish")
        let afterOldRefund = newerSubscription.beginRefresh()
        check(newerSubscription.completeRefresh(afterOldRefund))
        check(newerSubscription.preservesPreviousOnEmpty)

        // Equal or missing dates cannot prove a different owner of the aggregate fallback.
        newerSubscription.recordRevocation(transactionId: 43, expirationDate: newExpiry, retainedExpirationDate: newExpiry)
        check(!newerSubscription.preservesPreviousOnEmpty, "Matching expiry incorrectly retained a possibly refunded unlock")
        newerSubscription.recordRevocation(transactionId: 41, expirationDate: oldExpiry, retainedExpirationDate: newExpiry)
        check(!newerSubscription.preservesPreviousOnEmpty, "A later old refund undid the current refund")
        var unknownExpiry = SGIAPSnapshotRefreshState()
        unknownExpiry.recordRevocation(transactionId: 44, expirationDate: nil, retainedExpirationDate: newExpiry)
        check(!unknownExpiry.preservesPreviousOnEmpty)
        var unknownSnapshot = SGIAPSnapshotRefreshState()
        unknownSnapshot.recordRevocation(transactionId: 45, expirationDate: oldExpiry, retainedExpirationDate: nil)
        check(!unknownSnapshot.preservesPreviousOnEmpty)
        print("PASS: snapshot ordering, refund invalidation, newer offline subscription, ambiguous-expiry policy")
    }
}
