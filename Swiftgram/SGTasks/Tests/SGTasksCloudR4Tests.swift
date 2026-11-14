import Foundation
import SGEntitlement

// Host tests for the R4 engine of SGTasksCloudRepository (design 30 §5.3, §7.2-§7.4, §3.12). No
// `@main`: `SGTasksCloudRepositoryTests.main` runs `defaultPermissionSendsNothing` FIRST, before any
// permission source is installed, then appends `cases`. Every case installs the permission it needs
// and restores `.legacy` (the R3 cases' setting) when it ends. The scripted server stands in for the
// SGEntitlement facade (an R4 server echoes `X-Tasks-Wire: 4`); it proves repository behaviour, not
// backend behaviour.

/// What the consent-fence notifications carried (posted on the main queue).
private final class NoticeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(effectiveAt: String?, accountPeerId: Int64?)] = []

    func append(effectiveAt: String?, accountPeerId: Int64?) {
        self.lock.lock()
        self.items.append((effectiveAt, accountPeerId))
        self.lock.unlock()
    }

    var entries: [(effectiveAt: String?, accountPeerId: Int64?)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.items
    }
}

/// The analytics events one case saw (the sink may run on any queue).
private final class AnalyticsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SGTasksAnalyticsEvent] = []

    func append(_ event: SGTasksAnalyticsEvent) {
        self.lock.lock()
        self.items.append(event)
        self.lock.unlock()
    }

    var events: [SGTasksAnalyticsEvent] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.items
    }
}

enum SGTasksCloudR4Tests {
    static let cases: [(String, () async throws -> Void)] = [
        ("R4: legacy stays exactly R3 — single route, explicit conflicts — even against an R4 server", legacyStaysR3),
        ("R4: waiting/forbidden send nothing (realtime included) and show the consent hold; permissionChanged resumes", consentHoldAndResume),
        ("R4: a 250-entry migration outbox drains in homogeneous batches, user entries first; skipped items return with the same ids", migrationOutboxDrains),
        ("R4: 404 and batch_disabled send user entries through the single route; migration entries wait for the batch route", batchRouteFallback),
        ("R4: three consecutive batch 503s fall back for user entries; each halves the budget and counts no attempt", batch503Fallback),
        ("R4: migration_paused holds migration batches only, until its Retry-After", migrationPausedHoldsMigrationOnly),
        ("R4: 413 halves and resends at once; a one-entry 413 sends a user entry alone, a migration create never", batch413),
        ("R4: a scripted timeout halves the next batch, 3 full batches double it, entries never stall on batch size", adaptiveBatchSize),
        ("R4: a whole-batch 422 resends the entries one per batch, same bytes, no attempt; only the one refused alone ends invalid (user and migration)", wholeBatch422IsSplit),
        ("R4: a whole-batch 422 split is bounded: each entry is sent alone once; a one-entry batch's 422 is invalid at once", wholeBatch422SplitIsBounded),
        ("R4: the split is in memory: after a restart the batch is refused and split once more, again with no attempt", wholeBatch422SplitAfterRestart),
        ("R4: entries an older build left invalid for a whole-batch 422 are requeued once per store, then split; a later open repairs nothing", batchRefusalsRepairedOnce),
        ("R4: server_wire follows the echo; a 2xx without it clears it; R4 projections prove it", serverWireNegotiation),
        ("R4/R5: the request wire is the transport's (4 unless the build says 5); an echo of 4 or 5 is recorded numerically and keeps the R4 engine (task.patch, batch, migration entries); an unknown echo or none clears it", requestWireAndNumericEcho),
        ("R4: downgrade — a 422 on task.patch becomes a task.update, on a members-fenced list.delete a delete without the key", downgradeReencodesOnce),
        ("R4: updateTask seals a task.patch of the changed fields only (none for no change); the overlay applies it", patchGenerationAndOverlay),
        ("R4: field_changed re-patches the other fields and keeps the conflicting part explicit", autoResolvePatch),
        ("R4: task.complete / task.delete conflicts resolve automatically (dropped, resealed, deleteKept)", autoResolveTaskRows),
        ("R4: list.update merges three-way; list.delete reseals; members_changed stays explicit", autoResolveListRows),
        ("R4: an intent is resolved automatically at most twice, then explicitly", autoResolveBound),
        ("R4: stalled / blocked entries requeue on drive occasions, at most 5 times; paid-mode exemption and policy change", autoRequeueBounds),
        ("R4: a not-linked pause ends on a NEW binding only", notLinkedEndsOnBindingChange),
        ("R4: 403 tasks_consent_required fences the account: requeued without attempts, nothing discarded, 30 s doubling to 900 s", consentFence),
        ("R4: withdrawal discards unsent rows, bumps the epoch, refuses inserts; re-grant resumes", withdrawalAndRegrant),
        ("R4: a mutation that waited in SGEntitlement's gate past a withdrawal is never sent; the discard keeps the outbox, nothing fails", gateWaitPastWithdrawal),
        ("R4: a batch that waited in the gate past a permission change is never sent; its entries return unattempted, no backoff", gateWaitPastPermissionChange),
        ("R4: a snapshot or changes page that waited in the gate past a withdrawal is never fetched; no pause, no backoff", gateWaitRefusesReads),
        ("R4: both realtime calls carry the repository's CURRENT traffic permission as their post-gate check", realtimeCarriesPostGateCheck),
        ("R4: unsent counts split by origin, live and from the file (an R3-era store counts all as user)", unsentCountsByOrigin),
        ("R4: an R3 store upgrades to schema 3 additively and resnapshots once", storeUpgradeFromR3),
        ("R4: every 409 tasks_resync_required that asks for a resnapshot bumps resync_generation", resyncGeneration),
        ("R4: flush runs one bounded cycle; a driven repository continues while it makes progress", flushAndContinuation),
        ("R4: analytics events reach SGTasksAnalytics.sink (cloud scope, sync issues, failed cycles)", analyticsSink),
        ("wf15 I4a: the pacer table — per person, per minute, total, pending; counter keys, expiry and the D4 allowance", invitationPacerTable),
        ("wf15 I4a: assignTask on a synced task seals the invite on the shadow revision; on an unsynced task it chains behind the create's receipt; Qayta yuborish needs an ended state", assignTaskSyncedAndUnsynced),
        ("wf15 I4a: a blocked create keeps the chained invite waiting; discarding the create discards it", blockedCreateHoldsInvite),
        ("wf15 I4a: pick-time refusals — self, non-user, completed task, 6th per person, 11th per minute, 96th per day, 95 pending — queue nothing; counters are charged at enqueue and purged after two UTC days", pickTimeRefusals),
        ("wf15 I4a: a long 429 on an invitation (single route and batch item) defers the assignment: no account gate, other entries keep flowing, counted as unsent (TasksLogoutNotice), re-sent when due without a pacer charge, nothing left after the receipt", longRateLimitDefersAssignment),
        ("wf15 I4a: a newer pick cancels the deferral; a second long 429 re-defers; a short 429 keeps the account gate", deferralCancelAndRedefer),
        ("wf15 I4a: a due deferral of a deleted, completed or reassigned task ends quietly; a refused automatic re-send is dropped without an Unsent Changes row; revision_changed on it reseals and stays automatic", deferralEndsQuietly),
        ("wf15 I4a: invitation.request / invitation.revoke + revision_changed resolve automatically (resealed from the shadow; a revoke only while its epoch is current; explicit for a completed task)", autoResolveInviteRows),
        ("wf15 I4a: an invitation.request receipt on a task with a legacy annotation chains task.patch annotation=null; a field_changed on it is dropped quietly; without an annotation, no patch", receiptChainsAnnotationClear),
        ("wf15 review E-11: no annotation clear is chained behind a queued delete of the task; a 404 on an annotation clear is dropped quietly (no notFound row, no notice)", annotationClearNeverTrailsADelete),
        ("wf15 review E-1: a Save (updateTask, repair) never writes or clears the annotation — a draft captured before Masʼulni olib tashlash or before a send's chained clear seals no annotation key; a draft without one keeps an annotation written elsewhere; the R3 full update carries the task's current one", saveNeverTouchesTheAnnotation)
    ]

    // MARK: - Fixtures

    private static func allow(_ permission: SGTasksSyncPermission = .allowed) {
        SGTasksCloudRepository.trafficPermission = { _ in permission }
    }

    private static func restoreLegacy() {
        SGTasksCloudRepository.trafficPermission = { _ in .legacy }
    }

    /// An `allowed` account bound to principal A, an R4 server (every answer echoes wire 4) and a
    /// complete snapshot of `items`.
    private static func r4Board(_ items: [SGTasksWire.Projection] = []) async throws -> (Harness, SGTasksCloudRepository) {
        let harness = try Harness()
        harness.server.defaultServerWire = 4
        let repository = harness.repository()
        try await harness.bootstrap(repository, items: items)
        try check(try harness.cloudText("SELECT value FROM meta WHERE key = 'server_wire';") == "4", "The R4 snapshot did not record wire 4")
        return (harness, repository)
    }

    private static func task(_ id: SGTasksWire.UUID, rev: String, title: String, priority: Int = 0, completed: Bool = false, list: SGTasksWire.UUID? = nil) -> SGTasksWire.Projection {
        let content = SGTasksWire.Content(listId: list, title: title, description: nil, dueAt: nil, priority: priority, sortOrder: 0, annotation: nil)
        return .task(SGTasksWire.Task(id: id, revision: revision(rev), ownerTgId: ownTg, viewerRole: .owner, content: content, isCompleted: completed, completedAt: completed ? instant() : nil, createdAt: instant(), updatedAt: instant(), assignment: nil))
    }

    private static func r4List(_ id: SGTasksWire.UUID, rev: String, title: String, sortOrder: Int32 = 0, members: String?) -> SGTasksWire.Projection {
        return .list(SGTasksWire.List(id: id, revision: revision(rev), title: title, sortOrder: sortOrder, createdAt: instant(), updatedAt: instant(), membersRevision: members.map(revision)))
    }

    private static func receipt(_ mutation: SGTasksWire.SealedMutation, revision: String? = "1") -> SGTasksWire.BatchItemResult {
        guard case let .success(response) = ack(mutation, revision: revision) else {
            preconditionFailure("ack() always succeeds")
        }
        return .receipt(response.receipt)
    }

    private static func itemError(_ kind: SGTasksError.Kind, status: Int, retryAfter: Int? = nil, refinement: SGTasksError.Refinement? = nil) -> SGTasksWire.BatchItemResult {
        return .error(status: status, SGTasksError(kind: kind, retryAfter: retryAfter, serverTime: nil, outcomeUnknown: false, refinement: refinement))
    }

