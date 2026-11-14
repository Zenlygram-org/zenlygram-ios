import Foundation
import Postbox

/// Zenlygram — brute-force throttle for Chat Lock credentials, persisted in UserDefaults so dismissing
/// and re-presenting a PIN screen cannot reset it.
///
/// Every credential has its own scope, so a lockout on one chat's PIN neither blocks the master PIN
/// (the recovery path) nor another chat's own counter. After 5 consecutive failures in a scope, entries are
/// rejected WITHOUT being checked for an exponentially growing window; that is what makes a 4-digit PIN
/// infeasible to brute-force.
///
/// Shared budget: failures in `.chat(*)` and `.master` also count toward one global counter, and every
/// `.chat(*)` scope is gated by it as well. Without it, a PIN the owner reused for N chats (and the master)
/// would give a guesser N+1 separate budgets per window. `.master` feeds the global counter but is gated only
/// by its own, so hammering chats can never lock out the recovery path.
///
/// SG: Chat Lock — what may shrink the shared budget. A correct entry (PIN or biometric) in `.chat(p)` proves
/// only p's credential, and anyone holding the unlocked phone can lock a spare chat with a PIN of their own
/// choosing, so it must NOT clear the global counter (that would hand back a fresh budget between guesses at
/// another chat's PIN). It clears p's own scope and withdraws from the global counter only p's own failures
/// that still count there (see `reset`), i.e. the owner's typos on p. The shared budget otherwise shrinks only
/// by time (the monotonic 24 h decay) or with a proof that outranks every chat PIN: a correct master entry
/// (`reset(.master)`, which can already remove any chat's lock) or the device-owner "Reset Chat Lock"
/// (`resetAll`). Setting a new chat PIN is therefore left unthrottled: a spare chat gets no budget of its own
/// (`remaining(.chat)` is gated by the global counter) and its successes refund nothing but its own failures.
///
/// Time: lockouts and the 24 h decay are measured on a clock the user cannot set — `mach_continuous_time`,
/// which keeps counting while the device sleeps and restarts at boot — never on the wall clock, so moving
/// the date/time in either direction changes nothing. Every elapsed time used here is a LOWER bound on what
/// really passed (see `load`), so neither a clock change nor a reboot can shorten a lockout or decay the
/// count early; at worst a reboot restarts a pending lockout.
///
/// - Audit batch 4 (#27 / #90): `.legacy` is now an ALIAS of `.vault` — same storage, same monotonic timing, no
///   wall-clock branch left. Every Secret Vault credential check (the PIN screens AND the secret-code search
///   gate, through `ChatPincodeManager.checkVault`) therefore shares one budget, which is what makes guessing a
///   4-digit vault PIN through the chat-list search infeasible. `migrateLegacyToVaultIfNeeded()` carries the old
///   `fenix_chatlock_fail_count` / `fenix_chatlock_lockout_until` / `fenix_chatlock_lockout_anchor` state over
///   once, so a lockout in progress cannot be reset by installing this build.
/// - Every scope and the shared budget live under `fenix_chatlock_throttle_v2.<scope>` as `{count, delay,
///   anchor}`. `.vault` never touches the shared budget, and its count decays after 1 h instead of 24 h: an
///   accidental lockout heals itself, while 5 wrong codes still cost the escalating 30/60/120/300/900 s windows.
/// - Audit batch 4 round 2: the chat-list secret-code search has its OWN scope, `.vaultSearch`. It is neither
///   fed by nor gated by `.vault` (nor by the shared budget), because the owner's ordinary queries can look
///   exactly like a text-password credential: charging them to `.vault` locked the owner out of their own
///   vault PIN screen. Its profile is deliberately forgiving — 9 free tries, then a flat, non-escalating 60 s
///   window — and it decays on the same 1 h monotonic clock as `.vault`.
public enum ChatLockThrottle {
    public enum Scope: Hashable {
        /// Deprecated alias of `.vault` (same storage). Kept until every vault screen names `.vault`.
        case legacy
        /// One chat's PIN (verify / remove).
        case chat(PeerId)
        /// The master pincode (Chat Lock settings + "Forgot pincode?" recovery).
        case master
        /// Reserved for the Secret Vault.
        case vault
        /// Audit batch 4 (round 2): credential guesses typed into the chat-list search while the secret-code
        /// reveal is on. Separate storage, separate (forgiving) schedule; never touches `.vault`.
        case vaultSearch
    }

