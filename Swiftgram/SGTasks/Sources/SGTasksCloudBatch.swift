import Foundation
import SGEntitlement

// MARK: - R4 drain: POST /v1/tasks/mutations/batch (design 30 §5.3, §7.2)
//
// The `allowed` engine sends due, chain-free entries in batches: homogeneous in origin, user
// entries first, at most 100 items, sized by an adaptive per-account byte budget, at most 10
// batches per cycle. Every item's answer goes through the same `handleMutationResult` as the single
// route; a `skipped` item goes back to the queue with the SAME identity and no attempt counted.
//
// Fallbacks: while the batch route is unavailable (404, 503 `batch_disabled`, or three consecutive
// batch 503s: 15 min) USER entries take the single route; a one-entry 413 sends that user entry
// alone through it. A `migration` entry never takes the single route: it waits for the batch route,
// and an item 503 `migration_paused` holds every migration entry until its Retry-After while user
// entries keep going.
//
// Adaptive size: a timeout, an outcome-unknown answer or a 413 halves the budget (down to one entry
// per batch); three consecutive fully processed batches double it (at most 512 KiB). A
// multi-item batch that failed as a whole counts no attempt on its entries — its size, not the
// entries, is what gets adjusted — so a slow uplink converges to one-entry batches instead of
// stalling entries; from there on attempts count as for single sends.
//
// A 422 that refuses the whole batch: the server validates every item while it reads the batch
// (a `created_at` in its future, say), so one refused item refuses the request and nothing runs.
// A multi-item batch refused so goes back to the queue with no attempt, and batches carry one
// entry until each of its entries was sent alone (or left the queue): only an entry the server
// refuses alone becomes `invalid`, and a one-entry batch's 422 is `invalid` at once. The set is in
// memory; after a restart such a batch is refused and split once more, again with no attempt.
// Once per store, the entries an older build left `invalid` go back to the queue — such a refusal
// cannot be told from an entry's own (`repairBatchRefusals`).

extension SGTasksCloudRepository {
    static let maximumBatchesPerCycle = 10
    static let initialBatchByteBudget = 65536
    /// Halving stops here: at or below the reserves every batch is one entry.
    static let minimumBatchByteBudget = 1024
    /// Room kept for the sponsor `creation_proof` (a JWS of at most 32 KiB) when a create is in it.
    static let creationProofReserve = 34000
    static let batchEnvelopeReserve = 1024
    static let batchSuccessesToGrow = 3
    static let batch503sToFallBack = 3
    static let batchUnavailableWindow: TimeInterval = 900
    /// `migration_paused` without a Retry-After (the server sends 3600).
    static let defaultMigrationPause: TimeInterval = 3600

    struct BatchItem {
        let seq: Int64
        let mutation: SGTasksWire.SealedMutation
        let origin: SGTasksWire.MutationOrigin
    }

    private enum BatchNext {
        /// The next batch may go out in this cycle.
        case next
        case stop
        /// The batch route is out: user entries continue through the single route.
        case singleRoute
        /// A one-entry 413 of a user entry: it goes alone through the single route.
        case sendAlone(BatchItem)
    }

