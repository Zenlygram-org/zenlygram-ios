import Foundation
import sqlcipher
import SGEntitlement

// MARK: - Per-account cloud store
//
// One SQLite file per native account (`<accountPeerId>.sqlite`, packed PeerId.toInt64()):
//   meta(key, value)                  sync cursor, snapshot completeness, pause, counters
//   shadow(kind, id, body)            server projections only (strict wire bytes), never optimistic
//   staging(kind, id, body)           snapshot pages + post-watermark delta before reconcile
//   outbox(seq, mutation_id, …)       durable business operations (exact `mutation` bytes, never
//                                     credentials, JWS, nonce or creation proof); the optimistic
//                                     overlay is derived from its unresolved rows
//   chain_revision(resource_key, rev) resource revisions learned from receipts for dependent sealing
//   notices(id, kind, created_at)     content-free user notices
// Every local mutation + enqueue runs in ONE transaction. The store is not thread-safe: the owning
// repository serializes every call on its queue.
//
// v3 (R4) adds outbox columns — origin (user|migration), auto_requeues, auto_resolutions,
// auto_resolve (pending|NULL), conflict_fields, base_snapshot (a list.update's three-way base) —
// and `notices.fields`; no CHECK on added columns, the code validates them. R4 meta keys:
// server_wire, batch_unavailable_until, batch_byte_budget, batch_success_streak, batch_503_streak,
// migration_paused_until, consent_withdrawn, consent_epoch, consent_fenced_until,
// consent_fence_delay, consent_fenced_effective_at, pause_binding, resync_generation,
// migration_checked (the migration step has checked this store; it dies with the file and with a
// rebind), batch_refusals_repaired (once per store, in the repository's opening transaction, every
// entry an older build left `invalid` goes back to the queue, because a whole multi-item batch was
// marked invalid on a 422 and the outbox keeps no error code; a new store is marked at its first
// repository open; `repairBatchRefusals`). The whole-batch split (`.invalidRequest`: a 422 or 415
// `tasks_invalid_request`) is in memory (`batchSplitIds`), never stored.
//
// wf15 meta keys (no schema change, still v3): the pacer's content-free counters `invite_day.<yyyymmdd>`,
// `invite_day.<yyyymmdd>.<recipientTgId>` and `invite_minute.<epochMinute>` (§12.1, deleted after two
// UTC days); `assign_deferred.<taskId>` = `{"after":<unix>,"to":"<recipientTgId>"}`, an assignment the
// server rate-limited for longer than two minutes, waiting outside the outbox for its automatic re-send
// (§12.2; `unsentCounts` counts it as a user change); `assign_resend.<taskId>` = the mutation id of that
// re-send while it is in the outbox; `auto_accept.<invitationId>` = `<mutationId>:<attempts>`, the
// automatic accept of a contact's invitation (§5.3, D2: the entry's mutation id and the attempts made,
// at most 3). All of them die with the store (logout purge) and with a withdrawal's discard.

private let SGTasksCloudSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SGTasksCloudStoreError: Error, Equatable {
    let code: Int32
}

enum SGTasksCloudSQLValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func optionalText(_ value: String?) -> SGTasksCloudSQLValue {
        return value.map { .text($0) } ?? .null
    }

    static func optionalReal(_ value: Double?) -> SGTasksCloudSQLValue {
        return value.map { .real($0) } ?? .null
    }

    static func optionalInteger(_ value: Int64?) -> SGTasksCloudSQLValue {
        return value.map { .integer($0) } ?? .null
    }
}