    /// Pre-batch-4 vault counter (migrated once by `migrateLegacyToVaultIfNeeded`, then deleted).
    private static let legacyAttemptsKey = "fenix_chatlock_fail_count"
    /// Wall-clock lockout end written by builds that predate the monotonic clock (migrated once, then deleted).
    private static let legacyLockoutKey = "fenix_chatlock_lockout_until"
    /// Monotonic lockout record written by pre-batch-4 builds (migrated once, then deleted).
    private static let legacyAnchorKey = "fenix_chatlock_lockout_anchor"
    private static let legacyMigratedKey = "fenix_chatlock_throttle_legacy_migrated_v1"
    private static let scopedKeyPrefix = "fenix_chatlock_throttle_v2."
    private static let chatScopedKeyPrefix = "fenix_chatlock_throttle_v2.chat."
    /// The shared budget across `.chat(*)` and `.master` (cannot collide with `chatScopedKeyPrefix`).
    private static let globalKey = "fenix_chatlock_throttle_v2.global"
    private static let decayInterval: TimeInterval = 24.0 * 60.0 * 60.0
    /// `.vault` / `.vaultSearch` only (audit batch 4): a wrong code must not keep costing the owner for a day,
    /// while 5 wrong ones still start the same escalating lockouts.
    private static let vaultDecayInterval: TimeInterval = 60.0 * 60.0
    /// `.vaultSearch`: failures below this cost nothing. Higher than `.vault`'s 5 on purpose — the owner's own
    /// one-word searches can be charged here, and they must never add up to a lockout in normal use.
    private static let vaultSearchFreeAttempts = 10
    /// `.vaultSearch`: one flat window, never escalating. Long enough to make guessing pointless (10 tries per
    /// minute against a PIN screen that is itself throttled), short enough to be a blip for the owner.
    private static let vaultSearchLockout: TimeInterval = 60.0

    private static let countField = "count"
    private static let delayField = "delay"
    /// Monotonic seconds (`monotonicNow()`) at the last failure.
    private static let anchorField = "anchor"

    /// Seconds (rounded up) until an entry in `scope` will be checked again; 0 when not throttled.
    public static func remaining(_ scope: Scope) -> Int {
        let now = self.monotonicNow()
        // Audit batch 4 (#90): one monotonic source for every scope, `.legacy`/`.vault` included.
        var value = self.pendingLockout(self.storageKey(scope), now: now)
        if case .chat = scope {
            // Shared budget: a PIN reused across chats must not get a fresh window in every chat.
            value = max(value, self.pendingLockout(self.globalKey, now: now))
        }
        if value <= 0.0 {
            return 0
        }
        return Int(ceil(value))
    }

    /// Records one wrong entry in `scope` and starts a lockout window when the schedule calls for one.
    public static func registerFailure(_ scope: Scope) {
        let now = self.monotonicNow()
        switch scope {
        case .chat, .master:
            self.recordFailure(self.storageKey(scope), now: now, decay: self.decayInterval, schedule: self.delay(forFailureCount:))
            self.recordFailure(self.globalKey, now: now, decay: self.decayInterval, schedule: self.delay(forFailureCount:))
        case .vault, .legacy:
            // One budget for every vault credential screen, never the shared one.
            self.recordFailure(self.storageKey(scope), now: now, decay: self.vaultDecayInterval, schedule: self.delay(forFailureCount:))
        case .vaultSearch:
            // Audit batch 4 (round 2): the search path pays only into its own, forgiving budget.
            self.recordFailure(self.storageKey(scope), now: now, decay: self.vaultDecayInterval, schedule: self.vaultSearchDelay(forFailureCount:))
        }
    }

