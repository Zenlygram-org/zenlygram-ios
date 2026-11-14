import Foundation

// MARK: - Data Models

public struct TodoFolder: Equatable {
    public let id: String
    public var title: String
    public var sortOrder: Int
    public let createdDate: Int32

    // Old convenience init — saqlanadi, eski callerlar buzilmaydi
    public init(title: String) {
        self.id = UUID().uuidString
        self.title = title
        self.sortOrder = 0
        self.createdDate = Int32(Date().timeIntervalSince1970)
    }

    // Full init — SQLite layer ishlatadi
    public init(id: String, title: String, sortOrder: Int, createdDate: Int32) {
        self.id = id
        self.title = title
        self.sortOrder = sortOrder
        self.createdDate = createdDate
    }
}

/// A local contact annotation; it does not send or share the task with this peer.
public struct TodoAssignee: Equatable {
    public let peerId: Int64
    public let displayName: String

    public init(peerId: Int64, displayName: String) {
        self.peerId = peerId
        self.displayName = displayName
    }
}

public struct TodoTask: Equatable {
    public let id: String
    public let folderId: String
    public var title: String
    public var description: String?
    public var dueAt: Int32?
    public var assignee: TodoAssignee?
    public var priority: Int               // 0=none, 1=low, 2=normal, 3=high, 4=urgent
    public var isCompleted: Bool
    public var completedAt: Int32?
    public var sortOrder: Int
    public let createdDate: Int32
    public var updatedAt: Int32

    // Old convenience init — saqlanadi, eski callerlar buzilmaydi
    public init(folderId: String, title: String) {
        let now = Int32(Date().timeIntervalSince1970)
        self.id = UUID().uuidString
        self.folderId = folderId
        self.title = title
        self.description = nil
        self.dueAt = nil
        self.assignee = nil
        self.priority = 0
        self.isCompleted = false
        self.completedAt = nil
        self.sortOrder = 0
        self.createdDate = now
        self.updatedAt = now
    }

    // Full init — SQLite layer ishlatadi
    public init(
        id: String, folderId: String, title: String,
        description: String?, dueAt: Int32?, priority: Int,
        isCompleted: Bool, completedAt: Int32?,
        sortOrder: Int, createdDate: Int32, updatedAt: Int32,
        assignee: TodoAssignee? = nil
    ) {
        self.id = id
        self.folderId = folderId
        self.title = title
        self.description = description
        self.dueAt = dueAt
        self.assignee = assignee
        self.priority = priority
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.sortOrder = sortOrder
        self.createdDate = createdDate
        self.updatedAt = updatedAt
    }
}

// MARK: - Explicit cloud import snapshot (content stays local; only the consenting account maps it)

public struct TodoCloudImportFolder: Equatable {
    public let id: String
    /// Local-only identity of this exact folder insertion; never sent on the wire.
    public let incarnation: String
    public let title: String
    public let sortOrder: Int64
    public let createdDate: Int64
}

public struct TodoCloudImportTask: Equatable {
    public let task: TodoTask
    /// The parent folder's incarnation at consent; nil when the row has no existing parent.
    public let folderIncarnation: String?
}

/// wf15 §7.2 item 1: one device task with a local assignee (`TodoDatabase.liveTasksWithAssignee()`),
/// with its parent folder's current incarnation — the key its import mapping was minted under.
public struct TodoLiveAssigneeRow: Equatable {
    public let task: TodoTask
    /// nil when the row's parent folder no longer exists (then it has no mapping either).
    public let folderIncarnation: String?

    public init(task: TodoTask, folderIncarnation: String?) {
        self.task = task
        self.folderIncarnation = folderIncarnation
    }
}

/// An immutable row snapshot taken at consent. It is bound to the database instance and its
/// wipe generation so a final-logout wipe in between invalidates it.
public struct TodoCloudImportSnapshot: Equatable {
    public let folders: [TodoCloudImportFolder]
    public let tasks: [TodoCloudImportTask]
    let storageId: UUID
    let wipeGeneration: UInt64
}

