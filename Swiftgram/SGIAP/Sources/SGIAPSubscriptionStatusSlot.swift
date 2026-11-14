import Foundation

/// Zenlygram — the last StoreKit subscription status, with the newest-query-wins rule. Guarded by
/// `SGIAPManager.lock`; Foundation only (generic over the status) so `run-status-slot-tests.sh` runs
/// it without StoreKit.
///
/// The status is re-queried on foreground, on every `Transaction.updates` delivery, when the Pro
/// status screen appears, and after a product load, purchase or Restore. Those queries overlap and
/// finish in any order: only the newest may land, so an older answer read before the user turned
/// auto-renew off in Apple's page cannot overwrite a newer one, and cannot revive a value after the
/// newest query failed.
///
/// Two readings:
///  - `value`, the last ANSWER StoreKit gave. The paywall labels its plans with it. A failed query
///    (offline, no products loaded) is not an answer and leaves it alone; StoreKit answering "nothing
///    in the group" clears it.
///  - `settled`, the same value only while it is current: nil while a newer query runs and after the
///    newest one failed, until a later query answers. A surface stating renewal or billing facts
///    reads this, so it never repeats a claim nobody could re-confirm.
struct SGIAPSubscriptionStatusSlot<Status: Equatable> {
    private(set) var value: Status?
    private var generation: UInt64 = 0
    private var isQuerying = false
    /// The newest finished query failed: `value` is kept but no longer confirmed.
    private var isUnconfirmed = false

    var settled: Status? {
        return (self.isQuerying || self.isUnconfirmed) ? nil : self.value
    }

    /// Starts a query and supersedes every earlier one. Returns its generation, and whether
    /// `settled` just stopped showing a value (the caller then announces the change).
    mutating func begin() -> (generation: UInt64, hidValue: Bool) {
        let hidValue = self.settled != nil
        self.generation &+= 1
        self.isQuerying = true
        return (self.generation, hidValue)
    }

    /// StoreKit answered (nil: nothing in the group). Applied only for the newest, still-open query.
    /// Returns whether anything a reader sees changed.
    mutating func complete(_ generation: UInt64, status: Status?) -> Bool {
        guard generation == self.generation, self.isQuerying else {
            return false
        }
        let previousSettled = self.settled
        let previousValue = self.value
        self.isQuerying = false
        self.isUnconfirmed = false
        self.value = status
        return previousValue != status || previousSettled != status
    }

    /// The newest query could not get an answer. `value` stays for the paywall; `settled` stays
    /// unknown until a later query answers. A late or duplicate completion is ignored.
    mutating func fail(_ generation: UInt64) -> Bool {
        guard generation == self.generation, self.isQuerying else {
            return false
        }
        self.isQuerying = false
        self.isUnconfirmed = true
        // `settled` was already nil while querying and stays nil; `value` is unchanged.
        return false
    }
}
