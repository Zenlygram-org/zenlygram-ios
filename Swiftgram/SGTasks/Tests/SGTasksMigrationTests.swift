import Foundation
import SGEntitlement
import sqlcipher

// Host tests for the R4 headless migration (design 30 §5.4, §5.5, §5.9): SGTasksMigration, the R4
// rules of SGTasksCloudImport and SGTasksAccountLifecycle, against the real cloud repository, the
// scripted server and a real device database. No `@main`: SGTasksCloudRepositoryTests.main appends
// `cases`. Every case runs `.allowed` (the only permission a step runs under) with its own account
// ids and the harness as the repositories' static environment, and restores the shared statics
// (permission, write fence, analytics sink, test hook, environment) when it ends.

/// A stand-in for the sync coordinator's device-wide fence: while raised, every account's checked
/// local writes answer `.migrating` (`SGTasksSyncPolicy.writeFence`).
private final class RecordingFence: SGTasksMigrationFence {
    private(set) var raised = 0
    private(set) var lowered: [Int64] = []
    private(set) var isRaised = false
    /// Runs inside `lower`, before the fence drops (the record must already be written).
    var onLower: ((Int64) -> Void)?

    func install() {
        TodoStorage.writeFence = { [weak self] _ in (self?.isRaised ?? false) ? .migrating : .open }
    }

    func raise() {
        self.raised += 1
        self.isRaised = true
    }

    func lower(accountPeerId: Int64) {
        self.onLower?(accountPeerId)
        self.isRaised = false
        self.lowered.append(accountPeerId)
    }
}

/// The `tasks.migration` (and `tasks_migration` error) events emitted through SGTasksAnalytics.
private final class MigrationEventLog: @unchecked Sendable {
    struct Migration: Equatable {
        let phase: String
        let lists: Int?
        let tasks: Int?
        let skipped: Int?
        let durationS: Int?
        let errorCode: String?
        let accountPeerId: Int64?
    }

    private let lock = NSLock()
    private var migrationItems: [Migration] = []
    private var errorItems: [(domain: String, code: String)] = []

    func install() {
        SGTasksAnalytics.sink = { [weak self] event, accountPeerId in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            switch event {
            case let .migration(phase, lists, tasks, skipped, durationS, errorCode):
                self.migrationItems.append(Migration(phase: phase, lists: lists, tasks: tasks, skipped: skipped, durationS: durationS, errorCode: errorCode, accountPeerId: accountPeerId))
            case let .error(domain, code) where domain == "tasks_migration":
                self.errorItems.append((domain, code))
            default:
                break
            }
        }
    }

    var migrations: [Migration] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.migrationItems
    }

    var errors: [(domain: String, code: String)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.errorItems
    }
}

enum SGTasksMigrationTests {
    static let cases: [(String, () async throws -> Void)] = [
        ("migration: headless copy — Inbox to the Cloud Inbox, folders to lists, normalized rows, origin migration", happyPath),
        ("migration: a renamed inbox is a real list", renamedInbox),
        ("migration and R4 explicit copy: no create body carries an annotation", noAnnotationInAnyCreate),
        ("migration: a restart mid-enqueue and a rerun reuse the same mutation ids", restartAndRerun),
        ("migration: logout mid-migration, then re-login resumes with the same ids", logoutResume),
        ("cut-over: a completed copy, logout purge, re-login: a readable archive until the snapshot lands", completedCopyLogoutResume),
        ("cut-over: an enqueued copy, logout purge, re-login: a readable archive, retired once confirmed", enqueuedCopyLogoutResume),
        ("migration: a completed copy erased in Cloud while logged out: the new store is re-checked, the rows resent, an archive, not retired", newStoreRecheck),
        ("migration: the voided verification and the store marker survive a restart before the re-check", newStoreRecheckAfterRestart),
        ("lifecycle: invalidateMigrationVerification voids only the account's verifications, nothing else", invalidateVerificationScope),
        ("migration: a rebind to another server account and back re-checks a completed copy against the re-downloaded snapshot", rebindAndBackRecheck),
        ("migration: a rebind away voids the verifications and a return re-checks without an automatic resend into the other scope", rebindAwayVoidsVerification),
        ("migration: copied times are checked against the first enqueue's server time; resends and the explicit copy seal identical bytes", anchoredCopyTimes),
        ("migration: existing mappings skip it and take a free marker as completed", existingMappingsSkip),
        ("migration: claimed at consent before the link, copied once linked", claimBeforeLink),
        ("migration: the first account to consent gets the device rows, whatever the link order", firstConsentWins),
        ("migration: a scope change releases the marker and keeps the mappings", scopeChange),
        ("migration: a failed enqueue (stale snapshot, storage) leaves the claim and a writable board", failedEnqueue),
        ("migration: a withdrawal between mint and enqueue enqueues nothing; a re-grant re-migrates without duplicates", withdrawalRace),
        ("migration: a local write during the step gets .migrating (every account)", localWriteDuringStep),
        ("migration: a late erasure resends acknowledged rows once with the same ids", lateErasure),
        ("lifecycle: retireForConsentWithdrawal discards unsent user changes and releases the claim", retireForWithdrawal),
        ("lifecycle: purgeAfterAccountErasure leaves no record or mapping", purgeAfterErasure),
        ("migration: tasks.migration started / completed / failed are emitted once each", migrationEvents),
        ("lifecycle: the launch re-run of a withdrawal discards on the bare store; no repository is opened", launchRetireOnBareStore),
        ("lifecycle: the bare-store discard creates a missing store and finishes an unfinished purge first", bareRetireOpensTheStoreFirst)
    ]

    // MARK: - Fixtures

