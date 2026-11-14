import Foundation

/// Used only from the StoreKit engine actor: at most one outbox drain at a time, and a drain asked
/// for while one is running is NOT dropped — it is coalesced into one more pass once the running
/// pass ends. The running pass read its due list before the request, so an entry that became due
/// in between (Restore clearing the stuck flags, a foreground after a backoff elapsed) would
/// otherwise wait for the next unrelated trigger. `begin()` and `finishPass()` contain no `await`,
/// which on an actor makes each atomic.
struct SGIAPDrainGate {
    private(set) var isDraining = false
    private var rerunRequested = false

    /// True when the caller now owns the drain; false when one is running, which then reruns.
    mutating func begin() -> Bool {
        if self.isDraining {
            self.rerunRequested = true
            return false
        }
        self.isDraining = true
        return true
    }

    /// Called by the owner after each pass: true means run another pass, false releases the gate.
    mutating func finishPass() -> Bool {
        if self.rerunRequested {
            self.rerunRequested = false
            return true
        }
        self.isDraining = false
        return false
    }
}

/// Runs outbox drains through `SGIAPDrainGate`, and makes every caller wait for the drain that
/// covers its request. A caller arriving while a drain runs asks for one more pass and then awaits
/// the running drain's task — which, because of that request, ends only after a pass that STARTED
/// after the caller asked. So Restore reports and refreshes only once the entries it just made
/// retryable were actually tried, not merely scheduled.
///
/// The drain itself runs in an unstructured task: a caller that is cancelled (a closed paywall)
/// does not cancel attaches other callers are waiting for, exactly like `SGIAPDeliveryCoordinator`.
@available(iOS 15.0, *)
actor SGIAPDrainRunner {
    private var gate = SGIAPDrainGate()
    /// Non-nil exactly while `gate.isDraining`: set with no `await` after `begin()` succeeds and
    /// cleared with no `await` after `finishPass()` releases the gate.
    private var current: Task<Void, Never>?
    private var waiting = 0

    func drain(_ pass: @escaping () async -> Void) async {
        if self.gate.begin() {
            let task = Task {
                await self.runPasses(pass)
            }
            self.current = task
            await task.value
        } else if let current = self.current {
            self.waiting += 1
            await current.value
            self.waiting -= 1
        }
    }

    private func runPasses(_ pass: @escaping () async -> Void) async {
        repeat {
            await pass()
        } while self.gate.finishPass()
        self.current = nil
    }

    /// Callers waiting on a drain they did not start. Read-only observation; nothing depends on it.
    func waitingCallers() -> Int {
        return self.waiting
    }
}
