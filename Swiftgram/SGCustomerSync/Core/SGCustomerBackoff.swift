import Foundation

/// Zenlygram — the backoff of every automatic customer-data call, per account and route (design 40
/// §7.5, contract §6.5): full jitter, the delay after the n-th consecutive failure is
/// uniform(0, min(6 h, 30 s × 2^(n−1))); a `Retry-After` / `retry_after` wins (plus ≤ 5 s of
/// jitter); a success resets it. In memory: a relaunch starts afresh (first idle and the budgets
/// still pace it). Auto-link has its own ladders (`SGAutoLinkPolicy`).
public struct SGCustomerBackoff: Equatable {
    public static let base: TimeInterval = 30
    public static let cap: TimeInterval = 6 * 3600
    public static let retryAfterJitter: TimeInterval = 5

    /// Consecutive failures.
    public private(set) var failures: Int = 0
    /// Not before this (nil: now).
    public private(set) var nextAt: Date?

    public init() {}

    /// The upper bound of the delay after `failures` consecutive failures.
    public static func ceiling(failures: Int) -> TimeInterval {
        guard failures > 0 else {
            return 0
        }
        let exponent = Double(min(failures - 1, 20))
        return min(SGCustomerBackoff.cap, SGCustomerBackoff.base * pow(2.0, exponent))
    }

    public func allows(now: Date) -> Bool {
        return self.nextAt.map { $0 <= now } ?? true
    }

    /// One more failure. `random` draws from [0, 1).
    public mutating func recordFailure(now: Date, retryAfter: TimeInterval? = nil, random: () -> Double = { Double.random(in: 0 ..< 1) }) {
        self.failures += 1
        let draw = min(max(random(), 0), 1)
        if let retryAfter, retryAfter.isFinite, retryAfter >= 0 {
            self.nextAt = now.addingTimeInterval(retryAfter + draw * SGCustomerBackoff.retryAfterJitter)
        } else {
            self.nextAt = now.addingTimeInterval(draw * SGCustomerBackoff.ceiling(failures: self.failures))
        }
    }

    public mutating func recordSuccess() {
        self.failures = 0
        self.nextAt = nil
    }

    /// What a classified answer does to the route (design 40 §6.5): a 2xx or a final 4xx answer
    /// resets it; a timeout, a 429, a 404 / 5xx / offline count a failure (their `Retry-After`
    /// wins); a 413 (the events batch halves and goes again), nothing sent, a changed credential, a
    /// consent, link or session answer leave it unchanged.
    public mutating func apply(_ outcome: SGCustomerCallOutcome, now: Date, random: () -> Double = { Double.random(in: 0 ..< 1) }) {
        switch outcome {
        case .ok, .terminal, .accountMismatch:
            self.recordSuccess()
        case .timedOut:
            self.recordFailure(now: now, retryAfter: nil, random: random)
        case let .rateLimited(retryAfter), let .unavailable(retryAfter):
            self.recordFailure(now: now, retryAfter: retryAfter, random: random)
        case .payloadTooLarge, .consentRequired, .accountNotLinked, .session, .notLinkedLocally, .credentialChanged, .notConfigured:
            break
        }
    }
}

/// Zenlygram — a device-wide client budget for the AUTOMATIC calls of one route (design 40 §7.4,
/// contract §2.0: 80 % of the server's per-device limits): consents 16, sync 9, events 48 per hour.
/// User-initiated calls (`me`, the withdraw send, `delete`) and the logout final send are never
/// held by it. Persisted as `zg.cs.budget.v1.<route>@<authority>` = `{"sent":[unix s, …]}`.
public struct SGCustomerBudget: Equatable {
    public static let window: TimeInterval = 3600

    /// Automatic calls per hour, nil for the user-initiated routes.
    public static func limit(for route: SGCustomerRoute) -> Int? {
        switch route {
        case .consents:
            return 16
        case .sync:
            return 9
        case .events:
            return 48
        case .me, .delete:
            return nil
        }
    }

    public let route: SGCustomerRoute
    /// Send times within the window (unordered).
    public private(set) var sent: [Date]

    public init(route: SGCustomerRoute, sent: [Date] = []) {
        self.route = route
        self.sent = sent
    }

    /// The stored marker; a malformed one reads as empty.
    public init(route: SGCustomerRoute, jsonObject: [String: Any]?) {
        let values = (jsonObject?["sent"] as? [Any]) ?? []
        self.init(route: route, sent: values.compactMap { SGCustomerJSON.integer($0).map { Date(timeIntervalSince1970: TimeInterval($0)) } })
    }

    /// For `SGConsentStore.setJSONObject(_:for: .budget(route:authority:))`.
    public var jsonObject: [String: Any] {
        return ["sent": self.sent.map { Int($0.timeIntervalSince1970.rounded(.down)) }]
    }

    /// When the next automatic call may go: nil = now. A send time on either side of `now` within
    /// the window counts (a clock set back does not free the budget).
    public func nextAllowedAt(now: Date) -> Date? {
        guard let limit = SGCustomerBudget.limit(for: self.route) else {
            return nil
        }
        let recent = self.recent(now: now).sorted()
        guard recent.count >= limit else {
            return nil
        }
        return recent[recent.count - limit].addingTimeInterval(SGCustomerBudget.window)
    }

    /// An automatic call went out at `now`.
    public mutating func record(now: Date) {
        guard SGCustomerBudget.limit(for: self.route) != nil else {
            return
        }
        self.sent = Array((self.recent(now: now) + [now]).sorted().suffix(64))
    }

    private func recent(now: Date) -> [Date] {
        return self.sent.filter { abs($0.timeIntervalSince(now)) < SGCustomerBudget.window }
    }
}
