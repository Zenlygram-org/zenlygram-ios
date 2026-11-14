import Foundation

/// Zenlygram — every decision of the customer-data coordinator as ONE pure reducer (design 40 §6.6):
/// `reduce(state, event, inputs:, now:) -> (state, [Effect])`, host-tested, so the app-side driver
/// (`SGCustomerSyncCoordinator`, I-3) holds no decision logic of its own. The driver:
///
/// 1. feeds the events one at a time, in order, on the main queue;
/// 2. reads `Inputs` fresh from storage before EVERY event — the consent store, SGEntitlement's
///    session facts, the event queue, the budgets and the cadence helpers — so the reducer never
///    reads storage and §6.2's per-account state is "in memory, rebuilt from storage";
/// 3. runs the returned effects in order; `.call` and `.autoLink` report back through `.outcome` /
///    `.deleteOutcome` / `.autoLinkFinished`, `.scheduleTimer` through `.timer`. Store writes keyed by
///    `tg` go to the current authority.
///
/// What it decides:
/// - clearance (`SGCustomerClearance`, from persisted inputs only), published at once on every
///   change, `[]` for any account it cannot read;
/// - a binding the server ended (`SGCustomerLinkState`: normalise to `needs_reconsent`, or the local
///   erase for `account_erased`);
/// - a local withdrawal, in this order: gate `[]` → queue purge → receipt clear → Tasks retire → the
///   user-initiated send (no first idle, no budget, no backoff; not in an Unlink's own reduction,
///   which starts no upload for its account: `Event.userWillUnlink`); a withdrawal already on record
///   when the account is first read gets the four local steps again (each is idempotent, and the
///   process that withdrew may have died before they ran, C§6.7), never a second send;
/// - the deletion (`SGCustomerDeletion`) and its local erase list;
/// - the upload order (`SGCustomerUploadPlanner`) with one request per (account, route) in flight,
///   backoff (`SGCustomerBackoff`) and nothing automatic before first idle;
/// - the automatic link (`SGAutoLinkPolicy`), at most one in flight on the install, primary account
///   first;
/// - app sessions: start on foreground / grant / account switch (an account switch ends the old
///   session first), end on background, switch and terminate — never on logout (the queue goes);
/// - the logout purge and the launch reconciliation (`SGAccountReconcile.purgeSet`), never while
///   unreadable.
public enum SGCustomerCoordinatorCore {
    // MARK: - Inputs

    /// One signed-in Telegram account.
    public struct SignedIn: Equatable, Hashable {
        /// The packed `PeerId.toInt64()`.
        public let accountPeerId: Int64
        /// The RAW Telegram user id (store keys, queue files).
        public let tg: Int64

        public init(accountPeerId: Int64, tg: Int64) {
            self.accountPeerId = accountPeerId
            self.tg = tg
        }
    }

    /// One account's persisted facts at the current authority, read before every event.
    public struct Facts: Equatable {
        // The consent store (`init(store:tg:authority:)` reads these).
        public var record: SGConsentRecord?
        /// `SGConsentStore.latestGrantRejection(...) != nil`.
        public var latestGrantRejected: Bool
        /// The record's grant is acked at this authority.
        public var latestGrantAcked: Bool
        /// `SGConsentStore.pendingUploads(...)`, oldest first.
        public var pendingUploads: [Data]
        public var latestDecision: Data?
        /// `zg.cs.consents_sent…`.
        public var consentsSentDeviceId: String?
        /// `zg.cs.not_linked…`.
        public var notLinkedDeviceId: String?
        /// `zg.cs.link_ended…`.
        public var linkEndedHandled: SGCustomerLinkState.Handled?
        /// `zg.cs.delete…` (the erasing fence).
        public var deletion: SGCustomerDeletion.Record?
        /// `zg.autolink.v1…`.
        public var autoLink: SGAutoLinkRecord
        // SGEntitlement (the driver adds these).
        /// The session's `device_id` while linked for the current origin; nil (or empty) = not linked.
        public var bindingDeviceId: String?
        /// `SGEntitlement.shared.sessionEnd(accountPeerId:)`.
        public var sessionEnd: SGCustomerLinkState.SessionEnd?
        /// `SGEntitlement.shared.profileSyncReceipt(accountPeerId:) != nil`.
        public var hasProfileReceipt: Bool
        /// `SGEntitlement.shared.bindPermission(accountPeerId:) == .allowed`.
        public var bindPermissionAllowed: Bool
        /// `SGEntitlement.shared.isBindInProgress(accountPeerId:)`.
        public var bindInProgress: Bool
        // Cadence, queue and budgets (the driver computes these with the core's helpers).
        /// `SGProfileSyncCadence.dueAt(...)`.
        public var syncDueAt: Date?
        /// `SGAnalyticsBatcher.flushDueAt(...)`.
        public var eventsDueAt: Date?
        /// `SGAnalyticsPipeline.queuedCount(tg:)`.
        public var queuedEvents: Int
        /// `SGCustomerBudget.nextAllowedAt(now:)` per route.
        public var budgetUntil: [SGCustomerRoute: Date]
        // This build's consent texts (the driver adds these; nil = not compared): a grant they treat as
        // stale (§4.6 rows 5–6, `SGCustomerClearance.Inputs.staleGrantNotice`) is cleared for nothing,
        // on every signed-in account — the wall normalises only the primary one's record.
        /// `SGConsentTextRepository.minValidVersion`.
        public var bundledMinValidVersion: Int?
        /// `SGCustomerClearance.renderedSha256(record:texts:operatorValues:)` with this build's operator values.
        public var renderedSha256ForRecord: String?

        public init(record: SGConsentRecord? = nil, latestGrantRejected: Bool = false, latestGrantAcked: Bool = false, pendingUploads: [Data] = [], latestDecision: Data? = nil, consentsSentDeviceId: String? = nil, notLinkedDeviceId: String? = nil, linkEndedHandled: SGCustomerLinkState.Handled? = nil, deletion: SGCustomerDeletion.Record? = nil, autoLink: SGAutoLinkRecord = SGAutoLinkRecord(), bindingDeviceId: String? = nil, sessionEnd: SGCustomerLinkState.SessionEnd? = nil, hasProfileReceipt: Bool = false, bindPermissionAllowed: Bool = false, bindInProgress: Bool = false, syncDueAt: Date? = nil, eventsDueAt: Date? = nil, queuedEvents: Int = 0, budgetUntil: [SGCustomerRoute: Date] = [:], bundledMinValidVersion: Int? = nil, renderedSha256ForRecord: String? = nil) {
            self.record = record
            self.latestGrantRejected = latestGrantRejected
            self.latestGrantAcked = latestGrantAcked
            self.pendingUploads = pendingUploads
            self.latestDecision = latestDecision
            self.consentsSentDeviceId = consentsSentDeviceId
            self.notLinkedDeviceId = notLinkedDeviceId
            self.linkEndedHandled = linkEndedHandled
            self.deletion = deletion
            self.autoLink = autoLink
            self.bindingDeviceId = bindingDeviceId
            self.sessionEnd = sessionEnd
            self.hasProfileReceipt = hasProfileReceipt
            self.bindPermissionAllowed = bindPermissionAllowed
            self.bindInProgress = bindInProgress
            self.syncDueAt = syncDueAt
            self.eventsDueAt = eventsDueAt
            self.queuedEvents = queuedEvents
            self.budgetUntil = budgetUntil
            self.bundledMinValidVersion = bundledMinValidVersion
            self.renderedSha256ForRecord = renderedSha256ForRecord
        }

        /// The consent-store half of the facts of account `tg` at `authority`; the SGEntitlement,
        /// cadence, queue and budget fields are left at their defaults for the driver to fill.
        public init(store: SGConsentStore, tg: Int64, authority: String) {
            let record = store.record(tg: tg)
            let grantId = record?.state == .granted ? record?.consentId : nil
            self.init(
                record: record,
                latestGrantRejected: store.latestGrantRejection(tg: tg, authority: authority) != nil,
                latestGrantAcked: grantId.map { store.isAcked(tg: tg, authority: authority, consentId: $0) } ?? false,
                pendingUploads: store.pendingUploads(tg: tg, authority: authority),
                latestDecision: store.latestDecision(tg: tg),
                consentsSentDeviceId: store.string(.consentsSent(tg: tg, authority: authority)),
                notLinkedDeviceId: store.string(.notLinked(tg: tg, authority: authority)),
                linkEndedHandled: SGCustomerLinkState.Handled(jsonObject: store.jsonObject(.linkEnded(tg: tg, authority: authority))),
                deletion: SGCustomerDeletion.Record(jsonObject: store.jsonObject(.deletion(tg: tg, authority: authority))),
                autoLink: SGAutoLinkRecord(jsonObject: store.jsonObject(.autoLink(tg: tg, authority: authority)))
            )
        }

