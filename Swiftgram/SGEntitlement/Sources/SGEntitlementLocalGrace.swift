import Foundation

/// Zenlygram — the local grace: **everything is free for a number of days after first launch,
/// then Pro** — in PAID mode only. While the signed monetization policy is free
/// (`SGEntitlementPolicy`) the evaluator never consults it and no "free until" date is shown; it
/// stays the existing paid-mode fallback.
///
/// The owner's rule, in one sentence, with no action from the user — no bind, no trial request, no
/// server call of its own. It applies to every gated action (`SGEntitlementGatedAction`, new
/// retained-history capture included) and grants the four base capabilities, never `"*"` and never
/// `.ai`. A verified token or a StoreKit subscription takes precedence over it while either grants;
/// once the window closes with neither, the decision degrades exactly as if the window had never
/// existed. A lapse only stops new creates and new capture: nothing is deleted, and history retained
/// meanwhile stays readable.
///
/// **The length (`days`).** How long the window lasts is the owner's number, not the app's: the
/// signed `local_grace_days` (0...30) of the LAST ACCEPTED monetization policy when that policy is
/// ver 3 (`SGEntitlementPolicy.localGraceDays`), and `defaultDays` — the seven days this grace
/// always had — under a ver-1 / ver-2 policy or none, which is also what an install has between
/// updating to this build and its first ver-3 policy. The length is combined at evaluation time
/// (`lasting(days:)`), like the paid-policy mark below: it is in neither record's bytes, is never
/// stored on its own and is never taken from anything unsigned — the stored signed policy token is
/// the only place it lives, so every process that re-verifies that token (the app, an extension)
/// derives the same length. A newly accepted policy therefore applies to the very next evaluation:
/// a shorter length can end a running window, a longer one re-opens a closed one (nothing
/// remembers "it ended" — the window is always `startsAt + days`), and **0 means the grace never
/// grants**: an install with nothing else granting is "not active" as soon as it reads the paid
/// policy, and there is no "free until" date to show.
///
/// **Two records, one window (D9).** `firstLaunchAt` is minted ONCE, on the first evaluation, from
/// `SGEntitlementClock.effectiveNow()`. Because every install starts FREE and the owner enables
/// paid mode later, a window counted from first launch alone would have closed long ago for most
/// installs the day the flip lands, locking their creates out the minute the policy arrives. So a
/// SECOND record, `firstPaidPolicyAt` (`SGEntitlementPaidModeMark`), is minted once more — on the
/// install's first evaluation under an adopted PAID policy — and the paid-mode window is the LATER
/// of the two: `startsAt = max(firstLaunchAt, firstPaidPolicyAt)`. Every install gets the same
/// days from the flip it would have had from first launch; neither record is ever re-minted, so a
/// later free → paid flip re-bases nothing, and neither does a change of the length: the start
/// stays, only the end moves. The mark is minted whatever the length — under a 0-day policy too —
/// so a later, longer length counts from the moment the flip reached this install. The window of
/// an install first launched AFTER the flip starts at its first launch, as before.
///
/// Both records are persisted in the Keychain, in the app group's shared access group next to the
/// device id (`SGEntitlementStore`): per INSTALL, not per Telegram account, so logging out,
/// switching accounts, or clearing the app group's UserDefaults does not re-grant them, and the
/// Notification Service Extension can read them. A Keychain item in that class survives
/// reinstalling the app; only a Keychain wipe (a device erase) resets the window. That is accepted
/// — it is a fresh device, and this is a GPL client whose anti-tamper stops at the clock mark (see
/// `SGEntitlementClock`).
///
/// "Minted once" also means a record that merely could not be READ is never re-minted: before the
/// first unlock after a reboot the Keychain class it lives in is unavailable, and a launch there (a
/// VoIP push) grants the window in memory for that evaluation only — never cached, never mirrored —
/// and reads the real record on the next one (`SGEntitlement.resolveLocalGrace`,
/// `SGEntitlement.resolvePaidModeMark`).
///
/// **The clock.** The window is evaluated against `effectiveNow`, the clock high-water mark — but
/// that mark is fed only by server time, and the population this grace exists for (never bound,
/// never purchased) never sees any. So the record carries its own high-water mark, `lastSeenAt`:
/// the latest evaluation time this install has observed, advanced on every evaluation and
/// persisted as it moves. The window is `max(now, lastSeenAt) < endsAt`, so winding the device
/// clock backwards does not re-open a window that has closed, with or without a server mark;
/// winding it forwards only ends it sooner. It is scoped to this record on purpose: a wall-clock
/// reading is not a server assertion and must never feed the global mark, where a clock once set
/// far ahead would expire every token forever (invariant I2). Keychain-less builds (fake-codesigned
/// simulator / DEBUG, `SGProtectedKeychain.isKeychainlessBuild`) keep the records in the app-group
/// suite instead, so there and only there a defaults wipe does reset them.
public struct SGEntitlementLocalGrace: Codable, Equatable {
    /// The window's length while no signed policy names one — a ver-1 / ver-2 policy, or none: the
    /// seven days this grace always had.
    public static let defaultDays = 7
    /// The contract's ceiling for the signed `local_grace_days`
    /// (`SGEntitlementPolicyVerifier.maximumLocalGraceDays`).
    public static let maximumDays = 30
    /// `defaultDays`, in seconds: seven days, exactly.
    public static let defaultDuration: TimeInterval = TimeInterval(SGEntitlementLocalGrace.defaultDays) * 86400