    /// The R4 drain. Returns the number of acknowledgements.
    func drainBatches() async -> Int {
        var acknowledged = 0
        var batches = 0
        while batches < Self.maximumBatchesPerCycle {
            if self.onQueue({ self.isBatchRouteUnavailable() }) {
                return acknowledged + (await self.drain())
            }
            let items: [BatchItem] = self.onQueue {
                guard let store = self.store, self.mayRequest else { return [] }
                do {
                    return try store.transaction { try self.prepareNextBatch(store: store) }
                } catch {
                    if !store.isOpen { self.failStorage() }
                    return []
                }
            }
            guard !items.isEmpty else { break }
            batches += 1
            guard let request = try? SGTasksWire.MutationBatchRequest(batchId: SGTasksWire.UUID.generate(), items: items.map { SGTasksWire.MutationBatchRequest.Item($0.mutation, origin: $0.origin) }) else {
                // Never expected (the batch was sized and validated): nothing was sent.
                self.onQueue { self.requeueSending(items) }
                break
            }
            self.onQueue {
                if items.count == 1 {
                    // Sent alone: its answer is its own.
                    self.batchSplitIds.remove(items[0].mutation.mutationId.rawValue)
                }
                self.rebuildState()
            }
            for item in items where item.mutation.kind.isCreation {
                // Durable import provenance BEFORE the bytes can reach the server.
                self.recordImportProvenance(mutationId: item.mutation.mutationId.rawValue, acknowledged: false)
            }
            let check = self.trafficCheck()
            let result = await self.environment.transport.mutationBatch(request, accountPeerId: self.accountPeerId, stillWanted: check.ask)
            let handled: (acknowledged: [BatchItem], next: BatchNext) = self.onQueue {
                guard self.isFenceCurrent else {
                    // A fenced scope's answer is never applied (see `sendSingle`).
                    guard !self.isInvalidated, self.store != nil else { return ([], .stop) }
                    self.fencePrincipal()
                    self.requeueSending(items)
                    self.rebuildState()
                    return ([], .stop)
                }
                if check.refused {
                    // Refused by its own re-check in SGEntitlement's account gate: the batch never
                    // went out (see `sendSingle`). No attempt, no backoff, no batch-size change.
                    self.requeueSending(items)
                    self.rebuildState()
                    return ([], .stop)
                }
                let handled = self.handleBatchResult(items, result: result)
                self.rebuildState()
                return handled
            }
            acknowledged += handled.acknowledged.count
            for item in handled.acknowledged where item.mutation.kind.isCreation {
                self.recordImportProvenance(mutationId: item.mutation.mutationId.rawValue, acknowledged: true)
            }
            switch handled.next {
            case .next:
                continue
            case .stop:
                return acknowledged
            case .singleRoute:
                return acknowledged + (await self.drain())
            case let .sendAlone(item):
                let marked: Bool = self.onQueue {
                    guard let store = self.store, self.mayRequest else { return false }
                    return (try? store.transaction { try store.markSending(seq: item.seq) }) != nil
                }
                guard marked else { return acknowledged }
                switch await self.sendSingle(seq: item.seq, mutation: item.mutation) {
                case .acknowledged:
                    acknowledged += 1
                case .continueDraining:
                    break
                case .stopDraining:
                    return acknowledged
                }
            }
        }
        return acknowledged
    }

    // MARK: Building a batch

    /// Inside a transaction. The next batch, marked `sending`: due chain-free entries of ONE origin
    /// (user first), sealed as for a single send, as many as fit 100 items (one while a whole-batch
    /// 422 is split) and the byte budget minus the proof reserve — never fewer than one. Migration
    /// entries wait while migrations are paused.
    private func prepareNextBatch(store: SGTasksCloudStore) throws -> [BatchItem] {
        guard self.isGateOpen() else { return [] }
        let entries = try store.entries()
        let now = self.environment.now()
        let migrationPaused = (try store.realMeta("migration_paused_until")).map { $0 > now.timeIntervalSince1970 } ?? false
        let due = Self.chainFreeEntries(entries).filter { entry in
            if let next = entry.nextAttemptAt, next > now { return false }
            return entry.origin == .user || !migrationPaused
        }
        let budget = min(try self.batchByteBudget(store), SGTasksWire.maxBatchRequestBytes)
        let envelope = SGTasksWire.MutationBatchRequest.bodyBytes(of: [])
        let maxItems = self.isSplittingBatches(entries) ? 1 : SGTasksWire.maxBatchItems
        for origin in [SGTasksWire.MutationOrigin.user, .migration] {
            var chosen: [BatchItem] = []
            var bytes = envelope
            var hasCreation = false
            for entry in due where entry.origin == origin {
                guard chosen.count < maxItems else { break }
                guard let mutation = try self.sealedForSend(entry, entries: entries, store: store, now: now) else { continue }
                let itemBytes = SGTasksWire.MutationBatchRequest.bodyBytes(of: [SGTasksWire.MutationBatchRequest.Item(mutation, origin: origin)]) - envelope
                let total = bytes + itemBytes + (chosen.isEmpty ? 0 : 1)
                let reserve = hasCreation || mutation.kind.isCreation ? Self.creationProofReserve : Self.batchEnvelopeReserve
                if !chosen.isEmpty && (total > budget - reserve || total > SGTasksWire.maxBatchRequestBytes) {
                    break
                }
                chosen.append(BatchItem(seq: entry.seq, mutation: mutation, origin: origin))
                bytes = total
                hasCreation = hasCreation || mutation.kind.isCreation
            }
            if !chosen.isEmpty {
                for item in chosen {
                    try store.markSending(seq: item.seq)
                }
                return chosen
            }
        }
        return []
    }