        /// Linked for the current origin.
        public var isLinked: Bool {
            return self.bindingDeviceId.map { !$0.isEmpty } ?? false
        }

        /// What the account reads like right after the local erase.
        func erased() -> Facts {
            return Facts(bindPermissionAllowed: self.bindPermissionAllowed, bundledMinValidVersion: self.bundledMinValidVersion)
        }
    }

    /// Everything the reducer reads, fresh before every event.
    public struct Inputs: Equatable {
        /// `SGConsentStore.isReadable` (protected data and the canary): nothing is decided from
        /// storage while false, and every clearance is `[]`.
        public var readable: Bool
        /// The signed-in accounts' facts, by packed `accountPeerId`.
        public var accounts: [Int64: Facts]
        /// `SGConsentStore.knownTelegramUserIds()`.
        public var knownTelegramUserIds: [Int64]
        /// `SGAnalyticsQueueStore.queueOwners()` (nil: unreadable).
        public var queueOwners: [Int64]?
        /// `zg.autolink.install.v1@<authority>`.
        public var autoLinkInstall: SGAutoLinkInstallRecord
        /// `CFBundleShortVersionString`.
        public var appVersion: String
        /// `SGCustomerHints.eventsPausedUntil` (an `"ingest": "paused"` events answer).
        public var eventsPausedUntil: Date?

        public init(readable: Bool, accounts: [Int64: Facts], knownTelegramUserIds: [Int64] = [], queueOwners: [Int64]? = nil, autoLinkInstall: SGAutoLinkInstallRecord = SGAutoLinkInstallRecord(), appVersion: String, eventsPausedUntil: Date? = nil) {
            self.readable = readable
            self.accounts = accounts
            self.knownTelegramUserIds = knownTelegramUserIds
            self.queueOwners = queueOwners
            self.autoLinkInstall = autoLinkInstall
            self.appVersion = appVersion
            self.eventsPausedUntil = eventsPausedUntil
        }
    }

    // MARK: - Events and effects

    /// A timer the driver keeps per account (one per kind; scheduling again replaces it).
    public enum Timer: Hashable {
        /// The route's due time, backoff or budget (`delete`: its retry).
        case route(SGCustomerRoute)
        /// The automatic link's next possible attempt.
        case autoLink
    }

    /// One request of a `.call`. A request the driver cannot build when it runs (no snapshot yet, no
    /// batch) is reported as `.outcome(route, account, .notConfigured)`: nothing was sent, and the
    /// route waits its backoff. One whose account is no longer cleared for its route once its turn to
    /// be sent comes (`clearanceToSend`) is reported as `.notSent`: nothing was sent, and nothing waits.
    public enum Request: Equatable {
        /// `POST /v1/profile/consents` with exactly this body (one entry).
        case consents(Data)
        /// `POST /v1/profile/sync`: the driver builds the snapshot (`SGProfileSnapshot`) when it runs.
        case sync
        /// `POST /v1/profile/events`: the pipeline's next batch (`SGAnalyticsPipeline.nextBatch`);
        /// in the background at most one batch ≤ 64 KiB within 8 s (`SGAnalyticsBatcher`). The
        /// driver applies the answer to the batch (`SGAnalyticsBatcher.apply`, then
        /// `SGAnalyticsPipeline.complete`) before it reports `.outcome`.
        case events(background: Bool)
        /// `POST /v1/account/delete` with this `Idempotency-Key`.
        case delete(idempotencyKey: String)

        public var route: SGCustomerRoute {
            switch self {
            case .consents:
                return .consents
            case .sync:
                return .sync
            case .events:
                return .events
            case .delete:
                return .delete
            }
        }
    }

    public enum Event: Equatable {
        /// `activeAccountContexts` emitted: the signed-in accounts and the primary one. Delivered one
        /// main-queue turn after `SGAccountCleanup` has run, so `SGEntitlement.logout` has captured
        /// the final withdraw send before anything is purged. The first emission is the launch
        /// reconciliation.
        case accountsChanged(signedIn: [SignedIn], primary: Int64?)
        /// `SGEntitlement.didPassFirstIdleNotification` (or it had passed before the start).
        case firstIdle
        /// `willEnterForeground` / `didBecomeActive` (repeats are ignored until `.background`).
        case foreground
        /// `didEnterBackground` (inside the `zg.customer.flush` background task).
        case background
        /// `willTerminate` (best effort, no flush).
        case terminate
        /// `protectedDataDidBecomeAvailable`.
        case protectedDataAvailable
        /// `SGConsentStore.didChangeNotification`.
        case consentChanged(tg: Int64)
        /// `SGEntitlement.didChangeNotification`.
        case entitlementChanged
        /// A `.call` answered (`SGCustomerTransport.call`).
        case outcome(SGCustomerRoute, account: Int64, SGCustomerCallOutcome)
        /// A sync or events `.call` that was not sent: when its turn came (an account's calls go one at
        /// a time, so it may have waited behind another), the account was no longer cleared for its
        /// route (`clearanceToSend`). No receipt, no failure, no backoff.
        case notSent(SGCustomerRoute, account: Int64)
        /// A `.scheduleTimer` fired.
        case timer(account: Int64, Timer)
        /// The user confirmed Withdraw after `SGConsentStore.withdraw` succeeded, or tapped Retry on a
        /// pending withdrawal: the send goes at once.
        case userWithdrew(account: Int64)
        /// The user confirmed the deletion; `idempotencyKey` is a fresh uuid4, used only when no
        /// deletion is unresolved (an unresolved one keeps its key).
        case userDeleteConfirmed(account: Int64, idempotencyKey: String)
        /// A delete `.call` answered (`SGCustomerDeleteOutcome(answer)`).
        case deleteOutcome(account: Int64, SGCustomerDeleteOutcome)
        /// The automatic link ended; `attestOffered`: its start offered an attest block (the
        /// runner's attest closure ran).
        case autoLinkFinished(account: Int64, SGAutoLinkPolicy.Outcome, attestOffered: Bool)
        /// `SGCustomerLinkEvents` (the Link screen), synchronously. The reduction of `userWillUnlink`
        /// starts no consents, sync or events upload for the account, because the logout that
        /// follows removes its session. That logout's final send carries the newest pending
        /// withdrawals (at most three, best effort within 10 s, its answer not applied:
        /// `SGAccountReconcile.finalUploads`, `SGEntitlement.logout`) ahead of `/bind/revoke`, and
        /// each stays pending until a later link acks it. A withdraw send the user asked for stays
        /// requested: the next reduction sends it while the account is still linked, otherwise it
        /// waits for the next link. Queued events stay queued.
        case userWillUnlink(account: Int64)
        case userDidLink(account: Int64)
        case bindConsentStale(account: Int64, consentId: String?)

        /// The coordinator event of a Link-screen hook (`SGCustomerLinkEvents.install(handler:)`).
        public init(_ event: SGCustomerLinkEvents.Event) {
            switch event {
            case let .userWillUnlink(accountPeerId):
                self = .userWillUnlink(account: accountPeerId)
            case let .userDidLink(accountPeerId):
                self = .userDidLink(account: accountPeerId)
            case let .bindConsentStale(accountPeerId, consentId):
                self = .bindConsentStale(account: accountPeerId, consentId: consentId)
            }
        }
    }

