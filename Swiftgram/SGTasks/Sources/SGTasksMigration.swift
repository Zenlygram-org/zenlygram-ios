import Foundation
import SGEntitlement

// MARK: - Zenlygram Tasks R4: the automatic first migration of the device rows (design 30 §5.5)
//
// Pure except for the two stores it is handed (the device database and an account's cloud
// repository). The device database belongs to the first account on this device whose data consent
// is granted, whatever the link order: `claimAtConsent` takes the owner marker locally, with no
// network. Once that account is linked and its cloud snapshot is complete, `runStep` copies the rows
// headless — R4 rules (`SGTasksMigrationNormalizer`, no assignee ever), creates with origin
// `migration` (batch route only) — under the device-wide write fence, so no local edit slips between
// the snapshot and the enqueue (F19), and with the consent epoch it captured, so a withdrawal in
// between enqueues nothing. Every identity comes from the immutable import mapping: a restart, a
// logout/re-login or a rerun resends the same mutation ids and never duplicates a row, and with the
// same bytes: the copy's times are checked against its first enqueue's server time (§7.1). A cloud
// store the step has not checked yet (recreated after a logout purge, or rebound to another server
// account) voids what was verified against the one before it, and a 409 resync moves the store's
// generation past the completion's, so a completed copy is checked against it again (Android FIX-A3).

/// What the board shows about an account's migration (`SGTasksSyncCoordinator.migrationProgress`).
public struct SGTasksMigrationProgress: Equatable {
    public let state: TodoCloudMigrationRecord.State
    public let reason: TodoCloudMigrationRecord.Reason?
    /// Lists and tasks the copy covers (0 before its local step).
    public let total: Int
    /// Of `total`, no longer waiting in the account's outbox.
    public let done: Int
    /// Rows that could not be copied and stay on this device.
    public let keptLocal: Int
}

/// The device-wide write fence of a step's local part (design 30 §5.4). Production: the sync
/// coordinator's `isMigrationStepRunning`; host tests: a recording stand-in.
public protocol SGTasksMigrationFence: AnyObject {
    /// Before the snapshot: every account's checked local writes answer `.migrating`.
    func raise()
    /// After the enqueue AND the record update (also after a throw): the cut-over must already read
    /// the account's new record when the fence drops, so no write slips in as `.open`.
    func lower(accountPeerId: Int64)
}

public enum SGTasksMigration {
    public typealias Locale = TodoCloudMigrationRecord.Locale

    static let migrationErrorDomain = "tasks_migration"

    /// The consent-time claim (local only, no network), for an account with consent and no record
    /// yet, or with its own `released` one (`SGTasksSyncPolicy.shouldClaimDevice`):
    /// - an account with an import mapping in any scope copied rows explicitly: `skipped
    ///   (existing_mappings)`, and a FREE marker becomes its own as `completed` (those rows are never
    ///   copied automatically into a second account). A released record skips this check: its
    ///   withdrawal voided the mappings.
    /// - else the marker: free or its own → `claimed` (scope nil until the step; `started` event);
    ///   another account's → `skipped(device_owned_by_other)` (the account starts with an empty cloud).
    /// Any other existing record is returned unchanged.
    @discardableResult
    public static func claimAtConsent(accountPeerId: Int64, locale: Locale, database: TodoDatabase, now: Date = Date()) throws -> TodoCloudMigrationRecord {
        let existing = try database.cloudMigrationRecord(accountPeerId: accountPeerId)
        if let existing = existing, existing.state != .released {
            return existing
        }
        return try Self.claim(accountPeerId: accountPeerId, previous: existing, locale: existing?.normalizationLocale ?? locale, scope: nil, database: database, now: now)
    }

    private static func claim(accountPeerId: Int64, previous: TodoCloudMigrationRecord?, locale: Locale, scope: String?, database: TodoDatabase, now: Date) throws -> TodoCloudMigrationRecord {
        let at = Int64(now.timeIntervalSince1970)
        let record: TodoCloudMigrationRecord
        if previous == nil, try database.hasCloudImportMapping(accountPeerId: accountPeerId) {
            if try database.cloudDeviceOwner() == nil {
                try database.claimCloudDevice(accountPeerId: accountPeerId, asCompleted: true, now: now)
            }
            record = TodoCloudMigrationRecord(accountPeerId: accountPeerId, state: .skipped, reason: .existingMappings, normalizationLocale: locale, claimedAt: at)
        } else {
            switch try database.claimCloudDevice(accountPeerId: accountPeerId, now: now) {
            case .claimed, .alreadyOwner:
                record = TodoCloudMigrationRecord(accountPeerId: accountPeerId, state: .claimed, principalScope: scope, normalizationLocale: locale, claimedAt: at)
            case .ownedByOther, .releasedByOther:
                record = TodoCloudMigrationRecord(accountPeerId: accountPeerId, state: .skipped, reason: .deviceOwnedByOther, normalizationLocale: locale, claimedAt: at)
            }
        }
        guard try database.setCloudMigrationRecord(record, replacing: previous) else {
            // Changed meanwhile (a withdrawal or another claim): that state stands.
            return try database.cloudMigrationRecord(accountPeerId: accountPeerId) ?? record
        }
        if record.state == .claimed {
            SGTasksAnalytics.emit(.migration(phase: "started", lists: nil, tasks: nil, skipped: nil, durationS: nil, errorCode: nil), accountPeerId: accountPeerId)
        }
        return record
    }

