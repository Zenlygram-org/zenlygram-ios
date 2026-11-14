import Foundation

/// Zenlygram — exponential backoff WITH jitter, so a recovering server does not meet a thundering
/// herd of every Zenlygram install at once.
public enum SGEntitlementBackoff {
    public static let base: TimeInterval = 5.0
    public static let cap: TimeInterval = 3600.0

    /// Full jitter: a uniform draw from `[0, min(cap, base * 2^attempt)]`. `attempt` is 0 for the
    /// first retry.
    public static func delay(attempt: Int, base: TimeInterval = SGEntitlementBackoff.base, cap: TimeInterval = SGEntitlementBackoff.cap) -> TimeInterval {
        let clamped = max(0, min(attempt, 16))
        let ceiling = min(cap, base * pow(2.0, Double(clamped)))
        return TimeInterval.random(in: 0 ... ceiling)
    }

    /// The server's `retry_after` always wins; jitter is added on top so a whole NAT does not come
    /// back in the same second.
    public static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        guard let retryAfter else {
            return self.delay(attempt: attempt)
        }
        return retryAfter + TimeInterval.random(in: 0 ... min(5.0, max(1.0, retryAfter * 0.1)))
    }
}