    public enum Effect: Equatable {
        // The gate and the analytics sessions.
        /// `SGCustomerDataGate.shared.publish`, and the pipeline's accounts table
        /// (`recordingAllowed` = `.recordEvents`).
        case publishClearance(account: Int64, SGCustomerDataGate.Clearance)
        case sessionStart(account: Int64, SGAnalyticsSessionTrigger)
        case sessionEnd(account: Int64, SGAnalyticsSessionEndReason)
        // The network.
        /// Send `Request` under the account's current session. `budgeted`: an automatic call —
        /// record it in the route's device-wide budget (`SGCustomerBudget.record`).
        case call(account: Int64, Request, budgeted: Bool)
        /// `SGAutoLinkRunner`: `bindWithTelegramAttestation` for the account.
        case autoLink(account: Int64)
        case scheduleTimer(account: Int64, Timer, at: Date)
        // The consent store.
        /// `SGConsentStore.markNeedsReconsent(tg:notice:)`.
        case normalise(tg: Int64, notice: SGConsentStoredNotice)
        /// `SGConsentStore.normaliseAfterConsentStale(tg:consentId:)`: that grant → `needs_reconsent`
        /// / `link_ended` (a server-ended link, 409 `consent_stale`).
        case normaliseLinkEnded(tg: Int64, consentId: String?)
        case markAcked(tg: Int64, consentIds: [String])
        case markRejected(tg: Int64, consentId: String, code: String)
        case markWithdrawnRemote(tg: Int64, effectiveAt: String, consentId: String?)
        /// `setString(_, for: .consentsSent)`.
        case writeConsentsSent(tg: Int64, deviceId: String)
        /// `setString(_, for: .notLinked)`.
        case writeNotLinked(tg: Int64, deviceId: String)
        /// `setJSONObject(_, for: .linkEnded)`.
        case writeLinkEndedMarker(tg: Int64, SGCustomerLinkState.Handled)
        /// `setJSONObject(_, for: .deletion)` (nil removes the fence).
        case writeDeletion(tg: Int64, SGCustomerDeletion.Record?)
        /// `setJSONObject(_, for: .autoLink)` (nil removes it).
        case writeAutoLink(tg: Int64, SGAutoLinkRecord?)
        /// `setJSONObject(_, for: .autoLinkInstall)`.
        case writeAutoLinkInstall(SGAutoLinkInstallRecord)
        /// `SGConsentStore.setDeletedNotice(tg:at:)`.
        case writeDeletedNotice(tg: Int64, at: Date)
        /// `SGConsentStore.purge(tg:)`.
        case purgeConsent(tg: Int64)
        // The queue, SGEntitlement and Tasks.
        /// `SGAnalyticsPipeline.purge(tg:)`.
        case purgeQueue(tg: Int64)
        /// `SGEntitlement.clearProfileSyncReceipt(accountPeerId:)`.
        case clearReceipt(account: Int64)
        /// `SGEntitlement.recordProfileSync` with the digest of the snapshot just sent: delivered for
        /// this binding (a 2xx, or a final refusal — Contract issue 5) under the grant still in force,
        /// never for a sync a withdrawal superseded; `minIntervalS` → `SGCustomerHints.minIntervalS`
        /// when present.
        case recordSyncReceipt(account: Int64, minIntervalS: Int?)
        /// `SGEntitlement.forgetErasedAccount(accountPeerId:)`.
        case forgetErasedAccount(account: Int64)
        /// `SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId:)`.
        case tasksRetire(account: Int64)
        /// `SGTasksCloudRepository.purgeAfterAccountErasure(accountPeerId:)`.
        case tasksErased(account: Int64)
        // The screens and the log.
        /// For the deletion screen (and the done state).
        case deletionReport(account: Int64, SGCustomerDeletion.Report)
        /// `SGCustomerLog.log`.
        case log(SGCustomerLogCode)
    }

    // MARK: - State

    /// The coordinator's in-memory state (design 40 §6.2, the part that is not persisted). Start
    /// with `State(isForeground:autoLinkJitter:)` once per process.
    public struct State: Equatable {
        struct Account: Equatable {
            let tg: Int64
            /// The clearance last published (nil: never).
            var published: SGCustomerDataGate.Clearance?
            var inFlight = Set<SGCustomerRoute>()
            var backoff: [SGCustomerRoute: SGCustomerBackoff] = [:]
            /// The consents entry in flight.
            var sentConsents: SentConsents?
            /// The grant (`consent_id`) the sync in flight was sent under; nil once a withdrawal or the
            /// erase superseded it. Its answer records the receipt only while that grant is in force.
            var syncConsentId: String?
            /// `SGConsentReconciler`'s once-per-process re-upload.
            var reuploadSpent = false
            /// Routes stopped by `consent_required` until the record's decision or the binding changes.
            var stopped = Set<SGCustomerRoute>()
            var stopKey: StopKey?
            var timers: [Timer: Date] = [:]
            /// `.notPermitted` / `.notConfigured` until a consent or entitlement change.
            var autoLinkStopped = false
            /// The grant the automatic link in flight carried.
            var autoLinkConsentId: String?
            /// The local withdrawal (its `consent_id`) already acted on; a withdrawal on record when
            /// the account is first read belongs to an earlier process: its local steps run again
            /// (idempotent), its send is not repeated.
            var withdrawalBaselined = false
            var withdrawalSeen: String?
            /// A withdrawal waits for its user-initiated send.
            var userSendRequested = false
            /// The `sessionEnd` an `account_erased` erase already ran for.
            var erasedSessionEnd: Date?

            init(tg: Int64) {
                self.tg = tg
            }
        }

        enum ConsentsReason: Equatable {
            case pending
            case afterLink
            case reupload
            case user
        }

        struct SentConsents: Equatable {
            let entry: Data
            let reason: ConsentsReason
        }

        struct StopKey: Equatable {
            let consentId: String?
            let binding: String?
        }

        var accounts: [Int64: Account] = [:]
        public internal(set) var primary: Int64?
        public internal(set) var isForeground: Bool
        public internal(set) var firstIdleAt: Date?
        /// Uniform 0–30 s, drawn once per process (`SGAutoLinkPolicy.firstIdleJitter`).
        public let autoLinkJitter: TimeInterval
        /// The account whose automatic link runs (one on the install).
        public internal(set) var autoLinkInFlight: Int64?
        /// The account whose app session is open.
        public internal(set) var sessionAccount: Int64?
        var sessionsStarted = false
        var accountsKnown = false
        var reconcilePending = false
        var pendingPurge = Set<Int64>()
        var switchedAccount = false

        public init(isForeground: Bool = false, autoLinkJitter: TimeInterval) {
            self.isForeground = isForeground
            self.autoLinkJitter = autoLinkJitter
        }

        /// The signed-in accounts, ascending.
        public var accountPeerIds: [Int64] {
            return self.accounts.keys.sorted()
        }

        public func tg(accountPeerId: Int64) -> Int64? {
            return self.accounts[accountPeerId]?.tg
        }

        /// A request of `route` for the account is in flight (a screen shows its progress).
        public func isInFlight(_ route: SGCustomerRoute, accountPeerId: Int64) -> Bool {
            return self.accounts[accountPeerId]?.inFlight.contains(route) ?? false
        }

        /// The clearance last published for the account (`[]` before the first).
        public func publishedClearance(accountPeerId: Int64) -> SGCustomerDataGate.Clearance {
            return self.accounts[accountPeerId]?.published ?? []
        }
    }

    // MARK: - Reducer

    /// The effects of `event`, in the order the driver runs them. `now` is the server-offset clock
    /// (`SGEntitlement.shared.entitlementClock.effectiveNow()`), the clock the records use; `random`
    /// draws from [0, 1) for the backoff and ladder jitter.
    public static func reduce(_ state: State, _ event: Event, inputs: Inputs, now: Date, random: @escaping () -> Double = { Double.random(in: 0 ..< 1) }) -> (state: State, effects: [Effect]) {
        var reduction = Reduction(state: state, inputs: inputs, now: now, random: random)
        reduction.apply(event)
        reduction.reconcileIfPending()
        reduction.settle()
        return (reduction.state, reduction.effects)
    }