    private static func answer(_ request: SGTasksWire.MutationBatchRequest, retryAfter: Int? = nil, serverWire: Int? = 4, _ result: (Int, SGTasksWire.MutationBatchRequest.Item) -> SGTasksWire.BatchItemResult) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        let results = request.items.enumerated().map { result($0.offset, $0.element) }
        return .success(SGTasksWire.MutationBatchResponse(batchId: request.batchId, results: results, retryAfter: retryAfter, serverTime: instant(), serverWire: serverWire))
    }

    private static func acceptAll(_ request: SGTasksWire.MutationBatchRequest) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        return answer(request) { _, item in receipt(item.mutation) }
    }

    private static let timeout: (SGTasksWire.MutationBatchRequest) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> = { _ in
        failure(.transport(.timeout), outcomeUnknown: true)
    }

    /// Migration-origin creates, as the migration step queues them (no annotation, Cloud Inbox).
    @discardableResult
    private static func enqueueMigrationCreates(_ repository: SGTasksCloudRepository, count: Int, expectedConsentEpoch: Int64? = nil) throws -> [SGTasksWire.UUID] {
        return try repository.mutate { store, _ in
            var ids: [SGTasksWire.UUID] = []
            for index in 0 ..< count {
                let id = SGTasksWire.UUID.generate()
                let content = SGTasksWire.Content(listId: nil, title: "Migrated \(index)", description: nil, dueAt: nil, priority: 0, sortOrder: Int32(index * 1024), annotation: nil)
                try repository.insert(.taskCreate(SGTasksWire.TaskCreate(taskId: id, content: content, createdAt: nil, isCompleted: false, completedAt: nil)), keys: [SGTasksCloudKey.task(id)], sealed: true, store: store, origin: .migration, expectedConsentEpoch: expectedConsentEpoch)
                ids.append(id)
            }
            return ids
        }
    }

    private static func createdTaskId(_ item: SGTasksWire.MutationBatchRequest.Item) -> SGTasksWire.UUID? {
        if case let .mutation(request) = item.mutation, case let .taskCreate(op) = request.operation {
            return op.taskId
        }
        return nil
    }

    private static func meta(_ harness: Harness, _ key: String, account: Int64 = 42) throws -> String? {
        return try harness.cloudText("SELECT value FROM meta WHERE key = '\(key)';", accountPeerId: account)
    }

    private static func maxAttempts(_ harness: Harness) throws -> Int64 {
        return try harness.cloudScalar("SELECT COALESCE(MAX(attempts), 0) FROM outbox;")
    }

    private static func sealed(_ harness: Harness) throws -> [SGTasksWire.SealedMutation] {
        return try harness.outboxBodies().map { try SGTasksWire.SealedMutation(wireJSON: $0) }
    }

    // MARK: - The shipped default (run first, by the runner)

    /// The shipped default (no coordinator yet): `.forbidden` — no snapshot, changes, mutation,
    /// batch or realtime call, whatever the board does; local edits still work.
    static func defaultPermissionSendsNothing() async throws {
        let harness = try Harness()
        let service = SGTasksRealtimeTestService()
        harness.realtime = SGTasksCloudRealtimeEnvironment(service: service, makeScheduler: { _ in SGTasksRealtimeTestScheduler() }, random: { 1.0 })
        let repository = harness.repository()
        try check(SGTasksCloudRepository.trafficPermission(42) == .forbidden, "The default permission is not .forbidden")
        repository.start()
        repository.onQueue {}
        await repository.syncNow()
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Offline only"))
        repository.refresh()
        repository.requestDrive(.launch)
        await repository.syncNow()
        let counts = await repository.flush(timeout: 1)
        try check(harness.server.callCount == 0 && service.metadataCompletions.isEmpty, "A Tasks request went out under the default permission")
        try check(repository.state.phaseRefinement == .consentRequired(waiting: false), "The consent hold is not published: \(String(describing: repository.state.phaseRefinement))")
        try check(repository.state.tasks.map { $0.title } == ["Offline only"] && repository.state.entries.map { $0.status } == [.queued], "A local edit did not stay queued on the device")
        try check(counts?.user == 1 && counts?.migration == 0, "flush did not report the unsent change")
        repository.stop()
    }

    // MARK: - Permission

    private static func legacyStaysR3() async throws {
        allow(.legacy)
        defer { restoreLegacy() }
        let harness = try Harness()
        harness.server.defaultServerWire = 4
        let repository = harness.repository()
        let taskId = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [task(taskId, rev: "2", title: "Old")])
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "New"))
        try repository.setTaskCompleted(id: taskId, isCompleted: true)
        harness.server.mutationScript = [{ ack($0, revision: "1") }, { _ in failure(.conflict(.revisionChanged)) }]
        await repository.syncNow()
        try check(harness.server.sentBatches.isEmpty && harness.server.sentSealed.count == 2, "legacy did not use the single route alone")
        harness.server.changesScript = [changesPage([upsert(task(taskId, rev: "3", title: "Old"))], serverWire: 4)]
        await repository.syncNow()
        let complete = repository.state.entries.first { $0.kind == .taskComplete }
        try check(complete?.status == .conflict(.revisionChanged) && harness.server.sentSealed.count == 2, "legacy resolved a conflict by itself")
        try check(repository.state.phaseRefinement == nil, "legacy showed a consent hold")
    }

    private static func consentHoldAndResume() async throws {
        allow(.waiting)
        defer { restoreLegacy() }
        let harness = try Harness()
        let service = SGTasksRealtimeTestService()
        let scheduler = SGTasksRealtimeTestScheduler()
        harness.realtime = SGTasksCloudRealtimeEnvironment(service: service, makeScheduler: { _ in scheduler }, random: { 1.0 })
        let repository = harness.repository()
        repository.start()
        repository.onQueue {}
        await repository.syncNow()
        try check(harness.server.callCount == 0 && service.metadataCompletions.isEmpty, "waiting sent a Tasks request")
        try check(repository.state.phaseRefinement == .consentRequired(waiting: true), "waiting is not the consent hold")
        allow(.forbidden)
        repository.permissionChanged()
        repository.onQueue {}
        try check(repository.state.phaseRefinement == .consentRequired(waiting: false) && service.metadataCompletions.isEmpty, "forbidden is not the consent hold")
        // Granted: the hold ends, the visible board's realtime connects and REST runs.
        allow(.allowed)
        repository.permissionChanged()
        repository.onQueue {}
        try check(repository.state.phaseRefinement == nil, "the hold outlived the grant")
        try check(service.metadataCompletions.count == 1, "realtime did not follow the grant")
        try await harness.bootstrap(repository)
        try check(harness.server.snapshotCount == 1, "REST did not follow the grant")
        repository.stop()
    }

    // MARK: - Batch drain

    private static func migrationOutboxDrains() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        let migrated = try enqueueMigrationCreates(repository, count: 250)
        var userIds: [SGTasksWire.UUID] = []
        for index in 0 ..< 3 {
            userIds.append(try repository.createTask(SGTasksCloudTaskDraft(title: "Mine \(index)")))
        }
        // The first migration batch: the server's start window ended after 10 items.
        var skipped: [String] = []
        harness.server.batchScript = [
            { acceptAll($0) },
            { request in
                answer(request) { index, item in
                    if index < 10 {
                        return receipt(item.mutation)
                    }
                    skipped.append(item.mutation.mutationId.rawValue)
                    return .skipped
                }
            }
        ] + Array(repeating: { acceptAll($0) }, count: 8)
        await repository.syncNow()
        let batches = harness.server.sentBatches
        try check(harness.server.sentSealed.isEmpty, "the batch era used the single route")
        try check(batches.first.map { $0.items.map { $0.origin } } == [.user, .user, .user], "user entries did not go first, alone")
        try check(Set(batches.first?.items.compactMap(createdTaskId) ?? []) == Set(userIds), "the first batch was not the user creates")
        for batch in batches {
            try check(Set(batch.items.map { $0.origin }).count == 1, "a batch mixed origins")
            try check(batch.items.count <= SGTasksWire.maxBatchItems, "a batch over 100 items")
            try check(batch.items.count == 1 || batch.bodyBytes <= SGTasksWire.maxBatchRequestBytes - SGTasksCloudRepository.creationProofReserve, "a create batch left no room for the proof")
        }
        try check(batches.count <= SGTasksCloudRepository.maximumBatchesPerCycle, "more than 10 batches in one cycle")
        let migrationItems = batches.dropFirst().flatMap { $0.items }
        try check(Set(migrationItems.compactMap(createdTaskId)) == Set(migrated), "not every migrated row was sent")
        try check(batches.count > 1 && skipped.count == batches[1].items.count - 10, "the skip script did not apply: \(skipped.count)")
        let sentIds = migrationItems.map { $0.mutation.mutationId.rawValue }
        try check(skipped.allSatisfy { id in sentIds.filter { $0 == id }.count == 2 }, "a skipped item was not resent with the same mutation id")
        try check(sentIds.count == 250 + skipped.count, "a migration item was sent more often than its skip")
        try check(try maxAttempts(harness) == 0, "a skipped item counted an attempt")
        let counts = await repository.flush(timeout: 5)
        try check(counts?.user == 0 && counts?.migration == 0, "the outbox did not drain: \(String(describing: counts))")
    }

    private static func batchRouteFallback() async throws {
        allow()
        defer { restoreLegacy() }
        for refusal in [SGTasksError(kind: .rejected(status: 404)), SGTasksError(kind: .unavailable, refinement: .batchDisabled)] {
            let (harness, repository) = try await r4Board()
            let userA = try repository.createTask(SGTasksCloudTaskDraft(title: "User A"))
            let migrated = try enqueueMigrationCreates(repository, count: 3)
            harness.server.batchScript = [{ _ in .failure(refusal) }]
            harness.server.mutationScript = [{ ack($0, revision: "1") }]
            await repository.syncNow()
            try check(harness.server.sentBatches.count == 1 && harness.server.sentBatches[0].items.map { $0.origin } == [.user], "the user batch did not go first")
            guard harness.server.sentSealed.count == 1, case let .mutation(single) = harness.server.sentSealed[0], case let .taskCreate(op) = single.operation, op.taskId == userA else {
                throw CloudTestFailure.assertion("\(refusal.kind): the user entry did not take the single route")
            }
            try check(single.mutationId == harness.server.sentBatches[0].items[0].mutation.mutationId, "the fallback changed the mutation id")
            var counts = await repository.flush(timeout: 5)
            try check(counts?.user == 0 && counts?.migration == 3, "\(refusal.kind): migration entries did not wait")
            // Inside the window: no batch at all; a new user change takes the single route.
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: "User B"))
            harness.server.mutationScript = [{ ack($0, revision: "1") }]
            harness.clock = harness.clock.addingTimeInterval(60)
            await repository.syncNow()
            try check(harness.server.sentBatches.count == 1 && harness.server.sentSealed.count == 2, "the batch route was retried inside its window")
            try check(harness.server.sentSealed.allSatisfy { mutation in
                if case let .mutation(request) = mutation, case let .taskCreate(op) = request.operation { return !migrated.contains(op.taskId) }
                return true
            }, "a migration create took the single route")
            // After 15 minutes the batch route is back and the migration creates go.
            harness.clock = harness.clock.addingTimeInterval(SGTasksCloudRepository.batchUnavailableWindow)
            harness.server.batchScript = [{ acceptAll($0) }]
            await repository.syncNow()
            try check(harness.server.sentBatches.count == 2 && Set(harness.server.sentBatches[1].items.compactMap(createdTaskId)) == Set(migrated), "migration creates did not resume on the batch route")
            counts = await repository.flush(timeout: 5)
            try check(counts?.user == 0 && counts?.migration == 0, "the outbox did not drain after the window")
        }
    }

    private static func batch503Fallback() async throws {
        allow()
        defer { restoreLegacy() }
        // Completes, not creates: no proof reserve, so the halved batches still hold all three.
        let ids = (0 ..< 3).map { _ in SGTasksWire.UUID.generate() }
        let (harness, repository) = try await r4Board(ids.map { task($0, rev: "1", title: "Open") })
        for id in ids {
            try repository.setTaskCompleted(id: id, isCompleted: true)
        }
        harness.server.batchScript = Array(repeating: { _ in failure(.unavailable, outcomeUnknown: true) }, count: 3)
        for round in 1 ... 3 {
            await repository.syncNow()
            try check(harness.server.sentBatches.count == round, "round \(round): no batch")
            try check(try maxAttempts(harness) == 0, "round \(round): a whole-batch 503 counted attempts")
            // Past the account's short backoff, inside the 15 min window the third one opens.
            harness.clock = harness.clock.addingTimeInterval(round < 3 ? 1000 : 60)
        }
        try check(harness.server.sentBatches.allSatisfy { $0.items.count == 3 }, "the halved batches split the three completes")
        try check(try meta(harness, "batch_byte_budget") == "8192", "three 503s did not halve the budget three times")
        try check(try meta(harness, "batch_unavailable_until") != nil, "three 503s opened no fallback window")
        harness.server.mutationScript = Array(repeating: { ack($0, revision: "1") }, count: 3)
        await repository.syncNow()
        try check(harness.server.sentBatches.count == 3 && harness.server.sentSealed.count == 3, "user entries did not fall back to the single route")
    }

    private static func migrationPausedHoldsMigrationOnly() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        let migrated = try enqueueMigrationCreates(repository, count: 5)
        harness.server.batchScript = [{ request in
            answer(request, retryAfter: 3600) { index, _ in
                index == 0 ? itemError(.unavailable, status: 503, retryAfter: 3600, refinement: .migrationPaused) : .skipped
            }
        }]
        await repository.syncNow()
        try check(try harness.server.sentBatches.count == 1 && maxAttempts(harness) == 0, "migration_paused counted attempts")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE state = 'queued' AND origin = 'migration';") == 5, "the paused migration entries are not queued")
        try check(try meta(harness, "not_before") == nil, "migration_paused gated the whole account")
        let user = try repository.createTask(SGTasksCloudTaskDraft(title: "Still mine"))
        harness.server.batchScript = [{ acceptAll($0) }]
        harness.clock = harness.clock.addingTimeInterval(60)
        await repository.syncNow()
        try check(harness.server.sentBatches.count == 2 && harness.server.sentBatches[1].items.compactMap(createdTaskId) == [user], "user entries did not continue while migrations were paused")
        harness.clock = harness.clock.addingTimeInterval(3600)
        harness.server.batchScript = [{ acceptAll($0) }]
        await repository.syncNow()
        try check(harness.server.sentBatches.count == 3 && Set(harness.server.sentBatches[2].items.compactMap(createdTaskId)) == Set(migrated), "migration entries did not resume after Retry-After")
    }

    private static func batch413() async throws {
        allow()
        defer { restoreLegacy() }
        do {
            let (harness, repository) = try await r4Board()
            for index in 0 ..< 4 {
                _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Big \(index)"))
            }
            harness.server.batchScript = [{ _ in failure(.rejected(status: 413)) }] + Array(repeating: { acceptAll($0) }, count: 4)
            await repository.syncNow()
            let sizes = harness.server.sentBatches.map { $0.items.count }
            // 413 → 32 KiB: no room for a create next to the proof reserve, so one entry per batch;
            // three full batches double the budget back, and the last batch takes the rest.
            try check(sizes == [4, 1, 1, 1, 1], "413 did not halve and resend at once: \(sizes)")
            try check(try meta(harness, "batch_byte_budget") == "65536", "three full batches did not double the budget back")
            try check(try maxAttempts(harness) == 0, "a 413 counted attempts")
        }
        do {
            let (harness, repository) = try await r4Board()
            let user = try repository.createTask(SGTasksCloudTaskDraft(title: "Alone"))
            let migrated = try enqueueMigrationCreates(repository, count: 1)
            try harness.cloudExecute("INSERT INTO meta (key, value) VALUES ('batch_byte_budget', '1024') ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
            harness.server.batchScript = [{ _ in failure(.rejected(status: 413)) }, { _ in failure(.rejected(status: 413)) }]
            harness.server.mutationScript = [{ ack($0, revision: "1") }]
            await repository.syncNow()
            guard harness.server.sentSealed.count == 1, case let .mutation(single) = harness.server.sentSealed[0], case let .taskCreate(op) = single.operation, op.taskId == user else {
                throw CloudTestFailure.assertion("a one-entry 413 did not send the user entry alone")
            }
            try check(harness.server.sentBatches.count == 2 && harness.server.sentBatches[1].items.compactMap(createdTaskId) == migrated, "the migration create was not tried on the batch route")
            let migration = repository.state.entries.first { $0.resourceId == migrated[0].rawValue }
            try check(migration?.status == .invalid && harness.server.sentSealed.count == 1, "a one-entry migration 413 took the single route or stayed queued")
        }
    }

    private static func adaptiveBatchSize() async throws {
        allow()
        defer { restoreLegacy() }
        let description = String(repeating: "d", count: 2000)
        do {
            let ids = (0 ..< 60).map { _ in SGTasksWire.UUID.generate() }
            let (harness, repository) = try await r4Board(ids.map { task($0, rev: "1", title: "T") })
            for id in ids {
                try repository.updateTask(id: id, draft: SGTasksCloudTaskDraft(title: "T", description: description, sortOrder: 0))
            }
            harness.server.batchScript = [timeout]
            await repository.syncNow()
            let first = harness.server.sentBatches[0]
            try check(first.items.count > 20 && first.bodyBytes <= 65536 - SGTasksCloudRepository.batchEnvelopeReserve, "the first batch did not use the 64 KiB budget: \(first.items.count) items, \(first.bodyBytes) bytes")
            try check(try meta(harness, "batch_byte_budget") == "32768", "a timeout did not halve the budget")
            try check(try maxAttempts(harness) == 0 && repository.state.entries.allSatisfy { $0.status == .queued }, "a whole-batch timeout counted attempts")
            harness.clock = harness.clock.addingTimeInterval(600)
            harness.server.batchScript = Array(repeating: { acceptAll($0) }, count: 6)
            await repository.syncNow()
            let next = Array(harness.server.sentBatches.dropFirst())
            try check(next.count >= 4, "the outbox did not drain in smaller batches: \(next.map { $0.items.count })")
            for batch in next.prefix(3) {
                try check(batch.bodyBytes <= 32768 - SGTasksCloudRepository.batchEnvelopeReserve, "a batch after the timeout ignored the halved budget")
            }
            try check(next[3].items.count > next[0].items.count, "three full batches did not double the budget: \(next.map { $0.items.count })")
            try check(repository.state.entries.allSatisfy { $0.status == .awaitingSync }, "not every patch was acknowledged")
        }
        do {
            // A slow uplink: batches shrink to one entry before any attempt counts; nothing stalls.
            let ids = (0 ..< 40).map { _ in SGTasksWire.UUID.generate() }
            let (harness, repository) = try await r4Board(ids.map { task($0, rev: "1", title: "T") })
            for id in ids {
                try repository.updateTask(id: id, draft: SGTasksCloudTaskDraft(title: "T", description: description, sortOrder: 0))
            }
            for _ in 0 ..< 8 {
                harness.server.batchScript = [timeout]
                await repository.syncNow()
                harness.clock = harness.clock.addingTimeInterval(1000)
            }
            let sizes = harness.server.sentBatches.map { $0.items.count }
            try check(sizes.count == 8 && sizes.last == 1 && sizes.first! > 1, "the batch did not converge to one entry: \(sizes)")
            try check(try meta(harness, "batch_byte_budget") == String(SGTasksCloudRepository.minimumBatchByteBudget), "the budget did not reach its floor")
            try check(!repository.state.entries.contains { $0.status == .stalled } && (try maxAttempts(harness)) < Int64(SGTasksCloudRepository.maximumAutomaticAttempts), "an entry stalled because of the batch size")
        }
    }

    // MARK: - A 422 that refuses the whole batch

    /// The resource key ("task:<uuid>") of every item of every batch the server received, in order.
    private static func batchTasks(_ harness: Harness) -> [[String]] {
        return harness.server.sentBatches.map { $0.items.map { SGTasksCloudKey.primary(of: $0.mutation) } }
    }

    /// The server validates every item while it reads a batch: a change of `task` refuses any batch
    /// that carries it with an envelope 422 (nothing runs), alone too; every other batch is accepted.
    private static func refusingBatches(with task: SGTasksWire.UUID) -> (SGTasksWire.MutationBatchRequest) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        let key = SGTasksCloudKey.task(task)
        return { request in
            request.items.contains { SGTasksCloudKey.primary(of: $0.mutation) == key } ? failure(.invalidRequest) : acceptAll(request)
        }
    }

    /// The board's status of each entry, by the task it changes.
    private static func statuses(_ repository: SGTasksCloudRepository) -> [String: SGTasksCloudEntry.Status] {
        var out: [String: SGTasksCloudEntry.Status] = [:]
        for entry in repository.state.entries {
            out[entry.resourceId] = entry.status
        }
        return out
    }

    /// A restart: nothing in flight on the repository's queue, every change notice it enqueued on
    /// main has run (each briefly re-retains it), then it is gone with its SQLite connection.
    private static func release(_ repository: inout SGTasksCloudRepository?) async throws {
        repository?.onQueue {}
        await drainMainQueue()
        let isReleased = { [weak repository] in repository == nil }
        repository = nil
        try check(isReleased(), "the repository (and its SQLite connection) outlived the restart")
    }

    /// One bad item refuses the whole batch with 422: the batch goes back to the queue with no
    /// attempt and its entries are resent one per batch, in outbox order, with the same ids and
    /// bytes; only the entry the server refuses alone ends invalid (one sync issue). Migration
    /// creates split the same way on the batch route, never the single route. Afterwards batches
    /// carry several entries again and the invalid entry is not resent.
    private static func wholeBatch422IsSplit() async throws {
        allow()
        defer { restoreLegacy() }
        do {
            let (harness, repository) = try await r4Board()
            let first = try repository.createTask(SGTasksCloudTaskDraft(title: "One"))
            let bad = try repository.createTask(SGTasksCloudTaskDraft(title: "Two"))
            let third = try repository.createTask(SGTasksCloudTaskDraft(title: "Three"))
            harness.server.batchScript = Array(repeating: refusingBatches(with: bad), count: 4)
            let events = await recordingAnalytics { await repository.syncNow() }
            let keys = [first, bad, third].map(SGTasksCloudKey.task)
            try check(batchTasks(harness) == [keys, [keys[0]], [keys[1]], [keys[2]]], "the refused batch was not resent one entry per batch: \(batchTasks(harness))")
            let bytes = harness.server.sentBatches.map { $0.items.map { $0.mutation.wireJSON } }
            try check(Array(bytes.dropFirst().joined()) == bytes[0], "the split changed an entry's id or bytes")
            try check(harness.server.sentSealed.isEmpty, "a split entry took the single route")
            let status = statuses(repository)
            try check(status[first.rawValue] == .awaitingSync && status[third.rawValue] == .awaitingSync, "an entry accepted alone was not acknowledged: \(status)")
            try check(status[bad.rawValue] == .invalid, "the entry refused alone is not invalid: \(status)")
            try check(try maxAttempts(harness) == 0, "the split counted an attempt")
            try check(events.filter { $0 == .syncIssue(kind: SGTasksAnalytics.SyncIssue.invalid) }.count == 1, "not exactly one sync issue: \(events)")
            let more = [try repository.createTask(SGTasksCloudTaskDraft(title: "Four")), try repository.createTask(SGTasksCloudTaskDraft(title: "Five"))]
            harness.server.batchScript = [{ acceptAll($0) }]
            await repository.syncNow()
            try check(batchTasks(harness).count == 5 && batchTasks(harness).last == more.map(SGTasksCloudKey.task), "batches did not carry several entries again after the split: \(batchTasks(harness))")
        }
        do {
            let (harness, repository) = try await r4Board()
            let migrated = try enqueueMigrationCreates(repository, count: 3)
            harness.server.batchScript = Array(repeating: refusingBatches(with: migrated[1]), count: 4)
            await repository.syncNow()
            let keys = migrated.map(SGTasksCloudKey.task)
            try check(batchTasks(harness) == [keys, [keys[0]], [keys[1]], [keys[2]]], "the refused migration batch was not resent one entry per batch: \(batchTasks(harness))")
            try check(harness.server.sentBatches.allSatisfy { $0.items.allSatisfy { $0.origin == .migration } } && harness.server.sentSealed.isEmpty, "a split migration create lost its origin or took the single route")
            let status = statuses(repository)
            try check(status[migrated[0].rawValue] == .awaitingSync && status[migrated[1].rawValue] == .invalid && status[migrated[2].rawValue] == .awaitingSync, "migration entries after the split: \(status)")
            try check(try maxAttempts(harness) == 0, "the migration split counted an attempt")
        }
    }

    /// Never an endless loop: when the server refuses every request (a header it refuses, say),
    /// the batch is split once, each entry is refused alone and ends invalid, and nothing is sent
    /// again. A one-entry batch's 422 is invalid at once, as before.
    private static func wholeBatch422SplitIsBounded() async throws {
        allow()
        defer { restoreLegacy() }
        do {
            let (harness, repository) = try await r4Board()
            for index in 0 ..< 3 {
                _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Refused \(index)"))
            }
            harness.server.batchScript = Array(repeating: { _ in failure(.invalidRequest) }, count: 4)
            await repository.syncNow()
            let sizes = harness.server.sentBatches.map { $0.items.count }
            try check(sizes == [3, 1, 1, 1], "each entry was not sent alone exactly once: \(sizes)")
            try check(repository.state.entries.count == 3 && repository.state.entries.allSatisfy { $0.status == .invalid } && (try maxAttempts(harness)) == 0, "entries refused alone did not end invalid, without attempts")
            harness.clock = harness.clock.addingTimeInterval(3600)
            await repository.syncNow()
            try check(harness.server.sentBatches.count == 4, "an invalid entry was sent again")
        }
        do {
            let (harness, repository) = try await r4Board()
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Alone"))
            harness.server.batchScript = [{ _ in failure(.invalidRequest) }]
            await repository.syncNow()
            try check(harness.server.sentBatches.map { $0.items.count } == [1] && repository.state.entries.map { $0.status } == [.invalid], "a one-entry batch's 422 was not invalid at once")
        }
    }

    /// The split lives in memory. Here the first entry sent alone meets a 429 (the drain stops);
    /// after a restart the batch goes out whole again, is refused, and is split once more — with
    /// no attempt counted at any point.
    private static func wholeBatch422SplitAfterRestart() async throws {
        allow()
        defer { restoreLegacy() }
        let harness = try Harness()
        harness.server.defaultServerWire = 4
        var repository: SGTasksCloudRepository? = harness.repository()
        try await harness.bootstrap(repository!)
        let ids = try ["One", "Two", "Three"].map { try repository!.createTask(SGTasksCloudTaskDraft(title: $0)) }
        harness.server.batchScript = [refusingBatches(with: ids[1]), { _ in failure(.rateLimited, retryAfter: 60) }]
        await repository!.syncNow()
        let keys = ids.map(SGTasksCloudKey.task)
        try check(batchTasks(harness) == [keys, [keys[0]]], "the refused batch was not split: \(batchTasks(harness))")
        try await release(&repository)
        let reopened = harness.repository()
        harness.clock = harness.clock.addingTimeInterval(120)
        harness.server.batchScript = Array(repeating: refusingBatches(with: ids[1]), count: 4)
        await reopened.syncNow()
        try check(batchTasks(harness) == [keys, [keys[0]], keys, [keys[0]], [keys[1]], [keys[2]]], "after a restart the batch was not refused and split once more: \(batchTasks(harness))")
        let status = statuses(reopened)
        try check(status[ids[0].rawValue] == .awaitingSync && status[ids[1].rawValue] == .invalid && status[ids[2].rawValue] == .awaitingSync, "entries after the restart: \(status)")
        try check(try maxAttempts(harness) == 0, "a refusal counted an attempt")
    }

    /// An older build marked every entry of a batch a 422 refused as a whole invalid. At the store's
    /// next open, once per store, they go back to the queue with the same ids, bytes and attempts
    /// (another terminal state is untouched; a new store is marked at its first open). The batch
    /// refused again is split, so only the entry refused alone ends invalid, and a later open
    /// repairs nothing.
    private static func batchRefusalsRepairedOnce() async throws {
        allow()
        defer { restoreLegacy() }
        let harness = try Harness()
        harness.server.defaultServerWire = 4
        var repository: SGTasksCloudRepository? = harness.repository()
        try await harness.bootstrap(repository!)
        try check(try meta(harness, "batch_refusals_repaired") == "1", "a new store was not marked at its first open")
        let first = try repository!.createTask(SGTasksCloudTaskDraft(title: "One"))
        let bad = try repository!.createTask(SGTasksCloudTaskDraft(title: "Two"))
        let third = try repository!.createTask(SGTasksCloudTaskDraft(title: "Three"))
        let kept = try repository!.createTask(SGTasksCloudTaskDraft(title: "Quarantined"))
        try await release(&repository)
        // The file as an older build left it: the three refused together, invalid after their one
        // send; another entry in a terminal state of its own; no repair mark.
        try harness.cloudExecute("""
        UPDATE outbox SET state = 'invalid', sent_once = 1 WHERE seq IN (SELECT seq FROM outbox ORDER BY seq LIMIT 3);
        UPDATE outbox SET state = 'quarantined', sent_once = 1 WHERE seq = (SELECT MAX(seq) FROM outbox);
        DELETE FROM meta WHERE key = 'batch_refusals_repaired';
        """)
        let bodies = try harness.outboxBodies()
        var reopened: SGTasksCloudRepository? = harness.repository()
        try check(try meta(harness, "batch_refusals_repaired") == "1", "the repair did not mark the store")
        var status = statuses(reopened!)
        try check([first, bad, third].allSatisfy { status[$0.rawValue] == .queued } && status[kept.rawValue] == .integrityQuarantine, "the repair did not requeue exactly the invalid entries: \(status)")
        try check(try harness.outboxBodies() == bodies && maxAttempts(harness) == 0, "the repair changed an entry's bytes or attempts")
        harness.server.batchScript = Array(repeating: refusingBatches(with: bad), count: 4)
        await reopened!.syncNow()
        let keys = [first, bad, third].map(SGTasksCloudKey.task)
        try check(batchTasks(harness) == [keys, [keys[0]], [keys[1]], [keys[2]]], "the repaired batch was not refused and split: \(batchTasks(harness))")
        try check(harness.server.sentBatches[0].items.map { $0.mutation.wireJSON } == Array(bodies.prefix(3)), "the repaired entries were not resent with their bytes")
        status = statuses(reopened!)
        try check(status[first.rawValue] == .awaitingSync && status[bad.rawValue] == .invalid && status[third.rawValue] == .awaitingSync && status[kept.rawValue] == .integrityQuarantine, "entries after the resend: \(status)")
        // Once per store: the entry refused alone stays invalid through the next open.
        try await release(&reopened)
        let again = harness.repository()
        try check(statuses(again)[bad.rawValue] == .invalid, "a later open repaired the store again")
        harness.clock = harness.clock.addingTimeInterval(3600)
        await again.syncNow()
        try check(harness.server.sentBatches.count == 4, "an entry refused alone was sent again after a later open")
    }

    // MARK: - Wire negotiation

    private static func serverWireNegotiation() async throws {
        allow()
        defer { restoreLegacy() }
        let taskId = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(taskId, rev: "2", title: "Old")])
        // A 2xx without the echo: an R3 (or rolled-back) server — edits are R3 again.
        harness.server.changesScript = [changesPage([], serverWire: nil)]
        await repository.syncNow()
        try check(try meta(harness, "server_wire") == nil, "a 2xx without the echo kept server_wire")
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "R3 edit", sortOrder: 0))
        guard case let .mutation(update)? = try sealed(harness).last, case .taskUpdate = update.operation else {
            throw CloudTestFailure.assertion("an edit without server_wire was not a task.update")
        }
        try harness.clearOutbox(repository)
        // An R4 projection proves R4 even without the echo.
        let listId = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(r4List(listId, rev: "1", title: "L", members: "2"))], serverWire: nil)]
        await repository.syncNow()
        try check(try meta(harness, "server_wire") == "4", "an R4 projection did not set server_wire")
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "R4 edit", sortOrder: 0))
        guard case .patch? = try sealed(harness).last else {
            throw CloudTestFailure.assertion("an edit with server_wire 4 was not a task.patch")
        }
        // A batch 200 proves it too; a single-route 2xx without the echo clears it.
        harness.server.batchScript = [{ request in answer(request, serverWire: nil) { _, item in receipt(item.mutation, revision: "3") } }]
        harness.server.changesScript = [changesPage([], serverWire: nil), changesPage([], serverWire: nil)]
        await repository.syncNow()
        try check(try meta(harness, "server_wire") == nil, "the pull after the batch without the echo kept server_wire")
    }

    /// wf15 §8.2 / §8.3 (WP-I1): the request wire comes from the transport seam (the build's
    /// `sg_config.tasks_wire`), and `server_wire` is the numeric echo — an echo of 5 no longer clears
    /// it (F5), so `task.patch`, the batch route and the migration entries keep working under either
    /// echo and either request wire; an echo outside 4 ... 5 or a missing one still clears it.
    private static func requestWireAndNumericEcho() async throws {
        allow()
        defer { restoreLegacy() }
        do {
            let harness = try Harness()
            try check(harness.repository().requestWire == SGTasksWire.wireRevision, "the default request wire is not 4")
            harness.server.requestWireValue = SGTasksWire.maximumWire
            try check(harness.repository().requestWire == 5, "a scripted wire-5 build was not reported")
        }
        for requestWire in [SGTasksWire.wireRevision, SGTasksWire.maximumWire] {
            for echo in [4, 5] {
                let label = "request wire \(requestWire), echo \(echo)"
                let taskId = SGTasksWire.UUID.generate()
                let harness = try Harness()
                harness.server.requestWireValue = requestWire
                harness.server.defaultServerWire = echo
                let repository = harness.repository()
                try await harness.bootstrap(repository, items: [task(taskId, rev: "2", title: "Old")])
                try check(try meta(harness, "server_wire") == String(echo), "\(label): the snapshot's echo was not recorded numerically")
                // The R4 engine stays: an edit is a task.patch, it goes through the batch route, a
                // migration-origin create drains with it, and the batch 200 with the echo keeps the value.
                try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "Edit", sortOrder: 0))
                guard case .patch? = try sealed(harness).last else {
                    throw CloudTestFailure.assertion("\(label): an edit was not a task.patch")
                }
                let migrated = try enqueueMigrationCreates(repository, count: 2)
                harness.server.batchScript = [
                    { request in answer(request, serverWire: echo) { _, item in receipt(item.mutation, revision: "3") } },
                    { request in answer(request, serverWire: echo) { _, item in receipt(item.mutation) } }
                ]
                await repository.syncNow()
                try check(harness.server.sentSealed.isEmpty && harness.server.sentBatches.count == 2, "\(label): the batch route was not used: \(harness.server.sentBatches.count) batches, \(harness.server.sentSealed.count) single")
                try check(Set(harness.server.sentBatches[1].items.compactMap(createdTaskId)) == Set(migrated), "\(label): the migration creates did not drain")
                try check(try meta(harness, "server_wire") == String(echo), "\(label): the batch answer changed the recorded echo")
                let counts = await repository.flush(timeout: 5)
                try check(counts?.user == 0 && counts?.migration == 0, "\(label): the outbox did not drain: \(String(describing: counts))")
            }
        }
        // An echo outside the wires this client knows proves nothing: cleared like a missing one; an R4
        // projection on such a page still proves wire 4; a known echo returns the exact number.
        do {
            let taskId = SGTasksWire.UUID.generate()
            let (harness, repository) = try await r4Board([task(taskId, rev: "2", title: "Old")])
            harness.server.changesScript = [changesPage([], serverWire: 6)]
            await repository.syncNow()
            try check(try meta(harness, "server_wire") == nil, "an echo of 6 kept server_wire")
            let listId = SGTasksWire.UUID.generate()
            harness.server.changesScript = [changesPage([upsert(r4List(listId, rev: "1", title: "L", members: "2"))], serverWire: 6)]
            await repository.syncNow()
            try check(try meta(harness, "server_wire") == "4", "an R4 projection under an unknown echo did not prove wire 4")
            harness.server.changesScript = [changesPage([], serverWire: 5)]
            await repository.syncNow()
            try check(try meta(harness, "server_wire") == "5", "an echo of 5 after wire 4 was not recorded")
            harness.server.changesScript = [changesPage([], serverWire: nil)]
            await repository.syncNow()
            try check(try meta(harness, "server_wire") == nil, "a 2xx without the echo kept server_wire 5")
        }
    }

    private static func downgradeReencodesOnce() async throws {
        allow()
        defer { restoreLegacy() }
        do {
            let taskId = SGTasksWire.UUID.generate()
            let (harness, repository) = try await r4Board([task(taskId, rev: "2", title: "Old", priority: 1)])
            try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "Mine", priority: 1, sortOrder: 0))
            guard case let .patch(patch)? = try sealed(harness).first else { throw CloudTestFailure.assertion("no patch was sealed") }
            // The server was rolled back to R3: no echo, no batch route, no task.patch.
            harness.server.defaultServerWire = nil
            harness.server.batchScript = [{ _ in failure(.rejected(status: 404)) }]
            harness.server.mutationScript = [{ _ in failure(.invalidRequest) }, { ack($0, revision: "3") }]
            await repository.syncNow()
            let single = harness.server.sentSealed
            guard single.count == 2, case .patch = single[0], case let .mutation(resent) = single[1], case let .taskUpdate(op) = resent.operation else {
                throw CloudTestFailure.assertion("the refused patch was not re-encoded as a task.update: \(single.map { $0.kind.rawValue })")
            }
            try check(resent.mutationId != patch.mutationId, "the re-encoded update reused the patch's id")
            try check(op.baseRevision.rawValue == "2" && op.content.title == "Mine" && op.content.priority == 1, "the update is not the server row plus the patch's set values")
            try check(repository.state.entries.map { $0.status } == [.awaitingSync], "the re-encoded update was not acknowledged")
            try check(try meta(harness, "server_wire") == nil, "the downgrade kept server_wire")
            try check(!repository.state.entries.contains { $0.status == .invalid }, "the downgrade marked the entry invalid")
        }
        do {
            let listId = SGTasksWire.UUID.generate()
            let (harness, repository) = try await r4Board([r4List(listId, rev: "3", title: "Old list", members: "7")])
            try repository.deleteList(id: listId, expectedRevision: revision("3"))
            guard case let .mutation(fenced)? = try sealed(harness).first, case let .listDelete(op) = fenced.operation, op.baseMembersRevision?.rawValue == "7" else {
                throw CloudTestFailure.assertion("the delete was not members-fenced under wire 4")
            }
            harness.server.defaultServerWire = nil
            harness.server.batchScript = [{ _ in failure(.rejected(status: 404)) }]
            harness.server.mutationScript = [{ _ in failure(.invalidRequest) }, { ack($0, revision: "4") }]
            await repository.syncNow()
            guard harness.server.sent.count == 2, case let .listDelete(resent) = harness.server.sent[1].operation else {
                throw CloudTestFailure.assertion("the fenced delete was not resent")
            }
            try check(resent.baseMembersRevision == nil && resent.baseRevision.rawValue == "3" && harness.server.sent[1].mutationId != fenced.mutationId, "the delete was not resent once without the key under a new id")
        }
    }

    // MARK: - task.patch

    private static func patchGenerationAndOverlay() async throws {
        allow()
        defer { restoreLegacy() }
        let taskId = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(taskId, rev: "2", title: "Old")])
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "New", sortOrder: 0))
        guard case let .patch(first)? = try sealed(harness).first else { throw CloudTestFailure.assertion("no patch") }
        try check(first.patch.set == [.title: .title("New")] && first.patch.expect == [.title: .title("Old")], "the patch is not the changed field against the shown value")
        let shown = repository.state
        try check(shown.tasks.first?.title == "New" && shown.tasks.first?.isPending == true, "the overlay did not apply the patch")
        try check(shown.entries.first?.kind == .taskUpdate && shown.entries.first?.mutationKind == .taskPatch, "the entry's kinds are wrong")
        // No change, no entry.
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "New", sortOrder: 0))
        try check(try harness.outboxBodies().count == 1, "an unchanged edit queued a patch")
        // A second edit expects what the first one shows.
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "Newer", priority: 2, sortOrder: 0))
        guard case let .patch(second)? = try sealed(harness).last else { throw CloudTestFailure.assertion("no second patch") }
        try check(second.patch.set == [.title: .title("Newer"), .priority: .priority(2)] && second.patch.expect == [.title: .title("New"), .priority: .priority(0)], "the second patch does not expect the first one's values")
        var revisionCounter = 2
        harness.server.batchScript = Array(repeating: { request in
            revisionCounter += 1
            return answer(request) { _, item in receipt(item.mutation, revision: String(revisionCounter)) }
        }, count: 2)
        await repository.syncNow()
        try check(harness.server.sentBatches.map { $0.items.count } == [1, 1], "chained patches did not go one after the other")
        harness.server.changesScript = [changesPage([upsert(task(taskId, rev: "4", title: "Newer", priority: 2))], serverWire: 4)]
        await repository.syncNow()
        try check(repository.state.entries.isEmpty && repository.state.tasks.first?.title == "Newer" && repository.state.tasks.first?.priority == 2, "the shadow did not retire the acknowledged patches")
    }

    // MARK: - §7.3 automatic resolution

    private static func capture() -> (events: () -> [SGTasksAnalyticsEvent], stop: () -> Void) {
        let lock = NSLock()
        var events: [SGTasksAnalyticsEvent] = []
        SGTasksAnalytics.sink = { event, _ in
            lock.lock()
            events.append(event)
            lock.unlock()
        }
        return ({
            lock.lock()
            defer { lock.unlock() }
            return events
        }, {
            SGTasksAnalytics.sink = nil
        })
    }

    private static func autoResolvePatch() async throws {
        allow()
        defer { restoreLegacy() }
        let analytics = capture()
        defer { analytics.stop() }
        let taskId = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(taskId, rev: "2", title: "Old", priority: 1)])
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "Mine", priority: 3, sortOrder: 0))
        guard case let .patch(original)? = try sealed(harness).first else { throw CloudTestFailure.assertion("no patch") }
        harness.server.batchScript = [{ request in
            answer(request) { _, _ in itemError(.conflict(.revisionChanged), status: 409, refinement: .fieldChanged(fields: [.title])) }
        }]
        await repository.syncNow()
        let conflicted = repository.state.entries.first
        try check(conflicted?.status == .conflict(.revisionChanged) && conflicted?.conflictFields == [.title], "field_changed was not recorded with its fields")
        // The next pull shows the row as it is; the untouched field is re-patched against it.
        harness.server.changesScript = [changesPage([upsert(task(taskId, rev: "3", title: "Theirs", priority: 1))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _, item in receipt(item.mutation, revision: "4") } }]
        await repository.syncNow()
        guard harness.server.sentBatches.count == 2, case let .patch(automatic) = harness.server.sentBatches[1].items[0].mutation, harness.server.sentBatches[1].items.count == 1 else {
            throw CloudTestFailure.assertion("no automatic patch was sent")
        }
        try check(automatic.patch.set == [.priority: .priority(3)] && automatic.patch.expect == [.priority: .priority(1)] && automatic.mutationId != original.mutationId, "the automatic patch is not set ∖ F against the fresh row")
        let explicit = repository.state.entries.filter { $0.status == .conflict(.revisionChanged) }
        try check(explicit.count == 1 && explicit[0].conflictFields == [.title] && explicit[0].mutationKind == .taskPatch, "the conflicting part did not stay explicit")
        try check(repository.state.resolutionNotices.map { $0.kind } == [.changedElsewhere(fields: [.title])], "no changedElsewhere notice")
        let issues = analytics.events()
        try check(issues.contains(.syncIssue(kind: "conflict_auto_resolved")) && issues.contains(.syncIssue(kind: "conflict_manual")), "the resolution emitted no sync issues: \(issues)")
        // Keep mine: the same value, expected against the server's current one.
        try repository.reapplyOnCurrentVersion(entryId: explicit[0].id)
        guard case let .patch(kept)? = try sealed(harness).last else { throw CloudTestFailure.assertion("keep mine sealed no patch") }
        try check(kept.patch.set == [.title: .title("Mine")] && kept.patch.expect == [.title: .title("Theirs")], "keep mine did not take a fresh expectation")
    }

    private static func autoResolveTaskRows() async throws {
        allow()
        defer { restoreLegacy() }
        let done = SGTasksWire.UUID.generate(), moved = SGTasksWire.UUID.generate(), kept = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(done, rev: "2", title: "Done"), task(moved, rev: "2", title: "Moved"), task(kept, rev: "2", title: "Kept")])
        try repository.setTaskCompleted(id: done, isCompleted: true)
        try repository.setTaskCompleted(id: moved, isCompleted: true)
        let undo = try repository.deleteTask(id: kept)
        undo.commit()
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.conflict(.revisionChanged), status: 409) } }]
        await repository.syncNow()
        try check(repository.state.entries.count == 3 && repository.state.entries.allSatisfy { $0.status == .conflict(.revisionChanged) }, "the three conflicts were not recorded")
        harness.server.changesScript = [changesPage([
            upsert(task(done, rev: "3", title: "Done", completed: true)),
            upsert(task(moved, rev: "3", title: "Moved elsewhere")),
            upsert(task(kept, rev: "3", title: "Kept and edited"))
        ], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _, item in receipt(item.mutation, revision: "4") } }]
        await repository.syncNow()
        // done: already completed → dropped; moved: resealed on revision 3; kept: the delete dropped.
        guard harness.server.sentBatches.count == 2, harness.server.sentBatches[1].items.count == 1, case let .mutation(resealed) = harness.server.sentBatches[1].items[0].mutation, case let .taskComplete(op) = resealed.operation else {
            throw CloudTestFailure.assertion("the complete was not resealed alone: \(harness.server.sentBatches.map { $0.items.count })")
        }
        try check(op.taskId == moved && op.baseRevision.rawValue == "3" && op.isCompleted, "the resealed complete is not on the fresh revision")
        try check(repository.state.entries.map { $0.status } == [.awaitingSync], "a resolved conflict stayed: \(repository.state.entries.map { $0.status })")
        try check(repository.state.tasks.contains { $0.id == kept && $0.title == "Kept and edited" }, "the kept task is not visible")
        try check(repository.state.resolutionNotices.map { $0.kind } == [.deleteKept], "no deleteKept notice")
        repository.dismissNotice(id: repository.state.resolutionNotices[0].id)
        try check(repository.state.resolutionNotices.isEmpty, "the notice could not be dismissed")
    }

    private static func autoResolveListRows() async throws {
        allow()
        defer { restoreLegacy() }
        let merged = SGTasksWire.UUID.generate(), clash = SGTasksWire.UUID.generate(), renamed = SGTasksWire.UUID.generate(), members = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([
            r4List(merged, rev: "2", title: "A", members: "1"),
            r4List(clash, rev: "2", title: "B", members: "1"),
            r4List(renamed, rev: "3", title: "C", members: "7"),
            r4List(members, rev: "3", title: "D", members: "2")
        ])
        try repository.updateList(id: merged, title: "A2", sortOrder: 0, expectedRevision: revision("2"))
        try repository.updateList(id: clash, title: "B-mine", sortOrder: 0, expectedRevision: revision("2"))
        try repository.deleteList(id: renamed, expectedRevision: revision("3"))
        try repository.deleteList(id: members, expectedRevision: revision("3"))
        harness.server.batchScript = [{ request in
            answer(request) { _, item in
                if case let .mutation(request) = item.mutation, case let .listDelete(op) = request.operation, op.listId == members {
                    return itemError(.conflict(.revisionChanged), status: 409, refinement: .membersChanged)
                }
                return itemError(.conflict(.revisionChanged), status: 409)
            }
        }]
        await repository.syncNow()
        try check(repository.state.entries.first { $0.resourceId == members.rawValue }?.isMembersConflict == true, "members_changed was not recorded")
        harness.server.changesScript = [changesPage([
            upsert(r4List(merged, rev: "3", title: "A", sortOrder: 5, members: "1")),
            upsert(r4List(clash, rev: "3", title: "B-theirs", members: "1")),
            upsert(r4List(renamed, rev: "4", title: "C renamed", members: "7"))
        ], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _, item in receipt(item.mutation, revision: "5") } }]
        await repository.syncNow()
        let sent = harness.server.sentBatches.count == 2 ? harness.server.sentBatches[1].items.map { $0.mutation } : []
        var mergedUpdate: SGTasksWire.ListUpdate?
        var resealedDelete: SGTasksWire.ListDelete?
        for mutation in sent {
            guard case let .mutation(request) = mutation else { continue }
            switch request.operation {
            case let .listUpdate(op): mergedUpdate = op
            case let .listDelete(op): resealedDelete = op
            default: break
            }
        }
        try check(sent.count == 2, "not exactly the merge and the reseal were sent: \(sent.map { $0.kind.rawValue })")
        try check(mergedUpdate?.listId == merged && mergedUpdate?.title == "A2" && mergedUpdate?.sortOrder == 5 && mergedUpdate?.baseRevision.rawValue == "3", "the disjoint list edits were not merged on the fresh revision")
        try check(resealedDelete?.listId == renamed && resealedDelete?.baseRevision.rawValue == "4" && resealedDelete?.baseMembersRevision?.rawValue == "7", "the delete was not resealed keeping its members fence")
        let explicit = repository.state.entries.filter { $0.status == .conflict(.revisionChanged) }.map { $0.resourceId }
        try check(Set(explicit) == [clash.rawValue, members.rawValue], "the clashing edit / members_changed did not stay explicit: \(explicit)")
    }

    private static func autoResolveBound() async throws {
        allow()
        defer { restoreLegacy() }
        let analytics = capture()
        defer { analytics.stop() }
        let taskId = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(taskId, rev: "2", title: "Busy")])
        try repository.setTaskCompleted(id: taskId, isCompleted: true)
        for round in 0 ..< 4 {
            harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.conflict(.revisionChanged), status: 409) } }]
            harness.server.changesScript = [changesPage(round == 0 ? [] : [upsert(task(taskId, rev: String(2 + round), title: "Busy \(round)"))], serverWire: 4)]
            await repository.syncNow()
        }
        try check(harness.server.sentBatches.count == 3, "the intent was sent \(harness.server.sentBatches.count) times, not 1 + 2 automatic resolutions")
        try check(repository.state.entries.map { $0.status } == [.conflict(.revisionChanged)], "the third conflict was not left explicit")
        try check(try harness.cloudScalar("SELECT auto_resolutions FROM outbox;") == 2 && harness.cloudText("SELECT auto_resolve FROM outbox;") == nil, "the bound is not recorded")
        let issues = analytics.events()
        try check(issues.filter { $0 == .syncIssue(kind: "conflict_auto_resolved") }.count == 2 && issues.filter { $0 == .syncIssue(kind: "conflict_manual") }.count == 1, "sync issues: \(issues)")
    }

    // MARK: - §7.4 automatic retry

    private static func autoRequeueBounds() async throws {
        allow()
        defer { restoreLegacy() }
        let analytics = capture()
        defer { analytics.stop() }
        let (harness, repository) = try await r4Board()
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Stalls"))
        try harness.cloudExecute("UPDATE outbox SET state = 'stalled', attempts = 8, sent_once = 1;")
        repository.requestDrive(.timer)
        try check(try harness.cloudText("SELECT state FROM outbox;") == "stalled", "a timer drive requeued a stalled entry")
        for round in 1 ... 5 {
            repository.requestDrive(round % 2 == 0 ? .foreground : .network)
            try check(try harness.cloudText("SELECT state FROM outbox;") == "queued" && harness.cloudScalar("SELECT attempts FROM outbox;") == 0, "round \(round): the stalled entry was not requeued with its attempts reset")
            try harness.cloudExecute("UPDATE outbox SET state = 'stalled', attempts = 8;")
        }
        repository.requestDrive(.foreground)
        try check(try harness.cloudText("SELECT state FROM outbox;") == "stalled" && harness.cloudScalar("SELECT auto_requeues FROM outbox;") == 5, "a sixth automatic requeue happened")
        try check(analytics.events().filter { $0 == .syncIssue(kind: "stalled") }.count == 5, "the requeues were not reported")
        try harness.clearOutbox(repository)

        // Paid mode: the migration create is exempt (200), the user create refused (403 BLOCKED).
        harness.creationAllowed = false
        let user = try repository.createTask(SGTasksCloudTaskDraft(title: "Paid only"))
        let migrated = try enqueueMigrationCreates(repository, count: 1)
        harness.server.batchScript = [
            { request in answer(request) { _, _ in itemError(.creationNotPermitted, status: 403) } },
            { acceptAll($0) }
        ]
        await repository.syncNow()
        try check(repository.state.entries.first { $0.resourceId == user.rawValue }?.status == .creationNotPermitted, "the user create was not blocked")
        try check(repository.state.entries.first { $0.resourceId == migrated[0].rawValue }?.status == .awaitingSync, "the exempt migration create was not acknowledged")
        let refusedId = harness.server.sentBatches[0].items[0].mutation.mutationId
        repository.requestDrive(.session)
        try check(repository.state.entries.first { $0.resourceId == user.rawValue }?.status == .creationNotPermitted, "a blocked create was requeued while the local gate refuses creating")
        // The policy changed: the same identity goes again.
        harness.creationAllowed = true
        repository.requestDrive(.session)
        harness.server.batchScript = [{ acceptAll($0) }]
        await repository.syncNow()
        try check(harness.server.sentBatches.last?.items.map { $0.mutation.mutationId } == [refusedId], "the requeued create did not keep its mutation id")
        try check(repository.state.entries.allSatisfy { $0.status == .awaitingSync }, "the requeued create was not acknowledged")
        try check(analytics.events().contains(.syncIssue(kind: "blocked_creation")), "the blocked requeue was not reported")
    }

    // MARK: - Session and consent

    private static func notLinkedEndsOnBindingChange() async throws {
        allow()
        defer { restoreLegacy() }
        let harness = try Harness()
        harness.server.defaultServerWire = 4
        let notice = Notification.Name("sgtasks-r4-session-\(UUID().uuidString)")
        harness.server.sessionNotice = notice
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        harness.server.changesScript = [failure(.accountNotLinked)]
        await repository.syncNow()
        try check(try repository.state.phase == .pausedNotLinked && meta(harness, "pause_binding") == "binding-1", "the not-linked pause did not record its binding")
        // The same binding (a refresh rotation): still paused.
        harness.notificationCenter.post(name: notice, object: nil)
        try check(repository.state.phase == .pausedNotLinked, "a same-binding session change ended the not-linked pause")
        // A new binding: the pause is for the old one and ends.
        harness.server.bindingMarkerValue = "binding-2"
        harness.notificationCenter.post(name: notice, object: nil)
        try check(try repository.state.phase != .pausedNotLinked && meta(harness, "pause") == nil, "a new binding did not end the not-linked pause")
        let calls = harness.server.callCount
        await repository.syncNow()
        try check(harness.server.callCount > calls, "no request after the pause ended")
    }

    private static func consentFence() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        for index in 0 ..< 3 {
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Fenced \(index)"))
        }
        let fenceNotices = NoticeLog()
        let observer = harness.notificationCenter.addObserver(forName: SGTasksCloudRepository.consentFencedNotification, object: repository, queue: nil) { notification in
            fenceNotices.append(effectiveAt: notification.userInfo?["effectiveAt"] as? String, accountPeerId: notification.userInfo?["accountPeerId"] as? Int64)
        }
        defer { harness.notificationCenter.removeObserver(observer) }
        harness.server.batchScript = [{ request in
            answer(request) { index, _ in
                index == 0 ? itemError(.rejected(status: 403), status: 403, refinement: .consentRequired(effectiveAt: "2026-10-31T10:00:00Z")) : .skipped
            }
        }]
        await repository.syncNow()
        let fencedIds = harness.server.sentBatches[0].items.map { $0.mutation.mutationId }
        try check(repository.state.phaseRefinement == .consentFenced(effectiveAt: "2026-10-31T10:00:00Z"), "no consentFenced refinement: \(String(describing: repository.state.phaseRefinement))")
        try check(repository.state.phase == .unavailable(retryAt: harness.clock.addingTimeInterval(30)), "the fence is not 30 s: \(repository.state.phase)")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE state = 'queued';") == 3 && maxAttempts(harness) == 0, "a fenced entry was discarded or counted an attempt")
        await drainMainQueue()
        let posted = fenceNotices.entries
        try check(posted.count == 1 && posted[0].effectiveAt == "2026-10-31T10:00:00Z" && posted[0].accountPeerId == 42, "the fence was not posted")
        let calls = harness.server.callCount
        repository.refresh()
        await repository.syncNow()
        try check(harness.server.callCount == calls, "a request went out inside the fence (an explicit refresh included)")
        // Consecutive fences double, up to 15 minutes.
        for delay: TimeInterval in [60, 120, 240, 480, 900, 900] {
            harness.clock = harness.clock.addingTimeInterval(1000)
            harness.server.changesScript = [failure(.rejected(status: 403), refinement: .consentRequired(effectiveAt: nil))]
            await repository.syncNow()
            try check(repository.state.phase == .unavailable(retryAt: harness.clock.addingTimeInterval(delay)), "the fence after \(delay) s is \(repository.state.phase)")
        }
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox;") == 3, "the fence discarded entries")
        // The customer layer's permission change ends the fence and its backoff.
        repository.permissionChanged()
        try check(repository.state.phaseRefinement == nil, "permissionChanged did not clear the fence")
        harness.server.batchScript = [{ acceptAll($0) }]
        await repository.syncNow()
        try check(harness.server.sentBatches.last?.items.map { $0.mutation.mutationId } == fencedIds, "the fenced entries were not resent with their ids")
        try check(repository.state.entries.allSatisfy { $0.status == .awaitingSync }, "the entries were not acknowledged after the fence")
    }

    private static func withdrawalAndRegrant() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Sent"))
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Unsent"))
        try enqueueMigrationCreates(repository, count: 3)
        let migrationBody = try harness.outboxBodies()[2]
        harness.server.batchScript = [{ request in
            answer(request, retryAfter: 60) { index, item in index == 0 ? receipt(item.mutation) : itemError(.rateLimited, status: 429, retryAfter: 60) }
        }]
        await repository.syncNow()
        var counts = await repository.flush(timeout: 5)
        try check(counts?.user == 1 && counts?.migration == 3, "unexpected fixture counts: \(String(describing: counts))")
        repository.startDriving()
        try check(repository.consentEpoch() == 0, "a fresh store has a consent epoch")
        let discarded = repository.discardAfterConsentWithdrawal()
        try check(discarded == 1, "the discard did not report the unsent USER change: \(String(describing: discarded))")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox;") == 1 && harness.cloudText("SELECT state FROM outbox;") == "acked", "a non-acknowledged row survived, or the acknowledged one went")
        try check(try repository.consentEpoch() == 1 && meta(harness, "consent_withdrawn") == "1" && !repository.onQueue({ repository.isDriven }), "the withdrawal was not recorded")
        try check(repository.state.phaseRefinement == .consentRequired(waiting: false), "a withdrawn account shows no consent hold")
        try expectError(.consentWithdrawn) { _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Refused")) }
        try expectError(.consentWithdrawn) { try enqueueMigrationCreates(repository, count: 1) }
        harness.clock = harness.clock.addingTimeInterval(120)
        let calls = harness.server.callCount
        await repository.syncNow()
        try check(harness.server.callCount == calls, "a withdrawn account sent a request")
        // A migration row left over from before (never possible through `insert`) is not resent.
        let hex = migrationBody.map { String(format: "%02x", $0) }.joined()
        try harness.cloudExecute("INSERT INTO outbox (mutation_id, kind, keys, body, sealed, state, created_at, origin) VALUES ('leftover', 'task.create', 'task:x', X'\(hex)', 1, 'queued', 0, 'migration');")
        repository.resumeAfterConsentRegrant()
        try check(try meta(harness, "consent_withdrawn") == nil && meta(harness, "needs_resnapshot") == "1", "the re-grant did not resume with a resnapshot")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE origin = 'migration';") == 0, "a leftover migration row survived the re-grant")
        // The migration step's epoch check: an epoch captured before the withdrawal is refused.
        try expectError(.consentWithdrawn) { try enqueueMigrationCreates(repository, count: 1, expectedConsentEpoch: 0) }
        try enqueueMigrationCreates(repository, count: 1, expectedConsentEpoch: 1)
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Again"))
        counts = await repository.flush(timeout: 5)
        try check(counts?.migration == 1, "inserts are not accepted after the re-grant")
    }

    // MARK: - SGEntitlement's account gate (post-gate re-check)

    /// Every analytics event while `body` runs.
    private static func recordingAnalytics(_ body: () async throws -> Void) async rethrows -> [SGTasksAnalyticsEvent] {
        let log = AnalyticsLog()
        SGTasksAnalytics.sink = { event, _ in
            log.append(event)
        }
        defer { SGTasksAnalytics.sink = nil }
        try await body()
        return log.events
    }

    private static func isError(_ event: SGTasksAnalyticsEvent) -> Bool {
        if case .error = event {
            return true
        }
        return false
    }

    /// A single-route mutation built before the withdrawal waits in SGEntitlement's account gate
    /// (behind a token rotation or a customer-data call) while the customer layer runs the
    /// withdrawal's discard. Its post-gate re-check reads the CURRENT permission: nothing is sent,
    /// the discard's outbox stays as it left it, and the refusal is no failure (no backoff, no
    /// error).
    private static func gateWaitPastWithdrawal() async throws {
        allow(.legacy)
        defer { restoreLegacy() }
        let harness = try Harness()
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Written before the withdrawal"))
        var discarded: Int?
        harness.server.whileInGate = { route in
            guard route == .mutation else { return }
            harness.server.whileInGate = nil
            discarded = repository.discardAfterConsentWithdrawal()
        }
        let events = await recordingAnalytics {
            await repository.syncNow()
        }
        try check(discarded == 1, "the discard did not run while the mutation waited in the gate")
        try check(harness.server.refusedInGate == [.mutation] && harness.server.sentSealed.isEmpty, "a mutation went out after the withdrawal: \(harness.server.sentSealed.count) sent")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox;") == 0, "the refused send recreated an outbox row")
        try check(try meta(harness, "consent_withdrawn") == "1", "the withdrawal was not kept")
        try check(try meta(harness, "not_before") == nil && repository.onQueue({ repository.pullFailures }) == 0, "the refusal backed the account off")
        try check(repository.state.phase == .idle, "the refusal changed the phase: \(repository.state.phase)")
        try check(!events.contains(where: isError), "the refusal was reported as an error: \(events)")
        try check(repository.state.phaseRefinement == .consentRequired(waiting: false), "the withdrawn account shows no consent hold")
    }

    /// The customer layer's gate drops `tasksSync` (re-consent required) while a batch waits in the
    /// account gate: nothing is sent, the entries return to the queue with the same identities and
    /// no attempt, nothing backs off and the batch budget stays. Once permitted again the SAME
    /// mutations go out.
    private static func gateWaitPastPermissionChange() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "First"))
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Second"))
        let queued = try sealed(harness).map { $0.mutationId.rawValue }
        let budget = try meta(harness, "batch_byte_budget")
        let streak = try meta(harness, "batch_success_streak")
        harness.server.whileInGate = { route in
            guard route == .batch else { return }
            harness.server.whileInGate = nil
            allow(.waiting)
        }
        let events = await recordingAnalytics {
            await repository.syncNow()
        }
        try check(harness.server.refusedInGate == [.batch] && harness.server.sentBatches.isEmpty && harness.server.sentSealed.isEmpty, "a batch went out after the permission changed")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE state = 'queued' AND attempts = 0 AND next_attempt_at IS NULL;") == 2, "the refused entries did not return to the queue unattempted")
        try check(try meta(harness, "not_before") == nil && repository.onQueue({ repository.pullFailures }) == 0, "the refusal backed the account off")
        try check(try meta(harness, "batch_byte_budget") == budget && meta(harness, "batch_success_streak") == streak, "the refusal changed the batch budget")
        try check(!events.contains(where: isError), "the refusal was reported as an error: \(events)")
        try check(repository.state.phaseRefinement == .consentRequired(waiting: true), "the consent hold is not shown")
        allow()
        repository.permissionChanged()
        harness.server.batchScript = [{ acceptAll($0) }]
        await repository.syncNow()
        let sent = harness.server.sentBatches.flatMap { $0.items.map { $0.mutation.mutationId.rawValue } }
        try check(sent == queued, "the entries did not go out with their own identities: \(sent) vs \(queued)")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE state != 'acked';") == 0, "the resent entries were not acknowledged")
    }

    /// A snapshot page and a catch-up page that waited in the gate while the withdrawal was
    /// published: neither is fetched, no durable pause or backoff is recorded and the next
    /// permitted cycle reads as usual.
    private static func gateWaitRefusesReads() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        for route in [ScriptedServer.Route.changes, .snapshot] {
            if route == .snapshot {
                try harness.cloudExecute("INSERT OR REPLACE INTO meta (key, value) VALUES ('needs_resnapshot', '1');")
            }
            let reads = (snapshots: harness.server.snapshotCount, changes: harness.server.changesCount)
            harness.server.whileInGate = { called in
                guard called == route else { return }
                harness.server.whileInGate = nil
                allow(.forbidden)
            }
            let events = await recordingAnalytics {
                await repository.syncNow()
            }
            try check(harness.server.refusedInGate.last == route && harness.server.snapshotCount == reads.snapshots && harness.server.changesCount == reads.changes, "\(route): a page was fetched after the withdrawal")
            try check(repository.onQueue({ repository.pauseReason }) == nil && meta(harness, "not_before") == nil && repository.onQueue({ repository.pullFailures }) == 0, "\(route): the refusal paused or backed off the account")
            try check(!events.contains(where: isError), "\(route): the refusal was reported as an error: \(events)")
            allow()
            repository.permissionChanged()
            if route == .snapshot {
                harness.server.snapshotScript.append(.success(SGTasksWire.SnapshotResponse(items: [], nextCursor: nil, changesCursor: cursor("c2"), serverTime: instant(), serverWire: 4)))
            }
            await repository.syncNow()
            try check(harness.server.snapshotCount + harness.server.changesCount > reads.snapshots + reads.changes, "\(route): the next permitted cycle did not read")
            try check(repository.state.hasCompleteSnapshot, "\(route): the board lost its snapshot")
        }
    }

    /// The realtime GET and auth POST carry the repository's traffic permission as SGEntitlement's
    /// post-gate re-check, read when asked: a withdrawal published — or recorded locally — while
    /// either call waits in the gate refuses it.
    private static func realtimeCarriesPostGateCheck() async throws {
        allow()
        defer { restoreLegacy() }
        let harness = try Harness()
        let service = SGTasksRealtimeTestService()
        let scheduler = SGTasksRealtimeTestScheduler()
        harness.realtime = SGTasksCloudRealtimeEnvironment(service: service, makeScheduler: { _ in scheduler }, random: { 1.0 })
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        repository.start()
        repository.onQueue {}
        try check(service.metadataCompletions.count == 1 && service.stillWantedChecks.count == 1, "the visible board's realtime asked no metadata")
        service.metadataCompletions[0](.success(realtimeEnabled()))
        repository.onQueue {}
        guard let socket = service.lastSocket else {
            throw CloudTestFailure.assertion("no realtime socket was opened")
        }
        socket.requestAuthorization()
        repository.onQueue {}
        try check(service.authorizeCalls.count == 1 && service.stillWantedChecks.count == 2, "the socket's auth POST was not asked")
        try check(service.stillWantedChecks.allSatisfy { $0() }, "a permitted call was refused")
        allow(.forbidden)
        try check(service.stillWantedChecks.allSatisfy { !$0() }, "a published withdrawal did not refuse the waiting calls")
        allow()
        try check(service.stillWantedChecks.allSatisfy { $0() }, "the check does not read the permission when asked")
        _ = repository.discardAfterConsentWithdrawal()
        try check(service.stillWantedChecks.allSatisfy { !$0() }, "a local withdrawal did not refuse the waiting calls")
        repository.stop()
    }

    /// Account ids no other case uses: the static count reads the registry first.
    private static let countsAccount: Int64 = 4343
    private static let upgradeAccount: Int64 = 4344

    private static func unsentCountsByOrigin() async throws {
        allow()
        defer { restoreLegacy() }
        let harness = try Harness()
        let repository = harness.repository(Self.countsAccount)
        try await harness.bootstrap(repository)
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "One"))
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Two"))
        try enqueueMigrationCreates(repository, count: 3)
        let live = await repository.flush(timeout: 5)
        try check(live != nil, "the live counts are unknown")
        let savedEnvironment = SGTasksCloudRepository.environment
        defer { SGTasksCloudRepository.environment = savedEnvironment }
        SGTasksCloudRepository.environment = harness.environment
        // Not in the registry: the file is read (the scripted server answered nothing: all unsent).
        let counts = SGTasksCloudRepository.unsentChangeCounts(accountPeerId: Self.countsAccount)
        try check(counts?.user == 2 && counts?.migration == 3 && SGTasksCloudRepository.unsentChangeCount(accountPeerId: Self.countsAccount) == 2, "unsent counts: \(String(describing: counts))")
        try check(live?.user == counts?.user && live?.migration == counts?.migration, "the live and file counts differ")
        try check(SGTasksCloudRepository.unsentChangeCounts(accountPeerId: 4345)?.user == 0, "an account without a store is not zero")
    }

    private static func storeUpgradeFromR3() async throws {
        allow()
        defer { restoreLegacy() }
        let harness = try Harness()
        let account = Self.upgradeAccount
        var repository: SGTasksCloudRepository? = harness.repository(account)
        try await harness.bootstrap(repository!)
        _ = try repository!.createTask(SGTasksCloudTaskDraft(title: "Before R4"))
        // The R3 build closed the file: assert it, not assume it. Quiesce first, as the restart cases
        // do: nothing in flight on its queue, and every change notice it enqueued on main (each
        // briefly re-retains it to post) has run; else its WAL connection may close late, racing the
        // raw write below (SQLITE_BUSY).
        repository!.onQueue {}
        await drainMainQueue()
        let isReleased = { [weak repository] in repository == nil }
        repository = nil
        try check(isReleased(), "the R3 build's repository (and its SQLite connection) outlived the restart")
        // The file as an R3 build left it: schema 2, no R4 column.
        try harness.cloudExecute("""
        ALTER TABLE outbox DROP COLUMN origin; ALTER TABLE outbox DROP COLUMN auto_requeues;
        ALTER TABLE outbox DROP COLUMN auto_resolutions; ALTER TABLE outbox DROP COLUMN auto_resolve;
        ALTER TABLE outbox DROP COLUMN conflict_fields; ALTER TABLE outbox DROP COLUMN base_snapshot;
        ALTER TABLE notices DROP COLUMN fields; DELETE FROM meta WHERE key = 'needs_resnapshot';
        PRAGMA user_version = 2;
        """, accountPeerId: account)
        let savedEnvironment = SGTasksCloudRepository.environment
        SGTasksCloudRepository.environment = harness.environment
        let r3Counts = SGTasksCloudRepository.unsentChangeCounts(accountPeerId: account)
        SGTasksCloudRepository.environment = savedEnvironment
        try check(r3Counts?.user == 1 && r3Counts?.migration == 0, "an R3 store's rows are not all user changes: \(String(describing: r3Counts))")
        let reopened = harness.repository(account)
        try check(try harness.cloudScalar("PRAGMA user_version;", accountPeerId: account) == 3, "the store was not upgraded to schema 3")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM pragma_table_info('outbox') WHERE name IN ('origin', 'auto_requeues', 'auto_resolutions', 'auto_resolve', 'conflict_fields', 'base_snapshot');", accountPeerId: account) == 6, "an R4 column is missing")
        try check(try harness.cloudText("SELECT value FROM meta WHERE key = 'needs_resnapshot';", accountPeerId: account) == "1", "the upgrade did not ask for a resnapshot")
        try check(try harness.cloudText("SELECT origin FROM outbox;", accountPeerId: account) == "user" && reopened.state.entries.map { $0.status } == [.queued], "the R3 row did not survive as a queued user change")
    }

    private static func resyncGeneration() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        try check(try meta(harness, "resync_generation") == nil, "a fresh store has a resync generation")
        // A rejected cursor (catch-up) …
        harness.server.changesScript = [failure(.resyncRequired)]
        await repository.syncNow()
        try check(try meta(harness, "resync_generation") == "1" && meta(harness, "needs_resnapshot") == "1", "a catch-up resync did not count")
        // … and a mutation answered 409 resync.
        harness.clock = harness.clock.addingTimeInterval(1000)
        harness.server.snapshotScript = [.success(SGTasksWire.SnapshotResponse(items: [], nextCursor: nil, changesCursor: cursor("c2"), serverTime: instant(), serverWire: 4))]
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Resynced"))
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.resyncRequired, status: 409) } }]
        await repository.syncNow()
        try check(try meta(harness, "resync_generation") == "2" && meta(harness, "needs_resnapshot") == "1", "a mutation resync did not count")
    }

    // MARK: - Driver and flush

    private static func flushAndContinuation() async throws {
        allow()
        defer { restoreLegacy() }
        // A chain of completes on one task: exactly one entry is eligible per batch.
        func chained(_ count: Int) async throws -> (Harness, SGTasksCloudRepository) {
            let taskId = SGTasksWire.UUID.generate()
            let (harness, repository) = try await r4Board([task(taskId, rev: "1", title: "Toggled")])
            for index in 0 ..< count {
                try repository.setTaskCompleted(id: taskId, isCompleted: index % 2 == 0)
            }
            var revisionCounter = 1
            harness.server.batchScript = Array(repeating: { request in
                revisionCounter += 1
                return answer(request) { _, item in receipt(item.mutation, revision: String(revisionCounter)) }
            }, count: count)
            return (harness, repository)
        }
        do {
            let (harness, repository) = try await chained(12)
            let counts = await repository.flush(timeout: 10)
            try check(harness.server.sentBatches.count == SGTasksCloudRepository.maximumBatchesPerCycle && counts?.user == 2, "an undriven flush is not one cycle of 10 batches: \(harness.server.sentBatches.count), \(String(describing: counts))")
        }
        do {
            let (harness, repository) = try await chained(12)
            repository.startDriving()
            let counts = await repository.flush(timeout: 10)
            try check(harness.server.sentBatches.count == 12 && counts?.user == 0, "a driven repository did not continue: \(harness.server.sentBatches.count), \(String(describing: counts))")
            repository.stopDriving()
        }
        do {
            allow(.forbidden)
            let harness = try Harness()
            let repository = harness.repository()
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Held"))
            let counts = await repository.flush(timeout: 1)
            try check(harness.server.callCount == 0 && counts?.user == 1, "a forbidden flush sent something")
        }
    }

    // MARK: - Analytics seam

    private static func analyticsSink() async throws {
        allow()
        defer { restoreLegacy() }
        let lock = NSLock()
        var received: [(SGTasksAnalyticsEvent, Int64?)] = []
        SGTasksAnalytics.sink = { event, account in
            lock.lock()
            received.append((event, account))
            lock.unlock()
        }
        defer { SGTasksAnalytics.sink = nil }
        let existing = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(existing, rev: "2", title: "Existing")])
        let listId = try repository.createList(title: "Ishlar")
        _ = try repository.createTask(SGTasksCloudTaskDraft(listId: listId, title: "Hisobot", dueAt: 1_900_000_000, priority: 2))
        try repository.setTaskCompleted(id: existing, isCompleted: true)
        try repository.setTaskCompleted(id: existing, isCompleted: false)
        let undo = try repository.deleteTask(id: existing)
        try check(!received.contains { $0.0 == .taskDeleted(cloud: true) }, "a delete inside its Undo window was reported")
        undo.commit()
        try repository.deleteList(id: listId, expectedRevision: nil)
        // Migration creates are never user events.
        try enqueueMigrationCreates(repository, count: 2)
        let local: [SGTasksAnalyticsEvent] = [
            .listCreated(cloud: true),
            .taskCreated(cloud: true, hasDue: true, priority: 2, inList: true),
            .taskCompleted(cloud: true, reopened: false),
            .taskCompleted(cloud: true, reopened: true),
            .taskDeleted(cloud: true),
            .listDeleted(cloud: true, tasks: 1)
        ]
        try check(received.map { $0.0 } == local && received.allSatisfy { $0.1 == 42 }, "local commits: \(received.map { $0.0 })")
        // A refused item (terminal 422) and a failed cycle (timeout).
        received.removeAll()
        harness.server.batchScript = [
            { request in answer(request) { index, item in index == 0 ? itemError(.invalidRequest, status: 422) : receipt(item.mutation) } },
            timeout
        ]
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Next"))
        await repository.syncNow()
        try check(received.map { $0.0 }.contains(.syncIssue(kind: "invalid")), "a terminal 422 was not reported: \(received.map { $0.0 })")
        try check(received.map { $0.0 }.contains(.error(domain: "tasks_sync", code: "timeout")), "the failed cycle was not reported: \(received.map { $0.0 })")
    }

    // MARK: - wf15 I4a: the assignment engine (owner side)

    private static let deferralAccount: Int64 = 4346

    /// An owner task of the shadow with the given assignment.
    private static func assigned(_ id: SGTasksWire.UUID, rev: String, title: String, invitation: SGTasksWire.UUID, recipient: SGTasksWire.TelegramId, state: SGTasksWire.AssignmentState, completed: Bool = false, annotation: SGTasksWire.Annotation? = nil) -> SGTasksWire.Projection {
        let content = SGTasksWire.Content(listId: nil, title: title, description: nil, dueAt: nil, priority: 0, sortOrder: 0, annotation: annotation)
        let assignment = SGTasksWire.Assignment(invitationId: invitation, recipientTgId: recipient, state: state, expiresAt: instant(7 * 86400))
        return .task(SGTasksWire.Task(id: id, revision: revision(rev), ownerTgId: ownTg, viewerRole: .owner, content: content, isCompleted: completed, completedAt: completed ? instant() : nil, createdAt: instant(), updatedAt: instant(), assignment: assignment))
    }

    private static func inviteRequest(_ mutation: SGTasksWire.SealedMutation) -> SGTasksWire.InviteRequest? {
        if case let .mutation(request) = mutation, case let .inviteRequest(op) = request.operation {
            return op
        }
        return nil
    }

    /// The `invitation.request` items of every batch, in send order.
    private static func sentInvites(_ harness: Harness) -> [(mutationId: String, request: SGTasksWire.InviteRequest)] {
        return harness.server.sentBatches.flatMap { $0.items }.compactMap { item in
            inviteRequest(item.mutation).map { (item.mutation.mutationId.rawValue, $0) }
        }
    }

    /// The deferral meta row of a task, decoded; nil when absent.
    private static func deferral(_ harness: Harness, _ taskId: SGTasksWire.UUID, account: Int64 = 42) throws -> (to: String, after: Double)? {
        guard let raw = try harness.cloudText("SELECT value FROM meta WHERE key = 'assign_deferred.\(taskId.rawValue)';", accountPeerId: account),
              let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let to = object["to"] as? String, let after = (object["after"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return (to, after)
    }

    private static func invitationPacerTable() async throws {
        typealias Counts = SGTasksInvitationPacer.Counts
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 4, today: 94, thisMinute: 9, pending: 94)) == nil, "the last allowed pick was refused")
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 5, today: 0, thisMinute: 0, pending: 0)) == .perPerson, "the 6th pick to one person was allowed")
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 0, today: 0, thisMinute: 10, pending: 0)) == .perMinute, "the 11th pick in a minute was allowed")
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 0, today: 95, thisMinute: 0, pending: 0)) == .total, "the 96th pick of the day was allowed")
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 0, today: 0, thisMinute: 0, pending: 95)) == .pending, "a pick with 95 pending was allowed")
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 5, today: 95, thisMinute: 10, pending: 95)) == .perPerson, "the refusals are not ordered per person, per minute, total, pending")
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 0, today: 95, thisMinute: 10, pending: 95)) == .perMinute, "per minute does not come before total")
        try check(SGTasksInvitationPacer.refusal(Counts(recipientToday: 0, today: 95, thisMinute: 0, pending: 95)) == .total, "total does not come before pending")
        // Keys: UTC days and epoch minutes (baseTime is 2027-01-15T08:00:00Z).
        let now = Date(timeIntervalSince1970: baseTime)
        try check(SGTasksInvitationPacer.dayKey(now) == "20270115", "the UTC day key: \(SGTasksInvitationPacer.dayKey(now))")
        try check(SGTasksInvitationPacer.dayKey(now.addingTimeInterval(-8 * 3600 - 1)) == "20270114", "the UTC day boundary")
        try check(SGTasksInvitationPacer.minuteKey(now) == 30_000_000 && SGTasksInvitationPacer.minuteKey(now.addingTimeInterval(59)) == 30_000_000 && SGTasksInvitationPacer.minuteKey(now.addingTimeInterval(60)) == 30_000_001, "the epoch minute")
        try check(SGTasksInvitationPacer.recipientCounterKey(day: "20270115", recipient: otherTg) == "invite_day.20270115.987654321" && SGTasksInvitationPacer.dayCounterKey(day: "20270115") == "invite_day.20270115" && SGTasksInvitationPacer.minuteCounterKey(minute: 30_000_000) == "invite_minute.30000000", "the counter keys")
        // Expiry: today's and yesterday's counters stay, older ones go; minutes older than two days go.
        try check(!SGTasksInvitationPacer.isExpired(counterKey: "invite_day.20270115", now: now) && !SGTasksInvitationPacer.isExpired(counterKey: "invite_day.20270114.987654321", now: now), "a live day counter was expired")
        try check(SGTasksInvitationPacer.isExpired(counterKey: "invite_day.20270113", now: now) && SGTasksInvitationPacer.isExpired(counterKey: "invite_day.20270113.987654321", now: now), "an old day counter was kept")
        try check(!SGTasksInvitationPacer.isExpired(counterKey: "invite_minute.\(30_000_000 - 2880)", now: now) && SGTasksInvitationPacer.isExpired(counterKey: "invite_minute.\(30_000_000 - 2881)", now: now), "the minute counter lifetime")
        try check(!SGTasksInvitationPacer.isExpired(counterKey: "invite_day.garbage", now: now) && !SGTasksInvitationPacer.isExpired(counterKey: "server_wire", now: now), "an unknown key was expired")
        // The D4 allowance (§7.3): per recipient 5 − sent today, in all 95 − sent today, pending < 95.
        let a = SGTasksWire.TelegramId("111")!, b = SGTasksWire.TelegramId("222")!
        let candidates: [(id: Int, recipient: SGTasksWire.TelegramId)] = (0 ..< 8).map { ($0, $0 < 6 ? a : b) }
        let perRecipient = SGTasksInvitationPacer.allowance(candidates: candidates, recipientToday: { $0 == a ? 2 : 0 }, today: 2, pending: 0)
        try check(perRecipient == [0, 1, 2, 6, 7], "the per-recipient allowance: \(perRecipient)")
        try check(SGTasksInvitationPacer.allowance(candidates: candidates, recipientToday: { _ in 0 }, today: 93, pending: 0) == [0, 1], "the day allowance")
        try check(SGTasksInvitationPacer.allowance(candidates: candidates, recipientToday: { _ in 0 }, today: 0, pending: 94) == [0], "the pending allowance")
        try check(SGTasksInvitationPacer.allowance(candidates: candidates, recipientToday: { _ in 0 }, today: 95, pending: 0).isEmpty, "a spent day still allowed a send")
        try check(SGTasksInvitationPacer.spacedDate(index: 0, sentThisMinute: 0, now: now) == now && SGTasksInvitationPacer.spacedDate(index: 9, sentThisMinute: 0, now: now) == now && SGTasksInvitationPacer.spacedDate(index: 10, sentThisMinute: 0, now: now) == now.addingTimeInterval(60) && SGTasksInvitationPacer.spacedDate(index: 7, sentThisMinute: 3, now: now) == now.addingTimeInterval(60) && SGTasksInvitationPacer.spacedDate(index: 25, sentThisMinute: 0, now: now) == now.addingTimeInterval(120), "the ten-per-minute spacing")
    }

    private static func assignTaskSyncedAndUnsynced() async throws {
        allow()
        defer { restoreLegacy() }
        let synced = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(synced, rev: "2", title: "Synced")])
        try repository.assignTask(id: synced, recipientCloudUserPeerId: 987654321)
        let unsynced = try repository.createTask(SGTasksCloudTaskDraft(title: "Unsynced"))
        try repository.assignTask(id: unsynced, recipientCloudUserPeerId: 987654321)
        let queued = try sealed(harness)
        guard queued.count == 3, let syncedInvite = inviteRequest(queued[0]), let unsyncedInvite = inviteRequest(queued[2]) else {
            throw CloudTestFailure.assertion("the outbox is not invite, create, invite: \(queued.map { $0.kind })")
        }
        try check(syncedInvite.baseRevision.rawValue == "2" && syncedInvite.recipientTgId == otherTg, "the synced task's invite is not sealed on the shadow revision")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE sealed = 0;") == 1, "the unsynced task's invite is not waiting unsealed")
        let board = repository.state
        try check(board.tasks.first { $0.id == synced }?.assignment?.state == .pending && board.tasks.first { $0.id == unsynced }?.assignment?.recipientTgId == otherTg, "the overlay does not show both pending assignments")
        try check(board.entries.map { $0.status } == [.queued, .queued, .queued], "an invite waits as a problem: \(board.entries.map { $0.status })")
        // Batch 1: the synced invite and the create (chain-free); batch 2: the chained invite, sealed
        // from the create's receipt, with the epoch it was given at pick time.
        harness.server.batchScript = [
            { request in answer(request) { _, item in receipt(item.mutation, revision: "3") } },
            { request in answer(request) { _, item in receipt(item.mutation, revision: "4") } }
        ]
        await repository.syncNow()
        try check(harness.server.sentBatches.count == 2 && harness.server.sentBatches[0].items.count == 2 && harness.server.sentBatches[1].items.count == 1, "the chain did not drain as two batches: \(harness.server.sentBatches.map { $0.items.count })")
        guard let chained = inviteRequest(harness.server.sentBatches[1].items[0].mutation) else { throw CloudTestFailure.assertion("the second batch is not the chained invite") }
        try check(chained.taskId == unsynced && chained.baseRevision.rawValue == "3" && chained.invitationId == unsyncedInvite.invitationId, "the chained invite was not sealed from the create's receipt with its own epoch")
        try check(harness.server.sentBatches[0].items.allSatisfy { item in
            if case let .mutation(request) = item.mutation, case let .taskCreate(create) = request.operation { return create.content.annotation == nil }
            return true
        }, "the create carried an annotation")
        // Qayta yuborish: only an ended assignment, to the same recipient, as a new epoch.
        let ended = SGTasksWire.UUID.generate(), epoch = SGTasksWire.UUID.generate()
        harness.server.changesScript = [changesPage([upsert(assigned(ended, rev: "5", title: "Ended", invitation: epoch, recipient: otherTg, state: .declined))], serverWire: 4)]
        await repository.syncNow()
        try expectError(.actionNotAllowed) { try repository.resendAssignment(taskId: synced) }
        try repository.resendAssignment(taskId: ended)
        guard let resend = try sealed(harness).last.flatMap(inviteRequest) else { throw CloudTestFailure.assertion("Qayta yuborish queued no invite") }
        try check(resend.taskId == ended && resend.recipientTgId == otherTg && resend.invitationId != epoch && resend.baseRevision.rawValue == "5", "Qayta yuborish is not a new epoch to the same recipient on the shadow revision")
        try expectError(.actionNotAllowed) { try repository.resendAssignment(taskId: ended) }
    }

    private static func blockedCreateHoldsInvite() async throws {
        allow()
        defer { restoreLegacy() }
        let (harness, repository) = try await r4Board()
        let id = try repository.createTask(SGTasksCloudTaskDraft(title: "Gated"), assignee: 987654321)
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.creationNotPermitted, status: 403) } }]
        await repository.syncNow()
        try check(harness.server.sentBatches.count == 1 && harness.server.sentBatches[0].items.count == 1, "the invite went out with or before its refused create: \(harness.server.sentBatches.map { $0.items.count })")
        let statuses = repository.state.entries.map { $0.status }
        try check(statuses == [.creationNotPermitted, .waitingForDependency], "the invite does not wait behind the blocked create: \(statuses)")
        try check(repository.state.tasks.first { $0.id == id }?.assignment?.state == .pending, "the blocked task lost its pending assignment")
        try repository.discard(entryId: repository.state.entries[0].id)
        try check(repository.state.entries.isEmpty && !repository.state.tasks.contains { $0.id == id }, "discarding the create left the invite or the task behind")
        await repository.syncNow()
        try check(harness.server.sentBatches.count == 1, "something was sent after the discard")
    }

    private static func pickTimeRefusals() async throws {
        allow()
        defer { restoreLegacy() }
        let completed = SGTasksWire.UUID.generate()
        var items: [SGTasksWire.Projection] = [task(completed, rev: "1", title: "Done", completed: true)]
        var open: [SGTasksWire.UUID] = []
        for index in 0 ..< 14 {
            let id = SGTasksWire.UUID.generate()
            open.append(id)
            items.append(task(id, rev: "1", title: "Open \(index)"))
        }
        let (harness, repository) = try await r4Board(items)
        try expectError(.selfAssignment) { try repository.assignTask(id: open[0], recipientCloudUserPeerId: 123456789) }
        try expectError(.recipientNotConvertible) { try repository.assignTask(id: open[0], recipientCloudUserPeerId: 8_589_934_597) }
        try expectError(.taskCompleted) { try repository.assignTask(id: completed, recipientCloudUserPeerId: 987654321) }
        try check(repository.state.entries.isEmpty, "a refused pick queued something")
        // Per person: five picks a day, the sixth refused (the pre-check too); charged at enqueue.
        let day = SGTasksInvitationPacer.dayKey(harness.clock)
        let minute = SGTasksInvitationPacer.minuteKey(harness.clock)
        for index in 0 ..< 5 {
            try repository.assignTask(id: open[index], recipientCloudUserPeerId: 987654321)
        }
        try expectError(.assignmentLimit(.perPerson)) { try repository.assignTask(id: open[5], recipientCloudUserPeerId: 987654321) }
        try expectError(.assignmentLimit(.perPerson)) { try repository.checkAssignment(recipientCloudUserPeerId: 987654321) }
        try check(try meta(harness, "invite_day.\(day).987654321") == "5" && meta(harness, "invite_day.\(day)") == "5" && meta(harness, "invite_minute.\(minute)") == "5", "the counters were not charged at enqueue")
        try check(repository.state.entries.count == 5, "the refused sixth pick queued something")
        // Per minute: picks 6 … 10 of this minute go (other people); the 11th waits a minute.
        for index in 5 ..< 10 {
            try repository.assignTask(id: open[index], recipient: SGTasksWire.TelegramId(int64: Int64(1000 + index))!)
        }
        try expectError(.assignmentLimit(.perMinute)) { try repository.assignTask(id: open[10], recipient: SGTasksWire.TelegramId(int64: 2000)!) }
        try check(try meta(harness, "invite_minute.\(minute)") == "10" && repository.state.entries.count == 10, "the per-minute refusal queued something or miscounted")
        harness.clock = harness.clock.addingTimeInterval(61)
        try repository.assignTask(id: open[10], recipient: SGTasksWire.TelegramId(int64: 2000)!)
        try check(try meta(harness, "invite_minute.\(minute + 1)") == "1" && meta(harness, "invite_day.\(day)") == "11", "the next minute's counter or the day counter is wrong")
        // Total: 95 of the day → refused.
        try harness.cloudExecute("UPDATE meta SET value = '95' WHERE key = 'invite_day.\(day)';")
        try expectError(.assignmentLimit(.total)) { try repository.assignTask(id: open[11], recipient: SGTasksWire.TelegramId(int64: 3000)!) }
        try harness.cloudExecute("UPDATE meta SET value = '11' WHERE key = 'invite_day.\(day)';")
        // Purge: counters older than two UTC days go at the next pick; yesterday's stay.
        let yesterday = SGTasksInvitationPacer.dayKey(harness.clock.addingTimeInterval(-86400))
        try harness.cloudExecute("INSERT INTO meta (key, value) VALUES ('invite_day.20200101', '3'), ('invite_day.20200101.5', '1'), ('invite_minute.1', '1'), ('invite_day.\(yesterday)', '2');")
        try repository.assignTask(id: open[11], recipient: SGTasksWire.TelegramId(int64: 3000)!)
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key IN ('invite_day.20200101', 'invite_day.20200101.5', 'invite_minute.1');") == 0, "old counters were not purged")
        try check(try meta(harness, "invite_day.\(yesterday)") == "2" && meta(harness, "invite_day.\(day)") == "12", "yesterday's counter was purged or today's not charged")
        // Pending: 95 unexpired pending assignments on the shadow → refused; an expired one does not count.
        var pending: [SGTasksWire.Change] = []
        for index in 0 ..< 94 {
            pending.append(upsert(assigned(SGTasksWire.UUID.generate(), rev: "1", title: "Pending \(index)", invitation: SGTasksWire.UUID.generate(), recipient: SGTasksWire.TelegramId(int64: Int64(5000 + index))!, state: .pending), at: "\(10 + index)"))
        }
        let expiredAssignment = SGTasksWire.Assignment(invitationId: SGTasksWire.UUID.generate(), recipientTgId: SGTasksWire.TelegramId(int64: 7000)!, state: .pending, expiresAt: instant(-1))
        pending.append(upsert(.task(SGTasksWire.Task(id: SGTasksWire.UUID.generate(), revision: revision("1"), ownerTgId: ownTg, viewerRole: .owner, content: content("Expired"), isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: expiredAssignment)), at: "200"))
        harness.server.changesScript = [changesPage(pending, serverWire: 4)]
        // Receipts on revision 2: the shadow (revision 1) does not prove them yet, so the 12 acknowledged
        // invites stay applied as pending assignments.
        harness.server.batchScript = [{ request in answer(request) { _, item in receipt(item.mutation, revision: "2") } }, { request in answer(request) { _, item in receipt(item.mutation, revision: "2") } }]
        await repository.syncNow()
        // 94 pending on the shadow + the 12 acknowledged (unproven) invites = 106 ≥ 95.
        try check(repository.state.entries.count == 12 && repository.state.entries.allSatisfy { $0.status == .awaitingSync }, "the invites were not acknowledged: \(repository.state.entries.map { $0.status })")
        try expectError(.assignmentLimit(.pending)) { try repository.assignTask(id: open[12], recipient: SGTasksWire.TelegramId(int64: 3001)!) }
        try harness.cloudExecute("DELETE FROM outbox;")
        repository.onQueue { repository.rebuildState() }
        // 94 pending (the expired one excluded) → one more is allowed, then the 95th pending refuses.
        try repository.assignTask(id: open[12], recipient: SGTasksWire.TelegramId(int64: 3001)!)
        try expectError(.assignmentLimit(.pending)) { try repository.assignTask(id: open[13], recipient: SGTasksWire.TelegramId(int64: 3002)!) }
    }

    private static func longRateLimitDefersAssignment() async throws {
        defer { restoreLegacy() }
        // Single route (the R3 engine): A's invite is rate-limited for a day, B's invite and C's edit
        // go out in the same drain, nothing gates the account.
        do {
            allow(.legacy)
            let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate(), c = SGTasksWire.UUID.generate()
            let harness = try Harness()
            let repository = harness.repository(deferralAccount)
            try await harness.bootstrap(repository, items: [task(a, rev: "1", title: "A"), task(b, rev: "1", title: "B"), task(c, rev: "1", title: "C")])
            try repository.assignTask(id: a, recipientCloudUserPeerId: 987654321)
            try repository.assignTask(id: b, recipient: SGTasksWire.TelegramId(int64: 1001)!)
            try repository.updateTask(id: c, draft: SGTasksCloudTaskDraft(title: "C edited", sortOrder: 0))
            let day = SGTasksInvitationPacer.dayKey(harness.clock)
            harness.server.mutationScript = [{ _ in failure(.rateLimited, retryAfter: 86400) }, { ack($0, revision: "2") }, { ack($0, revision: "2") }]
            await repository.syncNow()
            try check(harness.server.sent.count == 3 && harness.server.sent.map { $0.operation.kind } == [.inviteRequest, .inviteRequest, .taskUpdate], "the drain stopped at the rate-limited invite: \(harness.server.sent.map { $0.operation.kind })")
            try check(repository.state.phase == .idle && meta(harness, "not_before", account: deferralAccount) == nil, "a long 429 on an invite gated the account: \(repository.state.phase)")
            let deferred = repository.state.deferredAssignments
            try check(deferred == [SGTasksCloudDeferredAssignment(taskId: a, recipientTgId: otherTg, after: harness.clock.addingTimeInterval(86400))], "the deferral is not published: \(deferred)")
            try check(try deferral(harness, a, account: deferralAccount)?.to == otherTg.rawValue && deferral(harness, a, account: deferralAccount)?.after == baseTime + 86400, "the deferral meta is not {to, after}")
            try check(repository.state.entries.map { $0.status } == [.awaitingSync, .awaitingSync] && repository.state.tasks.first { $0.id == a }?.assignment == nil, "the deferred invite stayed in the outbox")
            // An unsent change while it waits: the live counts, the file counts and the logout paragraph.
            let live = await repository.flush(timeout: 5)
            try check(live?.user == 1 && live?.migration == 0, "the deferral is not counted live: \(String(describing: live))")
            try check(TasksLogoutNotice(counts: live, unsentAssignees: 0) == .details(unsent: 1, migrationPending: false, unsentAssignees: 0), "the logout paragraph does not name the deferral")
            let savedEnvironment = SGTasksCloudRepository.environment
            SGTasksCloudRepository.environment = harness.environment
            let fromFile = SGTasksCloudRepository.unsentChangeCounts(accountPeerId: deferralAccount)
            SGTasksCloudRepository.environment = savedEnvironment
            try check(fromFile?.user == 1 && fromFile?.migration == 0, "the file read does not count the deferral: \(String(describing: fromFile))")
            // Not yet due: nothing is sent. Due: the same pick goes again — a new mutation id and a new
            // epoch, to the same recipient — past the pick-time refusals and without a pacer charge.
            harness.clock = harness.clock.addingTimeInterval(86399)
            await repository.syncNow()
            try check(harness.server.sent.count == 3, "the deferral was re-sent before its time")
            harness.clock = harness.clock.addingTimeInterval(2)
            let newDay = SGTasksInvitationPacer.dayKey(harness.clock)
            try harness.cloudExecute("INSERT INTO meta (key, value) VALUES ('invite_day.\(newDay).987654321', '5'), ('invite_day.\(newDay)', '95');", accountPeerId: deferralAccount)
            harness.server.mutationScript = [{ ack($0, revision: "3") }]
            await repository.syncNow()
            try check(harness.server.sent.count == 4, "the due deferral was not re-sent")
            let resent = harness.server.sent[3]
            guard case let .inviteRequest(op) = resent.operation, case let .inviteRequest(first) = harness.server.sent[0].operation else { throw CloudTestFailure.assertion("the re-send is not an invitation.request") }
            try check(op.taskId == a && op.recipientTgId == otherTg && op.invitationId != first.invitationId && resent.mutationId != harness.server.sent[0].mutationId && op.baseRevision.rawValue == "1", "the re-send is not the same pick as a new epoch: \(op)")
            try check(try meta(harness, "invite_day.\(newDay).987654321", account: deferralAccount) == "5" && meta(harness, "invite_day.\(newDay)", account: deferralAccount) == "95" && meta(harness, "invite_day.\(day)", account: deferralAccount) == "2", "the automatic re-send charged the pacer")
            try check(repository.state.deferredAssignments.isEmpty && meta(harness, "assign_resend.\(a.rawValue)", account: deferralAccount) == nil && deferral(harness, a, account: deferralAccount) == nil, "the deferral or its marker outlived the receipt")
            let after = await repository.flush(timeout: 5)
            try check(after?.user == 0 && TasksLogoutNotice(counts: after, unsentAssignees: 0) == nil, "the logout paragraph still names the sent assignment: \(String(describing: after))")
        }
        // Batch item (the R4 engine): the same, item by item; a whole-batch 429 too; a new change
        // right after goes out at once because nothing gates the account.
        do {
            allow()
            let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate()
            let (harness, repository) = try await r4Board([task(a, rev: "1", title: "A"), task(b, rev: "1", title: "B")])
            try repository.assignTask(id: a, recipientCloudUserPeerId: 987654321)
            try repository.assignTask(id: b, recipient: SGTasksWire.TelegramId(int64: 1001)!)
            harness.server.batchScript = [{ request in
                answer(request) { _, item in
                    if inviteRequest(item.mutation)?.taskId == a {
                        return itemError(.rateLimited, status: 429, retryAfter: 86400)
                    }
                    return receipt(item.mutation, revision: "2")
                }
            }]
            await repository.syncNow()
            try check(repository.state.deferredAssignments.map { $0.taskId } == [a] && repository.state.entries.map { $0.status } == [.awaitingSync], "the batch item 429 did not defer A alone: \(repository.state.entries.map { $0.status })")
            try check(repository.state.phase == .idle && meta(harness, "not_before") == nil, "a batch item's long 429 gated the account")
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Right after"))
            harness.server.batchScript = [{ acceptAll($0) }]
            await repository.syncNow()
            try check(harness.server.sentBatches.count == 2 && harness.server.sentBatches[1].items.count == 1, "a change right after the deferral did not go out at once")
            // A whole-batch 429 with a long Retry-After: every invite item of it is deferred.
            let c = SGTasksWire.UUID.generate(), d = SGTasksWire.UUID.generate()
            harness.server.changesScript = [changesPage([upsert(task(c, rev: "1", title: "C")), upsert(task(d, rev: "1", title: "D"))], serverWire: 4)]
            await repository.syncNow()
            try repository.assignTask(id: c, recipient: SGTasksWire.TelegramId(int64: 1002)!)
            try repository.assignTask(id: d, recipient: SGTasksWire.TelegramId(int64: 1003)!)
            harness.server.batchScript = [{ _ in failure(.rateLimited, retryAfter: 86400) }]
            await repository.syncNow()
            try check(Set(repository.state.deferredAssignments.map { $0.taskId }) == [a, c, d] && repository.state.phase == .idle && meta(harness, "not_before") == nil, "a whole-batch long 429 did not defer its invites without a gate: \(repository.state.deferredAssignments.map { $0.taskId })")
            let counts = await repository.flush(timeout: 5)
            try check(counts?.user == 3, "three deferrals are not three unsent changes: \(String(describing: counts))")
        }
    }

    private static func deferralCancelAndRedefer() async throws {
        allow()
        defer { restoreLegacy() }
        let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate(), c = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([task(a, rev: "1", title: "A"), task(b, rev: "1", title: "B"), task(c, rev: "1", title: "C")])
        try repository.assignTask(id: a, recipientCloudUserPeerId: 987654321)
        try repository.assignTask(id: b, recipient: SGTasksWire.TelegramId(int64: 1001)!)
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.rateLimited, status: 429, retryAfter: 86400) } }]
        await repository.syncNow()
        try check(Set(repository.state.deferredAssignments.map { $0.taskId }) == [a, b], "both invites were not deferred")
        // A newer pick on A cancels its deferral: only the new invite goes out.
        try repository.assignTask(id: a, recipient: SGTasksWire.TelegramId(int64: 3333)!)
        try check(repository.state.deferredAssignments.map { $0.taskId } == [b], "the newer pick did not cancel the deferral")
        harness.server.batchScript = [{ request in answer(request) { _, item in receipt(item.mutation, revision: "2") } }]
        await repository.syncNow()
        let invites = sentInvites(harness)
        try check(invites.count == 3 && invites[2].request.taskId == a && invites[2].request.recipientTgId.rawValue == "3333", "the newer pick did not go out alone: \(invites.map { $0.request.recipientTgId.rawValue })")
        // B's re-send meets a second long 429: deferred again with the new time, still no gate.
        harness.clock = harness.clock.addingTimeInterval(86401)
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.rateLimited, status: 429, retryAfter: 3600) } }]
        await repository.syncNow()
        try check(sentInvites(harness).count == 4 && sentInvites(harness)[3].request.taskId == b, "B's deferral was not re-sent when due")
        try check(repository.state.deferredAssignments == [SGTasksCloudDeferredAssignment(taskId: b, recipientTgId: SGTasksWire.TelegramId(int64: 1001)!, after: harness.clock.addingTimeInterval(3600))], "the second long 429 did not re-defer with its own time: \(repository.state.deferredAssignments)")
        try check(repository.state.entries.allSatisfy { $0.status == .awaitingSync } && meta(harness, "not_before") == nil && meta(harness, "assign_resend.\(b.rawValue)") == nil, "the re-deferred re-send left an entry, a gate or its marker")
        // A short 429 (the minute bucket) keeps today's account gate: the entry stays, no deferral.
        try repository.assignTask(id: c, recipient: SGTasksWire.TelegramId(int64: 1002)!)
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.rateLimited, status: 429, retryAfter: 60) } }]
        await repository.syncNow()
        let gated = repository.state.entries.first { $0.resourceId == c.rawValue }
        try check(gated?.status == .queued && gated?.attempts == 0 && repository.state.phase == .rateLimited(retryAt: harness.clock.addingTimeInterval(60)), "a short 429 did not keep the account gate: \(String(describing: gated?.status)) \(repository.state.phase)")
        try check(repository.state.deferredAssignments.map { $0.taskId } == [b] && meta(harness, "not_before_reason") == "rate_limited", "a short 429 deferred the invite")
    }

    private static func deferralEndsQuietly() async throws {
        allow()
        defer { restoreLegacy() }
        let analytics = capture()
        defer { analytics.stop() }
        let ids = (0 ..< 5).map { _ in SGTasksWire.UUID.generate() }
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        let (harness, repository) = try await r4Board(ids.enumerated().map { task($0.element, rev: "1", title: "T\($0.offset)") })
        for id in ids {
            try repository.assignTask(id: id, recipientCloudUserPeerId: 987654321)
        }
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.rateLimited, status: 429, retryAfter: 86400) } }]
        await repository.syncNow()
        try check(repository.state.deferredAssignments.count == 5, "the five invites were not deferred")
        // Before they are due: A is completed elsewhere, B is deleted, C is assigned elsewhere.
        harness.server.changesScript = [changesPage([
            upsert(task(a, rev: "2", title: "T0", completed: true)),
            remove(.task(b)),
            upsert(assigned(c, rev: "2", title: "T2", invitation: SGTasksWire.UUID.generate(), recipient: SGTasksWire.TelegramId(int64: 4444)!, state: .pending))
        ], serverWire: 4)]
        await repository.syncNow()
        try check(sentInvites(harness).count == 5, "something was sent before the deferrals were due")
        // Due: A, B and C end quietly; D and E go again. D meets completed_task (dropped quietly), E
        // meets revision_changed (resolved automatically after the pull, still an automatic re-send).
        harness.clock = harness.clock.addingTimeInterval(86401)
        harness.server.batchScript = [{ request in
            answer(request) { _, item in
                itemError(.conflict(inviteRequest(item.mutation)?.taskId == d ? .completedTask : .revisionChanged), status: 409)
            }
        }]
        await repository.syncNow()
        let dueInvites = sentInvites(harness).dropFirst(5).map { $0.request.taskId }
        try check(Set(dueInvites) == [d, e] && dueInvites.count == 2, "the due re-sends are not D and E alone: \(dueInvites)")
        try check(repository.state.deferredAssignments.isEmpty, "a deferral survived its due cycle")
        try check(repository.state.entries.count == 1 && repository.state.entries[0].resourceId == e.rawValue && repository.state.entries[0].status == .conflict(.revisionChanged), "D's refusal left a row, or E's conflict is missing: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        try check(repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "a quiet drop left a notice")
        try check(try meta(harness, "assign_resend.\(d.rawValue)") == nil && meta(harness, "assign_resend.\(e.rawValue)") == sentInvites(harness).last { $0.request.taskId == e }?.mutationId, "the re-send markers are wrong")
        // The pull shows E open on revision 2: resealed as a new epoch, the marker follows the new
        // mutation id; its invitation_changed answer then drops it quietly too.
        harness.server.changesScript = [changesPage([upsert(task(e, rev: "2", title: "T4"))], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.conflict(.invitationChanged), status: 409) } }]
        await repository.syncNow()
        let resealed = sentInvites(harness).last
        let before = sentInvites(harness).dropLast().last { $0.request.taskId == e }
        try check(resealed?.request.taskId == e && resealed?.request.baseRevision.rawValue == "2" && resealed?.mutationId != before?.mutationId && resealed?.request.invitationId != before?.request.invitationId, "E was not resealed as a new epoch on the fresh revision")
        try check(repository.state.entries.isEmpty && repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "the refused resealed re-send left a row or a notice: \(repository.state.entries.map { $0.status })")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key GLOB 'assign_resend.*' OR key GLOB 'assign_deferred.*';") == 0, "a marker outlived the quiet drops")
        try check(!analytics.events().contains(.syncIssue(kind: "conflict_manual")), "a quiet drop was reported as a manual conflict")
    }

    private static func autoResolveInviteRows() async throws {
        allow()
        defer { restoreLegacy() }
        let p = SGTasksWire.UUID.generate(), q = SGTasksWire.UUID.generate(), r = SGTasksWire.UUID.generate(), s = SGTasksWire.UUID.generate()
        let e1 = SGTasksWire.UUID.generate(), e2 = SGTasksWire.UUID.generate(), e3 = SGTasksWire.UUID.generate()
        let (harness, repository) = try await r4Board([
            task(p, rev: "2", title: "P"),
            task(q, rev: "2", title: "Q"),
            assigned(r, rev: "2", title: "R", invitation: e1, recipient: otherTg, state: .pending),
            assigned(s, rev: "2", title: "S", invitation: e2, recipient: otherTg, state: .accepted)
        ])
        try repository.assignTask(id: p, recipientCloudUserPeerId: 987654321)
        try repository.assignTask(id: q, recipientCloudUserPeerId: 987654321)
        try repository.revokeInvitation(taskId: r, expectedInvitationId: e1)
        try repository.revokeInvitation(taskId: s, expectedInvitationId: e2)
        let originalP = try sealed(harness).compactMap(inviteRequest).first { $0.taskId == p }
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.conflict(.revisionChanged), status: 409) } }]
        await repository.syncNow()
        try check(repository.state.entries.count == 4 && repository.state.entries.allSatisfy { $0.status == .conflict(.revisionChanged) }, "the four conflicts were not recorded")
        harness.server.changesScript = [changesPage([
            upsert(task(p, rev: "3", title: "P renamed")),
            upsert(task(q, rev: "3", title: "Q", completed: true)),
            upsert(assigned(r, rev: "3", title: "R renamed", invitation: e1, recipient: otherTg, state: .pending)),
            upsert(assigned(s, rev: "3", title: "S", invitation: e3, recipient: SGTasksWire.TelegramId(int64: 4444)!, state: .pending))
        ], serverWire: 4)]
        harness.server.batchScript = [{ request in answer(request) { _, item in receipt(item.mutation, revision: "4") } }]
        await repository.syncNow()
        guard harness.server.sentBatches.count == 2 else { throw CloudTestFailure.assertion("no resealed batch: \(harness.server.sentBatches.count)") }
        let resealed = harness.server.sentBatches[1].items.map { $0.mutation }
        var request: SGTasksWire.InviteRequest?
        var revoke: SGTasksWire.InviteRevoke?
        for mutation in resealed {
            guard case let .mutation(sealedRequest) = mutation else { continue }
            switch sealedRequest.operation {
            case let .inviteRequest(op): request = op
            case let .inviteRevoke(op): revoke = op
            default: break
            }
        }
        try check(resealed.count == 2, "the resealed batch is not P's request and R's revoke: \(resealed.map { $0.kind })")
        try check(request?.taskId == p && request?.baseRevision.rawValue == "3" && request?.recipientTgId == otherTg && request?.invitationId != originalP?.invitationId, "P's request was not resealed on the fresh revision as a new epoch")
        try check(revoke?.taskId == r && revoke?.baseRevision.rawValue == "3" && revoke?.invitationId == e1, "R's revoke was not resealed on the fresh revision with the same epoch")
        let left = repository.state.entries.filter { $0.status == .conflict(.revisionChanged) }
        try check(left.count == 1 && left[0].resourceId == q.rawValue && left[0].kind == .inviteRequest, "the completed task's request did not stay explicit: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        try check(!repository.state.entries.contains { $0.resourceId == s.rawValue }, "the revoke of a replaced epoch was not dropped")
        try check(left[0].allowedActions == [.reapply, .discard], "the explicit request lost its actions")
    }

    /// wf15 §4.1 (review E-1 / privacy P2): the owner editor captures its draft — annotation
    /// included — when it opens, and "Masʼulni olib tashlash" and "Yuborish" apply at once and
    /// leave it open. Whatever such a draft carries, a Save changes the user's fields only.
    private static func saveNeverTouchesTheAnnotation() async throws {
        allow()
        defer { restoreLegacy() }
        let removed = SGTasksWire.UUID.generate(), sent = SGTasksWire.UUID.generate(), plain = SGTasksWire.UUID.generate()
        let ali = SGTasksWire.Annotation(telegramUserId: otherTg, displayName: "Ali")
        let staleAnnotation = SGTasksCloudAnnotationDraft(cloudUserPeerId: 987654321, displayName: "Ali")
        func legacy(_ id: SGTasksWire.UUID, rev: String, title: String, annotation: SGTasksWire.Annotation?) -> SGTasksWire.Projection {
            let content = SGTasksWire.Content(listId: nil, title: title, description: nil, dueAt: nil, priority: 0, sortOrder: 0, annotation: annotation)
            return .task(SGTasksWire.Task(id: id, revision: revision(rev), ownerTgId: ownTg, viewerRole: .owner, content: content, isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: nil))
        }
        func patches(_ harness: Harness, of taskId: SGTasksWire.UUID) throws -> [SGTasksWire.TaskPatch] {
            return try sealed(harness).compactMap { mutation in
                if case let .patch(request) = mutation, request.patch.taskId == taskId { return request.patch }
                return nil
            }
        }
        let (harness, repository) = try await r4Board([
            legacy(removed, rev: "2", title: "Removed", annotation: ali),
            legacy(sent, rev: "2", title: "Sent", annotation: ali),
            task(plain, rev: "2", title: "Plain")
        ])

        // 1. The editor opened on the annotation-only task; "Masʼulni olib tashlash"; a title edit;
        //    Save with the draft captured at open.
        try repository.removeLegacyAnnotation(taskId: removed)
        try check(repository.state.tasks.first { $0.id == removed }?.annotation == nil, "the overlay still shows the removed annotation")
        try repository.updateTask(id: removed, draft: SGTasksCloudTaskDraft(title: "Removed, renamed", annotation: staleAnnotation, sortOrder: 0))
        let removedPatches = try patches(harness, of: removed)
        try check(removedPatches.count == 2 && removedPatches[0] == SGTasksCloudRepository.annotationClearPatch(taskId: removed, annotation: ali), "the clear is not the first patch: \(removedPatches)")
        try check(removedPatches[1].set == [.title: .title("Removed, renamed")] && removedPatches[1].expect == [.title: .title("Removed")], "the Save after the clear is not the title alone: \(removedPatches[1])")
        // The same stale draft with nothing else changed queues nothing at all.
        try repository.updateTask(id: removed, draft: SGTasksCloudTaskDraft(title: "Removed, renamed", annotation: staleAnnotation, sortOrder: 0))
        try check(try patches(harness, of: removed).count == 2, "a Save that differs only by the stale annotation queued a patch")

        // 2. "Yuborish" on the other annotation-only task: the receipt chains the clear; the editor
        //    stayed open and saves a due date with the draft captured before the send.
        try repository.assignTask(id: sent, recipientCloudUserPeerId: 987654321)
        var revisionCounter = 2
        harness.server.batchScript = Array(repeating: { request in
            revisionCounter += 1
            return answer(request) { _, item in receipt(item.mutation, revision: String(revisionCounter)) }
        }, count: 8)
        await repository.syncNow()
        let chained = harness.server.sentBatches.flatMap { $0.items }.compactMap { item -> SGTasksWire.TaskPatch? in
            if case let .patch(request) = item.mutation, request.patch.taskId == sent { return request.patch }
            return nil
        }
        try check(chained == [SGTasksCloudRepository.annotationClearPatch(taskId: sent, annotation: ali)], "the send's receipt did not chain exactly the clear: \(chained)")
        try check(repository.state.tasks.first { $0.id == sent }?.annotation == nil, "the overlay still shows the annotation after the chained clear")
        let before = try patches(harness, of: sent).count
        try repository.updateTask(id: sent, draft: SGTasksCloudTaskDraft(title: "Sent", dueAt: 1_900_000_000, annotation: staleAnnotation, sortOrder: 0))
        let sentPatches = try patches(harness, of: sent)
        try check(sentPatches.count == before + 1, "the Save after the chained clear queued \(sentPatches.count - before) patches")
        try check(sentPatches.last?.set == [.dueAt: .dueAt(1_900_000_000)] && sentPatches.last?.expect == [.dueAt: .dueAt(nil)], "the Save after the chained clear is not the due date alone: \(String(describing: sentPatches.last))")

        // 3. The mirror: the editor opened without an annotation, another client of the account
        //    wrote one meanwhile; the Save does not wipe it.
        let vali = SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId(int64: 5555)!, displayName: "Vali")
        harness.server.changesScript = [changesPage([upsert(legacy(plain, rev: "3", title: "Plain", annotation: vali))], serverWire: 4)]
        await repository.syncNow()
        try check(repository.state.tasks.first { $0.id == plain }?.annotation == vali, "the annotation written elsewhere is not shown")
        try repository.updateTask(id: plain, draft: SGTasksCloudTaskDraft(title: "Plain, renamed", sortOrder: 0))
        let plainPatches = try patches(harness, of: plain)
        try check(plainPatches.count == 1 && plainPatches[0].set == [.title: .title("Plain, renamed")] && plainPatches[0].expect == [.title: .title("Plain")], "the Save wiped or expected the annotation written elsewhere: \(plainPatches)")
        try check(repository.state.tasks.first { $0.id == plain }?.annotation == vali, "the overlay lost the annotation written elsewhere")
        // No patch of this case ever set an annotation other than the two clears.
        try check(try sealed(harness).allSatisfy { mutation in
            guard case let .patch(request) = mutation else { return true }
            return request.patch.set[.annotation] == nil || request.patch.set[.annotation] == .annotation(nil)
        }, "a patch wrote an annotation")

        // 4. A refused Save's repair keeps the server row's annotation too, never the draft's.
        try harness.clearOutbox(repository)
        try repository.updateTask(id: plain, draft: SGTasksCloudTaskDraft(title: "Refused", sortOrder: 0))
        harness.server.batchScript = [{ _ in failure(.invalidRequest) }]
        await repository.syncNow()
        guard let refused = repository.state.entries.first(where: { $0.resourceId == plain.rawValue && $0.status == .invalid }) else {
            throw CloudTestFailure.assertion("the refused Save is not an invalid entry: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        }
        try check(repository.entryTaskDraft(entryId: refused.id)?.annotation == SGTasksCloudAnnotationDraft(cloudUserPeerId: 5555, displayName: "Vali"), "the repair draft does not start from the server row")
        try repository.repair(entryId: refused.id, taskDraft: SGTasksCloudTaskDraft(title: "Repaired", annotation: staleAnnotation, sortOrder: 0))
        let repaired = try patches(harness, of: plain)
        try check(repaired.count == 1 && repaired[0].set == [.title: .title("Repaired")] && repaired[0].expect == [.title: .title("Plain")], "the repair wrote the draft's annotation: \(repaired)")
    }

    /// Review E-11: the chained clear is appended at the outbox tail when the invite's receipt
    /// arrives; behind a delete of the same task it could only meet a 404.
    private static func annotationClearNeverTrailsADelete() async throws {
        allow()
        defer { restoreLegacy() }
        let deleted = SGTasksWire.UUID.generate(), gone = SGTasksWire.UUID.generate()
        let ali = SGTasksWire.Annotation(telegramUserId: otherTg, displayName: "Ali")
        func legacy(_ id: SGTasksWire.UUID, title: String) -> SGTasksWire.Projection {
            let content = SGTasksWire.Content(listId: nil, title: title, description: nil, dueAt: nil, priority: 0, sortOrder: 0, annotation: ali)
            return .task(SGTasksWire.Task(id: id, revision: revision("2"), ownerTgId: ownTg, viewerRole: .owner, content: content, isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: nil))
        }
        let (harness, repository) = try await r4Board([legacy(deleted, title: "Sent, then deleted"), legacy(gone, title: "Deleted elsewhere")])
        // Offline: Yuborish on the annotation-only task, then the task is deleted (the Undo window passes).
        try repository.assignTask(id: deleted, recipientCloudUserPeerId: 987654321)
        let undo = try repository.deleteTask(id: deleted)
        undo.commit()
        // The other task: "Masʼulni olib tashlash" — the user's own clear — meets a task deleted elsewhere.
        try repository.removeLegacyAnnotation(taskId: gone)
        var revisionCounter = 2
        harness.server.batchScript = Array(repeating: { request in
            revisionCounter += 1
            return answer(request) { _, item in
                if case let .patch(patch) = item.mutation, patch.patch.taskId == gone { return itemError(.notFound, status: 404) }
                return receipt(item.mutation, revision: String(revisionCounter))
            }
        }, count: 6)
        await repository.syncNow()
        let sentPatches = harness.server.sentBatches.flatMap { $0.items }.compactMap { item -> SGTasksWire.TaskPatch? in
            if case let .patch(request) = item.mutation { return request.patch }
            return nil
        }
        try check(!sentPatches.contains { $0.taskId == deleted }, "an annotation clear was chained behind the task's delete")
        try check(try !sealed(harness).contains { mutation in
            if case let .patch(request) = mutation { return request.patch.taskId == deleted }
            return false
        }, "an annotation clear of the deleted task is queued")
        try check(sentPatches.filter { $0.taskId == gone } == [SGTasksCloudRepository.annotationClearPatch(taskId: gone, annotation: ali)], "the user's clear was not sent once")
        try check(!repository.state.entries.contains { $0.status == .notFound } && !repository.state.entries.contains { $0.mutationKind == .taskPatch }, "the clear's 404 left a row: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        try check(repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "the clear's 404 raised a notice: \(repository.state.notices.map { $0.kind })")
        // Contrast: a real edit's 404 still becomes a notFound row with its notice.
        try harness.clearOutbox(repository)
        try repository.updateTask(id: gone, draft: SGTasksCloudTaskDraft(title: "Edited", sortOrder: 0))
        harness.server.batchScript = [{ request in answer(request) { _, _ in itemError(.notFound, status: 404) } }]
        await repository.syncNow()
        try check(repository.state.entries.map { $0.status } == [.notFound] && repository.state.notices.map { $0.kind } == [SGTasksCloudNotice.Kind.ownResourceMissing], "a real edit's 404 lost its row or notice: \(repository.state.entries.map { $0.status })")
    }

    private static func receiptChainsAnnotationClear() async throws {
        allow()
        defer { restoreLegacy() }
        let legacy = SGTasksWire.UUID.generate(), plain = SGTasksWire.UUID.generate()
        let ali = SGTasksWire.Annotation(telegramUserId: otherTg, displayName: "Ali")
        let legacyContent = SGTasksWire.Content(listId: nil, title: "Legacy", description: nil, dueAt: nil, priority: 0, sortOrder: 0, annotation: ali)
        let (harness, repository) = try await r4Board([
            .task(SGTasksWire.Task(id: legacy, revision: revision("2"), ownerTgId: ownTg, viewerRole: .owner, content: legacyContent, isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: nil)),
            task(plain, rev: "2", title: "Plain")
        ])
        try repository.assignTask(id: legacy, recipientCloudUserPeerId: 987654321)
        try repository.assignTask(id: plain, recipientCloudUserPeerId: 987654321)
        try check(try sealed(harness).allSatisfy { if case .patch = $0 { return false } else { return true } }, "a patch was queued before any receipt")
        // Batch 1 acknowledges both invites; the chained clear goes in batch 2 and meets field_changed.
        harness.server.batchScript = [
            { request in answer(request) { _, item in receipt(item.mutation, revision: "3") } },
            { request in answer(request) { _, _ in itemError(.conflict(.revisionChanged), status: 409, refinement: .fieldChanged(fields: [.annotation])) } }
        ]
        await repository.syncNow()
        guard harness.server.sentBatches.count == 2, harness.server.sentBatches[1].items.count == 1, case let .patch(clear) = harness.server.sentBatches[1].items[0].mutation else {
            throw CloudTestFailure.assertion("the receipt did not chain one task.patch: \(harness.server.sentBatches.map { $0.items.map { $0.mutation.kind } })")
        }
        try check(clear.patch == SGTasksCloudRepository.annotationClearPatch(taskId: legacy, annotation: ali), "the chained patch is not {set: annotation null, expect: the shadow's annotation}: \(clear.patch)")
        try check(harness.server.sentBatches[1].items[0].mutation.mutationId != harness.server.sentBatches[0].items[0].mutation.mutationId, "the clear reused a mutation id")
        // The cycle's post-drain pull resolved the field_changed clear at once: dropped quietly — no
        // entry, no notice, no Unsent Changes row; the two invites wait for their shadow proof alone.
        try check(repository.state.entries.map { $0.status } == [.awaitingSync, .awaitingSync] && !repository.state.entries.contains { $0.mutationKind == .taskPatch }, "the conflicting clear stayed: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        try check(repository.state.notices.isEmpty && repository.state.resolutionNotices.isEmpty, "the quiet drop left a notice")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE kind = 'task.patch';") == 0, "the dropped clear is still in the outbox")
        // The next pull shows the other annotation written elsewhere: it is shown as the server holds
        // it, nothing is sent again, and the task without an annotation never got a clear.
        let vali = SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId(int64: 5555)!, displayName: "Vali")
        harness.server.changesScript = [changesPage([upsert(assigned(legacy, rev: "4", title: "Legacy", invitation: SGTasksWire.UUID.generate(), recipient: otherTg, state: .pending, annotation: vali))], serverWire: 4)]
        await repository.syncNow()
        try check(!repository.state.entries.contains { $0.mutationKind == .taskPatch } && harness.server.sentBatches.count == 2, "the dropped clear came back or was sent again: \(repository.state.entries.map { ($0.resourceId, $0.status) })")
        try check(repository.state.tasks.first { $0.id == legacy }?.annotation == vali, "the other annotation is not shown as the server holds it")
        try check(!harness.server.sentBatches.flatMap { $0.items }.contains { item in
            if case let .patch(request) = item.mutation { return request.patch.taskId == plain }
            return false
        }, "a task without an annotation got a clear")
    }
}
