import Foundation

/// Zenlygram — one answer to `POST /v1/account/delete` as the deletion table reads it (design 40
/// §11.4): the classified outcome, and whether the device had no connection (the screen then says
/// Offline rather than Unavailable — `SGCustomerCallOutcome.unavailable` covers both).
public struct SGCustomerDeleteOutcome: Equatable {
    public let outcome: SGCustomerCallOutcome
    /// No connection, or no answer in time.
    public let offline: Bool

    public init(outcome: SGCustomerCallOutcome, offline: Bool = false) {
        self.outcome = outcome
        self.offline = offline
    }

    /// The transport's answer, classified by the one classifier (`SGCustomerWire.classify`).
    public init(_ answer: SGCustomerRawAnswer) {
        self.init(outcome: SGCustomerWire.classify(answer), offline: answer.transport == .offline || answer.transport == .timeout)
    }
}

/// Zenlygram — the in-app account deletion (design 40 §11.4, contract §2.2.5 and §6.8, Contract
/// issue 18) as a pure state machine over the persisted fence `zg.cs.delete.v1.<tg>@<authority>`.
///
/// 1. Before the first send the fence `{key: uuid4, sent_unknown: false, since}` is written: the
///    account is **erasing** — auto-link, the planner, clearance and both bind providers treat it
///    as blocked.
/// 2. `POST /v1/account/delete` with `Idempotency-Key: key`; every retry reuses the key.
/// 3. The answer:
///
/// | answer | result |
/// |---|---|
/// | 200 | deleted |
/// | 401 `invalid_token` / `session_revoked` / `device_revoked` / `refresh_reuse` AND `sent_unknown` | deleted (a retry of a delete that was already sent) |
/// | 401 with `reason: account_erased` (amendment A3) | deleted (the account is gone) |
/// | any other 401 (a first send, `clock_skew`, `unauthenticated`, `nonce_replayed`, `device_key_mismatch`, …) | not deleted: `failed` + the web link; the fence is lifted; nothing erased |
/// | timeout, no connection, 5xx, 503 | `sent_unknown = true`; offline / unavailable; the fence stays; retried with the same key |
/// | 409 `idempotency_in_flight` | `sent_unknown = true`; retried after 1 s with the same key |
/// | 429 | rate limited; with `sent_unknown == false` the fence is lifted (nothing happened), else retried |
/// | the session changed under the call | retried at once with the same key |
/// | no session, `sent_unknown`, and a `sessionEnd` of a drop code above newer than `since` | deleted |
/// | no session otherwise | not deleted: `notLinked` + the web link; the fence is lifted |
/// | any other answer (422, another 4xx) | not deleted: `failed`; the fence is lifted |
///
/// 4. Resume: at first idle and on every foreground a fence that is not being sent is sent again
///    with its key (the user confirmed already).
///
/// Deleted → the coordinator's local erase, in this order: `SGEntitlement.forgetErasedAccount`,
/// `SGTasksCloudRepository.purgeAfterAccountErasure`, the event queue purge, gate `[]`,
/// `SGConsentStore.purge(tg:)`, the auto-link record and the fence removed, then the deleted notice.
public enum SGCustomerDeletion {
    /// The 401 codes that confirm a delete which was already sent (the session it was sent with is
    /// gone because the account is): contract §2.2.5, narrowed by Contract issue 18.
    public static let dropCodes: Set<String> = ["invalid_token", "session_revoked", "device_revoked", "refresh_reuse"]
    /// 409 `idempotency_in_flight`: the server is still running the first request with this key.
    public static let inFlightCode = "idempotency_in_flight"
    public static let inFlightRetryDelay: TimeInterval = 1

    /// `zg.cs.delete.v1.<tg>@<authority>` = `{"key":uuid4,"sent_unknown":Bool,"since":instant}`.
    public struct Record: Equatable {
        /// The `Idempotency-Key` of every send.
        public let key: String
        /// A send may have reached the server (its outcome is not known).
        public let sentUnknown: Bool
        /// When the fence was written, as an instant.
        public let since: String

        public init(key: String, sentUnknown: Bool, since: String) {
            self.key = key
            self.sentUnknown = sentUnknown
            self.since = since
        }

        /// The fence written before the first send; nil when `key` is not a uuid4.
        public static func begin(key: String, now: Date) -> Record? {
            guard SGCustomerTime.isUUID4(key) else {
                return nil
            }
            return Record(key: key, sentUnknown: false, since: SGCustomerTime.instant(now))
        }

        /// The stored fence; nil when its key or `since` is unusable. A missing or malformed
        /// `sent_unknown` reads as `true` (nothing says the send did not go).
        public init?(jsonObject object: [String: Any]?) {
            guard let object, let key = object["key"] as? String, SGCustomerTime.isUUID4(key),
                  let since = object["since"] as? String, SGCustomerTime.isInstant(since) else {
                return nil
            }
            self.init(key: key, sentUnknown: SGCustomerJSON.bool(object["sent_unknown"]) ?? true, since: since)
        }