    /// Whether a sync answer records the snapshot as delivered for the binding (`.recordSyncReceipt`):
    /// a 2xx (stored or paused), and a final refusal — 409 / 413 / 422 / another 4xx, kept as done
    /// for the binding so it never stalls events and Tasks (Contract issue 5). Everything else is
    /// retried.
    public static func syncDelivered(_ outcome: SGCustomerCallOutcome) -> (delivered: Bool, minIntervalS: Int?) {
        switch outcome {
        case let .ok(body):
            return (true, SGProfileSyncResponse.decode(body)?.minIntervalS)
        case .terminal, .accountMismatch, .payloadTooLarge:
            return (true, nil)
        default:
            return (false, nil)
        }
    }

    /// What a `.call` on `route` still needs when its turn to be sent comes — an account's calls go
    /// one at a time (`SGCustomerTransportLive`), so it may have waited behind another: a sync
    /// `.uploadProfile`, an events batch `.uploadEvents`. The consents (a withdrawal must reach the
    /// server), `me` and `delete` need nothing. A call whose account lost it meanwhile — a
    /// withdrawal, a deletion, an ended link — sends nothing and is reported as `.notSent`.
    public static func clearanceToSend(_ route: SGCustomerRoute) -> SGCustomerDataGate.Clearance {
        switch route {
        case .sync:
            return .uploadProfile
        case .events:
            return .uploadEvents
        case .consents, .me, .delete:
            return []
        }
    }

    /// The `error.occurred` input of a failed automatic call (design 40 §10.2: `consent_upload`,
    /// `profile_sync`, `events_upload`; the code is the call's stable log code); nil for a success,
    /// a call that sent nothing, and the user-initiated routes.
    public static func callError(route: SGCustomerRoute, outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer) -> SGAnalyticsInput? {
        let domain: SGAnalyticsErrorDomain
        switch route {
        case .consents:
            domain = .consentUpload
        case .sync:
            domain = .profileSync
        case .events:
            domain = .eventsUpload
        case .me, .delete:
            return nil
        }
        switch outcome {
        case .ok, .credentialChanged, .notLinkedLocally, .notConfigured:
            return nil
        default:
            return .error(domain, SGAnalyticsErrorCode(SGCustomerWire.logCode(outcome, answer: answer).rawValue) ?? .unknown)
        }
    }
}

extension SGCustomerLogCode {
    public static let linkEndedNormalised = SGCustomerLogCode("link_ended_normalised")
    public static let accountErasedLocally = SGCustomerLogCode("account_erased_locally")
    public static let consentsAnswerUnreadable = SGCustomerLogCode("consents_answer_unreadable")
}

// MARK: - One reduction

private struct Reduction {
    typealias Core = SGCustomerCoordinatorCore
    typealias Facts = SGCustomerCoordinatorCore.Facts

    var state: Core.State
    var inputs: Core.Inputs
    let now: Date
    let random: () -> Double
    var effects: [Core.Effect] = []
    /// The account whose `.userWillUnlink` this reduction applies: `settle` starts no upload for it
    /// (`Event.userWillUnlink`). Per reduction, never in `State`, so it cannot outlive the event.
    var unlinking: Int64?

    init(state: Core.State, inputs: Core.Inputs, now: Date, random: @escaping () -> Double) {
        self.state = state
        self.inputs = inputs
        self.now = now
        self.random = random
    }

    // MARK: Events

    mutating func apply(_ event: Core.Event) {
        switch event {
        case let .accountsChanged(signedIn, primary):
            self.accountsChanged(signedIn, primary: primary)
        case .firstIdle:
            if self.state.firstIdleAt == nil {
                self.state.firstIdleAt = self.now
            }
            self.resumeDeletions()
        case .foreground:
            self.state.isForeground = true
            self.resumeDeletions()
        case .background:
            if self.state.isForeground {
                self.state.isForeground = false
                self.endSession(.background)
            }
            self.backgroundFlush()
        case .terminate:
            self.state.isForeground = false
            self.endSession(.terminate)
        case .protectedDataAvailable:
            // Everything is decided again below, now from readable storage.
            break
        case let .consentChanged(tg):
            for (account, value) in self.state.accounts where value.tg == tg {
                self.state.accounts[account]?.autoLinkStopped = false
            }
        case .entitlementChanged:
            for account in self.state.accounts.keys {
                self.state.accounts[account]?.autoLinkStopped = false
            }
        case let .outcome(route, account, outcome):
            if route == .delete {
                self.deletionAnswered(account, SGCustomerDeleteOutcome(outcome: outcome))
            } else {
                self.answered(route, account: account, outcome: outcome)
            }
        case let .notSent(route, account):
            self.notSent(route, account: account)
        case let .timer(account, timer):
            self.state.accounts[account]?.timers[timer] = nil
            if timer == .route(.delete) {
                self.resumeDeletion(account)
            }
        case let .userWithdrew(account):
            guard var value = self.state.accounts[account] else {
                return
            }
            if !value.withdrawalBaselined {
                // Not read since the account appeared: the withdrawal on record is this user's new one,
                // so it gets the whole sequence rather than being taken for an earlier process's.
                value.withdrawalBaselined = true
            }
            if value.sentConsents?.reason != .user {
                value.userSendRequested = true
            }
            self.state.accounts[account] = value
        case let .userDeleteConfirmed(account, key):
            self.confirmDeletion(account, key: key)
        case let .deleteOutcome(account, outcome):
            self.deletionAnswered(account, outcome)
        case let .autoLinkFinished(account, outcome, attestOffered):
            self.autoLinkFinished(account, outcome: outcome, attestOffered: attestOffered)
        case let .userWillUnlink(account):
            self.unlinking = account
            self.setUnlinkSuppression(account, suppressed: true)
        case let .userDidLink(account):
            self.setUnlinkSuppression(account, suppressed: false)
        case let .bindConsentStale(account, consentId):
            if let tg = self.state.accounts[account]?.tg, self.facts(account) != nil {
                self.emit(.log(.consentStale))
                self.normaliseLinkEnded(account, tg: tg, consentId: consentId)
            }
        }
    }

    mutating func accountsChanged(_ signedIn: [Core.SignedIn], primary: Int64?) {
        let ids = Set(signedIn.map(\.accountPeerId))
        for (account, value) in self.state.accounts.sorted(by: { $0.key < $1.key }) where !ids.contains(account) {
            // Signed out: the gate at once; its keys and queue go with the purge set. No session end
            // (iOS never sends `logout`: the queue is purged).
            self.emit(.publishClearance(account: account, []))
            self.state.accounts[account] = nil
            self.state.pendingPurge.insert(value.tg)
            if self.state.sessionAccount == account {
                self.state.sessionAccount = nil
            }
        }
        for item in signedIn where self.state.accounts[item.accountPeerId] == nil {
            self.state.accounts[item.accountPeerId] = Core.State.Account(tg: item.tg)
        }
        let previous = self.state.primary
        self.state.primary = primary
        if self.state.accountsKnown, previous != primary, self.state.isForeground {
            if let open = self.state.sessionAccount {
                self.emit(.sessionEnd(account: open, .accountSwitch))
                self.state.sessionAccount = nil
            }
            self.state.switchedAccount = true
        }
        self.state.accountsKnown = true
        // The purge set is decided again (launch reconciliation, logout), once readable.
        self.state.reconcilePending = true
    }

    mutating func reconcileIfPending() {
        guard self.state.reconcilePending, self.inputs.readable, let owners = self.inputs.queueOwners else {
            return
        }
        let signedIn = Set(self.state.accounts.values.map(\.tg))
        let known = self.inputs.knownTelegramUserIds + self.state.pendingPurge.sorted()
        for tg in SGAccountReconcile.purgeSet(known: known, queueOwners: owners, signedIn: signedIn, readable: true) {
            self.emit(.purgeConsent(tg: tg))
            self.emit(.purgeQueue(tg: tg))
        }
        self.state.pendingPurge = []
        self.state.reconcilePending = false
    }

    // MARK: Settling every account

    mutating func settle() {
        for account in self.state.accounts.keys.sorted() {
            self.settle(account)
        }
        self.autoLinkPass()
        self.state.switchedAccount = false
    }

