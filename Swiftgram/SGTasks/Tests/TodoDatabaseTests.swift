import Foundation
import sqlcipher

private enum TestFailure: Error {
    case assertion(String)
    case sqlite(Int32)
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw TestFailure.assertion(message)
    }
}

private func expectFailure(_ expected: TodoDatabaseError? = nil, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        if let expected = expected {
            try check(error as? TodoDatabaseError == expected, "Unexpected rejection error: \(error)")
        }
        return
    }
    throw TestFailure.assertion("Expected operation to fail")
}

private func executeSQL(at path: String, _ sql: String) throws {
    var connection: OpaquePointer?
    let opened = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    defer { sqlite3_close(connection) }
    guard opened == SQLITE_OK else { throw TestFailure.sqlite(opened) }
    let result = sqlite3_exec(connection, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw TestFailure.sqlite(result) }
}

private func scalarSQL(at path: String, _ sql: String) throws -> Int64 {
    var connection: OpaquePointer?
    var statement: OpaquePointer?
    let opened = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil)
    defer { sqlite3_finalize(statement); sqlite3_close(connection) }
    guard opened == SQLITE_OK else { throw TestFailure.sqlite(opened) }
    let prepared = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
    guard prepared == SQLITE_OK else { throw TestFailure.sqlite(prepared) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW else { throw TestFailure.sqlite(result) }
    return sqlite3_column_int64(statement, 0)
}

private func createV1Database(at path: String, task: TodoTask) throws {
    try executeSQL(at: path, """
    CREATE TABLE folders (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
    );
    CREATE TABLE tasks (
        id TEXT PRIMARY KEY, folder_id TEXT REFERENCES folders(id) ON DELETE CASCADE,
        title TEXT NOT NULL, description TEXT, due_at INTEGER,
        priority INTEGER NOT NULL DEFAULT 0, is_completed INTEGER NOT NULL DEFAULT 0,
        completed_at INTEGER, sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    );
    CREATE INDEX idx_tasks_folder_sort ON tasks(folder_id, sort_order);
    CREATE INDEX idx_tasks_completed_due ON tasks(is_completed, due_at);
    CREATE INDEX idx_tasks_due_pending ON tasks(due_at) WHERE is_completed = 0;
    INSERT INTO folders VALUES ('legacy-folder', 'Legacy list', 17, 1600000000);
    PRAGMA user_version = 1;
    """)
    try seedTask(at: path, task)
}

// Fixture setup only: seed the persisted legacy row without minting an Undo capability.
private func seedTask(at path: String, _ task: TodoTask) throws {
    var connection: OpaquePointer?
    var statement: OpaquePointer?
    let opened = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil)
    defer { sqlite3_finalize(statement); sqlite3_close(connection) }
    guard opened == SQLITE_OK else { throw TestFailure.sqlite(opened) }
    let sql = """
    INSERT INTO tasks (id, folder_id, title, description, due_at, priority, is_completed, completed_at, sort_order, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """
    let prepared = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
    guard prepared == SQLITE_OK else { throw TestFailure.sqlite(prepared) }
    func text(_ index: Int32, _ value: String?) throws {
        let result: Int32
        if let value = value {
            result = sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw TestFailure.sqlite(result) }
    }
    func number(_ index: Int32, _ value: Int64?) throws {
        let result = value.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw TestFailure.sqlite(result) }
    }
    try text(1, task.id)
    try text(2, task.folderId)
    try text(3, task.title)
    try text(4, task.description)
    try number(5, task.dueAt.map(Int64.init))
    try number(6, Int64(task.priority))
    try number(7, task.isCompleted ? 1 : 0)
    try number(8, task.completedAt.map(Int64.init))
    try number(9, Int64(task.sortOrder))
    try number(10, Int64(task.createdDate))
    try number(11, Int64(task.updatedAt))
    let inserted = sqlite3_step(statement)
    guard inserted == SQLITE_DONE else { throw TestFailure.sqlite(inserted) }
}

private func withDatabasePath(_ body: (String, UserDefaults) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sgtasks-tests-\(UUID().uuidString)")
    let suiteName = "sgtasks-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
    try autoreleasepool {
        let path = directory.appendingPathComponent("tasks.sqlite").path
        try body(path, defaults)
    }
}

private func withDatabase(_ body: (TodoDatabase, String, UserDefaults) throws -> Void) throws {
    try withDatabasePath { path, defaults in
        let database = TodoDatabase(dbPath: path, defaults: defaults)
        try body(database, path, defaults)
    }
}

private func snapshot(folderId: String, id: String = UUID().uuidString, title: String = "Old task") -> TodoTask {
    return TodoTask(
        id: id, folderId: folderId, title: title, description: "Keep this metadata",
        dueAt: 1_800_000_000, priority: 4, isCompleted: true, completedAt: 1_700_000_100,
        sortOrder: 42, createdDate: 1_700_000_000, updatedAt: 1_700_000_200
    )
}