    /// The `effectiveNow` of the first evaluation on this install.
    public let firstLaunchAt: Date
    /// The latest evaluation time observed on this install (never earlier than `firstLaunchAt`).
    /// The window's own high-water mark; see the type comment.
    public let lastSeenAt: Date
    /// D9 — the `effectiveNow` of this install's first evaluation under an adopted PAID policy, from
    /// its own record (`SGEntitlementPaidModeMark`); nil before paid mode was ever adopted, and
    /// whenever the grace is combined for free mode, where it is not consulted. NOT part of this
    /// record's bytes: `encode(to:)` omits it and `init(from:)` leaves it nil, because it is a
    /// separate Keychain item combined at evaluation time (`rebased(firstPaidPolicyAt:)`).
    public let firstPaidPolicyAt: Date?
    /// The window's length in whole days, 0...`maximumDays`: the last accepted signed policy's
    /// (`SGEntitlementPolicyState.localGraceDays`), combined at evaluation time (`lasting(days:)`);
    /// `defaultDays` for a record nothing was combined with. 0 means the grace never grants. NOT
    /// part of this record's bytes either: `encode(to:)` omits it and `init(from:)` leaves the
    /// default, so the length is never stored outside the signed policy token it came from.
    public let days: Int

    public init(firstLaunchAt: Date, lastSeenAt: Date? = nil, firstPaidPolicyAt: Date? = nil, days: Int = SGEntitlementLocalGrace.defaultDays) {
        self.firstLaunchAt = firstLaunchAt
        self.lastSeenAt = max(firstLaunchAt, lastSeenAt ?? firstLaunchAt)
        self.firstPaidPolicyAt = firstPaidPolicyAt
        // The verifier already refuses a policy outside the contract's range; the window itself
        // can never be negative or longer than the contract allows, whoever builds it.
        self.days = min(max(days, 0), SGEntitlementLocalGrace.maximumDays)
    }

    private enum CodingKeys: String, CodingKey {
        case firstLaunchAt
        case lastSeenAt
    }