        /// For `SGConsentStore.setJSONObject(_:for: .deletion(tg:authority:))`.
        public var jsonObject: [String: Any] {
            return ["key": self.key, "sent_unknown": self.sentUnknown, "since": self.since]
        }

        /// The same fence once a send's outcome is unknown.
        public var outcomeUnknown: Record {
            return Record(key: self.key, sentUnknown: true, since: self.since)
        }
    }

    /// What the deletion screen says (I-4 maps it to `AccountDelete.*`).
    public enum Notice: String, CaseIterable, Equatable {
        /// `AccountDelete.Failed` + the web link.
        case failed
        /// `AccountDelete.NotLinked` + `AccountDelete.OpenWeb`.
        case notLinked = "not_linked"
        /// `AccountDelete.Error.Offline`.
        case offline
        /// `AccountDelete.Error.Unavailable`.
        case unavailable
        /// `AccountDelete.Error.RateLimited`.
        case rateLimited = "rate_limited"
        /// Still being sent (the server is running this key, or the session changed under the call).
        case inProgress = "in_progress"
    }

    /// The outcome the screen shows.
    public enum Report: Equatable {
        /// `AccountDelete.Done.*`.
        case deleted
        /// The fence is lifted: nothing was deleted.
        case notDeleted(Notice)
        /// The fence stays and the same key is sent again.
        case pending(Notice)
    }

    /// When an unresolved delete goes again.
    public enum Retry: Equatable {
        case immediately
        case after(TimeInterval)
        /// The route's backoff (`Retry-After` wins), and at the next first idle / foreground.
        case backoff
    }

    public enum Step: Equatable {
        /// The local erase.
        case deleted
        /// Remove the fence.
        case notDeleted(Notice)
        /// Persist this fence (when it changed) and send its key again.
        case retry(Record, Retry, Notice)
    }

    /// What one answer to a send of `record` means (the table above). `sessionEnd` is the account's
    /// (`SGEntitlement.sessionEnd`), read for a call that found no session.
    public static func decide(_ record: Record, outcome: SGCustomerDeleteOutcome, sessionEnd: SGCustomerLinkState.SessionEnd?) -> Step {
        switch outcome.outcome {
        case .ok:
            return .deleted
        case let .session(code, reason):
            if reason == SGCustomerWire.accountErasedReason {
                return .deleted
            }
            if record.sentUnknown, let code, SGCustomerDeletion.dropCodes.contains(code) {
                return .deleted
            }
            return .notDeleted(.failed)
        case .timedOut:
            return .retry(record.outcomeUnknown, .backoff, .offline)
        case .unavailable:
            return .retry(record.outcomeUnknown, .backoff, outcome.offline ? .offline : .unavailable)
        case let .terminal(status, code) where status == 409 && code == SGCustomerDeletion.inFlightCode:
            return .retry(record.outcomeUnknown, .after(SGCustomerDeletion.inFlightRetryDelay), .inProgress)
        case .rateLimited:
            guard record.sentUnknown else {
                return .notDeleted(.rateLimited)
            }
            return .retry(record, .backoff, .rateLimited)
        case .credentialChanged:
            return .retry(record, .immediately, .inProgress)
        case .notLinkedLocally:
            return SGCustomerDeletion.confirmsDeletion(sessionEnd, record: record) ? .deleted : .notDeleted(.notLinked)
        case .terminal, .payloadTooLarge, .accountMismatch, .accountNotLinked, .consentRequired, .notConfigured:
            return .notDeleted(.failed)
        }
    }

    public enum Resume: Equatable {
        /// Persist this fence (when it changed) and send its key.
        case send(Record)
        case deleted
        /// Remove the fence.
        case notDeleted(Notice)
    }

    /// A fence found unresolved and not being sent (first idle, foreground, its retry timer). Its
    /// earlier send may have reached the server — a timeout, or a process that ended mid-request
    /// before any answer was recorded — so it goes again as `sent_unknown`. Without a session there
    /// is nothing to send with: a drop that confirms the delete erases; otherwise the fence is lifted
    /// and the web page offered.
    public static func resume(_ record: Record, isLinked: Bool, sessionEnd: SGCustomerLinkState.SessionEnd?) -> Resume {
        let unknown = record.outcomeUnknown
        if isLinked {
            return .send(unknown)
        }
        return SGCustomerDeletion.confirmsDeletion(sessionEnd, record: unknown) ? .deleted : .notDeleted(.notLinked)
    }

    /// The account's session is gone in a way that confirms a delete already sent: `reason:
    /// account_erased`, or a drop code at or after `since` (whole seconds) with `sent_unknown`.
    public static func confirmsDeletion(_ sessionEnd: SGCustomerLinkState.SessionEnd?, record: Record) -> Bool {
        guard let sessionEnd else {
            return false
        }
        if sessionEnd.isAccountErased {
            return true
        }
        guard record.sentUnknown, SGCustomerDeletion.dropCodes.contains(sessionEnd.code),
              let since = SGCustomerTime.date(fromInstant: record.since) else {
            return false
        }
        return sessionEnd.at.timeIntervalSince1970.rounded(.down) >= since.timeIntervalSince1970
    }
}
