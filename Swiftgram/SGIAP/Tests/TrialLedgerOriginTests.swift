import Foundation
import SGEntitlement

/// Zenlygram — the trial ledger's facts are scoped to the backend origin (`zg.iap.trial.v1@<authority>`).
/// A new origin starts with no remembered refusal or grant, writes and resets only its own key, and
/// never reads, rewrites or removes the bare legacy key, which stays byte-for-byte identical.
/// Real `UserDefaults` suites; compiled into this test with `SGIAPTrialLedger.swift` itself
/// (`run-trial-ledger-tests.sh`).
@main
struct TrialLedgerOriginTests {
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    private static let account: Int64 = 69_229_542_146
    private static let legacyKey = "zg.iap.trial.v1"

    private static func scope(_ raw: String) -> SGEntitlementStoreScope {
        guard let origin = SGEntitlementBackendOrigin(apiUrl: raw, upstreamDefaultApiUrl: "https://api.swiftgram.app") else {
            preconditionFailure("premise: \(raw) is a valid origin")
        }
        return .origin(origin)
    }

    private static func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "TrialLedgerOriginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
        }
        body(defaults)
    }

    /// What an earlier `.com` build remembered: every account and the device exhausted.
    private static func seedLegacy(_ defaults: UserDefaults) -> Data {
        let legacy = SGIAPTrialLedgerState(deviceExhausted: true, accountsExhausted: ["\(account)": true], grantedAccounts: ["\(account)": true], pausedUntil: Date.distantFuture, lastRefusalCode: SGEntitlementRefusalCode.trialDeviceBlocked.rawValue)
        let data = try! JSONEncoder().encode(legacy)
        defaults.set(data, forKey: legacyKey)
        return data
    }

    static func main() {
        self.aNewOriginStartsWithoutLegacyTrialFacts()
        self.writesAndResetsTouchOnlyTheOriginKey()
        self.originsAreIsolatedFromEachOther()
        self.aDisabledTrialIsRememberedLikeAPausedOne()
        print("SGIAPTrialLedger origin scope: all checks passed")
    }

    /// `409 trial_disabled` (the operator has not enabled the server's trial) is remembered exactly
    /// like `503 trial_paused` — for an hour, hiding the affordance — but with its own copy, so a
    /// paywall that raced the policy refresh cannot spend the 3/h `/v1/trial/start` budget on an
    /// answer that will not change, and never says "temporarily unavailable" for a deliberate choice.
    private static func aDisabledTrialIsRememberedLikeAPausedOne() {
        self.withSuite { defaults in
            let org = self.scope("https://api.zenlygram.org")
            let ledger = SGIAPTrialLedger(defaults: defaults, scope: org)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            check(ledger.isServerTrialAvailable(accountPeerId: account, now: now), "premise: nothing remembered yet")

            ledger.record(refusal: .refused(.trialDisabled), accountPeerId: account, now: now)
            check(!ledger.isServerTrialAvailable(accountPeerId: account, now: now), "the affordance stayed after trial_disabled")
            check(!ledger.isServerTrialAvailable(accountPeerId: account, now: now.addingTimeInterval(SGIAPTrialLedger.pausedRetryInterval - 1)), "trial_disabled was forgotten before the hour")
            check(ledger.isServerTrialAvailable(accountPeerId: account, now: now.addingTimeInterval(SGIAPTrialLedger.pausedRetryInterval)), "trial_disabled outlived the hour")
            check(!ledger.isServerTrialAvailable(accountPeerId: 7, now: now), "an operator switch is not an account fact: every account on the install waits")
            check(ledger.refusalMessage(accountPeerId: account, now: now) == .trialNotOffered, "trial_disabled showed the outage copy")
            check(ledger.refusalMessage(accountPeerId: account, now: now.addingTimeInterval(SGIAPTrialLedger.pausedRetryInterval)) == nil, "the copy outlived the hour")

            let state = ledger.state()
            check(state.pausedUntil == now.addingTimeInterval(SGIAPTrialLedger.pausedRetryInterval), "trial_disabled is remembered for exactly the paused interval")
            check(state.lastRefusalCode == SGEntitlementRefusalCode.trialDisabled.rawValue, "the stable code was not kept")
            check(!state.deviceExhausted && state.accountsExhausted.isEmpty, "trial_disabled exhausted a ledger it says nothing about")

            let relaunched = SGIAPTrialLedger(defaults: defaults, scope: org)
            check(!relaunched.isServerTrialAvailable(accountPeerId: account, now: now), "trial_disabled did not survive a relaunch")
            check(relaunched.refusalMessage(accountPeerId: account, now: now) == .trialNotOffered, "the copy did not survive a relaunch")

            // The emergency stop keeps its own copy.
            ledger.record(refusal: .refused(.trialPaused), accountPeerId: account, now: now)
            check(ledger.refusalMessage(accountPeerId: account, now: now) == .trialUnavailable, "trial_paused lost the outage copy")
            check(defaults.data(forKey: legacyKey) == nil, "nothing may create the bare legacy key")
        }
    }

    private static func aNewOriginStartsWithoutLegacyTrialFacts() {
        self.withSuite { defaults in
            let legacy = self.seedLegacy(defaults)
            let org = self.scope("https://api.zenlygram.org")
            let ledger = SGIAPTrialLedger(defaults: defaults, scope: org)
            check(ledger.defaultsKey == "zg.iap.trial.v1@api.zenlygram.org", "unexpected key \(ledger.defaultsKey)")
            check(ledger.state() == SGIAPTrialLedgerState(), "a .com trial fact surfaced under the new origin")
            check(ledger.isServerTrialAvailable(accountPeerId: account), "a .com refusal hid the new origin's trial")
            check(ledger.refusalMessage(accountPeerId: account) == nil, "a .com refusal message surfaced")
            check(defaults.data(forKey: legacyKey) == legacy, "the legacy ledger changed")
            check(SGIAPTrialLedger(defaults: defaults, scope: .unconfigured).state() == SGIAPTrialLedgerState(), "the unconfigured scope read the bare legacy key")
        }
    }

    private static func writesAndResetsTouchOnlyTheOriginKey() {
        self.withSuite { defaults in
            let legacy = self.seedLegacy(defaults)
            let org = self.scope("https://api.zenlygram.org")
            let ledger = SGIAPTrialLedger(defaults: defaults, scope: org)
            ledger.record(refusal: .refused(.trialAlreadyUsed), accountPeerId: account)
            ledger.recordGrant(accountPeerId: 7)
            check(defaults.data(forKey: org.scopedKey(legacyKey)) != nil, "the origin's fact was not persisted under its key")
            check(defaults.data(forKey: legacyKey) == legacy, "a write reached the legacy key")
            let reloaded = SGIAPTrialLedger(defaults: defaults, scope: org)
            check(reloaded.refusalMessage(accountPeerId: account) == .trialAlreadyUsed, "the origin's own fact did not survive a relaunch")
            check(!reloaded.state().deviceExhausted, "the legacy device cap leaked in on reload")

            reloaded.reset()
            check(defaults.data(forKey: org.scopedKey(legacyKey)) == nil, "reset left the origin's ledger")
            check(defaults.data(forKey: legacyKey) == legacy, "reset removed or rewrote the legacy ledger")
        }
    }

    private static func originsAreIsolatedFromEachOther() {
        self.withSuite { defaults in
            let org = SGIAPTrialLedger(defaults: defaults, scope: self.scope("https://api.zenlygram.org"))
            let other = SGIAPTrialLedger(defaults: defaults, scope: self.scope("https://api.zenlygram.org:8443"))
            org.record(refusal: .refused(.trialDeviceCap), accountPeerId: account)
            check(!other.state().deviceExhausted, "one origin's device cap reached another")
            check(other.isServerTrialAvailable(accountPeerId: account), "one origin's refusal reached another")
            other.reset()
            check(SGIAPTrialLedger(defaults: defaults, scope: self.scope("https://api.zenlygram.org")).state().deviceExhausted, "another origin's reset removed this origin's fact")
            check(defaults.data(forKey: legacyKey) == nil, "nothing may create the bare legacy key")
        }
    }
}
