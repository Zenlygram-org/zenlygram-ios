import Foundation
import SGEntitlement

// MARK: - Sync cycle: pull (complete snapshot or catch-up), then drain the outbox
//
// Snapshot: all pages are STAGED, then changes after the snapshot watermark are applied to the
// staging set, and only then is the shadow replaced atomically. An incomplete or failed pagination
// leaves shadow, overlay and outbox untouched. Catch-up pages apply to the shadow atomically with
// their cursor. Every await is followed by a fence check: a purged account drops the result.

extension SGTasksCloudRepository {
    enum PullResult {
        case complete
        case partial
        case resync
        case failed
    }

    enum SendOutcome {
        case acknowledged
        case continueDraining
        case stopDraining
    }

    private var isLive: Bool {
        return !self.isInvalidated && self.store != nil
    }

    /// The cycle's captured principal/generation still match the account's current server binding.
    var isFenceCurrent: Bool {
        guard !self.isInvalidated, self.store != nil, let captured = self.cyclePrincipal else { return false }
        return self.cycleGeneration == self.principalGeneration && self.environment.transport.principal(accountPeerId: self.accountPeerId) == captured
    }

    /// Binds the store to the current canonical server account (first use) or retires everything
    /// scoped to a previous one: shadow, staging, cursors and receipt revisions are dropped, and
    /// every unresolved operation becomes `principalChanged` — never re-sent or re-sealed under
    /// the new account (its business identity is scoped to the old one), kept only for explicit
    /// copy/discard. Token rotation under the same principal changes nothing. On queue.
    @discardableResult
    func fencePrincipal() -> String? {
        guard let store = self.store, !self.isInvalidated else { return nil }
        guard let current = self.environment.transport.principal(accountPeerId: self.accountPeerId) else {
            self.setPause("not_signed_in")
            return nil
        }
        do {
            let stored = try store.meta("principal")
            if stored == nil {
                try store.setMeta("principal", current)
            } else if stored != current {
                try store.transaction {
                    try store.clear(.shadow)
                    try store.clear(.staging)
                    try store.clearChainRevisions()
                    // `migration_checked` too: the migration step checks the rebound store again, so
                    // a return to the earlier server account re-checks its copy against its snapshot.
                    for key in ["changes_cursor", "snapshot_complete", "server_time", "server_time_received_at", "last_synced_at", Self.migrationCheckedMeta] {
                        try store.setMeta(key, nil)
                    }
                    try store.setMeta("needs_resnapshot", "1")
                    for entry in try store.entries() {
                        if entry.isResolved {
                            // The old scope's acknowledged creates keep their provenance (queued).
                            try self.retireAcknowledged(entry, store: store)
                        } else {
                            try store.setState(seq: entry.seq, .principalChanged)
                        }
                    }
                    // wf15 §12.2 / §5.3: deferred assignments, re-send markers and automatic-accept
                    // records name the old scope's tasks and invitations.
                    try store.deleteMeta(prefix: SGTasksCloudStore.deferredAssignmentPrefix)
                    try store.deleteMeta(prefix: SGTasksCloudStore.automaticResendPrefix)
                    try store.deleteMeta(prefix: SGTasksCloudStore.automaticAcceptPrefix)
                    try store.setMeta("principal", current)
                }
                self.principalGeneration &+= 1
                self.needsPrivacyCheckpoint = true
                self.rebuildState()
            }
        } catch {
            if !store.isOpen {
                self.failStorage()
                // Publish storageUnavailable now (no store: no SQL); the previous account's cached
                // board must not outlive the store, withheld or not.
                self.rebuildState()
            }
            return nil
        }
        return current
    }

    /// Same retirement, outside a cycle (local edits, start/refresh, every session change, even
    /// while paused): runs only when a principal is bound now; an absent session pauses nothing
    /// here and keeps local edits possible. On queue.
    func fenceIfPrincipalChanged() {
        guard self.store != nil, !self.isInvalidated, self.environment.transport.principal(accountPeerId: self.accountPeerId) != nil else { return }
        self.fencePrincipal()
    }

    /// Runs exactly one cycle now (explicit refresh path and host tests).
    func syncNow() async {
        await self.performCycle()
    }

    /// On queue. Another Tasks request of this cycle may go out: the cycle's binding still holds,
    /// no durable pause, and the consent gate still allows traffic (it is re-read before every
    /// request, so a withdrawal mid-cycle stops it at the next one).
    var mayRequest: Bool {
        return self.isFenceCurrent && self.pauseReason == nil && self.permitsTraffic
    }

    func performCycle() async {
        let ready: Bool = self.onQueue {
            let explicit = self.pendingExplicitCycle
            self.pendingExplicitCycle = false
            self.lastCycleAcknowledged = 0
            self.cycleErrorCode = nil
            guard self.isLive else { return false }
            // No backend in this build: nothing is asked and nothing durable is recorded (not even
            // the missing session, which would offer a link that cannot work); the board says
            // notConfigured. A configured build first leaves a stale configuration pause.
            guard self.environment.transport.isConfigured else {
                self.rebuildState()
                return false
            }
            // Fail closed (design 30 §5.1): without `allowed` / `legacy` no Tasks request of any
            // kind is made; the board shows the consent hold (`phaseRefinement`).
            guard self.permitsTraffic else {
                self.rebuildState()
                return false
            }
            self.leaveStaleConfigurationPause()
            guard self.pauseReason == nil else { return false }
            // Durable account gate: a server Retry-After is never bypassed (not by an explicit
            // refresh, not by a local change); a local offline backoff yields to an explicit refresh.
            if let gate = self.accountGate(), gate.until > self.environment.now() {
                if explicit && !gate.isServerRetryAfter {
                    self.clearAccountGate()
                } else {
                    self.phase = gate.phase
                    self.rebuildState()
                    return false
                }
            }
            if self.consentFence() != nil, let store = self.store {
                // A consent fence whose time is over: requests may be tried again, realtime too. Its
                // doubling stays until an answer succeeds.
                do {
                    try store.transaction {
                        try store.setMeta("consent_fenced_until", nil)
                        try store.setMeta("consent_fenced_effective_at", nil)
                    }
                } catch {
                    if !store.isOpen { self.failStorage() }
                }
                self.updateRealtime()
            }
            guard let principal = self.fencePrincipal() else {
                // A missing session was just recorded as a durable pause: publish it now, not only
                // on the next reopen.
                self.rebuildState()
                return false
            }
            self.cyclePrincipal = principal
            self.cycleGeneration = self.principalGeneration
            self.cycleIsR4 = self.isR4Engine
            // wf15 §12.2: every cycle start re-enqueues the deferred assignments whose time has come.
            self.reenqueueDueDeferrals()
            self.phase = .syncing
            self.rebuildState()
            return true
        }
        guard ready else { return }
        var pulled = await self.pull()
        if pulled {
            self.onQueue {
                self.resolvePendingConflictsAfterPull()
                // wf15 §5.3: a contact's invitation that arrived with this pull is accepted — queued
                // — before the drain below, with the inputs the coordinator handed in last.
                self.performAutoAccept(requestCycle: false)
            }
        }
        if self.onQueue({ self.mayRequest }) {
            // R4 (`allowed`): the batch route, user entries falling back to single mutations. R3
            // (`legacy`): single mutations exactly as before.
            let acknowledged = self.onQueue({ self.cycleIsR4 }) ? await self.drainBatches() : await self.drain()
            self.onQueue { self.lastCycleAcknowledged = acknowledged }
            if acknowledged > 0, self.onQueue({ self.mayRequest }) {
                pulled = await self.pull()
                if pulled {
                    self.onQueue {
                        self.resolvePendingConflictsAfterPull()
                        self.performAutoAccept(requestCycle: true)
                    }
                }
            }
        }
        self.onQueue {
            let fenced = !self.isFenceCurrent
            self.cyclePrincipal = nil
            if let code = self.cycleErrorCode {
                self.cycleErrorCode = nil
                self.emitAnalytics(.error(domain: SGTasksAnalytics.syncErrorDomain, code: code))
            }
            guard self.isLive else { return }
            if fenced {
                // The binding changed under this cycle: retire the old scope now.
                self.fencePrincipal()
            }
            if self.phase == .syncing {
                self.phase = .idle
            }
            if pulled {
                self.pullFailures = 0
            }
            self.flushPendingImportAcks()
            self.rebuildState()
        }
    }