    // MARK: Answers

    /// On queue. One batch answer: every item result applied (receipts are recorded even when
    /// another item paused the account), the budget adapted, the fallbacks recorded.
    private func handleBatchResult(_ items: [BatchItem], result: Result<SGTasksWire.MutationBatchResponse, SGTasksError>) -> (acknowledged: [BatchItem], next: BatchNext) {
        guard let store = self.store else { return ([], .stop) }
        switch result {
        case let .success(response):
            // A batch 200 is an R4 server (`x-wire-negotiation`). Recorded first: an item below may
            // re-encode a refused R4-only entry, or record a consent fence whose doubling the
            // answer's success must not erase.
            self.updateBatchState(store) { store in
                try self.noteServerAnswer(serverWire: response.serverWire, provesWire4: true, store: store)
                try store.setMeta("batch_503_streak", nil)
            }
            var acknowledged: [BatchItem] = []
            var stop = false
            var skipped = false
            for (item, itemResult) in zip(items, response.results) {
                switch itemResult {
                case let .receipt(receipt):
                    let outcome = self.handleMutationResult(seq: item.seq, mutation: item.mutation, result: .success(SGTasksWire.MutationResponse(receipt: receipt, serverTime: response.serverTime, serverWire: response.serverWire)))
                    if outcome == .acknowledged {
                        acknowledged.append(item)
                    } else if outcome == .stopDraining {
                        stop = true
                    }
                case let .error(_, error):
                    if self.handleMutationResult(seq: item.seq, mutation: item.mutation, result: .failure(error)) == .stopDraining {
                        stop = true
                    }
                case .skipped:
                    // Never started: resent later with the same identity, no attempt.
                    skipped = true
                    self.requeueSending([item])
                }
            }
            self.updateBatchState(store) { store in
                if skipped {
                    try store.setMeta("batch_success_streak", nil)
                } else {
                    try self.noteFullBatch(store)
                }
            }
            return (acknowledged, stop ? .stop : .next)
        case let .failure(error):
            return ([], self.handleBatchFailure(items, error: error, store: store))
        }
    }