    /// A record written before `lastSeenAt` existed decodes with the mark at `firstLaunchAt`. The
    /// paid-policy mark and the length are never in these bytes: the decoded value is un-rebased
    /// and of the default length.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let firstLaunchAt = try container.decode(Date.self, forKey: .firstLaunchAt)
        let lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        self.init(firstLaunchAt: firstLaunchAt, lastSeenAt: lastSeenAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.firstLaunchAt, forKey: .firstLaunchAt)
        try container.encode(self.lastSeenAt, forKey: .lastSeenAt)
    }

    /// Where the window starts: first launch, or the first adopted paid policy when that came later
    /// (D9). The later of the two windows is the one that starts later, since both last `duration`.
    /// The length never moves it.
    public var startsAt: Date {
        guard let firstPaidPolicyAt = self.firstPaidPolicyAt else {
            return self.firstLaunchAt
        }
        return max(self.firstLaunchAt, firstPaidPolicyAt)
    }

    /// `days`, in seconds — whole days exactly: `endsAt` is `startsAt + duration`, and the window
    /// is `now < endsAt`: seven days are seven days, not seven days plus a second.
    public var duration: TimeInterval {
        return TimeInterval(self.days) * 86400
    }

    /// The instant the window closes — what the paywall / status UI shows as "free until". For a
    /// 0-day grace it is `startsAt` itself, and never shown: that window is never active.
    public var endsAt: Date {
        return self.startsAt.addingTimeInterval(self.duration)
    }

    /// The window at `now`, floored at the record's own high-water mark. A 0-day grace is never
    /// active — not even under a clock wound back before its start.
    public func isActive(at now: Date) -> Bool {
        guard self.days > 0 else {
            return false
        }
        return max(now, self.lastSeenAt) < self.endsAt
    }

    /// The record after observing an evaluation at `now`: the high-water mark only ever moves forward.
    public func observing(_ now: Date) -> SGEntitlementLocalGrace {
        guard now > self.lastSeenAt else {
            return self
        }
        return SGEntitlementLocalGrace(firstLaunchAt: self.firstLaunchAt, lastSeenAt: now, firstPaidPolicyAt: self.firstPaidPolicyAt, days: self.days)
    }

    /// This first-launch record combined with the install's paid-policy mark (D9): the same
    /// `firstLaunchAt`, high-water mark and length, the window re-based to the later start. nil
    /// combines nothing (free mode, or paid mode never adopted on this install).
    public func rebased(firstPaidPolicyAt: Date?) -> SGEntitlementLocalGrace {
        return SGEntitlementLocalGrace(firstLaunchAt: self.firstLaunchAt, lastSeenAt: self.lastSeenAt, firstPaidPolicyAt: firstPaidPolicyAt, days: self.days)
    }

    /// This record combined with the length the last accepted signed policy names
    /// (`SGEntitlementPolicyState.localGraceDays`): the same start and high-water mark, the window
    /// ending `days` after its start. The start is never re-based by it — a shorter length can
    /// close a window that was open, a longer one re-opens a closed one.
    public func lasting(days: Int) -> SGEntitlementLocalGrace {
        return SGEntitlementLocalGrace(firstLaunchAt: self.firstLaunchAt, lastSeenAt: self.lastSeenAt, firstPaidPolicyAt: self.firstPaidPolicyAt, days: days)
    }
}

/// Zenlygram — the second minted-once record behind the local grace (D9, see
/// `SGEntitlementLocalGrace`): the `effectiveNow` of this install's first evaluation under an
/// adopted PAID policy. Minted by the main app on that evaluation — which is the recompute the
/// adoption itself triggers, so it is the moment the flip reached this install — persisted as its
/// own Keychain item (`SGEntitlementStore.paidModeMarkAccount`) under exactly the rules of
/// `firstLaunchAt`: never re-minted, never cleared by a logout, never written by an extension, and
/// never minted over a record that merely could not be read (`SGEntitlement.resolvePaidModeMark`).
public struct SGEntitlementPaidModeMark: Codable, Equatable {
    public let firstPaidPolicyAt: Date

    public init(firstPaidPolicyAt: Date) {
        self.firstPaidPolicyAt = firstPaidPolicyAt
    }
}
