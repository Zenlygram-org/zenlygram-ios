import Foundation
import sqlcipher

// MARK: - SQLite-backed Todo storage
//
// Local-only SQLite database at:
//   ~/Documents/fenixuz_todo.sqlite
//
// Schema (user_version = 5):
//   folders: id TEXT PRIMARY KEY, title TEXT, sort_order INTEGER, created_at INTEGER,
//            incarnation TEXT (v3; a fresh local UUID minted on EVERY actual folder insert)
//   tasks:   id TEXT PRIMARY KEY, folder_id TEXT FK, title TEXT, description TEXT,
//            due_at INTEGER, priority INTEGER, is_completed INTEGER, completed_at INTEGER,
//            sort_order INTEGER, created_at INTEGER, updated_at INTEGER,
//            assignee_peer_id INTEGER, assignee_display_name TEXT (both nullable)
//   cloud_import_map (v4): content-free, immutable (account, server-account scope, legacy entity +
//            incarnation) -> cloud UUID + create mutation id; cloud_import_attempt (v4) records send/ack
//            provenance per create id (v5: + verified_generation, the R4 resend-once bookkeeping).
//            Both survive per-account logout; removed by the final-logout removeAllData step, and
//            per account by consent withdrawal / account erasure (releaseCloudDevice).
//   cloud_device_owner (v5): the single, content-free marker of the account the device database
//            belongs to (the first account whose data consent is granted, design 30 §5.4).
//   cloud_migration (v5): one content-free record per account of the automatic R4 migration.
//            Both survive per-account logout (a re-login resumes) and go with removeAllData.
//
// Migration: birinchi launch'da UserDefaults'dagi eski JSON'lar (todo_folders_list,
// todo_tasks_list) o'qib SQLite'ga ko'chiriladi, keyin migration flag o'rnatiladi.
//
// The folder incarnation is LOCAL metadata only (never a wire field). The special inbox id can be
// deleted and recreated within the same second, so (id, created_at) cannot tell two folders apart;
// ordinary title/order UPDATEs keep the incarnation.

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Storage failures contain no SQL, task text, or paths; presentation supplies localized messages.
public enum TodoDatabaseError: Error, Equatable {
    case invalidTitle
    case invalidAssignee
    case invalidDueDate
    case folderNotFound
    case taskNotFound
    case invalidSnapshot
    case sqlite(Int32)
    /// R4: the account's local board is a read-only archive (its rows were copied to Cloud). The UI
    /// shows its archive banner, never an error alert.
    case archived
    /// R4: a migration step is copying the device database right now (typically < 1 s); transient,
    /// the user retries.
    case migrating
}

/// An Undo capability issued only by this database after a committed deletion.
public struct TodoDeletedTaskSnapshot {
    public let task: TodoTask
    fileprivate let storageId: UUID
    fileprivate let wipeGeneration: UInt64

    fileprivate init(task: TodoTask, storageId: UUID, wipeGeneration: UInt64) {
        self.task = task
        self.storageId = storageId
        self.wipeGeneration = wipeGeneration
    }
}

public final class TodoDatabase {
    public static let shared = TodoDatabase()

    private var db: OpaquePointer?
    private var initializationError: TodoDatabaseError?
    private let queue = DispatchQueue(label: "uz.fenixuz.todo.db")
    private let dbPath: String
    private let defaults: UserDefaults
    private let storageId = UUID()
    private var wipeGeneration: UInt64 = 0