    /// One step of the account's migration (the coordinator, after a cycle with a complete snapshot,
    /// for an `allowed` account; one step in flight on the device). Its time is the estimated server
    /// time (every time it records too):
    /// 1. preconditions: linked, a principal, a complete snapshot of it, no resnapshot pending; a store
    ///    without `migration_checked` first voids the verifications of the record and its attempt rows
    ///    (verified generation -1, they were recorded against an earlier store), then gets the marker;
    /// 2. the record: none → `claimAtConsent` first; `released` (own) → claimed again with the
    ///    current scope; `skipped` → nothing; claimed with scope nil → the current scope; claimed /
    ///    enqueued / completed under ANOTHER scope → `skipped(scope_changed)`, the marker released and
    ///    the mappings kept;
    /// 3. `claimed` → the local step under the fence: the consent epoch, one snapshot, its plan, the
    ///    creates (origin `migration`) with that epoch, the record `enqueued` with its counts. A throw
    ///    leaves `claimed` (the board stays writable); a rerun finds earlier creates `importPending`;
    /// 4. `enqueued`, or `completed` verified at an older `resync_generation` (or against an earlier
    ///    store): mapped rows to (re)send (lost with a logout, or resent once after a late erasure or
    ///    in a new store) are enqueued again inside the fenced local step and the record is (again)
    ///    `enqueued`; when every mapped row is `alreadyInCloud` or `removedFromCloud`, the record is
    ///    `completed` at the current generation and the marker completed (`completed` event on the
    ///    first completion only). Steps 3 and 4 check created_at/completed_at against `normalizedAt`.
    /// A storage/transport failure emits `failed` + `error.occurred(tasks_migration)` and is
    /// rethrown; the step reruns with the next cycle. Not linked / no complete snapshot yet / a
    /// permission other than `allowed` / a withdrawal racing the step are not failures.
    @discardableResult
    public static func runStep(repository: SGTasksCloudRepository, locale: Locale, fence: SGTasksMigrationFence?) throws -> SGTasksMigrationProgress? {
        let accountPeerId = repository.accountPeerId
        do {
            return try Self.step(repository: repository, locale: locale, fence: fence)
        } catch let error as SGTasksCloudError {
            switch error {
            case .notLinked, .importRequiresCompleteSnapshot, .accountRemoved, .consentWithdrawn:
                break
            default:
                Self.emitFailure(code: "unknown", accountPeerId: accountPeerId)
            }
            throw error
        } catch let error as TodoDatabaseError {
            if case let .sqlite(code) = error {
                Self.emitFailure(code: "sqlite_\(code)", accountPeerId: accountPeerId)
            } else {
                Self.emitFailure(code: "unknown", accountPeerId: accountPeerId)
            }
            throw error
        }
    }

    private static func emitFailure(code: String, accountPeerId: Int64) {
        SGTasksAnalytics.emit(.migration(phase: "failed", lists: nil, tasks: nil, skipped: nil, durationS: nil, errorCode: code), accountPeerId: accountPeerId)
        SGTasksAnalytics.emit(.error(domain: Self.migrationErrorDomain, code: code), accountPeerId: accountPeerId)
    }