    /// On queue. The batch call failed as a whole (no item answers). Refinements first.
    private func handleBatchFailure(_ items: [BatchItem], error: SGTasksError, store: SGTasksCloudStore) -> BatchNext {
        let now = self.environment.now()
        switch error.refinement {
        case .batchDisabled?:
            self.requeueSending(items)
            self.updateBatchState(store) { try self.openBatchFallback($0) }
            return .singleRoute
        case let .consentRequired(effectiveAt)?:
            self.requeueSending(items)
            self.updateBatchState(store) { try self.recordConsentFence(effectiveAt: effectiveAt, store: $0) }
            return .stop
        case .migrationPaused?:
            self.requeueSending(items)
            self.updateBatchState(store) { try self.holdMigration(for: error.retryAfter.map(TimeInterval.init) ?? Self.defaultMigrationPause, store: $0) }
            return .next
        case .fieldChanged?, .membersChanged?, nil:
            break
        }
        switch error.kind {
        case .notFound, .rejected(status: 404):
            // No batch route on this server (an R3 one, or rolled back).
            self.requeueSending(items)
            self.updateBatchState(store) { try self.openBatchFallback($0) }
            return .singleRoute
        case .rejected(status: 413):
            // A definite non-commit: send less.
            self.updateBatchState(store) { try self.shrinkBatchBudget($0) }
            guard items.count == 1, let item = items.first else {
                self.requeueSending(items)
                return .next
            }
            if item.origin == .user {
                self.requeueSending(items)
                return .sendAlone(item)
            }
            // A migration create is never sent alone through the single route: as R3, invalid.
            _ = self.handleMutationResult(seq: item.seq, mutation: item.mutation, result: .failure(error))
            return .next
        case .unavailable:
            // Any 5xx may have committed (`outcomeUnknown`); three in a row: the single route.
            var fallBack = false
            self.updateBatchState(store) { store in
                try self.shrinkBatchBudget(store)
                let streak = (try store.integerMeta("batch_503_streak") ?? 0) + 1
                if streak >= Int64(Self.batch503sToFallBack) {
                    try self.openBatchFallback(store)
                    fallBack = true
                } else {
                    try store.setMeta("batch_503_streak", String(streak))
                }
            }
            if items.count == 1, let item = items.first {
                _ = self.handleMutationResult(seq: item.seq, mutation: item.mutation, result: .failure(error))
            } else {
                self.requeueSending(items)
                let delay = error.retryAfter.map(TimeInterval.init) ?? Self.backoff(attempt: self.pullFailures + 1)
                self.pullFailures += 1
                self.updateBatchState(store) { try self.extendAccountGate(by: delay, reason: error.retryAfter != nil ? "unavailable" : "offline", store: $0) }
                self.phase = .unavailable(retryAt: now.addingTimeInterval(delay))
                self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
            }
            return fallBack ? .singleRoute : .stop
        case .transport, .credentialChanged, .malformedResponse:
            if error.outcomeUnknown {
                self.updateBatchState(store) { try self.shrinkBatchBudget($0) }
            } else {
                self.updateBatchState(store) { try $0.setMeta("batch_success_streak", nil) }
            }
            if items.count == 1, error.outcomeUnknown, let item = items.first {
                _ = self.handleMutationResult(seq: item.seq, mutation: item.mutation, result: .failure(error))
                return .stop
            }
            // Certainly not sent, or a whole batch: no attempt on its entries; the account backs off.
            self.requeueSending(items)
            self.pullFailures += 1
            let delay = Self.backoff(attempt: self.pullFailures)
            self.updateBatchState(store) { try self.extendAccountGate(by: delay, reason: "offline", store: $0) }
            if case .transport = error.kind {
                self.phase = .offline(retryAt: now.addingTimeInterval(delay))
            } else {
                self.phase = .unavailable(retryAt: now.addingTimeInterval(delay))
            }
            self.cycleErrorCode = SGTasksAnalytics.errorCode(error)
            return .stop
        case .invalidRequest:
            self.updateBatchState(store) { try $0.setMeta("batch_success_streak", nil) }
            if items.count > 1 {
                // A 422 names no item: one item the server refused while it read the batch refused
                // the request, and nothing ran. Back to the queue with no attempt, then one entry per
                // batch, so the refusal lands on the entry that caused it.
                self.requeueSending(items)
                self.batchSplitIds.formUnion(items.map { $0.mutation.mutationId.rawValue })
                return .next
            }
            // A one-entry batch: the envelope 422 is its entry's, an R3 422 (not an R4-only item of
            // an R3 server), never re-encoded.
            for item in items {
                self.markInvalid(item, serverTime: error.serverTime)
            }
            return .next
        case .accountNotLinked, .notSignedIn, .notConfigured, .session, .rateLimited, .creationNotPermitted, .conflict, .resyncRequired, .mutationInFlight, .mutationMismatch, .invalidLocalRequest, .rejected:
            // The account-level answers (pauses, the 429 gate) as for a single send, item by item.
            self.updateBatchState(store) { try $0.setMeta("batch_success_streak", nil) }
            var stop = false
            for item in items where self.handleMutationResult(seq: item.seq, mutation: item.mutation, result: .failure(error)) == .stopDraining {
                stop = true
            }
            return stop ? .stop : .next
        }
    }

