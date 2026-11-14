import Foundation

/// What happened to one transaction on its way to `/v1/apple/attach`.
enum SGIAPAttachOutcome: Equatable {
    /// The server has it (or this build has no entitlement server).
    case attached
    /// Unfinished, waiting for configuration, persistence, or a retry.
    case deferred
    /// Unfinished; automatic retries cannot repair the server's refusal.
    case needsHelp
    /// Not one of our products, or already revoked.
    case ignored
}

/// Actor reentrancy permits other deliveries while an HTTP request is suspended. Share that
/// request's result instead of sending the same idempotency key concurrently. Successful delivery
/// is remembered for this process: StoreKit may still emit a duplicate after the outbox is removed
/// and before `Transaction.finish()` returns. Each caller remains responsible for finishing its
/// transaction only after receiving `.attached`.
@available(iOS 15.0, *)
actor SGIAPDeliveryCoordinator {
    private var pending: [String: Task<SGIAPAttachOutcome, Never>] = [:]
    private var delivered: Set<String> = []
    /// Callers currently suspended on another caller's in-flight attach, per transaction id.
    private var joiners: [String: Int] = [:]
    /// An explicit Restore claim running for a transaction id (`exclusive(id:operation:)`). While
    /// one runs, no ordinary attach of that id starts: it waits, then runs its own request.
    /// Each marker task completes only after its own entry is removed (`endExclusive`), so a waiter
    /// woken by it never finds that same entry again and cannot spin on it.
    private var exclusives: [String: (token: UUID, marker: Task<Void, Never>)] = [:]
    /// Ordinary deliveries currently waiting for an exclusive claim, per transaction id.
    private var heldDeliveries: [String: Int] = [:]

    /// How many ordinary deliveries of `id` are waiting for its explicit claim to return. Read-only
    /// observation, like `joinedCallers`; nothing in the delivery path depends on it.
    func heldBehindExclusive(id: String) -> Int {
        return self.heldDeliveries[id] ?? 0
    }

    /// How many callers are waiting on the in-flight attach for `id` instead of sending their own.
    /// Read-only observation of the coalescing above; nothing in the delivery path depends on it.
    func joinedCallers(id: String) -> Int {
        return self.joiners[id] ?? 0
    }

    func deliver(id: String, operation: @escaping () async -> SGIAPAttachOutcome) async -> SGIAPAttachOutcome {
        // Never beside an explicit claim of the same transaction: wait for it, then decide afresh.
        while let exclusive = self.exclusives[id]?.marker {
            self.heldDeliveries[id, default: 0] += 1
            await exclusive.value
            if let count = self.heldDeliveries[id], count > 1 {
                self.heldDeliveries[id] = count - 1
            } else {
                self.heldDeliveries.removeValue(forKey: id)
            }
        }
        if self.delivered.contains(id) {
            return .attached
        }
        if let pending = self.pending[id] {
            self.joiners[id, default: 0] += 1
            let outcome = await pending.value
            if let count = self.joiners[id], count > 1 {
                self.joiners[id] = count - 1
            } else {
                self.joiners.removeValue(forKey: id)
            }
            return outcome
        }
        // Do not inherit caller cancellation: another caller can be waiting for this payment's
        // delivery, and closing a paywall must not cancel its attach.
        let pending = Task {
            await operation()
        }
        self.pending[id] = pending
        let outcome = await pending.value
        if outcome == .attached {
            self.delivered.insert(id)
        }
        self.pending.removeValue(forKey: id)
        return outcome
    }

    /// Runs `operation` (the explicit Restore claim of `id`) alone: after every ordinary attach of
    /// `id` in flight has settled with its own captured account, and with every ordinary attach of
    /// `id` that arrives meanwhile — another `Transaction.updates` delivery, a drain on becoming
    /// active — held until it returns. The held attach then runs its OWN request: it neither shares
    /// the claim's answer nor is answered from it. Not cancelled with the caller.
    ///
    /// `operation` must not deliver `id` itself (it would wait for itself): a fallback attach goes
    /// after this returns.
    func exclusive<T: Sendable>(id: String, operation: @escaping () async -> T) async -> T {
        // An ordinary attach's `pending` entry is removed by its own caller after the task ends, so
        // a finished task can still be listed for a moment: wait for each task once, not per sight.
        var settled: Task<SGIAPAttachOutcome, Never>?
        while true {
            if let exclusive = self.exclusives[id]?.marker {
                await exclusive.value
                continue
            }
            if let pending = self.pending[id], pending != settled {
                settled = pending
                self.joiners[id, default: 0] += 1
                _ = await pending.value
                if let count = self.joiners[id], count > 1 {
                    self.joiners[id] = count - 1
                } else {
                    self.joiners.removeValue(forKey: id)
                }
                continue
            }
            break
        }
        // Installed with no suspension since the checks above, so nothing of `id` starts between.
        let token = UUID()
        let work = Task {
            await operation()
        }
        let marker = Task {
            _ = await work.value
            self.endExclusive(id: id, token: token)
        }
        self.exclusives[id] = (token, marker)
        let result = await work.value
        // Returns only once the entry is gone: a fallback attach right after this must not wait for
        // a claim that has already returned.
        await marker.value
        return result
    }

    private func endExclusive(id: String, token: UUID) {
        if self.exclusives[id]?.token == token {
            self.exclusives.removeValue(forKey: id)
        }
    }

    /// Restore Purchases only. The memo exists to absorb StoreKit's automatic duplicate; Restore is
    /// the user explicitly asking to attach again (typically under a Telegram account linked since
    /// the first, unbound attach), so it must reach the server. An attach still in flight stays
    /// coalesced: `pending` is untouched, so one Idempotency-Key is never sent twice at once.
    func forgetDeliveries() {
        self.delivered.removeAll()
    }
}