    private static func step(repository: SGTasksCloudRepository, locale: Locale, fence: SGTasksMigrationFence?) throws -> SGTasksMigrationProgress? {
        let accountPeerId = repository.accountPeerId
        let database = repository.environment.legacy()
        guard repository.permission == .allowed else {
            return try database.cloudMigrationRecord(accountPeerId: accountPeerId).map { Self.progress($0, repository: repository) }
        }
        let context = try repository.migrationPreconditions()
        if !context.storeChecked {
            // A new store reads `resync_generation` 0 like the one before it: what was verified
            // against that one is void, so a completed copy is checked against this one and an
            // acknowledged row absent here is resent once. Both writes are durable (a restart in
            // between voids again, idempotently); steps run one at a time (the coordinator's queue).
            try database.invalidateMigrationVerification(accountPeerId: accountPeerId)
            try repository.markMigrationChecked()
        }
        let now = context.serverNow
        var record: TodoCloudMigrationRecord
        if let existing = try database.cloudMigrationRecord(accountPeerId: accountPeerId) {
            record = existing
        } else {
            record = try Self.claimAtConsent(accountPeerId: accountPeerId, locale: locale, database: database, now: now)
        }
        switch record.state {
        case .skipped:
            return Self.progress(record, repository: repository)
        case .released:
            record = try Self.claim(accountPeerId: accountPeerId, previous: record, locale: record.normalizationLocale, scope: context.scope, database: database, now: now)
            guard record.state == .claimed else { return Self.progress(record, repository: repository) }
        case .claimed, .enqueued, .completed:
            if let scope = record.principalScope, scope != context.scope {
                // The server account changed (rebind/merge): the copy belongs to the old cloud.
                try database.releaseCloudDevice(accountPeerId: accountPeerId, reason: .scopeChanged, now: now)
                return try database.cloudMigrationRecord(accountPeerId: accountPeerId).map { Self.progress($0, repository: repository) }
            }
            if record.principalScope == nil {
                var scoped = record
                scoped.principalScope = context.scope
                guard try database.setCloudMigrationRecord(scoped, replacing: record) else {
                    return try database.cloudMigrationRecord(accountPeerId: accountPeerId).map { Self.progress($0, repository: repository) }
                }
                record = scoped
            }
        }
        switch record.state {
        case .claimed:
            record = try Self.copy(repository: repository, record: record, database: database, fence: fence, now: now)
        case .enqueued:
            record = try Self.verify(repository: repository, record: record, generation: context.resyncGeneration, database: database, fence: fence, now: now)
        case .completed where record.verifiedGeneration < context.resyncGeneration:
            record = try Self.verify(repository: repository, record: record, generation: context.resyncGeneration, database: database, fence: fence, now: now)
        default:
            break
        }
        return Self.progress(record, repository: repository)
    }

    private static func rules(_ record: TodoCloudMigrationRecord, normalizedAt: Date) -> SGTasksImportRules {
        return .r4(SGTasksMigrationNormalizer(locale: record.normalizationLocale), normalizedAt: normalizedAt)
    }

