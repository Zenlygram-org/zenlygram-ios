import Foundation

/// Zenlygram — the StoreKit attach outbox. Per INSTALL and backend ORIGIN (the store's
/// `SGEntitlementStoreScope`), not per Telegram account: a purchase belongs to the Apple ID, and it
/// must survive a logout, a re-bind and a relaunch — but an entry written for one origin is never
/// seen, sent, removed or rewritten by a build for another. Each entry carries the account it is
/// attributed to (`SGEntitlementOutboxEntry.accountPeerId`); a logout leaves its entries in place,
/// because an unfinished paid transaction is still owed its attach.
public final class SGEntitlementOutbox {
    public static let shared = SGEntitlementOutbox()

    /// After this many attempts an `apple_jws_invalid` stops auto-retrying and asks for help.
    public static let stuckAfterAttempts = SGEntitlementOutboxEntry.stuckAfterAttempts

    private let lock = NSLock()
    private let store: SGEntitlementStore
    private var cached: [SGEntitlementOutboxEntry]?

    init(store: SGEntitlementStore = .shared) {
        self.store = store
    }

    public func entries() -> [SGEntitlementOutboxEntry] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loadLocked()
    }

    private func loadLocked() -> [SGEntitlementOutboxEntry] {
        if let cached = self.cached {
            return cached
        }
        var entries: [SGEntitlementOutboxEntry] = []
        if let data = self.store.outboxData(), let decoded = try? JSONDecoder().decode([SGEntitlementOutboxEntry].self, from: data) {
            entries = decoded
        }
        self.cached = entries
        return entries
    }

    @discardableResult
    private func saveLocked(_ entries: [SGEntitlementOutboxEntry]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            return false
        }
        guard self.store.setOutboxData(data) else {
            return false
        }
        self.cached = entries
        return true
    }

    /// Adds a transaction, or returns the existing entry for the same id so its `Idempotency-Key` —
    /// and its attribution — are reused on every retry. `accountPeerId` is recorded only for a NEW
    /// entry; a redelivery or a Restore never re-attributes one that already exists.
    @discardableResult
    public func enqueue(signedTransaction: String, transactionId: String?, accountPeerId: Int64?) -> SGEntitlementOutboxEntry {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var entries = self.loadLocked()
        let id = transactionId ?? UUID().uuidString
        if let existing = entries.first(where: { $0.id == id }) {
            return existing
        }
        let entry = SGEntitlementOutboxEntry(id: id, signedTransaction: signedTransaction, idempotencyKey: UUID().uuidString, accountPeerId: accountPeerId)
        entries.append(entry)
        self.saveLocked(entries)
        return entry
    }

    /// Attached successfully: the caller may now `finish()` the transaction.
    public func remove(id: String) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var entries = self.loadLocked()
        entries.removeAll(where: { $0.id == id })
        self.saveLocked(entries)
    }

    /// Records a failed attach and schedules the next attempt. The transaction is NEVER dropped and
    /// NEVER finished from here; what the failure does to the entry is
    /// `SGEntitlementOutboxEntry.recordFailure`.
    public func recordFailure(id: String, failure: SGEntitlementFailureClass, retryAfter: TimeInterval?) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var entries = self.loadLocked()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].recordFailure(failure, retryAfter: retryAfter)
        self.saveLocked(entries)
    }

    /// Entries whose backoff has elapsed and that are not waiting for a human.
    public func dueEntries(now: Date = Date()) -> [SGEntitlementOutboxEntry] {
        return self.entries().filter { entry in
            if entry.isStuck {
                return false
            }
            guard let next = entry.nextAttemptAt else {
                return true
            }
            return next <= now
        }
    }

    /// Entries a human has to look at. The paywall / settings surface a support path for these —
    /// never a retry loop, and never an external-purchase link.
    public func stuckEntries() -> [SGEntitlementOutboxEntry] {
        return self.entries().filter { $0.isStuck }
    }

    /// Clears every `isStuck` flag and makes the entries due again.
    ///
    /// Only Restore Purchases calls this: "stuck" means no AUTOMATIC retry will help, and the user
    /// asking for one explicitly is exactly the event that can change the answer — an operator
    /// re-deploy that now accepts this environment, a subscription conflict a human resolved. It
    /// never finishes and never drops a transaction, so the worst case is one extra request.
    public func clearStuckFlags() {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var entries = self.loadLocked()
        guard entries.contains(where: { $0.isStuck || $0.nextAttemptAt != nil }) else {
            return
        }
        for index in entries.indices {
            entries[index].isStuck = false
            entries[index].nextAttemptAt = nil
        }
        self.saveLocked(entries)
    }
}
