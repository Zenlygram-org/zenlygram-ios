import Foundation
import SGProtectedStore

/// Zenlygram — why a refresh is being considered (design §4.5, client contract §8).
public enum SGEntitlementRefreshTrigger: Equatable, Hashable {
    /// The first idle window AFTER launch. **Never the launch critical path** (invariant I1).
    case firstIdleAfterLaunch
    /// The app came to the foreground. Refreshes only if the cached token's `iat` is older than 24 h.
    case foreground
    /// `Transaction.updates` delivered something.
    case storeKitUpdate
    /// A silent APNs refresh hint (`SGEntitlement.isRefreshPush`). It names no account, so every
    /// linked account on the install is considered; the payload is never a decision input.
    case silentPush
    /// A 401 from a Zenlygram endpoint — at most once per cause.
    case unauthorized(SGEntitlementSessionFailure)
    /// The user asked: opened the paywall, tapped Restore, finished a purchase.
    case userInitiated
    /// Paid mode met a verifying token without the genuine account claims (`account_ent` /
    /// `account_until`): it proves nothing, so a fresh `iat` does not postpone the refresh — but the
    /// in-flight check, the 60 s collapse, the budget and any backoff still apply.
    case accountClaimsMissing
}

/// Zenlygram — when the client may talk to the entitlement server.
///
/// Three things it protects: the launch critical path (nothing here runs before the first idle
/// window), the per-device throttles (`GET /entitlement` 60/h, `POST /entitlement/refresh` 20/h —
/// and the undocumented IP bucket at 10x, which a whole NAT shares), and the server itself (backoff
/// with jitter, never a retry storm).
///
/// The budget and the backoff are DEVICE-wide: the server buckets on the `X-Device-Id` every
/// account on the install presents, and an outage or a 429 is the server's, not one session's.
/// Everything else — in flight, the 60 s collapse, the launch pass, the 401 latch — is per ACCOUNT:
/// each Telegram account has its own binding and token, and one account's refresh must never
/// swallow another's (a switch to an account whose token is a day old would otherwise wait for the
/// next foreground, while its stale token keeps granting).
public final class SGEntitlementScheduler {
    /// Refresh on foreground only when the cached token is older than this.
    public static let tokenStaleAfter: TimeInterval = 24.0 * 3600.0
    /// The first refresh never happens sooner than this after launch.
    public static let firstIdleDelay: TimeInterval = 8.0
    /// Two refreshes closer together than this are collapsed into one.
    public static let minimumInterval: TimeInterval = 60.0
    /// While the app is ACTIVE the signed monetization policy is re-fetched this often
    /// (`SGEntitlement.applicationDidBecomeActive` starts the timer, resign-active stops it), so a
    /// server flip reaches an app kept in the foreground within 30 minutes instead of at its next
    /// launch. Every tick still goes through `SGEntitlementPolicyRefreshGate` (one request in
    /// flight, 60 s apart): the timer only fetches a signed policy, and no timer can turn paid mode
    /// on by itself — only a newer signed policy can (`SGEntitlementPolicy`). Two extra GETs an hour
    /// per device, well under the endpoint's 60/min/IP throttle.
    public static let policyRefreshInterval: TimeInterval = 1800.0
    /// Local budgets, one notch under the server's, so we never earn a 429 by ourselves.
    public static let getBudgetPerHour = 50
    public static let postBudgetPerHour = 15

    static let getCallsKey = "zg.ent.budget.get"
    static let postCallsKey = "zg.ent.budget.post"

    public enum Decision: Equatable {
        /// Go, using `GET /entitlement` (cheap, does not rotate).
        case fetch
        /// Go, using `POST /entitlement/refresh` (rotates; also how `app_version` and `push_token`
        /// reach the server, which is how the server measures adoption for key rotation).
        case rotate
        /// Wait this long first.
        case wait(TimeInterval)
        /// Nothing to do.
        case skip
    }

