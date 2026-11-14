import Foundation
import SGEntitlement
import sqlcipher

// Host tests for the legacy assignee sheet (wf15 §7, D4): the pure `SGTasksLegacyAssigneeOffer`
// (candidates, the per-task candidate, the one-time decision, the pacing plan), the repository's
// host reads behind it (`legacyDeviceFacts` / `legacyAssigneeOffer`: a real device database with
// real import mappings, the scripted server's board), the engine's paced send, and the durable
// markers (`SGTasksLocalMarkers`) across a simulated non-last and last logout. No `@main`:
// SGTasksCloudRepositoryTests.main appends `cases`. Nothing here opens UIKit; nothing is sent to a
// backend — the scripted server stands in.

enum SGTasksLegacyAssigneeOfferTests {
    static let cases: [(String, () async throws -> Void)] = [
        ("wf15 I6: candidates — mapped device rows joined with the board (order created_at then id, self and unconvertible greyed, completed / live / unmapped / sent out, annotation-only per task only, the §5.6 name map)", candidatesJoinDeviceRowsWithTheBoard),
        ("wf15 I6: the pacing plan — per person 5, total 95, pending 95, ten per minute from this minute's count; the paced send skips only the minute counter and a manual pick after it is refused", pacingPlanAndPacedSend),
        ("wf15 I6: a sent device-row candidate leaves the list at once and never returns — declined reads Rad etdi, a detach leaves no candidate; the marker, remaining and the sent set survive a non-last logout and go at the last", sentCandidateNeverReturnsAcrossLogouts),
        ("wf15 I6: the sheet is offered once per record — completed, skipped(existing_mappings), skipped(scope_changed) only once rows are mapped in the current scope; never after Keyinroq, again only for a new record", offeredOncePerRecord),
        ("wf15 I6: an annotation-only task is a per-task candidate, never a sheet row or counted; its send chains the annotation clear on the receipt", annotationOnlyIsPerTaskOnly),
        ("wf15 I6: SGTasksLocalMarkers — keys, the marker bound to claimedAt, remaining, the sent set, removeAll keeps sgtasks.inviteAnswers.*", localMarkers),
        ("wf15 review E-9 / P3 / P2: Yuborish sends only the rows the sheet listed — a pair that became a candidate while it was open is not in the plan, a listed row that stopped being one or changed its recipient is dropped; the paced count is the plan's", sheetSendsOnlyListedRows)
    ]

    // MARK: - Fixtures

    private static func allow(_ permission: SGTasksSyncPermission = .allowed) {
        SGTasksCloudRepository.trafficPermission = { _ in permission }
    }

    /// Runs `body` as an `.allowed` registry case of `harness` (the migration step reads the static
    /// environment), then restores every shared static.
    private static func run(_ harness: Harness, _ body: () async throws -> Void) async throws {
        let savedEnvironment = SGTasksCloudRepository.environment
        SGTasksCloudRepository.environment = harness.environment
        allow()
        defer {
            SGTasksCloudRepository.environment = savedEnvironment
            SGTasksCloudRepository.trafficPermission = { _ in .legacy }
            TodoStorage.writeFence = { _ in .open }
        }
        try await body()
    }

    private static func r4Harness() throws -> Harness {
        let harness = try Harness()
        harness.server.defaultServerWire = 4
        return harness
    }

    private static var scopeA: String {
        return SGTasksCloudRepository.importScope(origin: originX, principal: principalA)
    }

    private static var scopeB: String {
        return SGTasksCloudRepository.importScope(origin: originX, principal: principalB)
    }

    /// The packed CloudUser peer id of a raw Telegram id below 2^32 is the id itself (namespace 0).
    private static let aliPeerId: Int64 = otherTg.int64Value
    /// A group peer id (namespace 1): never a Telegram user.
    private static let groupPeerId: Int64 = 8_589_934_597
    private static let ali = TodoAssignee(peerId: aliPeerId, displayName: "Ali")

    private static func content(_ title: String, annotation: SGTasksWire.Annotation? = nil) -> SGTasksWire.Content {
        return SGTasksWire.Content(listId: nil, title: title, description: nil, dueAt: nil, priority: 0, sortOrder: 0, annotation: annotation)
    }

    private static func task(_ id: SGTasksWire.UUID, title: String, completed: Bool = false, assignment: SGTasksWire.Assignment? = nil, annotation: SGTasksWire.Annotation? = nil) -> SGTasksWire.Projection {
        return .task(SGTasksWire.Task(id: id, revision: revision("2"), ownerTgId: ownTg, viewerRole: .owner, content: content(title, annotation: annotation), isCompleted: completed, completedAt: completed ? instant() : nil, createdAt: instant(), updatedAt: instant(), assignment: assignment))
    }

    private static func assignment(_ state: SGTasksWire.AssignmentState, recipient: SGTasksWire.TelegramId = otherTg, expires: TimeInterval = 7 * 86400) -> SGTasksWire.Assignment {
        return SGTasksWire.Assignment(invitationId: SGTasksWire.UUID.generate(), recipientTgId: recipient, state: state, expiresAt: instant(expires))
    }

    private static func uuid(_ raw: String) throws -> SGTasksWire.UUID {
        return try SGTasksWire.UUID(raw).orThrow("uuid \(raw)")
    }

    /// Stamps a device row's creation time in seconds, as a device clock wrote it.
    private static func stamp(_ harness: Harness, _ id: String, createdAt: Int64) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let sql = "UPDATE tasks SET created_at = \(createdAt) WHERE id = '\(id)';"
        guard sqlite3_open_v2(harness.directory.appendingPathComponent("legacy.sqlite").path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(connection) == 1 else {
            throw CloudTestFailure.assertion("stamping a device row failed")
        }
    }

    /// Mints the import mapping of every device row under scope A (as an R3 explicit copy or the
    /// migration would) and returns legacy task id → cloud task id.
    private static func mapDeviceRows(_ harness: Harness, account: Int64, scope: String? = nil) throws -> [String: SGTasksWire.UUID] {
        let snapshot = try harness.legacy.cloudImportSnapshot()
        let mappings = try harness.legacy.cloudImportMappings(for: snapshot, accountPeerId: account, principalScope: scope ?? Self.scopeA, mint: {
            (cloudId: SGTasksWire.UUID.generate().rawValue, mutationId: SGTasksWire.UUID.generate().rawValue)
        })
        var out: [String: SGTasksWire.UUID] = [:]
        for mapping in mappings where mapping.kind == .task {
            out[mapping.legacyId] = try uuid(mapping.cloudId)
        }
        return out
    }

