import CryptoKit
import Foundation
import SGEntitlement

// MARK: - Import of device-local Tasks into this account's cloud (explicit copy and R4 migration)
//
// Two flows share this planner: the explicit, consented copy (preview, then commit) and — R4 — the
// automatic first migration (`SGTasksMigration`), whose consent is the account's data consent. The
// preview is built from ONE transactional immutable snapshot of the local database; originals stay
// local and unchanged. The content-free mapping (native account + backend origin + canonical
// server-account scope + legacy id + folder incarnation -> cloud id + create mutation id) is
// immutable and reused on restart, partial receipt and re-login under the SAME origin and server
// account, so the same rows never create a second copy there; another origin or another server
// account (rebind/merge) gets its own identities.
//
// Rules (`SGTasksImportRules`):
// - R3 (`.legacy`, a build without a Tasks backend — inert there): each actual local folder
//   (including the renamable/deletable local "Inbox") becomes a real cloud list; rows that would
//   need silent transformation (trimming, an unconvertible contact id, out-of-range values) are
//   reported for explicit correction; a convertible assignee becomes a private annotation.
// - R4 (both flows, every other permission): the stable inbox under a default title is the virtual
//   Cloud Inbox (no list, its tasks carry `list_id: null`); every row is normalized
//   (`SGTasksMigrationNormalizer`, design 30 §7.1) instead of refused; the assignee never leaves the
//   device (`annotation: nil` on every create, F16); an acknowledged mapped row absent from the
//   complete snapshot after a 409 resync, or from a new cloud store, is resent ONCE with its reserved
//   id before it counts as removed (resend-once, §5.5); created_at/completed_at are checked against
//   the migration's first enqueue while it (re)checks the scope, so a re-derivation seals the same
//   bytes (§7.1).
//
// Mappings written before origin scoping (the principal-only "v1" scope) are never read, copied or
// rewritten here; only the final-logout wipe, a withdrawal or an erasure removes them (and their
// existence skips the automatic migration of that account). So an import an older build already did
// against the SAME backend is offered again by the explicit copy: consenting to it creates a second
// cloud copy. Nothing is ever uploaded without consent.

/// Which rules the import planner applies (design 30 §5.5).
enum SGTasksImportRules: Equatable {
    /// Exactly R3 (`SGTasksSyncPermission.legacy`).
    case r3
    /// R4, for the automatic migration and the explicit copy alike. `normalizedAt`: the time the
    /// rows' created_at/completed_at are checked against (§7.1) — the migration's first enqueue
    /// (`SGTasksMigration.normalizedAt`), so every re-derivation of a create seals the same bytes
    /// (the server hashes both fields); nil: the plan's estimated server now.
    case r4(SGTasksMigrationNormalizer, normalizedAt: Date? = nil)
}

/// What the automatic migration reads from a plan (R4 rules). Content-free.
struct SGTasksImportSummary {
    /// Statuses of the rows that have a mapping of the scope (an earlier step's planned rows).
    var mappedStatuses: [SGTasksCloudImportPreview.ItemStatus] = []
    /// Lists / tasks the copy covers: enqueueable now, pending or already in the cloud (the Cloud
    /// Inbox itself is no list).
    var lists = 0
    var tasks = 0
    /// Rows that could not be copied and stay on this device.
    var keptLocal = 0
    /// Rows a commit would enqueue now; of them, those that already have a mapping.
    var enqueueable = 0
    var mappedEnqueueable = 0
}

extension SGTasksCloudRepository {
    /// Host tests only: runs inside a migration commit between the durable mint of its mappings and
    /// its enqueue — the window a withdrawal or a local edit may race (design 30 §5.5, F19). nil
    /// otherwise.
    static var migrationMintedHook: ((SGTasksCloudRepository) -> Void)?

    private struct ImportPlan {
        var folderStatus: [String: SGTasksCloudImportPreview.ItemStatus] = [:]
        var taskStatus: [String: SGTasksCloudImportPreview.ItemStatus] = [:]
        /// R4: folders that are the virtual Cloud Inbox (by incarnation): no list, no folder mapping.
        var cloudInboxFolders: Set<String> = []
        /// R4: the normalized rows (by incarnation / task key).
        var lists: [String: SGTasksMigrationNormalizer.List] = [:]
        var tasks: [String: SGTasksMigrationNormalizer.Task] = [:]
        /// Rows with a mapping of the scope.
        var mappedFolders: Set<String> = []
        var mappedTasks: Set<String> = []
        /// R4 resend-once: create ids of acknowledged rows to re-verify before their resend, and the
        /// generation they are verified at.
        var reverify: Set<String> = []
        var resyncGeneration: Int64 = 0
    }

