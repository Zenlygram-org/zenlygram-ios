import Foundation
#if !SGIAP_HOST_TESTS
import SGAppGroupIdentifier
#endif
import SGEntitlement

/// Zenlygram — the client's memory of the SERVER's trial ledger (design §5.6).
///
/// There is no endpoint that reports the ledger: the only way to learn it is to call
/// `POST /v1/trial/start` and read the refusal. That call is throttled at 3/h/device, so an app that
/// asked every time the paywall opened would burn the budget and then show "too many attempts" to a
/// user who never asked for a trial. So the refusal is remembered here, and the affordance is hidden
/// the way §5.6 requires — while the reason still renders next to the purchase options, because
/// "every refusal must be shown, never a dead end".
///
/// Two scopes, because the server has two:
/// - `trial_already_used` is about the ACCOUNT, and follows the Telegram account.
/// - `trial_device_cap` / `trial_device_blocked` are about the DEVICE, and outlive every account.
/// - `trial_paused` (the emergency stop) and `trial_disabled` (the trial not enabled in the
///   monetization policy) are operator switches and are remembered only briefly.
///
/// Nothing here gates anything: it changes one button's visibility. Losing it costs one wasted
/// request, which is why it lives in the app-group defaults rather than in the Keychain.
///
/// The server that refused is a backend ORIGIN's, so the facts are kept per origin
/// (`zg.iap.trial.v1@<authority>`, `SGEntitlementStoreScope`): a build for a new origin starts with
/// none, and never reads, rewrites or removes the bare pre-origin key.
struct SGIAPTrialLedgerState: Codable, Equatable {
    /// `trial_device_cap` / `trial_device_blocked`: no account on this install may trial again.
    var deviceExhausted: Bool
    /// `trial_already_used`, keyed by the Telegram account's peer id. Only the server's refusal
    /// writes this: it is what makes the paywall say "you've already used your free trial".
    var accountsExhausted: [String: Bool]
    /// Accounts whose trial THIS app started, keyed by peer id. The trial is consumed, so it is not
    /// offered again — but nothing was refused, and the user is inside that trial right now, so
    /// no refusal copy is shown for it.
    var grantedAccounts: [String: Bool]
    /// `trial_paused` / `trial_disabled`: operator switches, so they expire on their own.
    var pausedUntil: Date?
    /// The last stable refusal code, for the copy and for logs.
    var lastRefusalCode: String?

    init(deviceExhausted: Bool = false, accountsExhausted: [String: Bool] = [:], grantedAccounts: [String: Bool] = [:], pausedUntil: Date? = nil, lastRefusalCode: String? = nil) {
        self.deviceExhausted = deviceExhausted
        self.accountsExhausted = accountsExhausted
        self.grantedAccounts = grantedAccounts
        self.pausedUntil = pausedUntil
        self.lastRefusalCode = lastRefusalCode
    }

    /// Hand-written so a field added later decodes an existing blob instead of throwing: the
    /// synthesized decoder ignores property defaults, and a throw here would silently reset the
    /// whole ledger and re-offer a trial the server has already refused.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceExhausted = try container.decodeIfPresent(Bool.self, forKey: .deviceExhausted) ?? false
        self.accountsExhausted = try container.decodeIfPresent([String: Bool].self, forKey: .accountsExhausted) ?? [:]
        self.grantedAccounts = try container.decodeIfPresent([String: Bool].self, forKey: .grantedAccounts) ?? [:]
        self.pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        self.lastRefusalCode = try container.decodeIfPresent(String.self, forKey: .lastRefusalCode)
    }
}

final class SGIAPTrialLedger {
    #if !SGIAP_HOST_TESTS
    static let shared = SGIAPTrialLedger(defaults: UserDefaults(suiteName: sgAppGroupIdentifier()), scope: .shipped)
    #endif

    /// `trial_paused` and `trial_disabled` are temporary by construction. Long enough that the
    /// paywall does not hammer a 3/h budget, short enough that a switch flipped back is noticed
    /// within one session. (For `trial_disabled` the signed policy's `trial_days` hides the button
    /// anyway from the next refresh on; this covers the screen that raced it.)
    static let pausedRetryInterval: TimeInterval = 3600.0

    /// The bare pre-origin key. Never read, written or removed: only scoped (`defaultsKey`).
    private static let legacyDefaultsKey = "zg.iap.trial.v1"

    /// This origin's key, and the only one this ledger touches.
    let defaultsKey: String

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var cached: SGIAPTrialLedgerState?