    private static func acceptAll(_ request: SGTasksWire.MutationBatchRequest) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        let results = request.items.map { item -> SGTasksWire.BatchItemResult in
            guard case let .success(response) = ack(item.mutation, revision: "1") else {
                preconditionFailure("ack() always succeeds")
            }
            return .receipt(response.receipt)
        }
        return .success(SGTasksWire.MutationBatchResponse(batchId: request.batchId, results: results, retryAfter: nil, serverTime: instant(), serverWire: 4))
    }

    /// Sends every queued create (accepted) and proves it with a page of upserts.
    private static func deliver(_ harness: Harness, _ repository: SGTasksCloudRepository) async throws {
        let requests = try harness.outboxBodies(accountPeerId: repository.accountPeerId).map { try SGTasksWire.MutationRequest(wireJSON: $0) }
        var changes: [SGTasksWire.Change] = []
        for (offset, request) in requests.enumerated() {
            if case let .taskCreate(op) = request.operation {
                let projection = SGTasksWire.Projection.task(SGTasksWire.Task(id: op.taskId, revision: revision("1"), ownerTgId: ownTg, viewerRole: .owner, content: op.content, isCompleted: op.isCompleted, completedAt: op.completedAt, createdAt: instant(), updatedAt: instant(), assignment: nil))
                changes.append(upsert(projection, at: "\(100 + offset)"))
            } else if case let .listCreate(op) = request.operation {
                let projection = SGTasksWire.Projection.list(SGTasksWire.List(id: op.listId, revision: revision("1"), title: op.title, sortOrder: op.sortOrder, createdAt: instant(), updatedAt: instant(), membersRevision: revision("1")))
                changes.append(upsert(projection, at: "\(100 + offset)"))
            }
        }
        harness.server.batchScript = Array(repeating: Self.acceptAll, count: 10)
        harness.server.changesScript = [changesPage([]), changesPage(changes)]
        await repository.syncNow()
        try check(repository.state.entries.isEmpty, "the copy was not delivered: \(repository.state.entries.map { $0.status })")
    }

    /// Two inbox rows with Ali as their local Masʼul, migrated to a `completed` record.
    private static func migratedDevice(_ harness: Harness, account: Int64) async throws -> (repository: SGTasksCloudRepository, first: TodoTask, second: TodoTask) {
        let first = try harness.legacy.createQuickTask(folderId: nil, title: "QA legacy 1", inboxTitle: "Inbox", assignee: ali)
        let second = try harness.legacy.createQuickTask(folderId: nil, title: "QA legacy 2", inboxTitle: "Inbox", assignee: ali)
        try stamp(harness, first.id, createdAt: 1_000)
        try stamp(harness, second.id, createdAt: 2_000)
        let repository = SGTasksCloudRepository.repository(accountPeerId: account)
        try await harness.bootstrap(repository)
        try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
        try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .enqueued, "fixture: the copy was not enqueued")
        try await deliver(harness, repository)
        try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "fixture: the copy did not complete")
        return (repository, first, second)
    }

    private static func sentInviteTaskIds(_ harness: Harness) -> [SGTasksWire.UUID] {
        return harness.server.sentBatches.flatMap { $0.items }.compactMap { item in
            if case let .mutation(request) = item.mutation, case let .inviteRequest(op) = request.operation {
                return op.taskId
            }
            return nil
        }
    }

    // MARK: - Candidates (§7.2)

    private static func candidatesJoinDeviceRowsWithTheBoard() async throws {
        let harness = try r4Harness()
        let account: Int64 = 7201
        let legacy = harness.legacy
        try await run(harness) {
            let work = try legacy.createFolder(title: "Work")
            let plainAli = try legacy.createQuickTask(folderId: work.id, title: "Hisobot", inboxTitle: "Inbox", assignee: ali)
            let selfRow = try legacy.createQuickTask(folderId: work.id, title: "Oʻzimga", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: ownTg.int64Value, displayName: "Men"))
            let groupRow = try legacy.createQuickTask(folderId: work.id, title: "Guruh", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: groupPeerId, displayName: "Jamoa"))
            let doneRow = try legacy.createQuickTask(folderId: work.id, title: "Bajarilgan", inboxTitle: "Inbox", assignee: ali)
            let liveRow = try legacy.createQuickTask(folderId: work.id, title: "Yuborilgan", inboxTitle: "Inbox", assignee: ali)
            let declinedRow = try legacy.createQuickTask(folderId: nil, title: "Rad etilgan", inboxTitle: "Inbox", assignee: ali)
            let expiredRow = try legacy.createQuickTask(folderId: nil, title: "Muddati oʻtgan", inboxTitle: "Inbox", assignee: ali)
            _ = try legacy.createQuickTask(folderId: work.id, title: "Masʼulsiz", inboxTitle: "Inbox")
            // The sheet's order is the device row's created_at, then its id (§7.2 item 4).
            try stamp(harness, declinedRow.id, createdAt: 100)
            for row in [plainAli, selfRow, groupRow] {
                try stamp(harness, row.id, createdAt: 500)
            }
            try stamp(harness, doneRow.id, createdAt: 600)
            try stamp(harness, liveRow.id, createdAt: 700)
            try stamp(harness, expiredRow.id, createdAt: 800)
            let cloudIds = try mapDeviceRows(harness, account: account)
            // A row mapped only after the mint: no mapping, never a candidate.
            let unmapped = try legacy.createQuickTask(folderId: work.id, title: "Keyin", inboxTitle: "Inbox", assignee: ali)
            try check(cloudIds[unmapped.id] == nil && cloudIds.count == 8, "fixture: the mappings")

            let annotationOnly = SGTasksWire.UUID.generate()
            let vali = SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId(int64: 5555)!, displayName: "Vali")
            let repository = harness.repository(account)
            try await harness.bootstrap(repository, items: [
                task(cloudIds[plainAli.id]!, title: "Hisobot"),
                task(cloudIds[selfRow.id]!, title: "Oʻzimga"),
                task(cloudIds[groupRow.id]!, title: "Guruh"),
                task(cloudIds[doneRow.id]!, title: "Bajarilgan", completed: true),
                task(cloudIds[liveRow.id]!, title: "Yuborilgan", assignment: assignment(.pending)),
                task(cloudIds[declinedRow.id]!, title: "Rad etilgan", assignment: assignment(.declined)),
                task(cloudIds[expiredRow.id]!, title: "Muddati oʻtgan", assignment: assignment(.pending, expires: -60)),
                task(annotationOnly, title: "Eski yozuv", annotation: vali)
            ])
            let facts = repository.legacyDeviceFacts()
            try check(facts.rows.count == 8 && facts.mappings.count == 8 && facts.mappings.allSatisfy { $0.kind == .task }, "the host reads: \(facts.rows.count) rows, \(facts.mappings.count) mappings")
            let offer = repository.legacyAssigneeOffer()
            let order = offer.candidates.map { $0.deviceTaskId }
            let sameSecond = [plainAli.id, selfRow.id, groupRow.id].sorted()
            try check(order == [declinedRow.id] + sameSecond + [expiredRow.id], "the rows are not in created_at, id order: \(offer.candidates.map { $0.title })")
            let byDevice = Dictionary(uniqueKeysWithValues: offer.candidates.map { ($0.deviceTaskId, $0) })
            try check(byDevice[plainAli.id].map { $0.isSendable && $0.recipient == otherTg && $0.name == "Ali" && $0.title == "Hisobot" && $0.cloudTaskId == cloudIds[plainAli.id] } == true, "the plain row")
            try check(byDevice[selfRow.id].map { $0.isSelf && !$0.isSendable && $0.recipient == ownTg } == true, "the account's own row is listed greyed (self)")
            try check(byDevice[groupRow.id].map { $0.recipient == nil && !$0.isSelf && !$0.isSendable } == true, "a group id is listed greyed (not sendable)")
            try check(byDevice[declinedRow.id]?.isSendable == true && byDevice[expiredRow.id]?.isSendable == true, "an ended assignment (declined, pending past its expiry) is no live assignment")
            try check(byDevice[doneRow.id] == nil && byDevice[liveRow.id] == nil && byDevice[unmapped.id] == nil, "a completed task, a live assignment or an unmapped row became a candidate")
            try check(!offer.candidates.contains { $0.cloudTaskId == annotationOnly }, "an annotation-only task is a sheet row")
            try check(offer.remaining == 3 && offer.offersSheet && offer.sendable.map { $0.deviceTaskId } == [declinedRow.id, plainAli.id, expiredRow.id], "remaining counts the sendable rows only: \(offer.remaining)")
            // §5.6 fallback (1): every mapped row with a Telegram user id, candidate or not.
            let names = offer.deviceAssignees
            try check(Set(names.keys) == Set([plainAli, selfRow, doneRow, liveRow, declinedRow, expiredRow].map { cloudIds[$0.id]!.rawValue }), "the name map: \(names.keys.sorted())")
            try check(names[cloudIds[liveRow.id]!.rawValue] == TasksLegacyDeviceAssignee(recipient: otherTg, name: "Ali"), "the mapped row's owner-entered name")
            // The per-task candidate (§7.2 item 2): a device row first, else the annotation.
            let serverNow = repository.state.estimatedServerNow()
            let sent = Set<String>()
            try check(SGTasksLegacyAssigneeOffer.candidate(forCloudTaskId: cloudIds[plainAli.id]!, cloud: repository.state, deviceAssignee: names[cloudIds[plainAli.id]!.rawValue], sentTaskIds: sent, serverNow: serverNow) == .init(recipient: otherTg, name: "Ali", source: .deviceRow), "the device row's per-task candidate")
            try check(SGTasksLegacyAssigneeOffer.candidate(forCloudTaskId: annotationOnly, cloud: repository.state, deviceAssignee: nil, sentTaskIds: sent, serverNow: serverNow) == .init(recipient: vali.telegramUserId, name: "Vali", source: .annotation), "the annotation's per-task candidate")
            try check(SGTasksLegacyAssigneeOffer.candidate(forCloudTaskId: cloudIds[liveRow.id]!, cloud: repository.state, deviceAssignee: names[cloudIds[liveRow.id]!.rawValue], sentTaskIds: sent, serverNow: serverNow) == nil, "a live assignment has no per-task candidate")
            try check(SGTasksLegacyAssigneeOffer.candidate(forCloudTaskId: cloudIds[doneRow.id]!, cloud: repository.state, deviceAssignee: names[cloudIds[doneRow.id]!.rawValue], sentTaskIds: sent, serverNow: serverNow) == nil, "a completed task has no per-task candidate")
            try check(SGTasksLegacyAssigneeOffer.candidate(forCloudTaskId: annotationOnly, cloud: repository.state, deviceAssignee: nil, sentTaskIds: [annotationOnly.rawValue], serverNow: serverNow) == nil, "a task in the sent set has no per-task candidate")
            // The sent set (§7.2 item 5) takes a row out of the sheet at once; the name map keeps it.
            SGTasksLocalMarkers.markLegacySent([cloudIds[plainAli.id]!.rawValue], defaults: harness.legacyDefaults, accountPeerId: account)
            let afterSent = repository.legacyAssigneeOffer()
            try check(!afterSent.candidates.contains { $0.deviceTaskId == plainAli.id } && afterSent.remaining == 2 && afterSent.deviceAssignees[cloudIds[plainAli.id]!.rawValue] != nil, "the sent row stayed a candidate or lost its name")
            // Without a bound principal or without rows there is nothing to join.
            harness.server.principalValue = nil
            try check(repository.legacyDeviceFacts() == .empty && repository.legacyAssigneeOffer() == .empty, "an unbound account read the mappings")
            harness.server.principalValue = principalA
            // De-duplicated by cloud task id: a second mapping of another incarnation pointing at the
            // same cloud task is one row.
            let duplicate = try legacy.createQuickTask(folderId: work.id, title: "Nusxa", inboxTitle: "Inbox", assignee: ali)
            var rows = repository.legacyDeviceFacts().rows
            var mappings = repository.legacyDeviceFacts().mappings
            rows.append(TodoLiveAssigneeRow(task: duplicate.withCreated(9_000), folderIncarnation: "other"))
            mappings.append(TodoCloudImportMapping(kind: .task, legacyId: duplicate.id, legacyIncarnation: "other", cloudId: cloudIds[declinedRow.id]!.rawValue, createMutationId: "m", wasAttempted: false, isAcknowledged: false, verifiedGeneration: 0))
            let deduped = SGTasksLegacyAssigneeOffer.compute(deviceRows: rows, mappings: mappings, cloud: repository.state, ownTelegramId: ownTg, sentTaskIds: [], serverNow: serverNow)
            try check(deduped.candidates.filter { $0.cloudTaskId == cloudIds[declinedRow.id]! }.count == 1 && deduped.candidates.first?.deviceTaskId == declinedRow.id, "two rows mapped to one cloud task made two sheet rows")
        }
    }

    // MARK: - Pacing (§7.3, §12.1)

    private static func pacingPlanAndPacedSend() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let candidate: (Int, SGTasksWire.TelegramId?) -> SGTasksLegacyAssigneeCandidate = { index, recipient in
            SGTasksLegacyAssigneeCandidate(cloudTaskId: SGTasksWire.UUID.generate(), deviceTaskId: "d\(index)", title: "QA legacy \(index)", name: "QA Outsider", recipient: recipient, isSelf: false)
        }
        // Seven rows to one person, two of them to nobody sendable: five go today, two stay.
        var seven = (1 ... 7).map { candidate($0, otherTg) }
        seven.insert(candidate(8, nil), at: 2)
        seven.insert(SGTasksLegacyAssigneeCandidate(cloudTaskId: SGTasksWire.UUID.generate(), deviceTaskId: "self", title: "Oʻzimga", name: "Men", recipient: ownTg, isSelf: true), at: 5)
        let plan = SGTasksLegacyAssigneeOffer.plan(sendable: seven, snapshot: .init(today: 0, thisMinute: 8, pending: 0, recipientToday: [:]), now: now)
        try check(plan.sends.map { $0.candidate.deviceTaskId } == ["d1", "d2", "d3", "d4", "d5"] && plan.later == 2 && plan.isCapped, "the per-person allowance in sheet order: \(plan.sends.map { $0.candidate.deviceTaskId }), later \(plan.later)")
        try check(plan.sends.map { $0.dueAt.timeIntervalSince(now) } == [0, 0, 60, 60, 60], "the spacing from this minute's count (8 sent): \(plan.sends.map { $0.dueAt.timeIntervalSince(now) })")
        // Three already sent to that person today: two more.
        let three = SGTasksLegacyAssigneeOffer.plan(sendable: seven, snapshot: .init(today: 3, thisMinute: 0, pending: 3, recipientToday: [otherTg: 3]), now: now)
        try check(three.sends.count == 2 && three.later == 5, "the per-person remainder: \(three.sends.count)")
        // The day's total and the pending cap.
        try check(SGTasksLegacyAssigneeOffer.plan(sendable: seven, snapshot: .init(today: 93, thisMinute: 0, pending: 0, recipientToday: [:]), now: now).sends.count == 2, "the daily total")
        try check(SGTasksLegacyAssigneeOffer.plan(sendable: seven, snapshot: .init(today: 0, thisMinute: 0, pending: 95, recipientToday: [:]), now: now).sends.isEmpty, "the pending cap")
        // Twelve different people: all twelve, the eleventh and twelfth a minute later.
        let twelve = (1 ... 12).map { candidate($0, SGTasksWire.TelegramId(int64: Int64(1000 + $0))!) }
        let spread = SGTasksLegacyAssigneeOffer.plan(sendable: twelve, snapshot: .zero, now: now)
        try check(spread.sends.count == 12 && !spread.isCapped && spread.sends.map { $0.dueAt.timeIntervalSince(now) } == Array(repeating: 0, count: 10) + [60, 60], "twelve people: \(spread.sends.map { $0.dueAt.timeIntervalSince(now) })")

        // The engine: a paced send (`nextAttemptAt` set) is refused by the per-person, daily and
        // pending limits but not by the minute counter; a manual pick in the same minute still is.
        allow()
        defer { SGTasksCloudRepository.trafficPermission = { _ in .legacy } }
        let harness = try r4Harness()
        var ids: [SGTasksWire.UUID] = []
        var items: [SGTasksWire.Projection] = []
        for index in 0 ..< 20 {
            let id = SGTasksWire.UUID.generate()
            ids.append(id)
            items.append(task(id, title: "Open \(index)"))
        }
        let repository = harness.repository()
        try await harness.bootstrap(repository, items: items)
        let before = try repository.invitationPacerSnapshot().orThrow("snapshot")
        try check(before == .zero, "a fresh store has counters: \(before)")
        for index in 0 ..< 12 {
            try repository.assignTask(id: ids[index], recipient: SGTasksWire.TelegramId(int64: Int64(1000 + index))!, nextAttemptAt: SGTasksInvitationPacer.spacedDate(index: index, sentThisMinute: 0, now: harness.clock))
        }
        try check(repository.state.entries.count == 12, "the paced sends did not all queue: \(repository.state.entries.map { $0.status })")
        let snapshot = try repository.invitationPacerSnapshot().orThrow("snapshot")
        try check(snapshot.today == 12 && snapshot.thisMinute == 12 && snapshot.pending == 12 && snapshot.recipientToday[SGTasksWire.TelegramId(int64: 1000)!] == 1 && snapshot.recipientToday.count == 12, "the snapshot after twelve paced sends: \(snapshot)")
        try expectError(.assignmentLimit(.perMinute)) { try repository.assignTask(id: ids[12], recipient: SGTasksWire.TelegramId(int64: 3000)!) }
        for index in 13 ..< 17 {
            try repository.assignTask(id: ids[index], recipient: otherTg, nextAttemptAt: harness.clock.addingTimeInterval(120))
        }
        try repository.assignTask(id: ids[17], recipient: otherTg, nextAttemptAt: harness.clock.addingTimeInterval(120))
        try expectError(.assignmentLimit(.perPerson)) { try repository.assignTask(id: ids[18], recipient: otherTg, nextAttemptAt: harness.clock.addingTimeInterval(120)) }
        try harness.cloudExecute("UPDATE meta SET value = '95' WHERE key = 'invite_day.\(SGTasksInvitationPacer.dayKey(harness.clock))';")
        try expectError(.assignmentLimit(.total)) { try repository.assignTask(id: ids[18], recipient: SGTasksWire.TelegramId(int64: 4000)!, nextAttemptAt: harness.clock.addingTimeInterval(120)) }
        try check(repository.state.entries.count == 17, "a refused paced send queued something")
        // The due times are the entries' `not_before`: nothing leaves before its slot.
        let due = try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE next_attempt_at > \(Int64(harness.clock.timeIntervalSince1970));")
        try check(due == 7, "the spaced entries do not carry their due time: \(due)")
    }

    // MARK: - The sent set across both logouts (§7.2 item 5, §7.4)

    private static func sentCandidateNeverReturnsAcrossLogouts() async throws {
        let harness = try r4Harness()
        let account: Int64 = 7203
        let defaults = harness.legacyDefaults
        try await run(harness) {
            let (repository, first, second) = try await migratedDevice(harness, account: account)
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            try check(record.state == .completed, "fixture: \(record)")
            let cloudIds = try mapDeviceRows(harness, account: account)
            let firstCloud = try cloudIds[first.id].orThrow("first"), secondCloud = try cloudIds[second.id].orThrow("second")
            let offer = repository.legacyAssigneeOffer()
            try check(offer.candidates.map { $0.cloudTaskId } == [firstCloud, secondCloud] && offer.remaining == 2, "the migrated rows are the candidates: \(offer.candidates.map { $0.title })")
            try check(SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt), hasSendableCandidate: offer.offersSheet), "a completed record with candidates is not due")
            // The sheet's Yuborish for the first row: the sent set first, then the request; the
            // marker says done; `remaining` is rewritten.
            SGTasksLocalMarkers.markLegacySent([firstCloud.rawValue], defaults: defaults, accountPeerId: account)
            try repository.assignTask(id: firstCloud, recipient: otherTg, nextAttemptAt: harness.clock)
            SGTasksLocalMarkers.setLegacyOfferMarker(.done, defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt)
            let afterSend = repository.legacyAssigneeOffer()
            SGTasksLocalMarkers.setUnsentLegacyAssignees(afterSend.remaining, defaults: defaults, accountPeerId: account)
            try check(afterSend.candidates.map { $0.cloudTaskId } == [secondCloud] && SGTasksLocalMarkers.unsentLegacyAssignees(defaults: defaults, accountPeerId: account) == 1, "the sent row did not leave the list at once")
            try check(!SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt), hasSendableCandidate: true), "the sheet is due again after Yuborish")
            try check(TasksLogoutNotice(counts: SGTasksCloudRepository.unsentChangeCounts(accountPeerId: account), unsentAssignees: SGTasksLocalMarkers.unsentLegacyAssignees(defaults: defaults, accountPeerId: account))?.unsentAssignees == 1, "the logout paragraph does not count the row left")
            // The request is acknowledged; the assignee declines: the row reads Rad etdi, not Hali
            // yuborilmagan, and `remaining` is not incremented.
            harness.server.batchScript = [Self.acceptAll]
            await repository.syncNow()
            try check(sentInviteTaskIds(harness) == [firstCloud], "the request did not go out: \(sentInviteTaskIds(harness))")
            let declined = assignment(.declined)
            harness.server.changesScript = [changesPage([upsert(task(firstCloud, title: "QA legacy 1", assignment: declined))], serverWire: 4)]
            await repository.syncNow()
            let declinedOffer = repository.legacyAssigneeOffer()
            try check(declinedOffer.candidates.map { $0.cloudTaskId } == [secondCloud] && declinedOffer.remaining == 1, "the declined legacy assignee came back as a candidate")
            let declinedTask = try repository.state.tasks.first { $0.id == firstCloud }.orThrow("task")
            let display = tasksAssigneeDisplay(task: declinedTask, cloud: repository.state, serverNow: repository.state.estimatedServerNow(), legacyDeviceAssignee: declinedOffer.deviceAssignees[firstCloud.rawValue], isLegacySent: true)
            try check(display?.state == .declined && display?.deviceRowName == "Ali", "the sent and declined row does not read Rad etdi with the device-row name: \(String(describing: display))")
            // The server's detach (the assignment gone from the shadow): still no candidate, no
            // "Hali yuborilmagan" — the row shows "Masʼul / Yoʻq" (pick).
            harness.server.changesScript = [changesPage([upsert(task(firstCloud, title: "QA legacy 1"))], serverWire: 4)]
            await repository.syncNow()
            let detachedTask = try repository.state.tasks.first { $0.id == firstCloud }.orThrow("task")
            try check(detachedTask.assignment == nil && repository.legacyAssigneeOffer().candidates.map { $0.cloudTaskId } == [secondCloud], "the detached legacy assignee came back as a candidate")
            try check(tasksAssigneeDisplay(task: detachedTask, cloud: repository.state, serverNow: nil, legacyDeviceAssignee: declinedOffer.deviceAssignees[firstCloud.rawValue], isLegacySent: true) == nil, "the detached, sent row reads Hali yuborilmagan")
            // Not the last logout: the account store goes, the device database and every key stay.
            repository.stop()
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            try check(SGTasksLocalMarkers.legacySentTaskIds(defaults: defaults, accountPeerId: account) == [firstCloud.rawValue], "the sent set did not survive the non-last logout")
            try check(SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt) == .done && SGTasksLocalMarkers.unsentLegacyAssignees(defaults: defaults, accountPeerId: account) == 1, "the marker or remaining did not survive the non-last logout")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account) == record && harness.legacy.liveTasksWithAssignee().count == 2, "the device database did not survive the non-last logout")
            // Re-login: the snapshot brings both tasks back; the sent one is still not a candidate.
            let relogin = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(relogin, items: [task(firstCloud, title: "QA legacy 1"), task(secondCloud, title: "QA legacy 2")])
            let reloginOffer = relogin.legacyAssigneeOffer()
            try check(reloginOffer.candidates.map { $0.cloudTaskId } == [secondCloud] && reloginOffer.remaining == 1, "after the re-login the sent row came back, or the leftover went")
            try check(!SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt), hasSendableCandidate: true), "the sheet returned after the re-login")
            // The last logout: the device database is wiped and the markers go with it; the manual
            // answers do not.
            defaults.set("{}", forKey: "sgtasks.inviteAnswers.\(account)")
            relogin.stop()
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            harness.legacy.removeAllData()
            let removed = SGTasksLocalMarkers.removeAll(defaults: defaults)
            try check(Set(removed) == ["sgtasks.legacyAssignees.\(account)", "sgtasks.legacyAssignees.remaining.\(account)", "sgtasks.legacyAssignees.sent.\(account)"], "removeAll removed: \(removed)")
            try check(SGTasksLocalMarkers.legacySentTaskIds(defaults: defaults, accountPeerId: account).isEmpty && SGTasksLocalMarkers.unsentLegacyAssignees(defaults: defaults, accountPeerId: account) == 0 && SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt) == nil, "a marker survived the last logout")
            try check(defaults.string(forKey: "sgtasks.inviteAnswers.\(account)") == "{}", "the manual answers did not survive the last logout")
            // The next login has no device rows: no candidate, no sheet, whatever the server sends.
            let fresh = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(fresh, items: [task(firstCloud, title: "QA legacy 1"), task(secondCloud, title: "QA legacy 2")])
            try check(harness.legacy.liveTasksWithAssignee().isEmpty && fresh.legacyAssigneeOffer() == .empty, "device-row candidates survived the last logout")
            try check(TasksLogoutNotice(counts: SGTasksCloudRepository.unsentChangeCounts(accountPeerId: account), unsentAssignees: SGTasksLocalMarkers.unsentLegacyAssignees(defaults: defaults, accountPeerId: account)) == nil, "the logout paragraph names assignees that are gone")
            fresh.stop()
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    // MARK: - Once per record (§7.1, revision 2)

    private static func offeredOncePerRecord() async throws {
        // skipped(existing_mappings): an R3 explicit copy, then consent.
        let harness = try r4Harness()
        let account: Int64 = 7204
        let defaults = harness.legacyDefaults
        try await run(harness) {
            _ = try harness.legacy.createQuickTask(folderId: nil, title: "Eski", inboxTitle: "Inbox", assignee: ali)
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(repository)
            _ = try repository.commitLegacyImport(try repository.prepareLegacyImport())
            let record = try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            try check(record.state == .skipped && record.reason == .existingMappings, "fixture: \(record)")
            let offer = repository.legacyAssigneeOffer()
            try check(offer.remaining == 1, "the explicit copy's mapped row is not a candidate: \(offer)")
            let marker = { SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt) }
            try check(SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: marker(), hasSendableCandidate: offer.offersSheet), "a skipped(existing_mappings) record with mapped device assignees is not offered")
            // Keyinroq: never again for this record, and only when a candidate exists.
            SGTasksLocalMarkers.setLegacyOfferMarker(.later, defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt)
            try check(marker() == .later && !SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: marker(), hasSendableCandidate: true), "the sheet is offered again after Keyinroq")
            try check(!SGTasksLegacyAssigneeOffer.isDue(recordState: .completed, recordReason: nil, marker: nil, hasSendableCandidate: false), "the sheet is offered without a candidate")
            // A new record (another claimedAt): the stored marker is treated as absent.
            try check(SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: record.claimedAt + 1) == nil && SGTasksLegacyAssigneeOffer.isDue(recordState: .completed, recordReason: nil, marker: nil, hasSendableCandidate: true), "a marker of another record blocked the new copy's offer")
            // The other record states never offer.
            for (state, reason) in [(TodoCloudMigrationRecord.State.claimed, nil), (.enqueued, nil), (.released, .withdrawn), (.skipped, .deviceOwnedByOther)] as [(TodoCloudMigrationRecord.State, TodoCloudMigrationRecord.Reason?)] {
                try check(!SGTasksLegacyAssigneeOffer.isDue(recordState: state, recordReason: reason, marker: nil, hasSendableCandidate: true), "\(state) \(String(describing: reason)) offered the sheet")
            }
            try check(!SGTasksLegacyAssigneeOffer.isDue(recordState: nil, recordReason: nil, marker: nil, hasSendableCandidate: true), "no record offered the sheet")
            repository.stop()
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
        // skipped(scope_changed): nothing until rows are mapped in the current scope, then once.
        let scoped = try r4Harness()
        let other: Int64 = 7205
        try await run(scoped) {
            _ = try scoped.legacy.createQuickTask(folderId: nil, title: "Eski", inboxTitle: "Inbox", assignee: ali)
            let repository = SGTasksCloudRepository.repository(accountPeerId: other)
            try await scoped.bootstrap(repository)
            try SGTasksMigration.claimAtConsent(accountPeerId: other, locale: .en, database: scoped.legacy, now: scoped.clock)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .enqueued, "fixture: enqueued")
            // The native account is re-bound to another server account before the copy landed.
            scoped.server.principalValue = principalB
            try await scoped.bootstrap(repository)
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(progress?.state == .skipped && progress?.reason == .scopeChanged, "fixture: \(String(describing: progress))")
            let record = try scoped.legacy.cloudMigrationRecord(accountPeerId: other).orThrow("record")
            try check(record.state == .skipped && record.reason == .scopeChanged, "fixture: \(record)")
            // The old scope's mappings are not the current scope's: no candidate, nothing offered.
            let before = repository.legacyAssigneeOffer()
            try check(before == .empty && !SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: nil, hasSendableCandidate: before.offersSheet), "a scope_changed account was offered its old-scope rows")
            // S6b's explicit copy maps the rows into the new scope: offered once.
            _ = try repository.commitLegacyImport(try repository.prepareLegacyImport())
            let after = repository.legacyAssigneeOffer()
            try check(after.remaining == 1 && SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: SGTasksLocalMarkers.legacyOfferMarker(defaults: scoped.legacyDefaults, accountPeerId: other, claimedAt: record.claimedAt), hasSendableCandidate: after.offersSheet), "the rows mapped in the new scope are not offered")
            SGTasksLocalMarkers.setLegacyOfferMarker(.done, defaults: scoped.legacyDefaults, accountPeerId: other, claimedAt: record.claimedAt)
            try check(!SGTasksLegacyAssigneeOffer.isDue(recordState: record.state, recordReason: record.reason, marker: SGTasksLocalMarkers.legacyOfferMarker(defaults: scoped.legacyDefaults, accountPeerId: other, claimedAt: record.claimedAt), hasSendableCandidate: true), "offered twice")
            repository.stop()
            SGTasksCloudRepository.purgeAccount(accountPeerId: other)
        }
    }

    // MARK: - Annotation-only tasks (§7.2 item 2, §4.1)

    private static func annotationOnlyIsPerTaskOnly() async throws {
        allow()
        defer { SGTasksCloudRepository.trafficPermission = { _ in .legacy } }
        let harness = try r4Harness()
        let account: Int64 = 7206
        let legacy = SGTasksWire.UUID.generate()
        let vali = SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId(int64: 5555)!, displayName: "Vali")
        let repository = harness.repository(account)
        try await harness.bootstrap(repository, items: [task(legacy, title: "Eski yozuv", annotation: vali)])
        // No device rows: no sheet, nothing counted; the task is a per-task candidate.
        let offer = repository.legacyAssigneeOffer()
        try check(offer == .empty && !offer.offersSheet && offer.remaining == 0, "an annotation-only task fed the sheet")
        try check(SGTasksLegacyAssigneeOffer.candidate(forCloudTaskId: legacy, cloud: repository.state, deviceAssignee: nil, sentTaskIds: [], serverNow: nil)?.source == .annotation, "the per-task candidate")
        let display = tasksAssigneeDisplay(task: repository.state.tasks[0], cloud: repository.state, serverNow: nil, legacyDeviceAssignee: nil, isLegacySent: false)
        try check(display?.state == .notSent && display?.annotationName == "Vali", "the editor's Hali yuborilmagan: \(String(describing: display))")
        // The per-task Yuborish: the sent set first, then the request; its receipt chains the clear.
        SGTasksLocalMarkers.markLegacySent([legacy.rawValue], defaults: harness.legacyDefaults, accountPeerId: account)
        try repository.assignTask(id: legacy, recipient: vali.telegramUserId)
        harness.server.batchScript = [Self.acceptAll, Self.acceptAll]
        await repository.syncNow()
        let kinds = harness.server.sentBatches.map { $0.items.map { $0.mutation.kind } }
        try check(kinds.count == 2 && kinds[0] == [.operation(.inviteRequest)] && kinds[1] == [.taskPatch], "the receipt did not chain one task.patch: \(kinds)")
        guard case let .patch(clear) = harness.server.sentBatches[1].items[0].mutation else {
            throw CloudTestFailure.assertion("not a patch")
        }
        try check(clear.patch == SGTasksCloudRepository.annotationClearPatch(taskId: legacy, annotation: vali), "the chained patch is not {set: annotation null, expect: the shadow's annotation}")
        try check(SGTasksLegacyAssigneeOffer.candidate(forCloudTaskId: legacy, cloud: repository.state, deviceAssignee: nil, sentTaskIds: SGTasksLocalMarkers.legacySentTaskIds(defaults: harness.legacyDefaults, accountPeerId: account), serverNow: nil) == nil, "a sent annotation-only task is still a per-task candidate")
    }

    // MARK: - The markers (§7.4)

    /// §7.2 item 3: the confirmation covers the rows shown. The sheet keeps the offer it listed and
    /// intersects it with the offer recomputed at the tap (`confirmedSendable(at:)`), then paces.
    private static func sheetSendsOnlyListedRows() async throws {
        func candidate(_ id: SGTasksWire.UUID, _ title: String, to recipient: SGTasksWire.TelegramId?, isSelf: Bool = false) -> SGTasksLegacyAssigneeCandidate {
            return SGTasksLegacyAssigneeCandidate(cloudTaskId: id, deviceTaskId: "device-\(title)", title: title, name: "Name", recipient: recipient, isSelf: isSelf)
        }
        let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate(), c = SGTasksWire.UUID.generate(), d = SGTasksWire.UUID.generate(), late = SGTasksWire.UUID.generate(), grey = SGTasksWire.UUID.generate()
        let vali = SGTasksWire.TelegramId(int64: 5555)!
        let listed = SGTasksLegacyAssigneeOffer(candidates: [
            candidate(a, "A", to: otherTg), candidate(b, "B", to: otherTg), candidate(c, "C", to: vali), candidate(d, "D", to: otherTg),
            candidate(grey, "Self", to: ownTg, isSelf: true)
        ], deviceAssignees: [:])
        // At the tap: A unchanged; B was assigned from its task meanwhile (no longer a candidate);
        // C's device row now names another person; D unchanged; "Late" became a candidate while the
        // sheet was open (its other assignee declined) and sorts first; the greyed row stays greyed.
        let current = SGTasksLegacyAssigneeOffer(candidates: [
            candidate(late, "Late", to: otherTg), candidate(a, "A", to: otherTg), candidate(c, "C", to: otherTg), candidate(d, "D", to: otherTg),
            candidate(grey, "Self", to: ownTg, isSelf: true)
        ], deviceAssignees: [:])
        let confirmed = listed.confirmedSendable(at: current)
        try check(confirmed.map { $0.cloudTaskId } == [a, d], "the confirmed rows are not the listed, still-current pairs in sheet order: \(confirmed.map { $0.title })")
        try check(!confirmed.contains { $0.cloudTaskId == late }, "a pair the sheet never listed would be sent")
        try check(!confirmed.contains { $0.cloudTaskId == c }, "a row whose recipient changed after it was listed would be sent to the other person")
        try check(listed.confirmedSendable(at: listed).map { $0.cloudTaskId } == [a, b, c, d], "an unchanged offer does not confirm every sendable row")
        try check(listed.confirmedSendable(at: .empty).isEmpty && SGTasksLegacyAssigneeOffer.empty.confirmedSendable(at: current).isEmpty, "an empty side confirmed something")
        // The plan paces the confirmed rows only; its `later` is what the pacer left out, nothing else.
        let now = Date(timeIntervalSince1970: baseTime)
        let plan = SGTasksLegacyAssigneeOffer.plan(sendable: confirmed, snapshot: .zero, now: now)
        try check(plan.sends.map { $0.candidate.cloudTaskId } == [a, d] && plan.later == 0 && !plan.isCapped, "the plan over the confirmed rows: \(plan.sends.map { $0.candidate.title }), later \(plan.later)")
        var usedUp = SGTasksInvitationPacer.Snapshot.zero
        usedUp.recipientToday[otherTg] = 4
        let capped = SGTasksLegacyAssigneeOffer.plan(sendable: confirmed, snapshot: usedUp, now: now)
        try check(capped.sends.map { $0.candidate.cloudTaskId } == [a] && capped.later == 1 && capped.isCapped, "the capped plan: \(capped.sends.map { $0.candidate.title }), later \(capped.later)")
        // What the unfiltered tap-time offer would have sent (the defect): the unlisted pair first.
        try check(current.plan(snapshot: .zero, now: now).sends.first?.candidate.cloudTaskId == late, "the fixture does not reproduce the tap-time recompute")
    }

    private static func localMarkers() async throws {
        let suite = "sgtasks-markers-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account: Int64 = 7207
        try check(SGTasksLocalMarkers.legacyOfferKey(accountPeerId: account) == "sgtasks.legacyAssignees.7207" && SGTasksLocalMarkers.remainingKey(accountPeerId: account) == "sgtasks.legacyAssignees.remaining.7207" && SGTasksLocalMarkers.sentKey(accountPeerId: account) == "sgtasks.legacyAssignees.sent.7207", "the keys")
        try check(SGTasksLocalMarkers.preservedPrefixes == [SGTasksInviteAnswersStore.keyPrefix], "the preserved prefix is not the answers' key prefix")
        // The marker is bound to the record's claimedAt.
        try check(SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: 10) == nil, "a fresh suite has a marker")
        SGTasksLocalMarkers.setLegacyOfferMarker(.later, defaults: defaults, accountPeerId: account, claimedAt: 10)
        try check(defaults.string(forKey: "sgtasks.legacyAssignees.7207") == "10:later", "the stored form")
        try check(SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: 10) == .later && SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: 11) == nil, "the claimedAt binding")
        SGTasksLocalMarkers.setLegacyOfferMarker(.done, defaults: defaults, accountPeerId: account, claimedAt: 11)
        try check(SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: 11) == .done && SGTasksLocalMarkers.legacyOfferMarker(defaults: defaults, accountPeerId: account, claimedAt: 10) == nil, "the new record's marker")
        try check(SGTasksLocalMarkers.parseLegacyOfferMarker("garbage", claimedAt: 1) == nil && SGTasksLocalMarkers.parseLegacyOfferMarker("1:maybe", claimedAt: 1) == nil && SGTasksLocalMarkers.parseLegacyOfferMarker("1:done", claimedAt: 1) == .done, "the parse")
        // remaining: an Int, 0 removes the key.
        SGTasksLocalMarkers.setUnsentLegacyAssignees(2, defaults: defaults, accountPeerId: account)
        try check(SGTasksLocalMarkers.unsentLegacyAssignees(defaults: defaults, accountPeerId: account) == 2 && defaults.integer(forKey: "sgtasks.legacyAssignees.remaining.7207") == 2, "remaining")
        SGTasksLocalMarkers.setUnsentLegacyAssignees(0, defaults: defaults, accountPeerId: account)
        try check(defaults.object(forKey: "sgtasks.legacyAssignees.remaining.7207") == nil && SGTasksLocalMarkers.unsentLegacyAssignees(defaults: defaults, accountPeerId: account) == 0, "remaining 0 keeps a key")
        // The sent set: an array of cloud task ids, de-duplicated; unmark removes one; empty → no key.
        SGTasksLocalMarkers.markLegacySent(["a", "b"], defaults: defaults, accountPeerId: account)
        SGTasksLocalMarkers.markLegacySent(["b", "c"], defaults: defaults, accountPeerId: account)
        try check(defaults.stringArray(forKey: "sgtasks.legacyAssignees.sent.7207") == ["a", "b", "c"] && SGTasksLocalMarkers.legacySentTaskIds(defaults: defaults, accountPeerId: account) == ["a", "b", "c"], "the sent set")
        SGTasksLocalMarkers.unmarkLegacySent("b", defaults: defaults, accountPeerId: account)
        try check(SGTasksLocalMarkers.legacySentTaskIds(defaults: defaults, accountPeerId: account) == ["a", "c"] && SGTasksLocalMarkers.legacySentTaskIds(defaults: defaults, accountPeerId: 1) == [], "unmark, per account")
        SGTasksLocalMarkers.unmarkLegacySent("a", defaults: defaults, accountPeerId: account)
        SGTasksLocalMarkers.unmarkLegacySent("c", defaults: defaults, accountPeerId: account)
        try check(defaults.object(forKey: "sgtasks.legacyAssignees.sent.7207") == nil, "an empty sent set keeps a key")
        // removeAll: every sgtasks.* key of every account except the manual answers; nothing else.
        defaults.set(true, forKey: "sgtasks.assignExplainer.7207")
        defaults.set(true, forKey: "sgtasks.consentPrompted.7207")
        defaults.set(true, forKey: "sgtasks.notice.otherAccount.7208")
        defaults.set(true, forKey: TasksBoardSource.scopeKeysRemovedKey)
        defaults.set(2, forKey: "sgtasks.legacyAssignees.remaining.7208")
        defaults.set(["x"], forKey: "sgtasks.legacyAssignees.sent.7208")
        defaults.set("{}", forKey: SGTasksInviteAnswersStore.key(accountPeerId: account))
        defaults.set("kept", forKey: "sgtasksother")
        defaults.set("kept", forKey: "other.key")
        let removed = SGTasksLocalMarkers.removeAll(defaults: defaults)
        try check(removed == ["sgtasks.assignExplainer.7207", "sgtasks.consentPrompted.7207", "sgtasks.legacyAssignees.7207", "sgtasks.legacyAssignees.remaining.7208", "sgtasks.legacyAssignees.sent.7208", "sgtasks.notice.otherAccount.7208", "sgtasks.scopeKeysRemoved"], "removeAll removed: \(removed)")
        try check(defaults.string(forKey: SGTasksInviteAnswersStore.key(accountPeerId: account)) == "{}" && defaults.string(forKey: "sgtasksother") == "kept" && defaults.string(forKey: "other.key") == "kept", "removeAll took the answers or a foreign key")
        try check(SGTasksLocalMarkers.removeAll(defaults: defaults).isEmpty, "a second sweep found something")
    }
}

private extension TodoTask {
    /// The same row with another creation time (the sheet's order key).
    func withCreated(_ createdAt: Int32) -> TodoTask {
        return TodoTask(id: self.id, folderId: self.folderId, title: self.title, description: self.description, dueAt: self.dueAt, priority: self.priority, isCompleted: self.isCompleted, completedAt: self.completedAt, sortOrder: self.sortOrder, createdDate: createdAt, updatedAt: self.updatedAt, assignee: self.assignee)
    }
}