    // MARK: Account gate

    struct AccountGate {
        let until: Date
        let reason: String
        var isServerRetryAfter: Bool {
            return self.reason != "offline"
        }
        var phase: SGTasksCloudState.Phase {
            switch self.reason {
            case "rate_limited": return .rateLimited(retryAt: self.until)
            case "offline": return .offline(retryAt: self.until)
            default: return .unavailable(retryAt: self.until)
            }
        }
    }

    /// On queue. The account-wide "no request before" gate (content-free meta, survives restart):
    /// the server/offline gate and the R4 consent fence, whichever opens later. An unreadable gate
    /// store is treated as closed for one poll rather than as open.
    func accountGate() -> AccountGate? {
        let server = self.serverGate()
        guard let fence = self.consentFence() else { return server }
        let consent = AccountGate(until: fence.until, reason: Self.consentFencedGate)
        guard let server = server else { return consent }
        return consent.until > server.until ? consent : server
    }

    static let consentFencedGate = "consent_fenced"

    /// The server Retry-After / offline backoff gate alone (what `extendAccountGate` extends).
    private func serverGate() -> AccountGate? {
        guard let store = self.store else { return nil }
        do {
            guard let raw = try store.meta("not_before"), let seconds = Double(raw) else { return nil }
            return AccountGate(until: Date(timeIntervalSince1970: seconds), reason: try store.meta("not_before_reason") ?? "unavailable")
        } catch {
            return AccountGate(until: self.environment.now().addingTimeInterval(self.environment.pollInterval), reason: "unavailable")
        }
    }

    // MARK: Consent fence (design 30 §3.12)

    static let consentFenceInitialDelay: TimeInterval = 30
    static let consentFenceMaximumDelay: TimeInterval = 900

    /// On queue. The fence the last 403 `tasks_consent_required` recorded (nil: none / unreadable).
    func consentFence() -> (until: Date, effectiveAt: String?)? {
        guard let store = self.store, let seconds = try? store.realMeta("consent_fenced_until") else { return nil }
        return (until: Date(timeIntervalSince1970: seconds), effectiveAt: (try? store.meta("consent_fenced_effective_at")) ?? nil)
    }

    /// On queue, inside the answer's transaction. Never a failure of an entry: the caller requeues
    /// it with no attempt; here the whole account backs off — 30 s, doubling per consecutive fence,
    /// at most 15 min — and nothing is discarded (whether consent was really withdrawn is the
    /// customer layer's decision, which then calls `discardAfterConsentWithdrawal`).
    func recordConsentFence(effectiveAt: String?, store: SGTasksCloudStore) throws {
        let delay = try store.realMeta("consent_fence_delay").map { min($0 * 2, Self.consentFenceMaximumDelay) } ?? Self.consentFenceInitialDelay
        let until = self.environment.now().addingTimeInterval(delay)
        try store.setMeta("consent_fenced_until", String(until.timeIntervalSince1970))
        try store.setMeta("consent_fence_delay", String(delay))
        try store.setMeta("consent_fenced_effective_at", effectiveAt)
        self.phase = .unavailable(retryAt: until)
        self.cycleErrorCode = "tasks_consent_required"
        self.updateRealtime()
        let center = self.environment.notificationCenter
        var userInfo: [String: Any] = ["accountPeerId": self.accountPeerId]
        if let effectiveAt = effectiveAt {
            userInfo["effectiveAt"] = effectiveAt
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isInvalidated else { return }
            center.post(name: Self.consentFencedNotification, object: self, userInfo: userInfo)
        }
    }

    static func clearConsentFence(_ store: SGTasksCloudStore) throws {
        for key in ["consent_fenced_until", "consent_fence_delay", "consent_fenced_effective_at"] {
            try store.setMeta(key, nil)
        }
    }

    /// On queue, for every 2xx Tasks answer (snapshot / changes page, single mutation, batch):
    /// `x-wire-negotiation` — `server_wire` keeps the numeric echo while it is a wire this client
    /// knows (`SGTasksWire.wireRevision` ... `maximumWire`: an echo of 5 keeps every R4 operation
    /// sealed instead of dropping the client to R3, wf15 F5 / §8.3); a batch 200 or an R4 projection
    /// proves at least wire 4 without one; a 2xx that proves nothing is an R3 (or rolled-back) server
    /// and clears it. A successful answer also ends the consent fence's doubling.
    func noteServerAnswer(serverWire: Int?, provesWire4: Bool = false, store: SGTasksCloudStore) throws {
        let knownWires = SGTasksWire.wireRevision ... SGTasksWire.maximumWire
        let echoed = serverWire.flatMap { knownWires.contains($0) ? $0 : nil }
        let proven = provesWire4 ? SGTasksWire.wireRevision : nil
        let wire = [echoed, proven].compactMap { $0 }.max()
        try store.setMeta("server_wire", wire.map { String($0) })
        try store.setMeta("consent_fence_delay", nil)
    }

    /// An R4 `List` projection (`members_revision` present) proves an R4 server.
    static func containsR4Projection(_ items: [SGTasksWire.Projection]) -> Bool {
        return items.contains { projection in
            if case let .list(list) = projection {
                return list.membersRevision != nil
            }
            return false
        }
    }

    static func containsR4Projection(_ changes: [SGTasksWire.Change]) -> Bool {
        return changes.contains { change in
            if case let .upsert(_, item) = change {
                return Self.containsR4Projection([item])
            }
            return false
        }
    }

    /// On queue. Extends (never shortens) the gate. `reason` is rate_limited / unavailable (server
    /// Retry-After, never bypassed) or offline (local backoff); a server reason is never downgraded.
    func extendAccountGate(by delay: TimeInterval, reason: String, store: SGTasksCloudStore) throws {
        var until = self.environment.now().addingTimeInterval(max(delay, 0))
        var effectiveReason = reason
        if let current = self.serverGate(), current.until > self.environment.now() {
            until = max(until, current.until)
            if current.isServerRetryAfter && reason == "offline" {
                effectiveReason = current.reason
            }
        }
        try store.setMeta("not_before", String(until.timeIntervalSince1970))
        try store.setMeta("not_before_reason", effectiveReason)
    }

    /// On queue. Ends a local offline backoff early (explicit user refresh only).
    private func clearAccountGate() {
        guard let store = self.store else { return }
        do {
            try store.transaction {
                try store.setMeta("not_before", nil)
                try store.setMeta("not_before_reason", nil)
            }
        } catch {
            if !store.isOpen { self.failStorage() }
        }
    }

    func isGateOpen() -> Bool {
        guard let gate = self.accountGate() else { return true }
        return gate.until <= self.environment.now()
    }

    // MARK: Pull

    /// Returns true when the shadow is caught up to the server for this cycle.
    func pull() async -> Bool {
        typealias Plan = (needsSnapshot: Bool, cursor: SGTasksWire.Cursor?)
        let plan: Plan? = self.onQueue {
            guard let store = self.store, self.isFenceCurrent else { return nil }
            do {
                let complete = try store.meta("snapshot_complete") == "1"
                let needs = try store.meta("needs_resnapshot") == "1"
                let cursor = try store.meta("changes_cursor").flatMap(SGTasksWire.Cursor.init)
                return (needsSnapshot: needs || !complete || cursor == nil, cursor: cursor)
            } catch {
                self.failStorage()
                return nil
            }
        }
        guard let plan = plan else { return false }
        var result: PullResult
        if plan.needsSnapshot {
            result = await self.snapshot()
        } else {
            result = await self.catchUp(from: plan.cursor!)
            if case .resync = result {
                result = await self.snapshot()
            }
        }
        guard case .complete = result else { return false }
        return self.onQueue {
            guard let store = self.store, self.isFenceCurrent else { return false }
            do {
                try store.transaction {
                    // Only acknowledgements the shadow PROVES retire; has_more=false is no proof (a
                    // coalesced row can move beyond the watermark and arrive next cycle).
                    try self.retireCoveredAcknowledgements(store: store)
                    try store.setMeta("last_synced_at", String(self.environment.now().timeIntervalSince1970))
                }
            } catch {
                if !store.isOpen { self.failStorage() }
                return false
            }
            self.pullFailures = 0
            self.rebuildState()
            return true
        }
    }