    mutating func settle(_ account: Int64) {
        guard let tg = self.state.accounts[account]?.tg else {
            return
        }
        guard self.facts(account) != nil else {
            // Unreadable (or not read): fail closed, decide nothing from storage.
            self.publish(account, [])
            self.followSession(account, clearance: [])
            return
        }
        self.followSessionEnd(account, tg: tg)
        self.followWithdrawal(account, tg: tg)
        // An Unlink's own reduction starts no upload for its account: the logout right after it
        // removes the session (`Event.userWillUnlink`).
        let uploads = self.unlinking != account
        if uploads {
            self.sendUserWithdrawal(account)
        }
        let clearance = self.facts(account).map { SGCustomerClearance.derive(self.clearanceInputs($0)) } ?? []
        self.publish(account, clearance)
        self.followSession(account, clearance: clearance)
        self.refreshStops(account)
        if uploads {
            self.plan(account)
        }
    }

    /// §8.1: a binding the server ended, or an erased account.
    mutating func followSessionEnd(_ account: Int64, tg: Int64) {
        guard let facts = self.facts(account) else {
            return
        }
        switch SGCustomerLinkState.decide(record: facts.record, sessionEnd: facts.sessionEnd, handled: facts.linkEndedHandled) {
        case .none:
            break
        case .accountErased:
            guard let end = facts.sessionEnd, self.state.accounts[account]?.erasedSessionEnd != end.at else {
                return
            }
            self.state.accounts[account]?.erasedSessionEnd = end.at
            self.erase(account)
        case let .normalise(consentId):
            self.emit(.log(.linkEndedNormalised))
            self.normaliseLinkEnded(account, tg: tg, consentId: consentId)
        case let .markHandled(handled):
            self.emit(.writeLinkEndedMarker(tg: tg, handled))
            self.inputs.accounts[account]?.linkEndedHandled = handled
        }
    }

    /// A withdrawal made on this device: gate → queue → receipt → Tasks, then the send (§6.6, §11.2).
    mutating func followWithdrawal(_ account: Int64, tg: Int64) {
        guard let facts = self.facts(account), var value = self.state.accounts[account] else {
            return
        }
        let withdrawal = facts.record?.state == .withdrawn ? facts.record?.consentId : nil
        guard value.withdrawalBaselined else {
            value.withdrawalBaselined = true
            value.withdrawalSeen = withdrawal
            self.state.accounts[account] = value
            // Withdrawn here or on another device in an earlier process, which may have died between
            // the record and its effects: leftover events or unsent Tasks edits would otherwise go out
            // after a re-grant (C§6.7). The local steps run again, once per process; the send does not
            // (still pending, the planner delivers it).
            if let state = facts.record?.state, state == .withdrawn || state == .withdrawnRemote {
                self.withdrawalEffects(account, tg: tg)
            }
            return
        }
        guard let withdrawal, withdrawal != value.withdrawalSeen else {
            return
        }
        value.withdrawalSeen = withdrawal
        value.userSendRequested = true
        self.state.accounts[account] = value
        self.withdrawalEffects(account, tg: tg)
    }

    /// The local steps of a withdrawal, in this order: gate `[]` → queue purge → receipt clear →
    /// Tasks retire. Each is idempotent: the queue is not recorded into while withdrawn, the receipt
    /// is cleared only when present, and a repeated retire finds no unsent change and a released
    /// record (`SGTasksCloudRepository.retireForConsentWithdrawal`).
    mutating func withdrawalEffects(_ account: Int64, tg: Int64) {
        self.state.accounts[account]?.published = []
        // A sync in flight went under the grant just withdrawn: its answer records no receipt.
        self.state.accounts[account]?.syncConsentId = nil
        self.emit(.publishClearance(account: account, []))
        self.emit(.purgeQueue(tg: tg))
        self.emit(.clearReceipt(account: account))
        self.inputs.accounts[account]?.hasProfileReceipt = false
        self.emit(.tasksRetire(account: account))
    }

    /// The withdraw goes at once (user-initiated: no first idle, no budget, no backoff), one
    /// consents request at a time. Without a binding it waits for the next link or the logout's
    /// final send. An Unlink's own reduction does not call it for the account (`settle`): the
    /// request stays set, so the next reduction sends it while the account is still linked.
    mutating func sendUserWithdrawal(_ account: Int64) {
        guard let facts = self.facts(account), let value = self.state.accounts[account], value.userSendRequested, !value.inFlight.contains(.consents) else {
            return
        }
        self.state.accounts[account]?.userSendRequested = false
        guard facts.isLinked, let entry = Reduction.pendingWithdrawal(facts), let body = SGConsentsRequest.body(events: [entry]) else {
            return
        }
        self.sendConsents(account, entry: entry, body: body, reason: .user, budgeted: false)
    }

    mutating func followSession(_ account: Int64, clearance: SGCustomerDataGate.Clearance) {
        if self.state.sessionAccount == account, !clearance.contains(.recordEvents) {
            // Recording stopped (withdrawal, deletion, an ended link): the queue is purged or fenced.
            self.state.sessionAccount = nil
        }
        guard self.state.isForeground, self.state.accountsKnown, self.state.primary == account, self.state.sessionAccount == nil, clearance.contains(.recordEvents) else {
            return
        }
        let trigger: SGAnalyticsSessionTrigger
        if self.state.switchedAccount {
            trigger = .accountSwitch
        } else {
            trigger = self.state.sessionsStarted ? .foreground : .launch
        }
        self.emit(.sessionStart(account: account, trigger))
        self.state.sessionAccount = account
        self.state.sessionsStarted = true
    }

    mutating func endSession(_ reason: SGAnalyticsSessionEndReason) {
        if let open = self.state.sessionAccount {
            self.emit(.sessionEnd(account: open, reason))
            self.state.sessionAccount = nil
        }
    }

    /// A `consent_required` stop lasts until the record's decision or the binding changes.
    mutating func refreshStops(_ account: Int64) {
        guard let facts = self.facts(account) else {
            return
        }
        let key = Core.State.StopKey(consentId: facts.record?.consentId, binding: facts.bindingDeviceId)
        if self.state.accounts[account]?.stopKey != key {
            self.state.accounts[account]?.stopped = []
            self.state.accounts[account]?.stopKey = key
        }
    }

    // MARK: Uploads (§6.3)

    mutating func plan(_ account: Int64) {
        guard let facts = self.facts(account), let value = self.state.accounts[account] else {
            return
        }
        var planned = SGCustomerUploadPlanner.Account(
            clearance: self.clearanceInputs(facts),
            recordConsentId: facts.record?.consentId,
            firstIdlePassed: self.state.firstIdleAt != nil,
            pendingUploads: facts.pendingUploads,
            latestDecision: facts.latestDecision,
            consentsSentDeviceId: facts.consentsSentDeviceId,
            syncDueAt: facts.syncDueAt,
            eventsDueAt: facts.eventsDueAt,
            // A stopped route is skipped like one in flight.
            inFlight: value.inFlight.union(value.stopped),
            backoffUntil: value.backoff.compactMapValues(\.nextAt),
            budgetUntil: facts.budgetUntil
        )
        for _ in 0 ..< 3 {
            switch SGCustomerUploadPlanner.next(planned, now: self.now) {
            case let .consents(entry, reason):
                guard let body = SGConsentsRequest.body(events: [entry]) else {
                    return
                }
                self.sendConsents(account, entry: entry, body: body, reason: reason == .afterLink ? .afterLink : .pending, budgeted: true)
                planned.inFlight.insert(.consents)
            case .sync:
                self.send(account, .sync)
                self.state.accounts[account]?.syncConsentId = facts.record?.consentId
                planned.inFlight.insert(.sync)
            case .events:
                self.send(account, .events(background: false))
                planned.inFlight.insert(.events)
            case let .wait(route, until):
                self.schedule(account, .route(route), at: until)
                return
            case .autoLink, .none:
                // The automatic link is decided once for the install (`autoLinkPass`).
                return
            }
        }
    }

    /// `didEnterBackground`: one batch per account with events to upload.
    mutating func backgroundFlush() {
        guard self.state.firstIdleAt != nil, self.inputs.eventsPausedUntil.map({ $0 <= self.now }) ?? true else {
            return
        }
        for account in self.state.accounts.keys.sorted() {
            guard let facts = self.facts(account), let value = self.state.accounts[account], facts.queuedEvents > 0,
                  !value.inFlight.contains(.events), !value.stopped.contains(.events),
                  SGCustomerClearance.derive(self.clearanceInputs(facts)).contains(.uploadEvents),
                  value.backoff[.events]?.allows(now: self.now) ?? true,
                  facts.budgetUntil[.events].map({ $0 <= self.now }) ?? true else {
                continue
            }
            self.send(account, .events(background: true))
        }
    }