    /// Runs `body` as an `.allowed` registry case of `harness`, then restores every shared static.
    private static func run(_ harness: Harness, _ body: () async throws -> Void) async throws {
        let savedEnvironment = SGTasksCloudRepository.environment
        SGTasksCloudRepository.environment = harness.environment
        SGTasksCloudRepository.trafficPermission = { _ in .allowed }
        defer {
            SGTasksCloudRepository.environment = savedEnvironment
            SGTasksCloudRepository.trafficPermission = { _ in .legacy }
            SGTasksCloudRepository.migrationMintedHook = nil
            TodoStorage.writeFence = { _ in .open }
            SGTasksAnalytics.sink = nil
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

    private struct OutboxRow {
        let origin: String
        let state: String
        let request: SGTasksWire.MutationRequest
    }

    private static func outbox(_ harness: Harness, _ account: Int64) throws -> [OutboxRow] {
        var connection: OpaquePointer?
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(connection) }
        guard sqlite3_open_v2(harness.files.path(accountPeerId: account), &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(connection, "SELECT origin, state, body FROM outbox ORDER BY seq;", -1, &statement, nil) == SQLITE_OK else {
            throw CloudTestFailure.assertion("outbox read failed")
        }
        var rows: [OutboxRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let body = Data(bytes: sqlite3_column_blob(statement, 2), count: Int(sqlite3_column_bytes(statement, 2)))
            rows.append(OutboxRow(origin: String(cString: sqlite3_column_text(statement, 0)), state: String(cString: sqlite3_column_text(statement, 1)), request: try SGTasksWire.MutationRequest(wireJSON: body)))
        }
        return rows
    }

    private static func listCreates(_ rows: [OutboxRow]) -> [SGTasksWire.ListCreate] {
        return rows.compactMap { row in
            if case let .listCreate(op) = row.request.operation { return op } else { return nil }
        }
    }

    private static func taskCreates(_ rows: [OutboxRow]) -> [SGTasksWire.TaskCreate] {
        return rows.compactMap { row in
            if case let .taskCreate(op) = row.request.operation { return op } else { return nil }
        }
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

    private static func projection(_ request: SGTasksWire.MutationRequest) -> SGTasksWire.Projection? {
        switch request.operation {
        case let .listCreate(op):
            return .list(SGTasksWire.List(id: op.listId, revision: revision("1"), title: op.title, sortOrder: op.sortOrder, createdAt: instant(), updatedAt: instant(), membersRevision: revision("1")))
        case let .taskCreate(op):
            return .task(SGTasksWire.Task(id: op.taskId, revision: revision("1"), ownerTgId: ownTg, viewerRole: .owner, content: op.content, isCompleted: op.isCompleted, completedAt: op.completedAt, createdAt: instant(), updatedAt: instant(), assignment: nil))
        default:
            return nil
        }
    }

    /// Sends every unacknowledged entry (each batch accepted) and lets the next page prove it: an
    /// upsert of its row, or — for the creates in `absent` (a replayed receipt of a row deleted
    /// since) — its removal. Returns what was sent.
    @discardableResult
    private static func deliver(_ harness: Harness, _ repository: SGTasksCloudRepository, absent: Set<String> = []) async throws -> [SGTasksWire.MutationRequest] {
        let requests = try Self.outbox(harness, repository.accountPeerId).filter { $0.state != "acked" }.map { $0.request }
        var changes: [SGTasksWire.Change] = []
        for (offset, request) in requests.enumerated() {
            let position = "\(100 + offset)"
            if absent.contains(request.mutationId.rawValue) {
                switch request.operation {
                case let .listCreate(op):
                    changes.append(remove(.list(op.listId), at: position))
                case let .taskCreate(op):
                    changes.append(remove(.task(op.taskId), at: position))
                default:
                    break
                }
            } else if let projection = Self.projection(request) {
                changes.append(upsert(projection, at: position))
            }
        }
        harness.server.batchScript = Array(repeating: Self.acceptAll, count: 10)
        harness.server.changesScript = [changesPage([]), changesPage(changes)]
        await repository.syncNow()
        try check(repository.state.entries.isEmpty, "The copy was not delivered and proven: \(repository.state.entries.map { $0.status })")
        return requests
    }

    /// The cut-over the coordinator would compute for `account` (its binding is principal A).
    private static func cutOver(_ harness: Harness, _ account: Int64, ownerActive: Bool = false) throws -> TasksCutOver {
        let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account)
        let unmapped = try harness.legacy.unmappedLiveRowCount(accountPeerId: account, principalScope: record?.principalScope ?? Self.scopeA)
        return TasksCutOver.evaluate(TasksCutOver.Inputs(permission: SGTasksCloudRepository.trafficPermission(account), record: record, currentScope: Self.scopeA, unmappedLiveRows: unmapped, ownerActive: ownerActive))
    }

    /// The cut-over exactly as the sync coordinator computes it for `account` when no other signed-in
    /// account owns the device rows: the production read (`TasksCutOver.Inputs.read`) of the record,
    /// U and I1 from the account's real cloud store, under the gate's P and the binding's S given.
    /// `repository` opens the store read for I1 (default: the registry's instance, as production).
    private static func coordinatorCutOver(_ harness: Harness, _ account: Int64, _ permission: SGTasksSyncPermission, scope: String?, repository: (() -> SGTasksCloudRepository)? = nil) -> TasksCutOver {
        let open = repository ?? {
            return SGTasksCloudRepository.repository(accountPeerId: account)
        }
        return TasksCutOver.evaluate(TasksCutOver.Inputs.read(accountPeerId: account, permission: permission, currentScope: scope, ownerActive: false, database: harness.legacy, repository: open))
    }

    private static func mappingIds(_ harness: Harness, _ account: Int64, scope: String? = nil) throws -> Set<String> {
        return Set(try harness.legacy.existingCloudImportMappings(accountPeerId: account, principalScope: scope ?? Self.scopeA).map { $0.createMutationId })
    }

    /// A meta value of the account's cloud store (nil: absent).
    private static func cloudMeta(_ harness: Harness, _ account: Int64, _ key: String) throws -> String? {
        return try harness.cloudText("SELECT value FROM meta WHERE key = '\(key)';", accountPeerId: account)
    }

    /// Stamps a device row's creation (and completion) time in seconds, as a device clock wrote them.
    private static func stampTask(_ harness: Harness, _ id: String, createdAt: TimeInterval, completedAt: TimeInterval?) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let completion = completedAt.map { "is_completed = 1, completed_at = \(Int64($0))" } ?? "is_completed = 0, completed_at = NULL"
        let sql = "UPDATE tasks SET created_at = \(Int64(createdAt)), \(completion) WHERE id = '\(id)';"
        guard sqlite3_open_v2(harness.directory.appendingPathComponent("legacy.sqlite").path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(connection) == 1 else {
            throw CloudTestFailure.assertion("stamping a device row failed")
        }
    }

    /// One local folder with two tasks, ready for a copy.
    private static func seedSmallDevice(_ legacy: TodoDatabase) throws {
        let work = try legacy.createFolder(title: "Work")
        _ = try legacy.createQuickTask(folderId: work.id, title: "First", inboxTitle: "Inbox")
        _ = try legacy.createQuickTask(folderId: work.id, title: "Second", inboxTitle: "Inbox")
    }

    /// Bootstraps the account, claims at consent and runs the first step (`enqueued`).
    @discardableResult
    private static func migrate(_ harness: Harness, _ account: Int64, fence: RecordingFence? = nil, locale: TodoCloudMigrationRecord.Locale = .en) async throws -> SGTasksCloudRepository {
        let repository = SGTasksCloudRepository.repository(accountPeerId: account)
        if !repository.state.hasCompleteSnapshot {
            try await harness.bootstrap(repository)
        }
        try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: locale, database: harness.legacy, now: harness.clock)
        let progress = try SGTasksMigration.runStep(repository: repository, locale: locale, fence: fence)
        try check(progress?.state == .enqueued, "The first step did not enqueue: \(String(describing: progress))")
        return repository
    }

    // MARK: - Cases

    private static func happyPath() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6101
        let legacy = harness.legacy
        try await run(harness) {
            let events = MigrationEventLog()
            events.install()
            // The device rows: the stable inbox under its default title (→ Cloud Inbox) with a
            // contact assignee and a raw row, a list with an overlong task, an untitled folder.
            let hisobot = try legacy.createQuickTask(folderId: nil, title: "Hisobot", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 123_456_789, displayName: "Ali"), dueAt: 1_792_512_000)
            let raw = legacy.addTask(folderId: TodoStorage.inboxFolderId, title: "  Ish ", description: "", dueAt: -5, priority: 7)
            let work = try legacy.createFolder(title: "Work")
            let longTitle = String(repeating: "a", count: 250)
            let long = legacy.addTask(folderId: work.id, title: longTitle, description: "Batafsil", dueAt: nil, priority: 2)
            legacy.addFolder(title: "\u{200B}")
            let untitled = try legacy.cloudImportSnapshot().folders.first { $0.title == "\u{200B}" }.orThrow("untitled folder")
            let child = legacy.addTask(folderId: untitled.id, title: "Child", description: nil, dueAt: nil, priority: 0)
            let done = try legacy.createQuickTask(folderId: work.id, title: "Done", inboxTitle: "Inbox")
            try legacy.setTaskCompleted(id: done.id, isCompleted: true)
            let originals = legacy.loadTasks()

            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(repository)
            let claimed = try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .uz, database: legacy, now: harness.clock)
            try check(claimed.state == .claimed && claimed.principalScope == nil && claimed.normalizationLocale == .uz, "Consent did not claim the device rows: \(claimed)")
            try check(try legacy.cloudDeviceOwner()?.accountPeerId == account, "The marker is not the account's")