@main
private struct TodoDatabaseTests {
    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("shared title policy works without database access", sharedTitlePolicy),
            ("lazy stable inbox, never title-based", lazyInbox),
            ("explicit folder and stale selection", explicitFolder),
            ("title validation is write-free", invalidTitles),
            ("invisible and oversized UTF8 titles are write-free", invisibleAndOversizedTitles),
            ("8192-byte title boundary remains supported", titleByteBoundary),
            ("Unicode title boundaries and bound SQL", titleBoundaries),
            ("rename preserves current persisted metadata", renameMetadata),
            ("completion is idempotent and ID-specific", completion),
            ("delete and restore preserve exact full row", deleteRestore),
            ("restore rejects conflict without clobber", restoreConflict),
            ("restore cannot recreate deleted folder", restoreMissingFolder),
            ("logout invalidates undo even after inbox recreation", restoreAfterWipe),
            ("undo tokens belong to their database instance", restoreWrongInstance),
            ("undo preserves legacy titles outside create limits", restoreLegacyTitle),
            ("folder insert failure cannot create task", folderInsertRollback),
            ("prepare failure rolls back inbox", prepareRollback),
            ("quick-add rolls back failed insert", insertRollback),
            ("quick-add rejects ignored insert", ignoredInsert),
            ("quick-add rolls back failed commit", commitRollback),
            ("delete failure preserves persisted row", deleteRollback),
            ("rename and completion surface SQLite failures", updateFailures),
            ("missing task never reports success", missingTasks),
            ("reopen preserves all existing metadata", reopenDatabase),
            ("legacy defaults remain isolated", legacyDefaults),
            ("optional metadata creates and survives closed reopen", metadataCreateReopen),
            ("all task query projections preserve assignee", metadataQueries),
            ("details update retains unrelated persisted fields", updateDetails),
            ("assignee and deadline clear independently", clearDetails),
            ("rename legacy update toggle reorder and Undo retain assignee", metadataPreservation),
            ("invalid assignees never create lazy inbox", invalidAssignees),
            ("invalid detail updates preserve exact row", invalidDetails),
            ("assignee character and byte boundaries are enforced", assigneeBoundaries),
            ("deadline zero and Int32 bounds persist without wrapping", deadlineBoundaries),
            ("quoted Unicode metadata and IDs are bound as values", quotedMetadata),
            ("metadata insert failures roll back lazy inbox", metadataInsertRollback),
            ("details update failures preserve the committed row", detailsUpdateRollback),
            ("details missing task and unavailable database throw", detailsFailures),
            ("v1 migration preserves rows and adds nullable metadata", migrateV1),
            ("failed v1 migration rolls back columns and version", migrationRollback),
            ("v3 migration backfills a distinct incarnation per existing folder", migrateV3Incarnations),
            ("every actual folder insert mints an incarnation, updates keep it", incarnationPerInsert),
            ("import snapshot pins parent incarnation; mapping immutable, reused, per account", importMappingReuse),
            ("final wipe removes import mapping and fences earlier snapshots", importMappingWipe),
            ("v4 -> v5 adds the owner, migration and verified_generation; existing rows kept; idempotent", migrateV4ToV5),
            ("a failed v4 -> v5 upgrade rolls back every v5 table and column", migrationV5Rollback),
            ("owner marker: claim, alreadyOwner, ownedByOther, asCompleted, complete", deviceOwnerClaims),
            ("a released marker is claimed again only by its own account", releasedReclaim),
            ("withdrawn/erased release voids mappings and attempts; a never-enqueued owner is freed", releaseVoidsMappings),
            ("scope_changed release keeps mappings, releases the marker, skips the record", releaseScopeChanged),
            ("migration record CRUD with compare-and-set", migrationRecordCrud),
            ("hasCloudImportMapping sees every scope, v1 included; unmappedLiveRowCount per scope", mappingQueries),
            ("markImportReverified reopens an acknowledged create once per generation", importReverified),
            ("final wipe clears the owner marker and every migration record", wipeClearsMigrationState),
            ("write fence: archived and migrating refuse checked writes of that account only", writeFenceRefusesCheckedWrites),
            ("write fence: the facades refuse before touching the shared database", writeFenceFacades),
            ("wf15 §7.2: liveTasksWithAssignee lists every row with a local assignee, completed included, with its parent's incarnation, by created_at then id", liveTasksWithAssignee)
        ]
        for (name, test) in cases {
            try test()
            print("PASS: \(name)")
        }
        print("PASS: \(cases.count) storage behavior tests")
    }

    private static func sharedTitlePolicy() throws {
        let taskTitle = String(repeating: "a", count: TodoStorage.taskTitleLimit)
        let folderTitle = String(repeating: "b", count: TodoStorage.folderTitleLimit)
        let acceptedTask = try TodoStorage.validatedTitle(" \n" + taskTitle + "\t", limit: TodoStorage.taskTitleLimit)
        let acceptedFolder = try TodoStorage.validatedTitle(folderTitle, limit: TodoStorage.folderTitleLimit)
        try check(acceptedTask == taskTitle && acceptedFolder == folderTitle, "Shared policy changed valid title text")
        try expectFailure(.invalidTitle) { _ = try TodoStorage.validatedTitle(taskTitle + "x", limit: TodoStorage.taskTitleLimit) }
        try expectFailure(.invalidTitle) { _ = try TodoStorage.validatedTitle(folderTitle + "x", limit: TodoStorage.folderTitleLimit) }
        try expectFailure(.invalidTitle) { _ = try TodoStorage.validatedTitle("\u{200B}\u{0301}", limit: TodoStorage.taskTitleLimit) }
        let oversized = "a" + String(repeating: "\u{0301}", count: TodoStorage.maximumTitleUTF8Bytes / 2)
        try expectFailure(.invalidTitle) { _ = try TodoStorage.validatedTitle(oversized, limit: TodoStorage.taskTitleLimit) }
    }

    private static func lazyInbox() throws {
        try withDatabase { database, _, _ in
            try check(database.loadFolders().isEmpty, "Opening storage created an inbox")
            let existing = try database.createFolder(title: "Inbox")
            let first = try database.createQuickTask(folderId: nil, title: "  First\n", inboxTitle: "Inbox")
            let second = try database.createQuickTask(folderId: nil, title: "Second", inboxTitle: "Incoming")
            try check(first.folderId == "sgtasks.inbox", "Inbox ID must be stable")
            try check(first.folderId != existing.id, "A matching title is not an inbox identity")
            try check(second.folderId == first.folderId, "Quick-add created a second inbox")
            try check(first.title == "First", "Task title was not trimmed")
            try check(second.sortOrder > first.sortOrder, "New task must append")
            try check(database.loadTasks().contains(first), "Returned task was not persisted")
            try check(database.loadTasks().contains(second), "Second returned task was not persisted")
            let folders = database.loadFolders()
            try check(folders.count == 2, "Unexpected folder count")
            try check(folders.first(where: { $0.id == first.folderId })?.title == "Inbox", "Reuse renamed the inbox")
        }
    }

    private static func explicitFolder() throws {
        try withDatabase { database, _, _ in
            let folder = try database.createFolder(title: "  Work\n")
            try check(folder.title == "Work", "Folder title was not trimmed")
            let task = try database.createQuickTask(folderId: folder.id, title: "Task", inboxTitle: "Inbox")
            try check(task.folderId == folder.id, "Quick-add ignored selected folder")
            try check(database.loadFolders() == [folder], "Explicit folder add created inbox")
            try database.removeFolder(id: folder.id)
            try expectFailure(.folderNotFound) { _ = try database.createQuickTask(folderId: folder.id, title: "Stale", inboxTitle: "Inbox") }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Stale selection created data")
        }
    }

    private static func invalidTitles() throws {
        try withDatabase { database, _, _ in
            for title in ["", " \n\t ", String(repeating: "a", count: 201)] {
                try expectFailure(.invalidTitle) { _ = try database.createQuickTask(folderId: nil, title: title, inboxTitle: "Inbox") }
            }
            for title in ["", " \n\t ", String(repeating: "a", count: 101)] {
                try expectFailure(.invalidTitle) { _ = try database.createFolder(title: title) }
                try expectFailure(.invalidTitle) { _ = try database.createQuickTask(folderId: nil, title: "Valid", inboxTitle: title) }
            }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Invalid title caused writes")
        }
    }

    private static func invisibleAndOversizedTitles() throws {
        try withDatabase { database, _, _ in
            let invalid = [
                "\0", "\u{7}", "\u{200B}\u{200D}\u{FEFF}", "\u{0301}", "\u{0903}", "\u{20DD}",
                " \t\u{0301}\u{200B}\u{200D}\n", "a" + String(repeating: "\u{0301}", count: 4096)
            ]
            for title in invalid {
                try expectFailure(.invalidTitle) { _ = try database.createQuickTask(folderId: nil, title: title, inboxTitle: "Inbox") }
                try expectFailure(.invalidTitle) { _ = try database.createFolder(title: title) }
                try expectFailure(.invalidTitle) { _ = try database.createQuickTask(folderId: nil, title: "Valid", inboxTitle: title) }
            }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Rejected title created data")
            let task = try database.createQuickTask(folderId: nil, title: "Unchanged", inboxTitle: "Inbox")
            for title in invalid {
                try expectFailure(.invalidTitle) { try database.renameTask(id: task.id, title: title) }
            }
            try check(database.loadTasks() == [task], "Rejected rename changed persisted data")
        }
    }

    private static func titleByteBoundary() throws {
        try withDatabase { database, _, _ in
            let title = "aa" + String(repeating: "\u{0301}", count: 4095)
            try check(title.utf8.count == 8192, "Incorrect byte-boundary fixture")
            let folder = try database.createFolder(title: title)
            let task = try database.createQuickTask(folderId: folder.id, title: title, inboxTitle: "Inbox")
            try check(database.loadFolders() == [folder] && database.loadTasks() == [task], "Byte boundary failed")
            try database.renameTask(id: task.id, title: title)
            try check(database.loadTasks().first?.title == title, "Rename rejected the byte boundary")
        }
    }

    private static func titleBoundaries() throws {
        try withDatabase { database, _, _ in
            let folderTitle = String(repeating: "é", count: 100)
            let folder = try database.createFolder(title: folderTitle)
            let title = String(repeating: "e\u{301}", count: 200)
            let task = try database.createQuickTask(folderId: folder.id, title: title, inboxTitle: "Inbox")
            try check(database.loadFolders() == [folder], "Folder boundary failed")
            try check(database.loadTasks() == [task], "Grapheme-count title boundary failed")
            let sqlTitle = "'); DROP TABLE tasks; --\0still text"
            try database.renameTask(id: task.id, title: sqlTitle)
            try check(database.loadTasks().first?.title == sqlTitle, "Bound text lost data or was interpreted as SQL")
            let sqlFolder = try database.createFolder(title: sqlTitle)
            try check(database.loadFolders().contains(sqlFolder), "Bound folder title lost data")
            let emojiTitle = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"
            let emojiTask = try database.createQuickTask(folderId: folder.id, title: emojiTitle, inboxTitle: "Inbox")
            try check(database.loadTasks().contains(emojiTask), "Emoji title was rejected or normalized")
        }
    }

    private static func renameMetadata() throws {
        try withDatabase { database, path, _ in
            let folder = try database.createFolder(title: "Work")
            let original = snapshot(folderId: folder.id)
            try seedTask(at: path, original)
            database.updateTask(id: original.id, title: original.title, description: "Newer description", dueAt: 1_900_000_000, priority: 2)
            let current = database.loadTasks()[0]
            try database.renameTask(id: original.id, title: "  Renamed\n")
            let renamed = database.loadTasks()[0]
            let expected = TodoTask(
                id: current.id, folderId: current.folderId, title: "Renamed", description: current.description,
                dueAt: current.dueAt, priority: current.priority, isCompleted: current.isCompleted, completedAt: current.completedAt,
                sortOrder: current.sortOrder, createdDate: current.createdDate, updatedAt: renamed.updatedAt
            )
            try check(renamed == expected, "Rename discarded persisted metadata")
            try check(renamed.updatedAt >= current.updatedAt, "Rename did not maintain update timestamp")
            try expectFailure(.invalidTitle) { try database.renameTask(id: original.id, title: " ") }
            try expectFailure(.invalidTitle) { try database.renameTask(id: original.id, title: String(repeating: "x", count: 201)) }
            try check(database.loadTasks() == [renamed], "Invalid rename modified the task")
        }
    }

    private static func completion() throws {
        try withDatabase { database, path, _ in
            let folder = try database.createFolder(title: "Work")
            let original = snapshot(folderId: folder.id)
            try seedTask(at: path, original)
            let other = try database.createQuickTask(folderId: folder.id, title: "Untouched", inboxTitle: "Inbox")
            try check(other.sortOrder > original.sortOrder, "Quick-add must append after existing order, not count")
            try database.setTaskCompleted(id: original.id, isCompleted: true)
            try check(database.loadTasks().contains(original), "Idempotent completion altered original timestamps")
            try database.setTaskCompleted(id: original.id, isCompleted: false)
            let reopened = database.loadTasks().first(where: { $0.id == original.id })!
            let expected = TodoTask(
                id: original.id, folderId: original.folderId, title: original.title, description: original.description,
                dueAt: original.dueAt, priority: original.priority, isCompleted: false, completedAt: nil,
                sortOrder: original.sortOrder, createdDate: original.createdDate, updatedAt: reopened.updatedAt
            )
            try check(reopened == expected && reopened.updatedAt > original.updatedAt, "Reopen changed unrelated metadata")
            try database.setTaskCompleted(id: original.id, isCompleted: false)
            try check(database.loadTasks().contains(reopened), "Repeated reopen changed timestamps")
            try database.setTaskCompleted(id: original.id, isCompleted: true)
            let completed = database.loadTasks().first(where: { $0.id == original.id })!
            try check(completed.isCompleted && completed.completedAt == completed.updatedAt, "Completion timestamp missing")
            try database.setTaskCompleted(id: original.id, isCompleted: true)
            try check(database.loadTasks().contains(completed), "Repeated completion changed timestamps")
            try check(database.loadTasks().contains(other), "Completion touched another ID")
        }
    }

    private static func deleteRestore() throws {
        try withDatabase { database, path, _ in
            let folder = try database.createFolder(title: "Work")
            let original = snapshot(folderId: folder.id)
            try seedTask(at: path, original)
            database.updateTask(id: original.id, title: "Persisted version", description: "Updated", dueAt: nil, priority: 3)
            let current = database.loadTasks()[0]
            let deleted = try database.deleteTaskForUndo(id: original.id)
            try check(deleted?.task == current, "Delete returned a stale or partial snapshot")
            try check(database.loadTasks().isEmpty, "Deleted task is still persisted")
            let absent = try database.deleteTaskForUndo(id: original.id)
            try check(absent == nil, "Repeated delete must return nil")
            try database.restoreDeletedTask(deleted!)
            try check(database.loadTasks() == [current], "Undo changed identity or metadata")
            let full = snapshot(folderId: folder.id)
            try seedTask(at: path, full)
            let fullDeleted = try database.deleteTaskForUndo(id: full.id)
            try check(fullDeleted?.task == full, "Non-null metadata snapshot changed")
            try database.restoreDeletedTask(fullDeleted!)
            try check(database.loadTasks().contains(full), "Full metadata restoration changed")
        }
    }

    private static func restoreConflict() throws {
        try withDatabase { database, path, _ in
            let folder = try database.createFolder(title: "Work")
            let original = snapshot(folderId: folder.id)
            try seedTask(at: path, original)
            let deleted = try database.deleteTaskForUndo(id: original.id)!
            try seedTask(at: path, original)
            try database.renameTask(id: original.id, title: "Keep current version")
            let current = database.loadTasks()[0]
            try expectFailure(.sqlite(SQLITE_CONSTRAINT)) { try database.restoreDeletedTask(deleted) }
            try check(database.loadTasks() == [current], "Conflicting undo clobbered the existing row")
        }
    }

    private static func restoreMissingFolder() throws {
        try withDatabase { database, path, _ in
            let folder = try database.createFolder(title: "Work")
            let original = snapshot(folderId: folder.id)
            try seedTask(at: path, original)
            let deleted = try database.deleteTaskForUndo(id: original.id)!
            try database.removeFolder(id: folder.id)
            try expectFailure(.folderNotFound) { try database.restoreDeletedTask(deleted) }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Undo recreated a deleted folder")
        }
    }

    private static func restoreAfterWipe() throws {
        try withDatabase { database, _, _ in
            let oldTask = try database.createQuickTask(folderId: nil, title: "Old account", inboxTitle: "Inbox")
            let deleted = try database.deleteTaskForUndo(id: oldTask.id)!
            database.removeAllData()
            let newTask = try database.createQuickTask(folderId: nil, title: "New account", inboxTitle: "Inbox")
            try check(newTask.folderId == oldTask.folderId, "Fixture did not recreate the stable inbox")
            try expectFailure(.invalidSnapshot) { try database.restoreDeletedTask(deleted) }
            try check(database.loadTasks() == [newTask], "Undo resurrected wiped task data")
            let newDeleted = try database.deleteTaskForUndo(id: newTask.id)!
            try database.restoreDeletedTask(newDeleted)
            try check(database.loadTasks() == [newTask], "Fresh undo failed after generation changed")
        }
    }

    private static func restoreWrongInstance() throws {
        try withDatabase { database, path, defaults in
            let task = try database.createQuickTask(folderId: nil, title: "Original", inboxTitle: "Inbox")
            let deleted = try database.deleteTaskForUndo(id: task.id)!
            let otherInstance = TodoDatabase(dbPath: path, defaults: defaults)
            try expectFailure(.invalidSnapshot) { try otherInstance.restoreDeletedTask(deleted) }
            try check(otherInstance.loadTasks().isEmpty, "Another instance accepted a foreign undo token")
            try database.restoreDeletedTask(deleted)
            try check(database.loadTasks() == [task], "Original instance rejected its own token")
        }
    }

    private static func restoreLegacyTitle() throws {
        try withDatabase { database, path, _ in
            let folder = try database.createFolder(title: "Legacy")
            let original = snapshot(folderId: folder.id, title: String(repeating: "x", count: 300))
            try seedTask(at: path, original)
            let deleted = try database.deleteTaskForUndo(id: original.id)!
            try database.restoreDeletedTask(deleted)
            try check(database.loadTasks() == [original], "Undo applied create validation to legacy metadata")
        }
    }

    private static func folderInsertRollback() throws {
        try withDatabase { database, path, _ in
            try executeSQL(at: path, "CREATE TRIGGER fail_folder BEFORE INSERT ON folders BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;")
            try expectFailure { _ = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox") }
            try expectFailure { _ = try database.createFolder(title: "List") }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Failed folder insert left partial data")
            try executeSQL(at: path, "DROP TRIGGER fail_folder;")
            let task = try database.createQuickTask(folderId: nil, title: "Retry", inboxTitle: "Inbox")
            try check(database.loadTasks() == [task], "Folder rollback left transaction open")
        }
    }

    private static func prepareRollback() throws {
        try withDatabase { database, path, _ in
            try executeSQL(at: path, "DROP TABLE tasks;")
            try expectFailure { _ = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox") }
            try check(database.loadFolders().isEmpty, "Failed prepare left orphan inbox")
            let folder = try database.createFolder(title: "Retry")
            try check(database.loadFolders() == [folder], "Prepare rollback left transaction open")
        }
    }

    private static func insertRollback() throws {
        try withDatabase { database, path, _ in
            try executeSQL(at: path, "CREATE TRIGGER fail_insert BEFORE INSERT ON tasks BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;")
            try expectFailure { _ = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox") }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Failed task insert left orphan inbox")
            try executeSQL(at: path, "DROP TRIGGER fail_insert;")
            let task = try database.createQuickTask(folderId: nil, title: "Retry", inboxTitle: "Inbox")
            try check(database.loadTasks() == [task], "Rollback left connection unusable")
        }
    }

    private static func ignoredInsert() throws {
        try withDatabase { database, path, _ in
            try executeSQL(at: path, "CREATE TRIGGER ignore_insert BEFORE INSERT ON tasks BEGIN SELECT RAISE(IGNORE); END;")
            try expectFailure { _ = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox") }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Ignored insert reported phantom success")
        }
    }

    private static func commitRollback() throws {
        try withDatabase { database, path, _ in
            try executeSQL(at: path, """
            CREATE TABLE deferred_failure (folder_id TEXT REFERENCES folders(id) DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER fail_commit AFTER INSERT ON tasks BEGIN INSERT INTO deferred_failure VALUES ('missing-folder'); END;
            """)
            try expectFailure { _ = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox") }
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Failed commit leaked pending writes")
            try executeSQL(at: path, "DROP TRIGGER fail_commit;")
            let task = try database.createQuickTask(folderId: nil, title: "Retry", inboxTitle: "Inbox")
            try check(database.loadTasks() == [task], "Commit rollback left transaction open")
        }
    }

    private static func deleteRollback() throws {
        try withDatabase { database, path, _ in
            let task = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox")
            try executeSQL(at: path, "CREATE TRIGGER fail_delete BEFORE DELETE ON tasks BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;")
            try expectFailure { _ = try database.deleteTaskForUndo(id: task.id) }
            try check(database.loadTasks() == [task], "Failed deletion changed persisted row")
            try executeSQL(at: path, "DROP TRIGGER fail_delete;")
            let deleted = try database.deleteTaskForUndo(id: task.id)
            try check(deleted?.task == task && database.loadTasks().isEmpty, "Delete retry failed")
        }
    }

    private static func updateFailures() throws {
        try withDatabase { database, path, _ in
            let task = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox")
            try executeSQL(at: path, "CREATE TRIGGER fail_update BEFORE UPDATE ON tasks BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;")
            try expectFailure { try database.renameTask(id: task.id, title: "Changed") }
            try expectFailure { try database.setTaskCompleted(id: task.id, isCompleted: true) }
            try check(database.loadTasks() == [task], "Failed update modified persisted data")
        }
    }

    private static func missingTasks() throws {
        try withDatabase { database, _, _ in
            try expectFailure(.taskNotFound) { try database.renameTask(id: "missing", title: "Changed") }
            try expectFailure(.taskNotFound) { try database.setTaskCompleted(id: "missing", isCompleted: true) }
            try expectFailure(.taskNotFound) { try database.setTaskCompleted(id: "missing", isCompleted: false) }
            let deleted = try database.deleteTaskForUndo(id: "missing")
            try check(deleted == nil, "Missing delete returned a snapshot")
            try check(database.loadTasks().isEmpty && database.loadFolders().isEmpty, "Missing row operations created data")
        }
    }

    private static func reopenDatabase() throws {
        try withDatabase { database, path, defaults in
            database.addFolder(title: "Legacy list")
            let folder = database.loadFolders()[0]
            let task = database.addTask(folderId: folder.id, title: "Legacy task", description: "Existing detail", dueAt: 1_900_000_000, priority: 4)
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            try check(reopened.loadFolders() == [folder], "Opening v1 changed folder identity or metadata")
            try check(reopened.loadTasks() == [task], "Opening v1 changed task identity or metadata")
        }
    }

    private static func legacyDefaults() throws {
        try withDatabase { _, path, defaults in
            defaults.set(false, forKey: "todo_sqlite_migration_done")
            defaults.set(Data("[{\"id\":\"legacy-folder\",\"title\":\"Imported\",\"createdDate\":100}]".utf8), forKey: "todo_folders_list")
            defaults.set(Data("[{\"id\":\"legacy-task\",\"folderId\":\"legacy-folder\",\"title\":\"Imported task\",\"isCompleted\":true,\"createdDate\":101}]".utf8), forKey: "todo_tasks_list")
            let imported = TodoDatabase(dbPath: path, defaults: defaults)
            try check(imported.loadFolders().first?.id == "legacy-folder", "Injected defaults were not used")
            try check(imported.loadTasks().first?.id == "legacy-task", "Legacy task identity changed")
            try check(imported.loadTasks().first?.isCompleted == true, "Legacy completion changed")
            imported.removeAllData()
            try check(imported.loadTasks().isEmpty && imported.loadFolders().isEmpty, "Isolated cleanup failed")
            try check(defaults.data(forKey: "todo_folders_list") == nil, "Cleanup ignored injected defaults")
            try check(defaults.data(forKey: "todo_tasks_list") == nil, "Cleanup ignored injected task defaults")
        }
    }

    private static func metadataCreateReopen() throws {
        try withDatabasePath { path, defaults in
            let assignee = TodoAssignee(peerId: 4_294_967_297, displayName: "O‘zbek e\u{301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}")
            let saved: [TodoTask] = try autoreleasepool {
                let database = TodoDatabase(dbPath: path, defaults: defaults)
                try database.checkAvailability()
                let full = try database.createQuickTask(folderId: nil, title: "  Full \n", inboxTitle: "Inbox", assignee: assignee, dueAt: 1_900_000_000)
                let plain = try database.createQuickTask(folderId: full.folderId, title: "Plain", inboxTitle: "Unused")
                let assigned = try database.createQuickTask(folderId: full.folderId, title: "Assigned", inboxTitle: "Unused", assignee: assignee)
                let dated = try database.createQuickTask(folderId: full.folderId, title: "Dated", inboxTitle: "Unused", dueAt: 0)
                try check(full.title == "Full" && full.assignee == assignee && full.dueAt == 1_900_000_000, "Quick-add returned incomplete metadata")
                try check(plain.assignee == nil && plain.dueAt == nil, "Optional metadata is not optional")
                try check(assigned.assignee == assignee && assigned.dueAt == nil, "Assignee-only create changed deadline")
                try check(dated.assignee == nil && dated.dueAt == 0, "Deadline-only create changed assignee")
                try check(database.loadTasks() == [full, plain, assigned, dated], "Created metadata differs from persisted rows")
                return [full, plain, assigned, dated]
            }
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            try reopened.checkAvailability()
            try check(reopened.loadTasks() == saved, "Closing and reopening lost optional metadata")
            let version = try scalarSQL(at: path, "PRAGMA user_version;")
            let partialPairs = try scalarSQL(at: path, "SELECT COUNT(*) FROM tasks WHERE (assignee_peer_id IS NULL) != (assignee_display_name IS NULL);")
            try check(version == 5 && partialPairs == 0, "Fresh schema or all-or-none assignee persistence is incorrect")
        }
    }

    private static func metadataQueries() throws {
        try withDatabase { database, _, _ in
            let assignee = TodoAssignee(peerId: Int64.max, displayName: "Query contact")
            let overdue = try database.createQuickTask(folderId: nil, title: "Find overdue", inboxTitle: "Inbox", assignee: assignee, dueAt: 0)
            let upcoming = try database.createQuickTask(folderId: overdue.folderId, title: "Find upcoming", inboxTitle: "Inbox", assignee: assignee, dueAt: .max)
            try check(database.loadTasks(folderId: overdue.folderId) == [overdue, upcoming], "Folder projection lost assignee")
            try check(database.loadTasksDueToday() == [overdue], "Today projection lost metadata or deadline filtering")
            try check(database.loadTasksUpcoming() == [upcoming], "Upcoming projection lost metadata or deadline filtering")
            try check(database.searchTasks(query: "Find").contains(overdue), "Search projection lost overdue metadata")
            try check(database.searchTasks(query: "upcoming") == [upcoming], "Search projection lost upcoming metadata")
        }
    }

    private static func updateDetails() throws {
        try withDatabase { database, path, defaults in
            let folder = try database.createFolder(title: "Work")
            let original = snapshot(folderId: folder.id)
            try seedTask(at: path, original)
            let other = try database.createQuickTask(folderId: folder.id, title: "Untouched", inboxTitle: "Inbox")
            let assignee = TodoAssignee(peerId: 9_876_543_210, displayName: "Ada Lovelace")
            try database.updateTaskDetails(id: original.id, title: "  Updated \n", assignee: assignee, dueAt: 2_000_000_000)
            let updated = database.loadTasks().first(where: { $0.id == original.id })!
            let expected = TodoTask(
                id: original.id, folderId: original.folderId, title: "Updated", description: original.description,
                dueAt: 2_000_000_000, priority: original.priority, isCompleted: original.isCompleted,
                completedAt: original.completedAt, sortOrder: original.sortOrder, createdDate: original.createdDate,
                updatedAt: updated.updatedAt, assignee: assignee
            )
            try check(updated == expected, "Details update changed unrelated persisted metadata")
            try check(updated.updatedAt > original.updatedAt, "Details update did not advance old timestamp")
            try check(database.loadTasks().contains(other), "Details update touched another task")
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            try check(reopened.loadTasks().contains(expected), "Details update was not committed")
        }
    }

    private static func clearDetails() throws {
        try withDatabase { database, path, defaults in
            let assignee = TodoAssignee(peerId: 42, displayName: "Contact")
            let task = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox", assignee: assignee, dueAt: 1_900_000_000)
            try database.updateTaskDetails(id: task.id, title: task.title, assignee: nil, dueAt: task.dueAt)
            let unassigned = database.loadTasks()[0]
            try check(unassigned.assignee == nil && unassigned.dueAt == task.dueAt, "Clearing assignee also cleared deadline")
            let nullPair = try scalarSQL(at: path, "SELECT COUNT(*) FROM tasks WHERE assignee_peer_id IS NULL AND assignee_display_name IS NULL;")
            try check(nullPair == 1, "Clearing assignee left a half-populated SQLite pair")
            try database.updateTaskDetails(id: task.id, title: task.title, assignee: assignee, dueAt: nil)
            let undated = database.loadTasks()[0]
            try check(undated.assignee == assignee && undated.dueAt == nil, "Clearing deadline also cleared assignee")
            try database.updateTaskDetails(id: task.id, title: "Cleared", assignee: nil, dueAt: nil)
            let cleared = database.loadTasks()[0]
            try check(cleared.assignee == nil && cleared.dueAt == nil && cleared.title == "Cleared", "Clearing both metadata fields failed")
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            try check(reopened.loadTasks() == [cleared], "Reopen resurrected cleared metadata")
        }
    }

    private static func metadataPreservation() throws {
        try withDatabase { database, path, defaults in
            let assignee = TodoAssignee(peerId: 4_294_967_298, displayName: "Retained contact")
            let task = try database.createQuickTask(folderId: nil, title: "Original", inboxTitle: "Inbox", assignee: assignee, dueAt: 1_900_000_000)
            try database.renameTask(id: task.id, title: "Renamed")
            try check(database.loadTasks()[0].assignee == assignee && database.loadTasks()[0].dueAt == task.dueAt, "Rename discarded metadata")
            database.updateTask(id: task.id, title: "Legacy edit", description: "Details", dueAt: 2_000_000_000, priority: 4)
            let legacyUpdated = database.loadTasks()[0]
            try check(legacyUpdated.assignee == assignee && legacyUpdated.description == "Details" && legacyUpdated.priority == 4, "Legacy update dropped assignee or ignored its own fields")
            database.toggleTask(id: task.id)
            let toggled = database.loadTasks()[0]
            try check(toggled.isCompleted && toggled.assignee == assignee && toggled.dueAt == legacyUpdated.dueAt, "Legacy toggle discarded metadata")
            try database.setTaskCompleted(id: task.id, isCompleted: false)
            database.reorderTasks(folderId: task.folderId, idsInOrder: [task.id])
            let current = database.loadTasks()[0]
            try check(!current.isCompleted && current.assignee == assignee && current.dueAt == legacyUpdated.dueAt, "Completion or reorder discarded metadata")
            let deleted = try database.deleteTaskForUndo(id: task.id)!
            try check(deleted.task == current && database.loadTasks().isEmpty, "Undo snapshot omitted assignee or captured stale data")
            try database.restoreDeletedTask(deleted)
            try check(database.loadTasks() == [current], "Undo failed to restore exact assignee metadata")
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            try check(reopened.loadTasks() == [current], "Undo metadata did not survive reopen")
            let revoked = try database.deleteTaskForUndo(id: task.id)!
            database.removeAllData()
            _ = try database.createQuickTask(folderId: nil, title: "New account", inboxTitle: "Inbox")
            try expectFailure(.invalidSnapshot) { try database.restoreDeletedTask(revoked) }
            try check(database.loadTasks().allSatisfy { $0.assignee == nil }, "Logout Undo resurrected contact metadata")
        }
    }

    private static func invalidAssignees() throws {
        try withDatabase { database, _, _ in
            let invalid = [
                TodoAssignee(peerId: 0, displayName: "Valid name"),
                TodoAssignee(peerId: -1, displayName: "Valid name"),
                TodoAssignee(peerId: Int64.min, displayName: "Valid name"),
                TodoAssignee(peerId: 1, displayName: ""),
                TodoAssignee(peerId: 1, displayName: " \n\t "),
                TodoAssignee(peerId: 1, displayName: "\0\u{7}"),
                TodoAssignee(peerId: 1, displayName: "\u{200B}\u{200D}\u{FEFF}"),
                TodoAssignee(peerId: 1, displayName: "\u{0301}\u{0903}\u{20DD}"),
                TodoAssignee(peerId: 1, displayName: String(repeating: "é", count: 257)),
                TodoAssignee(peerId: 1, displayName: "a" + String(repeating: "\u{0301}", count: 2048))
            ]
            for assignee in invalid {
                try expectFailure(.invalidAssignee) {
                    _ = try TodoStorage.validatedAssignee(peerId: assignee.peerId, displayName: assignee.displayName)
                }
                try expectFailure(.invalidAssignee) {
                    _ = try database.createQuickTask(folderId: nil, title: "Valid title", inboxTitle: "Inbox", assignee: assignee, dueAt: 1_900_000_000)
                }
                try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Invalid assignee created a lazy inbox or task")
            }
            let valid = try database.createQuickTask(folderId: nil, title: "Retry", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 1, displayName: "Valid"))
            try check(database.loadTasks() == [valid], "Validation rejection left connection unusable")
        }
    }

    private static func invalidDetails() throws {
        try withDatabase { database, _, _ in
            let assignee = TodoAssignee(peerId: 1, displayName: "Keep contact")
            let task = try database.createQuickTask(folderId: nil, title: "Keep title", inboxTitle: "Inbox", assignee: assignee, dueAt: 1_900_000_000)
            for title in ["", " \n ", "\u{200B}", String(repeating: "x", count: 201)] {
                try expectFailure(.invalidTitle) {
                    try database.updateTaskDetails(id: task.id, title: title, assignee: nil, dueAt: nil)
                }
            }
            for invalid in [TodoAssignee(peerId: 0, displayName: "Wrong"), TodoAssignee(peerId: 2, displayName: " \n"), TodoAssignee(peerId: 2, displayName: String(repeating: "a", count: 257))] {
                try expectFailure(.invalidAssignee) {
                    try database.updateTaskDetails(id: task.id, title: "Changed", assignee: invalid, dueAt: nil)
                }
            }
            for dueAt in [Int32(-1), Int32.min] {
                try expectFailure(.invalidDueDate) {
                    try database.updateTaskDetails(id: task.id, title: "Changed", assignee: nil, dueAt: dueAt)
                }
            }
            try check(database.loadTasks() == [task], "Rejected details update partially changed title, metadata or timestamp")
        }
    }

    private static func assigneeBoundaries() throws {
        try withDatabase { database, _, _ in
            let byteBoundary = "aa" + String(repeating: "\u{0301}", count: 2047)
            try check(byteBoundary.utf8.count == 4096, "Incorrect assignee byte boundary fixture")
            let names = [String(repeating: "e\u{0301}", count: 256), byteBoundary, "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"]
            for name in names {
                let padded = TodoAssignee(peerId: Int64.max, displayName: " \n" + name + "\t ")
                let expected = TodoAssignee(peerId: Int64.max, displayName: name)
                let pickerValue = try TodoStorage.validatedAssignee(peerId: padded.peerId, displayName: padded.displayName)
                try check(pickerValue == expected, "Picker preflight did not trim or accept the boundary")
                let task = try database.createQuickTask(folderId: nil, title: "Boundary", inboxTitle: "Inbox", assignee: padded)
                try check(task.assignee == expected && database.loadTasks().contains(task), "Name boundary or trimming failed on create")
                try database.updateTaskDetails(id: task.id, title: task.title, assignee: padded, dueAt: nil)
                try check(database.loadTasks().first(where: { $0.id == task.id })?.assignee == expected, "Details update applied a different name policy")
            }
        }
    }

    private static func deadlineBoundaries() throws {
        try withDatabase { database, _, _ in
            for dueAt in [Int32(-1), Int32.min] {
                try expectFailure(.invalidDueDate) {
                    _ = try database.createQuickTask(folderId: nil, title: "Rejected", inboxTitle: "Inbox", dueAt: dueAt)
                }
                try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "Invalid deadline created a lazy inbox")
            }
            let epoch = try database.createQuickTask(folderId: nil, title: "Epoch", inboxTitle: "Inbox", dueAt: 0)
            let maximum = try database.createQuickTask(folderId: nil, title: "Maximum", inboxTitle: "Inbox", dueAt: .max)
            try check(epoch.dueAt == 0 && maximum.dueAt == Int32.max, "Deadline boundary wrapped or was treated as absent")
            try database.updateTaskDetails(id: epoch.id, title: epoch.title, assignee: nil, dueAt: .max)
            try database.updateTaskDetails(id: maximum.id, title: maximum.title, assignee: nil, dueAt: 0)
            try check(database.loadTasks().first(where: { $0.id == epoch.id })?.dueAt == Int32.max, "Update rejected maximum deadline")
            try check(database.loadTasks().first(where: { $0.id == maximum.id })?.dueAt == 0, "Update discarded epoch deadline")
        }
    }

    private static func quotedMetadata() throws {
        try withDatabase { database, path, _ in
            let first = TodoAssignee(peerId: 4_294_967_299, displayName: "O'Connor'); DROP TABLE tasks; -- e\u{301} \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}")
            let task = try database.createQuickTask(folderId: nil, title: "Quoted", inboxTitle: "Inbox", assignee: first, dueAt: 1_900_000_000)
            try check(database.loadTasks() == [task] && task.assignee == first, "Create interpreted or normalized quoted Unicode name")
            let quotedId = "quoted' OR 1=1 --"
            let seeded = snapshot(folderId: task.folderId, id: quotedId)
            try seedTask(at: path, seeded)
            let second = TodoAssignee(peerId: Int64.max, displayName: "\"Quoted\" 'name' \0suffix")
            try database.updateTaskDetails(id: quotedId, title: "'); DELETE FROM folders; --", assignee: second, dueAt: nil)
            let updated = database.loadTasks().first(where: { $0.id == quotedId })!
            try check(updated.assignee == second && updated.dueAt == nil, "Update did not bind full metadata bytes")
            try check(database.loadTasks().contains(task) && database.loadFolders().count == 1, "Quoted ID or name changed unrelated data")
            let deleted = try database.deleteTaskForUndo(id: quotedId)!
            try database.restoreDeletedTask(deleted)
            try check(database.loadTasks().contains(updated), "Undo truncated embedded NUL or quoted name")
        }
    }

    private static func metadataInsertRollback() throws {
        let failures = [
            "CREATE TRIGGER fail_metadata BEFORE INSERT ON tasks BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;",
            "CREATE TRIGGER fail_metadata BEFORE INSERT ON tasks BEGIN SELECT RAISE(IGNORE); END;",
            """
            CREATE TABLE deferred_metadata_failure (folder_id TEXT REFERENCES folders(id) DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER fail_metadata AFTER INSERT ON tasks BEGIN INSERT INTO deferred_metadata_failure VALUES ('missing-folder'); END;
            """
        ]
        for failure in failures {
            try withDatabase { database, path, _ in
                let assignee = TodoAssignee(peerId: 88, displayName: "Draft contact")
                try executeSQL(at: path, failure)
                try expectFailure {
                    _ = try database.createQuickTask(folderId: nil, title: "Draft title", inboxTitle: "Inbox", assignee: assignee, dueAt: 1_900_000_000)
                }
                try check(database.loadTasks().isEmpty && database.loadFolders().isEmpty, "Failed metadata insert leaked task or inbox")
                try executeSQL(at: path, "DROP TRIGGER fail_metadata;")
                let task = try database.createQuickTask(folderId: nil, title: "Draft title", inboxTitle: "Inbox", assignee: assignee, dueAt: 1_900_000_000)
                try check(database.loadTasks() == [task] && task.assignee == assignee, "Retry lost draft metadata or left transaction open")
            }
        }
    }

    private static func detailsUpdateRollback() throws {
        let failures = [
            "CREATE TRIGGER fail_details BEFORE UPDATE ON tasks BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;",
            "CREATE TRIGGER fail_details BEFORE UPDATE ON tasks BEGIN SELECT RAISE(IGNORE); END;",
            """
            CREATE TABLE deferred_details_failure (folder_id TEXT REFERENCES folders(id) DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER fail_details AFTER UPDATE ON tasks BEGIN INSERT INTO deferred_details_failure VALUES ('missing-folder'); END;
            """
        ]
        for failure in failures {
            try withDatabase { database, path, _ in
                let original = try database.createQuickTask(folderId: nil, title: "Keep", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 1, displayName: "Original"), dueAt: 1_900_000_000)
                let replacement = TodoAssignee(peerId: 2, displayName: "Replacement")
                try executeSQL(at: path, failure)
                try expectFailure { try database.updateTaskDetails(id: original.id, title: "Changed", assignee: replacement, dueAt: 2_000_000_000) }
                try check(database.loadTasks() == [original], "Failed details update partially committed fields or timestamp")
                try executeSQL(at: path, "DROP TRIGGER fail_details;")
                try database.updateTaskDetails(id: original.id, title: "Changed", assignee: replacement, dueAt: 2_000_000_000)
                let retried = database.loadTasks()[0]
                try check(retried.title == "Changed" && retried.assignee == replacement && retried.dueAt == 2_000_000_000, "Details failure left connection unusable")
            }
        }
    }

    private static func detailsFailures() throws {
        try withDatabase { database, path, _ in
            try expectFailure(.taskNotFound) {
                try database.updateTaskDetails(id: "missing", title: "Task", assignee: TodoAssignee(peerId: 1, displayName: "Contact"), dueAt: 0)
            }
            try check(database.loadTasks().isEmpty && database.loadFolders().isEmpty, "Missing details update inserted data")
            try executeSQL(at: path, "DROP TABLE tasks;")
            try expectFailure {
                try database.updateTaskDetails(id: "missing", title: "Task", assignee: nil, dueAt: nil)
            }
            try check(database.loadFolders().isEmpty, "Prepare failure mutated folders")
        }
        try withDatabasePath { path, defaults in
            let unavailable = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("missing-parent/tasks.sqlite").path
            let database = TodoDatabase(dbPath: unavailable, defaults: defaults)
            try expectFailure {
                _ = try database.createQuickTask(folderId: nil, title: "Task", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 1, displayName: "Contact"), dueAt: 0)
            }
            try expectFailure { try database.updateTaskDetails(id: "missing", title: "Task", assignee: nil, dueAt: nil) }
            try check(!FileManager.default.fileExists(atPath: unavailable), "Unavailable path silently created a different database")
        }
    }

    private static func migrateV1() throws {
        try withDatabasePath { path, defaults in
            let original = snapshot(folderId: "legacy-folder")
            let folder = TodoFolder(id: "legacy-folder", title: "Legacy list", sortOrder: 17, createdDate: 1_600_000_000)
            try createV1Database(at: path, task: original)
            let before = try scalarSQL(at: path, "PRAGMA user_version;")
            try check(before == 1, "Migration fixture is not a v1 database")
            let updated: TodoTask = try autoreleasepool {
                let database = TodoDatabase(dbPath: path, defaults: defaults)
                try database.checkAvailability()
                try check(database.loadFolders() == [folder] && database.loadTasks() == [original], "Migration changed existing identity, deadline or metadata")
                let version = try scalarSQL(at: path, "PRAGMA user_version;")
                let nullableColumns = try scalarSQL(at: path, """
                SELECT COUNT(*) FROM pragma_table_info('tasks')
                WHERE (name = 'assignee_peer_id' AND type = 'INTEGER' OR name = 'assignee_display_name' AND type = 'TEXT') AND "notnull" = 0;
                """)
                let unassigned = try scalarSQL(at: path, "SELECT COUNT(*) FROM tasks WHERE assignee_peer_id IS NULL AND assignee_display_name IS NULL;")
                try check(version == 5 && nullableColumns == 2 && unassigned == 1, "Migration did not add nullable v2 assignee pair")
                try database.updateTaskDetails(id: original.id, title: original.title, assignee: TodoAssignee(peerId: 42, displayName: "Migrated contact"), dueAt: original.dueAt)
                return database.loadTasks()[0]
            }
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            try reopened.checkAvailability()
            try check(reopened.loadFolders() == [folder] && reopened.loadTasks() == [updated], "Repeated migration changed saved v2 records")
            let deleted = try reopened.deleteTaskForUndo(id: updated.id)!
            try reopened.restoreDeletedTask(deleted)
            try check(reopened.loadTasks() == [updated], "Migrated row did not support exact Undo")
        }
    }

    private static func migrationRollback() throws {
        try withDatabasePath { path, defaults in
            let original = snapshot(folderId: "legacy-folder")
            try createV1Database(at: path, task: original)
            // A second-column collision forces a failure after the first ALTER, proving atomic DDL.
            try executeSQL(at: path, "ALTER TABLE tasks ADD COLUMN assignee_display_name TEXT;")
            let database = TodoDatabase(dbPath: path, defaults: defaults)
            try expectFailure(.sqlite(SQLITE_ERROR)) { try database.checkAvailability() }
            let version = try scalarSQL(at: path, "PRAGMA user_version;")
            let partialColumn = try scalarSQL(at: path, "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name = 'assignee_peer_id';")
            let preserved = try scalarSQL(at: path, "SELECT COUNT(*) FROM tasks WHERE due_at = 1800000000 AND priority = 4 AND is_completed = 1 AND sort_order = 42;")
            try check(version == 1 && partialColumn == 0, "Failed migration committed a partial schema or bumped version")
            try check(preserved == 1, "Failed migration damaged the existing row")
            try expectFailure {
                _ = try database.createQuickTask(folderId: nil, title: "Must fail", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 1, displayName: "Contact"), dueAt: 0)
            }
            let folders = try scalarSQL(at: path, "SELECT COUNT(*) FROM folders;")
            let tasks = try scalarSQL(at: path, "SELECT COUNT(*) FROM tasks;")
            try check(folders == 1 && tasks == 1, "Migration failure leaked a subsequent partial write")

            // Repair only this isolated fixture, then retry initialization on a fresh instance.
            try executeSQL(at: path, "ALTER TABLE tasks DROP COLUMN assignee_display_name;")
            let recovered = TodoDatabase(dbPath: path, defaults: defaults)
            try recovered.checkAvailability()
            let recoveredVersion = try scalarSQL(at: path, "PRAGMA user_version;")
            try check(recoveredVersion == 5 && recovered.loadTasks() == [original], "Fresh initialization failed to recover or changed the original task")
            let assignee = TodoAssignee(peerId: 42, displayName: "Recovered contact")
            try recovered.updateTaskDetails(id: original.id, title: original.title, assignee: assignee, dueAt: original.dueAt)
            let updated = recovered.loadTasks()[0]
            try check(updated.assignee == assignee && updated.dueAt == original.dueAt, "Recovered database cannot persist v2 metadata")
            try expectFailure(.sqlite(SQLITE_ERROR)) { try database.checkAvailability() }
        }
    }

    // MARK: Cloud import support (v3)

    private static func incarnation(of folderId: String, in database: TodoDatabase) throws -> String {
        guard let folder = try database.cloudImportSnapshot().folders.first(where: { $0.id == folderId }) else {
            throw TestFailure.assertion("Folder missing from import snapshot")
        }
        return folder.incarnation
    }

    private static func migrateV3Incarnations() throws {
        try withDatabasePath { path, defaults in
            try createV1Database(at: path, task: snapshot(folderId: "legacy-folder"))
            try executeSQL(at: path, "INSERT INTO folders VALUES ('second-folder', 'Second', 18, 1600000001);")
            let database = TodoDatabase(dbPath: path, defaults: defaults)
            try database.checkAvailability()
            let version = try scalarSQL(at: path, "PRAGMA user_version;")
            let missing = try scalarSQL(at: path, "SELECT COUNT(*) FROM folders WHERE incarnation IS NULL;")
            let distinct = try scalarSQL(at: path, "SELECT COUNT(DISTINCT incarnation) FROM folders;")
            let mapTable = try scalarSQL(at: path, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'cloud_import_map';")
            try check(version == 5 && missing == 0 && distinct == 2 && mapTable == 1, "v3 migration did not backfill distinct incarnations with the mapping table")
            let before = try incarnation(of: "legacy-folder", in: database)
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            let reopenedIncarnation = try incarnation(of: "legacy-folder", in: reopened)
            let reopenedTasks = try reopened.cloudImportSnapshot().tasks
            try check(reopenedIncarnation == before, "Reopening re-minted a persisted incarnation")
            try check(reopenedTasks.allSatisfy { $0.folderIncarnation == before }, "Task snapshot did not pin its parent's incarnation")
        }
    }

    private static func incarnationPerInsert() throws {
        try withDatabasePath { path, defaults in
            let legacyFolders = "[{\"id\":\"ud-folder\",\"title\":\"From defaults\",\"createdDate\":1600000000}]"
            defaults.set(Data(legacyFolders.utf8), forKey: "todo_folders_list")
            let database = TodoDatabase(dbPath: path, defaults: defaults)
            try database.checkAvailability()
            let migrated = try incarnation(of: "ud-folder", in: database)
            try check(!migrated.isEmpty, "UserDefaults migration inserted a folder without incarnation")

            let folder = try database.createFolder(title: "Work")
            let created = try incarnation(of: folder.id, in: database)
            try database.updateFolderTitle(id: folder.id, title: "Work renamed")
            let renamed = try incarnation(of: folder.id, in: database)
            try check(renamed == created, "A title UPDATE changed the folder incarnation")

            // The stable inbox id deleted and recreated within the same second is a NEW folder.
            _ = try database.createQuickTask(folderId: nil, title: "First", inboxTitle: "Inbox")
            let firstInbox = try incarnation(of: TodoStorage.inboxFolderId, in: database)
            try database.removeFolder(id: TodoStorage.inboxFolderId)
            _ = try database.createQuickTask(folderId: nil, title: "Second", inboxTitle: "Inbox")
            let secondInbox = try incarnation(of: TodoStorage.inboxFolderId, in: database)
            try check(firstInbox != secondInbox, "Recreated inbox reused the deleted folder's incarnation")

            database.addFolder(title: "Legacy add")
            let legacy = try database.cloudImportSnapshot().folders.first(where: { $0.title == "Legacy add" })
            let all = try database.cloudImportSnapshot().folders.map { $0.incarnation }
            try check(legacy != nil && Set(all).count == all.count, "Legacy addFolder did not mint a distinct incarnation")
        }
    }

    private static func importMappingReuse() throws {
        try withDatabase { database, path, _ in
            let task = try database.createQuickTask(folderId: nil, title: "Import me", inboxTitle: "Inbox")
            let snapshotA = try database.cloudImportSnapshot()
            var minted = 0
            let mint: () -> (cloudId: String, mutationId: String) = {
                minted += 1
                return (cloudId: "cloud-\(minted)", mutationId: "mutation-\(minted)")
            }
            let first = try database.cloudImportMappings(for: snapshotA, accountPeerId: 101, principalScope: "scope-a", mint: mint)
            try check(first.count == 2 && first.contains(where: { $0.kind == .task && $0.legacyId == task.id }), "Mapping did not cover folder and task")
            let again = try database.cloudImportMappings(for: try database.cloudImportSnapshot(), accountPeerId: 101, principalScope: "scope-a", mint: mint)
            try check(again == first, "Restart/re-import minted a second identity for the same rows")
            let stored = try database.existingCloudImportMappings(accountPeerId: 101, principalScope: "scope-a")
            try check(stored == first.sorted { ($0.kind.rawValue, $0.legacyId) < ($1.kind.rawValue, $1.legacyId) }, "Read-only lookup differs from minted mapping")
            let otherAccount = try database.cloudImportMappings(for: snapshotA, accountPeerId: 202, principalScope: "scope-a", mint: mint)
            try check(Set(otherAccount.map { $0.cloudId }).isDisjoint(with: Set(first.map { $0.cloudId })), "A second account claimed the first account's cloud identity")
            try expectFailure { try executeSQL(at: path, "UPDATE cloud_import_map SET cloud_id = 'tampered';") }
            let unchanged = try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_map WHERE cloud_id = 'tampered';")
            try check(unchanged == 0, "Import mapping row was mutable")

            // Recreating the inbox is a new incarnation: it maps to a new cloud list, never the old one.
            try database.removeFolder(id: TodoStorage.inboxFolderId)
            _ = try database.createQuickTask(folderId: nil, title: "After recreate", inboxTitle: "Inbox")
            let recreated = try database.cloudImportMappings(for: try database.cloudImportSnapshot(), accountPeerId: 101, principalScope: "scope-a", mint: mint)
            let oldFolder = first.first(where: { $0.kind == .folder })!
            let newFolder = recreated.first(where: { $0.kind == .folder })!
            try check(newFolder.cloudId != oldFolder.cloudId && newFolder.legacyId == oldFolder.legacyId, "Recreated inbox reused the old cloud list")
            try check(database.loadTasks().map { $0.title } == ["After recreate"], "Import mapping changed local originals")

            // Another canonical server account on the SAME native account never reuses these ids.
            let otherScope = try database.cloudImportMappings(for: try database.cloudImportSnapshot(), accountPeerId: 101, principalScope: "scope-b", mint: mint)
            let scopeAIds = Set(try database.existingCloudImportMappings(accountPeerId: 101, principalScope: "scope-a").map { $0.createMutationId })
            try check(scopeAIds.isDisjoint(with: Set(otherScope.map { $0.createMutationId })), "A new server account replayed the old account's mutation ids")

            // Provenance: attempted before send, acknowledged on receipt, never reverted; unknown ids ignored.
            let taskMapping = recreated.first(where: { $0.kind == .task })!
            try database.recordCloudImportAttempt(createMutationId: taskMapping.createMutationId, acknowledged: false)
            var provenance = try database.existingCloudImportMappings(accountPeerId: 101, principalScope: "scope-a").first { $0.createMutationId == taskMapping.createMutationId }!
            try check(provenance.wasAttempted && !provenance.isAcknowledged, "Attempt not recorded")
            try database.recordCloudImportAttempt(createMutationId: taskMapping.createMutationId, acknowledged: true)
            try database.recordCloudImportAttempt(createMutationId: taskMapping.createMutationId, acknowledged: false)
            provenance = try database.existingCloudImportMappings(accountPeerId: 101, principalScope: "scope-a").first { $0.createMutationId == taskMapping.createMutationId }!
            try check(provenance.wasAttempted && provenance.isAcknowledged, "Acknowledgement was reverted")
            try database.recordCloudImportAttempt(createMutationId: "not-an-import", acknowledged: true)
            let foreign = try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_attempt WHERE create_mutation_id = 'not-an-import';")
            try check(foreign == 0, "Non-import create recorded as import provenance")
        }
    }

    private static func importMappingWipe() throws {
        try withDatabase { database, path, _ in
            _ = try database.createQuickTask(folderId: nil, title: "Wipe me", inboxTitle: "Inbox")
            let stale = try database.cloudImportSnapshot()
            _ = try database.cloudImportMappings(for: stale, accountPeerId: 7, principalScope: "scope-a") { (cloudId: UUID().uuidString, mutationId: UUID().uuidString) }
            database.removeAllData()
            try expectFailure(.invalidSnapshot) {
                _ = try database.cloudImportMappings(for: stale, accountPeerId: 7, principalScope: "scope-a") { (cloudId: UUID().uuidString, mutationId: UUID().uuidString) }
            }
            let mappings = try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_map;")
            let attempts = try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_attempt;")
            let folders = try scalarSQL(at: path, "SELECT COUNT(*) FROM folders;")
            try check(mappings == 0 && attempts == 0 && folders == 0, "Final wipe left import mapping, provenance or folder incarnations")
        }
    }

    // MARK: R4 — owner marker, migration record, write fence (v5)

    private static let mint: () -> (cloudId: String, mutationId: String) = { (cloudId: UUID().uuidString, mutationId: UUID().uuidString) }

    /// A v4 database as the previous build left it: a mapped, acknowledged inbox task. Returns the
    /// task's create id.
    private static func makeV4Database(at path: String, defaults: UserDefaults) throws -> String {
        let createId: String = try autoreleasepool {
            let database = TodoDatabase(dbPath: path, defaults: defaults)
            try database.checkAvailability()
            _ = try database.createQuickTask(folderId: nil, title: "Kept", inboxTitle: "Inbox")
            let mappings = try database.cloudImportMappings(for: try database.cloudImportSnapshot(), accountPeerId: 7, principalScope: "scope-a", mint: Self.mint)
            let task = mappings.first(where: { $0.kind == .task })!
            try database.recordCloudImportAttempt(createMutationId: task.createMutationId, acknowledged: true)
            return task.createMutationId
        }
        try executeSQL(at: path, """
        DROP TABLE cloud_device_owner; DROP TABLE cloud_migration;
        ALTER TABLE cloud_import_attempt DROP COLUMN verified_generation;
        PRAGMA user_version = 4;
        """)
        let version = try scalarSQL(at: path, "PRAGMA user_version;")
        let column = try scalarSQL(at: path, "SELECT COUNT(*) FROM pragma_table_info('cloud_import_attempt') WHERE name = 'verified_generation';")
        try check(version == 4 && column == 0, "The v4 fixture is not a v4 database")
        return createId
    }

    private static func v5Shape(at path: String) throws -> (version: Int64, tables: Int64, column: Int64) {
        let version = try scalarSQL(at: path, "PRAGMA user_version;")
        let tables = try scalarSQL(at: path, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('cloud_device_owner', 'cloud_migration');")
        let column = try scalarSQL(at: path, "SELECT COUNT(*) FROM pragma_table_info('cloud_import_attempt') WHERE name = 'verified_generation' AND \"notnull\" = 1 AND dflt_value = '0';")
        return (version, tables, column)
    }

    private static func migrateV4ToV5() throws {
        try withDatabasePath { path, defaults in
            let createId = try makeV4Database(at: path, defaults: defaults)
            let database = TodoDatabase(dbPath: path, defaults: defaults)
            try database.checkAvailability()
            let shape = try v5Shape(at: path)
            try check(shape.version == 5 && shape.tables == 2 && shape.column == 1, "v5 did not add the owner, migration and verified_generation: \(shape)")
            let mapping = try database.existingCloudImportMappings(accountPeerId: 7, principalScope: "scope-a").first { $0.createMutationId == createId }
            try check(mapping?.isAcknowledged == true && mapping?.verifiedGeneration == 0, "The upgrade changed an existing attempt")
            try check(database.loadTasks().map { $0.title } == ["Kept"], "The upgrade changed the local rows")
            try check(try database.cloudDeviceOwner() == nil && database.cloudMigrationRecord(accountPeerId: 7) == nil, "The upgrade invented a claim")
            // Reopening a v5 database changes nothing; an upgrade interrupted after the column was
            // added (a v4 file that already has it) still completes.
            let reopened = TodoDatabase(dbPath: path, defaults: defaults)
            try reopened.checkAvailability()
            try check(try v5Shape(at: path) == shape, "Reopening changed the v5 schema")
            try executeSQL(at: path, "DROP TABLE cloud_device_owner; DROP TABLE cloud_migration; PRAGMA user_version = 4;")
            let resumed = TodoDatabase(dbPath: path, defaults: defaults)
            try resumed.checkAvailability()
            try check(try v5Shape(at: path) == shape, "An upgrade over an existing column failed")
        }
    }

    private static func migrationV5Rollback() throws {
        try withDatabasePath { path, defaults in
            _ = try makeV4Database(at: path, defaults: defaults)
            // The second v5 table cannot be created: the whole step must roll back.
            try executeSQL(at: path, "CREATE INDEX cloud_migration ON folders(title);")
            let failed = TodoDatabase(dbPath: path, defaults: defaults)
            try expectFailure(.sqlite(SQLITE_ERROR)) { try failed.checkAvailability() }
            let version = try scalarSQL(at: path, "PRAGMA user_version;")
            let owner = try scalarSQL(at: path, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'cloud_device_owner';")
            let column = try scalarSQL(at: path, "SELECT COUNT(*) FROM pragma_table_info('cloud_import_attempt') WHERE name = 'verified_generation';")
            try check(version == 4 && owner == 0 && column == 0, "A failed v5 step left part of its schema")
            try executeSQL(at: path, "DROP INDEX cloud_migration;")
            let recovered = TodoDatabase(dbPath: path, defaults: defaults)
            try recovered.checkAvailability()
            let shape = try v5Shape(at: path)
            try check(shape.version == 5 && shape.tables == 2 && shape.column == 1, "The repaired database did not upgrade")
        }
    }

    private static func deviceOwnerClaims() throws {
        try withDatabase { database, _, _ in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try check(try database.cloudDeviceOwner() == nil, "A fresh database has an owner")
            try check(try database.claimCloudDevice(accountPeerId: 7, now: now) == .claimed, "A free marker was not claimed")
            try check(try database.claimCloudDevice(accountPeerId: 7) == .alreadyOwner, "The owner's second claim")
            try check(try database.claimCloudDevice(accountPeerId: 8) == .ownedByOther, "Another account took the marker")
            try check(try database.claimCloudDevice(accountPeerId: 8, asCompleted: true) == .ownedByOther, "Another account completed the marker")
            var owner = try database.cloudDeviceOwner()
            try check(owner?.accountPeerId == 7 && owner?.state == .claimed && owner?.claimedAt == 1_800_000_000 && owner?.completedAt == nil, "Unexpected claimed marker: \(String(describing: owner))")
            // Completing: only the owner's claimed marker.
            try database.completeCloudDevice(accountPeerId: 8)
            try check(try database.cloudDeviceOwner()?.state == .claimed, "Another account completed the owner's marker")
            try database.completeCloudDevice(accountPeerId: 7, now: now.addingTimeInterval(60))
            owner = try database.cloudDeviceOwner()
            try check(owner?.state == .completed && owner?.completedAt == 1_800_000_060, "The owner's marker was not completed")
            try check(try database.claimCloudDevice(accountPeerId: 7) == .alreadyOwner, "A completed marker was claimed again")
        }
        try withDatabase { database, _, _ in
            // The free-marker rule of an account with existing mappings: directly `completed`.
            try check(try database.claimCloudDevice(accountPeerId: 9, asCompleted: true, now: Date(timeIntervalSince1970: 1_800_000_000)) == .claimed, "An asCompleted claim of a free marker failed")
            let owner = try database.cloudDeviceOwner()
            try check(owner?.state == .completed && owner?.completedAt == 1_800_000_000, "asCompleted did not write a completed marker")
        }
    }

    private static func releasedReclaim() throws {
        try withDatabase { database, _, _ in
            try database.claimCloudDevice(accountPeerId: 7)
            try database.setCloudMigrationRecord(TodoCloudMigrationRecord(accountPeerId: 7, state: .enqueued, principalScope: "scope-a", normalizationLocale: .uz, claimedAt: 1, enqueuedAt: 2))
            try check(try database.releaseCloudDevice(accountPeerId: 7, reason: .withdrawn), "The owner's release was not reported")
            let released = try database.cloudDeviceOwner()
            try check(released?.state == .released && released?.releaseReason == "withdrawn" && released?.accountPeerId == 7, "An enqueued owner was not released: \(String(describing: released))")
            try check(try database.claimCloudDevice(accountPeerId: 8) == .releasedByOther, "Another account took a released marker")
            try check(try database.claimCloudDevice(accountPeerId: 7) == .claimed, "The owner could not claim its released marker again")
            let reclaimed = try database.cloudDeviceOwner()
            try check(reclaimed?.state == .claimed && reclaimed?.releasedAt == nil && reclaimed?.releaseReason == nil, "The re-claim kept the release")
        }
    }

    private static func releaseVoidsMappings() throws {
        for reason in [TodoCloudRelease.withdrawn, .erased] {
            try withDatabase { database, path, _ in
                _ = try database.createQuickTask(folderId: nil, title: "Mine", inboxTitle: "Inbox")
                let snapshot = try database.cloudImportSnapshot()
                let own = try database.cloudImportMappings(for: snapshot, accountPeerId: 7, principalScope: "scope-a", mint: Self.mint)
                _ = try database.cloudImportMappings(for: snapshot, accountPeerId: 7, principalScope: "scope-old", mint: Self.mint)
                _ = try database.cloudImportMappings(for: snapshot, accountPeerId: 8, principalScope: "scope-b", mint: Self.mint)
                for mapping in own {
                    try database.recordCloudImportAttempt(createMutationId: mapping.createMutationId, acknowledged: true)
                }
                // Claimed, never enqueued: the marker becomes free again.
                try database.claimCloudDevice(accountPeerId: 7)
                try database.setCloudMigrationRecord(TodoCloudMigrationRecord(accountPeerId: 7, state: .claimed, normalizationLocale: .en, claimedAt: 1))
                try check(try database.releaseCloudDevice(accountPeerId: 7, reason: reason), "\(reason): the owner was not reported")
                let ownRows = try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_map WHERE account_peer_id = 7;")
                let attempts = try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_attempt;")
                let others = try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_map WHERE account_peer_id = 8;")
                try check(ownRows == 0 && attempts == 0 && others == 2, "\(reason): mappings/attempts not voided (own \(ownRows), attempts \(attempts), others \(others))")
                try check(try database.cloudDeviceOwner() == nil, "\(reason): a never-enqueued owner was not freed")
                let record = try database.cloudMigrationRecord(accountPeerId: 7)
                switch reason {
                case .withdrawn:
                    try check(record?.state == .released && record?.reason == .withdrawn && record?.principalScope == nil, "withdrawn: record \(String(describing: record))")
                case .erased:
                    try check(record == nil, "erased: the record survived")
                case .scopeChanged:
                    break
                }
                try check(database.loadTasks().map { $0.title } == ["Mine"], "\(reason): the local rows changed")
                // Not the owner: mappings still go, the marker of the other account stays.
                try database.claimCloudDevice(accountPeerId: 8)
                try check(try !database.releaseCloudDevice(accountPeerId: 9, reason: reason), "\(reason): a non-owner was reported as owner")
                try check(try database.cloudDeviceOwner()?.accountPeerId == 8, "\(reason): another account's marker changed")
            }
        }
    }

    private static func releaseScopeChanged() throws {
        try withDatabase { database, path, _ in
            _ = try database.createQuickTask(folderId: nil, title: "Mine", inboxTitle: "Inbox")
            _ = try database.cloudImportMappings(for: try database.cloudImportSnapshot(), accountPeerId: 7, principalScope: "scope-a", mint: Self.mint)
            try database.claimCloudDevice(accountPeerId: 7)
            let record = TodoCloudMigrationRecord(accountPeerId: 7, state: .completed, principalScope: "scope-a", normalizationLocale: .ru, claimedAt: 1, enqueuedAt: 2, completedAt: 3, lists: 1, tasks: 1)
            try database.setCloudMigrationRecord(record)
            try check(try database.releaseCloudDevice(accountPeerId: 7, reason: .scopeChanged), "The owner was not reported")
            try check(try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_map WHERE account_peer_id = 7;") == 2, "scope_changed voided the mappings")
            let owner = try database.cloudDeviceOwner()
            try check(owner?.state == .released && owner?.releaseReason == "scope_changed", "The marker was not released: \(String(describing: owner))")
            let skipped = try database.cloudMigrationRecord(accountPeerId: 7)
            try check(skipped?.state == .skipped && skipped?.reason == .scopeChanged && skipped?.lists == 1, "The record was not skipped(scope_changed): \(String(describing: skipped))")
            // A scope change never frees the marker, even when nothing was enqueued.
            try database.setCloudMigrationRecord(TodoCloudMigrationRecord(accountPeerId: 7, state: .claimed, principalScope: "scope-a", normalizationLocale: .ru, claimedAt: 1))
            try database.claimCloudDevice(accountPeerId: 7)
            try database.releaseCloudDevice(accountPeerId: 7, reason: .scopeChanged)
            try check(try database.cloudDeviceOwner()?.state == .released, "A never-enqueued scope change freed the marker")
        }
    }

    private static func migrationRecordCrud() throws {
        try withDatabase { database, path, _ in
            let record = TodoCloudMigrationRecord(accountPeerId: 7, state: .claimed, principalScope: nil, normalizationLocale: .uz, claimedAt: 10)
            try check(try database.setCloudMigrationRecord(record), "An unconditional write failed")
            try check(try database.cloudMigrationRecord(accountPeerId: 7) == record && database.cloudMigrationRecord(accountPeerId: 8) == nil, "The record did not round-trip")
            var enqueued = record
            enqueued.state = .enqueued
            enqueued.principalScope = "scope-a"
            enqueued.enqueuedAt = 20
            enqueued.lists = 3
            enqueued.tasks = 12
            enqueued.keptLocal = 1
            enqueued.verifiedGeneration = 4
            try check(try database.setCloudMigrationRecord(enqueued, replacing: record), "A current compare-and-set failed")
            try check(try database.cloudMigrationRecord(accountPeerId: 7) == enqueued, "Every field did not round-trip")
            // A stale expectation (the record moved on meanwhile) writes nothing.
            var stale = record
            stale.state = .completed
            try check(try !database.setCloudMigrationRecord(stale, replacing: record), "A stale compare-and-set wrote")
            try check(try database.cloudMigrationRecord(accountPeerId: 7) == enqueued, "A stale compare-and-set changed the record")
            // The CHECK constraints hold the closed sets.
            try expectFailure { try executeSQL(at: path, "UPDATE cloud_migration SET state = 'lost' WHERE account_peer_id = 7;") }
            try expectFailure { try executeSQL(at: path, "UPDATE cloud_migration SET normalization_locale = 'de' WHERE account_peer_id = 7;") }
            try expectFailure { try executeSQL(at: path, "INSERT INTO cloud_device_owner (singleton, account_peer_id, state, claimed_at) VALUES (2, 1, 'claimed', 0);") }
            try database.deleteCloudMigrationRecord(accountPeerId: 7)
            try check(try database.cloudMigrationRecord(accountPeerId: 7) == nil, "The record was not deleted")
        }
    }

    private static func mappingQueries() throws {
        try withDatabase { database, path, _ in
            try check(try !database.hasCloudImportMapping(accountPeerId: 7), "A fresh database has a mapping")
            let inboxTask = try database.createQuickTask(folderId: nil, title: "Inbox task", inboxTitle: "Inbox")
            let work = try database.createFolder(title: "Work")
            _ = try database.createQuickTask(folderId: work.id, title: "Work task", inboxTitle: "Unused")
            // Live rows of scope A: the Work folder and both tasks (the stable inbox is not counted).
            try check(try database.unmappedLiveRowCount(accountPeerId: 7, principalScope: "scope-a") == 3, "Unmapped rows of an unmapped device")
            // A principal-only (v1) mapping row of another scope still counts as a mapping.
            try executeSQL(at: path, "INSERT INTO cloud_import_map VALUES (7, 'v1-principal-only', 'task', '\(inboxTask.id)', 'x', 'c-1', 'm-1');")
            try check(try database.hasCloudImportMapping(accountPeerId: 7) && !database.hasCloudImportMapping(accountPeerId: 8), "A v1 mapping was not seen, or seen for another account")
            try check(try database.unmappedLiveRowCount(accountPeerId: 7, principalScope: "scope-a") == 3, "Another scope's mapping counted")
            // Map the Work folder and the inbox task in scope A (as the R4 copy does: no inbox list).
            let snapshot = try database.cloudImportSnapshot()
            let partial = TodoCloudImportSnapshot(folders: snapshot.folders.filter { $0.id == work.id }, tasks: snapshot.tasks.filter { $0.task.id == inboxTask.id }, storageId: snapshot.storageId, wipeGeneration: snapshot.wipeGeneration)
            _ = try database.cloudImportMappings(for: partial, accountPeerId: 7, principalScope: "scope-a", mint: Self.mint)
            try check(try database.unmappedLiveRowCount(accountPeerId: 7, principalScope: "scope-a") == 1, "Mapped rows still counted")
            try check(try database.unmappedLiveRowCount(accountPeerId: 8, principalScope: "scope-a") == 3, "Another account's mappings counted")
            try database.deleteCloudImportMappings(accountPeerId: 7)
            try check(try !database.hasCloudImportMapping(accountPeerId: 7), "deleteCloudImportMappings kept a scope")
        }
    }

    private static func importReverified() throws {
        try withDatabase { database, path, _ in
            _ = try database.createQuickTask(folderId: nil, title: "Copied", inboxTitle: "Inbox")
            let mappings = try database.cloudImportMappings(for: try database.cloudImportSnapshot(), accountPeerId: 7, principalScope: "scope-a", mint: Self.mint)
            let task = mappings.first { $0.kind == .task }!
            try database.recordCloudImportAttempt(createMutationId: task.createMutationId, acknowledged: true)
            try database.markImportReverified(mutationIds: [task.createMutationId, "not-an-import"], generation: 2)
            var row = try database.existingCloudImportMappings(accountPeerId: 7, principalScope: "scope-a").first { $0.createMutationId == task.createMutationId }!
            try check(row.wasAttempted && !row.isAcknowledged && row.verifiedGeneration == 2, "Not reopened for one resend: \(row)")
            try check(row.cloudId == task.cloudId, "The re-verify changed the reserved identity")
            // Its next acknowledgement counts at that generation.
            try database.recordCloudImportAttempt(createMutationId: task.createMutationId, acknowledged: true)
            row = try database.existingCloudImportMappings(accountPeerId: 7, principalScope: "scope-a").first { $0.createMutationId == task.createMutationId }!
            try check(row.isAcknowledged && row.verifiedGeneration == 2, "The acknowledgement after the resend lost the generation")
            try check(try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_import_attempt;") == 1, "A non-import id was recorded")
            try database.markImportReverified(mutationIds: [], generation: 3)
        }
    }

    private static func wipeClearsMigrationState() throws {
        try withDatabase { database, path, _ in
            _ = try database.createQuickTask(folderId: nil, title: "Wipe", inboxTitle: "Inbox")
            try database.claimCloudDevice(accountPeerId: 7)
            try database.setCloudMigrationRecord(TodoCloudMigrationRecord(accountPeerId: 7, state: .claimed, normalizationLocale: .en, claimedAt: 1))
            try database.setCloudMigrationRecord(TodoCloudMigrationRecord(accountPeerId: 8, state: .skipped, reason: .deviceOwnedByOther, normalizationLocale: .en, claimedAt: 1))
            database.removeAllData()
            try check(try database.cloudDeviceOwner() == nil, "The wipe kept the owner marker")
            try check(try scalarSQL(at: path, "SELECT COUNT(*) FROM cloud_migration;") == 0, "The wipe kept a migration record")
        }
    }

    /// Installs `fence` for the body; `.open` again afterwards whatever happens.
    private static func withFence(_ fence: @escaping (Int64) -> TodoWriteFence, _ body: () throws -> Void) rethrows {
        TodoStorage.writeFence = fence
        defer { TodoStorage.writeFence = { _ in .open } }
        try body()
    }

    private static func writeFenceRefusesCheckedWrites() throws {
        try withDatabase { database, _, _ in
            let folder = try database.createFolder(title: "Work")
            let task = try database.createQuickTask(folderId: folder.id, title: "Task", inboxTitle: "Inbox")
            let deleted = try database.deleteTaskForUndo(id: task.id)!
            try database.restoreDeletedTask(deleted)
            let before = (database.loadFolders(), database.loadTasks())
            for (fence, error) in [(TodoWriteFence.archived, TodoDatabaseError.archived), (.migrating, .migrating)] {
                try withFence({ $0 == 7 ? fence : .open }) {
                    try expectFailure(error) { _ = try database.createQuickTask(folderId: nil, title: "No", inboxTitle: "Inbox", asAccount: 7) }
                    try expectFailure(error) { _ = try database.createFolder(title: "No", asAccount: 7) }
                    try expectFailure(error) { try database.renameTask(id: task.id, title: "No", asAccount: 7) }
                    try expectFailure(error) { try database.updateTaskDetails(id: task.id, title: "No", assignee: nil, dueAt: nil, asAccount: 7) }
                    try expectFailure(error) { try database.setTaskCompleted(id: task.id, isCompleted: true, asAccount: 7) }
                    try expectFailure(error) { _ = try database.deleteTaskForUndo(id: task.id, asAccount: 7) }
                    try expectFailure(error) { try database.restoreDeletedTask(deleted, asAccount: 7) }
                    try expectFailure(error) { try database.updateFolderTitle(id: folder.id, title: "No", asAccount: 7) }
                    try expectFailure(error) { try database.removeFolder(id: folder.id, asAccount: 7) }
                    try check(database.loadFolders() == before.0 && database.loadTasks() == before.1, "\(fence): a refused write changed the rows")
                    // Another account, an account-less write and the caller-less legacy writes go on.
                    try database.renameTask(id: task.id, title: "Renamed by 8", asAccount: 8)
                    try database.renameTask(id: task.id, title: "Renamed without account")
                    database.toggleTask(id: task.id)
                    database.toggleTask(id: task.id)
                    database.updateTask(id: task.id, title: "Task", description: nil, dueAt: nil, priority: 0)
                    try check(database.loadTasks().first?.title == "Task", "\(fence): an unfenced write was refused")
                }
            }
            // `.open` again: the account writes.
            try database.renameTask(id: task.id, title: "Open", asAccount: 7)
            try check(database.loadTasks().first?.title == "Open", "An open fence refused a write")
            try database.updateFolderTitle(id: folder.id, title: "Work 2", asAccount: 7)
            try expectFailure(.folderNotFound) { try database.updateFolderTitle(id: "missing", title: "X", asAccount: 7) }
            try database.removeFolder(id: "missing", asAccount: 7)
            try database.removeFolder(id: folder.id, asAccount: 7)
            try check(database.loadFolders().isEmpty && database.loadTasks().isEmpty, "A checked folder removal did not cascade")
        }
    }

    private static func liveTasksWithAssignee() throws {
        try withDatabase { database, path, _ in
            let work = try database.createFolder(title: "Work")
            let ali = TodoAssignee(peerId: 987_654_321, displayName: "Ali")
            let later = try database.createQuickTask(folderId: work.id, title: "Later", inboxTitle: "Inbox", assignee: ali)
            let early = try database.createQuickTask(folderId: nil, title: "Early", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 5, displayName: "Vali"))
            let plain = try database.createQuickTask(folderId: work.id, title: "Plain", inboxTitle: "Inbox")
            let done = try database.createQuickTask(folderId: work.id, title: "Done", inboxTitle: "Inbox", assignee: ali)
            try database.setTaskCompleted(id: done.id, isCompleted: true)
            try check(database.liveTasksWithAssignee().count == 3, "a row without an assignee was listed, or one with was not")
            // The order is the sheet's (§7.2 item 4): created_at, then id.
            try executeSQL(at: path, "UPDATE tasks SET created_at = 100 WHERE id = '\(early.id)'; UPDATE tasks SET created_at = 200 WHERE id IN ('\(later.id)', '\(done.id)');")
            let rows = database.liveTasksWithAssignee()
            let expectedTail = [later.id, done.id].sorted()
            try check(rows.map { $0.task.id } == [early.id] + expectedTail, "the order is not created_at, then id: \(rows.map { $0.task.title })")
            try check(rows.allSatisfy { $0.task.assignee != nil } && rows.first { $0.task.id == done.id }?.task.isCompleted == true, "the rows lost their assignee or completion")
            // The parent folder's incarnation is the mapping key the offer joins on.
            let snapshot = try database.cloudImportSnapshot()
            let workIncarnation = snapshot.folders.first { $0.id == work.id }?.incarnation
            let inboxIncarnation = snapshot.folders.first { $0.id == early.folderId }?.incarnation
            try check(workIncarnation != nil && rows.first { $0.task.id == later.id }?.folderIncarnation == workIncarnation, "the Work incarnation is not the row's")
            try check(inboxIncarnation != nil && rows.first { $0.task.id == early.id }?.folderIncarnation == inboxIncarnation, "the inbox incarnation is not the row's")
            try check(!rows.contains { $0.task.id == plain.id }, "the plain row is listed")
            // A row whose display name is NULL carries no assignee for the board; it is not listed.
            try executeSQL(at: path, "UPDATE tasks SET assignee_display_name = NULL WHERE id = '\(early.id)';")
            try check(database.liveTasksWithAssignee().map { $0.task.id } == expectedTail, "a half-written assignee was listed")
            // The read never writes.
            try check(database.loadTasks().count == 4, "the read changed the rows")
        }
    }

    private static func writeFenceFacades() throws {
        // Every refusal happens in the facade, before the shared (Documents) database is touched;
        // this case never calls a facade with an open fence.
        let snapshot: TodoDeletedTaskSnapshot = try {
            var result: TodoDeletedTaskSnapshot?
            try withDatabase { database, _, _ in
                let task = try database.createQuickTask(folderId: nil, title: "Undo me", inboxTitle: "Inbox")
                result = try database.deleteTaskForUndo(id: task.id)
            }
            return result!
        }()
        for (fence, error) in [(TodoWriteFence.archived, TodoDatabaseError.archived), (.migrating, .migrating)] {
            try withFence({ _ in fence }) {
                try expectFailure(error) { _ = try TodoStorage.createQuickTask(folderId: nil, title: "No", inboxTitle: "Inbox", asAccount: 7) }
                try expectFailure(error) { _ = try TodoStorage.createFolder(title: "No", asAccount: 7) }
                try expectFailure(error) { try TodoStorage.renameTask(id: "t", title: "No", asAccount: 7) }
                try expectFailure(error) { try TodoStorage.updateTaskDetails(id: "t", title: "No", assignee: nil, dueAt: nil, asAccount: 7) }
                try expectFailure(error) { try TodoStorage.setTaskCompleted(id: "t", isCompleted: true, asAccount: 7) }
                try expectFailure(error) { _ = try TodoStorage.deleteTaskForUndo(id: "t", asAccount: 7) }
                try expectFailure(error) { try TodoStorage.restoreDeletedTask(snapshot, asAccount: 7) }
                try expectFailure(error) { try TodoStorage.renameFolder(id: "f", title: "No", asAccount: 7) }
                try expectFailure(error) { try TodoStorage.removeFolder(id: "f", asAccount: 7) }
            }
        }
        // The installed source is read per call, and the default is open.
        try check(TodoStorage.writeFence(7) == .open, "The fence was not reset to open")
        try TodoStorage.checkWriteFence(nil)
        try withFence({ _ in .archived }) {
            try TodoStorage.checkWriteFence(nil)
            try expectFailure(.archived) { try TodoStorage.checkWriteFence(7) }
        }
    }
}