struct SGTasksCloudSQLRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        return sqlite3_column_type(self.statement, column) == SQLITE_NULL
    }

    func integer(_ column: Int32) -> Int64 {
        return sqlite3_column_int64(self.statement, column)
    }

    func optionalInteger(_ column: Int32) -> Int64? {
        return self.isNull(column) ? nil : self.integer(column)
    }

    func real(_ column: Int32) -> Double {
        return sqlite3_column_double(self.statement, column)
    }

    func optionalReal(_ column: Int32) -> Double? {
        return self.isNull(column) ? nil : self.real(column)
    }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(self.statement, column) else { return "" }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(self.statement, column)))
        return String(decoding: bytes, as: UTF8.self)
    }

    func optionalText(_ column: Int32) -> String? {
        return self.isNull(column) ? nil : self.text(column)
    }

    func blob(_ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(self.statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(self.statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

/// Minimal checked SQLite connection: every failure throws, nothing is logged with content.
final class SGTasksCloudSQLite {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(path, &connection, flags, nil)
        guard result == SQLITE_OK, let opened = connection else {
            sqlite3_close(connection)
            throw SGTasksCloudStoreError(code: result == SQLITE_OK ? SQLITE_MISUSE : result)
        }
        self.db = opened
        if !readOnly {
            do {
                try self.execute("PRAGMA journal_mode = WAL;", returnsRow: true)
                try self.execute("PRAGMA synchronous = NORMAL;")
                try self.execute("PRAGMA foreign_keys = ON;")
                // Deleted rows (shared cache after access loss, purged drafts) are overwritten inside
                // the file. This is a logical overwrite, not a physical flash erase.
                try self.execute("PRAGMA secure_delete = ON;", returnsRow: true)
            } catch {
                self.close()
                throw error
            }
        }
        try self.execute("PRAGMA busy_timeout = 3000;", returnsRow: true)
    }

    deinit {
        self.close()
    }

    var isOpen: Bool {
        return self.db != nil
    }

    func close() {
        if let db = self.db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    private func check(_ result: Int32, _ expected: Int32 = SQLITE_OK) throws {
        guard result == expected else { throw SGTasksCloudStoreError(code: result) }
    }

    private func prepare(_ sql: String, _ values: [SGTasksCloudSQLValue]) throws -> OpaquePointer {
        guard let db = self.db else { throw SGTasksCloudStoreError(code: SQLITE_MISUSE) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let ready = statement else {
            sqlite3_finalize(statement)
            throw SGTasksCloudStoreError(code: prepared == SQLITE_OK ? SQLITE_MISUSE : prepared)
        }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .null:
                    try self.check(sqlite3_bind_null(ready, index))
                case let .integer(number):
                    try self.check(sqlite3_bind_int64(ready, index, number))
                case let .real(number):
                    try self.check(sqlite3_bind_double(ready, index, number))
                case let .text(text):
                    guard let length = Int32(exactly: text.utf8.count) else { throw SGTasksCloudStoreError(code: SQLITE_TOOBIG) }
                    try self.check(sqlite3_bind_text(ready, index, text, length, SGTasksCloudSQLiteTransient))
                case let .blob(data):
                    guard let length = Int32(exactly: data.count) else { throw SGTasksCloudStoreError(code: SQLITE_TOOBIG) }
                    try data.withUnsafeBytes { buffer in
                        // A zero-length blob still binds as a blob, never as NULL.
                        try self.check(sqlite3_bind_blob(ready, index, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1), length, SGTasksCloudSQLiteTransient))
                    }
                }
            }
        } catch {
            sqlite3_finalize(ready)
            throw error
        }
        return ready
    }

    /// Runs a statement to completion and returns the number of changed rows.
    @discardableResult
    func execute(_ sql: String, _ values: [SGTasksCloudSQLValue] = [], returnsRow: Bool = false) throws -> Int {
        let statement = try self.prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        if returnsRow {
            while result == SQLITE_ROW {
                result = sqlite3_step(statement)
            }
        }
        try self.check(result, SQLITE_DONE)
        return Int(sqlite3_changes(self.db))
    }

    func query<T>(_ sql: String, _ values: [SGTasksCloudSQLValue] = [], _ map: (SGTasksCloudSQLRow) throws -> T) throws -> [T] {
        let statement = try self.prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            try self.check(result, SQLITE_ROW)
            out.append(try map(SGTasksCloudSQLRow(statement: statement)))
        }
        return out
    }

    var lastInsertRowId: Int64 {
        return sqlite3_last_insert_rowid(self.db)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try self.execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try self.execute("COMMIT;")
            return result
        } catch {
            if let db = self.db, sqlite3_get_autocommit(db) == 0 {
                do {
                    try self.execute("ROLLBACK;")
                } catch {
                    // Never allow a later operation to commit a transaction we could not unwind.
                    self.close()
                }
            }
            throw error
        }
    }
}

// MARK: - Outbox rows

enum SGTasksCloudEntryState: String {
    case queued
    case sending
    case held
    case acked
    case blockedCreation = "blocked_creation"
    case invalid
    case quarantined
    case conflict
    case notFound = "not_found"
    case stalled
    /// Decided under a previous canonical server account; never sent under the current one.
    case principalChanged = "principal_changed"
}

struct SGTasksCloudStoredEntry {
    let seq: Int64
    let mutationId: String
    /// As sealed: one of the R3 twelve, or `task.patch` (R4).
    let kind: SGTasksWire.MutationKind
    /// Resource keys ("task:<uuid>", "list:<uuid>", "invitation:<uuid>", "block:<tg>") this
    /// operation reads or writes; overlapping keys order operations into one dependency chain.
    let keys: [String]
    let body: Data
    /// false while base_revision still awaits the predecessor in its chain; never sent unsealed.
    let sealed: Bool
    let sentOnce: Bool
    let state: SGTasksCloudEntryState
    let conflictReason: SGTasksWire.ConflictReason?
    let attempts: Int
    let nextAttemptAt: Date?
    let holdToken: String?
    /// A held delete of a task whose create never left the device: promotion cancels both.
    let cancelsCreate: Bool
    let ackRevision: String?
    let ackMarker: Int64?
    /// The verified inviter of a block, captured from the addressed invitation for the overlay.
    let subject: String?
    /// Issued as an invitation recipient / assignee: a 404 means shared access was lost.
    let isShared: Bool
    let createdAt: Date
    let serverTime: Date?
    /// R4: a `migration` entry is a create of data that existed locally before the account's
    /// cloud; it travels only through the batch route.
    let origin: SGTasksWire.MutationOrigin
    /// Automatic `stalled` / `blocked_creation` → `queued` moves of this entry (§7.4, ≤ 5).
    let autoRequeues: Int
    /// Automatic conflict resolutions of this intent so far (§7.3, ≤ 2); a resolution's new entry
    /// inherits the count + 1.
    let autoResolutions: Int
    /// A conflict waiting for the next complete pull to be resolved automatically.
    let isAutoResolvePending: Bool
    /// `field_changed`: the conflicting fields, in content order.
    let conflictFields: [SGTasksWire.ContentField]
    /// `members_changed` (a members-fenced list.delete); with `conflictReason` `.revisionChanged`.
    let isMembersConflict: Bool
    /// A list.update's base (`SGTasksCloudListBase` bytes): the title and order the user edited.
    let baseSnapshot: Data?