    /// The time a copy's created_at/completed_at are checked against (design 30 §7.1; Android
    /// `TasksAutoMigration.normalizedAt`): its first enqueue's (`enqueuedAt`, server-estimated), so a
    /// re-derivation — after a logout, the resend-once or in a new store — rebuilds identical bytes
    /// (the server hashes both fields) and a time nulled then is never kept later; before the first
    /// enqueue, the step's (server) time, in whole seconds like the record.
    static func normalizedAt(_ record: TodoCloudMigrationRecord, stepNow: Date) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(record.enqueuedAt ?? Int64(stepNow.timeIntervalSince1970)))
    }

    /// The explicit copy's time base beside the migration (Android `TasksCloudImport.Rules.forCopy`):
    /// while the account's migration (re)checks its copy in `scope` (`enqueued`/`completed`), its
    /// first enqueue, since that re-check rebuilds every mapped row of the scope; else nil (the
    /// copy's own rule: the estimated server now).
    static func explicitCopyTimeBase(record: TodoCloudMigrationRecord?, scope: String?) -> Date? {
        guard let record = record, record.state == .enqueued || record.state == .completed,
              let scope = scope, record.principalScope == scope, let enqueuedAt = record.enqueuedAt else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(enqueuedAt))
    }

    /// Step 3: the first copy, all on this device, under the fence.
    private static func copy(repository: SGTasksCloudRepository, record: TodoCloudMigrationRecord, database: TodoDatabase, fence: SGTasksMigrationFence?, now: Date) throws -> TodoCloudMigrationRecord {
        let at = Self.normalizedAt(record, stepNow: now)
        let rules = Self.rules(record, normalizedAt: at)
        fence?.raise()
        defer { fence?.lower(accountPeerId: repository.accountPeerId) }
        guard let epoch = repository.consentEpoch() else { throw SGTasksCloudError.storageUnavailable }
        let prepared = try repository.preparedImport(rules: rules)
        _ = try repository.commitLegacyImport(prepared.preview, rules: rules, origin: .migration, expectedConsentEpoch: epoch, mappedOnly: false)
        var enqueued = record
        enqueued.state = .enqueued
        enqueued.enqueuedAt = Int64(at.timeIntervalSince1970)
        enqueued.lists = prepared.summary.lists
        enqueued.tasks = prepared.summary.tasks
        enqueued.keptLocal = prepared.summary.keptLocal
        guard try database.setCloudMigrationRecord(enqueued, replacing: record) else {
            // A withdrawal or an erasure changed the record meanwhile: it wins.
            return try database.cloudMigrationRecord(accountPeerId: repository.accountPeerId) ?? record
        }
        return enqueued
    }

    /// Step 4: re-enqueue what this copy still owes, or complete it.
    private static func verify(repository: SGTasksCloudRepository, record: TodoCloudMigrationRecord, generation: Int64, database: TodoDatabase, fence: SGTasksMigrationFence?, now: Date) throws -> TodoCloudMigrationRecord {
        let at = Self.normalizedAt(record, stepNow: now)
        let rules = Self.rules(record, normalizedAt: at)
        let summary = try repository.preparedImport(rules: rules).summary
        if summary.mappedEnqueueable > 0 {
            fence?.raise()
            defer { fence?.lower(accountPeerId: repository.accountPeerId) }
            guard let epoch = repository.consentEpoch() else { throw SGTasksCloudError.storageUnavailable }
            // A fresh snapshot under the fence; only rows of this copy (with a mapping) go again.
            let prepared = try repository.preparedImport(rules: rules)
            _ = try repository.commitLegacyImport(prepared.preview, rules: rules, origin: .migration, expectedConsentEpoch: epoch, mappedOnly: true)
            var enqueued = record
            enqueued.state = .enqueued
            if enqueued.enqueuedAt == nil {
                enqueued.enqueuedAt = Int64(at.timeIntervalSince1970)
            }
            guard enqueued != record else { return record }
            guard try database.setCloudMigrationRecord(enqueued, replacing: record) else {
                return try database.cloudMigrationRecord(accountPeerId: repository.accountPeerId) ?? record
            }
            return enqueued
        }
        let confirmed = summary.mappedStatuses.allSatisfy { $0 == .alreadyInCloud || $0 == .removedFromCloud }
        guard confirmed else {
            // Still in flight (or blocked for an explicit choice): a re-checked completed copy shows
            // its archive again until its rows are confirmed.
            guard record.state == .completed else { return record }
            var enqueued = record
            enqueued.state = .enqueued
            guard try database.setCloudMigrationRecord(enqueued, replacing: record) else {
                return try database.cloudMigrationRecord(accountPeerId: repository.accountPeerId) ?? record
            }
            return enqueued
        }
        var completed = record
        completed.state = .completed
        completed.verifiedGeneration = generation
        let isFirstCompletion = record.completedAt == nil
        if isFirstCompletion {
            completed.completedAt = Int64(now.timeIntervalSince1970)
        }
        guard try database.setCloudMigrationRecord(completed, replacing: record) else {
            return try database.cloudMigrationRecord(accountPeerId: repository.accountPeerId) ?? record
        }
        try database.completeCloudDevice(accountPeerId: repository.accountPeerId, now: now)
        if isFirstCompletion {
            let started = completed.enqueuedAt ?? completed.claimedAt
            let duration = max(0, Int(Int64(now.timeIntervalSince1970) - started))
            SGTasksAnalytics.emit(.migration(phase: "completed", lists: completed.lists, tasks: completed.tasks, skipped: completed.keptLocal, durationS: duration, errorCode: nil), accountPeerId: repository.accountPeerId)
        }
        return completed
    }

    /// The board's progress for a record: `done` counts the covered rows no longer waiting in the
    /// account's outbox (unknown outbox → nothing counted as done).
    static func progress(_ record: TodoCloudMigrationRecord, repository: SGTasksCloudRepository?) -> SGTasksMigrationProgress {
        let total = record.lists + record.tasks
        let done: Int
        switch record.state {
        case .completed:
            done = total
        case .enqueued:
            let pending = repository?.pendingMigrationCount() ?? total
            done = max(0, total - pending)
        case .claimed, .released, .skipped:
            done = 0
        }
        return SGTasksMigrationProgress(state: record.state, reason: record.reason, total: total, done: done, keptLocal: record.keptLocal)
    }
}

extension SGTasksCloudRepository {
    /// Unacknowledged migration creates in this account's outbox; nil when unreadable.
    func pendingMigrationCount() -> Int? {
        return self.onQueue {
            guard let store = self.store else { return nil }
            return (try? store.unsentCounts())?.migration
        }
    }

    /// The import scope of the account's current binding (nil when unbound): the cut-over's S.
    static func currentImportScope(accountPeerId: Int64) -> String? {
        let environment = Self.environment
        return environment.transport.principal(accountPeerId: accountPeerId).map { Self.importScope(origin: environment.originScope, principal: $0) }
    }
}
