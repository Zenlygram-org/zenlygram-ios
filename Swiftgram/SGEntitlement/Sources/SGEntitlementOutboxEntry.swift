import Foundation

/// Zenlygram — one App Store transaction waiting to be attached.
///
/// It exists because of one rule: **never `finish()` an unattached transaction.** StoreKit
/// redelivers an unfinished transaction; a finished one is gone forever, and with it the proof of a
/// payment. So the transaction stays unfinished, and its `signed_transaction` plus its
/// `Idempotency-Key` are persisted here until `/apple/attach` answers 2xx.
///
/// The entry is a plain value: what one failed attach does to it (`recordFailure`) is decided here,
/// with no store behind it, so the rule runs in the host tests; `SGEntitlementOutbox` only loads,
/// locks and persists the list.
public struct SGEntitlementOutboxEntry: Codable, Equatable {
    /// After this many attempts an `apple_jws_invalid`, or an answer with no server code behind it
    /// (a bare 404 / 405 / uncoded 4xx), stops auto-retrying and asks for help.
    public static let stuckAfterAttempts = 5

    /// Apple's transaction id when we have one, otherwise a local UUID.
    public let id: String
    /// `Transaction.jwsRepresentation`.
    public let signedTransaction: String
    /// Persisted WITH the entry: a retry must present the SAME key, or the server treats it as a new
    /// request. Only a 2xx is stored server-side, for 24 h, so a failure stays retryable.
    public let idempotencyKey: String
    /// The Telegram account whose binding authenticates this attach, captured ONCE when the entry
    /// is created and never re-read from the active account: the account whose paywall started the
    /// purchase (and whose `/apple/prepare` minted its `appAccountToken`), or the one Restore was
    /// pressed for. nil means UNBOUND — no `Authorization`, only `X-Device-Id` — and the server
    /// resolves the owner from the `appAccountToken` or the original transaction. That includes
    /// every entry written before this field existed: an old entry never borrows whichever account
    /// happens to be active when it is retried.
    public let accountPeerId: Int64?
    public var attempts: Int
    public var nextAttemptAt: Date?
    /// The last stable error code, for support and for logs.
    public var lastErrorCode: String?
    /// Set when no AUTOMATIC retry will help and a human has to decide: a refusal the server CODED
    /// whose recovery is `.stop` (`apple_environment_mismatch`, `apple_subscription_conflict`,
    /// `apple_family_shared`, a client or configuration bug, a stable code this build does not know),
    /// or `apple_jws_invalid` and the answers synthesised from a bare status past
    /// `stuckAfterAttempts`. Auto-retrying stops; the transaction still stays UNFINISHED and a
    /// support path is surfaced. Only Restore Purchases clears it (`SGEntitlementOutbox.clearStuckFlags`).
    public var isStuck: Bool

    public init(id: String, signedTransaction: String, idempotencyKey: String, accountPeerId: Int64?, attempts: Int = 0, nextAttemptAt: Date? = nil, lastErrorCode: String? = nil, isStuck: Bool = false) {
        self.id = id
        self.signedTransaction = signedTransaction
        self.idempotencyKey = idempotencyKey
        self.accountPeerId = accountPeerId
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.lastErrorCode = lastErrorCode
        self.isStuck = isStuck
    }

    /// Whether the attach that just failed with `failure` on its `attempts`-th try waits for a human
    /// from now on.
    ///
    /// "Stuck" means no AUTOMATIC retry will help — never "drop" and never "finish". A refusal the
    /// server would only repeat is not helped by one more attempt, so every refusal the server CODED
    /// whose recovery is `.stop` is stuck at once — `apple_environment_mismatch`,
    /// `apple_subscription_conflict`, `apple_family_shared`, a client or configuration bug such as
    /// `invalid_transaction`, and a stable code this build does not know. The table that says which
    /// refusals stop is `SGEntitlementFailureMapping`, so a new code is taught in one place.
    ///
    /// Two kinds of answer are stopped by that table without being a stable server refusal, and
    /// those keep backing off until `stuckAfterAttempts` instead: `apple_jws_invalid`, which Apple's
    /// chain check can also produce transiently; and the classes `SGEntitlementFailureMapping
    /// .classify` synthesises from a bare STATUS when the body carries no JSON `code` — a 404 or 405
    /// (an edge misroute during a deploy) and an uncoded 4xx (a CDN, WAF or proxy error page). One
    /// such answer must not strand a PAID transaction until the user finds Restore; five in a row
    /// are no longer transient. Offline, rate-limited and session failures never make an entry stuck
    /// — time or a re-bind repairs those, not a human.
    static func isStuck(after failure: SGEntitlementFailureClass, attempts: Int) -> Bool {
        switch failure {
        case .refused(.appleJwsInvalid), .refused(.notFound), .refused(.methodNotAllowed):
            return attempts >= SGEntitlementOutboxEntry.stuckAfterAttempts
        case let .unknownRefusal(code, _) where code.isEmpty:
            return attempts >= SGEntitlementOutboxEntry.stuckAfterAttempts
        case .refused, .unknownRefusal:
            return SGEntitlementFailureMapping.recovery(for: failure).retry == .stop
        case .offline, .rateLimited, .session:
            return false
        }
    }

    /// Records one failed attach: one more attempt, the stable code for support and logs, whether a
    /// human has to look at it from now on, and the next attempt — none while stuck, otherwise after
    /// backoff (the server's `retry_after` wins). Nothing here drops or finishes the transaction.
    mutating func recordFailure(_ failure: SGEntitlementFailureClass, retryAfter: TimeInterval?, now: Date = Date()) {
        self.attempts += 1
        switch failure {
        case let .refused(code):
            self.lastErrorCode = code.rawValue
        case .unknownRefusal:
            self.lastErrorCode = "request_failed"
        case let .session(sessionFailure):
            self.lastErrorCode = sessionFailure.rawValue
        case .rateLimited:
            self.lastErrorCode = "rate_limited"
        case .offline:
            self.lastErrorCode = nil
        }
        // Once stuck, stuck until Restore clears the flag: a later transient failure does not make
        // the human unnecessary.
        self.isStuck = self.isStuck || SGEntitlementOutboxEntry.isStuck(after: failure, attempts: self.attempts)
        self.nextAttemptAt = self.isStuck ? nil : now.addingTimeInterval(SGEntitlementBackoff.delay(attempt: self.attempts - 1, retryAfter: retryAfter))
    }
}