    private static func mappingKey(_ kind: TodoCloudImportMapping.Kind, _ legacyId: String, _ incarnation: String) -> String {
        return "\(kind.rawValue)\u{0}\(legacyId)\u{0}\(incarnation)"
    }

    private static func validInstant(_ seconds: Int64, now: Date) -> SGTasksWire.Instant? {
        guard seconds >= 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        guard date <= now.addingTimeInterval(300) else { return nil }
        return SGTasksWire.Instant(date: date)
    }

    private static func folderIssue(_ folder: TodoCloudImportFolder, now: Date) -> SGTasksCloudImportIssue? {
        guard (try? TodoStorage.validatedTitle(folder.title, limit: TodoStorage.folderTitleLimit)) == folder.title else { return .invalidTitle }
        guard Int32(exactly: folder.sortOrder) != nil else { return .invalidSortOrder }
        guard Self.validInstant(folder.createdDate, now: now) != nil else { return .invalidDate }
        return nil
    }

    private static func taskIssue(_ task: TodoTask, now: Date) -> SGTasksCloudImportIssue? {
        guard (try? TodoStorage.validatedTitle(task.title, limit: TodoStorage.taskTitleLimit)) == task.title else { return .invalidTitle }
        if let description = task.description {
            guard description.count <= Self.descriptionGraphemeLimit, description.utf8.count <= Self.descriptionByteLimit else { return .invalidDescription }
        }
        if let dueAt = task.dueAt, dueAt < 0 { return .invalidDate }
        guard (0 ... 4).contains(task.priority) else { return .invalidPriority }
        guard Int32(exactly: task.sortOrder) != nil else { return .invalidSortOrder }
        guard Self.validInstant(Int64(task.createdDate), now: now) != nil else { return .invalidDate }
        if task.isCompleted, let completedAt = task.completedAt, Self.validInstant(Int64(completedAt), now: now) == nil { return .invalidDate }
        if let assignee = task.assignee {
            guard SGTasksWire.TelegramId(cloudUserPeerId: assignee.peerId) != nil else { return .annotationNotConvertible }
            guard (try? TodoStorage.validatedAssignee(peerId: assignee.peerId, displayName: assignee.displayName))?.displayName == assignee.displayName else { return .invalidAnnotation }
        }
        return nil
    }

    /// R4: a normalized row still failing the wire rules stays local (`needsCorrection`). The
    /// normalizer makes this unreachable for every row it produces; the check stays as the guard.
    private static func normalizedFolderIssue(_ list: SGTasksMigrationNormalizer.List) -> SGTasksCloudImportIssue? {
        guard (try? TodoStorage.validatedTitle(list.title, limit: TodoStorage.folderTitleLimit)) == list.title else { return .invalidTitle }
        return nil
    }

    private static func normalizedTaskIssue(_ task: SGTasksMigrationNormalizer.Task) -> SGTasksCloudImportIssue? {
        guard (try? TodoStorage.validatedTitle(task.title, limit: TodoStorage.taskTitleLimit)) == task.title else { return .invalidTitle }
        if let description = task.description {
            guard description.count <= Self.descriptionGraphemeLimit, description.utf8.count <= Self.descriptionByteLimit else { return .invalidDescription }
        }
        return nil
    }

