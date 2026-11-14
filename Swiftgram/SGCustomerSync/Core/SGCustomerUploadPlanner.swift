import Foundation

/// Zenlygram — the per-account upload order (contract §6.4, design 40 §6.3) as a pure next-step
/// function over PERSISTED markers (never "this process only"):
///
/// | # | step | runs when |
/// |---|---|---|
/// | 2 | auto-link | not linked, `granted`, the grant not rejected, the link not ended, the grant not stale in this build (the schedule is `SGAutoLinkPolicy`'s) |
/// | 3 | `POST /v1/profile/consents`, one entry per request | linked and an entry is pending at this authority, or the current binding has not had its post-link upload yet ("always after a link") |
/// | 4 | `POST /v1/profile/sync` | `uploadProfile` clearance and the snapshot is due (`SGProfileSyncCadence`) |
/// | 5 | `POST /v1/profile/events` | `uploadEvents` clearance and a flush is due (`SGAnalyticsBatcher.flushDueAt`) |
///
/// Steps 4–5 never run when not linked, while the latest grant is not acked or is rejected, in any
/// state but `granted`, while erasing, after a server-ended link, or when the current binding
/// answered `profile_account_not_linked`. In `withdrawn` / `withdrawn_remote` only step 3 runs, and
/// only for withdrawals. A grant this build treats as stale (§4.6 rows 5–6,
/// `SGCustomerClearance.Inputs.staleGrantNotice`) is read as `needs_reconsent`: never linked with,
/// never sent again, only a pending withdrawal goes. Nothing automatic runs before first idle, while
/// the store is unreadable or while erasing. One request per (account, route) is in flight; step 3
/// goes before 4 and 5.
/// Automatic steps respect the route's backoff and the device-wide budget; user-initiated calls
/// (`me`, the withdraw send, `delete`) do not (`userInitiated`).
public enum SGCustomerUploadPlanner {
    public struct Account: Equatable {
        public var clearance: SGCustomerClearance.Inputs
        /// The record's `consent_id` (the current grant's when `granted`).
        public var recordConsentId: String?
        /// SGEntitlement's first-idle window has passed in this process.
        public var firstIdlePassed: Bool
        /// `SGConsentStore.pendingUploads(tg:authority:)`: un-acked, un-rejected, oldest first.
        public var pendingUploads: [Data]
        /// `SGConsentStore.latestDecision(tg:)`.
        public var latestDecision: Data?
        /// `zg.cs.consents_sent…`: the binding whose post-link upload finished.
        public var consentsSentDeviceId: String?
        /// `SGProfileSyncCadence.dueAt(...)` (nil = not due).
        public var syncDueAt: Date?
        /// `SGAnalyticsBatcher.flushDueAt(...)` (nil = not due).
        public var eventsDueAt: Date?
        public var inFlight: Set<SGCustomerRoute>
        /// The account's `SGCustomerBackoff.nextAt` per route.
        public var backoffUntil: [SGCustomerRoute: Date]
        /// The device-wide `SGCustomerBudget.nextAllowedAt` per route.
        public var budgetUntil: [SGCustomerRoute: Date]

        public init(clearance: SGCustomerClearance.Inputs, recordConsentId: String?, firstIdlePassed: Bool, pendingUploads: [Data], latestDecision: Data?, consentsSentDeviceId: String?, syncDueAt: Date?, eventsDueAt: Date?, inFlight: Set<SGCustomerRoute> = [], backoffUntil: [SGCustomerRoute: Date] = [:], budgetUntil: [SGCustomerRoute: Date] = [:]) {
            self.clearance = clearance
            self.recordConsentId = recordConsentId
            self.firstIdlePassed = firstIdlePassed
            self.pendingUploads = pendingUploads
            self.latestDecision = latestDecision
            self.consentsSentDeviceId = consentsSentDeviceId
            self.syncDueAt = syncDueAt
            self.eventsDueAt = eventsDueAt
            self.inFlight = inFlight
            self.backoffUntil = backoffUntil
            self.budgetUntil = budgetUntil
        }
    }

    /// Why a consents entry is sent.
    public enum ConsentsReason: Equatable {
        /// Not acked (nor rejected) at this authority.
        case pending
        /// The current binding's post-link re-send of the latest decision (idempotent). After its
        /// 200 — and after any 200 that leaves nothing pending — write `consents_sent` = the binding.
        case afterLink
    }

    public enum Step: Equatable {
        /// Nothing to do now (re-plan on the next event).
        case none
        /// Step 2: hand the account to `SGAutoLinkPolicy`.
        case autoLink
        /// Step 3: send this one entry (`SGConsentsRequest.body(events: [entry])`).
        case consents(entry: Data, reason: ConsentsReason)
        case sync
        case events
        /// The next step is held by its due time, backoff or budget until then.
        case wait(SGCustomerRoute, until: Date)
    }

