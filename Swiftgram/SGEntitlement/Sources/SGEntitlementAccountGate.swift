import Foundation

/// Zenlygram — the per-account gate that refresh-token ROTATION and every Tasks network attempt
/// share (`x-authentication.native_rotation`).
///
/// One holder per account at a time, waiters served first-in first-out. A Tasks attempt never
/// starts while a rotation for its account is in flight, and a rotation never starts while a Tasks
/// attempt is presenting the token it is about to replace. Whoever acquires the gate re-reads the
/// stored refresh token and abandons its work when that is no longer the token it was queued with,
/// so no attempt ever sends a credential a rotation already replaced. Different accounts never wait
/// for each other.
///
/// `acquire` is `async` and suspends instead of blocking; the lock is only ever taken inside
/// synchronous code (`NSLock` is unavailable from asynchronous contexts).
final class SGEntitlementAccountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holders = Set<Int64>()
    private var waiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]

    init() {
    }

    func acquire(accountPeerId: Int64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.enqueueOrTake(accountPeerId: accountPeerId, continuation: continuation) {
                continuation.resume()
            }
        }
    }

    /// Hands the gate to the next waiter for the account, or frees it.
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
        // Ownership passes directly: the account stays held, so nobody can slip in between.
        next.resume()
    }

    /// Tests: whether someone holds the account's gate, and how many wait behind it.
    func state(accountPeerId: Int64) -> (isHeld: Bool, waiting: Int) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return (self.holders.contains(accountPeerId), self.waiters[accountPeerId]?.count ?? 0)
    }

    /// True when the caller took the free gate; false when it was queued.
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