    /// One-way, content-free digest of where an import mapping belongs: the validated backend
    /// origin and the canonical server account on it. Length-prefixed, so no origin/principal pair
    /// can collide with another; never the principal-only v1 scope of earlier builds.
    static func importScope(origin: SGEntitlementStoreScope, principal: String) -> String {
        let identifier = origin.identifier
        let material = "zenlygram-tasks-import-scope-v2\u{0}\(identifier.utf8.count):\(identifier)\u{0}\(principal.utf8.count):\(principal)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Where a mapped row stands in THIS account's cloud state. Never frees an identity that may
    /// still be in flight or blocked: those stay pending/blocked for explicit resolution.
    /// `resyncGeneration` (R4 only) applies resend-once to an acknowledged row: absent from the
    /// complete snapshot and verified at an older generation, it is resent with its reserved id
    /// (its create id lands in `reverify`); only once verified at the current one is it removed.
    private static func status(of mapping: TodoCloudImportMapping, kind: String, store: SGTasksCloudStore, entries: [SGTasksCloudStoredEntry], resyncGeneration: Int64?, reverify: inout Set<String>) throws -> SGTasksCloudImportPreview.ItemStatus {
        if try store.row(.shadow, kind: kind, id: mapping.cloudId) != nil { return .alreadyInCloud }
        let key = "\(kind):\(mapping.cloudId)"
        let related = entries.filter { $0.keys.contains(key) }
        if let create = related.first(where: { $0.mutationId == mapping.createMutationId }) {
            switch create.state {
            case .queued, .sending, .held, .acked:
                return .importPending
            case .blockedCreation, .invalid, .conflict, .stalled:
                return .importBlocked
            case .quarantined, .notFound, .principalChanged:
                return .needsCorrection(.previousImportFailed)
            }
        }
        var hasBlockedEntry = false
        for entry in related {
            switch entry.state {
            case .queued, .sending, .held, .acked:
                return .importPending
            case .principalChanged:
                break
            default:
                hasBlockedEntry = true
            }
        }
        if hasBlockedEntry { return .importBlocked }
        // Acknowledged before, absent now: removed in the cloud. Re-sending the same id would only
        // replay the old receipt, and a new id would break the immutable mapping. An acknowledgement
        // still queued for the local database counts as recorded. R4: after a resync the server may
        // have erased it (a late erasure) — the same id is resent once (§5.5).
        if try mapping.isAcknowledged || store.pendingImportAcks().contains(mapping.createMutationId) {
            if let generation = resyncGeneration, mapping.verifiedGeneration < generation {
                reverify.insert(mapping.createMutationId)
                return .resendPreviousAttempt
            }
            return .removedFromCloud
        }
        // Handed to the network before with an unknown outcome: only the SAME reserved identity
        // may be resent (idempotent at the server).
        if mapping.wasAttempted { return .resendPreviousAttempt }
        return .importable
    }

    private static func isEnqueued(_ status: SGTasksCloudImportPreview.ItemStatus?) -> Bool {
        return status?.isEnqueuedByConsent ?? false
    }

    /// A task only follows a parent that is, or is about to be, a healthy cloud list (or the Cloud
    /// Inbox, `alreadyInCloud`).
    private static func acceptsChildren(_ status: SGTasksCloudImportPreview.ItemStatus?) -> Bool {
        return status == .importable || status == .resendPreviousAttempt || status == .alreadyInCloud || status == .importPending
    }

    private func importPlan(snapshot: TodoCloudImportSnapshot, mappings: [TodoCloudImportMapping], store: SGTasksCloudStore, now: Date, rules: SGTasksImportRules) throws -> ImportPlan {
        var byKey: [String: TodoCloudImportMapping] = [:]
        for mapping in mappings {
            byKey[Self.mappingKey(mapping.kind, mapping.legacyId, mapping.legacyIncarnation)] = mapping
        }
        let entries = try store.entries()
        var plan = ImportPlan()
        let normalizer: SGTasksMigrationNormalizer?
        let resyncGeneration: Int64?
        // What R4 checks created_at/completed_at against (its time base, §7.1); R3 checks `now`.
        var checkedAt = now
        switch rules {
        case .r3:
            normalizer = nil
            resyncGeneration = nil
        case let .r4(rule, normalizedAt):
            normalizer = rule
            checkedAt = normalizedAt ?? now
            plan.resyncGeneration = try store.integerMeta("resync_generation") ?? 0
            resyncGeneration = plan.resyncGeneration
        }
        var folderByIncarnation: [String: TodoCloudImportFolder] = [:]
        for (index, folder) in snapshot.folders.enumerated() {
            folderByIncarnation[folder.incarnation] = folder
            if normalizer != nil, SGTasksMigrationNormalizer.isCloudInbox(folderId: folder.id, title: folder.title) {
                // The virtual Cloud Inbox always exists: nothing to create, its tasks follow it.
                plan.cloudInboxFolders.insert(folder.incarnation)
                plan.folderStatus[folder.incarnation] = .alreadyInCloud
                continue
            }
            let issue: SGTasksCloudImportIssue?
            if let normalizer = normalizer {
                let list = normalizer.list(folder, index: index, now: checkedAt)
                plan.lists[folder.incarnation] = list
                issue = Self.normalizedFolderIssue(list)
            } else {
                issue = Self.folderIssue(folder, now: now)
            }
            let mapping = byKey[Self.mappingKey(.folder, folder.id, folder.incarnation)]
            if mapping != nil {
                plan.mappedFolders.insert(folder.incarnation)
            }
            if let issue = issue {
                plan.folderStatus[folder.incarnation] = .needsCorrection(issue)
            } else if let mapping = mapping {
                plan.folderStatus[folder.incarnation] = try Self.status(of: mapping, kind: "list", store: store, entries: entries, resyncGeneration: resyncGeneration, reverify: &plan.reverify)
            } else {
                plan.folderStatus[folder.incarnation] = .importable
            }
        }
        // A task's index among its siblings, in the snapshot's local order (§7.1 sort_order rule).
        var siblingIndex: [String: Int] = [:]
        for item in snapshot.tasks {
            let key = Self.taskKey(item)
            guard let incarnation = item.folderIncarnation, folderByIncarnation[incarnation] != nil else {
                plan.taskStatus[key] = .needsCorrection(.parentFolderNeedsCorrection)
                continue
            }
            let index = siblingIndex[incarnation, default: 0]
            siblingIndex[incarnation] = index + 1
            let mapping = byKey[Self.mappingKey(.task, item.task.id, incarnation)]
            if mapping != nil {
                plan.mappedTasks.insert(key)
            }
            // A row imported before reports its own state (pending, blocked, removed...) first.
            if let mapping = mapping {
                let own = try Self.status(of: mapping, kind: "task", store: store, entries: entries, resyncGeneration: resyncGeneration, reverify: &plan.reverify)
                if !own.isEnqueuedByConsent {
                    plan.taskStatus[key] = own
                    continue
                }
            }
            // Never enqueue a task into a parent that is blocked, failed or removed.
            guard Self.acceptsChildren(plan.folderStatus[incarnation]) else {
                plan.taskStatus[key] = .needsCorrection(.parentFolderNeedsCorrection)
                continue
            }
            let issue: SGTasksCloudImportIssue?
            if let normalizer = normalizer {
                let task = normalizer.task(item.task, index: index, now: checkedAt)
                plan.tasks[key] = task
                issue = Self.normalizedTaskIssue(task)
            } else {
                issue = Self.taskIssue(item.task, now: now)
            }
            if let issue = issue {
                plan.taskStatus[key] = .needsCorrection(issue)
            } else if let mapping = mapping {
                plan.taskStatus[key] = try Self.status(of: mapping, kind: "task", store: store, entries: entries, resyncGeneration: resyncGeneration, reverify: &plan.reverify)
            } else {
                plan.taskStatus[key] = .importable
            }
        }
        return plan
    }

    private static func taskKey(_ item: TodoCloudImportTask) -> String {
        return "\(item.task.id)\u{0}\(item.folderIncarnation ?? "")"
    }

    /// On queue. Binds/fences the store to the CURRENT server account first, then requires a
    /// complete snapshot of that account; returns the store and the account's mapping scope.
    private func importPreconditions() throws -> (store: SGTasksCloudStore, scope: String) {
        guard !self.isInvalidated else { throw SGTasksCloudError.accountRemoved }
        guard self.store != nil else { throw SGTasksCloudError.storageUnavailable }
        guard self.environment.transport.isLinked(accountPeerId: self.accountPeerId) else { throw SGTasksCloudError.notLinked }
        guard let principal = self.fencePrincipal() else { throw SGTasksCloudError.notLinked }
        guard let store = self.store else { throw SGTasksCloudError.storageUnavailable }
        // Knowing what is already in the cloud requires a complete snapshot of THIS server account.
        guard try store.meta("snapshot_complete") == "1", try store.meta("principal") == principal else { throw SGTasksCloudError.importRequiresCompleteSnapshot }
        return (store, Self.importScope(origin: self.environment.originScope, principal: principal))
    }

    /// Cloud meta (dies with the store file): the migration step has checked this store, so the
    /// verifications the account's record and attempt rows hold refer to it (Android FIX-A3's
    /// `migration_checked`). Absent in a store's first open, in one recreated after a logout purge
    /// or a launch cleanup, or one rebound to another server account (`fencePrincipal`).
    static let migrationCheckedMeta = "migration_checked"

    /// The automatic migration's preconditions (§5.5 step 1), on queue: those of the explicit copy
    /// (linked, principal, a complete snapshot of it), plus no resnapshot pending — a shadow a 409
    /// resync made stale may still list rows the server erased, and a completion checked against it
    /// would never resend them. Returns the scope, the store's `resync_generation`, whether the step
    /// has checked this store (`migration_checked`), and the step's time: the estimated server now
    /// (the device clock only while the store has no server time), read in the same turn.
    func migrationPreconditions() throws -> (scope: String, resyncGeneration: Int64, storeChecked: Bool, serverNow: Date) {
        return try self.onQueue {
            let (store, scope) = try self.importPreconditions()
            do {
                guard try store.meta("needs_resnapshot") != "1" else { throw SGTasksCloudError.importRequiresCompleteSnapshot }
                let serverNow = self.state.estimatedServerNow(localNow: self.environment.now()) ?? self.environment.now()
                return (scope, try store.integerMeta("resync_generation") ?? 0, try store.meta(Self.migrationCheckedMeta) == "1", serverNow)
            } catch let error as SGTasksCloudError {
                throw error
            } catch {
                throw SGTasksCloudError.storageUnavailable
            }
        }
    }

    /// On queue: the step has checked this store (after voiding what was verified against an earlier
    /// one). A purge since closed it: the step stops and its successor is checked anew.
    func markMigrationChecked() throws {
        try self.onQueue {
            guard !self.isInvalidated else { throw SGTasksCloudError.accountRemoved }
            guard let store = self.store else { throw SGTasksCloudError.storageUnavailable }
            do {
                try store.setMeta(Self.migrationCheckedMeta, "1")
            } catch {
                if !store.isOpen { self.failStorage() }
                throw SGTasksCloudError.storageUnavailable
            }
        }
    }

    private func legacyMappings(scope: String) throws -> [TodoCloudImportMapping] {
        do {
            return try self.environment.legacy().existingCloudImportMappings(accountPeerId: self.accountPeerId, principalScope: scope)
        } catch {
            throw SGTasksCloudError.storageUnavailable
        }
    }

    /// The explicit copy's rules: exactly R3 under `.legacy`; else R4 in the locale of the account's
    /// migration record (a resend then seals the bytes of the first copy), else `locale`, else English,
    /// with times checked against the migration's first enqueue while it re-checks the current scope
    /// (`SGTasksMigration.explicitCopyTimeBase`; its re-check rebuilds these rows too), else against
    /// the estimated server now.
    func explicitImportRules(locale: TodoCloudMigrationRecord.Locale?) -> SGTasksImportRules {
        guard self.permission != .legacy else { return .r3 }
        let record = try? self.environment.legacy().cloudMigrationRecord(accountPeerId: self.accountPeerId)
        let scope = self.environment.transport.principal(accountPeerId: self.accountPeerId).map { Self.importScope(origin: self.environment.originScope, principal: $0) }
        return .r4(SGTasksMigrationNormalizer(locale: record?.normalizationLocale ?? locale ?? .en), normalizedAt: SGTasksMigration.explicitCopyTimeBase(record: record, scope: scope))
    }

    /// Builds the consent preview from one immutable snapshot of the local Tasks. `locale` names the
    /// placeholder language of an R4 copy when the account has no migration record yet.
    public func prepareLegacyImport(locale: TodoCloudMigrationRecord.Locale? = nil) throws -> SGTasksCloudImportPreview {
        return try self.preparedImport(rules: self.explicitImportRules(locale: locale)).preview
    }

    /// The preview and, for the automatic migration, its content-free summary.
    func preparedImport(rules: SGTasksImportRules) throws -> (preview: SGTasksCloudImportPreview, summary: SGTasksImportSummary) {
        let snapshot: TodoCloudImportSnapshot
        do {
            snapshot = try self.environment.legacy().cloudImportSnapshot()
        } catch {
            throw SGTasksCloudError.storageUnavailable
        }
        return try self.onQueue {
            let (store, scope) = try self.importPreconditions()
            let mappings = try self.legacyMappings(scope: scope)
            let now = self.state.estimatedServerNow(localNow: self.environment.now()) ?? self.environment.now()
            let plan: ImportPlan
            do {
                plan = try self.importPlan(snapshot: snapshot, mappings: mappings, store: store, now: now, rules: rules)
            } catch {
                throw SGTasksCloudError.storageUnavailable
            }
            let folders = snapshot.folders.map { folder in
                SGTasksCloudImportPreview.Folder(
                    legacyId: folder.id, title: folder.title,
                    taskCount: snapshot.tasks.filter { $0.folderIncarnation == folder.incarnation }.count,
                    isLegacyInbox: folder.id == TodoStorage.inboxFolderId,
                    status: plan.folderStatus[folder.incarnation] ?? .needsCorrection(.invalidTitle)
                )
            }
            let tasks = snapshot.tasks.map { item in
                SGTasksCloudImportPreview.Task(
                    legacyId: item.task.id, title: item.task.title, folderLegacyId: item.task.folderId,
                    status: plan.taskStatus[Self.taskKey(item)] ?? .needsCorrection(.parentFolderNeedsCorrection)
                )
            }
            var summary = SGTasksImportSummary()
            let covered: (SGTasksCloudImportPreview.ItemStatus?) -> Bool = { status in
                status == .importable || status == .resendPreviousAttempt || status == .importPending || status == .alreadyInCloud
            }
            for folder in snapshot.folders where !plan.cloudInboxFolders.contains(folder.incarnation) {
                let status = plan.folderStatus[folder.incarnation]
                summary.add(status, mapped: plan.mappedFolders.contains(folder.incarnation), covered: covered(status), isList: true)
            }
            for item in snapshot.tasks {
                let key = Self.taskKey(item)
                let status = plan.taskStatus[key]
                summary.add(status, mapped: plan.mappedTasks.contains(key), covered: covered(status), isList: false)
            }
            return (SGTasksCloudImportPreview(folders: folders, tasks: tasks, accountPeerId: self.accountPeerId, snapshot: snapshot), summary)
        }
    }

    /// The user consented to this exact preview: map (immutably, durably) and enqueue its
    /// importable rows. Counts report only operations actually enqueued now. `locale`: as for
    /// `prepareLegacyImport(locale:)`, the same value.
    public func commitLegacyImport(_ preview: SGTasksCloudImportPreview, locale: TodoCloudMigrationRecord.Locale? = nil) throws -> SGTasksCloudImportResult {
        return try self.commitLegacyImport(preview, rules: self.explicitImportRules(locale: locale), origin: .user, expectedConsentEpoch: nil, mappedOnly: false)
    }

    /// Both flows. The automatic one passes `origin: .migration` (batch route only, server
    /// exemption), the consent epoch its step captured (a withdrawal since then enqueues nothing)
    /// and, when it only re-checks an earlier copy, `mappedOnly` (rows without a mapping are new
    /// local rows: they are offered to the explicit copy, never copied automatically).
    func commitLegacyImport(_ preview: SGTasksCloudImportPreview, rules: SGTasksImportRules, origin: SGTasksWire.MutationOrigin, expectedConsentEpoch: Int64?, mappedOnly: Bool) throws -> SGTasksCloudImportResult {
        guard preview.accountPeerId == self.accountPeerId else { throw SGTasksCloudError.actionNotAllowed }
        let snapshot = preview.snapshot
        let (plan, scope): (ImportPlan, String) = try self.onQueue {
            let (store, scope) = try self.importPreconditions()
            let existing = try self.legacyMappings(scope: scope)
            do {
                let now = self.state.estimatedServerNow(localNow: self.environment.now()) ?? self.environment.now()
                return (try self.importPlan(snapshot: snapshot, mappings: existing, store: store, now: now, rules: rules), scope)
            } catch {
                throw SGTasksCloudError.storageUnavailable
            }
        }
        let importableFolders = snapshot.folders.filter {
            !plan.cloudInboxFolders.contains($0.incarnation) && Self.isEnqueued(plan.folderStatus[$0.incarnation]) && (!mappedOnly || plan.mappedFolders.contains($0.incarnation))
        }
        let enqueuedFolders = Set(importableFolders.map { $0.incarnation })
        // Parents already in the cloud still need their (existing) mapping for dependent tasks; a
        // folder that is neither enqueued now nor mapped gets no mapping (and so none of its tasks
        // goes now); the Cloud Inbox has none.
        let parentFolders = snapshot.folders.filter {
            !plan.cloudInboxFolders.contains($0.incarnation) && Self.acceptsChildren(plan.folderStatus[$0.incarnation])
                && (enqueuedFolders.contains($0.incarnation) || plan.mappedFolders.contains($0.incarnation))
        }
        let parents = Set(parentFolders.map { $0.incarnation }).union(plan.cloudInboxFolders)
        let importableTasks = snapshot.tasks.filter {
            guard let incarnation = $0.folderIncarnation, parents.contains(incarnation) else { return false }
            return Self.isEnqueued(plan.taskStatus[Self.taskKey($0)]) && (!mappedOnly || plan.mappedTasks.contains(Self.taskKey($0)))
        }
        let toMap = TodoCloudImportSnapshot(folders: parentFolders, tasks: importableTasks, storageId: snapshot.storageId, wipeGeneration: snapshot.wipeGeneration)
        let mappings: [TodoCloudImportMapping]
        do {
            mappings = try self.environment.legacy().cloudImportMappings(for: toMap, accountPeerId: self.accountPeerId, principalScope: scope) {
                (cloudId: SGTasksWire.UUID.generate().rawValue, mutationId: SGTasksWire.UUID.generate().rawValue)
            }
            // Resend-once: the rows about to be resent are re-verified first (durably), so their
            // next acknowledgement counts at this generation and they are never resent twice.
            try self.environment.legacy().markImportReverified(mutationIds: plan.reverify.sorted(), generation: plan.resyncGeneration)
        } catch TodoDatabaseError.invalidSnapshot {
            throw SGTasksCloudError.importSnapshotStale
        } catch {
            throw SGTasksCloudError.storageUnavailable
        }
        if origin == .migration, let hook = Self.migrationMintedHook {
            hook(self)
        }
        var byKey: [String: TodoCloudImportMapping] = [:]
        for mapping in mappings {
            byKey[Self.mappingKey(mapping.kind, mapping.legacyId, mapping.legacyIncarnation)] = mapping
        }
        var statuses = snapshot.tasks.compactMap { plan.taskStatus[Self.taskKey($0)] }
        for folder in snapshot.folders where !plan.cloudInboxFolders.contains(folder.incarnation) {
            if let status = plan.folderStatus[folder.incarnation] {
                statuses.append(status)
            }
        }
        let alreadyImported = statuses.filter { $0 == .alreadyInCloud || $0 == .importPending }.count
        let removed = statuses.filter { $0 == .removedFromCloud }.count
        let blocked = statuses.filter { $0 == .importBlocked }.count
        let needsCorrection = statuses.filter { if case .needsCorrection = $0 { return true } else { return false } }.count

        return try self.mutate { store, state in
            // The server account must still be the one the mapping scope was taken for.
            guard let principal = try store.meta("principal"), Self.importScope(origin: self.environment.originScope, principal: principal) == scope,
                  self.environment.transport.principal(accountPeerId: self.accountPeerId) == principal else {
                throw SGTasksCloudError.importSnapshotStale
            }
            let entries = try store.entries()
            let now = state.estimatedServerNow(localNow: self.environment.now()) ?? self.environment.now()
            // The plan's own reading of resend-once (its mappings predate the re-verify above).
            let resyncGeneration: Int64?
            if case .r4 = rules {
                resyncGeneration = plan.resyncGeneration
            } else {
                resyncGeneration = nil
            }
            var recheck = Set<String>()
            var lists = 0
            var tasks = 0
            var resent = 0
            var skipped = alreadyImported
            for folder in importableFolders {
                guard let mapping = byKey[Self.mappingKey(.folder, folder.id, folder.incarnation)],
                      let listId = SGTasksWire.UUID(mapping.cloudId), let mutationId = SGTasksWire.UUID(mapping.createMutationId) else {
                    throw SGTasksCloudError.storageUnavailable
                }
                guard Self.isEnqueued(try Self.status(of: mapping, kind: "list", store: store, entries: entries, resyncGeneration: resyncGeneration, reverify: &recheck)) else {
                    skipped += 1
                    continue
                }
                let create: SGTasksWire.ListCreate
                switch rules {
                case .r3:
                    create = SGTasksWire.ListCreate(listId: listId, title: folder.title, sortOrder: Int32(folder.sortOrder), createdAt: Self.validInstant(folder.createdDate, now: now))
                case .r4:
                    guard let list = plan.lists[folder.incarnation] else { throw SGTasksCloudError.storageUnavailable }
                    create = SGTasksWire.ListCreate(listId: listId, title: list.title, sortOrder: list.sortOrder, createdAt: list.createdAt)
                }
                if plan.reverify.contains(mapping.createMutationId) {
                    // Its old acknowledgement must not reach the local database after the re-verify.
                    try store.removePendingImportAck(mapping.createMutationId)
                }
                try self.insert(.listCreate(create), keys: [SGTasksCloudKey.list(listId)], sealed: true, store: store, mutationId: mutationId, origin: origin, expectedConsentEpoch: expectedConsentEpoch)
                lists += 1
                if mapping.wasAttempted { resent += 1 }
            }
            for item in importableTasks {
                guard let incarnation = item.folderIncarnation,
                      let mapping = byKey[Self.mappingKey(.task, item.task.id, incarnation)],
                      let taskId = SGTasksWire.UUID(mapping.cloudId), let mutationId = SGTasksWire.UUID(mapping.createMutationId) else {
                    throw SGTasksCloudError.storageUnavailable
                }
                // A task of the Cloud Inbox carries no list; any other follows its parent's mapping.
                var listId: SGTasksWire.UUID?
                if !plan.cloudInboxFolders.contains(incarnation) {
                    guard let parentFolder = parentFolders.first(where: { $0.incarnation == incarnation }),
                          let parent = byKey[Self.mappingKey(.folder, parentFolder.id, incarnation)],
                          let parentId = SGTasksWire.UUID(parent.cloudId) else {
                        throw SGTasksCloudError.storageUnavailable
                    }
                    listId = parentId
                }
                guard Self.isEnqueued(try Self.status(of: mapping, kind: "task", store: store, entries: entries, resyncGeneration: resyncGeneration, reverify: &recheck)) else {
                    skipped += 1
                    continue
                }
                let create: SGTasksWire.TaskCreate
                switch rules {
                case .r3:
                    let task = item.task
                    let annotation = task.assignee.flatMap { assignee in
                        SGTasksWire.TelegramId(cloudUserPeerId: assignee.peerId).map { SGTasksWire.Annotation(telegramUserId: $0, displayName: assignee.displayName) }
                    }
                    let content = SGTasksWire.Content(listId: listId, title: task.title, description: task.description, dueAt: task.dueAt, priority: task.priority, sortOrder: Int32(task.sortOrder), annotation: annotation)
                    // Unknown completion time stays unknown (null), never an invented server-now.
                    let completedAt = task.isCompleted ? task.completedAt.flatMap { Self.validInstant(Int64($0), now: now) } : nil
                    create = SGTasksWire.TaskCreate(taskId: taskId, content: content, createdAt: Self.validInstant(Int64(task.createdDate), now: now), isCompleted: task.isCompleted, completedAt: completedAt)
                case .r4:
                    // Never the assignee: `content(listId:)` carries no annotation (F16).
                    guard let normalized = plan.tasks[Self.taskKey(item)] else { throw SGTasksCloudError.storageUnavailable }
                    create = SGTasksWire.TaskCreate(taskId: taskId, content: normalized.content(listId: listId), createdAt: normalized.createdAt, isCompleted: normalized.isCompleted, completedAt: normalized.completedAt)
                }
                if plan.reverify.contains(mapping.createMutationId) {
                    try store.removePendingImportAck(mapping.createMutationId)
                }
                let keys = [SGTasksCloudKey.task(taskId)] + (listId.map { [SGTasksCloudKey.list($0)] } ?? [])
                try self.insert(.taskCreate(create), keys: keys, sealed: true, store: store, mutationId: mutationId, origin: origin, expectedConsentEpoch: expectedConsentEpoch)
                tasks += 1
                if mapping.wasAttempted { resent += 1 }
            }
            return SGTasksCloudImportResult(enqueuedLists: lists, enqueuedTasks: tasks, resentPreviousAttempts: resent, skippedAlreadyImported: skipped, removedFromCloud: removed, blocked: blocked, needsCorrection: needsCorrection)
        }
    }

    /// Import provenance for a create (content-free, in the local Tasks database, survives logout):
    /// `acknowledged == false` right before its first send, `true` on its receipt. Non-import
    /// creates are ignored by the database. A lost record only weakens the preview label (an
    /// attempted row shows as importable, a committed one as a resend); the identity resent is
    /// always the same reserved one, so no second copy can be created.
    @discardableResult
    func recordImportProvenance(mutationId: String, acknowledged: Bool) -> Bool {
        do {
            try self.environment.legacy().recordCloudImportAttempt(createMutationId: mutationId, acknowledged: acknowledged)
            return true
        } catch {
            print("[SGTasksCloud] import provenance not recorded")
            return false
        }
    }

    /// Deletes a proven acknowledged entry in the CURRENT cloud transaction. A create's id is kept
    /// (content-free) in `import_ack_pending` in the same transaction, so its "acknowledged" import
    /// provenance reaches the device-local Tasks database later even if that database is
    /// unavailable now; the cloud board never waits for it.
    func retireAcknowledged(_ entry: SGTasksCloudStoredEntry, store: SGTasksCloudStore) throws {
        if entry.kind.isCreation {
            try store.addPendingImportAck(entry.mutationId)
        }
        try store.deleteEntry(seq: entry.seq)
    }

    /// On queue, outside a transaction: hands pending acknowledged provenance to the device-local
    /// Tasks database (non-import ids are no-ops there); each id leaves the queue only on success.
    func flushPendingImportAcks() {
        guard let store = self.store, let pending = try? store.pendingImportAcks(), !pending.isEmpty else { return }
        for mutationId in pending where self.recordImportProvenance(mutationId: mutationId, acknowledged: true) {
            do {
                try store.removePendingImportAck(mutationId)
            } catch {
                if !store.isOpen { self.failStorage() }
                return
            }
        }
    }
}

extension SGTasksImportSummary {
    mutating func add(_ status: SGTasksCloudImportPreview.ItemStatus?, mapped: Bool, covered: Bool, isList: Bool) {
        if mapped, let status = status {
            self.mappedStatuses.append(status)
        }
        if let status = status, status.isEnqueuedByConsent {
            self.enqueueable += 1
            if mapped {
                self.mappedEnqueueable += 1
            }
        }
        if case .needsCorrection? = status {
            self.keptLocal += 1
        }
        if covered {
            if isList {
                self.lists += 1
            } else {
                self.tasks += 1
            }
        }
    }
}