    mutating func answered(_ route: SGCustomerRoute, account: Int64, outcome: SGCustomerCallOutcome) {
        guard var value = self.state.accounts[account], value.inFlight.contains(route) else {
            return
        }
        value.inFlight.remove(route)
        let sent = route == .consents ? value.sentConsents : nil
        if route == .consents {
            value.sentConsents = nil
        }
        let syncConsentId = route == .sync ? value.syncConsentId : nil
        if route == .sync {
            value.syncConsentId = nil
        }
        var backoff = value.backoff[route] ?? SGCustomerBackoff()
        switch outcome {
        case .session, .notConfigured:
            // A 401 that left the session in place (a lasting clock or signing problem), or nothing
            // could be sent (no snapshot, no batch): the route waits rather than going again at once.
            backoff.recordFailure(now: self.now, random: self.random)
        default:
            backoff.apply(outcome, now: self.now, random: self.random)
        }
        value.backoff[route] = backoff
        if case .credentialChanged = outcome, sent?.reason == .user {
            // The user's send goes again as soon as it can.
            value.userSendRequested = true
        }
        self.state.accounts[account] = value
        let tg = value.tg

        switch SGCustomerLinkState.signal(outcome) {
        case .accountErased:
            self.erase(account)
            return
        case .consentStale:
            if let facts = self.facts(account) {
                self.emit(.log(.consentStale))
                self.normaliseLinkEnded(account, tg: tg, consentId: facts.record?.consentId)
            }
            return
        case nil:
            break
        }
        guard let facts = self.facts(account) else {
            return
        }
        switch outcome {
        case .accountNotLinked:
            if let binding = facts.bindingDeviceId, facts.isLinked, facts.notLinkedDeviceId != binding {
                self.emit(.writeNotLinked(tg: tg, deviceId: binding))
                self.inputs.accounts[account]?.notLinkedDeviceId = binding
            }
        case let .consentRequired(extras) where route == .sync || route == .events:
            self.consentRequired(account, tg: tg, route: route, extras: extras)
        default:
            break
        }
        switch route {
        case .consents:
            if let sent {
                self.consentsAnswered(account, tg: tg, sent: sent, outcome: outcome)
            }
        case .sync:
            let delivered = Core.syncDelivered(outcome)
            // The receipt says the server keeps this snapshot under the grant in force. A sync sent
            // under an earlier grant is superseded: a withdrawal since deletes the profile on the
            // server (C§9.3), and a receipt left behind would give a re-grant events and Tasks before
            // its own sync (C§6.4 step 4). Granted, acked and linked come with `.uploadProfile`.
            if delivered.delivered, let syncConsentId, syncConsentId == facts.record?.consentId,
               SGCustomerClearance.derive(self.clearanceInputs(facts)).contains(.uploadProfile) {
                self.emit(.recordSyncReceipt(account: account, minIntervalS: delivered.minIntervalS))
                self.inputs.accounts[account]?.hasProfileReceipt = true
                self.inputs.accounts[account]?.syncDueAt = nil
            }
        case .events, .me, .delete:
            break
        }
    }

    /// A call that found its account no longer cleared for its route when its turn came: nothing
    /// went out, so the route is free again with no receipt, no failure counted and no backoff. The
    /// next pass plans again from the account's clearance now.
    mutating func notSent(_ route: SGCustomerRoute, account: Int64) {
        guard var value = self.state.accounts[account], value.inFlight.contains(route) else {
            return
        }
        value.inFlight.remove(route)
        switch route {
        case .sync:
            value.syncConsentId = nil
        case .consents:
            value.sentConsents = nil
        case .events, .me, .delete:
            break
        }
        self.state.accounts[account] = value
    }

    mutating func consentsAnswered(_ account: Int64, tg: Int64, sent: Core.State.SentConsents, outcome: SGCustomerCallOutcome) {
        guard let facts = self.facts(account), let event = SGConsentEvent.decode(sent.entry) else {
            return
        }
        switch outcome {
        case let .ok(body):
            guard let response = SGConsentsResponse.decode(body) else {
                self.emit(.log(.consentsAnswerUnreadable))
                self.holdConsents(account)
                return
            }
            let result = SGConsentReconciler.onConsentsResponse(response, sent: [event], record: facts.record)
            if !result.acked.contains(event.consentId) {
                // A 200 that did not take the entry (an outcome this build does not know): it stays
                // pending, but not for an immediate resend.
                self.holdConsents(account)
            }
            if !result.acked.isEmpty {
                self.emit(.markAcked(tg: tg, consentIds: result.acked))
                let acked = Set(result.acked)
                self.inputs.accounts[account]?.pendingUploads = facts.pendingUploads.filter { entry in
                    return SGConsentEvent.decode(entry).map { !acked.contains($0.consentId) } ?? true
                }
                if facts.record?.state == .granted, let grantId = facts.record?.consentId, acked.contains(grantId) {
                    self.inputs.accounts[account]?.latestGrantAcked = true
                }
            }
            switch result.action {
            case let .markWithdrawnRemote(effectiveAt, consentId):
                self.withdrawnRemotely(account, tg: tg, effectiveAt: effectiveAt, consentId: consentId)
            case let .markNeedsReconsent(notice):
                self.emit(.log(notice == .linkEnded ? .consentForeignDuplicate : .consentNeedsReconsent))
                self.normalise(account, tg: tg, notice: notice)
            case .none, .reuploadThenRetryOnce, .stop:
                break
            }
            // "Always after a link": the binding has the decisions once its post-link re-send — or
            // any 200 that leaves nothing pending — went through.
            if let current = self.inputs.accounts[account], current.isLinked, let binding = current.bindingDeviceId, current.consentsSentDeviceId != binding,
               sent.reason == .afterLink || current.pendingUploads.isEmpty {
                self.emit(.writeConsentsSent(tg: tg, deviceId: binding))
                self.inputs.accounts[account]?.consentsSentDeviceId = binding
            }
        case let .terminal(status, code):
            self.consentsRefused(account, tg: tg, event: event, status: status, code: code)
        case .accountMismatch:
            self.consentsRefused(account, tg: tg, event: event, status: 409, code: "profile_account_mismatch")
        case .payloadTooLarge:
            self.consentsRefused(account, tg: tg, event: event, status: 413, code: "payload_too_large")
        default:
            break
        }
    }

    mutating func holdConsents(_ account: Int64) {
        var backoff = self.state.accounts[account]?.backoff[.consents] ?? SGCustomerBackoff()
        backoff.recordFailure(now: self.now, random: self.random)
        self.state.accounts[account]?.backoff[.consents] = backoff
    }

    mutating func consentsRefused(_ account: Int64, tg: Int64, event: SGConsentEvent, status: Int, code: String?) {
        switch SGConsentReconciler.onConsentsTerminal(status: status, code: code, field: nil, sent: [event]) {
        case let .markRejected(consentId, code):
            self.emit(.log(.consentRejected))
            self.emit(.markRejected(tg: tg, consentId: consentId, code: code))
            if let facts = self.facts(account) {
                self.inputs.accounts[account]?.pendingUploads = facts.pendingUploads.filter { SGConsentEvent.decode($0)?.consentId != consentId }
                if facts.record?.consentId == consentId {
                    self.inputs.accounts[account]?.latestGrantRejected = true
                }
            }
        case let .keep(code):
            // A withdraw is never rejected: it stays in the outbox (a client bug if it happens).
            self.emit(.log(.consentWithdrawKept))
            self.emit(.log(code))
        case .unattributed:
            break
        }
    }