/// Content-free, immutable mapping row: (account, legacy entity, incarnation) -> cloud identity.
public struct TodoCloudImportMapping: Equatable {
    public enum Kind: String {
        case folder
        case task
    }

    public let kind: Kind
    public let legacyId: String
    /// The folder's own incarnation, or for a task its parent folder's incarnation at consent.
    public let legacyIncarnation: String
    public let cloudId: String
    public let createMutationId: String
    /// Its create was handed to the network at least once (content-free, survives logout).
    public let wasAttempted: Bool
    /// The server acknowledged this create at least once (content-free, survives logout).
    public let isAcknowledged: Bool
    /// R4 resend-once bookkeeping (v5): the cloud store's `resync_generation` at which this
    /// acknowledged create was last re-verified (0 = never).
    public let verifiedGeneration: Int64
}

// MARK: - Zenlygram R4: device owner marker and the automatic migration record (v5)

/// The device-wide marker of the account the local Tasks database belongs to (design 30 §5.4):
/// the first account on this device whose data consent is granted. Content-free.
public struct TodoCloudDeviceOwner: Equatable {
    public enum State: String {
        case claimed
        case completed
        case released
    }

    public let accountPeerId: Int64
    public let state: State
    public let claimedAt: Int64
    public let completedAt: Int64?
    public let releasedAt: Int64?
    public let releaseReason: String?
}

/// What `claimCloudDevice` found.
public enum TodoCloudClaim: Equatable {
    /// The marker was free (or this account's own released one): it is this account's now.
    case claimed
    /// It already was this account's (claimed or completed).
    case alreadyOwner
    /// Another account holds it.
    case ownedByOther
    /// Another account's released marker: only that account may claim it again.
    case releasedByOther
}

/// One account's automatic migration of the device database (design 30 §5.4, §5.5). Content-free.
public struct TodoCloudMigrationRecord: Equatable {
    public enum State: String {
        case claimed
        case enqueued
        case completed
        case released
        case skipped
    }

    public enum Reason: String {
        /// skipped: the account already copied rows explicitly (a mapping in any scope).
        case existingMappings = "existing_mappings"
        /// skipped: the device database belongs to another account.
        case deviceOwnedByOther = "device_owned_by_other"
        /// skipped: the account's server account changed after the claim.
        case scopeChanged = "scope_changed"
        /// released: the account's data consent was withdrawn.
        case withdrawn
        /// released: the account was erased.
        case erased
    }

    /// `normalization_locale`: the placeholders of the copy are in this language for good, so a
    /// rerun seals byte-identical creates.
    public enum Locale: String, CaseIterable {
        case uz
        case ru
        case en

        /// `uz` / `ru` by their language code, anything else `en` (the shipped languages).
        public init(languageCode: String) {
            let primary = languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            self = Locale(rawValue: primary) ?? .en
        }
    }

    public let accountPeerId: Int64
    public var state: State
    public var reason: Reason?
    /// `importScope(origin:principal:)` of the copy; nil while a consent-time claim waits for the link.
    public var principalScope: String?
    public var normalizationLocale: Locale
    public var claimedAt: Int64
    public var enqueuedAt: Int64?
    public var completedAt: Int64?
    /// The cloud store's `resync_generation` the completion was checked at.
    public var verifiedGeneration: Int64
    public var lists: Int
    public var tasks: Int
    public var keptLocal: Int

    public init(accountPeerId: Int64, state: State, reason: Reason? = nil, principalScope: String? = nil, normalizationLocale: Locale, claimedAt: Int64, enqueuedAt: Int64? = nil, completedAt: Int64? = nil, verifiedGeneration: Int64 = 0, lists: Int = 0, tasks: Int = 0, keptLocal: Int = 0) {
        self.accountPeerId = accountPeerId
        self.state = state
        self.reason = reason
        self.principalScope = principalScope
        self.normalizationLocale = normalizationLocale
        self.claimedAt = claimedAt
        self.enqueuedAt = enqueuedAt
        self.completedAt = completedAt
        self.verifiedGeneration = verifiedGeneration
        self.lists = lists
        self.tasks = tasks
        self.keptLocal = keptLocal
    }
}

