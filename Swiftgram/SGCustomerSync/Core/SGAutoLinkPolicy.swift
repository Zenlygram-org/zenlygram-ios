import Foundation

/// Zenlygram — an account's automatic-link schedule, `zg.autolink.v1.<tg>@<authority>` (design 40
/// §4.4, §8, §8.2): `{"v":1,"starts":[instant…24h],"failures":Int,"next_at":instant?,
/// "paused_until":instant?,"suppressed":"user_unlink"?}`. Times are whole seconds.
/// `SGConsentStore.grant` lifts `suppressed` by removing that key from the stored object.
public struct SGAutoLinkRecord: Equatable {
    public static let formatVersion = 1
    /// `suppressed` after a user-initiated Unlink (compliance C-13).
    public static let userUnlink = "user_unlink"

    /// The `bind/start`s of the trailing 24 h.
    public var starts: [Date]
    /// Consecutive failures on the retry ladder.
    public var failures: Int
    /// No attempt before this.
    public var nextAt: Date?
    /// `bind_conflict` pauses the account's automatic link until then.
    public var pausedUntil: Date?
    /// Why the automatic link is off (`user_unlink`); any value suppresses it.
    public var suppressed: String?

    public init(starts: [Date] = [], failures: Int = 0, nextAt: Date? = nil, pausedUntil: Date? = nil, suppressed: String? = nil) {
        self.starts = starts.map(SGAutoLinkPolicy.wholeSeconds)
        self.failures = max(0, failures)
        self.nextAt = nextAt.map(SGAutoLinkPolicy.wholeSeconds)
        self.pausedUntil = pausedUntil.map(SGAutoLinkPolicy.wholeSeconds)
        self.suppressed = suppressed
    }