    /// Clears the counter and any lockout for `scope` (after a successful entry or a recovery).
    /// - `.chat(p)`: clears p's own scope and withdraws only p's own failures from the shared budget, never
    ///   anyone else's (see the type comment).
    /// - `.master`: the master outranks every chat PIN, so it clears the shared budget and every `.chat(*)`
    ///   scope too (same as `resetAll`).
    public static func reset(_ scope: Scope) {
        let defaults = UserDefaults.standard
        switch scope {
        case .chat:
            // SG: Chat Lock — a chat success must not refund the shared budget for other chats' guesses.
            let key = self.storageKey(scope)
            let now = self.monotonicNow()
            // Only failures that still count in p's record (not decayed) are withdrawn. Each of them was also
            // recorded in the global counter, and while p's count is live the global one cannot have decayed
            // past them (every global gap within p's run is <= p's own gap); `reset(.master)` and `resetAll`
            // clear every chat record together with the global one. So this never takes back more than p added.
            // (A reboot can re-base the two anchors unevenly, but only someone who can unlock the device after a
            // reboot, with its passcode or because it has none, can go on, and they can already turn Chat Lock
            // off through the device-owner "Reset Chat Lock".)
            var refund = 0
            if let own = self.load(key, now: now), now - own.anchor <= self.decayInterval {
                refund = own.count
            }
            defaults.removeObject(forKey: key)
            if refund > 0, let global = self.load(self.globalKey, now: now) {
                let count = max(0, global.count - refund)
                if count == 0 {
                    defaults.removeObject(forKey: self.globalKey)
                } else {
                    // Keep the anchor (the latest failure in any scope): the remaining lockout can only be as long
                    // as, or longer than, the one the remaining failures alone would have started.
                    self.store(Record(count: count, delay: self.delay(forFailureCount: count), anchor: global.anchor), key: self.globalKey)
                }
            }
        case .master:
            // SG: Chat Lock — clearing the chat records as well keeps the `.chat` refund above exact.
            self.resetAll()
        case .vault, .legacy, .vaultSearch:
            defaults.removeObject(forKey: self.storageKey(scope))
        }
    }

