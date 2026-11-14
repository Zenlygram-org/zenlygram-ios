import Foundation

/// Zenlygram — what the facade hands to the installed sink (design 40 §10.1).
public enum SGAnalyticsInput: Equatable {
    case event(SGAnalyticsEvent)
    /// Aggregated per (domain, code) per session into `error.occurred`.
    case error(SGAnalyticsErrorDomain, SGAnalyticsErrorCode)
    /// Aggregated per kind per session into `tasks.sync_issue`.
    case tasksSyncIssue(SGAnalyticsTasksSyncIssueKind, count: Int)
}

/// Zenlygram — the receiver of every recorded event: the main app's `SGAnalyticsPipeline`. Called
/// on the emitting thread; it must return at once (hop to its own queue).
public protocol SGAnalyticsSink: AnyObject {
    /// `accountPeerId` (packed `PeerId.toInt64()`) names the owning account, nil = the active one;
    /// `at` is the device clock when the event happened.
    func receive(_ input: SGAnalyticsInput, accountPeerId: Int64?, at: Date)
}

/// Zenlygram — the analytics facade every feature module records through (design 40 §10.1,
/// contract §3). Thread-safe and never blocking: it hands each call to the installed sink. A no-op
/// until the main app installs one (`SGCustomerSync`), always in an extension, and for an owning
/// account without `recordEvents` clearance (the pipeline drops the event; it is never attributed
/// to another account).
public enum SGAnalytics {
    /// How long a noted paywall entry stays fresh.
    public static let paywallEntryLifetime: TimeInterval = 10.0

    private static let lock = NSLock()
    private static var installedSink: SGAnalyticsSink?
    private static var paywallEntry: (source: SGAnalyticsProSource, at: TimeInterval)?

    /// Monotonic seconds (`ProcessInfo.systemUptime`; replaced in tests).
    static var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The event time (device clock; replaced in tests).
    static var clock: () -> Date = { Date() }
    /// The process is an app extension (`.appex`).
    static var isExtensionProcess: () -> Bool = { Bundle.main.bundlePath.hasSuffix(".appex") }

    // MARK: - Recording

    /// Records `event` for `accountPeerId` (packed `PeerId.toInt64()`; nil = the active account).
    public static func record(_ event: SGAnalyticsEvent, accountPeerId: Int64? = nil) {
        SGAnalytics.deliver(.event(event), accountPeerId: accountPeerId)
    }

    /// `screen.view` (dropped when the same screen was this session's last view < 30 s ago, and
    /// before the account's first session in this process).
    public static func screen(_ screen: SGAnalyticsScreen, accountPeerId: Int64? = nil) {
        SGAnalytics.deliver(.event(.screenView(screen)), accountPeerId: accountPeerId)
    }

    /// `feature.toggle`: the user switched a Zenlygram setting.
    public static func featureToggled(_ feature: SGAnalyticsFeature, enabled: Bool, accountPeerId: Int64? = nil) {
        SGAnalytics.deliver(.event(.featureToggle(feature, enabled: enabled)), accountPeerId: accountPeerId)
    }

    /// `feature.used`: at most once per feature per session.
    public static func featureUsed(_ feature: SGAnalyticsFeature, accountPeerId: Int64? = nil) {
        SGAnalytics.deliver(.event(.featureUsed(feature)), accountPeerId: accountPeerId)
    }

    /// An error, aggregated per (domain, code) per session into one `error.occurred` with `count`
    /// (capped at 1000), emitted at session end and before every flush.
    public static func error(_ domain: SGAnalyticsErrorDomain, _ code: SGAnalyticsErrorCode, accountPeerId: Int64? = nil) {
        SGAnalytics.deliver(.error(domain, code), accountPeerId: accountPeerId)
    }

    /// Tasks sync issues, aggregated per kind per session into `tasks.sync_issue` like `error`.
    public static func tasksSyncIssue(_ kind: SGAnalyticsTasksSyncIssueKind, count: Int, accountPeerId: Int64) {
        SGAnalytics.deliver(.tasksSyncIssue(kind, count: count), accountPeerId: accountPeerId)
    }

    // MARK: - Paywall entry

    /// Remembers how the paywall is being reached; the paywall reads it within 10 s.
    public static func notePaywallEntry(_ source: SGAnalyticsProSource) {
        let now = SGAnalytics.uptime()
        SGAnalytics.lock.lock()
        SGAnalytics.paywallEntry = (source, now)
        SGAnalytics.lock.unlock()
    }

    /// The fresh (≤ 10 s) entry, not consumed: a later source (`.settings`) notes itself only when
    /// nothing fresher (`.deeplink`) is pending.
    public static func peekPaywallEntry() -> SGAnalyticsProSource? {
        let now = SGAnalytics.uptime()
        SGAnalytics.lock.lock()
        defer {
            SGAnalytics.lock.unlock()
        }
        return SGAnalytics.freshEntryLocked(now: now)
    }

    /// Consumes the fresh entry; `.other` when there is none.
    public static func takePaywallEntry() -> SGAnalyticsProSource {
        let now = SGAnalytics.uptime()
        SGAnalytics.lock.lock()
        defer {
            SGAnalytics.lock.unlock()
        }
        let source = SGAnalytics.freshEntryLocked(now: now) ?? .other
        SGAnalytics.paywallEntry = nil
        return source
    }

    // MARK: - Installation

    /// SGCustomerSync only, once, in the main app. Refused inside an app extension.
    public static func install(_ sink: SGAnalyticsSink) {
        guard !SGAnalytics.isExtensionProcess() else {
            return
        }
        SGAnalytics.lock.lock()
        SGAnalytics.installedSink = sink
        SGAnalytics.lock.unlock()
    }

    /// Tests: removes the sink and the paywall entry.
    static func resetForTesting() {
        SGAnalytics.lock.lock()
        SGAnalytics.installedSink = nil
        SGAnalytics.paywallEntry = nil
        SGAnalytics.lock.unlock()
    }

    private static func deliver(_ input: SGAnalyticsInput, accountPeerId: Int64?) {
        SGAnalytics.lock.lock()
        let sink = SGAnalytics.installedSink
        SGAnalytics.lock.unlock()
        // Read under the lock, called outside it.
        sink?.receive(input, accountPeerId: accountPeerId, at: SGAnalytics.clock())
    }

    private static func freshEntryLocked(now: TimeInterval) -> SGAnalyticsProSource? {
        guard let entry = SGAnalytics.paywallEntry, now - entry.at >= 0, now - entry.at <= SGAnalytics.paywallEntryLifetime else {
            return nil
        }
        return entry.source
    }
}