/// Why `releaseCloudDevice` runs (design 30 §5.4).
public enum TodoCloudRelease: String {
    /// Consent withdrawn: the account's mappings are voided, its record becomes `released(withdrawn)`.
    case withdrawn
    /// Account erased: the account's mappings and record are deleted.
    case erased
    /// The account's server account changed: its record becomes `skipped(scope_changed)`; the
    /// mappings stay (they still guard the explicit copy into the old cloud).
    case scopeChanged = "scope_changed"
}

/// Whether a checked local write may run now for an account (design 30 §5.4).
public enum TodoWriteFence: Equatable {
    case open
    /// A migration step is copying the device database right now (typically < 1 s): retry soon.
    case migrating
    /// The account's local board is a read-only archive (cut-over).
    case archived
}

// MARK: - Storage Facade
//
// Shared facade above TodoDatabase (SQLite). The Tasks board uses checked mutations
// for quick-add, editing, completion and Undo; list management retains the existing
// folder APIs. Title validation is pure and does not open the database.
//
// R4 write fence (design 30 §5.4): a checked write made `asAccount` an account is refused with
// `TodoDatabaseError.archived` while that account's cut-over makes the local board read-only, and
// with `.migrating` while a migration step copies the device database. The facade checks before it
// touches the database, and the database checks again on its queue, so no write can land between a
// migration step's snapshot and its enqueue. Writes without an account, and the caller-less legacy
// writes, are never fenced.

public final class TodoStorage {
    public static let inboxFolderId = "sgtasks.inbox"
    public static let taskTitleLimit = 200
    public static let folderTitleLimit = 100
    public static let maximumTitleUTF8Bytes = 8192
    private static let assigneeNameLimit = 256
    private static let maximumAssigneeNameUTF8Bytes = 4096

    private static let writeFenceLock = NSLock()
    private static var writeFenceSource: (Int64) -> TodoWriteFence = { _ in .open }

    /// The fence of an account's checked writes; `.open` until the sync coordinator installs its
    /// source. It must only read cached values: it is called on the database queue, so it may
    /// never call back into `TodoDatabase`.
    public static var writeFence: (Int64) -> TodoWriteFence {
        get {
            self.writeFenceLock.lock()
            defer { self.writeFenceLock.unlock() }
            return self.writeFenceSource
        }
        set {
            self.writeFenceLock.lock()
            self.writeFenceSource = newValue
            self.writeFenceLock.unlock()
        }
    }

    /// Refuses a checked write of `accountPeerId` the fence holds; nil (no account) always passes.
    static func checkWriteFence(_ accountPeerId: Int64?) throws {
        guard let accountPeerId = accountPeerId else { return }
        switch Self.writeFence(accountPeerId) {
        case .open:
            return
        case .migrating:
            throw TodoDatabaseError.migrating
        case .archived:
            throw TodoDatabaseError.archived
        }
    }

    /// Throws if storage initialization failed or its connection is no longer available.
    public static func checkAvailability() throws {
        try TodoDatabase.shared.checkAvailability()
    }

