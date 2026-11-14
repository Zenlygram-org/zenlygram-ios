import Foundation

// MARK: - Zenlygram Tasks R4: cut-over of the local board (design 30 §7.5; Android `TasksCutOver.java`)
//
// Pure, the same table on both platforms. Invariant I1 (`S/docs/entitlement.md`): the local board is
// read-only only while a copy of its rows exists in a cloud store the user can open on this device
// and edit offline — the account's own outbox/overlay from `enqueued` on, or the signed-in owner
// account's. The sync coordinator recomputes it on every input change; the board, the scope picker
// and the write fence read the result.
//
// iOS adds `ownCopyOnDevice` (like `ownerActive`): a Telegram logout purges the account's cloud store
// but keeps its record and mappings (the device database is device-wide), so after a re-login the
// record alone no longer proves the copy is here. The board is then never hidden (`retired`); it
// stays a readable archive until the copy is back: queued again by the step, or, for a confirmed
// copy, in the account's next complete snapshot once the migration step has checked it against that
// store at its current `resync_generation` (a new store, a rebind to another server account and a
// 409 resync each call for that check again).
//
// What the coordinator reads for these inputs (the device database, the account's cloud store) is in
// SGTasksCutOver+Inputs.swift: it needs the repository, which the host scripts that build this file
// (run-sync-policy-tests.sh, run-cloud-model-tests.sh) do not compile.

public enum TasksCutOver: Equatable {
    public enum ArchiveReason: Equatable {
        /// The copy is enqueued and not confirmed yet (progress is shown; the copies are editable in
        /// Cloud, offline too). Also a copy whose account store is not on this device (yet): a logout
        /// purged it, or it does not open — and a confirmed copy the step has not yet checked against
        /// this store (a new store, a 409 since the completion, a rebind): the archive stays readable
        /// until the copy is back (a completed one shows no progress: nothing is being copied).
        case migrating
        /// The copy is confirmed but this many local rows are not in Cloud ("Copy to Cloud").
        case newRows(Int)
        /// The rows belong to another account signed in on this device, whose copy exists.
        case otherAccount
    }

    /// The local board is writable as before R4 (default scope: the stored choice).
    case none
    /// The local board is a read-only archive (default scope: Cloud).
    case archive(ArchiveReason)
    /// Every local row is confirmed in Cloud: the local board is hidden (always Cloud).
    case retired

    /// Whether checked local writes of the account are refused (`TodoDatabaseError.archived`).
    public var isReadOnly: Bool {
        switch self {
        case .none:
            return false
        case .archive, .retired:
            return true
        }
    }

    public struct Inputs: Equatable {
        /// P (iOS adds `legacy`).
        public var permission: SGTasksSyncPermission
        /// R: the account's migration record (`state` and `principalScope` are read).
        public var record: TodoCloudMigrationRecord?
        /// S: the import scope of the account's current binding (nil when unbound).
        public var currentScope: String?
        /// U: live local rows without a mapping of the record's scope.
        public var unmappedLiveRows: Int
        /// The device owner marker names ANOTHER account that is signed in on this device and whose
        /// record is `enqueued`/`completed` with the scope of its current binding.
        public var ownerActive: Bool
        /// I1 for rows 3–5: the record's copy sits in the account's own cloud store on this device
        /// (`isOwnCopyOnDevice`). The sync coordinator always passes it (`Inputs.read`); the default
        /// (the copy is here) models a bound, checked store with a complete snapshot.
        public var ownCopyOnDevice: Bool

        public init(permission: SGTasksSyncPermission, record: TodoCloudMigrationRecord?, currentScope: String?, unmappedLiveRows: Int, ownerActive: Bool, ownCopyOnDevice: Bool = true) {
            self.permission = permission
            self.record = record
            self.currentScope = currentScope
            self.unmappedLiveRows = unmappedLiveRows
            self.ownerActive = ownerActive
            self.ownCopyOnDevice = ownCopyOnDevice
        }
    }

    /// What the account's cloud store on this device holds, and what the migration step has checked
    /// there; read on the repository's queue (`SGTasksCloudRepository.cutOverStoreFacts()`, nil when
    /// the store does not open).
    public struct StoreFacts: Equatable {
        /// The import scope of the store's bound server account; nil while the store is unbound (one
        /// created after a logout purge, before its first cycle) or the value is unreadable.
        public var boundScope: String?
        /// The store holds a complete snapshot of that server account.
        public var hasCompleteSnapshot: Bool
        /// Unacknowledged migration creates in the store's outbox.
        public var pendingMigrationCreates: Int
        /// Cloud meta `migration_checked` is "1": the migration step has checked this store, so the
        /// record's verification refers to it. It dies with the file and with a rebind.
        public var migrationChecked: Bool
        /// Cloud meta `resync_generation` (0 when absent): +1 with every 409 resync.
        public var resyncGeneration: Int64