    init(defaults: UserDefaults?, scope: SGEntitlementStoreScope) {
        self.defaults = defaults
        self.defaultsKey = scope.scopedKey(SGIAPTrialLedger.legacyDefaultsKey)
    }

    func state() -> SGIAPTrialLedgerState {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loadLocked()
    }

    private func loadLocked() -> SGIAPTrialLedgerState {
        if let cached = self.cached {
            return cached
        }
        var state = SGIAPTrialLedgerState()
        if let data = self.defaults?.data(forKey: self.defaultsKey), let decoded = try? JSONDecoder().decode(SGIAPTrialLedgerState.self, from: data) {
            state = decoded
        }
        self.cached = state
        return state
    }

    private func mutate(_ transform: (inout SGIAPTrialLedgerState) -> Void) {
        self.lock.lock()
        var state = self.loadLocked()
        transform(&state)
        self.cached = state
        if let data = try? JSONEncoder().encode(state) {
            self.defaults?.set(data, forKey: self.defaultsKey)
        }
        self.lock.unlock()
    }

    /// May the app OFFER its own trial for this account right now?
    ///
    /// `accountPeerId` nil means no Telegram account is linked, and `/v1/trial/start` needs a bound
    /// device — so there is nothing to offer. A PURCHASE is never gated this way (§3.6, §7 row 21).
    func isServerTrialAvailable(accountPeerId: Int64?, now: Date = Date()) -> Bool {
        guard let accountPeerId else {
            return false
        }
        let state = self.state()
        if state.deviceExhausted {
            return false
        }
        if let pausedUntil = state.pausedUntil, now < pausedUntil {
            return false
        }
        let key = "\(accountPeerId)"
        return state.accountsExhausted[key] != true && state.grantedAccounts[key] != true
    }

    /// The copy to show next to the purchase options, or nil when there is nothing to explain.
    func refusalMessage(accountPeerId: Int64?, now: Date = Date()) -> SGEntitlementMessage? {
        let state = self.state()
        if state.deviceExhausted {
            return state.lastRefusalCode == SGEntitlementRefusalCode.trialDeviceBlocked.rawValue ? .trialDeviceBlocked : .trialDeviceCap
        }
        if let pausedUntil = state.pausedUntil, now < pausedUntil {
            // "Not offered right now" and "temporarily unavailable" are different facts.
            return state.lastRefusalCode == SGEntitlementRefusalCode.trialDisabled.rawValue ? .trialNotOffered : .trialUnavailable
        }
        if let accountPeerId, state.accountsExhausted["\(accountPeerId)"] == true {
            return .trialAlreadyUsed
        }
        return nil
    }

    /// Records what the server said. Only the trial refusals below are remembered: a 5xx, a timeout
    /// or a 429 tells us nothing about the ledger, and treating one as "already used" would hide a
    /// trial the user is entitled to.
    func record(refusal: SGEntitlementFailureClass, accountPeerId: Int64?, now: Date = Date()) {
        guard case let .refused(code) = refusal else {
            return
        }
        switch code {
        case .trialAlreadyUsed:
            guard let accountPeerId else {
                return
            }
            self.mutate { state in
                state.accountsExhausted["\(accountPeerId)"] = true
                state.lastRefusalCode = code.rawValue
            }
        case .trialDeviceCap, .trialDeviceBlocked:
            self.mutate { state in
                state.deviceExhausted = true
                state.lastRefusalCode = code.rawValue
            }
        case .trialPaused, .trialDisabled:
            // Both are operator switches the server would only repeat for a while: remembered for
            // an hour, so a stale paywall cannot spend the 3/h `/v1/trial/start` budget on them.
            self.mutate { state in
                state.pausedUntil = now.addingTimeInterval(SGIAPTrialLedger.pausedRetryInterval)
                state.lastRefusalCode = code.rawValue
            }
        default:
            break
        }
    }

    /// A trial we started ourselves consumes the account's trial, exactly as the server's does — but
    /// it is not a refusal, so it touches neither `accountsExhausted` nor `lastRefusalCode`.
    func recordGrant(accountPeerId: Int64?) {
        guard let accountPeerId else {
            return
        }
        self.mutate { state in
            state.grantedAccounts["\(accountPeerId)"] = true
        }
    }

    func reset() {
        self.lock.lock()
        self.cached = SGIAPTrialLedgerState()
        self.defaults?.removeObject(forKey: self.defaultsKey)
        self.lock.unlock()
    }
}
