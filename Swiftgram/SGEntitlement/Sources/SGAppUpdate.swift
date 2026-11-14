import Foundation

/// Zenlygram — the app-update decision as the app reads it (`SGAppUpdateDecision`): a thin holder
/// over the coordinator's stored, re-verified app-update policy (`SGEntitlement.appUpdateDecision`).
///
/// Foundation only, on purpose: the presenter — the full-screen "Update required" overlay and the
/// one "Update available" alert — lives in its own UIKit module and builds on this. It observes
/// `decisionDidChange`, re-reads `currentDecision`, and records a shown reminder through
/// `noteReminderShown(latest:)`. `restoreDecision()` is the first-frame call: synchronous, offline,
/// from the token persisted under `zg.app.policy.v1@<origin>`, so a known-blocked install never
/// flashes the chat list or the login — the +8 s fetch only refines or lifts.
public final class SGAppUpdate {
    /// The app's instance, over `SGEntitlement.shared`.
    public static let shared = SGAppUpdate(entitlement: SGEntitlement.shared)

    /// Posted on the main queue after every adopted app-update policy
    /// (`SGEntitlement.refreshAppUpdatePolicy`), whether or not the decision moved: observers
    /// re-read `currentDecision`.
    public static let decisionDidChange = Notification.Name("SGAppUpdateDecisionDidChange")

    private let entitlement: SGEntitlement

    /// Tests construct their own over an owned coordinator; the app uses `shared`.
    init(entitlement: SGEntitlement) {
        self.entitlement = entitlement
    }

    /// The decision from the stored, re-verified policy — for the first frame, before any network.
    /// The same value as `currentDecision`; the name marks the call that must happen synchronously
    /// when a root is attached.
    public func restoreDecision() -> SGAppUpdateDecision {
        return self.entitlement.appUpdateDecision
    }

    /// The decision right now: the accepted policy, the installed version, the reminder marker and
    /// the policy clock (the 30-day block valve). Cheap after the first read of the process.
    public var currentDecision: SGAppUpdateDecision {
        return self.entitlement.appUpdateDecision
    }

    /// The reminder for `latest` was actually shown: it reminds no more, on any launch, until a
    /// policy names a newer `latest`. Never called on the decision alone.
    public func noteReminderShown(latest: SGAppUpdateVersion) {
        self.entitlement.noteAppUpdateReminderShown(latest: latest)
    }
}