    /// Clears `.master`, every `.chat(*)` scope and the shared budget. Never touches `.vault` (`.legacy`) or
    /// `.vaultSearch`: the device-owner "Reset Chat Lock" must not hand back a fresh budget for guessing the
    /// vault credential (from the PIN screens or through the chat-list search).
    public static func resetAll() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: self.storageKey(.master))
        defaults.removeObject(forKey: self.globalKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(self.chatScopedKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Audit batch 4 (#90): moves the pre-batch-4 vault counter (`fenix_chatlock_fail_count` plus its wall-clock
    /// or monotonic lockout) into the `.vault` scope, once. Idempotent, and called from `ChatPincodeManager.init`
    /// — i.e. before any vault screen or the search gate can ask — so installing this build can never hand a
    /// user in the middle of a lockout a fresh budget. The pre-batch-4 keys are deleted afterwards.
    public static func migrateLegacyToVaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: self.legacyMigratedKey) else {
            return
        }
        defaults.set(true, forKey: self.legacyMigratedKey)

        let now = self.monotonicNow()
        let vaultKey = self.storageKey(.vault)
        let vaultRecord = self.load(vaultKey, now: now)
        let count = max(defaults.integer(forKey: self.legacyAttemptsKey), vaultRecord?.count ?? 0)
        if count > 0 {
            let delay = self.delay(forFailureCount: count)
            var remaining = self.pendingLockout(vaultKey, now: now)
            if defaults.object(forKey: self.legacyAnchorKey) != nil {
                remaining = max(remaining, self.pendingLockout(self.legacyAnchorKey, now: now))
            } else {
                // Written before the monotonic clock: only a wall-clock end exists. Whatever is left of it is
                // honoured (clamped to the scheduled delay), never more — this is the one place that reads it.
                let until = defaults.double(forKey: self.legacyLockoutKey)
                if until > 0.0 {
                    remaining = max(remaining, until - (CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970))
                }
            }
            remaining = min(max(remaining, 0.0), delay)
            self.store(Record(count: count, delay: delay, anchor: now - (delay - remaining)), key: vaultKey)
        }
        defaults.removeObject(forKey: self.legacyAttemptsKey)
        defaults.removeObject(forKey: self.legacyLockoutKey)
        defaults.removeObject(forKey: self.legacyAnchorKey)
    }

    // MARK: - Private

    /// One persisted counter; `anchor` is `monotonicNow()` at the last failure.
    private struct Record {
        var count: Int
        var delay: Double
        var anchor: Double
    }

    /// Seconds on `mach_continuous_time` (CLOCK_MONOTONIC_RAW): unaffected by the date/time settings,
    /// keeps counting while the device sleeps (unlike `systemUptime`), restarts from ~0 at boot.
    /// Covered by the app's SystemBootTime privacy declaration (35F9.1: elapsed time between in-app events,
    /// never leaves the device). Internal: ChatLockSession measures its short-lived vault-credential proof on
    /// the same clock (audit batch 4).
    static func monotonicNow() -> Double {
        return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000.0
    }

    private static func storageKey(_ scope: Scope) -> String {
        switch scope {
        case .legacy, .vault:
            // Audit batch 4: `.legacy` is an alias of `.vault`, so both share one record.
            return self.scopedKeyPrefix + "vault"
        case let .chat(peerId):
            return self.chatScopedKeyPrefix + "\(peerId.toInt64())"
        case .master:
            return self.scopedKeyPrefix + "master"
        case .vaultSearch:
            // Audit batch 4 (round 2): its own record, so search guesses and PIN-screen guesses never mix.
            return self.scopedKeyPrefix + "vaultSearch"
        }
    }

    /// Reads the record under `key` such that `now - anchor` is a LOWER bound on the seconds since its last
    /// failure, whatever happened in between:
    /// - same boot: the monotonic delta is exact;
    /// - rebooted, and the new clock is still below the anchor (`now < anchor` can only mean a reboot): only
    ///   the time since this boot is certain, so the anchor is rebased to boot start (0) and persisted, so the
    ///   credit a reboot earns cannot change on a later read;
    /// - rebooted, and the new clock already passed the anchor: `now - anchor` is less than the time since
    ///   boot, so it still under-counts (fail closed). A boot-session id is deliberately NOT used to credit
    ///   the full time since boot here: a userspace reboot keeps this clock running, so that credit could
    ///   exceed what really elapsed.
    /// A record without a monotonic anchor (older wall-clock format) has no trustworthy timestamp, so its
    /// window restarts now.
    private static func load(_ key: String, now: Double) -> Record? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else {
            return nil
        }
        let count = (dict[self.countField] as? NSNumber)?.intValue ?? 0
        let delay = (dict[self.delayField] as? NSNumber)?.doubleValue ?? 0.0
        guard let anchor = (dict[self.anchorField] as? NSNumber)?.doubleValue, anchor.isFinite, anchor >= 0.0 else {
            let record = Record(count: count, delay: delay, anchor: now)
            self.store(record, key: key)
            return record
        }
        var record = Record(count: count, delay: delay, anchor: anchor)
        if now < anchor {
            record.anchor = 0.0
            self.store(record, key: key)
        }
        return record
    }

    private static func store(_ record: Record, key: String) {
        UserDefaults.standard.set([
            self.countField: record.count,
            self.delayField: record.delay,
            self.anchorField: record.anchor
        ] as [String: Any], forKey: key)
    }

    /// Seconds left in the lockout recorded under `key`; <= 0 when there is none. Never exceeds the scheduled
    /// delay, since `load` guarantees `now >= anchor`.
    private static func pendingLockout(_ key: String, now: Double) -> Double {
        guard let record = self.load(key, now: now), record.delay > 0.0 else {
            return 0.0
        }
        return record.delay - (now - record.anchor)
    }

    /// `schedule` maps the running failure count to the lockout it earns, so each scope can have its own
    /// profile (`.vault` escalates, `.vaultSearch` does not) while sharing this monotonic bookkeeping.
    private static func recordFailure(_ key: String, now: Double, decay: Double, schedule: (Int) -> Double) {
        var count = 0
        // The count decays only after `decay` (24 h; 1 h for `.vault` / `.vaultSearch`) that certainly passed on
        // the monotonic clock; a wall-clock jump (or a reboot) can never reset it.
        if let record = self.load(key, now: now), now - record.anchor <= decay {
            count = record.count
        }
        count += 1
        self.store(Record(count: count, delay: schedule(count), anchor: now), key: key)
    }

    /// `.vaultSearch`: nothing for the first `vaultSearchFreeAttempts - 1` failures, then a flat window that
    /// never escalates, so an owner who searched their way into it is never locked out for more than a minute.
    private static func vaultSearchDelay(forFailureCount count: Int) -> Double {
        return count < self.vaultSearchFreeAttempts ? 0.0 : self.vaultSearchLockout
    }

    private static func delay(forFailureCount count: Int) -> Double {
        switch count {
        case ..<5:
            return 0.0
        case 5:
            return 30.0
        case 6:
            return 60.0
        case 7:
            return 120.0
        case 8:
            return 300.0
        default:
            return 900.0
        }
    }
}