    /// Pure shared policy for UI preflight and database writes; never opens the database.
    public static func validatedTitle(_ title: String, limit: Int) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= Self.maximumTitleUTF8Bytes, trimmed.count <= limit,
              Self.containsVisibleCharacter(trimmed) else { throw TodoDatabaseError.invalidTitle }
        return trimmed
    }

    /// Shared contact policy for picker preflight and writes; never opens the database.
    public static func validatedAssignee(peerId: Int64, displayName: String) throws -> TodoAssignee {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard peerId > 0, trimmed.utf8.count <= Self.maximumAssigneeNameUTF8Bytes,
              trimmed.count <= Self.assigneeNameLimit, Self.containsVisibleCharacter(trimmed) else {
            throw TodoDatabaseError.invalidAssignee
        }
        return TodoAssignee(peerId: peerId, displayName: trimmed)
    }

    private static func containsVisibleCharacter(_ value: String) -> Bool {
        return value.unicodeScalars.contains(where: { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .nonspacingMark, .spacingMark, .enclosingMark, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        })
    }

    /// Creates a validated task after the caller has passed the create-task entitlement gate.
    /// A nil folder lazily creates the stable inbox in the same transaction as the task.
    public static func createQuickTask(folderId: String?, title: String, inboxTitle: String, assignee: TodoAssignee? = nil, dueAt: Int32? = nil, asAccount accountPeerId: Int64? = nil) throws -> TodoTask {
        try Self.checkWriteFence(accountPeerId)
        return try TodoDatabase.shared.createQuickTask(folderId: folderId, title: title, inboxTitle: inboxTitle, assignee: assignee, dueAt: dueAt, asAccount: accountPeerId)
    }

    /// Creates a validated folder after the caller has passed the create-task entitlement gate.
    public static func createFolder(title: String, asAccount accountPeerId: Int64? = nil) throws -> TodoFolder {
        try Self.checkWriteFence(accountPeerId)
        return try TodoDatabase.shared.createFolder(title: title, asAccount: accountPeerId)
    }

    /// Changes only the title and update timestamp; existing metadata is never resubmitted.
    public static func renameTask(id: String, title: String, asAccount accountPeerId: Int64? = nil) throws {
        try Self.checkWriteFence(accountPeerId)
        try TodoDatabase.shared.renameTask(id: id, title: title, asAccount: accountPeerId)
    }

    /// Updates title and optional metadata without changing list, completion, order or other details.
    public static func updateTaskDetails(id: String, title: String, assignee: TodoAssignee?, dueAt: Int32?, asAccount accountPeerId: Int64? = nil) throws {
        try Self.checkWriteFence(accountPeerId)
        try TodoDatabase.shared.updateTaskDetails(id: id, title: title, assignee: assignee, dueAt: dueAt, asAccount: accountPeerId)
    }

    /// Sets completion explicitly. Repeating the current state leaves timestamps unchanged.
    public static func setTaskCompleted(id: String, isCompleted: Bool, asAccount accountPeerId: Int64? = nil) throws {
        try Self.checkWriteFence(accountPeerId)
        try TodoDatabase.shared.setTaskCompleted(id: id, isCompleted: isCompleted, asAccount: accountPeerId)
    }

    /// Atomically snapshots and deletes the persisted row, or returns nil if already absent.
    public static func deleteTaskForUndo(id: String, asAccount accountPeerId: Int64? = nil) throws -> TodoDeletedTaskSnapshot? {
        try Self.checkWriteFence(accountPeerId)
        return try TodoDatabase.shared.deleteTaskForUndo(id: id, asAccount: accountPeerId)
    }

    /// Restores an exact, non-revoked snapshot without replacing a task or recreating its folder.
    /// Undo is not a create operation and must remain ungated (by the entitlement; the write
    /// fence still applies to it).
    public static func restoreDeletedTask(_ snapshot: TodoDeletedTaskSnapshot, asAccount accountPeerId: Int64? = nil) throws {
        try Self.checkWriteFence(accountPeerId)
        try TodoDatabase.shared.restoreDeletedTask(snapshot, asAccount: accountPeerId)
    }

    // MARK: - Folders

    public static func loadFolders() -> [TodoFolder] {
        return TodoDatabase.shared.loadFolders()
    }

    public static func addFolder(title: String) {
        TodoDatabase.shared.addFolder(title: title)
    }

    /// Checked rename (fenced for `accountPeerId`); throws `folderNotFound` for a missing folder.
    public static func renameFolder(id: String, title: String, asAccount accountPeerId: Int64?) throws {
        try Self.checkWriteFence(accountPeerId)
        try TodoDatabase.shared.updateFolderTitle(id: id, title: title, asAccount: accountPeerId)
    }

    /// Checked removal (fenced for `accountPeerId`); its tasks go with it. A missing folder is not
    /// an error.
    public static func removeFolder(id: String, asAccount accountPeerId: Int64?) throws {
        try Self.checkWriteFence(accountPeerId)
        try TodoDatabase.shared.removeFolder(id: id, asAccount: accountPeerId)
    }

    /// Unchecked rename, as before R4 (failures are ignored). The lists screen moves to the
    /// throwing `renameFolder(id:title:asAccount:)` with its cut-over UI.
    public static func renameFolder(id: String, title: String) {
        try? TodoDatabase.shared.updateFolderTitle(id: id, title: title)
    }

    /// Unchecked removal, as before R4 (failures are ignored); see `removeFolder(id:asAccount:)`.
    public static func removeFolder(id: String) {
        try? TodoDatabase.shared.removeFolder(id: id)
    }

    // MARK: - Tasks

    public static func loadTasks() -> [TodoTask] {
        return TodoDatabase.shared.loadTasks()
    }

    public static func loadTasks(folderId: String) -> [TodoTask] {
        return TodoDatabase.shared.loadTasks(folderId: folderId)
    }

    public static func loadTasksDueToday() -> [TodoTask] {
        return TodoDatabase.shared.loadTasksDueToday()
    }

    /// wf15 §7.2: the device rows with a local assignee, in the D4 sheet's order (read-only).
    public static func liveTasksWithAssignee() -> [TodoLiveAssigneeRow] {
        return TodoDatabase.shared.liveTasksWithAssignee()
    }

    public static func loadTasksUpcoming() -> [TodoTask] {
        return TodoDatabase.shared.loadTasksUpcoming()
    }

    public static func addTask(folderId: String, title: String) {
        _ = TodoDatabase.shared.addTask(folderId: folderId, title: title)
    }

    @discardableResult
    public static func addTask(folderId: String, title: String, description: String?, dueAt: Int32?, priority: Int) -> TodoTask {
        return TodoDatabase.shared.addTask(folderId: folderId, title: title, description: description, dueAt: dueAt, priority: priority)
    }

    public static func updateTask(id: String, title: String, description: String?, dueAt: Int32?, priority: Int) {
        TodoDatabase.shared.updateTask(id: id, title: title, description: description, dueAt: dueAt, priority: priority)
    }

    public static func toggleTask(id: String) {
        TodoDatabase.shared.toggleTask(id: id)
    }

    public static func removeTask(id: String) {
        TodoDatabase.shared.removeTask(id: id)
    }

    public static func reorderTasks(folderId: String, idsInOrder: [String]) {
        TodoDatabase.shared.reorderTasks(folderId: folderId, idsInOrder: idsInOrder)
    }

    public static func searchTasks(query: String) -> [TodoTask] {
        return TodoDatabase.shared.searchTasks(query: query)
    }

    public static func countActiveAndTotal(folderId: String) -> (done: Int, total: Int) {
        return TodoDatabase.shared.countActiveAndTotal(folderId: folderId)
    }

    // MARK: Zenlygram — explicit cloud import

    /// One transactional snapshot of all local folders and tasks; originals are never modified.
    public static func cloudImportSnapshot() throws -> TodoCloudImportSnapshot {
        return try TodoDatabase.shared.cloudImportSnapshot()
    }

    /// Reuses or mints the consenting account's immutable mapping for a still-current snapshot,
    /// scoped to the canonical server account (`principalScope`).
    public static func cloudImportMappings(for snapshot: TodoCloudImportSnapshot, accountPeerId: Int64, principalScope: String, mint: () -> (cloudId: String, mutationId: String)) throws -> [TodoCloudImportMapping] {
        return try TodoDatabase.shared.cloudImportMappings(for: snapshot, accountPeerId: accountPeerId, principalScope: principalScope, mint: mint)
    }

    // MARK: Zenlygram — logout cleanup (audit #96)

    /// Deletes every folder and task on this device (last account logged out).
    public static func removeAllData() {
        TodoDatabase.shared.removeAllData()
    }
}