    /// What the scheduler holds about one account's session.
    private struct AccountState {
        var lastRefreshAt: Date?
        var isInFlight = false
        var handledCauses: Set<SGEntitlementSessionFailure> = []
        var didLaunchIdlePass = false
    }

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var accounts: [Int64: AccountState] = [:]
    private var consecutiveFailures = 0
    /// The jittered backoff after a failure. Any account's success clears it: the server answered.
    private var backoffUntil: Date?
    /// The server's own `retry_after` for this device's bucket. Never cleared or shortened by a
    /// success: with several accounts in flight at once, a request admitted before the bucket filled
    /// can succeed after another one was told to wait, and the bucket is still full.
    private var retryAfterUntil: Date?

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: SGProtectedKeychain.sharedAccessGroup))
    }

    /// Tests pass a defaults suite of their own: the budget is persisted there.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// The decision for ONE account, given a trigger and what that account currently holds.
    ///
    /// `tokenIssuedAt` is that account's cached token's `iat` (nil when there is none), `isLinked`
    /// says whether it has a refresh token at all, and `wantsRotation` is true when its binding has
    /// not received the current APNs token yet.
    ///
    /// Only that telemetry rotates the session (`POST /entitlement/refresh`). A hint (push, StoreKit)
    /// only needs a fresh token, which the non-rotating GET returns: a rotation whose answer is lost
    /// strands the session once the server's 60 s overlap passes (`refresh_reuse`), so it is never
    /// spent on every linked account for every hint. A binding still owed the token is not skipped
    /// for a fresh `iat` — otherwise a re-bound account would hold no push token for a day.
    public func decide(
        trigger: SGEntitlementRefreshTrigger,
        accountPeerId: Int64,
        tokenIssuedAt: Date?,
        isLinked: Bool,
        wantsRotation: Bool,
        now: Date = Date()
    ) -> Decision {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard isLinked else {
            // Nothing to refresh: an unlinked account has no session to present. This is not a
            // failure and it is never surfaced.
            return .skip
        }
        var account = self.accounts[accountPeerId] ?? AccountState()
        defer {
            self.accounts[accountPeerId] = account
        }
        if account.isInFlight {
            return .skip
        }
        let holdUntil = [self.backoffUntil, self.retryAfterUntil].compactMap { $0 }.max()
        if let holdUntil, holdUntil > now {
            return .wait(holdUntil.timeIntervalSince(now))
        }
        let deliversToken = wantsRotation && self.hasBudgetLocked(key: SGEntitlementScheduler.postCallsKey, limit: SGEntitlementScheduler.postBudgetPerHour, now: now)
        let isFresh = tokenIssuedAt.map { now.timeIntervalSince($0) < SGEntitlementScheduler.tokenStaleAfter } ?? false

        switch trigger {
        case .firstIdleAfterLaunch:
            if account.didLaunchIdlePass {
                return .skip
            }
            account.didLaunchIdlePass = true
            if isFresh && !deliversToken {
                return .skip
            }
        case .foreground:
            if isFresh && !deliversToken {
                return .skip
            }
        case let .unauthorized(cause):
            if account.handledCauses.contains(cause) {
                return .skip
            }
            account.handledCauses.insert(cause)
        case .storeKitUpdate, .silentPush, .userInitiated, .accountClaimsMissing:
            break
        }

        if let last = account.lastRefreshAt, now.timeIntervalSince(last) < SGEntitlementScheduler.minimumInterval {
            return .skip
        }

        if deliversToken {
            return .rotate
        }
        if self.hasBudgetLocked(key: SGEntitlementScheduler.getCallsKey, limit: SGEntitlementScheduler.getBudgetPerHour, now: now) {
            return .fetch
        }
        return .skip
    }

    /// Call immediately before performing the decided call for `accountPeerId`.
    public func willPerform(_ decision: Decision, accountPeerId: Int64, now: Date = Date()) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        switch decision {
        case .fetch:
            self.recordCallLocked(key: SGEntitlementScheduler.getCallsKey, now: now)
        case .rotate:
            self.recordCallLocked(key: SGEntitlementScheduler.postCallsKey, now: now)
        case .wait, .skip:
            return
        }
        var account = self.accounts[accountPeerId] ?? AccountState()
        account.isInFlight = true
        account.lastRefreshAt = now
        self.accounts[accountPeerId] = account
    }

    public func didSucceed(accountPeerId: Int64, now: Date = Date()) {
        self.lock.lock()
        self.accounts[accountPeerId]?.isInFlight = false
        self.accounts[accountPeerId]?.handledCauses.removeAll()
        self.consecutiveFailures = 0
        self.backoffUntil = nil
        self.lock.unlock()
    }

    /// Backs off with jitter, device-wide. `retryAfter` from a 429 always wins, and is kept until it
    /// has passed whatever succeeds meanwhile.
    public func didFail(accountPeerId: Int64, retryAfter: TimeInterval?, now: Date = Date()) {
        self.lock.lock()
        self.accounts[accountPeerId]?.isInFlight = false
        let attempt = self.consecutiveFailures
        self.consecutiveFailures += 1
        let until = now.addingTimeInterval(SGEntitlementBackoff.delay(attempt: attempt, retryAfter: retryAfter))
        if retryAfter != nil {
            self.retryAfterUntil = max(self.retryAfterUntil ?? until, until)
        } else {
            self.backoffUntil = until
        }
        self.lock.unlock()
    }

    /// Resets one account's per-cause 401 latch, e.g. after a successful re-bind or a logout.
    public func resetCauses(accountPeerId: Int64) {
        self.lock.lock()
        self.accounts[accountPeerId]?.handledCauses.removeAll()
        self.lock.unlock()
    }

    // MARK: - Budget (a rolling hour, shared across processes through the app group)

    private func recentCallsLocked(key: String, now: Date) -> [Double] {
        let stored = self.defaults?.array(forKey: key) as? [Double] ?? []
        let cutoff = now.timeIntervalSince1970 - 3600.0
        return stored.filter { $0 > cutoff }
    }

    private func hasBudgetLocked(key: String, limit: Int, now: Date) -> Bool {
        return self.recentCallsLocked(key: key, now: now).count < limit
    }

    private func recordCallLocked(key: String, now: Date) {
        var calls = self.recentCallsLocked(key: key, now: now)
        calls.append(now.timeIntervalSince1970)
        self.defaults?.set(calls, forKey: key)
    }
}