    // MARK: State

    /// On queue. Batch bookkeeping in its own transaction (a storage failure fails the store).
    private func updateBatchState(_ store: SGTasksCloudStore, _ body: (SGTasksCloudStore) throws -> Void) {
        do {
            try store.transaction { try body(store) }
        } catch {
            if !store.isOpen { self.failStorage() }
        }
    }

    /// On queue. Entries of a batch that never ran (or whose answer is not this scope's) return to
    /// the queue with the same identity and no attempt.
    private func requeueSending(_ items: [BatchItem]) {
        guard let store = self.store else { return }
        self.updateBatchState(store) { store in
            for item in items {
                try store.requeueSending(seq: item.seq)
            }
        }
    }

    private func markInvalid(_ item: BatchItem, serverTime: Date?) {
        guard let store = self.store else { return }
        var quiet = false
        self.updateBatchState(store) { store in
            // wf15 §12.2 / §5.3: a 422 on the automatic re-send of a deferred assignment or on the
            // automatic accept of a contact's invitation ends it quietly — never an Unsent Changes row.
            if let entry = try store.entry(seq: item.seq) {
                let resend = try self.isAutomaticResend(entry, store: store)
                let accept = try self.isAutomaticAccept(entry, store: store)
                if resend || accept {
                    try self.dropAutomaticEntry(entry, resend: resend, store: store)
                    quiet = true
                    return
                }
            }
            try store.setState(seq: item.seq, .invalid, serverTime: serverTime)
        }
        if !quiet {
            self.emitAnalytics(.syncIssue(kind: SGTasksAnalytics.SyncIssue.invalid))
        }
    }

    /// On queue. Batches carry one entry while an entry of a batch a 422 refused as a whole is still
    /// queued (due or not) and was not sent alone; one that left the queue (acknowledged, invalid,
    /// discarded, retired by a withdrawal or a principal change) no longer counts.
    private func isSplittingBatches(_ entries: [SGTasksCloudStoredEntry]) -> Bool {
        guard !self.batchSplitIds.isEmpty else { return false }
        self.batchSplitIds.formIntersection(entries.filter { $0.state == .queued }.map { $0.mutationId })
        return !self.batchSplitIds.isEmpty
    }

    func batchByteBudget(_ store: SGTasksCloudStore) throws -> Int {
        guard let stored = try store.integerMeta("batch_byte_budget"), stored >= Int64(Self.minimumBatchByteBudget), stored <= Int64(SGTasksWire.maxBatchRequestBytes) else {
            return Self.initialBatchByteBudget
        }
        return Int(stored)
    }

    private func shrinkBatchBudget(_ store: SGTasksCloudStore) throws {
        let budget = max(try self.batchByteBudget(store) / 2, Self.minimumBatchByteBudget)
        try store.setMeta("batch_byte_budget", String(budget))
        try store.setMeta("batch_success_streak", nil)
    }

    /// A batch whose every item was processed: three in a row double the budget.
    private func noteFullBatch(_ store: SGTasksCloudStore) throws {
        let streak = (try store.integerMeta("batch_success_streak") ?? 0) + 1
        if streak >= Int64(Self.batchSuccessesToGrow) {
            let budget = min(try self.batchByteBudget(store) * 2, SGTasksWire.maxBatchRequestBytes)
            try store.setMeta("batch_byte_budget", String(budget))
            try store.setMeta("batch_success_streak", nil)
        } else {
            try store.setMeta("batch_success_streak", String(streak))
        }
    }

    private func openBatchFallback(_ store: SGTasksCloudStore) throws {
        let until = self.environment.now().addingTimeInterval(Self.batchUnavailableWindow)
        try store.setMeta("batch_unavailable_until", String(until.timeIntervalSince1970))
        try store.setMeta("batch_503_streak", nil)
        try store.setMeta("batch_success_streak", nil)
    }