    private convenience init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.init(dbPath: docs.appendingPathComponent("fenixuz_todo.sqlite").path, defaults: .standard)
    }

    // Internal injection keeps host tests entirely outside user Documents and standard defaults.
    init(dbPath: String, defaults: UserDefaults) {
        self.dbPath = dbPath
        self.defaults = defaults
        self.openAndConfigure()
        do {
            try self.migrate()
            self.migrateFromUserDefaultsIfNeeded()
        } catch {
            let failure = error as? TodoDatabaseError ?? .sqlite(SQLITE_ERROR)
            self.initializationError = failure
            sqlite3_close(self.db)
            self.db = nil
            print("[FenixuzTodo] schema initialization failed: \(failure)")
        }
    }

    deinit {
        sqlite3_close(self.db)
    }

    /// Distinguishes unavailable storage from an empty board without querying or retrying.
    public func checkAvailability() throws {
        try self.queue.sync {
            if let failure = self.initializationError { throw failure }
            guard self.db != nil else { throw TodoDatabaseError.sqlite(SQLITE_MISUSE) }
        }
    }

    // MARK: - Connection lifecycle

    private func openAndConfigure() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let res = sqlite3_open_v2(self.dbPath, &self.db, flags, nil)
        if res != SQLITE_OK {
            print("[FenixuzTodo] sqlite3_open_v2 failed: \(res)")
            sqlite3_close(self.db)
            self.db = nil
            self.initializationError = .sqlite(res)
            return
        }
        self.exec("PRAGMA journal_mode = WAL;")
        self.exec("PRAGMA synchronous = NORMAL;")
        self.exec("PRAGMA foreign_keys = ON;")
        self.exec("PRAGMA busy_timeout = 3000;")
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let res = sqlite3_exec(self.db, sql, nil, nil, &err)
        if res != SQLITE_OK, let err = err {
            print("[FenixuzTodo] exec error: \(String(cString: err)) for SQL: \(sql)")
            sqlite3_free(err)
        }
    }

    private func userVersion() throws -> Int32 {
        return try self.withStatement("PRAGMA user_version;") { statement in
            try self.checkSQLite(sqlite3_step(statement), expected: SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }
    }

    // MARK: - Schema migrations

    private static let schemaVersion: Int32 = 5

    private func migrate() throws {
        guard try self.userVersion() < Self.schemaVersion else { return }
        try self.transaction {
            // Re-read under the write lock in case another connection just migrated.
            let version = try self.userVersion()
            if version < 1 {
                try self.executeChecked("""
                CREATE TABLE IF NOT EXISTS folders (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL
                );
                """)
                try self.executeChecked("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY,
                    folder_id TEXT REFERENCES folders(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    description TEXT,
                    due_at INTEGER,
                    priority INTEGER NOT NULL DEFAULT 0,
                    is_completed INTEGER NOT NULL DEFAULT 0,
                    completed_at INTEGER,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """)
                try self.executeChecked("CREATE INDEX IF NOT EXISTS idx_tasks_folder_sort ON tasks(folder_id, sort_order);")
                try self.executeChecked("CREATE INDEX IF NOT EXISTS idx_tasks_completed_due ON tasks(is_completed, due_at);")
                try self.executeChecked("CREATE INDEX IF NOT EXISTS idx_tasks_due_pending ON tasks(due_at) WHERE is_completed = 0;")
            }
            if version < 2 {
                try self.executeChecked("ALTER TABLE tasks ADD COLUMN assignee_peer_id INTEGER;")
                try self.executeChecked("ALTER TABLE tasks ADD COLUMN assignee_display_name TEXT;")
                try self.executeChecked("PRAGMA user_version = 2;")
            }
            if version < 3 {
                // Backfill atomically with the column: every existing folder gets its own incarnation.
                try self.executeChecked("ALTER TABLE folders ADD COLUMN incarnation TEXT;")
                let folderIds: [String] = try self.withStatement("SELECT id FROM folders;") { statement in
                    var ids: [String] = []
                    while true {
                        let result = sqlite3_step(statement)
                        if result == SQLITE_DONE { break }
                        try self.checkSQLite(result, expected: SQLITE_ROW)
                        ids.append(self.textFromRow(statement, column: 0))
                    }
                    return ids
                }
                for folderId in folderIds {
                    try self.writeOne("UPDATE folders SET incarnation = ? WHERE id = ?;") { statement in
                        try self.bindText(Self.newIncarnation(), at: 1, to: statement)
                        try self.bindText(folderId, at: 2, to: statement)
                    }
                }
                try self.executeChecked("PRAGMA user_version = 3;")
            }
            if version < 4 {
                // A pre-release working copy created an unscoped cloud_import_map under version 3.
                // It is content-free and never shipped: replace it rather than reuse ids whose
                // server account is unknown.
                let scoped = try self.withStatement("SELECT COUNT(*) FROM pragma_table_info('cloud_import_map') WHERE name = 'principal_scope';") { statement in
                    try self.checkSQLite(sqlite3_step(statement), expected: SQLITE_ROW)
                    return sqlite3_column_int(statement, 0) != 0
                }
                if !scoped {
                    try self.executeChecked("DROP TRIGGER IF EXISTS cloud_import_map_immutable;")
                    try self.executeChecked("DROP TABLE IF EXISTS cloud_import_ack;")
                    try self.executeChecked("DROP TABLE IF EXISTS cloud_import_map;")
                }
                // The scope is a one-way digest of the canonical server account the mapping was
                // minted for: a rebind/merge on the same native account never reuses old cloud ids.
                try self.executeChecked("""
                CREATE TABLE IF NOT EXISTS cloud_import_map (
                    account_peer_id INTEGER NOT NULL,
                    principal_scope TEXT NOT NULL,
                    legacy_kind TEXT NOT NULL CHECK (legacy_kind IN ('folder', 'task')),
                    legacy_id TEXT NOT NULL,
                    legacy_incarnation TEXT NOT NULL,
                    cloud_id TEXT NOT NULL UNIQUE,
                    create_mutation_id TEXT NOT NULL UNIQUE,
                    PRIMARY KEY (account_peer_id, principal_scope, legacy_kind, legacy_id, legacy_incarnation)
                ) WITHOUT ROWID;
                """)
                try self.executeChecked("""
                CREATE TRIGGER IF NOT EXISTS cloud_import_map_immutable BEFORE UPDATE ON cloud_import_map
                BEGIN SELECT RAISE(ABORT, 'cloud_import_map is immutable'); END;
                """)
                // Content-free provenance of a mapped create: recorded before its first send
                // (`acknowledged = 0`) and marked when the server acknowledged it, so a re-import can
                // tell "never left the device" from "attempted" and "committed, since removed".
                try self.executeChecked("""
                CREATE TABLE IF NOT EXISTS cloud_import_attempt (
                    create_mutation_id TEXT PRIMARY KEY REFERENCES cloud_import_map(create_mutation_id) ON DELETE CASCADE,
                    acknowledged INTEGER NOT NULL DEFAULT 0 CHECK (acknowledged IN (0, 1))
                ) WITHOUT ROWID;
                """)
                try self.executeChecked("PRAGMA user_version = 4;")
            }
            if version < 5 {
                // R4 (design 30 §5.4): the device owner marker (one row) and the per-account record
                // of the automatic migration, both content-free.
                try self.executeChecked("""
                CREATE TABLE IF NOT EXISTS cloud_device_owner (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    account_peer_id INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('claimed', 'completed', 'released')),
                    claimed_at INTEGER NOT NULL, completed_at INTEGER, released_at INTEGER, release_reason TEXT
                );
                """)
                try self.executeChecked("""
                CREATE TABLE IF NOT EXISTS cloud_migration (
                    account_peer_id INTEGER PRIMARY KEY,
                    state TEXT NOT NULL CHECK (state IN ('claimed', 'enqueued', 'completed', 'released', 'skipped')),
                    reason TEXT,
                    principal_scope TEXT,
                    normalization_locale TEXT NOT NULL CHECK (normalization_locale IN ('uz', 'ru', 'en')),
                    claimed_at INTEGER NOT NULL, enqueued_at INTEGER, completed_at INTEGER,
                    verified_generation INTEGER NOT NULL DEFAULT 0,
                    lists INTEGER NOT NULL DEFAULT 0, tasks INTEGER NOT NULL DEFAULT 0, kept_local INTEGER NOT NULL DEFAULT 0
                ) WITHOUT ROWID;
                """)
                // Resend-once bookkeeping of an acknowledged mapped create (§5.5). Added only when
                // missing, so a re-run of an interrupted upgrade cannot fail on it.
                let hasVerifiedGeneration = try self.withStatement("SELECT COUNT(*) FROM pragma_table_info('cloud_import_attempt') WHERE name = 'verified_generation';") { statement in
                    try self.checkSQLite(sqlite3_step(statement), expected: SQLITE_ROW)
                    return sqlite3_column_int(statement, 0) != 0
                }
                if !hasVerifiedGeneration {
                    try self.executeChecked("ALTER TABLE cloud_import_attempt ADD COLUMN verified_generation INTEGER NOT NULL DEFAULT 0;")
                }
                try self.executeChecked("PRAGMA user_version = 5;")
            }
        }
    }

    private static func newIncarnation() -> String {
        return UUID().uuidString.lowercased()
    }

    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = self.defaults
        let migrationKey = "todo_sqlite_migration_done"
        if defaults.bool(forKey: migrationKey) { return }

        // Eski folders
        if let data = defaults.data(forKey: "todo_folders_list"),
           let legacy = try? JSONDecoder().decode([LegacyFolder].self, from: data) {
            for (i, f) in legacy.enumerated() {
                self.insertFolder(id: f.id, title: f.title, sortOrder: i, createdAt: f.createdDate)
            }
        }
        // Eski tasks
        if let data = defaults.data(forKey: "todo_tasks_list"),
           let legacy = try? JSONDecoder().decode([LegacyTask].self, from: data) {
            for (i, t) in legacy.enumerated() {
                self.insertTask(
                    id: t.id, folderId: t.folderId, title: t.title,
                    description: nil, dueAt: nil, priority: 0,
                    isCompleted: t.isCompleted, completedAt: nil,
                    sortOrder: i, createdAt: t.createdDate, updatedAt: t.createdDate
                )
            }
        }
        defaults.set(true, forKey: migrationKey)
        print("[FenixuzTodo] migrated from UserDefaults to SQLite")
    }

    // MARK: - Checked board mutations (all helpers run on the serialized queue)
    //
    // `asAccount` (R4): the write fence of that account is checked ON the queue, so a write either
    // lands before a migration step's snapshot (and is copied) or sees the step's `.migrating`
    // fence; nil skips the fence. The fence source only reads cached values, never this database.

    /// Creates the inbox only when needed, atomically with a validated new task.
    public func createQuickTask(folderId: String?, title: String, inboxTitle: String, assignee: TodoAssignee? = nil, dueAt: Int32? = nil, asAccount accountPeerId: Int64? = nil) throws -> TodoTask {
        let title = try TodoStorage.validatedTitle(title, limit: TodoStorage.taskTitleLimit)
        let assignee = try assignee.map { try TodoStorage.validatedAssignee(peerId: $0.peerId, displayName: $0.displayName) }
        if let dueAt = dueAt, dueAt < 0 { throw TodoDatabaseError.invalidDueDate }
        return try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            return try self.transaction {
                let resolvedId = folderId ?? TodoStorage.inboxFolderId
                let now = Int32(Date().timeIntervalSince1970)
                if try !self.folderExists(id: resolvedId) {
                    guard folderId == nil else { throw TodoDatabaseError.folderNotFound }
                    let inbox = TodoFolder(id: resolvedId, title: try TodoStorage.validatedTitle(inboxTitle, limit: TodoStorage.folderTitleLimit), sortOrder: try self.nextSortOrder(folderId: nil), createdDate: now)
                    try self.insertFolderChecked(inbox)
                }
                let task = TodoTask(
                    id: UUID().uuidString, folderId: resolvedId, title: title,
                    description: nil, dueAt: dueAt, priority: 0, isCompleted: false, completedAt: nil,
                    sortOrder: try self.nextSortOrder(folderId: resolvedId), createdDate: now, updatedAt: now, assignee: assignee
                )
                try self.insertTaskChecked(task)
                return task
            }
        }
    }

    /// Creates a validated folder and returns it only after commit succeeds.
    public func createFolder(title: String, asAccount accountPeerId: Int64? = nil) throws -> TodoFolder {
        let title = try TodoStorage.validatedTitle(title, limit: TodoStorage.folderTitleLimit)
        return try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            return try self.transaction {
                let folder = TodoFolder(id: UUID().uuidString, title: title, sortOrder: try self.nextSortOrder(folderId: nil), createdDate: Int32(Date().timeIntervalSince1970))
                try self.insertFolderChecked(folder)
                return folder
            }
        }
    }

    /// Updates only the title and update timestamp, leaving persisted metadata intact.
    public func renameTask(id: String, title: String, asAccount accountPeerId: Int64? = nil) throws {
        let title = try TodoStorage.validatedTitle(title, limit: TodoStorage.taskTitleLimit)
        try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            try self.transaction {
                let changed = try self.executeChecked("UPDATE tasks SET title = ?, updated_at = ? WHERE id = ?;") { statement in
                    try self.bindText(title, at: 1, to: statement)
                    try self.bindInteger(Int64(Date().timeIntervalSince1970), at: 2, to: statement)
                    try self.bindText(id, at: 3, to: statement)
                }
                guard changed == 1 else { throw TodoDatabaseError.taskNotFound }
            }
        }
    }

    /// Commits only editable board fields and the update timestamp; nil removes metadata.
    public func updateTaskDetails(id: String, title: String, assignee: TodoAssignee?, dueAt: Int32?, asAccount accountPeerId: Int64? = nil) throws {
        let title = try TodoStorage.validatedTitle(title, limit: TodoStorage.taskTitleLimit)
        let assignee = try assignee.map { try TodoStorage.validatedAssignee(peerId: $0.peerId, displayName: $0.displayName) }
        if let dueAt = dueAt, dueAt < 0 { throw TodoDatabaseError.invalidDueDate }
        try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            try self.transaction {
                let sql = "UPDATE tasks SET title = ?, assignee_peer_id = ?, assignee_display_name = ?, due_at = ?, updated_at = ? WHERE id = ?;"
                let changed = try self.executeChecked(sql) { statement in
                    try self.bindText(title, at: 1, to: statement)
                    try self.bindInteger(assignee?.peerId, at: 2, to: statement)
                    try self.bindText(assignee?.displayName, at: 3, to: statement)
                    try self.bindInteger(dueAt.map(Int64.init), at: 4, to: statement)
                    try self.bindInteger(Int64(Date().timeIntervalSince1970), at: 5, to: statement)
                    try self.bindText(id, at: 6, to: statement)
                }
                guard changed == 1 else { throw TodoDatabaseError.taskNotFound }
            }
        }
    }

    /// Repeated requests for the current completion state preserve both timestamps.
    public func setTaskCompleted(id: String, isCompleted: Bool, asAccount accountPeerId: Int64? = nil) throws {
        try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            try self.transaction {
                let currentState: Bool? = try self.withStatement("SELECT is_completed FROM tasks WHERE id = ?;") { statement in
                    try self.bindText(id, at: 1, to: statement)
                    let result = sqlite3_step(statement)
                    if result == SQLITE_ROW { return sqlite3_column_int(statement, 0) != 0 }
                    try self.checkSQLite(result, expected: SQLITE_DONE)
                    return nil
                }
                guard let currentState = currentState else { throw TodoDatabaseError.taskNotFound }
                guard currentState != isCompleted else { return }
                let now = Int64(Date().timeIntervalSince1970)
                try self.writeOne("UPDATE tasks SET is_completed = ?, completed_at = ?, updated_at = ? WHERE id = ?;") { statement in
                    try self.bindInteger(isCompleted ? 1 : 0, at: 1, to: statement)
                    try self.bindInteger(isCompleted ? now : nil, at: 2, to: statement)
                    try self.bindInteger(now, at: 3, to: statement)
                    try self.bindText(id, at: 4, to: statement)
                }
            }
        }
    }

    /// Snapshots the persisted row and deletes it in one transaction; absent rows return nil.
    public func deleteTaskForUndo(id: String, asAccount accountPeerId: Int64? = nil) throws -> TodoDeletedTaskSnapshot? {
        return try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            return try self.transaction {
                guard let task = try self.loadTaskChecked(id: id) else { return nil }
                try self.writeOne("DELETE FROM tasks WHERE id = ?;") { statement in
                    try self.bindText(id, at: 1, to: statement)
                }
                return TodoDeletedTaskSnapshot(task: task, storageId: self.storageId, wipeGeneration: self.wipeGeneration)
            }
        }
    }

    /// Restores only this instance's non-revoked snapshot; never recreates a folder or replaces an ID.
    public func restoreDeletedTask(_ snapshot: TodoDeletedTaskSnapshot, asAccount accountPeerId: Int64? = nil) throws {
        try self.queue.sync {
            guard snapshot.storageId == self.storageId, snapshot.wipeGeneration == self.wipeGeneration else { throw TodoDatabaseError.invalidSnapshot }
            try TodoStorage.checkWriteFence(accountPeerId)
            try self.transaction {
                let task = snapshot.task
                guard try self.folderExists(id: task.folderId) else { throw TodoDatabaseError.folderNotFound }
                try self.insertTaskChecked(task)
            }
        }
    }

    private func checkSQLite(_ result: Int32, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else { throw TodoDatabaseError.sqlite(result) }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        if let failure = self.initializationError { throw failure }
        guard let db = self.db else { throw TodoDatabaseError.sqlite(SQLITE_MISUSE) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try self.checkSQLite(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement = statement else { throw TodoDatabaseError.sqlite(SQLITE_MISUSE) }
        return try body(statement)
    }

    private func bindText(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        if let value = value {
            guard let length = Int32(exactly: value.utf8.count) else { throw TodoDatabaseError.sqlite(SQLITE_TOOBIG) }
            try self.checkSQLite(sqlite3_bind_text(statement, index, value, length, SQLITE_TRANSIENT_DESTRUCTOR))
        } else {
            try self.checkSQLite(sqlite3_bind_null(statement, index))
        }
    }

    private func bindInteger(_ value: Int64?, at index: Int32, to statement: OpaquePointer) throws {
        if let value = value {
            try self.checkSQLite(sqlite3_bind_int64(statement, index, value))
        } else {
            try self.checkSQLite(sqlite3_bind_null(statement, index))
        }
    }

    @discardableResult
    private func executeChecked(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws -> Int32 {
        return try self.withStatement(sql) { statement in
            try bind(statement)
            try self.checkSQLite(sqlite3_step(statement), expected: SQLITE_DONE)
            return sqlite3_changes(self.db)
        }
    }

    private func writeOne(_ sql: String, bind: (OpaquePointer) throws -> Void) throws {
        guard try self.executeChecked(sql, bind: bind) == 1 else { throw TodoDatabaseError.sqlite(SQLITE_CONSTRAINT) }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try self.executeChecked("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try self.executeChecked("COMMIT;")
            return result
        } catch {
            let failure = error
            if sqlite3_get_autocommit(self.db) == 0 {
                do {
                    try self.executeChecked("ROLLBACK;")
                } catch {
                    // Do not allow any later operation to commit a transaction we could not unwind.
                    sqlite3_close(self.db)
                    self.db = nil
                    throw error
                }
            }
            throw failure
        }
    }

    private func folderExists(id: String) throws -> Bool {
        return try self.withStatement("SELECT 1 FROM folders WHERE id = ?;") { statement in
            try self.bindText(id, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { return true }
            try self.checkSQLite(result, expected: SQLITE_DONE)
            return false
        }
    }

    private func nextSortOrder(folderId: String?) throws -> Int {
        let sql = folderId == nil
            ? "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM folders;"
            : "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM tasks WHERE folder_id = ?;"
        return try self.withStatement(sql) { statement in
            if let folderId = folderId {
                try self.bindText(folderId, at: 1, to: statement)
            }
            try self.checkSQLite(sqlite3_step(statement), expected: SQLITE_ROW)
            guard let order = Int32(exactly: sqlite3_column_int64(statement, 0)) else { throw TodoDatabaseError.sqlite(SQLITE_FULL) }
            return Int(order)
        }
    }

    /// Every actual folder INSERT mints a new incarnation (createFolder, lazy inbox).
    private func insertFolderChecked(_ folder: TodoFolder) throws {
        try self.writeOne("INSERT INTO folders (id, title, sort_order, created_at, incarnation) VALUES (?, ?, ?, ?, ?);") { statement in
            try self.bindText(folder.id, at: 1, to: statement)
            try self.bindText(folder.title, at: 2, to: statement)
            try self.bindInteger(Int64(folder.sortOrder), at: 3, to: statement)
            try self.bindInteger(Int64(folder.createdDate), at: 4, to: statement)
            try self.bindText(Self.newIncarnation(), at: 5, to: statement)
        }
    }

    private func insertTaskChecked(_ task: TodoTask) throws {
        let sql = """
        INSERT INTO tasks (id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at, assignee_peer_id, assignee_display_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try self.writeOne(sql) { statement in
            try self.bindText(task.id, at: 1, to: statement)
            try self.bindText(task.folderId, at: 2, to: statement)
            try self.bindText(task.title, at: 3, to: statement)
            try self.bindText(task.description, at: 4, to: statement)
            try self.bindInteger(task.dueAt.map(Int64.init), at: 5, to: statement)
            try self.bindInteger(Int64(task.priority), at: 6, to: statement)
            try self.bindInteger(task.isCompleted ? 1 : 0, at: 7, to: statement)
            try self.bindInteger(task.completedAt.map(Int64.init), at: 8, to: statement)
            try self.bindInteger(Int64(task.sortOrder), at: 9, to: statement)
            try self.bindInteger(Int64(task.createdDate), at: 10, to: statement)
            try self.bindInteger(Int64(task.updatedAt), at: 11, to: statement)
            try self.bindInteger(task.assignee?.peerId, at: 12, to: statement)
            try self.bindText(task.assignee?.displayName, at: 13, to: statement)
        }
    }

    private func loadTaskChecked(id: String) throws -> TodoTask? {
        let sql = """
        SELECT id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at, assignee_peer_id, assignee_display_name
        FROM tasks WHERE id = ?;
        """
        return try self.withStatement(sql) { statement in
            try self.bindText(id, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { return self.taskFromRow(statement) }
            try self.checkSQLite(result, expected: SQLITE_DONE)
            return nil
        }
    }

    // MARK: - Folders CRUD

    public func loadFolders() -> [TodoFolder] {
        return self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id, title, sort_order, created_at FROM folders ORDER BY sort_order, created_at;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var out: [TodoFolder] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TodoFolder(
                    id: self.textFromRow(stmt, column: 0),
                    title: self.textFromRow(stmt, column: 1),
                    sortOrder: Int(sqlite3_column_int(stmt, 2)),
                    createdDate: sqlite3_column_int(stmt, 3)
                ))
            }
            return out
        }
    }

    public func addFolder(title: String) {
        self.queue.sync {
            let count = self.countFolders()
            self.insertFolder(id: UUID().uuidString, title: title, sortOrder: count, createdAt: Int32(Date().timeIntervalSince1970))
        }
    }

    private func countFolders() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(self.db, "SELECT COUNT(*) FROM folders;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Legacy addFolder and the UserDefaults migration: INSERT OR REPLACE is an actual (re)insert,
    /// so it also mints a new incarnation.
    private func insertFolder(id: String, title: String, sortOrder: Int, createdAt: Int32) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT OR REPLACE INTO folders (id, title, sort_order, created_at, incarnation) VALUES (?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        sqlite3_bind_int(stmt, 4, createdAt)
        sqlite3_bind_text(stmt, 5, Self.newIncarnation(), -1, SQLITE_TRANSIENT_DESTRUCTOR)
        _ = sqlite3_step(stmt)
    }

    /// Changes only the title (the incarnation stays); a missing folder throws `folderNotFound`.
    public func updateFolderTitle(id: String, title: String, asAccount accountPeerId: Int64? = nil) throws {
        try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            try self.transaction {
                let changed = try self.executeChecked("UPDATE folders SET title = ? WHERE id = ?;") { statement in
                    try self.bindText(title, at: 1, to: statement)
                    try self.bindText(id, at: 2, to: statement)
                }
                guard changed == 1 else { throw TodoDatabaseError.folderNotFound }
            }
        }
    }

    /// Deletes the folder and (FK cascade) its tasks; a missing folder is not an error.
    public func removeFolder(id: String, asAccount accountPeerId: Int64? = nil) throws {
        try self.queue.sync {
            try TodoStorage.checkWriteFence(accountPeerId)
            try self.transaction {
                // CASCADE'da tasks'lar avtomatik o'chiriladi
                _ = try self.executeChecked("DELETE FROM folders WHERE id = ?;") { statement in
                    try self.bindText(id, at: 1, to: statement)
                }
            }
        }
    }

    // MARK: - Tasks CRUD

    public func loadTasks(folderId: String? = nil) -> [TodoTask] {
        return self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql: String
            if folderId != nil {
                sql = "SELECT id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at, assignee_peer_id, assignee_display_name FROM tasks WHERE folder_id = ? ORDER BY is_completed ASC, sort_order ASC, created_at ASC;"
            } else {
                sql = "SELECT id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at, assignee_peer_id, assignee_display_name FROM tasks ORDER BY is_completed ASC, sort_order ASC, created_at ASC;"
            }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            if let folderId = folderId {
                sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            var out: [TodoTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(self.taskFromRow(stmt))
            }
            return out
        }
    }

    /// wf15 §7.2 item 1: every device task that carries a local assignee (`assignee_peer_id` and
    /// `assignee_display_name` set), each with its parent folder's current incarnation (the key of
    /// its import mapping), in the sheet's order — `created_at`, then id (§7.2 item 4). Completed
    /// rows are included (the offer leaves them out itself); a row whose parent folder is gone has
    /// no incarnation and can have no mapping. Read-only; the rows are never written here.
    public func liveTasksWithAssignee() -> [TodoLiveAssigneeRow] {
        return self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT t.id, t.folder_id, t.title, t.description, t.due_at, t.priority, t.is_completed, t.completed_at, t.sort_order, t.created_at, t.updated_at, t.assignee_peer_id, t.assignee_display_name, f.incarnation
            FROM tasks t LEFT JOIN folders f ON f.id = t.folder_id
            WHERE t.assignee_peer_id IS NOT NULL AND t.assignee_display_name IS NOT NULL
            ORDER BY t.created_at ASC, t.id ASC;
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var out: [TodoLiveAssigneeRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let incarnation: String? = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : self.textFromRow(stmt, column: 13)
                out.append(TodoLiveAssigneeRow(task: self.taskFromRow(stmt), folderIncarnation: incarnation))
            }
            return out
        }
    }

    public func loadTasksDueToday() -> [TodoTask] {
        return self.queue.sync {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!.timeIntervalSince1970
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at, assignee_peer_id, assignee_display_name
            FROM tasks
            WHERE is_completed = 0 AND due_at IS NOT NULL AND due_at < ?
            ORDER BY due_at ASC;
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(stmt, 1, Int64(endOfDay))
            var out: [TodoTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(self.taskFromRow(stmt))
            }
            return out
        }
    }

    public func loadTasksUpcoming() -> [TodoTask] {
        return self.queue.sync {
            let startOfNextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.timeIntervalSince1970
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at, assignee_peer_id, assignee_display_name
            FROM tasks
            WHERE is_completed = 0 AND due_at IS NOT NULL AND due_at >= ?
            ORDER BY due_at ASC;
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(stmt, 1, Int64(startOfNextDay))
            var out: [TodoTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(self.taskFromRow(stmt))
            }
            return out
        }
    }

    private func taskFromRow(_ stmt: OpaquePointer?) -> TodoTask {
        let description: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : self.textFromRow(stmt, column: 3)
        let dueAt: Int32? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 4)
        let completedAt: Int32? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 7)
        let assignee: TodoAssignee?
        if sqlite3_column_type(stmt, 11) != SQLITE_NULL, sqlite3_column_type(stmt, 12) != SQLITE_NULL {
            assignee = TodoAssignee(peerId: sqlite3_column_int64(stmt, 11), displayName: self.textFromRow(stmt, column: 12))
        } else {
            assignee = nil
        }
        return TodoTask(
            id: self.textFromRow(stmt, column: 0),
            folderId: self.textFromRow(stmt, column: 1),
            title: self.textFromRow(stmt, column: 2),
            description: description,
            dueAt: dueAt,
            priority: Int(sqlite3_column_int(stmt, 5)),
            isCompleted: sqlite3_column_int(stmt, 6) != 0,
            completedAt: completedAt,
            sortOrder: Int(sqlite3_column_int(stmt, 8)),
            createdDate: sqlite3_column_int(stmt, 9),
            updatedAt: sqlite3_column_int(stmt, 10),
            assignee: assignee
        )
    }

    private func textFromRow(_ statement: OpaquePointer?, column: Int32) -> String {
        let bytes = UnsafeBufferPointer(start: sqlite3_column_text(statement, column), count: Int(sqlite3_column_bytes(statement, column)))
        return String(decoding: bytes, as: UTF8.self)
    }

    public func addTask(folderId: String, title: String, description: String? = nil, dueAt: Int32? = nil, priority: Int = 0) -> TodoTask {
        return self.queue.sync {
            let now = Int32(Date().timeIntervalSince1970)
            let id = UUID().uuidString
            let count = self.countTasksInFolder(folderId: folderId)
            self.insertTask(
                id: id, folderId: folderId, title: title,
                description: description, dueAt: dueAt, priority: priority,
                isCompleted: false, completedAt: nil,
                sortOrder: count, createdAt: now, updatedAt: now
            )
            return TodoTask(
                id: id, folderId: folderId, title: title,
                description: description, dueAt: dueAt, priority: priority,
                isCompleted: false, completedAt: nil,
                sortOrder: count, createdDate: now, updatedAt: now
            )
        }
    }

    private func countTasksInFolder(folderId: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM tasks WHERE folder_id = ?;"
        guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func insertTask(
        id: String, folderId: String, title: String,
        description: String?, dueAt: Int32?, priority: Int,
        isCompleted: Bool, completedAt: Int32?,
        sortOrder: Int, createdAt: Int32, updatedAt: Int32
    ) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT OR REPLACE INTO tasks
        (id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, folderId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 3, title, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let description = description {
            sqlite3_bind_text(stmt, 4, description, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let dueAt = dueAt {
            sqlite3_bind_int(stmt, 5, dueAt)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, Int32(priority))
        sqlite3_bind_int(stmt, 7, isCompleted ? 1 : 0)
        if let completedAt = completedAt {
            sqlite3_bind_int(stmt, 8, completedAt)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_int(stmt, 9, Int32(sortOrder))
        sqlite3_bind_int(stmt, 10, createdAt)
        sqlite3_bind_int(stmt, 11, updatedAt)
        _ = sqlite3_step(stmt)
    }

    public func updateTask(id: String, title: String, description: String?, dueAt: Int32?, priority: Int) {
        self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "UPDATE tasks SET title = ?, description = ?, due_at = ?, priority = ?, updated_at = ? WHERE id = ?;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if let description = description {
                sqlite3_bind_text(stmt, 2, description, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let dueAt = dueAt {
                sqlite3_bind_int(stmt, 3, dueAt)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int(stmt, 4, Int32(priority))
            sqlite3_bind_int(stmt, 5, Int32(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt, 6, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            _ = sqlite3_step(stmt)
        }
    }

    public func toggleTask(id: String) {
        self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let now = Int32(Date().timeIntervalSince1970)
            let sql = """
            UPDATE tasks
            SET is_completed = CASE WHEN is_completed = 0 THEN 1 ELSE 0 END,
                completed_at = CASE WHEN is_completed = 0 THEN ? ELSE NULL END,
                updated_at = ?
            WHERE id = ?;
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, now)
            sqlite3_bind_int(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            _ = sqlite3_step(stmt)
        }
    }

    public func removeTask(id: String) {
        self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, "DELETE FROM tasks WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            _ = sqlite3_step(stmt)
        }
    }

    public func reorderTasks(folderId: String, idsInOrder: [String]) {
        self.queue.sync {
            self.exec("BEGIN TRANSACTION;")
            for (i, id) in idsInOrder.enumerated() {
                var stmt: OpaquePointer?
                let sql = "UPDATE tasks SET sort_order = ? WHERE id = ?;"
                if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int(stmt, 1, Int32(i))
                    sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    _ = sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            self.exec("COMMIT;")
        }
    }

    public func searchTasks(query: String) -> [TodoTask] {
        return self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at, assignee_peer_id, assignee_display_name
            FROM tasks
            WHERE title LIKE ? OR description LIKE ?
            ORDER BY is_completed ASC, due_at IS NULL ASC, due_at ASC, created_at DESC
            LIMIT 200;
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            let like = "%\(query)%"
            sqlite3_bind_text(stmt, 1, like, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, like, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            var out: [TodoTask] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(self.taskFromRow(stmt))
            }
            return out
        }
    }

    // MARK: Zenlygram — logout cleanup (audit #96)

    /// Wipes every folder and task (called when the last account logs out). Deleted content is
    /// overwritten in the SQLite file (secure_delete; a logical overwrite, not a physical flash
    /// erase) and the WAL is truncated so no task text lingers in the database files. The old
    /// UserDefaults JSON is removed as well, while the migration flag stays set so it is never
    /// re-imported. The content-free cloud import mapping, the device owner marker and every
    /// migration record go in the same queued step; folder incarnations go with their rows. The
    /// generation bump fences any import snapshot taken earlier.
    public func removeAllData() {
        self.queue.async {
            self.wipeGeneration &+= 1
            self.exec("PRAGMA secure_delete = ON;")
            do {
                try self.transaction {
                    try self.executeChecked("DELETE FROM cloud_import_attempt;")
                    try self.executeChecked("DELETE FROM cloud_import_map;")
                    try self.executeChecked("DELETE FROM cloud_device_owner;")
                    try self.executeChecked("DELETE FROM cloud_migration;")
                    try self.executeChecked("DELETE FROM tasks;")
                    try self.executeChecked("DELETE FROM folders;")
                }
            } catch {
                // Never leave the wipe half-claimed: retry each table independently, as before v3.
                print("[FenixuzTodo] atomic wipe failed: \(error)")
                self.exec("DELETE FROM cloud_import_attempt;")
                self.exec("DELETE FROM cloud_import_map;")
                self.exec("DELETE FROM cloud_device_owner;")
                self.exec("DELETE FROM cloud_migration;")
                self.exec("DELETE FROM tasks;")
                self.exec("DELETE FROM folders;")
            }
            self.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            let defaults = self.defaults
            defaults.removeObject(forKey: "todo_folders_list")
            defaults.removeObject(forKey: "todo_tasks_list")
            defaults.set(true, forKey: "todo_sqlite_migration_done")
        }
    }

    // MARK: Zenlygram — explicit cloud import (consent snapshot + immutable mapping)

    /// One consistent read of every folder (with incarnation) and every task (with its parent's
    /// incarnation at this moment). The parent is never re-resolved later from folder_id.
    public func cloudImportSnapshot() throws -> TodoCloudImportSnapshot {
        return try self.queue.sync {
            try self.transaction {
                let folders: [TodoCloudImportFolder] = try self.withStatement("SELECT id, title, sort_order, created_at, incarnation FROM folders ORDER BY sort_order, created_at, id;") { statement in
                    var out: [TodoCloudImportFolder] = []
                    while true {
                        let result = sqlite3_step(statement)
                        if result == SQLITE_DONE { break }
                        try self.checkSQLite(result, expected: SQLITE_ROW)
                        guard sqlite3_column_type(statement, 4) != SQLITE_NULL else { throw TodoDatabaseError.invalidSnapshot }
                        out.append(TodoCloudImportFolder(
                            id: self.textFromRow(statement, column: 0),
                            incarnation: self.textFromRow(statement, column: 4),
                            title: self.textFromRow(statement, column: 1),
                            sortOrder: sqlite3_column_int64(statement, 2),
                            createdDate: sqlite3_column_int64(statement, 3)
                        ))
                    }
                    return out
                }
                let sql = """
                SELECT t.id, t.folder_id, t.title, t.description, t.due_at, t.priority, t.is_completed, t.completed_at, t.sort_order, t.created_at, t.updated_at, t.assignee_peer_id, t.assignee_display_name, f.incarnation
                FROM tasks t LEFT JOIN folders f ON f.id = t.folder_id
                ORDER BY t.folder_id, t.sort_order, t.created_at, t.id;
                """
                let tasks: [TodoCloudImportTask] = try self.withStatement(sql) { statement in
                    var out: [TodoCloudImportTask] = []
                    while true {
                        let result = sqlite3_step(statement)
                        if result == SQLITE_DONE { break }
                        try self.checkSQLite(result, expected: SQLITE_ROW)
                        let incarnation: String? = sqlite3_column_type(statement, 13) == SQLITE_NULL ? nil : self.textFromRow(statement, column: 13)
                        var task = self.taskFromRow(statement)
                        // The board reads these as 32-bit; the import sees the stored values (a sort
                        // order beyond Int32 is re-indexed, a deadline beyond it dropped, §7.1).
                        task.sortOrder = Int(truncatingIfNeeded: sqlite3_column_int64(statement, 8))
                        if sqlite3_column_type(statement, 4) != SQLITE_NULL, Int32(exactly: sqlite3_column_int64(statement, 4)) == nil {
                            task.dueAt = nil
                        }
                        out.append(TodoCloudImportTask(task: task, folderIncarnation: incarnation))
                    }
                    return out
                }
                return TodoCloudImportSnapshot(folders: folders, tasks: tasks, storageId: self.storageId, wipeGeneration: self.wipeGeneration)
            }
        }
    }

    /// Existing mapping rows of one account and server-account scope (read only; never mints),
    /// each with whether its create was acknowledged.
    public func existingCloudImportMappings(accountPeerId: Int64, principalScope: String) throws -> [TodoCloudImportMapping] {
        return try self.queue.sync {
            try self.withStatement("""
            SELECT m.legacy_kind, m.legacy_id, m.legacy_incarnation, m.cloud_id, m.create_mutation_id, a.create_mutation_id IS NOT NULL, COALESCE(a.acknowledged, 0), COALESCE(a.verified_generation, 0)
            FROM cloud_import_map m LEFT JOIN cloud_import_attempt a ON a.create_mutation_id = m.create_mutation_id
            WHERE m.account_peer_id = ? AND m.principal_scope = ?
            ORDER BY m.legacy_kind, m.legacy_id, m.legacy_incarnation;
            """) { statement in
                try self.bindInteger(accountPeerId, at: 1, to: statement)
                try self.bindText(principalScope, at: 2, to: statement)
                var out: [TodoCloudImportMapping] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    try self.checkSQLite(result, expected: SQLITE_ROW)
                    guard let kind = TodoCloudImportMapping.Kind(rawValue: self.textFromRow(statement, column: 0)) else { throw TodoDatabaseError.invalidSnapshot }
                    out.append(TodoCloudImportMapping(kind: kind, legacyId: self.textFromRow(statement, column: 1), legacyIncarnation: self.textFromRow(statement, column: 2), cloudId: self.textFromRow(statement, column: 3), createMutationId: self.textFromRow(statement, column: 4), wasAttempted: sqlite3_column_int(statement, 5) != 0, isAcknowledged: sqlite3_column_int(statement, 6) != 0, verifiedGeneration: sqlite3_column_int64(statement, 7)))
                }
                return out
            }
        }
    }

    /// Records the provenance of a mapped create: `acknowledged == false` before its first send,
    /// `true` once the server acknowledged it (never reverts). A create id that is not an import
    /// mapping is ignored. Idempotent; committed durably (synchronous = FULL).
    public func recordCloudImportAttempt(createMutationId: String, acknowledged: Bool) throws {
        try self.queue.sync {
            try self.executeChecked("PRAGMA synchronous = FULL;")
            defer { self.exec("PRAGMA synchronous = NORMAL;") }
            _ = try self.transaction {
                try self.executeChecked("""
                INSERT INTO cloud_import_attempt (create_mutation_id, acknowledged)
                SELECT create_mutation_id, ? FROM cloud_import_map WHERE create_mutation_id = ?
                ON CONFLICT(create_mutation_id) DO UPDATE SET acknowledged = MAX(acknowledged, excluded.acknowledged);
                """) { statement in
                    try self.bindInteger(acknowledged ? 1 : 0, at: 1, to: statement)
                    try self.bindText(createMutationId, at: 2, to: statement)
                }
            }
        }
    }

    /// Returns the scope's immutable mapping for every folder and parented task of the consent
    /// snapshot, minting ids only for rows never mapped before. Existing rows are reused verbatim
    /// (restart, partial receipt, re-login). A snapshot from before a wipe or from another instance
    /// is refused, so a concurrent final-logout wipe cannot be undone by a late import. The commit
    /// is durable (synchronous = FULL) before the caller enqueues creates that use these ids.
    public func cloudImportMappings(for snapshot: TodoCloudImportSnapshot, accountPeerId: Int64, principalScope: String, mint: () -> (cloudId: String, mutationId: String)) throws -> [TodoCloudImportMapping] {
        return try self.queue.sync {
            guard snapshot.storageId == self.storageId, snapshot.wipeGeneration == self.wipeGeneration else { throw TodoDatabaseError.invalidSnapshot }
            try self.executeChecked("PRAGMA synchronous = FULL;")
            defer { self.exec("PRAGMA synchronous = NORMAL;") }
            return try self.transaction {
                var keys: [(TodoCloudImportMapping.Kind, String, String)] = snapshot.folders.map { (.folder, $0.id, $0.incarnation) }
                for item in snapshot.tasks {
                    guard let incarnation = item.folderIncarnation else { continue }
                    keys.append((.task, item.task.id, incarnation))
                }
                var out: [TodoCloudImportMapping] = []
                for (kind, legacyId, incarnation) in keys {
                    let minted = mint()
                    try self.executeChecked("INSERT OR IGNORE INTO cloud_import_map (account_peer_id, principal_scope, legacy_kind, legacy_id, legacy_incarnation, cloud_id, create_mutation_id) VALUES (?, ?, ?, ?, ?, ?, ?);") { statement in
                        try self.bindInteger(accountPeerId, at: 1, to: statement)
                        try self.bindText(principalScope, at: 2, to: statement)
                        try self.bindText(kind.rawValue, at: 3, to: statement)
                        try self.bindText(legacyId, at: 4, to: statement)
                        try self.bindText(incarnation, at: 5, to: statement)
                        try self.bindText(minted.cloudId, at: 6, to: statement)
                        try self.bindText(minted.mutationId, at: 7, to: statement)
                    }
                    let mapping: TodoCloudImportMapping? = try self.withStatement("""
                    SELECT m.cloud_id, m.create_mutation_id, a.create_mutation_id IS NOT NULL, COALESCE(a.acknowledged, 0), COALESCE(a.verified_generation, 0)
                    FROM cloud_import_map m LEFT JOIN cloud_import_attempt a ON a.create_mutation_id = m.create_mutation_id
                    WHERE m.account_peer_id = ? AND m.principal_scope = ? AND m.legacy_kind = ? AND m.legacy_id = ? AND m.legacy_incarnation = ?;
                    """) { statement in
                        try self.bindInteger(accountPeerId, at: 1, to: statement)
                        try self.bindText(principalScope, at: 2, to: statement)
                        try self.bindText(kind.rawValue, at: 3, to: statement)
                        try self.bindText(legacyId, at: 4, to: statement)
                        try self.bindText(incarnation, at: 5, to: statement)
                        let result = sqlite3_step(statement)
                        if result == SQLITE_ROW {
                            return TodoCloudImportMapping(kind: kind, legacyId: legacyId, legacyIncarnation: incarnation, cloudId: self.textFromRow(statement, column: 0), createMutationId: self.textFromRow(statement, column: 1), wasAttempted: sqlite3_column_int(statement, 2) != 0, isAcknowledged: sqlite3_column_int(statement, 3) != 0, verifiedGeneration: sqlite3_column_int64(statement, 4))
                        }
                        try self.checkSQLite(result, expected: SQLITE_DONE)
                        return nil
                    }
                    // An ignored insert without a row means a minted id collided: never guess.
                    guard let mapping = mapping else { throw TodoDatabaseError.sqlite(SQLITE_CONSTRAINT) }
                    out.append(mapping)
                }
                return out
            }
        }
    }

    // MARK: Zenlygram R4 — device owner marker, migration record, mapping lifecycle (v5)
    //
    // All content-free and durable (synchronous = FULL), like the import mapping: they decide which
    // account's cloud receives the device rows, so a crash must never forget a claim.

    private func durably<T>(_ body: () throws -> T) throws -> T {
        try self.executeChecked("PRAGMA synchronous = FULL;")
        defer { self.exec("PRAGMA synchronous = NORMAL;") }
        return try body()
    }

    private func optionalInteger(_ statement: OpaquePointer, column: Int32) -> Int64? {
        return sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        return sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : self.textFromRow(statement, column: column)
    }

    private func ownerRow() throws -> TodoCloudDeviceOwner? {
        return try self.withStatement("SELECT account_peer_id, state, claimed_at, completed_at, released_at, release_reason FROM cloud_device_owner WHERE singleton = 1;") { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            try self.checkSQLite(result, expected: SQLITE_ROW)
            guard let state = TodoCloudDeviceOwner.State(rawValue: self.textFromRow(statement, column: 1)) else { throw TodoDatabaseError.invalidSnapshot }
            return TodoCloudDeviceOwner(accountPeerId: sqlite3_column_int64(statement, 0), state: state, claimedAt: sqlite3_column_int64(statement, 2), completedAt: self.optionalInteger(statement, column: 3), releasedAt: self.optionalInteger(statement, column: 4), releaseReason: self.optionalText(statement, column: 5))
        }
    }

    private func migrationRecordRow(accountPeerId: Int64) throws -> TodoCloudMigrationRecord? {
        let sql = """
        SELECT state, reason, principal_scope, normalization_locale, claimed_at, enqueued_at, completed_at, verified_generation, lists, tasks, kept_local
        FROM cloud_migration WHERE account_peer_id = ?;
        """
        return try self.withStatement(sql) { statement in
            try self.bindInteger(accountPeerId, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            try self.checkSQLite(result, expected: SQLITE_ROW)
            guard let state = TodoCloudMigrationRecord.State(rawValue: self.textFromRow(statement, column: 0)),
                  let locale = TodoCloudMigrationRecord.Locale(rawValue: self.textFromRow(statement, column: 3)) else { throw TodoDatabaseError.invalidSnapshot }
            var reason: TodoCloudMigrationRecord.Reason?
            if let raw = self.optionalText(statement, column: 1) {
                // An unknown reason is unreadable state, never silently dropped.
                guard let known = TodoCloudMigrationRecord.Reason(rawValue: raw) else { throw TodoDatabaseError.invalidSnapshot }
                reason = known
            }
            return TodoCloudMigrationRecord(
                accountPeerId: accountPeerId, state: state, reason: reason,
                principalScope: self.optionalText(statement, column: 2), normalizationLocale: locale,
                claimedAt: sqlite3_column_int64(statement, 4), enqueuedAt: self.optionalInteger(statement, column: 5),
                completedAt: self.optionalInteger(statement, column: 6), verifiedGeneration: sqlite3_column_int64(statement, 7),
                lists: Int(sqlite3_column_int64(statement, 8)), tasks: Int(sqlite3_column_int64(statement, 9)), keptLocal: Int(sqlite3_column_int64(statement, 10))
            )
        }
    }

    private func writeMigrationRecord(_ record: TodoCloudMigrationRecord) throws {
        let sql = """
        INSERT INTO cloud_migration (account_peer_id, state, reason, principal_scope, normalization_locale, claimed_at, enqueued_at, completed_at, verified_generation, lists, tasks, kept_local)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_peer_id) DO UPDATE SET state = excluded.state, reason = excluded.reason, principal_scope = excluded.principal_scope,
            normalization_locale = excluded.normalization_locale, claimed_at = excluded.claimed_at, enqueued_at = excluded.enqueued_at,
            completed_at = excluded.completed_at, verified_generation = excluded.verified_generation, lists = excluded.lists,
            tasks = excluded.tasks, kept_local = excluded.kept_local;
        """
        try self.writeOne(sql) { statement in
            try self.bindInteger(record.accountPeerId, at: 1, to: statement)
            try self.bindText(record.state.rawValue, at: 2, to: statement)
            try self.bindText(record.reason?.rawValue, at: 3, to: statement)
            try self.bindText(record.principalScope, at: 4, to: statement)
            try self.bindText(record.normalizationLocale.rawValue, at: 5, to: statement)
            try self.bindInteger(record.claimedAt, at: 6, to: statement)
            try self.bindInteger(record.enqueuedAt, at: 7, to: statement)
            try self.bindInteger(record.completedAt, at: 8, to: statement)
            try self.bindInteger(record.verifiedGeneration, at: 9, to: statement)
            try self.bindInteger(Int64(record.lists), at: 10, to: statement)
            try self.bindInteger(Int64(record.tasks), at: 11, to: statement)
            try self.bindInteger(Int64(record.keptLocal), at: 12, to: statement)
        }
    }

    /// The device owner marker; nil while it is free.
    public func cloudDeviceOwner() throws -> TodoCloudDeviceOwner? {
        return try self.queue.sync {
            try self.ownerRow()
        }
    }

    /// Claims the device owner marker for an account (design 30 §5.4). A free marker is taken
    /// (`asCompleted`: directly as `completed` — the free-marker rule of an account whose rows were
    /// already copied explicitly); this account's own `released` marker is taken again; another
    /// account's marker, released or not, is never taken.
    @discardableResult
    public func claimCloudDevice(accountPeerId: Int64, asCompleted: Bool = false, now: Date = Date()) throws -> TodoCloudClaim {
        let at = Int64(now.timeIntervalSince1970)
        let state = asCompleted ? TodoCloudDeviceOwner.State.completed : .claimed
        return try self.queue.sync {
            try self.durably {
                try self.transaction {
                    guard let owner = try self.ownerRow() else {
                        try self.writeOne("INSERT INTO cloud_device_owner (singleton, account_peer_id, state, claimed_at, completed_at) VALUES (1, ?, ?, ?, ?);") { statement in
                            try self.bindInteger(accountPeerId, at: 1, to: statement)
                            try self.bindText(state.rawValue, at: 2, to: statement)
                            try self.bindInteger(at, at: 3, to: statement)
                            try self.bindInteger(asCompleted ? at : nil, at: 4, to: statement)
                        }
                        return .claimed
                    }
                    guard owner.accountPeerId == accountPeerId else {
                        return owner.state == .released ? .releasedByOther : .ownedByOther
                    }
                    guard owner.state == .released else { return .alreadyOwner }
                    try self.writeOne("UPDATE cloud_device_owner SET state = ?, claimed_at = ?, completed_at = ?, released_at = NULL, release_reason = NULL WHERE singleton = 1 AND account_peer_id = ? AND state = 'released';") { statement in
                        try self.bindText(state.rawValue, at: 1, to: statement)
                        try self.bindInteger(at, at: 2, to: statement)
                        try self.bindInteger(asCompleted ? at : nil, at: 3, to: statement)
                        try self.bindInteger(accountPeerId, at: 4, to: statement)
                    }
                    return .claimed
                }
            }
        }
    }

    /// The account's copy of the device rows is confirmed: its claimed marker becomes `completed`.
    /// Anything else (another account's marker, a released one) is left as it is.
    public func completeCloudDevice(accountPeerId: Int64, now: Date = Date()) throws {
        try self.queue.sync {
            try self.durably {
                try self.transaction {
                    _ = try self.executeChecked("UPDATE cloud_device_owner SET state = 'completed', completed_at = ? WHERE singleton = 1 AND account_peer_id = ? AND state = 'claimed';") { statement in
                        try self.bindInteger(Int64(now.timeIntervalSince1970), at: 1, to: statement)
                        try self.bindInteger(accountPeerId, at: 2, to: statement)
                    }
                }
            }
        }
    }

    /// One atomic release of an account's claim on the device rows (design 30 §5.4):
    /// - `withdrawn` / `erased`: every import mapping of the account goes (its cloud copies are being
    ///   erased, so they no longer guard against duplicates; attempts cascade); when the account
    ///   holds the marker it is DELETED if its record never reached `enqueued` (nothing of the device
    ///   was copied: the marker is free again), else `released`; the record becomes
    ///   `released(withdrawn)`, or is deleted for `erased`.
    /// - `scopeChanged`: the account's marker becomes `released`, the mappings stay (they guard the
    ///   explicit copy into the old cloud), the record becomes `skipped(scope_changed)`.
    /// Returns whether the account held the marker.
    @discardableResult
    public func releaseCloudDevice(accountPeerId: Int64, reason: TodoCloudRelease, now: Date = Date()) throws -> Bool {
        let at = Int64(now.timeIntervalSince1970)
        return try self.queue.sync {
            try self.durably {
                try self.transaction {
                    let record = try self.migrationRecordRow(accountPeerId: accountPeerId)
                    if reason != .scopeChanged {
                        try self.executeChecked("DELETE FROM cloud_import_map WHERE account_peer_id = ?;") { statement in
                            try self.bindInteger(accountPeerId, at: 1, to: statement)
                        }
                    }
                    var held = false
                    if let owner = try self.ownerRow(), owner.accountPeerId == accountPeerId {
                        held = true
                        if reason != .scopeChanged && record?.enqueuedAt == nil {
                            try self.executeChecked("DELETE FROM cloud_device_owner WHERE singleton = 1;")
                        } else {
                            try self.writeOne("UPDATE cloud_device_owner SET state = 'released', released_at = ?, release_reason = ? WHERE singleton = 1;") { statement in
                                try self.bindInteger(at, at: 1, to: statement)
                                try self.bindText(reason.rawValue, at: 2, to: statement)
                            }
                        }
                    }
                    if var record = record {
                        switch reason {
                        case .withdrawn:
                            // `enqueuedAt` stays: a repeated release still knows the rows were copied.
                            record.state = .released
                            record.reason = .withdrawn
                            record.principalScope = nil
                            record.completedAt = nil
                            record.verifiedGeneration = 0
                            try self.writeMigrationRecord(record)
                        case .erased:
                            try self.executeChecked("DELETE FROM cloud_migration WHERE account_peer_id = ?;") { statement in
                                try self.bindInteger(accountPeerId, at: 1, to: statement)
                            }
                        case .scopeChanged:
                            record.state = .skipped
                            record.reason = .scopeChanged
                            try self.writeMigrationRecord(record)
                        }
                    }
                    return held
                }
            }
        }
    }

    public func cloudMigrationRecord(accountPeerId: Int64) throws -> TodoCloudMigrationRecord? {
        return try self.queue.sync {
            try self.migrationRecordRow(accountPeerId: accountPeerId)
        }
    }

    /// Writes the account's record. With `expected`, only while the stored record still equals it
    /// (the migration step's compare-and-set: a withdrawal that released the record meanwhile wins);
    /// returns whether it was written.
    @discardableResult
    public func setCloudMigrationRecord(_ record: TodoCloudMigrationRecord, replacing expected: TodoCloudMigrationRecord? = nil) throws -> Bool {
        return try self.queue.sync {
            try self.durably {
                try self.transaction {
                    if let expected = expected {
                        guard expected.accountPeerId == record.accountPeerId, try self.migrationRecordRow(accountPeerId: record.accountPeerId) == expected else { return false }
                    }
                    try self.writeMigrationRecord(record)
                    return true
                }
            }
        }
    }

    public func deleteCloudMigrationRecord(accountPeerId: Int64) throws {
        try self.queue.sync {
            try self.durably {
                try self.transaction {
                    _ = try self.executeChecked("DELETE FROM cloud_migration WHERE account_peer_id = ?;") { statement in
                        try self.bindInteger(accountPeerId, at: 1, to: statement)
                    }
                }
            }
        }
    }

    /// Voids every import mapping of the account, in every scope (attempts cascade, F5: the
    /// immutability trigger guards UPDATE only).
    public func deleteCloudImportMappings(accountPeerId: Int64) throws {
        try self.queue.sync {
            try self.durably {
                try self.transaction {
                    _ = try self.executeChecked("DELETE FROM cloud_import_map WHERE account_peer_id = ?;") { statement in
                        try self.bindInteger(accountPeerId, at: 1, to: statement)
                    }
                }
            }
        }
    }

    /// Whether the account has an import mapping in ANY scope (other origins and the principal-only
    /// v1 scope included): rows it copied explicitly are never copied again automatically.
    public func hasCloudImportMapping(accountPeerId: Int64) throws -> Bool {
        return try self.queue.sync {
            try self.withStatement("SELECT EXISTS (SELECT 1 FROM cloud_import_map WHERE account_peer_id = ?);") { statement in
                try self.bindInteger(accountPeerId, at: 1, to: statement)
                try self.checkSQLite(sqlite3_step(statement), expected: SQLITE_ROW)
                return sqlite3_column_int(statement, 0) != 0
            }
        }
    }

    /// Live local rows without a mapping of this scope: every task (keyed by its parent's current
    /// incarnation) and every folder except the stable inbox (whose default-titled copy is the
    /// virtual Cloud Inbox and has no mapping of its own). The cut-over's `unmappedLiveRows`.
    public func unmappedLiveRowCount(accountPeerId: Int64, principalScope: String) throws -> Int {
        let sql = """
        SELECT
            (SELECT COUNT(*) FROM tasks t LEFT JOIN folders f ON f.id = t.folder_id
             WHERE NOT EXISTS (SELECT 1 FROM cloud_import_map m WHERE m.account_peer_id = ?1 AND m.principal_scope = ?2
                               AND m.legacy_kind = 'task' AND m.legacy_id = t.id AND m.legacy_incarnation = f.incarnation))
          + (SELECT COUNT(*) FROM folders f WHERE f.id != ?3
             AND NOT EXISTS (SELECT 1 FROM cloud_import_map m WHERE m.account_peer_id = ?1 AND m.principal_scope = ?2
                             AND m.legacy_kind = 'folder' AND m.legacy_id = f.id AND m.legacy_incarnation = f.incarnation));
        """
        return try self.queue.sync {
            try self.withStatement(sql) { statement in
                try self.bindInteger(accountPeerId, at: 1, to: statement)
                try self.bindText(principalScope, at: 2, to: statement)
                try self.bindText(TodoStorage.inboxFolderId, at: 3, to: statement)
                try self.checkSQLite(sqlite3_step(statement), expected: SQLITE_ROW)
                return Int(sqlite3_column_int64(statement, 0))
            }
        }
    }

    /// Resend-once (design 30 §5.5): acknowledged creates found absent after a resync are marked as
    /// re-verified at `generation` and read as attempted-unacknowledged again, so they are resent
    /// with their reserved ids (a durable receipt replays; an erased one executes anew). The next
    /// acknowledgement sets `acknowledged` again; the generation stays, so they are resent once.
    public func markImportReverified(mutationIds: [String], generation: Int64) throws {
        guard !mutationIds.isEmpty else { return }
        try self.queue.sync {
            try self.durably {
                try self.transaction {
                    for mutationId in mutationIds {
                        try self.executeChecked("UPDATE cloud_import_attempt SET acknowledged = 0, verified_generation = ? WHERE create_mutation_id = ?;") { statement in
                            try self.bindInteger(generation, at: 1, to: statement)
                            try self.bindText(mutationId, at: 2, to: statement)
                        }
                    }
                }
            }
        }
    }

    /// A new cloud store of the account (design 30 §5.5; Android FIX-A3): its `resync_generation`
    /// reads 0 again, so every verification recorded against an earlier store is void. It also runs
    /// after a rebind of the store to another server account (the rebind drops `migration_checked`),
    /// where `resync_generation` does not reset. The account's record and the attempt rows of its
    /// mappings go to verified generation -1, older than any generation of a store: a completed copy
    /// is checked again and an acknowledged row absent from the new store is resent once. Every
    /// mapping of the account is voided, whatever its scope: after a rebind also those of the scope
    /// the record leaves (`skipped(scope_changed)`), so a later explicit copy into either scope offers
    /// an acknowledged row missing from that snapshot as a resend, whose immutable receipt the server
    /// replays (nothing reappears). State, mappings and acknowledgements stay. Idempotent.
    public func invalidateMigrationVerification(accountPeerId: Int64) throws {
        try self.queue.sync {
            try self.durably {
                try self.transaction {
                    try self.executeChecked("UPDATE cloud_migration SET verified_generation = -1 WHERE account_peer_id = ?;") { statement in
                        try self.bindInteger(accountPeerId, at: 1, to: statement)
                    }
                    try self.executeChecked("UPDATE cloud_import_attempt SET verified_generation = -1 WHERE create_mutation_id IN (SELECT create_mutation_id FROM cloud_import_map WHERE account_peer_id = ?);") { statement in
                        try self.bindInteger(accountPeerId, at: 1, to: statement)
                    }
                }
            }
        }
    }

    public func countActiveAndTotal(folderId: String) -> (done: Int, total: Int) {
        return self.queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT SUM(is_completed) AS done, COUNT(*) AS total FROM tasks WHERE folder_id = ?;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
            sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
            let done = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? 0 : Int(sqlite3_column_int(stmt, 0))
            let total = Int(sqlite3_column_int(stmt, 1))
            return (done, total)
        }
    }
}

// MARK: - Legacy structs for migration (UserDefaults JSON shape)

private struct LegacyFolder: Codable {
    let id: String
    let title: String
    let createdDate: Int32
}

private struct LegacyTask: Codable {
    let id: String
    let folderId: String
    let title: String
    let isCompleted: Bool
    let createdDate: Int32
}