            let fence = RecordingFence()
            fence.install()
            var recordAtLower: TodoCloudMigrationRecord?
            fence.onLower = { _ in recordAtLower = try? legacy.cloudMigrationRecord(accountPeerId: account) }
            // The step's own locale is ignored once the record has one.
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: fence)
            try check(fence.raised == 1 && fence.lowered == [account] && !fence.isRaised, "The local step was not fenced exactly once")
            try check(recordAtLower?.state == .enqueued, "The fence dropped before the record said enqueued")

            let rows = try Self.outbox(harness, account)
            try check(!rows.isEmpty && rows.allSatisfy { $0.origin == "migration" && $0.state == "queued" }, "Not every create is a queued migration create")
            let lists = Self.listCreates(rows)
            let tasks = Self.taskCreates(rows)
            try check(lists.count == 2 && tasks.count == 5 && rows.count == 7, "Unexpected creates: \(lists.count) lists, \(tasks.count) tasks")
            try check(Set(lists.map { $0.title }) == ["Work", "Import qilingan ro\u{02BB}yxat"], "List titles: \(lists.map { $0.title })")
            try check(!lists.contains { $0.title == "Inbox" }, "The default inbox became a list")
            try check(tasks.allSatisfy { $0.content.annotation == nil }, "A migration create carries an annotation")
            let workList = try lists.first { $0.title == "Work" }.orThrow("Work list")
            let placeholderList = try lists.first { $0.title != "Work" }.orThrow("placeholder list")
            let byTitle = Dictionary(tasks.map { ($0.content.title, $0) }, uniquingKeysWith: { first, _ in first })
            let hisobotCreate = try byTitle["Hisobot"].orThrow("Hisobot")
            try check(hisobotCreate.content.listId == nil && hisobotCreate.content.dueAt == 1_792_512_000, "The inbox task did not go to the Cloud Inbox with its deadline")
            let ish = try byTitle["Ish"].orThrow("normalized raw row")
            try check(ish.content.listId == nil && ish.content.description == nil && ish.content.dueAt == nil && ish.content.priority == 4, "The raw row was not normalized: \(ish.content)")
            let cut = try byTitle[String(repeating: "a", count: 199) + "\u{2026}"].orThrow("cut title")
            try check(cut.content.listId == workList.listId && cut.content.description == longTitle + "\n\nBatafsil" && cut.content.priority == 2, "The overlong title lost its full text")
            try check(byTitle["Child"]?.content.listId == placeholderList.listId, "The untitled folder's task is not in its list")
            try check(byTitle["Done"].map { $0.isCompleted && $0.completedAt != nil } == true, "Completion was lost")

            let record = try legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            try check(record.state == .enqueued && record.principalScope == Self.scopeA && record.lists == 2 && record.tasks == 5 && record.keptLocal == 0 && record.enqueuedAt == Int64(harness.clock.timeIntervalSince1970), "Record after the step: \(record)")
            try check(progress == SGTasksMigrationProgress(state: .enqueued, reason: nil, total: 7, done: 0, keptLocal: 0), "Progress after the step: \(String(describing: progress))")
            try check(try Self.cutOver(harness, account) == .archive(.migrating), "An enqueued copy did not make the board read-only")
            // The mapping is the identity of every create.
            try check(Set(rows.map { $0.request.mutationId.rawValue }) == (try Self.mappingIds(harness, account)), "Creates do not use the durable mapping ids")
            try check(legacy.loadTasks() == originals, "The migration changed the local originals")
            try check(originals.contains { $0.id == hisobot.id && $0.assignee?.displayName == "Ali" }, "The local assignee was lost")
            _ = (raw, long, child)

            // Delivered and proven: the copy completes, the marker too; the board retires.
            try await Self.deliver(harness, repository)
            harness.clock = harness.clock.addingTimeInterval(42)
            let completed = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: fence)
            try check(completed == SGTasksMigrationProgress(state: .completed, reason: nil, total: 7, done: 7, keptLocal: 0), "Not completed: \(String(describing: completed))")
            try check(try legacy.cloudDeviceOwner()?.state == .completed, "The marker was not completed")
            try check(try Self.cutOver(harness, account) == .retired, "A confirmed copy did not retire the board")
            try check(fence.raised == 1, "Completion ran a fenced local step")
            // Nothing more happens on a rerun.
            _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: fence)
            try check(try Self.outbox(harness, account).isEmpty && legacy.cloudMigrationRecord(accountPeerId: account)?.state == .completed, "A rerun of a completed copy changed something")
            let phases = events.migrations.map { $0.phase }
            try check(phases == ["started", "completed"], "Migration events: \(phases)")
            try check(events.migrations.last == MigrationEventLog.Migration(phase: "completed", lists: 2, tasks: 5, skipped: 0, durationS: 42, errorCode: nil, accountPeerId: account), "Completed event: \(String(describing: events.migrations.last))")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func renamedInbox() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6102
        try await run(harness) {
            let task = try harness.legacy.createQuickTask(folderId: nil, title: "Mine", inboxTitle: "Inbox")
            try harness.legacy.updateFolderTitle(id: TodoStorage.inboxFolderId, title: "Ishlarim")
            try await Self.migrate(harness, account)
            let rows = try Self.outbox(harness, account)
            let list = try Self.listCreates(rows).first.orThrow("list")
            try check(Self.listCreates(rows).count == 1 && list.title == "Ishlarim", "A renamed inbox is not a list: \(Self.listCreates(rows).map { $0.title })")
            try check(Self.taskCreates(rows).map { $0.content.listId } == [list.listId] && Self.taskCreates(rows).first?.content.title == task.title, "The renamed inbox's task is not in its list")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func noAnnotationInAnyCreate() async throws {
        // The automatic migration and the R4 explicit copy of another device: neither sends a contact.
        for explicit in [false, true] {
            let harness = try r4Harness()
            let account: Int64 = explicit ? 6104 : 6103
            try await run(harness) {
                _ = try harness.legacy.createQuickTask(folderId: nil, title: "Valid contact", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 123_456_789, displayName: "Ali"))
                let work = try harness.legacy.createFolder(title: "Work")
                _ = try harness.legacy.createQuickTask(folderId: work.id, title: "Unconvertible contact", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 8_589_934_597, displayName: "Group"))
                let repository: SGTasksCloudRepository
                if explicit {
                    repository = SGTasksCloudRepository.repository(accountPeerId: account)
                    try await harness.bootstrap(repository)
                    let preview = try repository.prepareLegacyImport(locale: .ru)
                    try check(preview.tasks.allSatisfy { $0.status == .importable }, "An assignee still blocks a task in the R4 copy: \(preview.tasks.map { $0.status })")
                    try check(preview.folders.first { $0.isLegacyInbox }?.status == .alreadyInCloud, "The default inbox is not the Cloud Inbox in the R4 copy")
                    let result = try repository.commitLegacyImport(preview, locale: .ru)
                    try check(result.enqueuedLists == 1 && result.enqueuedTasks == 2 && result.needsCorrection == 0 && result.skippedAlreadyImported == 0, "R4 copy counts: \(result)")
                } else {
                    repository = try await Self.migrate(harness, account)
                }
                let rows = try Self.outbox(harness, account)
                try check(Self.taskCreates(rows).count == 2 && Self.taskCreates(rows).allSatisfy { $0.content.annotation == nil }, "A create carries an annotation (explicit: \(explicit))")
                try check(rows.allSatisfy { $0.origin == (explicit ? "user" : "migration") }, "Wrong origin (explicit: \(explicit))")
                try check(!rows.contains { $0.request.operation.kind == .inviteRequest }, "An assignee became an invitation")
                _ = repository
                SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            }
        }
    }

    private static func restartAndRerun() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6105
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            var repository: SGTasksCloudRepository? = harness.repository(account)
            try await harness.bootstrap(repository!)
            try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            // The step's creates commit, then the process dies before the record update.
            let rules = SGTasksImportRules.r4(SGTasksMigrationNormalizer(locale: .en))
            let epoch = try repository!.consentEpoch().orThrow("epoch")
            let prepared = try repository!.preparedImport(rules: rules)
            _ = try repository!.commitLegacyImport(prepared.preview, rules: rules, origin: .migration, expectedConsentEpoch: epoch, mappedOnly: false)
            let before = try Self.outbox(harness, account).map { $0.request.mutationId }
            try check(before.count == 3 && (try harness.legacy.cloudMigrationRecord(accountPeerId: account))?.state == .claimed, "Fixture: creates without the record update")
            try check(try Self.cutOver(harness, account) == .none, "A claim whose record is not enqueued made the board read-only")
            // Restart: quiesce, release, assert the release (the WAL late-close race), reopen.
            repository!.onQueue {}
            await drainMainQueue()
            let isReleased = { [weak repository] in repository == nil }
            repository = nil
            try check(isReleased(), "The repository (and its SQLite connection) outlived the restart")
            harness.simulateRestart()
            let reopened = harness.repository(account)
            let progress = try SGTasksMigration.runStep(repository: reopened, locale: .en, fence: nil)
            try check(progress?.state == .enqueued && progress?.total == 3, "The rerun did not adopt the creates: \(String(describing: progress))")
            try check(try Self.outbox(harness, account).map { $0.request.mutationId } == before, "The rerun duplicated or changed a create")
            // A further rerun of the enqueued copy adds nothing either.
            _ = try SGTasksMigration.runStep(repository: reopened, locale: .en, fence: nil)
            try check(try Self.outbox(harness, account).map { $0.request.mutationId } == before, "A rerun of an enqueued copy enqueued again")
        }
    }

    private static func logoutResume() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6106
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            try await Self.migrate(harness, account)
            let first = try Self.outbox(harness, account).map { $0.request.mutationId.rawValue }
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account)
            // Telegram logout: the cloud store goes; the record and the mappings stay.
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account) == record && Self.mappingIds(harness, account) == Set(first), "Logout lost the record or the mappings")
            // Re-login: the step re-enqueues the same identities (none was sent).
            let relogged = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(relogged)
            let fence = RecordingFence()
            let progress = try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: fence)
            try check(progress?.state == .enqueued && fence.raised == 1, "The resumed copy was not re-enqueued under the fence")
            let again = try Self.outbox(harness, account)
            try check(again.map { $0.request.mutationId.rawValue } == first && again.allSatisfy { $0.origin == "migration" }, "The re-login did not resend the same ids")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account)?.enqueuedAt == record?.enqueuedAt, "The resume restarted the copy")
            try await Self.deliver(harness, relogged)
            try check(try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: fence)?.state == .completed, "The resumed copy did not complete")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    /// The re-login after a Telegram logout, through the coordinator's production read of the inputs
    /// against the real store and purge. The copy completed; the logout purged the account's cloud
    /// store and kept the record and the mappings. The device rows stay a readable archive (never
    /// `retired`, which would leave only the empty Cloud board) while the account is not linked, while
    /// its snapshot downloads and while its store does not open; the snapshot that brings the copy
    /// back retires the board again, once the step has re-checked the copy against the new store in
    /// place (every row is in it: nothing is resent). A checked store is not re-checked again. The
    /// archive's banner reads the same I1 (`SGTasksMigration.archiveProgress`): the copy is not here
    /// until that re-check.
    private static func completedCopyLogoutResume() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6122
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let repository = try await Self.migrate(harness, account)
            let sent = try await Self.deliver(harness, repository)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "Fixture: the copy did not complete")
            let before = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(before == .retired, "Before the logout: \(before)")
            try check(Self.coordinatorCutOver(harness, account, .waiting, scope: nil) == .retired, "A dropped session flapped")
            // Telegram logout: the store goes; the record and the mappings stay.
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            try check(record.state == .completed, "The record did not survive the logout: \(record)")
            // Re-login, consent agreed, not linked yet: the read opens a new, unbound store.
            harness.server.principalValue = nil
            harness.server.linked = false
            let relogin = Self.coordinatorCutOver(harness, account, .waiting, scope: nil)
            try check(relogin == .archive(.migrating), "Re-login: \(relogin)")
            let unbound = SGTasksCloudRepository.repository(accountPeerId: account).cutOverStoreFacts()
            try check(unbound == TasksCutOver.StoreFacts(boundScope: nil, hasCompleteSnapshot: false, pendingMigrationCreates: 0, migrationChecked: false, resyncGeneration: 0), "The purged store's facts: \(String(describing: unbound))")
            // The board builds the archive from `archiveProgress`: the record's state and I1 (the copy
            // is not in this store), not its counts, say that nothing is being copied here (no
            // "N of N" line, TasksBoardArchive(cutOver:...)) and that the Cloud copy returns.
            let progress = SGTasksMigration.progress(record, repository: SGTasksCloudRepository.repository(accountPeerId: account))
            try check(progress.state == .completed && progress.done == progress.total, "The completed copy's progress: \(progress)")
            let unboundBanner = SGTasksMigration.archiveProgress(record, repository: SGTasksCloudRepository.repository(accountPeerId: account))
            try check(!unboundBanner.copyOnDevice && unboundBanner.progress == progress, "The banner found the copy in the unbound store: \(unboundBanner)")
            // Linked: the first cycle binds the store; its snapshot fails (unscripted).
            harness.server.principalValue = principalA
            harness.server.linked = true
            let relogged = SGTasksCloudRepository.repository(accountPeerId: account)
            await relogged.syncNow()
            try check(try harness.cloudText("SELECT value FROM meta WHERE key = 'principal';", accountPeerId: account) == principalA && !relogged.state.hasCompleteSnapshot, "Fixture: the store is not bound without a snapshot")
            try check(relogged.cutOverStoreFacts() == TasksCutOver.StoreFacts(boundScope: Self.scopeA, hasCompleteSnapshot: false, pendingMigrationCreates: 0, migrationChecked: false, resyncGeneration: 0), "The bound store's facts: \(String(describing: relogged.cutOverStoreFacts()))")
            let downloading = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(downloading == .archive(.migrating), "Bound, the snapshot incomplete: \(downloading)")
            try check(!SGTasksMigration.archiveProgress(record, repository: SGTasksCloudRepository.repository(accountPeerId: account)).copyOnDevice, "The banner found the copy in a store still downloading its snapshot")
            // The snapshot lands (the copy is in it), past the failed pull's backoff. Until the step
            // has checked the copy against this never-checked store the board stays the archive
            // (no step runs while the consent waits for its link, or in a launch's first seconds).
            // The step re-checks it in place: nothing is resent, and the board retires again, also
            // for a later dropped session.
            harness.clock = harness.clock.addingTimeInterval(3600)
            try await harness.bootstrap(relogged, items: sent.compactMap { Self.projection($0) })
            let landed = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(landed == .archive(.migrating), "The snapshot landed, the copy not checked against the new store: \(landed)")
            let landedWaiting = Self.coordinatorCutOver(harness, account, .waiting, scope: nil)
            try check(landedWaiting == .archive(.migrating), "A dropped session before the step checked the copy: \(landedWaiting)")
            // The banner reads the cut-over's own I1: not here until the step has checked the copy.
            try check(!SGTasksMigration.archiveProgress(record, repository: SGTasksCloudRepository.repository(accountPeerId: account)).copyOnDevice, "The banner found the copy in a store the step has not checked")
            let fence = RecordingFence()
            let rechecked = try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: fence)
            try check(rechecked?.state == .completed && fence.raised == 0 && (try Self.outbox(harness, account)).isEmpty, "The re-check of a copy that is in the cloud resent something: \(String(describing: rechecked))")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account)?.verifiedGeneration == 0 && Self.cloudMeta(harness, account, "migration_checked") == "1", "The copy was not verified against the new store")
            let checkedRecord = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            let backBanner = SGTasksMigration.archiveProgress(checkedRecord, repository: SGTasksCloudRepository.repository(accountPeerId: account))
            try check(backBanner.copyOnDevice, "The banner missed the copy the step re-checked in the new store: \(backBanner)")
            let back = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(back == .retired, "The snapshot landed: \(back)")
            try check(Self.coordinatorCutOver(harness, account, .waiting, scope: nil) == .retired, "A dropped session flapped after the copy came back")
            // Checked once: a task the user deletes in Cloud later is removed there, never resent.
            let deletedTask = try sent.compactMap { request -> SGTasksWire.UUID? in
                if case let .taskCreate(op) = request.operation { return op.taskId } else { return nil }
            }.first.orThrow("a copied task")
            harness.server.changesScript = [changesPage([remove(.task(deletedTask))])]
            await relogged.syncNow()
            try check(!relogged.state.tasks.contains { $0.id == deletedTask }, "Fixture: the Cloud deletion did not land")
            _ = try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: fence)
            try check(fence.raised == 0 && (try Self.outbox(harness, account)).isEmpty, "A checked store was re-checked: a row deleted in Cloud was resent")
            // A logout whose purge cannot finish: the store opens as storage-unavailable, no copy here.
            harness.fileSystem.failMove = true
            harness.fileSystem.failStoreRemove = true
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            let fenced = SGTasksCloudRepository.repository(accountPeerId: account)
            try check(fenced.state.phase == .storageUnavailable && fenced.cutOverStoreFacts() == nil, "Fixture: the store opened")
            let unavailable = Self.coordinatorCutOver(harness, account, .waiting, scope: nil)
            try check(unavailable == .archive(.migrating), "Storage unavailable: \(unavailable)")
            try check(!SGTasksMigration.archiveProgress(record, repository: SGTasksCloudRepository.repository(accountPeerId: account)).copyOnDevice, "The banner found the copy in a store that does not open")
            harness.fileSystem.failMove = false
            harness.fileSystem.failStoreRemove = false
            harness.simulateRestart()
            SGTasksCloudRepository.environment = harness.environment
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    /// The same logout while the copy is still queued: its creates went with the store, the record
    /// stays `enqueued`. A readable archive throughout; once linked, the step re-enqueues the creates
    /// (the copy is on the device again, still the archive) and their confirmation retires the board.
    /// The archive's banner has no progress line while the copy is not in the store, and shows it
    /// again from the complete snapshot on.
    private static func enqueuedCopyLogoutResume() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6123
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            try await Self.migrate(harness, account)
            try check(Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA) == .archive(.migrating), "Enqueued before the logout")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            harness.server.principalValue = nil
            harness.server.linked = false
            try check(Self.coordinatorCutOver(harness, account, .waiting, scope: nil) == .archive(.migrating), "Enqueued, purged, re-login")
            // The board's banner over the purged store: its counts alone would read "N of N" (the
            // purged outbox holds none of the queued creates), but the copy is not in this store.
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            try check(record.state == .enqueued, "Fixture: the record is not enqueued: \(record)")
            let archived = SGTasksMigration.archiveProgress(record, repository: SGTasksCloudRepository.repository(accountPeerId: account))
            try check(!archived.copyOnDevice && archived.progress.total > 0 && archived.progress.done == archived.progress.total, "The purged store's banner: \(archived)")
            harness.server.principalValue = principalA
            harness.server.linked = true
            let relogged = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(relogged)
            // The accepted window: a complete snapshot alone counts as the queued copy (I1), so until
            // the step re-enqueues the creates the banner's line can read "N of N".
            let window = SGTasksMigration.archiveProgress(record, repository: relogged)
            try check(window.copyOnDevice && window.progress.done == window.progress.total, "The complete snapshot before the re-enqueue: \(window)")
            try check(try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: nil)?.state == .enqueued, "The copy was not re-enqueued")
            try check(relogged.cutOverStoreFacts() == TasksCutOver.StoreFacts(boundScope: Self.scopeA, hasCompleteSnapshot: true, pendingMigrationCreates: 3, migrationChecked: true, resyncGeneration: 0), "The re-enqueued store's facts: \(String(describing: relogged.cutOverStoreFacts()))")
            try check(Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA) == .archive(.migrating), "Re-enqueued")
            let requeuedRecord = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            let requeued = SGTasksMigration.archiveProgress(requeuedRecord, repository: relogged)
            try check(requeued.copyOnDevice && requeued.progress.done == requeued.progress.total - 3, "The re-enqueued copy's banner: \(requeued)")
            try await Self.deliver(harness, relogged)
            try check(try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: nil)?.state == .completed, "The resumed copy did not complete")
            let done = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(done == .retired, "Confirmed: \(done)")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    /// The account's cloud copy is erased while it is logged out (a withdrawal on another device);
    /// it signs back in, agrees and links the same server account. The new store's snapshot is
    /// complete and empty, and its `resync_generation` reads 0 again like the purged store's, so the
    /// record's verification alone would retire the board without a cloud copy (I1): before the
    /// step the board is the archive, since the store has no `migration_checked`. The step
    /// re-checks the copy against this never-checked store: every row is resent once with its
    /// reserved id and the same bytes, and the board is the archive until they are confirmed.
    private static func newStoreRecheck() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6124
        try await run(harness) {
            let events = MigrationEventLog()
            events.install()
            try Self.seedSmallDevice(harness.legacy)
            let repository = try await Self.migrate(harness, account)
            let first = try harness.outboxBodies(accountPeerId: account)
            try await Self.deliver(harness, repository)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "Fixture: the copy did not complete")
            // Telegram logout: the store goes; the record and the mappings stay.
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            // Re-login: the copy was erased meanwhile; the new store's snapshot is complete and empty.
            let relogged = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(relogged)
            try check(try Self.cloudMeta(harness, account, "migration_checked") == nil && Self.cloudMeta(harness, account, "resync_generation") == nil, "Fixture: the new store is not a fresh one")
            // Before the step: no step runs while the consent waits for its link, or in a launch's
            // first seconds, and the complete snapshot alone proves nothing about the copy.
            let unchecked = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(unchecked == .archive(.migrating), "The board retired on a store the step has not checked: \(unchecked)")
            let uncheckedWaiting = Self.coordinatorCutOver(harness, account, .waiting, scope: nil)
            try check(uncheckedWaiting == .archive(.migrating), "A dropped session retired the board on a store the step has not checked: \(uncheckedWaiting)")
            let facts = relogged.cutOverStoreFacts()
            try check(facts == TasksCutOver.StoreFacts(boundScope: Self.scopeA, hasCompleteSnapshot: true, pendingMigrationCreates: 0, migrationChecked: false, resyncGeneration: 0), "The new store's facts: \(String(describing: facts))")
            let fence = RecordingFence()
            let progress = try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: fence)
            let archived = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(archived == .archive(.migrating), "The board retired without a cloud copy: \(archived)")
            try check(progress?.state == .enqueued && fence.raised == 1, "The new store was not re-checked: \(String(describing: progress))")
            try check(try harness.outboxBodies(accountPeerId: account) == first && Self.outbox(harness, account).allSatisfy { $0.origin == "migration" }, "The copy was not resent with the same ids and bytes")
            try check(try Self.cloudMeta(harness, account, "migration_checked") == "1", "The new store was not marked as checked")
            // Confirmed: verified against this store and retired again, with no second completion.
            try await Self.deliver(harness, relogged)
            try check(try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: fence)?.state == .completed, "The re-checked copy did not complete")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account)?.verifiedGeneration == 0, "The copy is not verified against the new store")
            let retired = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(retired == .retired, "The confirmed copy did not retire the board: \(retired)")
            _ = try SGTasksMigration.runStep(repository: relogged, locale: .en, fence: fence)
            try check(try Self.outbox(harness, account).isEmpty && fence.raised == 1, "A checked store was checked again")
            try check(events.migrations.map { $0.phase } == ["started", "completed"] && events.errors.isEmpty, "Migration events: \(events.migrations.map { $0.phase })")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    /// The step voided the verifications recorded against the purged store and marked the new one,
    /// then the process died before its re-check: both writes are durable, so the next step of the
    /// next process still re-checks the copy (against the marked store, without voiding again). The
    /// mark alone retires nothing: until that re-check the voided verification keeps the archive.
    private static func newStoreRecheckAfterRestart() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6126
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            var repository: SGTasksCloudRepository? = harness.repository(account)
            try await harness.bootstrap(repository!)
            try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            try check(try SGTasksMigration.runStep(repository: repository!, locale: .en, fence: nil)?.state == .enqueued, "Fixture: the copy was not enqueued")
            let first = try harness.outboxBodies(accountPeerId: account)
            try await Self.deliver(harness, repository!)
            try check(try SGTasksMigration.runStep(repository: repository!, locale: .en, fence: nil)?.state == .completed, "Fixture: the copy did not complete")
            // Logout: the instance goes, then its store; the record and the mappings stay.
            repository!.onQueue {}
            await drainMainQueue()
            let isReleased = { [weak repository] in repository == nil }
            repository = nil
            try check(isReleased(), "The repository (and its SQLite connection) outlived the logout")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            try check(!harness.files.storeExists(accountPeerId: account), "Fixture: the store survived the logout")
            // Re-login in a new process; the copy was erased meanwhile (a complete, empty snapshot).
            harness.simulateRestart()
            var relogged: SGTasksCloudRepository? = harness.repository(account)
            try await harness.bootstrap(relogged!)
            // The step's first two writes land, then the process dies.
            try harness.legacy.invalidateMigrationVerification(accountPeerId: account)
            try relogged!.markMigrationChecked()
            relogged!.onQueue {}
            await drainMainQueue()
            let isGone = { [weak relogged] in relogged == nil }
            relogged = nil
            try check(isGone(), "The repository (and its SQLite connection) outlived the restart")
            harness.simulateRestart()
            let reopened = harness.repository(account)
            try check(reopened.state.hasCompleteSnapshot && Self.cloudMeta(harness, account, "migration_checked") == "1", "Fixture: the marked store did not reopen complete")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account)?.verifiedGeneration == -1, "The voided verification did not survive the restart")
            // Read through the instance under test: marked, not re-checked yet.
            let marked = Self.coordinatorCutOver(harness, account, .waiting, scope: nil, repository: { reopened })
            try check(marked == .archive(.migrating), "The marked store retired the board before the re-check: \(marked)")
            let markedLinked = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA, repository: { reopened })
            try check(markedLinked == .archive(.migrating), "The marked, linked store retired the board before the re-check: \(markedLinked)")
            let progress = try SGTasksMigration.runStep(repository: reopened, locale: .en, fence: nil)
            try check(progress?.state == .enqueued && (try harness.outboxBodies(accountPeerId: account)) == first, "The marked store's copy was not re-checked after the restart: \(String(describing: progress))")
        }
    }

    /// `invalidateMigrationVerification` (a new store) voids only the account's own verifications:
    /// its record and the attempt rows of its mappings go to -1; states, mappings, acknowledgements
    /// and every other account stay as they were. Idempotent.
    private static func invalidateVerificationScope() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6127
        let other: Int64 = 6128
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let legacy = harness.legacy
            let snapshot = try legacy.cloudImportSnapshot()
            for owner in [account, other] {
                let ids = try legacy.cloudImportMappings(for: snapshot, accountPeerId: owner, principalScope: Self.scopeA) {
                    (cloudId: SGTasksWire.UUID.generate().rawValue, mutationId: SGTasksWire.UUID.generate().rawValue)
                }.map { $0.createMutationId }
                for id in ids {
                    try legacy.recordCloudImportAttempt(createMutationId: id, acknowledged: false)
                }
                try legacy.markImportReverified(mutationIds: ids, generation: 3)
                for id in ids {
                    try legacy.recordCloudImportAttempt(createMutationId: id, acknowledged: true)
                }
                try legacy.setCloudMigrationRecord(TodoCloudMigrationRecord(accountPeerId: owner, state: .completed, principalScope: Self.scopeA, normalizationLocale: .en, claimedAt: 1, enqueuedAt: 2, completedAt: 3, verifiedGeneration: 3, lists: 1, tasks: 2))
            }
            let before = try legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            let otherRecord = try legacy.cloudMigrationRecord(accountPeerId: other)
            let otherMappings = try legacy.existingCloudImportMappings(accountPeerId: other, principalScope: Self.scopeA)
            try check(otherMappings.count == 3 && otherMappings.allSatisfy { $0.isAcknowledged && $0.verifiedGeneration == 3 }, "Fixture: the other account's verifications")
            for _ in 0 ..< 2 {
                try legacy.invalidateMigrationVerification(accountPeerId: account)
                var expected = before
                expected.verifiedGeneration = -1
                try check(try legacy.cloudMigrationRecord(accountPeerId: account) == expected, "The record changed beyond its verification")
                let mappings = try legacy.existingCloudImportMappings(accountPeerId: account, principalScope: Self.scopeA)
                try check(mappings.count == 3 && mappings.allSatisfy { $0.wasAttempted && $0.isAcknowledged && $0.verifiedGeneration == -1 }, "The attempt rows were not voided alone: \(mappings)")
                try check(try legacy.cloudMigrationRecord(accountPeerId: other) == otherRecord && legacy.existingCloudImportMappings(accountPeerId: other, principalScope: Self.scopeA) == otherMappings, "Another account's verifications were touched")
            }
        }
    }

    /// The store is rebound to another server account (B) and back (A) with no step while B was
    /// bound. The rebind drops `migration_checked` with the rest of the earlier account's state, so
    /// the completed copy is checked again against A's re-downloaded snapshot: erased meanwhile (a
    /// complete, empty snapshot), every row is resent once with its reserved id and the same bytes,
    /// and the board is the archive until they are confirmed.
    private static func rebindAndBackRecheck() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6129
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let repository = try await Self.migrate(harness, account)
            let first = try harness.outboxBodies(accountPeerId: account)
            try await Self.deliver(harness, repository)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "Fixture: the copy did not complete")
            try check(try Self.cloudMeta(harness, account, "migration_checked") == "1", "Fixture: the store is not checked")
            // Rebound to B; no step runs while B is bound.
            harness.server.principalValue = principalB
            try await harness.bootstrap(repository)
            try check(try Self.cloudMeta(harness, account, "migration_checked") == nil, "The rebind kept the store's check against the earlier server account")
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            try check(record.state == .completed && record.principalScope == Self.scopeA && record.verifiedGeneration == 0, "The rebind changed the record: \(record)")
            let onB = Self.coordinatorCutOver(harness, account, .allowed, scope: SGTasksCloudRepository.importScope(origin: originX, principal: principalB))
            try check(onB == .none, "The board under another server account: \(onB)")
            // Back to A, whose copy was erased meanwhile: a complete, empty snapshot.
            harness.server.principalValue = principalA
            try await harness.bootstrap(repository)
            try check(try Self.cloudMeta(harness, account, "migration_checked") == nil, "The return to A carries a check")
            let back = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(back == .archive(.migrating), "The board retired on the re-downloaded snapshot before the re-check: \(back)")
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(progress?.state == .enqueued, "The copy was not re-checked against the re-downloaded snapshot: \(String(describing: progress))")
            try check(try harness.outboxBodies(accountPeerId: account) == first && Self.outbox(harness, account).allSatisfy { $0.origin == "migration" }, "The copy was not resent with the same ids and bytes")
            try check(try Self.cloudMeta(harness, account, "migration_checked") == "1", "The rebound store was not marked as checked")
            // Confirmed: verified against the re-downloaded snapshot and retired again.
            try await Self.deliver(harness, repository)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "The re-checked copy did not complete")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account)?.verifiedGeneration == 0, "The copy is not verified against the re-downloaded snapshot")
            let retired = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(retired == .retired, "The confirmed copy did not retire the board: \(retired)")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    /// The first step on a store rebound to another server account (B) voids the verifications (its
    /// mark died with the rebind) before it finds that the copy belongs to A: the record becomes
    /// `skipped(scope_changed)` at -1 and the attempt rows of the account's mappings go to -1 too.
    /// Back on A, nothing is resent automatically (a skipped record has no copy to check), and the
    /// explicit copy offers the acknowledged rows missing from A's snapshot as resends, whose
    /// immutable receipts the server would replay (nothing reappears).
    private static func rebindAwayVoidsVerification() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6130
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let repository = try await Self.migrate(harness, account)
            try await Self.deliver(harness, repository)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "Fixture: the copy did not complete")
            // Rebound to B, and a step there.
            harness.server.principalValue = principalB
            try await harness.bootstrap(repository)
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(progress?.state == .skipped && progress?.reason == .scopeChanged, "The rebind did not skip the copy: \(String(describing: progress))")
            try check(try Self.cloudMeta(harness, account, "migration_checked") == "1", "The step did not mark the rebound store")
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            try check(record.verifiedGeneration == -1 && record.principalScope == Self.scopeA, "The step on the rebound store did not void the record's verification: \(record)")
            let mappings = try harness.legacy.existingCloudImportMappings(accountPeerId: account, principalScope: Self.scopeA)
            try check(mappings.count == 3 && mappings.allSatisfy { $0.isAcknowledged && $0.verifiedGeneration == -1 }, "The attempt rows were not voided: \(mappings)")
            // Back to A, whose copy was erased meanwhile: a complete, empty snapshot.
            harness.server.principalValue = principalA
            try await harness.bootstrap(repository)
            try check(try Self.cloudMeta(harness, account, "migration_checked") == nil, "The return to A kept the check against B")
            let back = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(back == .none, "A skipped copy's board: \(back)")
            let skipped = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(skipped?.state == .skipped && (try Self.outbox(harness, account)).isEmpty, "The return resent the copy automatically: \(String(describing: skipped))")
            let preview = try repository.prepareLegacyImport()
            let folders = preview.folders.filter { !$0.isLegacyInbox }
            let statuses = folders.map { $0.status } + preview.tasks.map { $0.status }
            try check(folders.count == 1 && preview.tasks.count == 2 && statuses.allSatisfy { $0 == .resendPreviousAttempt }, "The explicit copy does not offer the absent acknowledged rows as resends: \(statuses)")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    /// The copy's created_at/completed_at are checked against its first enqueue's server time
    /// (§7.1), never against a moving "now". The device clock runs an hour ahead of the server, so one
    /// row carries times 400 s and 500 s past the server's when the first step runs: both go as null
    /// (the server stamps its own) and the record keeps the server's time of that enqueue, not the
    /// device's. Hours later a late erasure makes the step resend the copy: identical bytes, although
    /// those times are long past by then. The explicit copy in the migration's scope checks against
    /// the same first enqueue, so the re-check rebuilds its row byte for byte too.
    private static func anchoredCopyTimes() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6125
        try await run(harness) {
            // Every server answer says baseTime; the device clock reads an hour later.
            harness.clock = harness.clock.addingTimeInterval(3600)
            let work = try harness.legacy.createFolder(title: "Work")
            let ahead = try harness.legacy.createQuickTask(folderId: work.id, title: "Ahead", inboxTitle: "Inbox")
            let earlier = try harness.legacy.createQuickTask(folderId: work.id, title: "Earlier", inboxTitle: "Inbox")
            try Self.stampTask(harness, ahead.id, createdAt: baseTime + 400, completedAt: baseTime + 500)
            try Self.stampTask(harness, earlier.id, createdAt: baseTime - 100, completedAt: nil)
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(repository)
            // No copy of this account yet: the explicit copy keeps its own rule (the server's now).
            try check(repository.explicitImportRules(locale: .ru) == .r4(SGTasksMigrationNormalizer(locale: .ru), normalizedAt: nil), "The explicit copy took a time base without a migration")
            try await Self.migrate(harness, account)
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account).orThrow("record")
            try check(record.enqueuedAt == Int64(baseTime), "The first enqueue's time is not the server's: \(String(describing: record.enqueuedAt))")
            let first = try harness.outboxBodies(accountPeerId: account)
            let creates = Self.taskCreates(try Self.outbox(harness, account))
            let aheadCreate = try creates.first { $0.content.title == "Ahead" }.orThrow("Ahead")
            try check(aheadCreate.isCompleted && aheadCreate.createdAt == nil && aheadCreate.completedAt == nil, "Times past the server's +300 s were sent: \(aheadCreate)")
            try check(creates.first { $0.content.title == "Earlier" }?.createdAt == instant(-100), "A valid creation time was lost")
            try await Self.deliver(harness, repository)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "Fixture: the copy did not complete")
            // The explicit copy in the migration's scope checks against the same first enqueue.
            try check(repository.explicitImportRules(locale: .ru) == .r4(SGTasksMigrationNormalizer(locale: .en), normalizedAt: Date(timeIntervalSince1970: baseTime)), "The explicit copy does not use the migration's time base")
            harness.clock = harness.clock.addingTimeInterval(1000)
            let later = try harness.legacy.createQuickTask(folderId: work.id, title: "Later", inboxTitle: "Inbox")
            try Self.stampTask(harness, later.id, createdAt: baseTime + 400, completedAt: nil)
            let explicit = try repository.commitLegacyImport(try repository.prepareLegacyImport(locale: .ru), locale: .ru)
            try check(explicit.enqueuedLists == 0 && explicit.enqueuedTasks == 1, "The explicit copy fixture: \(explicit)")
            let explicitBodies = try harness.outboxBodies(accountPeerId: account)
            try check(Self.taskCreates(try Self.outbox(harness, account)).map { $0.createdAt } == [nil], "The explicit copy checked its row against a moving now")
            try await Self.deliver(harness, repository)
            // Hours on, a late erasure: 409, then a complete, empty snapshot at the server's later time.
            harness.clock = harness.clock.addingTimeInterval(6200)
            harness.server.changesScript = [failure(.resyncRequired)]
            harness.server.snapshotScript = [.success(SGTasksWire.SnapshotResponse(items: [], nextCursor: nil, changesCursor: cursor("c-erased"), serverTime: instant(7200), serverWire: 4))]
            await repository.syncNow()
            try check(try Self.cloudMeta(harness, account, "resync_generation") == "1" && repository.state.hasCompleteSnapshot, "Fixture: no resync with a complete snapshot")
            let serverNow = try repository.state.estimatedServerNow(localNow: harness.clock).orThrow("server time")
            try check(serverNow == Date(timeIntervalSince1970: baseTime + 7200), "Fixture: the server's time did not move on: \(serverNow)")
            // The resend-once rebuilds every row of the copy's scope byte for byte, the explicit one too.
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(progress?.state == .enqueued && (try harness.legacy.cloudMigrationRecord(accountPeerId: account))?.enqueuedAt == Int64(baseTime), "The late erasure did not resend the copy: \(String(describing: progress))")
            let resent = try harness.outboxBodies(accountPeerId: account)
            try check(resent.count == first.count + explicitBodies.count && Set(resent) == Set(first + explicitBodies), "A resend did not rebuild identical bytes")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func existingMappingsSkip() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6107
        let other: Int64 = 6108
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(repository)
            _ = try repository.commitLegacyImport(try repository.prepareLegacyImport())
            let explicit = try Self.outbox(harness, account)
            try check(explicit.count == 3 && explicit.allSatisfy { $0.origin == "user" }, "The explicit copy fixture")
            let record = try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            try check(record.state == .skipped && record.reason == .existingMappings, "Existing mappings did not skip the migration: \(record)")
            let owner = try harness.legacy.cloudDeviceOwner()
            try check(owner?.accountPeerId == account && owner?.state == .completed, "The free marker was not taken as completed: \(String(describing: owner))")
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(progress?.state == .skipped && (try Self.outbox(harness, account).count) == 3, "A skipped account copied the rows again")
            // The device rows now belong to that account: a second account gets none of them.
            let second = try SGTasksMigration.claimAtConsent(accountPeerId: other, locale: .en, database: harness.legacy, now: harness.clock)
            try check(second.state == .skipped && second.reason == .deviceOwnedByOther, "A second account claimed explicitly copied rows")
            try check(try Self.cutOver(harness, account) == .none, "A skipped account's board became read-only")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
        // A marker someone else holds stays theirs.
        let busy = try r4Harness()
        try await run(busy) {
            try Self.seedSmallDevice(busy.legacy)
            try busy.legacy.claimCloudDevice(accountPeerId: other)
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await busy.bootstrap(repository)
            _ = try repository.commitLegacyImport(try repository.prepareLegacyImport())
            let record = try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: busy.legacy, now: busy.clock)
            try check(record.reason == .existingMappings && (try busy.legacy.cloudDeviceOwner())?.accountPeerId == other, "Existing mappings took another account's marker")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func claimBeforeLink() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6109
        try await run(harness) {
            let events = MigrationEventLog()
            events.install()
            try Self.seedSmallDevice(harness.legacy)
            harness.server.linked = false
            harness.server.principalValue = nil
            let claimed = try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .ru, database: harness.legacy, now: harness.clock)
            try check(claimed.state == .claimed && claimed.principalScope == nil, "No consent-time claim before the link")
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try expectError(.notLinked) { _ = try SGTasksMigration.runStep(repository: repository, locale: .ru, fence: nil) }
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account) == claimed && Self.outbox(harness, account).isEmpty, "A step before the link changed something")
            try check(try Self.cutOver(harness, account) == .none, "The board is read-only before anything was copied")
            // Linked: the claim gets its scope and the rows are copied.
            harness.server.linked = true
            harness.server.principalValue = principalA
            try await harness.bootstrap(repository)
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(progress?.state == .enqueued && (try harness.legacy.cloudMigrationRecord(accountPeerId: account))?.principalScope == Self.scopeA, "The linked claim was not copied")
            try check(events.migrations.map { $0.phase } == ["started"] && events.errors.isEmpty, "A not-linked step counted as a failure: \(events.migrations)")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func firstConsentWins() async throws {
        let harness = try r4Harness()
        let first: Int64 = 6110
        let second: Int64 = 6111
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            // Consent: first, then second. Link: second, then first.
            try check(try SGTasksMigration.claimAtConsent(accountPeerId: first, locale: .en, database: harness.legacy, now: harness.clock).state == .claimed, "The first consent did not claim")
            let secondRecord = try SGTasksMigration.claimAtConsent(accountPeerId: second, locale: .en, database: harness.legacy, now: harness.clock)
            try check(secondRecord.state == .skipped && secondRecord.reason == .deviceOwnedByOther, "The second consent took the rows")
            let secondRepository = SGTasksCloudRepository.repository(accountPeerId: second)
            try await harness.bootstrap(secondRepository)
            try check(try SGTasksMigration.runStep(repository: secondRepository, locale: .en, fence: nil)?.state == .skipped && Self.outbox(harness, second).isEmpty, "The account that linked first copied the rows")
            try await Self.migrate(harness, first)
            try check(try Self.outbox(harness, first).count == 3 && harness.legacy.cloudDeviceOwner()?.accountPeerId == first, "The first account to consent did not get the rows")
            // The second account's board shows the other account's archive while it is active.
            try check(try Self.cutOver(harness, second, ownerActive: true) == .archive(.otherAccount), "The other account's copy did not make the board read-only")
            try check(try Self.cutOver(harness, second, ownerActive: false) == .none, "The board stayed read-only with the owner gone")
            SGTasksCloudRepository.purgeAccount(accountPeerId: first)
            SGTasksCloudRepository.purgeAccount(accountPeerId: second)
        }
    }

    private static func scopeChange() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6112
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let repository = try await Self.migrate(harness, account)
            let mappingsA = try Self.mappingIds(harness, account)
            // The native account is re-bound to another server account.
            harness.server.principalValue = principalB
            try await harness.bootstrap(repository)
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(progress?.state == .skipped && progress?.reason == .scopeChanged, "A scope change did not skip the copy: \(String(describing: progress))")
            let owner = try harness.legacy.cloudDeviceOwner()
            try check(owner?.state == .released && owner?.releaseReason == "scope_changed", "The marker was not released")
            try check(try Self.mappingIds(harness, account) == mappingsA, "The old scope's mappings were not kept")
            try check(try Self.cutOver(harness, account) == .none, "A scope change left the board read-only")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func failedEnqueue() async throws {
        // A stale snapshot: the server account changes between the mint and the enqueue.
        let harness = try r4Harness()
        let account: Int64 = 6113
        try await run(harness) {
            let events = MigrationEventLog()
            events.install()
            try Self.seedSmallDevice(harness.legacy)
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(repository)
            try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            SGTasksCloudRepository.migrationMintedHook = { _ in harness.server.principalValue = principalB }
            let fence = RecordingFence()
            fence.install()
            try expectError(.importSnapshotStale) { _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: fence) }
            SGTasksCloudRepository.migrationMintedHook = nil
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account)?.state == .claimed, "A failed enqueue moved the record")
            try check(!fence.isRaised && fence.lowered == [account], "A failed step left the fence up")
            try check(try Self.cutOver(harness, account) == .none, "A failed enqueue made the board read-only")
            _ = try harness.legacy.createQuickTask(folderId: nil, title: "Still writable", inboxTitle: "Inbox", asAccount: account)
            try check(try Self.outbox(harness, account).filter { $0.origin == "migration" }.isEmpty, "A failed enqueue left migration creates")
            try check(events.migrations.map { $0.phase } == ["started", "failed"] && events.migrations.last?.errorCode == "unknown" && events.errors.map { $0.code } == ["unknown"], "Failure events: \(events.migrations)")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
        // A storage failure of the enqueue itself; the rerun reuses the minted ids.
        let storage = try r4Harness()
        let storageAccount: Int64 = 6114
        try await run(storage) {
            try Self.seedSmallDevice(storage.legacy)
            let repository = SGTasksCloudRepository.repository(accountPeerId: storageAccount)
            try await storage.bootstrap(repository)
            try SGTasksMigration.claimAtConsent(accountPeerId: storageAccount, locale: .en, database: storage.legacy, now: storage.clock)
            SGTasksCloudRepository.migrationMintedHook = { _ in
                try? storage.cloudExecute("CREATE TRIGGER refuse_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'refused'); END;", accountPeerId: storageAccount)
            }
            try expectError(.storageUnavailable) { _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil) }
            SGTasksCloudRepository.migrationMintedHook = nil
            try check(try storage.legacy.cloudMigrationRecord(accountPeerId: storageAccount)?.state == .claimed, "A storage failure moved the record")
            let minted = try Self.mappingIds(storage, storageAccount)
            try storage.cloudExecute("DROP TRIGGER refuse_outbox;", accountPeerId: storageAccount)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .enqueued, "The rerun after a storage failure did not enqueue")
            try check(Set(try Self.outbox(storage, storageAccount).map { $0.request.mutationId.rawValue }) == minted, "The rerun minted new identities")
            SGTasksCloudRepository.purgeAccount(accountPeerId: storageAccount)
        }
    }

    private static func withdrawalRace() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6115
        try await run(harness) {
            let events = MigrationEventLog()
            events.install()
            try Self.seedSmallDevice(harness.legacy)
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(repository)
            try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            var discarded: Int??
            // The withdrawal lands after the step captured its epoch and minted its mappings.
            SGTasksCloudRepository.migrationMintedHook = { _ in
                discarded = SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId: account)
            }
            try expectError(.consentWithdrawn) { _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil) }
            SGTasksCloudRepository.migrationMintedHook = nil
            try check(discarded == .some(.some(0)), "The withdrawal did not run inside the step")
            try check(try Self.outbox(harness, account).isEmpty, "A withdrawal racing the step let creates in")
            let released = try harness.legacy.cloudMigrationRecord(accountPeerId: account)
            try check(released?.state == .released && released?.reason == .withdrawn, "The record is not released(withdrawn): \(String(describing: released))")
            try check(try harness.legacy.cloudDeviceOwner() == nil && !harness.legacy.hasCloudImportMapping(accountPeerId: account), "A never-enqueued claim kept its marker or mappings")
            try check(events.errors.isEmpty && !events.migrations.contains { $0.phase == "failed" }, "A withdrawal counted as a failed step")
            // Re-grant: the gate is back; the next consent claim takes the rows again, once.
            repository.resumeAfterConsentRegrant()
            try await harness.bootstrap(repository)
            try check(try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock).state == .claimed, "The re-grant did not re-claim")
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .enqueued, "The re-grant did not re-migrate")
            let rows = try Self.outbox(harness, account)
            try check(rows.count == 3 && Set(rows.map { $0.request.mutationId }).count == 3, "The re-migration duplicated a row: \(rows.count)")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func localWriteDuringStep() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6116
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let fence = RecordingFence()
            fence.install()
            var refusals: [TodoDatabaseError] = []
            SGTasksCloudRepository.migrationMintedHook = { _ in
                for writer in [account, 9_999] {
                    do {
                        _ = try harness.legacy.createQuickTask(folderId: nil, title: "Late", inboxTitle: "Inbox", asAccount: writer)
                    } catch let error as TodoDatabaseError {
                        refusals.append(error)
                    } catch {}
                }
                do {
                    _ = try TodoStorage.createFolder(title: "Late", asAccount: account)
                } catch let error as TodoDatabaseError {
                    refusals.append(error)
                } catch {}
            }
            try await Self.migrate(harness, account, fence: fence)
            try check(refusals == [.migrating, .migrating, .migrating], "A write during the step was not refused with .migrating: \(refusals)")
            try check(!harness.legacy.loadTasks().contains { $0.title == "Late" }, "A write slipped in during the step")
            try check(try Self.outbox(harness, account).count == 3, "The step did not copy the snapshot rows")
            // The fence is down again: an unfenced write works (the coordinator's cut-over archives it).
            _ = try harness.legacy.createQuickTask(folderId: nil, title: "After", inboxTitle: "Inbox", asAccount: account)
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func lateErasure() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6117
        try await run(harness) {
            let events = MigrationEventLog()
            events.install()
            try Self.seedSmallDevice(harness.legacy)
            let repository = try await Self.migrate(harness, account)
            let sent = try await Self.deliver(harness, repository)
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .completed, "Fixture: the first copy did not complete")
            let ids = sent.map { $0.mutationId.rawValue }
            // The account's cloud data is erased later; the next catch-up answers 409 resync and the
            // complete resnapshot is empty.
            harness.server.changesScript = [failure(.resyncRequired)]
            harness.server.snapshotScript = [.success(SGTasksWire.SnapshotResponse(items: [], nextCursor: nil, changesCursor: cursor("c-erased"), serverTime: instant(), serverWire: 4))]
            await repository.syncNow()
            try check(try harness.cloudText("SELECT value FROM meta WHERE key = 'resync_generation';", accountPeerId: account) == "1" && repository.state.hasCompleteSnapshot, "Fixture: no resync with a complete snapshot")
            // A 409 since the completion: the copy was checked at generation 0, the store is at 1.
            // Until the step has re-checked it there, the board is the archive, never `retired`.
            let resynced = Self.coordinatorCutOver(harness, account, .waiting, scope: nil)
            try check(resynced == .archive(.migrating), "The board stayed retired after a 409 before the re-check: \(resynced)")
            let resyncedLinked = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(resyncedLinked == .archive(.migrating), "The linked board stayed retired after a 409 before the re-check: \(resyncedLinked)")
            // The first absence never retires the board: the rows are resent once, same ids.
            let fence = RecordingFence()
            let progress = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: fence)
            try check(progress?.state == .enqueued && fence.raised == 1, "The late erasure did not send the copy back to enqueued: \(String(describing: progress))")
            try check(try Self.cutOver(harness, account) == .archive(.migrating), "The board retired on the first absence")
            let resent = try Self.outbox(harness, account)
            try check(resent.map { $0.request.mutationId.rawValue } == ids && resent.allSatisfy { $0.origin == "migration" }, "The resend did not reuse the same ids")
            // The server replays the receipts of the list and one task (deleted by the user since) and
            // executes the other task anew.
            let replayed = Set(sent.filter { request in
                if case let .taskCreate(op) = request.operation { return op.content.title == "First" } else { return true }
            }.map { $0.mutationId.rawValue })
            try await Self.deliver(harness, repository, absent: replayed)
            let mappings = try harness.legacy.existingCloudImportMappings(accountPeerId: account, principalScope: Self.scopeA)
            try check(mappings.allSatisfy { $0.isAcknowledged && $0.verifiedGeneration == 1 }, "The resent rows were not re-verified at generation 1")
            // Verified at this generation: the replayed rows are removed, the fresh one is in the cloud.
            let completed = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: fence)
            try check(completed?.state == .completed && (try harness.legacy.cloudMigrationRecord(accountPeerId: account))?.verifiedGeneration == 1, "The re-check did not complete at generation 1")
            let rechecked = Self.coordinatorCutOver(harness, account, .allowed, scope: Self.scopeA)
            try check(rechecked == .retired, "The copy re-checked at generation 1 did not retire the board: \(rechecked)")
            let preview = try repository.prepareLegacyImport()
            try check(preview.tasks.filter { $0.status == .removedFromCloud }.map { $0.title } == ["First"] && preview.tasks.filter { $0.status == .alreadyInCloud }.map { $0.title } == ["Second"], "Statuses after the resend: \(preview.tasks.map { ($0.title, $0.status) })")
            // Never resent twice: a rerun sends nothing.
            _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: fence)
            try check(try Self.outbox(harness, account).isEmpty && fence.raised == 1, "A replayed row was resent a second time")
            try check(events.migrations.filter { $0.phase == "completed" }.count == 1, "The re-check emitted a second completion")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func retireForWithdrawal() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6118
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            let repository = try await Self.migrate(harness, account)
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Unsent one"))
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Unsent two"))
            let counts = SGTasksCloudRepository.unsentChangeCounts(accountPeerId: account)
            try check(counts?.user == 2 && counts?.migration == 3, "Fixture counts: \(String(describing: counts))")
            repository.startDriving()
            let discarded = SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId: account)
            try check(discarded == 2, "The discarded user changes: \(String(describing: discarded))")
            // The account's repository is open: the discard went through it (board, flag, driver).
            try check(SGTasksCloudRepository.hasLiveRepository(accountPeerId: account) && repository.state.entries.isEmpty, "The open repository's board kept the discarded changes: \(repository.state.entries.map { $0.status })")
            try check(!repository.onQueue({ repository.isDriven }), "The open repository is still driven after the withdrawal")
            try expectError(.consentWithdrawn) { _ = try repository.createTask(SGTasksCloudTaskDraft(title: "After")) }
            try check(try Self.outbox(harness, account).isEmpty, "An unsent row survived the withdrawal")
            let record = try harness.legacy.cloudMigrationRecord(accountPeerId: account)
            try check(record?.state == .released && record?.reason == .withdrawn && record?.enqueuedAt != nil, "The record is not released(withdrawn): \(String(describing: record))")
            let owner = try harness.legacy.cloudDeviceOwner()
            try check(owner?.state == .released && owner?.releaseReason == "withdrawn", "An enqueued owner was not released")
            try check(try !harness.legacy.hasCloudImportMapping(accountPeerId: account), "The mappings were not voided")
            try check(try Self.cutOver(harness, account) == .none, "The device board is not writable after the withdrawal")
            _ = try harness.legacy.createQuickTask(folderId: nil, title: "Writable", inboxTitle: "Inbox", asAccount: account)
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    private static func purgeAfterErasure() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6119
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            try await Self.migrate(harness, account)
            SGTasksCloudRepository.purgeAfterAccountErasure(accountPeerId: account)
            try check(!harness.files.storeExists(accountPeerId: account), "The cloud store survived the erasure")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account) == nil && !harness.legacy.hasCloudImportMapping(accountPeerId: account), "A record or mapping survived the erasure")
            let owner = try harness.legacy.cloudDeviceOwner()
            try check(owner?.state == .released && owner?.releaseReason == "erased", "An enqueued owner was not released as erased")
            try check(harness.legacy.loadTasks().count == 2, "The erasure touched the local rows")
        }
        // Nothing enqueued yet: the marker is free again.
        let fresh = try r4Harness()
        let other: Int64 = 6120
        try await run(fresh) {
            try SGTasksMigration.claimAtConsent(accountPeerId: other, locale: .en, database: fresh.legacy, now: fresh.clock)
            SGTasksCloudRepository.purgeAfterAccountErasure(accountPeerId: other)
            try check(try fresh.legacy.cloudDeviceOwner() == nil && fresh.legacy.cloudMigrationRecord(accountPeerId: other) == nil, "A never-enqueued claim survived the erasure")
        }
    }

    /// The account ids `migrationDidChangeNotification` carried (posted on the main queue).
    private final class MigrationChangeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int64?] = []

        func append(_ accountPeerId: Int64?) {
            self.lock.lock()
            self.items.append(accountPeerId)
            self.lock.unlock()
        }

        var accountPeerIds: [Int64?] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.items
        }
    }

    /// The launch re-run of a withdrawal (design 40 §6.6): an earlier process copied the device rows,
    /// queued edits and was fenced; this one has opened no repository of the account. The retire
    /// discards on the bare store and opens none; a repository opened later reads the withdrawal
    /// and refuses every insert until the re-grant resumes.
    private static func launchRetireOnBareStore() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6140
        try await run(harness) {
            try Self.seedSmallDevice(harness.legacy)
            // The earlier process, on an instance of its own (never the registry's).
            var earlier: SGTasksCloudRepository? = harness.repository(account)
            try await harness.bootstrap(earlier!)
            try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            let progress = try SGTasksMigration.runStep(repository: earlier!, locale: .en, fence: nil)
            try check(progress?.state == .enqueued, "Fixture: the first step did not enqueue: \(String(describing: progress))")
            _ = try earlier!.createTask(SGTasksCloudTaskDraft(title: "Unsent one"))
            _ = try earlier!.createTask(SGTasksCloudTaskDraft(title: "Unsent two"))
            // That process ended: nothing of it in flight, its connection closed.
            earlier!.onQueue {}
            await drainMainQueue()
            let isEarlierReleased = { [weak earlier] in earlier == nil }
            earlier = nil
            try check(isEarlierReleased(), "Fixture: the earlier process's repository (and its SQLite connection) outlived it")
            // The server had fenced it.
            try harness.cloudExecute("INSERT OR REPLACE INTO meta (key, value) VALUES ('consent_fenced_until', '\(baseTime + 60)'), ('consent_fence_delay', '60'), ('consent_fenced_effective_at', '2026-10-31T10:00:00Z');", accountPeerId: account)
            let rows = try Self.outbox(harness, account)
            try check(rows.count == 5 && rows.filter { $0.origin == "user" }.count == 2 && rows.allSatisfy { $0.state == "queued" }, "Fixture: the outbox is not 3 queued creates and 2 user changes")
            let enqueued = try harness.legacy.cloudMigrationRecord(accountPeerId: account)
            try check(try harness.legacy.hasCloudImportMapping(accountPeerId: account) && enqueued?.state == .enqueued && enqueued?.enqueuedAt != nil, "Fixture: no enqueued record with mappings")

            // The launch: a new process, no repository of the account in it.
            harness.simulateRestart()
            SGTasksCloudRepository.environment = harness.environment
            let changes = MigrationChangeLog()
            let observer = harness.notificationCenter.addObserver(forName: SGTasksCloudRepository.migrationDidChangeNotification, object: nil, queue: nil) { notification in
                changes.append(notification.userInfo?["accountPeerId"] as? Int64)
            }
            defer { harness.notificationCenter.removeObserver(observer) }
            try check(!SGTasksCloudRepository.hasLiveRepository(accountPeerId: account), "Fixture: a repository of the account is open at launch")
            let discarded = SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId: account)
            try check(!SGTasksCloudRepository.hasLiveRepository(accountPeerId: account), "The launch retire opened the account's repository")
            try check(discarded == 2, "The discarded user changes: \(String(describing: discarded))")
            // The TRUNCATE checkpoint and closing the only connection folded the WAL: no file, or an
            // empty one where the SQLite build keeps the WAL file (the host's platform SQLite does).
            let wal = harness.files.path(accountPeerId: account) + "-wal"
            let walBytes = ((try? FileManager.default.attributesOfItem(atPath: wal))?[.size] as? NSNumber)?.intValue
            try check(walBytes == nil || walBytes == 0, "The discard left \(walBytes ?? 0) bytes in the WAL")
            try check(try Self.outbox(harness, account).isEmpty, "An unsent row survived the withdrawal")
            try check(try Self.cloudMeta(harness, account, "consent_withdrawn") == "1" && Self.cloudMeta(harness, account, "consent_epoch") == "1", "The withdrawal was not recorded in the store")
            for key in ["consent_fenced_until", "consent_fence_delay", "consent_fenced_effective_at"] {
                try check(try Self.cloudMeta(harness, account, key) == nil, "The consent fence survived the withdrawal: \(key)")
            }
            let released = try harness.legacy.cloudMigrationRecord(accountPeerId: account)
            try check(released?.state == .released && released?.reason == .withdrawn && released?.enqueuedAt == enqueued?.enqueuedAt, "The record is not released(withdrawn) with its enqueue time: \(String(describing: released))")
            let owner = try harness.legacy.cloudDeviceOwner()
            try check(owner?.state == .released && owner?.releaseReason == "withdrawn", "An enqueued owner was not released")
            try check(try !harness.legacy.hasCloudImportMapping(accountPeerId: account), "The mappings were not voided")
            await drainMainQueue()
            try check(changes.accountPeerIds == [account], "The claim change was not posted once: \(changes.accountPeerIds)")

            // The next launch re-runs it: nothing to discard, still no repository, the epoch bumped.
            harness.simulateRestart()
            SGTasksCloudRepository.environment = harness.environment
            try check(SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId: account) == 0, "The repeated retire found something to discard")
            try check(!SGTasksCloudRepository.hasLiveRepository(accountPeerId: account), "The repeated retire opened the account's repository")
            try check(try Self.cloudMeta(harness, account, "consent_epoch") == "2" && Self.cloudMeta(harness, account, "consent_withdrawn") == "1", "The repeated retire did not bump the epoch")
            try check(try harness.legacy.cloudMigrationRecord(accountPeerId: account) == released, "The repeated retire changed the record")
            await drainMainQueue()
            try check(changes.accountPeerIds == [account, account], "The repeated retire was not posted once: \(changes.accountPeerIds)")

            // A repository opened later reads the withdrawal: no insert until the re-grant resumes.
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try check(repository.onQueue({ repository.isConsentWithdrawn }), "A repository opened after the bare discard did not read the withdrawal")
            try expectError(.consentWithdrawn) { _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Refused")) }
            repository.resumeAfterConsentRegrant()
            try check(try Self.cloudMeta(harness, account, "consent_withdrawn") == nil && Self.cloudMeta(harness, account, "needs_resnapshot") == "1", "The re-grant did not resume with a resnapshot")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }

    /// The bare-store discard opens the store as a repository does: an unfinished purge completes
    /// before anything in the store is read, and a missing store is created with the withdrawal.
    private static func bareRetireOpensTheStoreFirst() async throws {
        // An earlier process's logout purge could not finish (its marker stays): the retire finishes
        // it first, so the purged store's change is never read or counted.
        let harness = try r4Harness()
        let account: Int64 = 6142
        try await run(harness) {
            var earlier: SGTasksCloudRepository? = harness.repository(account)
            try await harness.bootstrap(earlier!)
            _ = try earlier!.createTask(SGTasksCloudTaskDraft(title: "Before the logout"))
            earlier!.onQueue {}
            await drainMainQueue()
            let isEarlierReleased = { [weak earlier] in earlier == nil }
            earlier = nil
            try check(isEarlierReleased(), "Fixture: the earlier process's repository (and its SQLite connection) outlived it")
            harness.fileSystem.failMove = true
            harness.fileSystem.failStoreRemove = true
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
            harness.fileSystem.failMove = false
            harness.fileSystem.failStoreRemove = false
            harness.simulateRestart()
            SGTasksCloudRepository.environment = harness.environment
            try check(harness.files.hasPendingPurge(accountPeerId: account) && harness.files.storeExists(accountPeerId: account), "Fixture: the purge did not stay unfinished")
            let discarded = SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId: account)
            let pending = harness.files.hasPendingPurge(accountPeerId: account)
            try check(!SGTasksCloudRepository.hasLiveRepository(accountPeerId: account), "The retire opened the account's repository")
            try check(discarded == 0, "The retire read the purged store: \(String(describing: discarded)) discarded, purge still pending: \(pending)")
            try check(!pending, "The unfinished purge was not completed before the open")
            try check(try Self.outbox(harness, account).isEmpty && Self.cloudMeta(harness, account, "consent_withdrawn") == "1", "The store after the purge is not an empty, withdrawn one")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
        // No store yet (consent claimed, nothing synced): it is created with the withdrawal.
        let fresh = try r4Harness()
        let other: Int64 = 6141
        try await run(fresh) {
            try SGTasksMigration.claimAtConsent(accountPeerId: other, locale: .en, database: fresh.legacy, now: fresh.clock)
            try check(!fresh.files.storeExists(accountPeerId: other), "Fixture: the account has a store")
            let discarded = SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId: other)
            try check(!SGTasksCloudRepository.hasLiveRepository(accountPeerId: other), "The retire opened the account's repository")
            try check(discarded == 0, "A new store had changes to discard: \(String(describing: discarded))")
            try check(try fresh.files.storeExists(accountPeerId: other) && Self.cloudMeta(fresh, other, "consent_withdrawn") == "1", "The missing store was not created with the withdrawal")
            let record = try fresh.legacy.cloudMigrationRecord(accountPeerId: other)
            try check(try fresh.legacy.cloudDeviceOwner() == nil && record?.state == .released && record?.reason == .withdrawn, "The never-enqueued claim was not freed and released(withdrawn): \(String(describing: record))")
            SGTasksCloudRepository.purgeAccount(accountPeerId: other)
        }
    }

    private static func migrationEvents() async throws {
        let harness = try r4Harness()
        let account: Int64 = 6121
        try await run(harness) {
            let events = MigrationEventLog()
            events.install()
            try Self.seedSmallDevice(harness.legacy)
            let repository = SGTasksCloudRepository.repository(accountPeerId: account)
            try await harness.bootstrap(repository)
            try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            try SGTasksMigration.claimAtConsent(accountPeerId: account, locale: .en, database: harness.legacy, now: harness.clock)
            // A device database that cannot be read fails the step.
            let good = harness.legacy
            harness.legacy = TodoDatabase(dbPath: harness.directory.appendingPathComponent("missing/legacy.sqlite").path, defaults: harness.legacyDefaults)
            do {
                _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
                throw CloudTestFailure.assertion("An unreadable device database did not fail the step")
            } catch is TodoDatabaseError {
            }
            harness.legacy = good
            try check(events.migrations.map { $0.phase } == ["started", "failed"] && events.migrations[1].errorCode?.hasPrefix("sqlite_") == true, "Failure event: \(events.migrations)")
            try check(events.errors.count == 1 && events.errors[0].code == events.migrations[1].errorCode, "The failure has no tasks_migration error")
            try check(events.migrations.allSatisfy { $0.accountPeerId == account }, "An event lost its account")
            try check(try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)?.state == .enqueued, "The rerun did not enqueue")
            try await Self.deliver(harness, repository)
            _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            _ = try SGTasksMigration.runStep(repository: repository, locale: .en, fence: nil)
            try check(events.migrations.map { $0.phase } == ["started", "failed", "completed"], "Events: \(events.migrations.map { $0.phase })")
            let completed = events.migrations[2]
            try check(completed.lists == 1 && completed.tasks == 2 && completed.skipped == 0 && completed.durationS == 0 && completed.errorCode == nil, "Completed event: \(completed)")
            SGTasksCloudRepository.purgeAccount(accountPeerId: account)
        }
    }
}
