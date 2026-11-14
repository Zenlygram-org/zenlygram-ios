import Foundation

// Host tests for the cut-over table (Sources/SGTasksCutOver.swift, design 30 §7.5), every row, the
// I1 facts of the account's own copy on this device (`isOwnCopyOnDevice`; a confirmed copy only once
// the migration step has checked it against the store at its generation), and the device archive's
// banner for a cut-over (`TasksBoardArchive(cutOver:...)`, Sources/TasksBoardSource.swift). What the
// coordinator reads from the device database and the store (SGTasksCutOver+Inputs.swift) runs against
// the real repository in run-cloud-tests.sh. No `@main`: SGTasksSyncPolicyTests.main runs `cases`
// after its own.

enum SGTasksCutOverTests {
    static let cases: [(String, () throws -> Void)] = [
        ("cut-over row 1: legacy and forbidden leave the board writable, whatever the record", row1PermissionWithoutConsent),
        ("cut-over row 2: a claim under another server account leaves the board writable", row2ScopeChanged),
        ("cut-over row 3: enqueued is read-only with progress (waiting too, unbound session too)", row3Enqueued),
        ("cut-over rows 4/5: completed with its copy here retires the board, or keeps the archive for new rows", row4And5Completed),
        ("cut-over row 4: a completed copy no longer on this device (logout purge) stays a readable archive", row4WithoutOwnCopy),
        ("cut-over: never retired without the own copy; that input changes nothing else", neverRetiredWithoutOwnCopy),
        ("cut-over I1: the own copy is here only in a store bound to its scope, complete or holding its creates", ownCopyFacts),
        ("cut-over I1: a completed copy counts only once the step has checked it against this store at its generation", ownCopyCheckedAtGeneration),
        ("cut-over I1: the store is read only for an account with consent and a copy", ownCopyReadOnlyWhenNeeded),
        ("cut-over: logout purge, re-login, link, snapshot: a readable archive until the copy is back", logoutPurgeSequence),
        ("archive banner: a completed copy claims no copying; a queued one with its copy in this store keeps its progress", archiveProgressLine),
        ("archive banner: a copy not in this account's store shows no progress and says it returns; nothing else changes", archiveCopyNotOnDevice),
        ("cut-over row 6: another signed-in account's copy makes the board read-only", row6OtherAccount),
        ("cut-over row 7: nothing copied yet, the owner gone or not copied: writable", row7Writable),
        ("cut-over: only archive and retired are read-only", readOnlyFlag)
    ]

    private static let scopeA = "scope-a"
    private static let scopeB = "scope-b"

    private static func record(_ state: TodoCloudMigrationRecord.State, scope: String? = Self.scopeA, reason: TodoCloudMigrationRecord.Reason? = nil, verified: Int64 = 0) -> TodoCloudMigrationRecord {
        return TodoCloudMigrationRecord(accountPeerId: 7, state: state, reason: reason, principalScope: scope, normalizationLocale: .en, claimedAt: 1_700_000_000, enqueuedAt: state == .enqueued || state == .completed ? 1_700_000_100 : nil, completedAt: state == .completed ? 1_700_000_200 : nil, verifiedGeneration: verified, lists: 2, tasks: 5)
    }

    private static func cutOver(_ permission: SGTasksSyncPermission, _ record: TodoCloudMigrationRecord?, scope: String? = Self.scopeA, unmapped: Int = 0, ownerActive: Bool = false, ownCopy: Bool = true) -> TasksCutOver {
        return TasksCutOver.evaluate(TasksCutOver.Inputs(permission: permission, record: record, currentScope: scope, unmappedLiveRows: unmapped, ownerActive: ownerActive, ownCopyOnDevice: ownCopy))
    }

    /// A store the migration step has checked at generation 0 unless told otherwise.
    private static func store(_ boundScope: String?, complete: Bool, pending: Int = 0, checked: Bool = true, generation: Int64 = 0) -> TasksCutOver.StoreFacts {
        return TasksCutOver.StoreFacts(boundScope: boundScope, hasCompleteSnapshot: complete, pendingMigrationCreates: pending, migrationChecked: checked, resyncGeneration: generation)
    }

    private static func expect(_ actual: TasksCutOver, _ expected: TasksCutOver, _ message: String) throws {
        if actual != expected {
            throw PolicyTestFailure.assertion("\(message): \(actual), expected \(expected)")
        }
    }