    /// 403 `consent_required` on sync or events (C§6.3).
    mutating func consentRequired(_ account: Int64, tg: Int64, route: SGCustomerRoute, extras: SGConsentRequiredExtras) {
        guard let facts = self.facts(account), let value = self.state.accounts[account] else {
            return
        }
        switch SGConsentReconciler.onConsentRequired(extras, record: facts.record, didReuploadThisProcess: value.reuploadSpent) {
        case .none:
            break
        case .reuploadThenRetryOnce:
            // The grant goes again now; the failed call follows through the planner once it is in.
            self.state.accounts[account]?.reuploadSpent = true
            self.emit(.log(.consentReupload))
            if !value.inFlight.contains(.consents), let entry = Reduction.reuploadEntry(facts), let body = SGConsentsRequest.body(events: [entry]) {
                self.sendConsents(account, entry: entry, body: body, reason: .reupload, budgeted: true)
            }
        case .stop:
            self.state.accounts[account]?.stopped.insert(route)
            self.state.accounts[account]?.stopKey = Core.State.StopKey(consentId: facts.record?.consentId, binding: facts.bindingDeviceId)
        case let .markWithdrawnRemote(effectiveAt, consentId):
            self.withdrawnRemotely(account, tg: tg, effectiveAt: effectiveAt, consentId: consentId)
        case let .markNeedsReconsent(notice):
            self.emit(.log(.consentNeedsReconsent))
            self.normalise(account, tg: tg, notice: notice)
        }
    }

    /// Withdrawn on another device: stop profile, events and Tasks traffic, drop the queue and
    /// retire the Tasks outbox (C§6.3; T§3.12 — the same seam as a local withdrawal).
    mutating func withdrawnRemotely(_ account: Int64, tg: Int64, effectiveAt: String, consentId: String?) {
        self.emit(.log(.consentWithdrawnRemote))
        self.emit(.markWithdrawnRemote(tg: tg, effectiveAt: effectiveAt, consentId: consentId))
        if var record = self.inputs.accounts[account]?.record, record.state == .granted || record.state == .needsReconsent {
            record.state = .withdrawnRemote
            record.consentId = consentId ?? record.consentId
            record.decidedAt = effectiveAt
            self.inputs.accounts[account]?.record = record
        }
        self.withdrawalEffects(account, tg: tg)
    }

    // MARK: Deletion (§11.4)

    mutating func confirmDeletion(_ account: Int64, key: String) {
        guard let value = self.state.accounts[account], !value.inFlight.contains(.delete) else {
            return
        }
        guard let facts = self.facts(account) else {
            // The fence cannot be written while the store is unreadable: nothing is sent.
            self.emit(.deletionReport(account: account, .notDeleted(.failed)))
            return
        }
        if facts.deletion != nil {
            // An unresolved deletion: its own key goes again.
            self.resumeDeletion(account)
            return
        }
        guard facts.isLinked else {
            self.emit(.deletionReport(account: account, .notDeleted(.notLinked)))
            return
        }
        guard let record = SGCustomerDeletion.Record.begin(key: key, now: self.now) else {
            self.emit(.deletionReport(account: account, .notDeleted(.failed)))
            return
        }
        // The fence before the first send: from here on the account is erasing.
        self.emit(.writeDeletion(tg: value.tg, record))
        self.inputs.accounts[account]?.deletion = record
        self.emit(.publishClearance(account: account, []))
        self.state.accounts[account]?.published = []
        self.sendDelete(account, record: record)
    }

    mutating func resumeDeletions() {
        for account in self.state.accounts.keys.sorted() {
            self.resumeDeletion(account)
        }
    }

    mutating func resumeDeletion(_ account: Int64) {
        guard let value = self.state.accounts[account], !value.inFlight.contains(.delete), let facts = self.facts(account), let record = facts.deletion else {
            return
        }
        switch SGCustomerDeletion.resume(record, isLinked: facts.isLinked, sessionEnd: facts.sessionEnd) {
        case let .send(updated):
            if updated != record {
                self.emit(.writeDeletion(tg: value.tg, updated))
                self.inputs.accounts[account]?.deletion = updated
            }
            self.sendDelete(account, record: updated)
        case .deleted:
            self.erase(account)
        case let .notDeleted(notice):
            self.liftDeletion(account, tg: value.tg, notice: notice)
        }
    }

    mutating func deletionAnswered(_ account: Int64, _ outcome: SGCustomerDeleteOutcome) {
        guard let value = self.state.accounts[account], value.inFlight.contains(.delete) else {
            return
        }
        self.state.accounts[account]?.inFlight.remove(.delete)
        guard let facts = self.facts(account), let record = facts.deletion else {
            return
        }
        switch SGCustomerDeletion.decide(record, outcome: outcome, sessionEnd: facts.sessionEnd) {
        case .deleted:
            self.erase(account)
        case let .notDeleted(notice):
            self.liftDeletion(account, tg: value.tg, notice: notice)
        case let .retry(updated, retry, notice):
            if updated != record {
                self.emit(.writeDeletion(tg: value.tg, updated))
                self.inputs.accounts[account]?.deletion = updated
            }
            self.emit(.deletionReport(account: account, .pending(notice)))
            switch retry {
            case .immediately:
                self.sendDelete(account, record: updated)
            case let .after(delay):
                self.schedule(account, .route(.delete), at: self.now.addingTimeInterval(delay))
            case .backoff:
                var backoff = value.backoff[.delete] ?? SGCustomerBackoff()
                backoff.apply(outcome.outcome, now: self.now, random: self.random)
                self.state.accounts[account]?.backoff[.delete] = backoff
                self.schedule(account, .route(.delete), at: backoff.nextAt ?? self.now.addingTimeInterval(SGCustomerBackoff.base))
            }
        }
    }

    mutating func sendDelete(_ account: Int64, record: SGCustomerDeletion.Record) {
        // User-initiated: no first idle, no budget, no backoff.
        self.emit(.call(account: account, .delete(idempotencyKey: record.key), budgeted: false))
        self.state.accounts[account]?.inFlight.insert(.delete)
    }

    /// Nothing was deleted: the fence goes, the account is usable again.
    mutating func liftDeletion(_ account: Int64, tg: Int64, notice: SGCustomerDeletion.Notice) {
        self.emit(.writeDeletion(tg: tg, nil))
        self.inputs.accounts[account]?.deletion = nil
        self.state.accounts[account]?.backoff[.delete] = nil
        self.emit(.deletionReport(account: account, .notDeleted(notice)))
    }

    /// The local erase of a deleted account (§11.4, this order), with no network call.
    mutating func erase(_ account: Int64) {
        guard var value = self.state.accounts[account] else {
            return
        }
        let tg = value.tg
        self.emit(.forgetErasedAccount(account: account))
        self.emit(.tasksErased(account: account))
        self.emit(.purgeQueue(tg: tg))
        self.emit(.publishClearance(account: account, []))
        self.emit(.purgeConsent(tg: tg))
        self.emit(.writeAutoLink(tg: tg, nil))
        self.emit(.writeDeletion(tg: tg, nil))
        self.emit(.writeDeletedNotice(tg: tg, at: self.now))
        self.emit(.deletionReport(account: account, .deleted))
        self.emit(.log(.accountErasedLocally))
        value.published = []
        value.inFlight = []
        value.sentConsents = nil
        value.syncConsentId = nil
        value.backoff = [:]
        value.userSendRequested = false
        value.withdrawalSeen = nil
        self.state.accounts[account] = value
        if self.state.sessionAccount == account {
            self.state.sessionAccount = nil
        }
        if let facts = self.inputs.accounts[account] {
            self.inputs.accounts[account] = facts.erased()
        }
    }

    // MARK: Automatic link (§8)

