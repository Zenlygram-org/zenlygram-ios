import Foundation

/// Zenlygram — the local grace: **everything is free for 7 days after first launch, then Pro** —
/// in PAID mode only. While the signed monetization policy is free (`SGEntitlementPolicy`) the
/// evaluator never consults it and no "free until" date is shown; it stays the existing paid-mode
/// fallback.
///
/// The owner's rule, in one sentence, with no action from the user — no bind, no trial request, no
/// server. It applies to every gated action (`SGEntitlementGatedAction`, new retained-history
/// capture included) and grants the four base capabilities, never `"*"` and never
/// `.ai`. A verified token or a StoreKit subscription takes precedence over it while either grants;
/// once the window closes with neither, the decision degrades exactly as if the window had never
/// existed. A lapse only stops new creates and new capture: nothing is deleted, and history retained
/// meanwhile stays readable.
///
/// **Two records, one window (D9).** `firstLaunchAt` is minted ONCE, on the first evaluation, from
/// `SGEntitlementClock.effectiveNow()`. Because every install starts FREE and the owner enables
/// paid mode later, a window counted from first launch alone would have closed long ago for most
/// installs the day the flip lands, locking their creates out the minute the policy arrives. So a
/// SECOND record, `firstPaidPolicyAt` (`SGEntitlementPaidModeMark`), is minted once more — on the
/// install's first evaluation under an adopted PAID policy — and the paid-mode window is the LATER
/// of the two: `startsAt = max(firstLaunchAt, firstPaidPolicyAt)`. Every install gets the same seven
/// days from the flip it would have had from first launch; neither record is ever re-minted, so a
/// later free → paid flip re-bases nothing. The window of an install first launched AFTER the flip
/// starts at its first launch, as before.
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
    /// Seven days, exactly: `endsAt` is `startsAt + duration`, and the window is `now < endsAt`
    /// — seven days, not seven days plus a second.
    public static let duration: TimeInterval = 7 * 86400

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

    public init(firstLaunchAt: Date, lastSeenAt: Date? = nil, firstPaidPolicyAt: Date? = nil) {
        self.firstLaunchAt = firstLaunchAt
        self.lastSeenAt = max(firstLaunchAt, lastSeenAt ?? firstLaunchAt)
        self.firstPaidPolicyAt = firstPaidPolicyAt
    }

    private enum CodingKeys: String, CodingKey {
        case firstLaunchAt
        case lastSeenAt
    }

    /// A record written before `lastSeenAt` existed decodes with the mark at `firstLaunchAt`. The
    /// paid-policy mark is never in these bytes: the decoded value is un-rebased.
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
    public var startsAt: Date {
        guard let firstPaidPolicyAt = self.firstPaidPolicyAt else {
            return self.firstLaunchAt
        }
        return max(self.firstLaunchAt, firstPaidPolicyAt)
    }

    /// The instant the window closes — what the paywall / status UI shows as "free until".
    public var endsAt: Date {
        return self.startsAt.addingTimeInterval(SGEntitlementLocalGrace.duration)
    }

    /// The window at `now`, floored at the record's own high-water mark.
    public func isActive(at now: Date) -> Bool {
        return max(now, self.lastSeenAt) < self.endsAt
    }

    /// The record after observing an evaluation at `now`: the high-water mark only ever moves forward.
    public func observing(_ now: Date) -> SGEntitlementLocalGrace {
        guard now > self.lastSeenAt else {
            return self
        }
        return SGEntitlementLocalGrace(firstLaunchAt: self.firstLaunchAt, lastSeenAt: now, firstPaidPolicyAt: self.firstPaidPolicyAt)
    }

    /// This first-launch record combined with the install's paid-policy mark (D9): the same
    /// `firstLaunchAt` and high-water mark, the window re-based to the later start. nil combines
    /// nothing (free mode, or paid mode never adopted on this install).
    public func rebased(firstPaidPolicyAt: Date?) -> SGEntitlementLocalGrace {
        return SGEntitlementLocalGrace(firstLaunchAt: self.firstLaunchAt, lastSeenAt: self.lastSeenAt, firstPaidPolicyAt: firstPaidPolicyAt)
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