    /// The stored record; absent → a fresh one. Each field is read on its own, a malformed one as
    /// absent, so a damaged schedule never loses the Unlink suppression.
    public init(jsonObject object: [String: Any]?) {
        let object = object ?? [:]
        let starts = ((object["starts"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(SGCustomerTime.date(fromInstant:)) }
        let instant: (String) -> Date? = { key in
            return (object[key] as? String).flatMap(SGCustomerTime.date(fromInstant:))
        }
        self.init(
            starts: starts,
            failures: SGCustomerJSON.integer(object["failures"]) ?? 0,
            nextAt: instant("next_at"),
            pausedUntil: instant("paused_until"),
            suppressed: (object["suppressed"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// For `SGConsentStore.setJSONObject(_:for: .autoLink(tg:authority:))`.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "v": SGAutoLinkRecord.formatVersion,
            "starts": self.starts.sorted().map(SGCustomerTime.instant),
            "failures": self.failures,
        ]
        object["next_at"] = self.nextAt.map(SGCustomerTime.instant)
        object["paused_until"] = self.pausedUntil.map(SGCustomerTime.instant)
        object["suppressed"] = self.suppressed
        return object
    }

    public var isSuppressed: Bool {
        return self.suppressed != nil
    }

    /// After a user-initiated Unlink (`SGCustomerLinkEvents.userWillUnlink`).
    public func suppressingForUnlink() -> SGAutoLinkRecord {
        var record = self
        record.suppressed = SGAutoLinkRecord.userUnlink
        return record
    }

    /// After a manual link (`SGCustomerLinkEvents.userDidLink`); a new grant lifts it in the store.
    public func liftingSuppression() -> SGAutoLinkRecord {
        var record = self
        record.suppressed = nil
        return record
    }

    /// The record as an attempt begins at `now`: its start counted (written BEFORE the attempt, so
    /// a process that dies mid-attempt still counts it), starts older than 24 h dropped.
    public func recordingStart(at now: Date) -> SGAutoLinkRecord {
        var record = self.pruned(now: now)
        record.starts.append(SGAutoLinkPolicy.wholeSeconds(now))
        return record
    }

    /// Starts outside the trailing window dropped (either side of `now`: a clock set back does not
    /// free the limit).
    func pruned(now: Date) -> SGAutoLinkRecord {
        var record = self
        record.starts = self.starts.filter { abs($0.timeIntervalSince(now)) < SGAutoLinkPolicy.startWindow }.sorted()
        return record
    }
}

/// Zenlygram — the install-wide attest-null ladder, `zg.autolink.install.v1@<authority>` =
/// `{"attest_null":Int,"app_version":ver,"next_at":instant?}` (design 40 §8): while the server offers
/// no attestation (production attest inert), three consecutive `attest_unavailable` starts hold
/// every account's automatic link 24 h, then 72 h, then 7 d. Reset by a new app version and by any
/// start that offers an attest block.
public struct SGAutoLinkInstallRecord: Equatable {
    /// Consecutive starts that offered no attestation.
    public var attestNull: Int
    /// The app version the counter belongs to.
    public var appVersion: String?
    /// No automatic link on the install before this.
    public var nextAt: Date?

    public init(attestNull: Int = 0, appVersion: String? = nil, nextAt: Date? = nil) {
        self.attestNull = max(0, attestNull)
        self.appVersion = appVersion
        self.nextAt = nextAt.map(SGAutoLinkPolicy.wholeSeconds)
    }

    /// The stored record; absent or malformed fields read as absent.
    public init(jsonObject object: [String: Any]?) {
        let object = object ?? [:]
        self.init(
            attestNull: SGCustomerJSON.integer(object["attest_null"]) ?? 0,
            appVersion: object["app_version"] as? String,
            nextAt: (object["next_at"] as? String).flatMap(SGCustomerTime.date(fromInstant:))
        )
    }

    /// For `SGConsentStore.setJSONObject(_:for: .autoLinkInstall(authority:))`.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["attest_null": self.attestNull]
        object["app_version"] = self.appVersion
        object["next_at"] = self.nextAt.map(SGCustomerTime.instant)
        return object
    }

    /// The record for `version` (`ver`, clipped): a fresh ladder when the app version changed.
    public func forAppVersion(_ version: String) -> SGAutoLinkInstallRecord {
        let version = SGConsentEvent.clippedVersion(version)
        guard self.appVersion != version else {
            return self
        }
        return SGAutoLinkInstallRecord(attestNull: 0, appVersion: version, nextAt: nil)
    }

    /// A start offered an attest block (or an account linked): the ladder starts afresh.
    func reset() -> SGAutoLinkInstallRecord {
        return SGAutoLinkInstallRecord(attestNull: 0, appVersion: self.appVersion, nextAt: nil)
    }
}

/// Zenlygram — when one account links automatically (design 40 §8, contract §6.6): the preconditions
/// and the schedule after each outcome, pure. `SGAutoLinkRunner` (I-3) runs
/// `SGEntitlement.bindWithTelegramAttestation` when `SGCustomerCoordinatorCore` says `.autoLink`, at
/// most one at a time on the install.
///
/// Preconditions (all): the record is `granted`, the latest grant not rejected, no server-ended
/// link pending (§8.1); `bindPermission == .allowed`; not linked for the current origin; not
/// erasing; not `suppressed` (§8.2); first idle passed + a uniform 0–30 s jitter drawn once per
/// process; outside the account's `next_at` / `paused_until` and the install-wide `next_at`; ≤ 6
/// `bind/start` in the trailing 24 h for the account; no other automatic link in flight; no manual
/// bind in progress (`isBindInProgress`).
///
/// | outcome | next attempt |
/// |---|---|
/// | `.linked`, `.alreadyLinked` | done; failures reset; the install ladder reset |
/// | `.attestUnavailable` | account +6 h; install `attest_null` += 1; from the 3rd in a row the install waits 24 h, then 72 h, then 7 d |
/// | `.consentStale` | the grant is normalised (`needs_reconsent` / `link_ended`): stops until a new grant |
/// | `.notPermitted` | stops until the consent state or the permission changes |
/// | `.refused("bind_conflict")` | `paused_until` = +24 h |
/// | `.rateLimited(n)`, `.paused(n)` | `max(n, ladder)` |
/// | `.telegramUnavailable`, `.offline`, `.expired`, `.notStored`, any other `.refused` | ladder 60 s, 5 min, 30 min, 2 h, 6 h, then 24 h, each ±20 % |
/// | `.superseded`, `.bindInProgress` | +5 min, no failure counted |
///
/// A start that offered an attest block resets the install ladder; a `sentNothing` outcome
/// (`.alreadyLinked`, `.bindInProgress`, `.notPermitted`, `.notConfigured`) gives back the start
/// counted for it. `.notPermitted` also ends a run that lost its permission after its `bind/start`
/// (design 40 §7.2). Its `bind/start` may have gone out; it still gives the start back and records
/// no `link.attempt`, so once the run may start again (after a re-grant, or after an unreadable
/// store, at the next consent or entitlement change) the 6-per-24 h cap counts one start fewer than
/// were sent.
public enum SGAutoLinkPolicy {
    /// At most this many automatic `bind/start` per account in `startWindow`.
    public static let maxStarts = 6
    public static let startWindow: TimeInterval = 86_400
    /// The failure ladder (contract §6.6), each ±`ladderSpread`.
    public static let ladder: [TimeInterval] = [60, 300, 1_800, 7_200, 21_600, 86_400]
    public static let ladderSpread = 0.2
    /// `.attestUnavailable`: the account waits this long.
    public static let attestUnavailableDelay: TimeInterval = 6 * 3_600
    /// Consecutive attest-null starts before the install ladder applies.
    public static let installThreshold = 3
    public static let installLadder: [TimeInterval] = [86_400, 3 * 86_400, 7 * 86_400]
    /// 409 `bind_conflict` pauses the account this long.
    public static let conflictPause: TimeInterval = 86_400
    public static let conflictCode = "bind_conflict"
    /// `.superseded` / `.bindInProgress`: another bind was live; try again after this.
    public static let contendedDelay: TimeInterval = 300
    /// The first-idle jitter is uniform in [0, this).
    public static let maxFirstIdleJitter: TimeInterval = 30

    /// The server codes a failed attempt reports as its `error_code` (§8).
    public static let serverCodes: Set<String> = ["bind_conflict", "attest_invalid", "attest_stale", "attest_mismatch", "bind_not_found", "bind_expired"]
    /// The local attest reasons of §7.3 (`SGBindAttest.sgBindAttestEvidence`).
    public static let localAttestCodes: Set<String> = ["attest_bot_not_found", "attest_bot_mismatch", "attest_no_main_app", "attest_webview_failed", "attest_no_init_data", "timeout"]

    /// `SGEntitlementAttestedBindOutcome` as the core reads it (`SGAutoLinkRunner` maps it case by
    /// case; `linked`'s merge-conflict flag and `refused`'s status do not change the schedule).
    public enum Outcome: Equatable {
        case linked
        /// The account already held a session: nothing was sent.
        case alreadyLinked
        /// A manual bind for the account was live: nothing was sent.
        case bindInProgress
        case attestUnavailable
        /// The Telegram side produced no `initData`; `reason` is a local attest code (§7.3).
        case telegramUnavailable(reason: String)
        /// A coded refusal (`bind_conflict`, `attest_invalid`, `bind_not_found`, …).
        case refused(code: String)
        /// 409 `consent_stale`.
        case consentStale
        /// `bindPermission` was not `.allowed`. From the preflight or `beginBind`'s checks before
        /// its start nothing was sent. When it stopped being `.allowed` later (a withdrawal, an
        /// erasure, a grant that became unusable, or the consent store unreadable after a device
        /// lock; at `beginBind`'s re-read before an automatic consent-fallback retry, or later in
        /// the run), nothing more was sent, but its `bind/start`, and possibly the Telegram
        /// request, `/bind/attest` and polls (a poll in flight may have consumed the bind), may
        /// already have gone out. Read as `sentNothing` either way.
        case notPermitted
        case rateLimited(retryAfter: Int)
        /// 503 `bind_paused`.
        case paused(retryAfter: Int?)
        case offline
        case expired
        case notStored
        case superseded
        /// An extension or a build without the backend: nothing was sent.
        case notConfigured

        /// The attempt gives back the start counted for it and records no `link.attempt`: it sent
        /// no `bind/start`, or (`.notPermitted`) its permission changed after its start.
        public var sentNothing: Bool {
            switch self {
            case .alreadyLinked, .bindInProgress, .notPermitted, .notConfigured:
                return true
            default:
                return false
            }
        }
    }

    /// Why the account may not link automatically right now.
    public enum Blocker: String, CaseIterable, Equatable {
        case unreadable
        case notGranted = "not_granted"
        case grantRejected = "grant_rejected"
        case linkEnded = "link_ended"
        case erasing
        case linked
        case notPermitted = "not_permitted"
        case suppressed
        /// A `.notPermitted` / `.notConfigured` outcome: until the consent state or the permission
        /// changes.
        case stopped
        case firstIdle = "first_idle"
        case inFlight = "in_flight"
        case bindInProgress = "bind_in_progress"
    }

    public struct Inputs: Equatable {
        /// The consent store is readable.
        public var readable: Bool
        public var state: SGConsentState
        public var latestGrantRejected: Bool
        /// `SGCustomerLinkState.linkEnded(...)`.
        public var linkEnded: Bool
        /// `zg.cs.delete…` present.
        public var erasing: Bool
        /// A session for the current origin (`SGEntitlement.isLinked`).
        public var isLinked: Bool
        /// `SGEntitlement.shared.bindPermission(accountPeerId:) == .allowed`.
        public var bindPermissionAllowed: Bool
        /// `SGEntitlement.shared.isBindInProgress(accountPeerId:)`.
        public var bindInProgress: Bool
        /// A `.notPermitted` / `.notConfigured` outcome since the last consent or permission change.
        public var stopped: Bool
        public var record: SGAutoLinkRecord
        public var install: SGAutoLinkInstallRecord
        /// When first idle passed in this process (nil: not yet).
        public var firstIdleAt: Date?
        /// Drawn once per process (`firstIdleJitter(_:)`).
        public var firstIdleJitter: TimeInterval
        /// Another automatic link is running on the install.
        public var inFlight: Bool

        public init(readable: Bool, state: SGConsentState, latestGrantRejected: Bool = false, linkEnded: Bool = false, erasing: Bool = false, isLinked: Bool = false, bindPermissionAllowed: Bool = false, bindInProgress: Bool = false, stopped: Bool = false, record: SGAutoLinkRecord = SGAutoLinkRecord(), install: SGAutoLinkInstallRecord = SGAutoLinkInstallRecord(), firstIdleAt: Date?, firstIdleJitter: TimeInterval = 0, inFlight: Bool = false) {
            self.readable = readable
            self.state = state
            self.latestGrantRejected = latestGrantRejected
            self.linkEnded = linkEnded
            self.erasing = erasing
            self.isLinked = isLinked
            self.bindPermissionAllowed = bindPermissionAllowed
            self.bindInProgress = bindInProgress
            self.stopped = stopped
            self.record = record
            self.install = install
            self.firstIdleAt = firstIdleAt
            self.firstIdleJitter = firstIdleJitter
            self.inFlight = inFlight
        }
    }

    public enum Decision: Equatable {
        case run
        /// Every precondition holds except time: re-evaluate then.
        case wait(until: Date)
        case blocked(Blocker)
    }

    public static func decide(_ inputs: Inputs, now: Date) -> Decision {
        guard inputs.readable else {
            return .blocked(.unreadable)
        }
        guard inputs.state == .granted else {
            return .blocked(.notGranted)
        }
        guard !inputs.latestGrantRejected else {
            return .blocked(.grantRejected)
        }
        guard !inputs.linkEnded else {
            return .blocked(.linkEnded)
        }
        guard !inputs.erasing else {
            return .blocked(.erasing)
        }
        guard !inputs.isLinked else {
            return .blocked(.linked)
        }
        guard inputs.bindPermissionAllowed else {
            return .blocked(.notPermitted)
        }
        guard !inputs.record.isSuppressed else {
            return .blocked(.suppressed)
        }
        guard !inputs.stopped else {
            return .blocked(.stopped)
        }
        guard let firstIdleAt = inputs.firstIdleAt else {
            return .blocked(.firstIdle)
        }
        guard !inputs.inFlight else {
            return .blocked(.inFlight)
        }
        guard !inputs.bindInProgress else {
            return .blocked(.bindInProgress)
        }
        var until = firstIdleAt.addingTimeInterval(max(0, inputs.firstIdleJitter))
        for limit in [inputs.record.nextAt, inputs.record.pausedUntil, inputs.install.nextAt] {
            if let limit {
                until = max(until, limit)
            }
        }
        let recent = inputs.record.pruned(now: now).starts
        if recent.count >= SGAutoLinkPolicy.maxStarts {
            until = max(until, recent[recent.count - SGAutoLinkPolicy.maxStarts].addingTimeInterval(SGAutoLinkPolicy.startWindow))
        }
        return until > now ? .wait(until: until) : .run
    }

    /// The account's record and the install record after `outcome` (the table above).
    /// `attestOffered`: the start offered an attest block (the runner's attest closure ran).
    public static func next(after outcome: Outcome, attestOffered: Bool, record: SGAutoLinkRecord, install: SGAutoLinkInstallRecord, now: Date, random: () -> Double) -> (record: SGAutoLinkRecord, install: SGAutoLinkInstallRecord) {
        var record = record.pruned(now: now)
        var install = attestOffered ? install.reset() : install
        if outcome.sentNothing, let last = record.starts.indices.last {
            // The start counted when the attempt began is given back: none went out, or
            // (`.notPermitted`) the permission changed after it did.
            record.starts.remove(at: last)
        }
        func after(_ delay: TimeInterval) -> Date {
            return SGAutoLinkPolicy.wholeSeconds(now.addingTimeInterval(delay))
        }
        // A failure moves the ladder one rung; `Retry-After` wins when it is longer.
        var failureMinimum: TimeInterval?
        switch outcome {
        case .linked, .alreadyLinked:
            record.failures = 0
            record.nextAt = nil
            record.pausedUntil = nil
            install = install.reset()
        case .attestUnavailable:
            record.nextAt = after(SGAutoLinkPolicy.attestUnavailableDelay)
            if !attestOffered {
                install.attestNull += 1
                if install.attestNull >= SGAutoLinkPolicy.installThreshold {
                    let rung = min(install.attestNull - SGAutoLinkPolicy.installThreshold, SGAutoLinkPolicy.installLadder.count - 1)
                    install.nextAt = after(SGAutoLinkPolicy.installLadder[rung])
                }
            }
        case .consentStale, .notPermitted, .notConfigured:
            // Stops: a new grant, or a change of the permission, re-evaluates.
            break
        case let .refused(code) where code == SGAutoLinkPolicy.conflictCode:
            record.pausedUntil = after(SGAutoLinkPolicy.conflictPause)
        case let .rateLimited(retryAfter):
            failureMinimum = TimeInterval(max(0, retryAfter))
        case let .paused(retryAfter):
            failureMinimum = TimeInterval(max(0, retryAfter ?? 0))
        case .telegramUnavailable, .offline, .expired, .notStored, .refused:
            failureMinimum = 0
        case .superseded, .bindInProgress:
            record.nextAt = after(SGAutoLinkPolicy.contendedDelay)
        }
        if let failureMinimum {
            record.failures += 1
            record.nextAt = after(max(failureMinimum, SGAutoLinkPolicy.ladderDelay(failures: record.failures, random: random)))
        }
        return (record, install)
    }

    /// The delay after the `failures`-th consecutive failure: 60 s, 5 min, 30 min, 2 h, 6 h, then
    /// 24 h, times a uniform factor in [0.8, 1.2] (`random` draws from [0, 1)).
    public static func ladderDelay(failures: Int, random: () -> Double) -> TimeInterval {
        let rung = min(max(failures, 1), SGAutoLinkPolicy.ladder.count) - 1
        let draw = min(max(random(), 0), 1)
        return SGAutoLinkPolicy.ladder[rung] * (1 - SGAutoLinkPolicy.ladderSpread + 2 * SGAutoLinkPolicy.ladderSpread * draw)
    }

    /// The process's first-idle jitter, uniform in [0, 30 s).
    public static func firstIdleJitter(_ random: () -> Double) -> TimeInterval {
        return min(max(random(), 0), 1) * SGAutoLinkPolicy.maxFirstIdleJitter
    }

    /// `link.attempt{trigger: auto, method: attest, outcome, error_code?, duration_s}` for the
    /// attempt, or nil for a `sentNothing` outcome.
    public static func linkAttempt(_ outcome: Outcome, durationS: Int) -> SGAnalyticsEvent? {
        guard !outcome.sentNothing else {
            return nil
        }
        if case .linked = outcome {
            return .linkAttempt(trigger: .auto, method: .attest, outcome: .success, errorCode: nil, durationS: durationS)
        }
        return .linkAttempt(trigger: .auto, method: .attest, outcome: .failed, errorCode: SGAutoLinkPolicy.errorCode(outcome) ?? .unknown, durationS: durationS)
    }

    /// A failed attempt's `error_code` (§8): the server code, the local attest reason, `offline`,
    /// else `unknown`; nil for a link or a `sentNothing` outcome.
    public static func errorCode(_ outcome: Outcome) -> SGAnalyticsErrorCode? {
        switch outcome {
        case .linked, .alreadyLinked, .bindInProgress, .notPermitted, .notConfigured:
            return nil
        case .attestUnavailable:
            return .backend("attest_unavailable")
        case let .telegramUnavailable(reason):
            return SGAutoLinkPolicy.localAttestCodes.contains(reason) ? .backend(reason) : .unknown
        case let .refused(code):
            return SGAutoLinkPolicy.serverCodes.contains(code) ? .backend(code) : .unknown
        case .consentStale:
            return .backend(SGCustomerWire.consentStaleCode)
        case .rateLimited:
            return .backend("rate_limited")
        case .paused:
            return .backend("bind_paused")
        case .offline:
            return .offline
        case .expired:
            return .backend("bind_expired")
        case .notStored, .superseded:
            return .unknown
        }
    }

    static func wholeSeconds(_ date: Date) -> Date {
        return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