    private static func row1PermissionWithoutConsent() throws {
        for permission in [SGTasksSyncPermission.legacy, .forbidden] {
            for state in [TodoCloudMigrationRecord.State.claimed, .enqueued, .completed, .released, .skipped] {
                try expect(cutOver(permission, record(state), unmapped: 3, ownerActive: true), .none, "\(permission) with \(state)")
            }
            try expect(cutOver(permission, nil, ownerActive: true), .none, "\(permission) with another active owner")
        }
    }

    private static func row2ScopeChanged() throws {
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            for state in [TodoCloudMigrationRecord.State.claimed, .enqueued, .completed] {
                try expect(cutOver(permission, record(state, scope: Self.scopeA), scope: Self.scopeB, ownerActive: true), .none, "\(permission) \(state) on another scope")
            }
        }
        // No current binding (S = nil) is not a scope change: the enqueued copy stays the archive.
        try expect(cutOver(.waiting, record(.enqueued), scope: nil), .archive(.migrating), "an unbound session flapped the archive")
        // A consent-time claim (scope nil) is not a scope change either.
        try expect(cutOver(.allowed, record(.claimed, scope: nil), scope: Self.scopeB), .none, "a consent-time claim")
    }

    private static func row3Enqueued() throws {
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            try expect(cutOver(permission, record(.enqueued)), .archive(.migrating), "\(permission) enqueued")
            try expect(cutOver(permission, record(.enqueued), unmapped: 4, ownerActive: true), .archive(.migrating), "\(permission) enqueued with rows and an owner")
        }
    }

    private static func row4And5Completed() throws {
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            try expect(cutOver(permission, record(.completed), unmapped: 0), .retired, "\(permission) completed, nothing new")
            try expect(cutOver(permission, record(.completed), unmapped: 3), .archive(.newRows(3)), "\(permission) completed with new rows")
            try expect(cutOver(permission, record(.completed), scope: nil, unmapped: 1), .archive(.newRows(1)), "\(permission) completed, unbound now")
        }
    }

    /// The re-login after a Telegram logout: the record and the mappings survived, the account's cloud
    /// store did not. Consent agreed but not linked yet (P waiting, S nil) — or linked with the
    /// snapshot still downloading — the device rows must stay reachable: never `retired` (that hides
    /// the scope switch and leaves only the empty Cloud board).
    private static func row4WithoutOwnCopy() throws {
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            for scope in [nil, Self.scopeA] as [String?] {
                let label = "\(permission), S \(scope ?? "nil")"
                try expect(cutOver(permission, record(.completed), scope: scope, unmapped: 0, ownCopy: false), .archive(.migrating), "\(label): completed without the copy")
                try expect(cutOver(permission, record(.completed), scope: scope, unmapped: 2, ownCopy: false), .archive(.newRows(2)), "\(label): completed with new rows, without the copy")
                try expect(cutOver(permission, record(.enqueued), scope: scope, ownCopy: false), .archive(.migrating), "\(label): enqueued without its queued creates")
                try expect(cutOver(permission, record(.completed), scope: scope, unmapped: 0, ownCopy: true), .retired, "\(label): completed with the copy back")
            }
        }
    }

    /// Every combination: without the own copy the board is never hidden, and the input changes only
    /// row 4 (`retired` → the readable archive).
    private static func neverRetiredWithoutOwnCopy() throws {
        let states: [TodoCloudMigrationRecord.State] = [.claimed, .enqueued, .completed, .released, .skipped]
        let records: [TodoCloudMigrationRecord?] = [nil] + states.flatMap { [record($0), record($0, scope: nil)] }
        for permission in [SGTasksSyncPermission.legacy, .forbidden, .waiting, .allowed] {
            for record in records {
                for scope in [nil, Self.scopeA, Self.scopeB] as [String?] {
                    for unmapped in [0, 3] {
                        for ownerActive in [false, true] {
                            let label = "\(permission), \(record.map { "\($0.state) \($0.principalScope ?? "nil")" } ?? "no record"), S \(scope ?? "nil"), U \(unmapped), owner \(ownerActive)"
                            let present = cutOver(permission, record, scope: scope, unmapped: unmapped, ownerActive: ownerActive, ownCopy: true)
                            let absent = cutOver(permission, record, scope: scope, unmapped: unmapped, ownerActive: ownerActive, ownCopy: false)
                            try check(absent != .retired, "retired without the own copy: \(label)")
                            try expect(absent, present == .retired ? .archive(.migrating) : present, label)
                        }
                    }
                }
            }
        }
    }

    private static func ownCopyFacts() throws {
        for state in [TodoCloudMigrationRecord.State.enqueued, .completed] {
            try check(TasksCutOver.isOwnCopyOnDevice(record: record(state), store: store(Self.scopeA, complete: true)), "\(state): a complete snapshot of the record's scope is not the copy")
            try check(TasksCutOver.isOwnCopyOnDevice(record: record(state), store: store(Self.scopeA, complete: false, pending: 4)), "\(state): the copy's queued creates are not the copy")
            try check(!TasksCutOver.isOwnCopyOnDevice(record: record(state), store: store(Self.scopeA, complete: false)), "\(state): a store still downloading its snapshot holds the copy")
            try check(!TasksCutOver.isOwnCopyOnDevice(record: record(state), store: store(nil, complete: false)), "\(state): the empty store a logout purge leaves holds the copy")
            try check(!TasksCutOver.isOwnCopyOnDevice(record: record(state), store: nil), "\(state): a store that does not open holds the copy")
            try check(!TasksCutOver.isOwnCopyOnDevice(record: record(state), store: store(Self.scopeB, complete: true, pending: 4)), "\(state): another server account's store holds the copy")
            try check(!TasksCutOver.isOwnCopyOnDevice(record: record(state, scope: nil), store: store(Self.scopeA, complete: true)), "\(state): a record without a scope names a copy")
        }
        for state in [TodoCloudMigrationRecord.State.claimed, .released, .skipped] {
            try check(!TasksCutOver.isOwnCopyOnDevice(record: record(state), store: store(Self.scopeA, complete: true, pending: 4)), "\(state) has a copy")
        }
        try check(!TasksCutOver.isOwnCopyOnDevice(record: nil, store: store(Self.scopeA, complete: true, pending: 4)), "no record has a copy")
    }

    /// A confirmed copy is in this store only once the migration step has checked it there at the
    /// store's current generation: the exact complement of the step's re-check (no
    /// `migration_checked`, or the record verified at an older `resync_generation`). A new store, a
    /// verification voided by a new store or a rebind (-1) and a 409 since the completion read as
    /// "not here". A queued copy is here by its snapshot or its creates, checked or not.
    private static func ownCopyCheckedAtGeneration() throws {
        try check(!TasksCutOver.isOwnCopyOnDevice(record: record(.completed), store: store(Self.scopeA, complete: true, checked: false)), "completed: a store the step has not checked holds the copy")
        try check(!TasksCutOver.isOwnCopyOnDevice(record: record(.completed, verified: 0), store: store(Self.scopeA, complete: true, generation: 1)), "completed: a copy checked before a 409 is still here")
        try check(!TasksCutOver.isOwnCopyOnDevice(record: record(.completed, verified: -1), store: store(Self.scopeA, complete: true)), "completed: a voided verification counts as checked here")
        try check(TasksCutOver.isOwnCopyOnDevice(record: record(.completed, verified: 2), store: store(Self.scopeA, complete: true, generation: 2)), "completed: a copy checked at the store's generation is not here")
        try check(TasksCutOver.isOwnCopyOnDevice(record: record(.enqueued), store: store(Self.scopeA, complete: true, checked: false)), "enqueued: an unchecked store hides the queued copy")
        try check(TasksCutOver.isOwnCopyOnDevice(record: record(.enqueued, verified: -1), store: store(Self.scopeA, complete: true)), "enqueued: a voided verification hides the queued copy")
        try check(TasksCutOver.isOwnCopyOnDevice(record: record(.enqueued, verified: -1), store: store(Self.scopeA, complete: false, pending: 3, checked: false, generation: 1)), "enqueued: its queued creates in an unchecked store are not the copy")
        // The check never stands in for the store's own facts.
        try check(!TasksCutOver.isOwnCopyOnDevice(record: record(.completed, verified: 2), store: store(Self.scopeA, complete: false, generation: 2)), "completed: a checked store still downloading its snapshot holds the copy")
        try check(!TasksCutOver.isOwnCopyOnDevice(record: record(.completed, verified: 2), store: store(Self.scopeB, complete: true, generation: 2)), "completed: another server account's checked store holds the copy")
    }

    /// The coordinator's entry: reading the store opens the account's repository, so it happens only
    /// for P waiting/allowed with an enqueued/completed record, exactly once; the answer is then the
    /// facts' I1. Every other account has no copy here, whatever its store would say.
    private static func ownCopyReadOnlyWhenNeeded() throws {
        let records: [TodoCloudMigrationRecord?] = [nil, record(.claimed), record(.enqueued), record(.completed), record(.released), record(.skipped), record(.completed, scope: nil)]
        let facts: [TasksCutOver.StoreFacts?] = [store(Self.scopeA, complete: true), store(Self.scopeA, complete: false, pending: 3), store(Self.scopeA, complete: false), store(nil, complete: false), store(Self.scopeB, complete: true), store(Self.scopeA, complete: true, checked: false), store(Self.scopeA, complete: true, generation: 1), nil]
        for permission in [SGTasksSyncPermission.legacy, .forbidden, .waiting, .allowed] {
            for record in records {
                for fact in facts {
                    let label = "\(permission), \(record.map { "\($0.state) \($0.principalScope ?? "nil")" } ?? "no record"), \(fact.map { "\($0)" } ?? "no store")"
                    let needed = (permission == .waiting || permission == .allowed) && (record?.state == .enqueued || record?.state == .completed)
                    var reads = 0
                    let ownCopy = TasksCutOver.isOwnCopyOnDevice(permission: permission, record: record, readStore: {
                        reads += 1
                        return fact
                    })
                    try check(reads == (needed ? 1 : 0), "\(label): the store was read \(reads) times")
                    try check(ownCopy == (needed && TasksCutOver.isOwnCopyOnDevice(record: record, store: fact)), "\(label): own copy \(ownCopy)")
                }
            }
        }
    }

    /// The reviewed sequence through the inputs the coordinator reads at each point: the account's
    /// copy completed, a Telegram logout purged its store (the record stays), it logs back in and
    /// agrees (P waiting, unlinked), links (its store bound, the snapshot downloading), the snapshot
    /// lands, and the step checks the copy against the new store; later a 409 resync.
    private static func logoutPurgeSequence() throws {
        let completed = record(.completed)
        func at(_ permission: SGTasksSyncPermission, scope: String?, store: TasksCutOver.StoreFacts?) -> TasksCutOver {
            return cutOver(permission, completed, scope: scope, unmapped: 0, ownCopy: TasksCutOver.isOwnCopyOnDevice(record: completed, store: store))
        }
        try expect(at(.allowed, scope: Self.scopeA, store: store(Self.scopeA, complete: true)), .retired, "before the logout")
        try expect(at(.waiting, scope: nil, store: store(nil, complete: false)), .archive(.migrating), "re-login, consent agreed, not linked")
        try expect(at(.waiting, scope: nil, store: nil), .archive(.migrating), "re-login, the store does not open")
        try expect(at(.allowed, scope: Self.scopeA, store: store(Self.scopeA, complete: false)), .archive(.migrating), "linked, the snapshot downloading")
        try expect(at(.allowed, scope: Self.scopeA, store: store(Self.scopeA, complete: true, checked: false)), .archive(.migrating), "the snapshot landed, not checked yet")
        // No step runs while the consent waits for its link (or in a launch's first seconds).
        try expect(at(.waiting, scope: nil, store: store(Self.scopeA, complete: true, checked: false)), .archive(.migrating), "a session dropped before the step checked the copy")
        try expect(at(.allowed, scope: Self.scopeA, store: store(Self.scopeA, complete: true, checked: true)), .retired, "the step checked the copy in the new store")
        try expect(at(.waiting, scope: nil, store: store(Self.scopeA, complete: true)), .retired, "a session dropped once the copy is back (no flapping)")
        try expect(at(.allowed, scope: Self.scopeA, store: store(Self.scopeA, complete: true, generation: 1)), .archive(.migrating), "a 409 since")
        // An enqueued copy whose queued creates went with the store: readable throughout.
        let enqueued = record(.enqueued)
        try expect(cutOver(.waiting, enqueued, scope: nil, ownCopy: TasksCutOver.isOwnCopyOnDevice(record: enqueued, store: store(nil, complete: false))), .archive(.migrating), "enqueued, purged, re-login")
        try expect(cutOver(.allowed, enqueued, ownCopy: TasksCutOver.isOwnCopyOnDevice(record: enqueued, store: store(Self.scopeA, complete: true, pending: 7))), .archive(.migrating), "enqueued again by the step")
    }

    /// The banner of that readable archive. A completed copy's progress is all done (`done` =
    /// `total`), but nothing is being copied, so "Copying device tasks to Cloud: N of N" would be
    /// wrong: no progress line (the board shows one only while `total` > 0), the banner text alone
    /// ("These tasks were copied to Cloud…"), even with the default `copyOnDevice` (the copy here).
    /// A queued copy keeps its progress only while its copy is in this account's store; a completed
    /// copy not on this device shows the notice and `tasks_older_footer_awaiting`
    /// (`archiveCopyNotOnDevice`). The other reasons ignore the record state.
    private static func archiveProgressLine() throws {
        let completed = record(.completed)
        let enqueued = record(.enqueued)
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            for scope in [nil, Self.scopeA] as [String?] {
                let label = "\(permission), S \(scope ?? "nil")"
                let purged = cutOver(permission, completed, scope: scope, unmapped: 0, ownCopy: false)
                try expect(purged, .archive(.migrating), "\(label): the fixture")
                let archive = TasksBoardArchive(cutOver: purged, done: 7, total: 7, keptLocal: 1, recordState: completed.state)
                try check(archive == TasksBoardArchive(reason: .migrating(done: 0, total: 0), keptLocal: 1), "\(label): a completed copy claims copying: \(String(describing: archive))")
                try check(archive?.offersCopy == false, "\(label): a completed copy offers the explicit copy")
                // A queued copy with its creates in this store (the default): its progress.
                let queued = cutOver(permission, enqueued, scope: scope, ownCopy: true)
                try check(TasksBoardArchive(cutOver: queued, done: 3, total: 7, keptLocal: 0, recordState: enqueued.state)?.reason == .migrating(done: 3, total: 7), "\(label): a queued copy lost its progress")
            }
        }
        // Every create confirmed while the record still says enqueued (the next step completes it).
        try check(TasksBoardArchive(cutOver: .archive(.migrating), done: 7, total: 7, keptLocal: 0, recordState: .enqueued)?.reason == .migrating(done: 7, total: 7), "a queued copy confirmed in full lost its progress")
        // No record state (unknown): the progress as given.
        try check(TasksBoardArchive(cutOver: .archive(.migrating), done: 3, total: 9, keptLocal: 1) == TasksBoardArchive(reason: .migrating(done: 3, total: 9), keptLocal: 1), "an unknown record state dropped the progress")
        // The other reasons are unchanged by a completed record.
        try check(TasksBoardArchive(cutOver: .archive(.newRows(2)), done: 7, total: 7, keptLocal: 1, recordState: .completed) == TasksBoardArchive(reason: .newRows(2), keptLocal: 1), "new rows")
        try check(TasksBoardArchive(cutOver: .archive(.otherAccount), done: 7, total: 7, keptLocal: 1, recordState: .completed) == TasksBoardArchive(reason: .otherAccount), "another account's copy")
        try check(TasksBoardArchive(cutOver: .retired, done: 7, total: 7, keptLocal: 0, recordState: .completed) == TasksBoardArchive(reason: .retired), "retired")
        try check(TasksBoardArchive(cutOver: .none, done: 7, total: 7, keptLocal: 0, recordState: .completed) == nil, "a writable board has an archive")
    }

    /// The banner while the copy is not in this account's store on this device (I1 false: a logout
    /// purged the store, it does not open, or the step has not checked the copy there yet). A purged
    /// outbox holds none of the queued creates, so the counts would read "N of N": no progress line,
    /// whatever the record's state, and the line that says the Cloud copy returns (`awaitsCloudCopy`,
    /// `tasks_older_footer_awaiting`). Only `migrating` carries it: the other reasons ignore the input,
    /// and the plain init drops it for them.
    private static func archiveCopyNotOnDevice() throws {
        for state in [.enqueued, .completed, nil] as [TodoCloudMigrationRecord.State?] {
            let label = state.map { "\($0)" } ?? "unknown state"
            let archive = TasksBoardArchive(cutOver: .archive(.migrating), done: 7, total: 7, keptLocal: 1, recordState: state, copyOnDevice: false)
            try check(archive == TasksBoardArchive(reason: .migrating(done: 0, total: 0), keptLocal: 1, awaitsCloudCopy: true), "\(label): a copy not on this device: \(String(describing: archive))")
            try check(archive?.offersCopy == false, "\(label): a copy not on this device offers the explicit copy")
        }
        // A queued copy in this store: its progress, and nothing about a return.
        let queued = TasksBoardArchive(cutOver: .archive(.migrating), done: 3, total: 7, keptLocal: 0, recordState: .enqueued, copyOnDevice: true)
        try check(queued?.reason == .migrating(done: 3, total: 7) && queued?.awaitsCloudCopy == false, "a queued copy in this store: \(String(describing: queued))")
        // The default is the copy here.
        for state in [.enqueued, .completed, nil] as [TodoCloudMigrationRecord.State?] {
            let label = state.map { "\($0)" } ?? "unknown state"
            try check(TasksBoardArchive(cutOver: .archive(.migrating), done: 3, total: 7, keptLocal: 1, recordState: state) == TasksBoardArchive(cutOver: .archive(.migrating), done: 3, total: 7, keptLocal: 1, recordState: state, copyOnDevice: true), "\(label): the default is not the copy here")
        }
        // The other banners are unchanged by it.
        try check(TasksBoardArchive(cutOver: .archive(.newRows(2)), done: 7, total: 7, keptLocal: 1, recordState: .completed, copyOnDevice: false) == TasksBoardArchive(reason: .newRows(2), keptLocal: 1), "new rows")
        try check(TasksBoardArchive(cutOver: .archive(.otherAccount), done: 7, total: 7, keptLocal: 1, recordState: .completed, copyOnDevice: false) == TasksBoardArchive(reason: .otherAccount), "another account's copy")
        try check(TasksBoardArchive(cutOver: .retired, done: 7, total: 7, keptLocal: 0, recordState: .completed, copyOnDevice: false) == TasksBoardArchive(reason: .retired), "retired")
        try check(TasksBoardArchive(cutOver: .none, done: 7, total: 7, keptLocal: 0, recordState: .completed, copyOnDevice: false) == nil, "a writable board has an archive")
        // Only `migrating` awaits the copy, by construction.
        for reason in [TasksBoardArchive.Reason.newRows(2), .otherAccount, .retired] {
            try check(!TasksBoardArchive(reason: reason, awaitsCloudCopy: true).awaitsCloudCopy, "\(reason) awaits the Cloud copy")
        }
    }

    private static func row6OtherAccount() throws {
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            try expect(cutOver(permission, nil, ownerActive: true), .archive(.otherAccount), "\(permission) without a record")
            try expect(cutOver(permission, record(.skipped, scope: nil, reason: .deviceOwnedByOther), ownerActive: true), .archive(.otherAccount), "\(permission) skipped for the owner")
            try expect(cutOver(permission, record(.released, scope: nil, reason: .withdrawn), ownerActive: true), .archive(.otherAccount), "\(permission) released")
        }
    }

    private static func row7Writable() throws {
        for permission in [SGTasksSyncPermission.waiting, .allowed] {
            // No record yet, a consent-time claim waiting for the link, a claim whose step has not
            // run (Tasks unreachable, snapshot incomplete, enqueue failed): writable until enqueued.
            try expect(cutOver(permission, nil), .none, "\(permission) no record")
            try expect(cutOver(permission, record(.claimed, scope: nil)), .none, "\(permission) consent-time claim")
            try expect(cutOver(permission, record(.claimed), unmapped: 9), .none, "\(permission) claimed, not enqueued")
            try expect(cutOver(permission, record(.released, scope: nil, reason: .withdrawn)), .none, "\(permission) released")
            try expect(cutOver(permission, record(.skipped, scope: nil, reason: .existingMappings)), .none, "\(permission) skipped (existing mappings)")
            try expect(cutOver(permission, record(.skipped, reason: .scopeChanged)), .none, "\(permission) skipped (scope changed)")
            // The owner logged out, its copy not enqueued yet, released or on another scope: the
            // coordinator reports ownerActive = false.
            try expect(cutOver(permission, record(.skipped, scope: nil, reason: .deviceOwnedByOther), ownerActive: false), .none, "\(permission) owner not active")
        }
    }

    private static func readOnlyFlag() throws {
        try check(!TasksCutOver.none.isReadOnly, "none is read-only")
        for cutOver in [TasksCutOver.archive(.migrating), .archive(.newRows(1)), .archive(.otherAccount), .retired] {
            try check(cutOver.isReadOnly, "\(cutOver) is writable")
        }
    }
}