    public static func next(_ account: Account, now: Date) -> Step {
        let inputs = account.clearance
        guard account.firstIdlePassed, inputs.readable, !inputs.erasing else {
            return .none
        }
        guard inputs.isLinked else {
            if SGCustomerUploadPlanner.isUsableGrant(inputs), !inputs.latestGrantRejected, !inputs.linkEnded {
                return .autoLink
            }
            return .none
        }
        if let found = SGCustomerUploadPlanner.consentsEntry(account) {
            if account.inFlight.contains(.consents) {
                return .none
            }
            if let until = SGCustomerUploadPlanner.heldUntil(.consents, account, now) {
                return .wait(.consents, until: until)
            }
            return .consents(entry: found.entry, reason: found.reason)
        }
        if account.inFlight.contains(.consents) {
            // A user-initiated send: wait for its answer.
            return .none
        }
        let clearance = SGCustomerClearance.derive(inputs)
        guard clearance.contains(.uploadProfile) else {
            return .none
        }
        var waits: [(route: SGCustomerRoute, until: Date)] = []
        let candidates: [(SGCustomerRoute, Date?, Bool)] = [
            (.sync, account.syncDueAt, true),
            (.events, account.eventsDueAt, clearance.contains(.uploadEvents)),
        ]
        for (route, dueAt, allowed) in candidates {
            guard allowed, let dueAt, !account.inFlight.contains(route) else {
                continue
            }
            if dueAt > now {
                waits.append((route, dueAt))
            } else if let until = SGCustomerUploadPlanner.heldUntil(route, account, now) {
                waits.append((route, until))
            } else {
                return route == .sync ? .sync : .events
            }
        }
        if let earliest = waits.min(by: { $0.until < $1.until }) {
            return .wait(earliest.route, until: earliest.until)
        }
        return .none
    }

    /// The step-3 entry, if any: for a usable grant (`isUsableGrant`) the oldest pending entry; in
    /// any other state — a stale grant included — the oldest pending withdrawal; else, once per
    /// binding, the latest decision again when it is the record's (a usable grant not rejected, or a
    /// withdrawal).
    public static func consentsEntry(_ account: Account) -> (entry: Data, reason: ConsentsReason)? {
        let inputs = account.clearance
        let usable = SGCustomerUploadPlanner.isUsableGrant(inputs)
        let pending = account.pendingUploads.compactMap { data in SGConsentEvent.decode(data).map { (data, $0) } }
        if usable {
            if let first = pending.first {
                return (first.0, .pending)
            }
        } else if let withdraw = pending.first(where: { $0.1.action == .withdraw }) {
            return (withdraw.0, .pending)
        }
        guard let binding = inputs.bindingDeviceId, account.consentsSentDeviceId != binding, let latest = account.latestDecision,
              let event = SGConsentEvent.decode(latest), event.consentId == account.recordConsentId else {
            return nil
        }
        switch (inputs.state, event.action) {
        case (.granted, .grant) where usable && !inputs.latestGrantRejected:
            return (latest, .afterLink)
        case (.withdrawn, .withdraw):
            return (latest, .afterLink)
        default:
            return nil
        }
    }

    /// What a user-initiated call (`me`, the withdraw send, `delete`) may do: never held by first
    /// idle, a consent state, the backoff or a client budget — only one per (account, route) in
    /// flight, and only with a binding to send with.
    public enum UserCall: Equatable {
        case send
        /// No binding on this device: show the web page instead.
        case notLinked
        case inFlight
        /// `sync` and `events` are automatic only.
        case notUserInitiated
    }

    public static func userInitiated(_ route: SGCustomerRoute, isLinked: Bool, inFlight: Set<SGCustomerRoute>) -> UserCall {
        switch route {
        case .me, .consents, .delete:
            break
        case .sync, .events:
            return .notUserInitiated
        }
        guard isLinked else {
            return .notLinked
        }
        return inFlight.contains(route) ? .inFlight : .send
    }

    /// `granted`, and not stale in this build — exactly the term `SGCustomerClearance.derive` stops
    /// a grant on (`staleGrantNotice`, §4.6 rows 5–6). A stale grant is read as `needs_reconsent`:
    /// the wall would persist it so, but only for the primary account.
    private static func isUsableGrant(_ inputs: SGCustomerClearance.Inputs) -> Bool {
        return inputs.state == .granted && inputs.staleGrantNotice == nil
    }

    /// The later of the route's backoff and budget, when it is after `now`.
    private static func heldUntil(_ route: SGCustomerRoute, _ account: Account, _ now: Date) -> Date? {
        let until = [account.backoffUntil[route], account.budgetUntil[route]].compactMap { $0 }.filter { $0 > now }.max()
        return until
    }
}