        public init(boundScope: String?, hasCompleteSnapshot: Bool, pendingMigrationCreates: Int, migrationChecked: Bool, resyncGeneration: Int64) {
            self.boundScope = boundScope
            self.hasCompleteSnapshot = hasCompleteSnapshot
            self.pendingMigrationCreates = pendingMigrationCreates
            self.migrationChecked = migrationChecked
            self.resyncGeneration = resyncGeneration
        }
    }

    /// I1 for rows 3–5: the record's copy (`enqueued`/`completed`) is on this device when the
    /// account's store is bound to the record's scope and holds either a complete snapshot of it (the
    /// confirmed rows) or the copy's queued creates (editable in Cloud, offline too). A confirmed copy
    /// (`completed`) counts only once the migration step has checked it against this store at its
    /// current generation (`migrationChecked`, and the record verified at `resyncGeneration` or
    /// later): exactly when the step would not check it again (`SGTasksMigration.runStep`), so a new
    /// store, a voided verification (-1) and a 409 since the completion read as "not here". Creates
    /// queued under another server account are not this copy; an unreadable store holds none.
    public static func isOwnCopyOnDevice(record: TodoCloudMigrationRecord?, store: StoreFacts?) -> Bool {
        guard let record = record, record.state == .enqueued || record.state == .completed,
              let recordScope = record.principalScope, let store = store, store.boundScope == recordScope else {
            return false
        }
        guard store.hasCompleteSnapshot || store.pendingMigrationCreates > 0 else {
            return false
        }
        if record.state == .completed {
            return store.migrationChecked && record.verifiedGeneration >= store.resyncGeneration
        }
        return true
    }

    /// I1 as the sync coordinator reads it: only an account with consent (P `waiting`/`allowed`)
    /// and a copy (`enqueued`/`completed`) has one to look for, and only then does `readStore` run
    /// (it opens the account's repository; nil = the store does not open).
    public static func isOwnCopyOnDevice(permission: SGTasksSyncPermission, record: TodoCloudMigrationRecord?, readStore: () -> StoreFacts?) -> Bool {
        guard permission == .waiting || permission == .allowed, let record = record, record.state == .enqueued || record.state == .completed else {
            return false
        }
        return Self.isOwnCopyOnDevice(record: record, store: readStore())
    }

    /// The §7.5 table, evaluated top-down. Rows 3–6 apply while P is `waiting` too (no flapping
    /// when a session drops after the copy started).
    public static func evaluate(_ inputs: Inputs) -> TasksCutOver {
        // 1. No consent (or a build without a Tasks backend): exactly as before.
        if inputs.permission == .legacy || inputs.permission == .forbidden {
            return .none
        }
        let record = inputs.record
        // 2. The account's server account changed since its claim: the coordinator records
        //    `skipped(scope_changed)` and releases the owner marker; the board stays writable.
        if let record = record, record.state == .claimed || record.state == .enqueued || record.state == .completed,
           let recordScope = record.principalScope, let currentScope = inputs.currentScope, recordScope != currentScope {
            return .none
        }
        switch record?.state {
        case .enqueued?:
            // 3. The copies exist in this account's outbox: editable in Cloud, offline too. Purged with
            //    a logout, they are re-enqueued by the step once the account is linked again and its
            //    snapshot is complete; until then the same readable archive.
            return .archive(.migrating)
        case .completed?:
            // 4./5. Confirmed; new local rows keep the archive visible with "Copy to Cloud".
            if inputs.unmappedLiveRows > 0 {
                return .archive(.newRows(inputs.unmappedLiveRows))
            }
            // 4. Hidden only while the copy is on this device: after a logout purged the account's
            //    store, or while it does not open, the device rows stay a readable archive.
            return inputs.ownCopyOnDevice ? .retired : .archive(.migrating)
        default:
            break
        }
        // 6. Another signed-in account owns the device rows and has its copy.
        if inputs.ownerActive {
            return .archive(.otherAccount)
        }
        // 7. Nothing copied yet (no record, a claim waiting for the link or for its step, released,
        //    skipped), or the owner is logged out / not copied yet / on another scope.
        return .none
    }
}