    private static func identity(of projection: SGTasksWire.Projection) -> (kind: String, id: String) {
        switch projection {
        case let .list(list): return ("list", list.id.rawValue)
        case let .task(task): return ("task", task.id.rawValue)
        case let .invitation(invitation): return ("invitation", invitation.id.rawValue)
        case let .block(block): return ("block", block.id.rawValue)
        }
    }

    private static func identity(of target: SGTasksWire.RemovalTarget) -> (kind: String, id: String) {
        switch target {
        case let .list(id): return ("list", id.rawValue)
        case let .task(id): return ("task", id.rawValue)
        case let .invitation(id): return ("invitation", id.rawValue)
        case let .block(id): return ("block", id.rawValue)
        }
    }

    private func setServerTime(_ instant: SGTasksWire.Instant, store: SGTasksCloudStore) throws {
        try store.setMeta("server_time", String(instant.date.timeIntervalSince1970))
        try store.setMeta("server_time_received_at", String(self.environment.now().timeIntervalSince1970))
    }

    private func snapshot() async -> PullResult {
        var restarts = 0
        while true {
            let outcome = await self.snapshotAttempt()
            if case .resync = outcome, restarts == 0 {
                restarts += 1
                continue
            }
            if case .resync = outcome {
                self.onQueue { self.handlePullFailure(SGTasksError(kind: .unavailable)) }
                return .failed
            }
            return outcome
        }
    }

    private func snapshotAttempt() async -> PullResult {
        let startMarker: Int64? = self.onQueue {
            guard let store = self.store, self.isFenceCurrent else { return nil }
            do {
                return try store.transaction {
                    try store.clear(.staging)
                    return try store.currentAckMarker()
                }
            } catch {
                return nil
            }
        }
        guard let startMarker = startMarker else { return .failed }

        var cursor: SGTasksWire.Cursor?
        var changesCursor: SGTasksWire.Cursor?
        var pages = 0
        repeat {
            guard pages < Self.maximumSnapshotPages else {
                self.onQueue { self.handlePullFailure(SGTasksError(kind: .unavailable)) }
                return .failed
            }
            pages += 1
            guard self.onQueue({ self.permitsTraffic }) else { return .failed }
            let check = self.trafficCheck()
            let result = await self.environment.transport.snapshot(accountPeerId: self.accountPeerId, cursor: cursor, stillWanted: check.ask)
            let staged: PullResult? = self.onQueue {
                guard let store = self.store, self.isFenceCurrent else { return .failed }
                // Refused by its own re-check in SGEntitlement's account gate: nothing was sent.
                guard !check.refused else { return .failed }
                switch result {
                case let .failure(error):
                    if case .resyncRequired = error.kind { return .resync }
                    self.handlePullFailure(error)
                    return .failed
                case let .success(page):
                    do {
                        try store.transaction {
                            for item in page.items {
                                let identity = Self.identity(of: item)
                                try store.upsert(.staging, kind: identity.kind, id: identity.id, body: item.wireJSON)
                            }
                            try self.setServerTime(page.serverTime, store: store)
                            try self.noteServerAnswer(serverWire: page.serverWire, provesWire4: Self.containsR4Projection(page.items), store: store)
                        }
                    } catch {
                        return .failed
                    }
                    if changesCursor == nil {
                        changesCursor = page.changesCursor
                    }
                    cursor = page.nextCursor
                    return nil
                }
            }
            if let staged = staged {
                return staged
            }
        } while cursor != nil

        guard var deltaCursor = changesCursor else { return .failed }
        var deltaPages = 0
        while true {
            guard deltaPages < Self.maximumChangePagesPerCycle else {
                // Staging is not reconciled until the post-watermark delta is complete.
                self.onQueue { self.handlePullFailure(SGTasksError(kind: .unavailable)) }
                return .failed
            }
            deltaPages += 1
            guard self.onQueue({ self.permitsTraffic }) else { return .failed }
            let check = self.trafficCheck()
            let result = await self.environment.transport.changes(accountPeerId: self.accountPeerId, cursor: deltaCursor, stillWanted: check.ask)
            let step: PullResult? = self.onQueue {
                guard let store = self.store, self.isFenceCurrent else { return .failed }
                guard !check.refused else { return .failed }
                switch result {
                case let .failure(error):
                    if case .resyncRequired = error.kind { return .resync }
                    self.handlePullFailure(error)
                    return .failed
                case let .success(page):
                    do {
                        try store.transaction {
                            for change in page.changes {
                                try self.apply(change, to: .staging, store: store)
                            }
                            try self.noteServerAnswer(serverWire: page.serverWire, provesWire4: Self.containsR4Projection(page.changes), store: store)
                        }
                    } catch {
                        return .failed
                    }
                    deltaCursor = page.nextCursor
                    return page.hasMore ? nil : .complete
                }
            }
            if let step = step {
                if case .complete = step { break }
                return step
            }
        }

        return self.onQueue {
            guard let store = self.store, self.isFenceCurrent else { return .failed }
            do {
                try store.transaction {
                    let staged = Set(try store.rows(.staging).map { "\($0.kind):\($0.id)" })
                    var lostShared = false
                    for row in try store.rows(.shadow) where !staged.contains("\(row.kind):\(row.id)") {
                        lostShared = try self.forgetSharedResource(kind: row.kind, id: row.id, store: store) || lostShared
                    }
                    try store.replaceShadowWithStaging()
                    try self.retireAcknowledgementsAbsent(fromSnapshotStartedAt: startMarker, store: store)
                    try store.setMeta("changes_cursor", deltaCursor.rawValue)
                    try store.setMeta("snapshot_complete", "1")
                    try store.setMeta("needs_resnapshot", nil)
                    if lostShared {
                        try store.addNotice(.sharedAccessLost, at: self.environment.now())
                    }
                }
            } catch {
                if !store.isOpen { self.failStorage() }
                return .failed
            }
            self.rebuildState()
            return .complete
        }
    }

    private func catchUp(from start: SGTasksWire.Cursor) async -> PullResult {
        var cursor = start
        var pages = 0
        while true {
            guard self.onQueue({ self.permitsTraffic }) else { return .failed }
            let check = self.trafficCheck()
            let result = await self.environment.transport.changes(accountPeerId: self.accountPeerId, cursor: cursor, stillWanted: check.ask)
            let step: PullResult? = self.onQueue {
                guard let store = self.store, self.isFenceCurrent else { return .failed }
                guard !check.refused else { return .failed }
                switch result {
                case let .failure(error):
                    if case .resyncRequired = error.kind {
                        // Keep the shadow until a complete resnapshot replaces it.
                        try? store.transaction { try store.markResyncRequired() }
                        return .resync
                    }
                    self.handlePullFailure(error)
                    return .failed
                case let .success(page):
                    do {
                        try store.transaction {
                            var lostShared = false
                            for change in page.changes {
                                lostShared = try self.apply(change, to: .shadow, store: store) || lostShared
                            }
                            try store.setMeta("changes_cursor", page.nextCursor.rawValue)
                            try self.setServerTime(page.serverTime, store: store)
                            try self.noteServerAnswer(serverWire: page.serverWire, provesWire4: Self.containsR4Projection(page.changes), store: store)
                            if lostShared {
                                try store.addNotice(.sharedAccessLost, at: self.environment.now())
                            }
                        }
                    } catch {
                        if !store.isOpen { self.failStorage() }
                        return .failed
                    }
                    cursor = page.nextCursor
                    self.rebuildState()
                    return page.hasMore ? nil : .complete
                }
            }
            if let step = step {
                return step
            }
            pages += 1
            if pages >= Self.maximumChangePagesPerCycle {
                self.onQueue { self.isCycleRequested = true }
                return .partial
            }
        }
    }

