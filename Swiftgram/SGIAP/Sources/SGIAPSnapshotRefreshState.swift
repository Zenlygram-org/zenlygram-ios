import Foundation

/// Used only from the StoreKit engine actor. A verified refund invalidates any enumeration that
/// began before it. A refund whose expiry is strictly older than the retained aggregate expiry
/// cannot remove that later subscription's offline allowance. Equal or missing expiries cannot
/// identify the aggregate's source, so those refunds invalidate empty-snapshot preservation.
struct SGIAPSnapshotRefreshState {
    private var generation: UInt64 = 0
    private var revokedTransactions: Set<UInt64> = []
    private(set) var preservesPreviousOnEmpty = true

    mutating func recordRevocation(transactionId: UInt64, expirationDate: Date? = nil, retainedExpirationDate: Date? = nil) {
        self.revokedTransactions.insert(transactionId)
        if let expirationDate, let retainedExpirationDate, expirationDate < retainedExpirationDate {
            // Do not reset this to true: an earlier refund may already have invalidated the
            // retained subscription, and a subsequent old refund cannot restore it.
        } else {
            self.preservesPreviousOnEmpty = false
        }
        self.generation &+= 1
    }

    func isRevoked(transactionId: UInt64) -> Bool {
        return self.revokedTransactions.contains(transactionId)
    }

    mutating func beginRefresh() -> UInt64 {
        self.generation &+= 1
        return self.generation
    }

    /// Only the newest enumeration may publish. An earlier loop can resume after a refund or a
    /// newer refresh, but must never restore its stale snapshot.
    mutating func completeRefresh(_ generation: UInt64) -> Bool {
        guard generation == self.generation else {
            return false
        }
        self.preservesPreviousOnEmpty = true
        return true
    }
}