    var isResolved: Bool {
        return self.state == .acked
    }

    /// The R3 class of the kind (a patch is a task.update).
    var operationClass: SGTasksWire.OperationKind {
        switch self.kind {
        case let .operation(kind):
            return kind
        case .taskPatch:
            return .taskUpdate
        }
    }
}

/// The three-way base of a list.update (design 30 §7.3): what the list showed when the user edited
/// it. Local content-only JSON (title + order), never a revision or an id; anything else in the
/// column reads as "no base" (the conflict then stays explicit).
struct SGTasksCloudListBase: Equatable {
    let title: String
    let sortOrder: Int32

    init(title: String, sortOrder: Int32) {
        self.title = title
        self.sortOrder = sortOrder
    }

    init?(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object.count == 2,
              let title = object["title"] as? String, let order = object["sort_order"] as? Int, let sortOrder = Int32(exactly: order) else {
            return nil
        }
        self.title = title
        self.sortOrder = sortOrder
    }

    var encoded: Data? {
        return try? JSONSerialization.data(withJSONObject: ["title": self.title, "sort_order": Int(self.sortOrder)], options: [.sortedKeys])
    }
}

final class SGTasksCloudStore {
    static let schemaVersion: Int64 = 3

    private let connection: SGTasksCloudSQLite

    init(path: String) throws {
        self.connection = try SGTasksCloudSQLite(path: path)
        do {
            try self.migrate()
        } catch {
            self.connection.close()
            throw error
        }
    }

    func close() {
        self.connection.close()
    }

    var isOpen: Bool {
        return self.connection.isOpen
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        return try self.connection.transaction(body)
    }