    /// Inside a transaction. Holds every migration entry until `delay` passes (never shortened).
    func holdMigration(for delay: TimeInterval, store: SGTasksCloudStore) throws {
        let until = self.environment.now().addingTimeInterval(max(delay, 0)).timeIntervalSince1970
        let current = try store.realMeta("migration_paused_until") ?? 0
        try store.setMeta("migration_paused_until", String(max(until, current)))
    }

    /// On queue. The batch route is out until `batch_unavailable_until`.
    func isBatchRouteUnavailable() -> Bool {
        guard let store = self.store, let until = try? store.realMeta("batch_unavailable_until") else { return false }
        return until > self.environment.now().timeIntervalSince1970
    }

    /// On queue. When a migration entry may go out at the earliest: after a migration pause and a
    /// batch-route outage (nil: neither holds it).
    func batchRouteHold(store: SGTasksCloudStore) -> Date? {
        let paused = (try? store.realMeta("migration_paused_until")) ?? nil
        let unavailable = (try? store.realMeta("batch_unavailable_until")) ?? nil
        guard let latest = [paused, unavailable].compactMap({ $0 }).max() else { return nil }
        return Date(timeIntervalSince1970: latest)
    }

    // MARK: One-time repair

    /// Inside the store's opening transaction, once per store (meta `batch_refusals_repaired`, set in
    /// the same transaction; a new store is marked at its first open, before any send): an older
    /// build marked EVERY entry of a multi-item batch `invalid` when a 422 refused the batch as a
    /// whole. A 422 names no item and the outbox keeps no error code, so every `invalid` entry goes
    /// back to the queue once, same id and bytes, its attempts as they were (the refusal counted
    /// none). A batch refused again is split, so an entry the server refuses alone ends `invalid`
    /// for good.
    func repairBatchRefusals(store: SGTasksCloudStore) throws {
        guard try store.meta("batch_refusals_repaired") == nil else { return }
        for entry in try store.entries() where entry.state == .invalid {
            try store.setState(seq: entry.seq, .queued)
        }
        try store.setMeta("batch_refusals_repaired", "1")
    }

    // MARK: Downgrade (x-wire-negotiation.downgrade)

    /// Inside the answer's transaction. A 422 on an R4-only entry from an R3 server is a definite
    /// non-commit: the entry is re-encoded ONCE as R3 under a NEW mutation id, in its place — a
    /// `task.patch` as a `task.update` of the server row with the `set` values (base: the chain's
    /// receipt revision, else the row's), a members-fenced `list.delete` without the fence. false
    /// when it cannot be (no server row of the task, or content the R3 rules refuse): the entry is
    /// then invalid, as before.
    func reencodeAsR3(_ entry: SGTasksCloudStoredEntry, mutation: SGTasksWire.SealedMutation, store: SGTasksCloudStore) throws -> Bool {
        let operation: SGTasksWire.Operation
        switch mutation {
        case let .patch(request):
            guard let task = try self.shadowTask(request.patch.taskId, store: store) else { return false }
            let base = try store.chainRevision(SGTasksCloudKey.task(task.id)).flatMap(SGTasksWire.Revision.init) ?? task.revision
            operation = .taskUpdate(SGTasksWire.TaskUpdate(taskId: task.id, baseRevision: base, content: task.content.applying(request.patch.set)))
        case let .mutation(request):
            guard case let .listDelete(op) = request.operation, op.baseMembersRevision != nil else { return false }
            operation = .listDelete(SGTasksWire.ListDelete(listId: op.listId, baseRevision: op.baseRevision))
        }
        guard let sealed = try? Self.sealedRequest(mutationId: SGTasksWire.UUID.generate(), operation: operation) else { return false }
        try store.deleteEntry(seq: entry.seq)
        try self.insertSealed(.mutation(sealed), keys: entry.keys, sealed: true, store: store, seq: entry.seq, subject: entry.subject, isShared: entry.isShared, origin: entry.origin, autoResolutions: entry.autoResolutions)
        return true
    }
}