    /// Applies one feed change; returns true when shared access was lost for a cached item.
    @discardableResult
    private func apply(_ change: SGTasksWire.Change, to table: SGTasksCloudStore.Table, store: SGTasksCloudStore) throws -> Bool {
        switch change {
        case let .upsert(_, item):
            let identity = Self.identity(of: item)
            try store.upsert(table, kind: identity.kind, id: identity.id, body: item.wireJSON)
            return false
        case let .remove(_, target):
            let identity = Self.identity(of: target)
            var lost = false
            if table == .shadow {
                lost = try self.forgetSharedResource(kind: identity.kind, id: identity.id, store: store)
                try self.retireAcknowledgements(touching: "\(identity.kind):\(identity.id)", store: store)
            }
            try store.remove(table, kind: identity.kind, id: identity.id)
            return lost
        }
    }

    /// Retires every acknowledged entry the current shadow proves; keeps receipt revisions for
    /// every remaining entry (unresolved AND acknowledged-but-unproven). Inside a transaction.
    func retireCoveredAcknowledgements(store: SGTasksCloudStore) throws {
        let index = SGTasksCloudOverlay.ShadowIndex(try store.rows(.shadow).compactMap { try? SGTasksWire.Projection(wireJSON: $0.body) })
        let entries = try store.entries()
        var retired = Set<Int64>()
        for entry in entries where entry.state == .acked {
            guard let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body) else {
                retired.insert(entry.seq)
                continue
            }
            guard SGTasksCloudOverlay.isCovered(entry, mutation: mutation, index: index) else { continue }
            retired.insert(entry.seq)
            // A proven delete also proves every earlier acknowledgement of the same resource (a
            // create/update whose row never reached the shadow must not bring it back).
            if case let .mutation(request) = mutation, request.operation.kind == .taskDelete || request.operation.kind == .listDelete {
                let key = SGTasksCloudKey.primary(of: request.operation)
                var latestContent: [String: (listId: SGTasksWire.UUID?, seqs: [Int64])] = [:]
                for earlier in entries where earlier.seq < entry.seq && earlier.state == .acked {
                    guard let earlierMutation = try? SGTasksWire.SealedMutation(wireJSON: earlier.body) else { continue }
                    let earlierKey = SGTasksCloudKey.primary(of: earlierMutation)
                    if earlierKey == key {
                        retired.insert(earlier.seq)
                    }
                    // Per task, the LAST acknowledged content decides its list before this delete.
                    var record = latestContent[earlierKey] ?? (listId: nil, seqs: [])
                    switch earlierMutation {
                    case let .mutation(earlierRequest):
                        switch earlierRequest.operation {
                        case let .taskCreate(op): record.listId = op.content.listId
                        case let .taskUpdate(op): record.listId = op.content.listId
                        default: break
                        }
                    case let .patch(earlierRequest):
                        // A patch moves the task only when it sets `list_id`.
                        if case let .listId(listId)? = earlierRequest.patch.set[.listId] {
                            record.listId = listId
                        }
                    }
                    record.seqs.append(earlier.seq)
                    latestContent[earlierKey] = record
                }
                // The server deleted a list's members with it: a task whose last acknowledged content
                // put it in that list is gone too (a task moved OUT of it is not, though it also
                // carries the list's key).
                if case let .listDelete(op) = request.operation {
                    for (taskKey, record) in latestContent where taskKey.hasPrefix("task:") && record.listId == op.listId {
                        retired.formUnion(record.seqs)
                    }
                }
            }
        }
        for entry in entries where retired.contains(entry.seq) {
            if entry.state == .acked {
                try self.retireAcknowledged(entry, store: store)
            } else {
                try store.deleteEntry(seq: entry.seq)
            }
        }
        try store.pruneChainRevisions(keeping: Set(try store.entries().flatMap { $0.keys }))
    }

    /// An authoritative removal of `key` (a `remove` change applied to the shadow) proves every
    /// acknowledgement touching that resource. A block acknowledgement is not proven by the
    /// removal of the invitation it was issued from (the block itself suppresses invitations).
    func retireAcknowledgements(touching key: String, store: SGTasksCloudStore) throws {
        for entry in try store.entries() where entry.state == .acked && entry.keys.contains(key) {
            guard let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body) else { continue }
            if Self.proofKey(entry, mutation: mutation) == key {
                try self.retireAcknowledged(entry, store: store)
            }
        }
    }

    static func proofKey(_ entry: SGTasksCloudStoredEntry, mutation: SGTasksWire.SealedMutation) -> String {
        switch mutation {
        case let .mutation(request):
            return Self.proofKey(entry, operation: request.operation)
        case .patch:
            return SGTasksCloudKey.primary(of: mutation)
        }
    }

    /// The one resource whose authoritative removal proves an acknowledgement. Secondary keys
    /// (e.g. the lists of a moved task) never do: removing list A proves nothing about task T.
    static func proofKey(_ entry: SGTasksCloudStoredEntry, operation: SGTasksWire.Operation) -> String {
        switch operation {
        case let .inviteRespond(op) where op.decision == .decline:
            return SGTasksCloudKey.invitation(op.invitationId)
        case .senderBlock:
            return entry.subject.map { SGTasksCloudKey.block(raw: $0) } ?? SGTasksCloudKey.primary(of: operation)
        default:
            return SGTasksCloudKey.primary(of: operation)
        }
    }

    /// After a complete snapshot that began after an acknowledgement, the absence of its resource
    /// is authoritative too. Inside a transaction, after the shadow was replaced.
    private func retireAcknowledgementsAbsent(fromSnapshotStartedAt marker: Int64, store: SGTasksCloudStore) throws {
        let present = Set(try store.rows(.shadow).map { "\($0.kind):\($0.id)" })
        for entry in try store.entries() where entry.state == .acked {
            guard let ackMarker = entry.ackMarker, ackMarker <= marker, let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body) else { continue }
            if !present.contains(Self.proofKey(entry, mutation: mutation)) {
                try self.retireAcknowledged(entry, store: store)
            }
        }
    }

    /// Confirmed loss of a shared item: its cached copy and every command for it go; nothing of
    /// another owner's content is retained. Returns true when the user should get the content-free
    /// access-loss notice (not for a removal the user caused by leaving/declining).
    func forgetSharedResource(kind: String, id: String, store: SGTasksCloudStore) throws -> Bool {
        switch kind {
        case "task":
            guard let body = try store.row(.shadow, kind: "task", id: id), case let .task(task)? = try? SGTasksWire.Projection(wireJSON: body), task.viewerRole == .assignee else { return false }
            let related = try store.entries().filter { $0.keys.contains("task:\(id)") }
            let selfInitiated = related.contains { $0.kind == .operation(.inviteRespond) && $0.state != .principalChanged }
            try store.remove(.shadow, kind: "task", id: id)
            for entry in related {
                try store.deleteEntry(seq: entry.seq)
            }
            self.needsPrivacyCheckpoint = true
            return !selfInitiated
        case "invitation":
            var dropped = false
            // A block stays valid for a historical addressed invitation: never drop it here.
            for entry in try store.entries() where entry.keys.contains("invitation:\(id)") && entry.isShared && !entry.isResolved && entry.kind != .operation(.senderBlock) {
                if try self.isAutomaticAccept(entry, store: store) {
                    // wf15 §5.3: the automatic accept goes quietly — the user did nothing, so there
                    // is no access-loss notice (the accept's answer was lost and the pull shows the
                    // task accepted, or the owner removed / reassigned before it was sent).
                    try self.dropAutomaticAccept(entry, store: store)
                    continue
                }
                try store.deleteEntry(seq: entry.seq)
                dropped = true
            }
            self.needsPrivacyCheckpoint = true
            return dropped
        default:
            return false
        }
    }

    /// After shared content left the database: fold the WAL back so removed rows do not linger in
    /// the -wal file until an automatic checkpoint (logical overwrite, not a physical erase).
    func checkpointIfNeeded() {
        guard self.needsPrivacyCheckpoint, let store = self.store else { return }
        do {
            try store.checkpoint()
            self.needsPrivacyCheckpoint = false
        } catch {
            // A busy reader keeps the WAL; the flag stays set and the next write cycle retries.
            print("[SGTasksCloud] WAL checkpoint deferred")
        }
    }

    private func gate(_ delay: TimeInterval, reason: String) {
        guard let store = self.store else { return }
        do {
            try self.extendAccountGate(by: delay, reason: reason, store: store)
        } catch {
            if !store.isOpen { self.failStorage() }
        }
    }

    /// Pull failure classification (on queue). Pauses are durable; transient failures back off.
    func handlePullFailure(_ error: SGTasksError) {
        let now = self.environment.now()
        self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
        // R4 first: a consent fence keeps its R3 class (`.rejected(403)`) in `kind`.
        if case let .consentRequired(effectiveAt)? = error.refinement {
            if let store = self.store {
                do {
                    try store.transaction { try self.recordConsentFence(effectiveAt: effectiveAt, store: store) }
                } catch {
                    if !store.isOpen { self.failStorage() }
                }
            }
            return
        }
        switch error.kind {
        case .accountNotLinked:
            self.setPause(Self.notLinkedPause)
        case .notSignedIn:
            self.setPause("not_signed_in")
        case .notConfigured:
            self.setPause(Self.notConfiguredPause)
        case .session:
            self.setPause("session_invalid")
        case .rateLimited:
            self.pullFailures += 1
            let delay = error.retryAfter.map(TimeInterval.init) ?? Self.defaultRateLimitDelay
            self.gate(delay, reason: "rate_limited")
            self.phase = .rateLimited(retryAt: now.addingTimeInterval(delay))
        case .transport, .credentialChanged:
            // The drain of this cycle is gated too, so offline never spends mutation attempts.
            self.pullFailures += 1
            let delay = Self.backoff(attempt: self.pullFailures)
            self.gate(delay, reason: "offline")
            self.phase = .offline(retryAt: now.addingTimeInterval(delay))
        case .resyncRequired:
            self.pullFailures += 1
            if let store = self.store {
                try? store.transaction { try store.markResyncRequired() }
            }
            self.gate(Self.backoff(attempt: self.pullFailures), reason: "offline")
        default:
            self.pullFailures += 1
            let delay = error.retryAfter.map(TimeInterval.init) ?? Self.backoff(attempt: self.pullFailures)
            self.gate(delay, reason: error.retryAfter != nil ? "unavailable" : "offline")
            self.phase = .unavailable(retryAt: now.addingTimeInterval(delay))
        }
    }

    // MARK: Drain

    /// Sends eligible USER operations one at a time through the single route (so at most one in
    /// flight per chain); returns the number of acknowledgements. The whole R3 drain, and the R4
    /// fallback while the batch route is unavailable; a `migration` entry never takes this route.
    func drain() async -> Int {
        var acknowledged = 0
        var sends = 0
        while sends < Self.maximumSendsPerCycle {
            let next: (seq: Int64, mutation: SGTasksWire.SealedMutation)? = self.onQueue {
                guard let store = self.store, self.mayRequest else { return nil }
                do {
                    return try store.transaction { try self.prepareNextSend(store: store) }
                } catch {
                    if !store.isOpen { self.failStorage() }
                    return nil
                }
            }
            guard let next = next else { break }
            sends += 1
            switch await self.sendSingle(seq: next.seq, mutation: next.mutation) {
            case .acknowledged:
                acknowledged += 1
            case .continueDraining:
                break
            case .stopDraining:
                return acknowledged
            }
        }
        return acknowledged
    }

    /// One entry already marked `sending`, through `POST /v1/tasks/mutations`.
    func sendSingle(seq: Int64, mutation: SGTasksWire.SealedMutation) async -> SendOutcome {
        self.onQueue { self.rebuildState() }
        let isCreation = mutation.kind.isCreation
        if isCreation {
            // Durable import provenance BEFORE the bytes can reach the server.
            self.recordImportProvenance(mutationId: mutation.mutationId.rawValue, acknowledged: false)
        }
        let check = self.trafficCheck()
        let result = await self.environment.transport.mutation(mutation, accountPeerId: self.accountPeerId, stillWanted: check.ask)
        let outcome: SendOutcome = self.onQueue {
            guard self.isFenceCurrent else {
                // A response for a fenced scope is never applied. A principal change retires the
                // entry as `principalChanged`; otherwise (binding temporarily absent) the SAME sealed
                // identity returns to the queue, exactly as after an interrupted send.
                guard !self.isInvalidated, let store = self.store else { return .stopDraining }
                self.fencePrincipal()
                do {
                    if let entry = try store.entry(seq: seq), entry.state == .sending {
                        try store.setState(seq: seq, .queued)
                    }
                } catch {
                    if !store.isOpen { self.failStorage() }
                }
                self.rebuildState()
                return .stopDraining
            }
            if check.refused {
                // Refused by its own re-check in SGEntitlement's account gate (a withdrawal or a
                // permission change while it waited there): nothing was sent. Back to the queue with
                // the same identity, no attempt, no backoff and no error; a withdrawal's discard has
                // deleted it already, and nothing recreates it.
                if let store = self.store {
                    do {
                        try store.transaction { try store.requeueSending(seq: seq) }
                    } catch {
                        if !store.isOpen { self.failStorage() }
                    }
                }
                self.rebuildState()
                return .stopDraining
            }
            let outcome = self.handleMutationResult(seq: seq, mutation: mutation, result: result)
            if case let .success(response) = result, let store = self.store {
                try? store.transaction { try self.noteServerAnswer(serverWire: response.serverWire, store: store) }
            }
            self.rebuildState()
            return outcome
        }
        if outcome == .acknowledged, isCreation {
            self.recordImportProvenance(mutationId: mutation.mutationId.rawValue, acknowledged: true)
        }
        return outcome
    }

    private enum SealResolution {
        case revision(SGTasksWire.Revision)
        case wait
        case missing
    }

    /// Picks the first queued, due entry whose resource keys no earlier unresolved entry (or held
    /// delete) shares; seals it if its base awaited a predecessor; records `sent_once` before send.
    /// Queued entries whose dependency chain is free: no earlier unresolved entry and no held
    /// delete shares a resource key. The ONLY eligibility rule, used by send and by scheduling.
    static func chainFreeEntries(_ entries: [SGTasksCloudStoredEntry]) -> [SGTasksCloudStoredEntry] {
        let heldKeys = Set(entries.filter { $0.state == .held }.flatMap { $0.keys })
        var busy = Set<String>()
        var out: [SGTasksCloudStoredEntry] = []
        for entry in entries where !entry.isResolved {
            if entry.state == .queued, !entry.keys.contains(where: { busy.contains($0) || heldKeys.contains($0) }) {
                out.append(entry)
            }
            busy.formUnion(entry.keys)
        }
        return out
    }

    /// On queue. When the next send could happen: nil if nothing can be sent without a sync or a
    /// user action (blocked chains, unsealed entries waiting for the following snapshot).
    func nextSendDate() -> Date? {
        guard let store = self.store, let entries = try? store.entries() else { return nil }
        let now = self.environment.now()
        // A migration entry waits for the batch route: never under R3, and not before a
        // migration pause or a batch-route outage ends.
        let migrationDue: Date? = self.isR4Engine ? max(now, self.batchRouteHold(store: store) ?? now) : nil
        var earliest: Date?
        for entry in Self.chainFreeEntries(entries) {
            var floor = now
            if entry.origin == .migration {
                guard let due = migrationDue else { continue }
                floor = due
            }
            if !entry.sealed {
                guard case let .mutation(request)? = try? SGTasksWire.SealedMutation(wireJSON: entry.body),
                      let resolution = try? self.resolveSealBase(entry: entry, operation: request.operation, entries: entries, store: store) else { continue }
                if case .wait = resolution { continue }
            }
            let due = max(entry.nextAttemptAt ?? floor, floor)
            earliest = min(earliest ?? due, due)
        }
        // wf15 §12.2: a deferred assignment is due at its `after` (the cycle start re-enqueues it).
        for deferral in (try? Self.deferredAssignments(store)) ?? [] {
            let due = max(deferral.after, now)
            earliest = min(earliest ?? due, due)
        }
        guard let date = earliest else { return nil }
        if let gate = self.accountGate(), gate.until > date { return gate.until }
        return date
    }

    private func prepareNextSend(store: SGTasksCloudStore) throws -> (seq: Int64, mutation: SGTasksWire.SealedMutation)? {
        guard self.isGateOpen() else { return nil }
        let entries = try store.entries()
        let now = self.environment.now()
        for entry in Self.chainFreeEntries(entries) where entry.origin == .user {
            if let due = entry.nextAttemptAt, due > now { continue }
            guard let mutation = try self.sealedForSend(entry, entries: entries, store: store, now: now) else { continue }
            try store.markSending(seq: entry.seq)
            return (entry.seq, mutation)
        }
        return nil
    }

    /// The entry's sealed mutation, ready to send: undecodable bytes are quarantined, and an unsealed
    /// R3 entry is sealed with its resolved base (or waits, or is not found). nil = not now.
    func sealedForSend(_ entry: SGTasksCloudStoredEntry, entries: [SGTasksCloudStoredEntry], store: SGTasksCloudStore, now: Date) throws -> SGTasksWire.SealedMutation? {
        guard let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body), mutation.kind == entry.kind else {
            try store.setState(seq: entry.seq, .quarantined)
            return nil
        }
        guard !entry.sealed, case let .mutation(request) = mutation else {
            return mutation
        }
        switch try self.resolveSealBase(entry: entry, operation: request.operation, entries: entries, store: store) {
        case .wait:
            return nil
        case .missing:
            try store.setState(seq: entry.seq, .notFound)
            try store.addNotice(.ownResourceMissing, at: now)
            return nil
        case let .revision(revision):
            let sealed = try Self.sealedRequest(mutationId: request.mutationId, operation: Self.operation(request.operation, withBase: revision))
            try store.reseal(seq: entry.seq, body: sealed.wireJSON)
            return .mutation(sealed)
        }
    }

    private func resolveSealBase(entry: SGTasksCloudStoredEntry, operation: SGTasksWire.Operation, entries: [SGTasksCloudStoredEntry], store: SGTasksCloudStore) throws -> SealResolution {
        guard let key = SGTasksCloudKey.base(of: operation) else { return .wait }
        let earlier = entries.filter { $0.seq < entry.seq && $0.keys.contains(key) }
        if earlier.contains(where: { !$0.isResolved }) { return .wait }
        // Exact revision from the predecessor's receipt (no rebase onto foreign changes).
        if let raw = try store.chainRevision(key), let revision = SGTasksWire.Revision(raw) {
            return .revision(revision)
        }
        // A predecessor changed this resource without telling its new revision (e.g. a member
        // task changed its list): wait for the sync that prunes it.
        if !earlier.isEmpty { return .wait }
        let kind = key.hasPrefix("list:") ? "list" : "task"
        let id = String(key.dropFirst(kind.count + 1))
        guard let body = try store.row(.shadow, kind: kind, id: id), let projection = try? SGTasksWire.Projection(wireJSON: body) else { return .missing }
        switch projection {
        case let .list(list): return .revision(list.revision)
        case let .task(task): return .revision(task.revision)
        case .invitation, .block: return .missing
        }
    }

    private func retryLater(_ entry: SGTasksCloudStoredEntry, delay: TimeInterval, store: SGTasksCloudStore) throws {
        let attempts = entry.attempts + 1
        if attempts >= Self.maximumAutomaticAttempts {
            try store.setState(seq: entry.seq, .stalled, attempts: attempts)
        } else {
            try store.setState(seq: entry.seq, .queued, attempts: attempts, nextAttemptAt: self.environment.now().addingTimeInterval(delay))
        }
    }

    private func isSharedContext(_ entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore) throws -> Bool {
        if entry.isShared { return true }
        guard let taskKey = entry.keys.first(where: { $0.hasPrefix("task:") }) else { return false }
        let id = String(taskKey.dropFirst("task:".count))
        guard let body = try store.row(.shadow, kind: "task", id: id), case let .task(task)? = try? SGTasksWire.Projection(wireJSON: body) else { return false }
        return task.viewerRole == .assignee
    }

    /// Classifies one mutation result (on queue) — of the single route or of one batch item. Every
    /// R3 refusal has its own handling; the R4 refinements are read FIRST (each keeps the R3 `kind`
    /// an R3 client would act on).
    func handleMutationResult(seq: Int64, mutation: SGTasksWire.SealedMutation, result: Result<SGTasksWire.MutationResponse, SGTasksError>) -> SendOutcome {
        guard let store = self.store, self.isFenceCurrent else { return .stopDraining }
        var events: [SGTasksAnalyticsEvent] = []
        do {
            let outcome: SendOutcome = try store.transaction {
                guard let entry = try store.entry(seq: seq) else { return .continueDraining }
                let now = self.environment.now()
                switch result {
                case let .success(response):
                    let receipt = response.receipt
                    try store.markAcked(seq: seq, revision: receipt.resourceRevision?.rawValue, marker: try store.nextAckMarker(), serverTime: response.serverTime.date)
                    let primary = SGTasksCloudKey.primary(of: mutation)
                    switch entry.kind {
                    case .operation(.taskDelete), .operation(.listDelete):
                        try store.setChainRevision(primary, nil)
                    default:
                        try store.setChainRevision(primary, receipt.resourceRevision?.rawValue)
                    }
                    // A member-task change moves its list's revision to a value the receipt does not carry.
                    for key in entry.keys where key != primary && key.hasPrefix("list:") {
                        try store.setChainRevision(key, nil)
                    }
                    try self.setServerTime(response.serverTime, store: store)
                    if case let .mutation(request) = mutation {
                        switch request.operation {
                        case let .inviteRequest(op):
                            // wf15 §4.1 / §12.2: the re-send marker goes; a legacy annotation is cleared.
                            try self.settleAssignmentReceipt(taskId: op.taskId, mutationId: entry.mutationId, store: store)
                        case .inviteRespond:
                            // wf15 §5.3: an acknowledged automatic accept keeps its `auto_accept.<id>`
                            // row while the entry awaits the server's proof (the invitation leaves the
                            // snapshot, the task arrives as an assignee row), so the invitation stays
                            // provisional and is never accepted twice in that gap; `performAutoAccept`
                            // sweeps the row once the entry is retired.
                            break
                        default:
                            break
                        }
                    }
                    return .acknowledged
                case let .failure(error):
                    switch error.refinement {
                    case let .consentRequired(effectiveAt)?:
                        // Never a failure of the entry: back to the queue, no attempt; the account
                        // backs off and nothing is discarded (§3.12).
                        try store.setState(seq: seq, .queued)
                        try self.recordConsentFence(effectiveAt: effectiveAt, store: store)
                        return .stopDraining
                    case .migrationPaused?:
                        // The migration kill switch: this and every migration entry wait (no attempt);
                        // user entries keep going.
                        try store.setState(seq: seq, .queued)
                        try self.holdMigration(for: error.retryAfter.map(TimeInterval.init) ?? Self.defaultMigrationPause, store: store)
                        return .continueDraining
                    case let .fieldChanged(fields)?:
                        return try self.markConflict(entry, mutation: mutation, reason: .fieldChanged, fields: fields, serverTime: error.serverTime, store: store, events: &events)
                    case .membersChanged?:
                        return try self.markConflict(entry, mutation: mutation, reason: .membersChanged, fields: [], serverTime: error.serverTime, store: store, events: &events)
                    case .batchDisabled?, nil:
                        // `batch_disabled` is an envelope answer (the batch drain's); here it is the
                        // 503 it is classed as.
                        break
                    }
                    // wf15 §12.2: the automatic re-send of a deferred assignment is the user's own
                    // pick retried. A long rate limit defers it again, a short one gates the account
                    // as for any entry, a transient failure retries it; a definite refusal (the task
                    // was deleted, completed or reassigned meanwhile) ends it quietly — no Unsent
                    // Changes row, no notice; the row shows whatever the projection says.
                    // wf15 §5.3: the automatic accept of a contact's invitation is handled the same
                    // way — `revision_changed` reseals it (the automatic row, up to the cap), every
                    // other definite refusal (`invitation_expired`, `completed_task`,
                    // `invitation_changed`, 404, 422) drops it quietly: no row, no `sharedAccessLost`
                    // notice (the user did nothing), the attempts recorded.
                    let automaticResend = try self.isAutomaticResend(entry, store: store)
                    let automaticAccept = try self.isAutomaticAccept(entry, store: store)
                    let automatic = automaticResend || automaticAccept
                    switch error.kind {
                    case .accountNotLinked:
                        // Account-level pause: nothing is wiped, no attempt is counted, no cursor moves.
                        try store.setState(seq: seq, .queued)
                        self.setPause(Self.notLinkedPause)
                        self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
                        return .stopDraining
                    case .notSignedIn:
                        try store.setState(seq: seq, .queued)
                        self.setPause("not_signed_in")
                        return .stopDraining
                    case .notConfigured:
                        try store.setState(seq: seq, .queued)
                        self.setPause(Self.notConfiguredPause)
                        return .stopDraining
                    case .session:
                        // SGEntitlement already applied it to the exact captured credential.
                        try store.setState(seq: seq, .queued)
                        self.setPause("session_invalid")
                        self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
                        return .stopDraining
                    case .creationNotPermitted:
                        // Blocked draft; no automatic resend. Explicit retry reuses the same id.
                        try store.setState(seq: seq, mutation.kind.isCreation ? .blockedCreation : .stalled, serverTime: error.serverTime)
                        return .continueDraining
                    case .notFound:
                        if automatic {
                            try self.dropAutomaticEntry(entry, resend: automaticResend, store: store)
                            return .continueDraining
                        }
                        if case let .patch(request) = mutation, Self.isAnnotationClear(request.patch) {
                            // wf15 §4.1: the task of an annotation clear is gone — there is nothing
                            // left to clear and nothing to recreate. Dropped quietly, as its
                            // `field_changed` is: no Unsent Changes row, no notice.
                            try store.deleteEntry(seq: seq)
                            return .continueDraining
                        }
                        if try self.isSharedContext(entry, store: store) {
                            try self.forgetSharedAfterNotFound(entry: entry, store: store)
                            try store.addNotice(.sharedAccessLost, at: now)
                        } else {
                            try store.setState(seq: seq, .notFound, serverTime: error.serverTime)
                            try store.addNotice(.ownResourceMissing, at: now)
                        }
                        return .continueDraining
                    case let .conflict(reason):
                        // Explicit user resolution after a re-fetch, except the automatic §7.3 rows.
                        let wireReason = SGTasksWire.ErrorReason(rawValue: reason.rawValue) ?? .revisionChanged
                        if automatic, !self.willResolveAutomatically(entry, mutation: mutation, reason: wireReason) {
                            try self.dropAutomaticEntry(entry, resend: automaticResend, store: store)
                            return .continueDraining
                        }
                        return try self.markConflict(entry, mutation: mutation, reason: wireReason, fields: [], serverTime: error.serverTime, store: store, events: &events)
                    case .resyncRequired:
                        // Same sealed identity after a resnapshot; bounded like any other retry.
                        try self.retryLater(entry, delay: Self.backoff(attempt: entry.attempts + 1), store: store)
                        try store.markResyncRequired()
                        return .stopDraining
                    case .invalidRequest:
                        if automatic {
                            try self.dropAutomaticEntry(entry, resend: automaticResend, store: store)
                            return .continueDraining
                        }
                        // `x-wire-negotiation.downgrade`: an R3 server refuses an R4-only operation as
                        // invalid, a definite non-commit — re-encoded once as R3 under a new id.
                        if mutation.requiresWire4, try self.reencodeAsR3(entry, mutation: mutation, store: store) {
                            try store.setMeta("server_wire", nil)
                            return .continueDraining
                        }
                        try store.setState(seq: seq, .invalid, serverTime: error.serverTime)
                        events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.invalid))
                        return .continueDraining
                    case .mutationMismatch, .invalidLocalRequest:
                        if automatic {
                            try self.dropAutomaticEntry(entry, resend: automaticResend, store: store)
                            return .continueDraining
                        }
                        // Client-integrity bug: quarantined, never re-issued under a new id automatically.
                        try store.setState(seq: seq, .quarantined, serverTime: error.serverTime)
                        return .continueDraining
                    case .rateLimited:
                        let delay = error.retryAfter.map(TimeInterval.init) ?? Self.defaultRateLimitDelay
                        if case let .mutation(request) = mutation, case let .inviteRequest(op) = request.operation, delay > Self.invitationDeferralThreshold {
                            // wf15 §12.2: a long Retry-After on an assignment (the server's day,
                            // per-recipient or pending-expiry window) defers the assignment out of
                            // the outbox — no account gate, the drain goes on with the next entry.
                            try self.deferAssignment(entry, request: op, after: now.addingTimeInterval(delay), store: store)
                            return .continueDraining
                        }
                        // Account-wide: no request of this account (pull, any row, an explicit refresh or
                        // a new local change) goes out before Retry-After. Not the row's fault: no attempt.
                        try store.setState(seq: seq, .queued)
                        try self.extendAccountGate(by: delay, reason: "rate_limited", store: store)
                        self.phase = .rateLimited(retryAt: now.addingTimeInterval(delay))
                        self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
                        return .stopDraining
                    case .mutationInFlight, .unavailable, .malformedResponse:
                        let delay = error.retryAfter.map(TimeInterval.init) ?? Self.backoff(attempt: entry.attempts + 1)
                        try self.retryLater(entry, delay: delay, store: store)
                        if error.retryAfter != nil {
                            try self.extendAccountGate(by: delay, reason: "unavailable", store: store)
                        }
                        self.phase = .unavailable(retryAt: now.addingTimeInterval(delay))
                        self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
                        return .stopDraining
                    case .transport, .credentialChanged:
                        self.pullFailures += 1
                        let delay = Self.backoff(attempt: max(self.pullFailures, entry.attempts + 1))
                        if error.outcomeUnknown {
                            // The bytes may have reached the server: a bounded attempt of the SAME identity.
                            try self.retryLater(entry, delay: delay, store: store)
                        } else {
                            // Certainly not sent: no attempt is spent; the account backs off instead.
                            try store.setState(seq: seq, .queued)
                        }
                        try self.extendAccountGate(by: delay, reason: "offline", store: store)
                        self.phase = .offline(retryAt: now.addingTimeInterval(delay))
                        self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
                        return .stopDraining
                    case let .rejected(status):
                        if status == 413 {
                            if automatic {
                                try self.dropAutomaticEntry(entry, resend: automaticResend, store: store)
                                return .continueDraining
                            }
                            try store.setState(seq: seq, .invalid, serverTime: error.serverTime)
                            events.append(.syncIssue(kind: SGTasksAnalytics.SyncIssue.invalid))
                            return .continueDraining
                        }
                        try self.retryLater(entry, delay: Self.backoff(attempt: entry.attempts + 1), store: store)
                        self.phase = .unavailable(retryAt: now.addingTimeInterval(Self.backoff(attempt: entry.attempts + 1)))
                        self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
                        return .stopDraining
                    }
                }
            }
            for event in events {
                self.emitAnalytics(event)
            }
            return outcome
        } catch {
            if !store.isOpen { self.failStorage() }
            return .stopDraining
        }
    }

    // MARK: Assignments (wf15 §4.1, §12.2)

    /// A `Retry-After` longer than this on an `invitation.request` defers the assignment out of the
    /// outbox instead of gating the account: the server's day and per-recipient windows run up to
    /// 86 400 s and its pending-expiry one up to 7 days, while its minute window is at most 60 s.
    static let invitationDeferralThreshold: TimeInterval = 120

    /// On queue, at every cycle start (§12.2): deferred assignments whose time has come go back to
    /// the outbox as the same pick retried — while the task is still owned, open, without a live
    /// assignment (a newer pick elsewhere, or the recipient already assigned, ends the deferral
    /// quietly) and without a queued invite of its own (a newer pick here cancelled the deferral
    /// already) — and markers of automatic re-sends whose entry is gone are dropped.
    func reenqueueDueDeferrals() {
        guard let store = self.store, !self.isConsentWithdrawn else { return }
        var resent = 0
        do {
            let deferrals = try Self.deferredAssignments(store)
            let markers = try store.metaEntries(prefix: SGTasksCloudStore.automaticResendPrefix)
            guard !deferrals.isEmpty || !markers.isEmpty else { return }
            let now = self.environment.now()
            let state = self.state
            let serverNow = state.estimatedServerNow(localNow: now)
            try store.transaction {
                let entries = try store.entries()
                for marker in markers where !entries.contains(where: { $0.mutationId == marker.value }) {
                    try store.setMeta(marker.key, nil)
                }
                for deferral in deferrals where deferral.after <= now {
                    try store.setMeta(Self.deferredAssignmentKey(deferral.taskId), nil)
                    let key = SGTasksCloudKey.task(deferral.taskId)
                    guard let task = state.tasks.first(where: { $0.id == deferral.taskId }), task.viewerRole == .owner, !task.isCompleted,
                          !Self.hasLiveAssignment(task, serverNow: serverNow),
                          !entries.contains(where: { !$0.isResolved && $0.kind == .operation(.inviteRequest) && $0.keys.contains(key) }) else {
                        continue
                    }
                    try self.enqueueAssignment(task: task, recipient: deferral.recipientTgId, store: store, state: state, automatic: true, nextAttemptAt: nil)
                    resent += 1
                }
            }
        } catch {
            if !store.isOpen { self.failStorage() }
            return
        }
        for _ in 0 ..< resent {
            self.emitAnalytics(.shared(action: SGTasksAnalytics.Shared.inviteSent))
        }
        if resent > 0 {
            self.rebuildState()
        }
    }

    /// Accepted, or pending and not past its expiry by the estimated server clock.
    static func hasLiveAssignment(_ task: SGTasksCloudTask, serverNow: Date?) -> Bool {
        guard let assignment = task.assignment else { return false }
        switch assignment.state {
        case .accepted:
            return true
        case .pending:
            return !assignment.isExpired(serverTime: serverNow)
        case .declined, .revoked, .left, .expired:
            return false
        }
    }

    /// Inside the answer's transaction: a 429 with a long `Retry-After` on an `invitation.request`
    /// (single route or batch item). The entry goes and the assignment waits as
    /// `assign_deferred.<taskId>` — no account gate, no attempt, the drain continues with the next
    /// entry (F8: a held entry would block every later edit of the task). A second long 429 on the
    /// automatic re-send rewrites the time.
    private func deferAssignment(_ entry: SGTasksCloudStoredEntry, request op: SGTasksWire.InviteRequest, after: Date, store: SGTasksCloudStore) throws {
        try store.deleteEntry(seq: entry.seq)
        try store.setMeta(Self.deferredAssignmentKey(op.taskId), Self.encodedDeferral(recipient: op.recipientTgId, after: after))
        let resendKey = Self.automaticResendKey(op.taskId)
        if try store.meta(resendKey) == entry.mutationId {
            try store.setMeta(resendKey, nil)
        }
    }

    private static func taskId(of entry: SGTasksCloudStoredEntry) -> SGTasksWire.UUID? {
        guard let taskKey = entry.keys.first(where: { $0.hasPrefix("task:") }) else { return nil }
        return SGTasksWire.UUID(String(taskKey.dropFirst("task:".count)))
    }

    /// The entry is the automatic re-send of a deferred assignment (`assign_resend.<taskId>` names
    /// its mutation id).
    func isAutomaticResend(_ entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore) throws -> Bool {
        guard entry.kind == .operation(.inviteRequest), let taskId = Self.taskId(of: entry) else { return false }
        return try store.meta(Self.automaticResendKey(taskId)) == entry.mutationId
    }

    /// A definite refusal of the automatic re-send (the task was deleted, completed or reassigned
    /// meanwhile): the entry and its marker go — no Unsent Changes row, no notice; the row shows
    /// whatever the projection says.
    func dropAutomaticResend(_ entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore) throws {
        try store.deleteEntry(seq: entry.seq)
        if let taskId = Self.taskId(of: entry) {
            try store.setMeta(Self.automaticResendKey(taskId), nil)
        }
    }

    /// The quiet drop of either automatic entry: a re-send loses its marker (§12.2), an automatic
    /// accept records that the device gave up on the invitation (§5.3).
    func dropAutomaticEntry(_ entry: SGTasksCloudStoredEntry, resend: Bool, store: SGTasksCloudStore) throws {
        if resend {
            try self.dropAutomaticResend(entry, store: store)
        } else {
            try self.dropAutomaticAccept(entry, store: store)
        }
    }

    /// Inside the answer's transaction, after an acknowledged `invitation.request`: its re-send
    /// marker (if it was one) goes, and — §4.1 — a task whose shadow still carries a legacy
    /// `annotation` (a per-task Yuborish on an annotation-only task) gets the chained owner-field
    /// clear, `task.patch {set: {annotation: null}, expect: {annotation: <the shadow's>}}`, on the
    /// task key: no base revision, sealed at once (R4 server), one `mutations` attempt. Once it lands
    /// the annotation is a legacy candidate on no device of the account; a `field_changed` on it is
    /// dropped quietly (`patchResolution`). Never queued twice for one task.
    func settleAssignmentReceipt(taskId: SGTasksWire.UUID, mutationId: String, store: SGTasksCloudStore) throws {
        let resendKey = Self.automaticResendKey(taskId)
        if try store.meta(resendKey) == mutationId {
            try store.setMeta(resendKey, nil)
        }
        guard !self.isConsentWithdrawn, try Self.isServerWire4(store), let task = try self.shadowTask(taskId, store: store), task.viewerRole == .owner, let annotation = task.content.annotation else { return }
        let key = SGTasksCloudKey.task(taskId)
        let alreadyQueued = try store.entries().contains { entry in
            guard !entry.isResolved, entry.kind == .taskPatch, entry.keys.contains(key), case let .patch(request)? = try? SGTasksWire.SealedMutation(wireJSON: entry.body) else { return false }
            return Self.isAnnotationClear(request.patch)
        }
        guard !alreadyQueued else { return }
        // A delete of the task is queued behind this request (or already acknowledged): the clear
        // would land after it and meet a 404 for an edit the user never made. Nothing to clear.
        let deleteQueued = try store.entries().contains { $0.operationClass == .taskDelete && $0.keys.contains(key) }
        guard !deleteQueued else { return }
        let keys = [key] + (task.content.listId.map { [SGTasksCloudKey.list($0)] } ?? [])
        try self.insertPatch(Self.annotationClearPatch(taskId: taskId, annotation: annotation), keys: keys, store: store)
    }

    private func forgetSharedAfterNotFound(entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore) throws {
        for key in entry.keys {
            if key.hasPrefix("task:") {
                let id = String(key.dropFirst("task:".count))
                _ = try self.forgetSharedResource(kind: "task", id: id, store: store)
            } else if key.hasPrefix("invitation:") {
                let id = String(key.dropFirst("invitation:".count))
                try store.remove(.shadow, kind: "invitation", id: id)
                _ = try self.forgetSharedResource(kind: "invitation", id: id, store: store)
            }
        }
        if try store.entry(seq: entry.seq) != nil {
            try store.deleteEntry(seq: entry.seq)
        }
    }
}