    private func migrate() throws {
        let version = try self.connection.query("PRAGMA user_version;") { $0.integer(0) }.first ?? 0
        guard version < Self.schemaVersion else { return }
        try self.connection.transaction {
            try self.connection.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;")
            try self.connection.execute("CREATE TABLE IF NOT EXISTS shadow (kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY (kind, id)) WITHOUT ROWID;")
            try self.connection.execute("CREATE TABLE IF NOT EXISTS staging (kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY (kind, id)) WITHOUT ROWID;")
            try self.connection.execute("""
            CREATE TABLE IF NOT EXISTS outbox (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                mutation_id TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                keys TEXT NOT NULL,
                body BLOB NOT NULL,
                sealed INTEGER NOT NULL,
                sent_once INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL,
                conflict_reason TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at REAL,
                hold_token TEXT,
                cancels_create INTEGER NOT NULL DEFAULT 0,
                ack_revision TEXT,
                ack_marker INTEGER,
                subject TEXT,
                is_shared INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                server_time REAL
            );
            """)
            // After the first send the business identity (id + bytes) can never change.
            try self.connection.execute("""
            CREATE TRIGGER IF NOT EXISTS outbox_sent_identity_immutable
            BEFORE UPDATE OF mutation_id, body, kind ON outbox
            WHEN OLD.sent_once = 1 AND (NEW.mutation_id IS NOT OLD.mutation_id OR NEW.body IS NOT OLD.body OR NEW.kind IS NOT OLD.kind)
            BEGIN SELECT RAISE(ABORT, 'sent mutation identity is immutable'); END;
            """)
            try self.connection.execute("CREATE TABLE IF NOT EXISTS chain_revision (resource_key TEXT PRIMARY KEY, revision TEXT NOT NULL) WITHOUT ROWID;")
            try self.connection.execute("CREATE TABLE IF NOT EXISTS notices (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, created_at REAL NOT NULL);")
            // v2: content-free create ids whose "acknowledged" import provenance still has to reach
            // the device-local Tasks database; cloud retirement never waits for that database.
            try self.connection.execute("CREATE TABLE IF NOT EXISTS import_ack_pending (mutation_id TEXT PRIMARY KEY) WITHOUT ROWID;")
            if version < 3 {
                try self.migrateToR4(upgrading: version > 0)
            }
            try self.connection.execute("PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    /// v3 (R4), inside the migration transaction: additive columns only (an R3 build's rows keep
    /// their meaning: origin user, nothing automatic yet). An upgraded store resnapshots once — an
    /// R3-era shadow has no `members_revision`, and a members-fenced delete is sealed from it.
    private func migrateToR4(upgrading: Bool) throws {
        let outbox = Set(try self.connection.query("PRAGMA table_info(outbox);") { $0.text(1) })
        let columns: [(String, String)] = [
            ("origin", "TEXT NOT NULL DEFAULT 'user'"),
            ("auto_requeues", "INTEGER NOT NULL DEFAULT 0"),
            ("auto_resolutions", "INTEGER NOT NULL DEFAULT 0"),
            ("auto_resolve", "TEXT"),
            ("conflict_fields", "TEXT"),
            ("base_snapshot", "BLOB")
        ]
        for (name, definition) in columns where !outbox.contains(name) {
            try self.connection.execute("ALTER TABLE outbox ADD COLUMN \(name) \(definition);")
        }
        let notices = Set(try self.connection.query("PRAGMA table_info(notices);") { $0.text(1) })
        if !notices.contains("fields") {
            try self.connection.execute("ALTER TABLE notices ADD COLUMN fields TEXT;")
        }
        if upgrading {
            try self.setMeta("needs_resnapshot", "1")
        }
    }

    // MARK: Pending import provenance

    func addPendingImportAck(_ mutationId: String) throws {
        try self.connection.execute("INSERT OR IGNORE INTO import_ack_pending (mutation_id) VALUES (?);", [.text(mutationId)])
    }

    func pendingImportAcks() throws -> [String] {
        return try self.connection.query("SELECT mutation_id FROM import_ack_pending ORDER BY mutation_id;") { $0.text(0) }
    }

    func removePendingImportAck(_ mutationId: String) throws {
        try self.connection.execute("DELETE FROM import_ack_pending WHERE mutation_id = ?;", [.text(mutationId)])
    }

    // MARK: Meta

    func meta(_ key: String) throws -> String? {
        return try self.connection.query("SELECT value FROM meta WHERE key = ?;", [.text(key)]) { $0.text(0) }.first
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value = value {
            try self.connection.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", [.text(key), .text(value)])
        } else {
            try self.connection.execute("DELETE FROM meta WHERE key = ?;", [.text(key)])
        }
    }

    /// wf15 §12.2: `assign_deferred.<taskId>` — an assignment waiting outside the outbox for its
    /// automatic re-send (`SGTasksCloudDeferredAssignment`); counted by `unsentCounts`.
    static let deferredAssignmentPrefix = "assign_deferred."
    /// wf15 §12.2: `assign_resend.<taskId>` — the mutation id of that assignment's automatic re-send
    /// while the re-send is in the outbox.
    static let automaticResendPrefix = "assign_resend."
    /// wf15 §5.3 (D2): `auto_accept.<invitationId>` = `"<mutationId>:<attempts>"` — the automatic
    /// accept of a contact's invitation: the mutation id of its `invitation.respond` entry while it is
    /// in the outbox, and how many automatic accepts (the initial one and its reseals) were made for
    /// the invitation; attempts at the cap mean the device gave up on it (it waits in Takliflar).
    static let automaticAcceptPrefix = "auto_accept."

    /// Every meta row whose key starts with `prefix` (the content-free counters and markers), by key.
    func metaEntries(prefix: String) throws -> [(key: String, value: String)] {
        return try self.connection.query("SELECT key, value FROM meta WHERE key GLOB ? ORDER BY key;", [.text(Self.globPattern(prefix: prefix))]) { row in
            (key: row.text(0), value: row.text(1))
        }
    }

    func deleteMeta(prefix: String) throws {
        try self.connection.execute("DELETE FROM meta WHERE key GLOB ?;", [.text(Self.globPattern(prefix: prefix))])
    }

    /// A GLOB pattern for "starts with `prefix`" (`*`, `?` and `[` of the prefix escaped as classes).
    static func globPattern(prefix: String) -> String {
        var pattern = ""
        for scalar in prefix.unicodeScalars {
            switch scalar {
            case "*", "?", "[":
                pattern.append("[\(scalar)]")
            default:
                pattern.unicodeScalars.append(scalar)
            }
        }
        return pattern + "*"
    }

    /// Monotonic counter used to order acknowledgements against completed sync passes.
    func nextAckMarker() throws -> Int64 {
        let current = Int64(try self.meta("ack_counter") ?? "0") ?? 0
        try self.setMeta("ack_counter", String(current + 1))
        return current + 1
    }

    func currentAckMarker() throws -> Int64 {
        return Int64(try self.meta("ack_counter") ?? "0") ?? 0
    }

    // MARK: Shadow and staging

    enum Table: String {
        case shadow
        case staging
    }

    func rows(_ table: Table) throws -> [(kind: String, id: String, body: Data)] {
        return try self.connection.query("SELECT kind, id, body FROM \(table.rawValue) ORDER BY kind, id;") { row in
            (kind: row.text(0), id: row.text(1), body: row.blob(2))
        }
    }

    func row(_ table: Table, kind: String, id: String) throws -> Data? {
        return try self.connection.query("SELECT body FROM \(table.rawValue) WHERE kind = ? AND id = ?;", [.text(kind), .text(id)]) { $0.blob(0) }.first
    }

    func upsert(_ table: Table, kind: String, id: String, body: Data) throws {
        try self.connection.execute("INSERT INTO \(table.rawValue) (kind, id, body) VALUES (?, ?, ?) ON CONFLICT(kind, id) DO UPDATE SET body = excluded.body;", [.text(kind), .text(id), .blob(body)])
    }

    @discardableResult
    func remove(_ table: Table, kind: String, id: String) throws -> Bool {
        return try self.connection.execute("DELETE FROM \(table.rawValue) WHERE kind = ? AND id = ?;", [.text(kind), .text(id)]) > 0
    }

    func clear(_ table: Table) throws {
        try self.connection.execute("DELETE FROM \(table.rawValue);")
    }

    /// Replaces the whole server shadow with the completed staging set (inside a transaction).
    func replaceShadowWithStaging() throws {
        try self.connection.execute("DELETE FROM shadow;")
        try self.connection.execute("INSERT INTO shadow (kind, id, body) SELECT kind, id, body FROM staging;")
        try self.connection.execute("DELETE FROM staging;")
    }

    // MARK: Outbox

    private static let entryColumns = "seq, mutation_id, kind, keys, body, sealed, sent_once, state, conflict_reason, attempts, next_attempt_at, hold_token, cancels_create, ack_revision, ack_marker, subject, is_shared, created_at, server_time, origin, auto_requeues, auto_resolutions, auto_resolve, conflict_fields, base_snapshot"

    static let autoResolvePending = "pending"

    static func encodeFields(_ fields: [SGTasksWire.ContentField]) -> String? {
        return fields.isEmpty ? nil : fields.sorted().map { $0.rawValue }.joined(separator: " ")
    }

    static func decodeFields(_ raw: String?) -> [SGTasksWire.ContentField]? {
        guard let raw = raw else { return [] }
        var fields: [SGTasksWire.ContentField] = []
        for name in raw.split(separator: " ") {
            guard let field = SGTasksWire.ContentField(rawValue: String(name)) else { return nil }
            fields.append(field)
        }
        return fields.sorted()
    }

    private static func decodeEntry(_ row: SGTasksCloudSQLRow) throws -> SGTasksCloudStoredEntry {
        guard let kind = SGTasksWire.MutationKind(rawValue: row.text(2)), let state = SGTasksCloudEntryState(rawValue: row.text(7)),
              let origin = SGTasksWire.MutationOrigin(rawValue: row.text(19)), let fields = Self.decodeFields(row.optionalText(23)) else {
            throw SGTasksCloudStoreError(code: SQLITE_CORRUPT)
        }
        // The exact wire reason is stored; an R4-only one (`field_changed`, `members_changed`) keeps
        // its R3 class, "changed since your base".
        let reason = row.optionalText(8).flatMap(SGTasksWire.ErrorReason.init(rawValue:))
        return SGTasksCloudStoredEntry(
            seq: row.integer(0),
            mutationId: row.text(1),
            kind: kind,
            keys: row.text(3).split(separator: " ").map(String.init),
            body: row.blob(4),
            sealed: row.integer(5) != 0,
            sentOnce: row.integer(6) != 0,
            state: state,
            conflictReason: reason.map { $0.conflictReason ?? .revisionChanged },
            attempts: Int(row.integer(9)),
            nextAttemptAt: row.optionalReal(10).map(Date.init(timeIntervalSince1970:)),
            holdToken: row.optionalText(11),
            cancelsCreate: row.integer(12) != 0,
            ackRevision: row.optionalText(13),
            ackMarker: row.optionalInteger(14),
            subject: row.optionalText(15),
            isShared: row.integer(16) != 0,
            createdAt: Date(timeIntervalSince1970: row.real(17)),
            serverTime: row.optionalReal(18).map(Date.init(timeIntervalSince1970:)),
            origin: origin,
            autoRequeues: Int(row.integer(20)),
            autoResolutions: Int(row.integer(21)),
            isAutoResolvePending: row.optionalText(22) == Self.autoResolvePending,
            conflictFields: fields,
            isMembersConflict: reason == .membersChanged,
            baseSnapshot: row.isNull(24) ? nil : row.blob(24)
        )
    }

    func entries() throws -> [SGTasksCloudStoredEntry] {
        return try self.connection.query("SELECT \(Self.entryColumns) FROM outbox ORDER BY seq;", [], Self.decodeEntry)
    }

    func entry(seq: Int64) throws -> SGTasksCloudStoredEntry? {
        return try self.connection.query("SELECT \(Self.entryColumns) FROM outbox WHERE seq = ?;", [.integer(seq)], Self.decodeEntry).first
    }

    @discardableResult
    func insertEntry(seq: Int64? = nil, mutationId: String, kind: SGTasksWire.MutationKind, keys: [String], body: Data, sealed: Bool, state: SGTasksCloudEntryState, holdToken: String? = nil, cancelsCreate: Bool = false, subject: String? = nil, isShared: Bool = false, createdAt: Date, origin: SGTasksWire.MutationOrigin = .user, autoResolutions: Int = 0, baseSnapshot: Data? = nil, conflict: (reason: SGTasksWire.ErrorReason, fields: [SGTasksWire.ContentField])? = nil) throws -> Int64 {
        try self.connection.execute(
            "INSERT INTO outbox (seq, mutation_id, kind, keys, body, sealed, state, hold_token, cancels_create, subject, is_shared, created_at, origin, auto_resolutions, base_snapshot, conflict_reason, conflict_fields) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            [.optionalInteger(seq), .text(mutationId), .text(kind.rawValue), .text(keys.joined(separator: " ")), .blob(body), .integer(sealed ? 1 : 0), .text(state.rawValue), .optionalText(holdToken), .integer(cancelsCreate ? 1 : 0), .optionalText(subject), .integer(isShared ? 1 : 0), .real(createdAt.timeIntervalSince1970),
             .text(origin.rawValue), .integer(Int64(autoResolutions)), baseSnapshot.map { .blob($0) } ?? .null, .optionalText(conflict?.reason.rawValue), .optionalText(conflict.flatMap { Self.encodeFields($0.fields) })]
        )
        return self.connection.lastInsertRowId
    }

    /// Seals an unsent entry once its base revision is resolved.
    func reseal(seq: Int64, body: Data) throws {
        let changed = try self.connection.execute("UPDATE outbox SET body = ?, sealed = 1 WHERE seq = ? AND sent_once = 0;", [.blob(body), .integer(seq)])
        guard changed == 1 else { throw SGTasksCloudStoreError(code: SQLITE_CONSTRAINT) }
    }

    /// Explicit pre-send correction of a never-sent operation (same mutation id, new bytes/keys).
    func rewriteUnsent(seq: Int64, body: Data, keys: [String]) throws {
        let changed = try self.connection.execute("UPDATE outbox SET body = ?, keys = ?, sealed = 1 WHERE seq = ? AND sent_once = 0;", [.blob(body), .text(keys.joined(separator: " ")), .integer(seq)])
        guard changed == 1 else { throw SGTasksCloudStoreError(code: SQLITE_CONSTRAINT) }
    }

    /// Recorded BEFORE the network attempt: from here on the identity is immutable.
    func markSending(seq: Int64) throws {
        let changed = try self.connection.execute("UPDATE outbox SET state = 'sending', sent_once = 1 WHERE seq = ? AND state = 'queued' AND sealed = 1;", [.integer(seq)])
        guard changed == 1 else { throw SGTasksCloudStoreError(code: SQLITE_CONSTRAINT) }
    }

    /// Every state change but `setConflict` also clears the R4 conflict detail (fields, pending
    /// automatic resolution).
    func setState(seq: Int64, _ state: SGTasksCloudEntryState, conflictReason: SGTasksWire.ConflictReason? = nil, attempts: Int? = nil, nextAttemptAt: Date? = nil, serverTime: Date? = nil) throws {
        try self.connection.execute(
            "UPDATE outbox SET state = ?, conflict_reason = ?, conflict_fields = NULL, auto_resolve = NULL, attempts = COALESCE(?, attempts), next_attempt_at = ?, server_time = COALESCE(?, server_time) WHERE seq = ?;",
            [.text(state.rawValue), .optionalText(conflictReason?.rawValue), .optionalInteger(attempts.map(Int64.init)), .optionalReal(nextAttemptAt?.timeIntervalSince1970), .optionalReal(serverTime?.timeIntervalSince1970), .integer(seq)]
        )
    }

    /// A 409 with its exact wire reason (an R4 one included) and, for `field_changed`, its fields;
    /// `autoResolve` marks it for the automatic resolution after the next complete pull.
    func setConflict(seq: Int64, reason: SGTasksWire.ErrorReason, fields: [SGTasksWire.ContentField], autoResolve: Bool, serverTime: Date?) throws {
        try self.connection.execute(
            "UPDATE outbox SET state = 'conflict', conflict_reason = ?, conflict_fields = ?, auto_resolve = ?, next_attempt_at = NULL, server_time = COALESCE(?, server_time) WHERE seq = ?;",
            [.text(reason.rawValue), .optionalText(Self.encodeFields(fields)), .optionalText(autoResolve ? Self.autoResolvePending : nil), .optionalReal(serverTime?.timeIntervalSince1970), .integer(seq)]
        )
    }

    /// The conflict stays, for an explicit choice.
    func clearAutoResolve(seq: Int64) throws {
        try self.connection.execute("UPDATE outbox SET auto_resolve = NULL WHERE seq = ?;", [.integer(seq)])
    }

    /// An entry still `sending` goes back to the queue with the same identity and no attempt
    /// counted (a batch item that never started, a fenced answer).
    func requeueSending(seq: Int64) throws {
        try self.connection.execute("UPDATE outbox SET state = 'queued' WHERE seq = ? AND state = 'sending';", [.integer(seq)])
    }

    /// §7.4: `stalled` / `blocked_creation` → `queued`, same identity, attempts reset, one more
    /// automatic requeue counted.
    func autoRequeue(seq: Int64) throws {
        try self.connection.execute("UPDATE outbox SET state = 'queued', attempts = 0, next_attempt_at = NULL, auto_requeues = auto_requeues + 1 WHERE seq = ? AND state IN ('stalled', 'blocked_creation');", [.integer(seq)])
    }

    func markAcked(seq: Int64, revision: String?, marker: Int64, serverTime: Date) throws {
        try self.connection.execute(
            "UPDATE outbox SET state = 'acked', conflict_reason = NULL, next_attempt_at = NULL, ack_revision = ?, ack_marker = ?, server_time = ? WHERE seq = ?;",
            [.optionalText(revision), .integer(marker), .real(serverTime.timeIntervalSince1970), .integer(seq)]
        )
    }

    /// Exactly-once hold transition: only a still-held row with the same token changes.
    func promoteHeld(seq: Int64) throws -> Bool {
        return try self.connection.execute("UPDATE outbox SET state = 'queued', hold_token = NULL WHERE seq = ? AND state = 'held';", [.integer(seq)]) == 1
    }

    func deleteEntry(seq: Int64) throws {
        try self.connection.execute("DELETE FROM outbox WHERE seq = ?;", [.integer(seq)])
    }

    func deleteHeld(seq: Int64, token: String) throws -> Bool {
        return try self.connection.execute("DELETE FROM outbox WHERE seq = ? AND state = 'held' AND hold_token = ?;", [.integer(seq), .text(token)]) == 1
    }


    /// Unsent (not yet acknowledged) USER changes; migration creates are re-derived from the local
    /// archive and are not the user's unsent work.
    func unsentCount() throws -> Int {
        return try self.unsentCounts().user
    }

    func unsentCounts() throws -> (user: Int, migration: Int) {
        return try Self.unsentCounts(self.connection)
    }

    /// The same read on any connection (a read-only one included). A store an R3 build left behind
    /// has no `origin` column yet: every row of it is a user change. wf15 §12.2: a deferred
    /// assignment (`assign_deferred.*`, due or not) is a user change too — it left the outbox but has
    /// not reached the server, and a logout purge or a withdrawal deletes it — so the logout and
    /// withdrawal confirmations name it.
    static func unsentCounts(_ connection: SGTasksCloudSQLite) throws -> (user: Int, migration: Int) {
        let deferred = Int(try connection.query("SELECT COUNT(*) FROM meta WHERE key GLOB ?;", [.text(Self.globPattern(prefix: Self.deferredAssignmentPrefix))]) { $0.integer(0) }.first ?? 0)
        let columns = Set(try connection.query("PRAGMA table_info(outbox);") { $0.text(1) })
        guard columns.contains("origin") else {
            let all = Int(try connection.query("SELECT COUNT(*) FROM outbox WHERE state != 'acked';") { $0.integer(0) }.first ?? 0)
            return (user: all + deferred, migration: 0)
        }
        var user = deferred
        var migration = 0
        for (origin, count) in try connection.query("SELECT origin, COUNT(*) FROM outbox WHERE state != 'acked' GROUP BY origin;", [], { ($0.text(0), Int($0.integer(1))) }) {
            switch SGTasksWire.MutationOrigin(rawValue: origin) {
            case .user?:
                user += count
            case .migration?:
                migration += count
            case nil:
                throw SGTasksCloudStoreError(code: SQLITE_CORRUPT)
            }
        }
        return (user: user, migration: migration)
    }

    /// Withdrawal: every row not acknowledged by the server goes (held deletes included), and so
    /// do the deferred assignments and the re-send markers (wf15 §12.2); returns how many of them
    /// were user changes (deferred assignments included).
    func deleteUnacknowledged() throws -> Int {
        let user = try self.unsentCounts().user
        try self.connection.execute("DELETE FROM outbox WHERE state != 'acked';")
        try self.deleteMeta(prefix: Self.deferredAssignmentPrefix)
        try self.deleteMeta(prefix: Self.automaticResendPrefix)
        try self.deleteMeta(prefix: Self.automaticAcceptPrefix)
        return user
    }

    /// Re-grant: unacknowledged migration rows left over are never sent (the migration re-derives
    /// them from the archive with its own identities).
    func deleteUnacknowledgedMigration() throws {
        try self.connection.execute("DELETE FROM outbox WHERE state != 'acked' AND origin = 'migration';")
    }

    func integerMeta(_ key: String) throws -> Int64? {
        return try self.meta(key).flatMap { Int64($0) }
    }

    func realMeta(_ key: String) throws -> Double? {
        return try self.meta(key).flatMap { Double($0) }
    }

    /// Bumped by every withdrawal discard; an insert made for an older epoch is refused.
    func consentEpoch() throws -> Int64 {
        return try self.integerMeta("consent_epoch") ?? 0
    }

    /// +1 wherever a 409 `tasks_resync_required` sets `needs_resnapshot` (the migration's late-
    /// erasure check compares generations).
    func markResyncRequired() throws {
        try self.setMeta("needs_resnapshot", "1")
        try self.setMeta("resync_generation", String((try self.integerMeta("resync_generation") ?? 0) + 1))
    }

    /// Sending rows interrupted by a crash/kill: their bytes may have reached the server, so they
    /// return to the queue and are resent with the SAME sealed identity.
    func requeueInterruptedSends() throws {
        try self.connection.execute("UPDATE outbox SET state = 'queued' WHERE state = 'sending';")
    }

    /// Folds the WAL into the main file and truncates it (outside any transaction).
    func checkpoint() throws {
        // The row is (busy, log frames, checkpointed frames); busy means a reader blocked it.
        let busy = try self.connection.query("PRAGMA wal_checkpoint(TRUNCATE);") { $0.integer(0) }.first ?? 1
        guard busy == 0 else { throw SGTasksCloudStoreError(code: SQLITE_BUSY) }
    }

    // MARK: Chain revisions

    func chainRevision(_ key: String) throws -> String? {
        return try self.connection.query("SELECT revision FROM chain_revision WHERE resource_key = ?;", [.text(key)]) { $0.text(0) }.first
    }

    func setChainRevision(_ key: String, _ revision: String?) throws {
        if let revision = revision {
            try self.connection.execute("INSERT INTO chain_revision (resource_key, revision) VALUES (?, ?) ON CONFLICT(resource_key) DO UPDATE SET revision = excluded.revision;", [.text(key), .text(revision)])
        } else {
            try self.connection.execute("DELETE FROM chain_revision WHERE resource_key = ?;", [.text(key)])
        }
    }

    func clearChainRevisions() throws {
        try self.connection.execute("DELETE FROM chain_revision;")
    }

    /// Keeps receipt-learned revisions only for resources an unresolved entry still references.
    func pruneChainRevisions(keeping keys: Set<String>) throws {
        let stored = try self.connection.query("SELECT resource_key FROM chain_revision;") { $0.text(0) }
        for key in stored where !keys.contains(key) {
            try self.connection.execute("DELETE FROM chain_revision WHERE resource_key = ?;", [.text(key)])
        }
    }

    // MARK: Notices

    func addNotice(_ kind: SGTasksCloudNotice.Kind, at date: Date) throws {
        try self.connection.execute("INSERT INTO notices (kind, created_at) VALUES (?, ?);", [.text(kind.rawValue), .real(date.timeIntervalSince1970)])
    }

    static let deleteKeptNotice = "delete_kept"
    static let changedElsewhereNotice = "changed_elsewhere"

    func notices() throws -> [SGTasksCloudNotice] {
        return try self.connection.query("SELECT id, kind, created_at FROM notices WHERE kind NOT IN (?, ?) ORDER BY id;", [.text(Self.deleteKeptNotice), .text(Self.changedElsewhereNotice)]) { row in
            guard let kind = SGTasksCloudNotice.Kind(rawValue: row.text(1)) else { throw SGTasksCloudStoreError(code: SQLITE_CORRUPT) }
            return SGTasksCloudNotice(id: row.integer(0), kind: kind, date: Date(timeIntervalSince1970: row.real(2)))
        }
    }

    func addResolutionNotice(_ kind: SGTasksCloudResolutionNotice.Kind, at date: Date) throws {
        switch kind {
        case .deleteKept:
            try self.connection.execute("INSERT INTO notices (kind, created_at) VALUES (?, ?);", [.text(Self.deleteKeptNotice), .real(date.timeIntervalSince1970)])
        case let .changedElsewhere(fields):
            try self.connection.execute("INSERT INTO notices (kind, created_at, fields) VALUES (?, ?, ?);", [.text(Self.changedElsewhereNotice), .real(date.timeIntervalSince1970), .optionalText(Self.encodeFields(fields))])
        }
    }

    func resolutionNotices() throws -> [SGTasksCloudResolutionNotice] {
        return try self.connection.query("SELECT id, kind, created_at, fields FROM notices WHERE kind IN (?, ?) ORDER BY id;", [.text(Self.deleteKeptNotice), .text(Self.changedElsewhereNotice)]) { row in
            let kind: SGTasksCloudResolutionNotice.Kind
            if row.text(1) == Self.deleteKeptNotice {
                kind = .deleteKept
            } else {
                guard let fields = Self.decodeFields(row.optionalText(3)) else { throw SGTasksCloudStoreError(code: SQLITE_CORRUPT) }
                kind = .changedElsewhere(fields: fields)
            }
            return SGTasksCloudResolutionNotice(id: row.integer(0), kind: kind, date: Date(timeIntervalSince1970: row.real(2)))
        }
    }

    func deleteNotice(id: Int64) throws {
        try self.connection.execute("DELETE FROM notices WHERE id = ?;", [.integer(id)])
    }
}