    mutating func autoLinkPass() {
        guard self.inputs.readable else {
            return
        }
        // The install-wide ladder starts afresh with every app version.
        let install = self.inputs.autoLinkInstall.forAppVersion(self.inputs.appVersion)
        if install != self.inputs.autoLinkInstall {
            self.emit(.writeAutoLinkInstall(install))
            self.inputs.autoLinkInstall = install
        }
        guard self.state.autoLinkInFlight == nil else {
            return
        }
        var order = self.state.accounts.keys.sorted()
        if let primary = self.state.primary, let index = order.firstIndex(of: primary) {
            order.remove(at: index)
            order.insert(primary, at: 0)
        }
        for account in order {
            guard let value = self.state.accounts[account], let facts = self.facts(account) else {
                continue
            }
            let inputs = SGAutoLinkPolicy.Inputs(
                readable: true,
                state: self.linkState(facts),
                latestGrantRejected: facts.latestGrantRejected,
                linkEnded: SGCustomerLinkState.linkEnded(record: facts.record, sessionEnd: facts.sessionEnd, handled: facts.linkEndedHandled),
                erasing: facts.deletion != nil,
                isLinked: facts.isLinked,
                bindPermissionAllowed: facts.bindPermissionAllowed,
                bindInProgress: facts.bindInProgress,
                stopped: value.autoLinkStopped,
                record: facts.autoLink,
                install: self.inputs.autoLinkInstall,
                firstIdleAt: self.state.firstIdleAt,
                firstIdleJitter: self.state.autoLinkJitter,
                inFlight: false
            )
            switch SGAutoLinkPolicy.decide(inputs, now: self.now) {
            case .run:
                let record = facts.autoLink.recordingStart(at: self.now)
                self.emit(.writeAutoLink(tg: value.tg, record))
                self.inputs.accounts[account]?.autoLink = record
                self.emit(.autoLink(account: account))
                self.state.autoLinkInFlight = account
                self.state.accounts[account]?.autoLinkConsentId = facts.record?.consentId
                self.state.accounts[account]?.timers[.autoLink] = nil
                return
            case let .wait(until):
                self.schedule(account, .autoLink, at: until)
            case .blocked:
                break
            }
        }
    }

    mutating func autoLinkFinished(_ account: Int64, outcome: SGAutoLinkPolicy.Outcome, attestOffered: Bool) {
        if self.state.autoLinkInFlight == account {
            self.state.autoLinkInFlight = nil
        }
        guard let value = self.state.accounts[account], let facts = self.facts(account) else {
            return
        }
        self.state.accounts[account]?.autoLinkConsentId = nil
        let install = self.inputs.autoLinkInstall.forAppVersion(self.inputs.appVersion)
        let next = SGAutoLinkPolicy.next(after: outcome, attestOffered: attestOffered, record: facts.autoLink, install: install, now: self.now, random: self.random)
        if next.record != facts.autoLink {
            self.emit(.writeAutoLink(tg: value.tg, next.record))
            self.inputs.accounts[account]?.autoLink = next.record
        }
        if next.install != self.inputs.autoLinkInstall {
            self.emit(.writeAutoLinkInstall(next.install))
            self.inputs.autoLinkInstall = next.install
        }
        switch outcome {
        case .consentStale:
            // The grant predates an erasure of this Telegram id: asked again, no link until a new one.
            self.emit(.log(.consentStale))
            self.normaliseLinkEnded(account, tg: value.tg, consentId: value.autoLinkConsentId)
        case .notPermitted, .notConfigured:
            self.state.accounts[account]?.autoLinkStopped = true
        default:
            break
        }
    }

    mutating func setUnlinkSuppression(_ account: Int64, suppressed: Bool) {
        guard let value = self.state.accounts[account], let facts = self.facts(account) else {
            return
        }
        if !suppressed {
            self.state.accounts[account]?.autoLinkStopped = false
        }
        let record = suppressed ? facts.autoLink.suppressingForUnlink() : facts.autoLink.liftingSuppression()
        guard record != facts.autoLink else {
            return
        }
        self.emit(.writeAutoLink(tg: value.tg, record))
        self.inputs.accounts[account]?.autoLink = record
    }

    // MARK: Consent-store normalisations (their effect on this reduction's facts too)

    mutating func normaliseLinkEnded(_ account: Int64, tg: Int64, consentId: String?) {
        self.emit(.normaliseLinkEnded(tg: tg, consentId: consentId))
        if SGConsentReconciler.onBindConsentStale(record: self.inputs.accounts[account]?.record, consentId: consentId) == .markNeedsReconsent(.linkEnded) {
            self.inputs.accounts[account]?.record?.state = .needsReconsent
        }
    }

    mutating func normalise(_ account: Int64, tg: Int64, notice: SGConsentStoredNotice) {
        self.emit(.normalise(tg: tg, notice: notice))
        if let state = self.inputs.accounts[account]?.record?.state, state == .granted || state == .needsReconsent {
            self.inputs.accounts[account]?.record?.state = .needsReconsent
        }
    }

    // MARK: Helpers

    mutating func emit(_ effect: Core.Effect) {
        self.effects.append(effect)
    }

    /// The account's facts; nil while the store is unreadable or the driver read none.
    func facts(_ account: Int64) -> Facts? {
        guard self.inputs.readable else {
            return nil
        }
        return self.inputs.accounts[account]
    }

    func clearanceInputs(_ facts: Facts) -> SGCustomerClearance.Inputs {
        return SGCustomerClearance.Inputs(
            readable: self.inputs.readable,
            state: facts.record?.state ?? .none,
            latestGrantRejected: facts.latestGrantRejected,
            erasing: facts.deletion != nil,
            linkEnded: SGCustomerLinkState.linkEnded(record: facts.record, sessionEnd: facts.sessionEnd, handled: facts.linkEndedHandled),
            bindingDeviceId: facts.isLinked ? facts.bindingDeviceId : nil,
            latestGrantAcked: facts.latestGrantAcked,
            notLinkedDeviceId: facts.notLinkedDeviceId,
            hasProfileReceipt: facts.hasProfileReceipt,
            textVersion: facts.record?.textVersion,
            textSha256: facts.record?.textSha256,
            bundledMinValidVersion: facts.bundledMinValidVersion,
            renderedSha256ForRecord: facts.renderedSha256ForRecord
        )
    }

    /// The record's state as the automatic link reads it: a grant this build treats as stale (§4.6
    /// rows 5–6, `SGCustomerClearance.Inputs.staleGrantNotice`) is `needs_reconsent`, as the wall
    /// would persist it — never linked with (the bind would carry it).
    func linkState(_ facts: Facts) -> SGConsentState {
        let inputs = self.clearanceInputs(facts)
        if inputs.state == .granted, inputs.staleGrantNotice != nil {
            return .needsReconsent
        }
        return inputs.state
    }

    mutating func publish(_ account: Int64, _ clearance: SGCustomerDataGate.Clearance) {
        guard let value = self.state.accounts[account], value.published != clearance else {
            return
        }
        self.emit(.publishClearance(account: account, clearance))
        self.state.accounts[account]?.published = clearance
    }

    mutating func send(_ account: Int64, _ request: Core.Request) {
        self.emit(.call(account: account, request, budgeted: true))
        self.state.accounts[account]?.inFlight.insert(request.route)
    }

    mutating func sendConsents(_ account: Int64, entry: Data, body: Data, reason: Core.State.ConsentsReason, budgeted: Bool) {
        self.emit(.call(account: account, .consents(body), budgeted: budgeted))
        self.state.accounts[account]?.inFlight.insert(.consents)
        self.state.accounts[account]?.sentConsents = Core.State.SentConsents(entry: entry, reason: reason)
    }

    /// One timer per (account, kind); an unchanged time is not scheduled again.
    mutating func schedule(_ account: Int64, _ timer: Core.Timer, at date: Date) {
        guard let value = self.state.accounts[account], value.timers[timer] != date else {
            return
        }
        self.state.accounts[account]?.timers[timer] = date
        self.emit(.scheduleTimer(account: account, timer, at: date))
    }

    /// The withdrawal the user's send carries: the record's own when pending, else the newest
    /// pending one.
    static func pendingWithdrawal(_ facts: Facts) -> Data? {
        let withdrawals = facts.pendingUploads.compactMap { entry in SGConsentEvent.decode(entry).map { (entry, $0) } }.filter { $0.1.action == .withdraw }
        if let own = facts.record?.consentId, let entry = withdrawals.first(where: { $0.1.consentId == own }) {
            return entry.0
        }
        return withdrawals.last?.0
    }

    /// What a `consent_required` re-upload sends: the oldest pending entry, else the record's grant
    /// (the latest decision) again.
    static func reuploadEntry(_ facts: Facts) -> Data? {
        if let first = facts.pendingUploads.first {
            return first
        }
        guard let latest = facts.latestDecision, let event = SGConsentEvent.decode(latest), event.action == .grant, event.consentId == facts.record?.consentId else {
            return nil
        }
        return latest
    }
}
