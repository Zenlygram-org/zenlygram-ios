import CryptoKit
import Foundation
import SGEntitlement
import sqlcipher

// Host tests for SGTasksCloudRepository. The scripted server returns exactly the wire responses a
// case needs; every assertion is about what the repository persisted, showed, sent or refused. The
// fixtures below are module-internal: SGTasksCloudR4Tests.swift (the R4 engine) shares them.

enum CloudTestFailure: Error {
    case assertion(String)
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw CloudTestFailure.assertion(message)
    }
}

func expectError(_ expected: SGTasksCloudError, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as SGTasksCloudError {
        try check(error == expected, "Expected \(expected), got \(error)")
        return
    }
    throw CloudTestFailure.assertion("Expected \(expected), nothing thrown")
}

let ownTg = SGTasksWire.TelegramId("123456789")!
let otherTg = SGTasksWire.TelegramId("987654321")!
let principalA = "01arz3ndektsv4rrffq69g5fav"
let principalB = "01bx5zzkbkactav9wevgemmvrz"
let baseTime: TimeInterval = 1_800_000_000

/// The import-mapping scope builds before origin scoping persisted (principal only). Kept here as
/// the format of existing on-device rows, not as anything this build is expected to compute.
private func bareImportScope(_ principal: String) -> String {
    let digest = SHA256.hash(data: Data("zenlygram-tasks-import-scope-v1\u{0}\(principal)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Two validated backend origins (the parser the shipped configuration uses). The harness's
/// build talks to X; `otherOriginRepository` is the same account on Y.
private let upstreamApiUrl = "https://api.swiftgram.app"
let originX = SGEntitlementStoreScope.origin(SGEntitlementBackendOrigin(apiUrl: "https://tasks-x.example.org", upstreamDefaultApiUrl: upstreamApiUrl)!)
private let originY = SGEntitlementStoreScope.origin(SGEntitlementBackendOrigin(apiUrl: "https://tasks-y.example.org", upstreamDefaultApiUrl: upstreamApiUrl)!)

func instant(_ offset: TimeInterval = 0) -> SGTasksWire.Instant {
    return SGTasksWire.Instant(date: Date(timeIntervalSince1970: baseTime + offset))!
}

func cursor(_ raw: String) -> SGTasksWire.Cursor {
    return SGTasksWire.Cursor(raw)!
}

func revision(_ raw: String) -> SGTasksWire.Revision {
    return SGTasksWire.Revision(raw)!
}

func content(_ title: String, list: SGTasksWire.UUID? = nil, annotation: SGTasksWire.Annotation? = nil) -> SGTasksWire.Content {
    return SGTasksWire.Content(listId: list, title: title, description: nil, dueAt: nil, priority: 0, sortOrder: 0, annotation: annotation)
}

func ownerTask(_ id: SGTasksWire.UUID, rev: String, title: String, list: SGTasksWire.UUID? = nil) -> SGTasksWire.Projection {
    return .task(SGTasksWire.Task(id: id, revision: revision(rev), ownerTgId: ownTg, viewerRole: .owner, content: content(title, list: list), isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: nil))
}

func assignedTask(_ id: SGTasksWire.UUID, rev: String, title: String, invitation: SGTasksWire.UUID) -> SGTasksWire.Projection {
    let assignment = SGTasksWire.Assignment(invitationId: invitation, recipientTgId: ownTg, state: .accepted, expiresAt: instant(7 * 86400))
    return .task(SGTasksWire.Task(id: id, revision: revision(rev), ownerTgId: otherTg, viewerRole: .assignee, content: content(title), isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: assignment))
}

func list(_ id: SGTasksWire.UUID, rev: String, title: String) -> SGTasksWire.Projection {
    return .list(SGTasksWire.List(id: id, revision: revision(rev), title: title, sortOrder: 0, createdAt: instant(), updatedAt: instant()))
}

func failure<T>(_ kind: SGTasksError.Kind, retryAfter: Int? = nil, outcomeUnknown: Bool = false, refinement: SGTasksError.Refinement? = nil) -> Result<T, SGTasksError> {
    return .failure(SGTasksError(kind: kind, retryAfter: retryAfter, serverTime: nil, outcomeUnknown: outcomeUnknown, refinement: refinement))
}

/// A receipt for any sealed mutation (`serverWire` is the answer's `X-Tasks-Wire` echo).
func ack(_ mutation: SGTasksWire.SealedMutation, revision raw: String?, outcome: SGTasksWire.ReceiptOutcome = .committed, serverWire: Int? = nil) -> Result<SGTasksWire.MutationResponse, SGTasksError> {
    switch mutation {
    case let .mutation(request):
        return ack(request, revision: raw, outcome: outcome, serverWire: serverWire)
    case let .patch(request):
        let receipt = SGTasksWire.Receipt(mutationId: request.mutationId, operation: .taskPatch, outcome: outcome, resourceKind: .task, resourceId: .uuid(request.patch.taskId), resourceRevision: raw.map(revision), committedAt: instant())
        return .success(SGTasksWire.MutationResponse(receipt: receipt, serverTime: instant(), serverWire: serverWire))
    }
}

func ack(_ request: SGTasksWire.MutationRequest, revision raw: String?, outcome: SGTasksWire.ReceiptOutcome = .committed, serverWire: Int? = nil) -> Result<SGTasksWire.MutationResponse, SGTasksError> {
    let kind: SGTasksWire.ResourceKind
    let resource: SGTasksWire.ResourceId
    switch request.operation {
    case let .listCreate(op): (kind, resource) = (.list, .uuid(op.listId))
    case let .listUpdate(op): (kind, resource) = (.list, .uuid(op.listId))
    case let .listDelete(op): (kind, resource) = (.list, .uuid(op.listId))
    case let .taskCreate(op): (kind, resource) = (.task, .uuid(op.taskId))
    case let .taskUpdate(op): (kind, resource) = (.task, .uuid(op.taskId))
    case let .taskComplete(op): (kind, resource) = (.task, .uuid(op.taskId))
    case let .taskDelete(op): (kind, resource) = (.task, .uuid(op.taskId))
    case let .inviteRequest(op): (kind, resource) = (.task, .uuid(op.taskId))
    case let .inviteRespond(op): (kind, resource) = (.task, .uuid(op.taskId))
    case let .inviteRevoke(op): (kind, resource) = (.task, .uuid(op.taskId))
    case .senderBlock: (kind, resource) = (.block, .telegramId(otherTg))
    case let .senderUnblock(op): (kind, resource) = (.block, .telegramId(op.senderTgId))
    }
    let receipt = SGTasksWire.Receipt(mutationId: request.mutationId, operation: request.operation.kind, outcome: outcome, resourceKind: kind, resourceId: resource, resourceRevision: raw.map(revision), committedAt: instant())
    return .success(SGTasksWire.MutationResponse(receipt: receipt, serverTime: instant(), serverWire: serverWire))
}

func changesPage(_ changes: [SGTasksWire.Change], next: String = "c-next", serverWire: Int? = nil) -> Result<SGTasksWire.ChangesResponse, SGTasksError> {
    return .success(SGTasksWire.ChangesResponse(changes: changes, nextCursor: cursor(next), hasMore: false, serverTime: instant(), serverWire: serverWire))
}

func upsert(_ item: SGTasksWire.Projection, at position: String = "5") -> SGTasksWire.Change {
    return .upsert(position: SGTasksWire.Sequence(position)!, item: item)
}

func remove(_ target: SGTasksWire.RemovalTarget, at position: String = "6") -> SGTasksWire.Change {
    return .remove(position: SGTasksWire.Sequence(position)!, target: target)
}

func baseRevision(_ operation: SGTasksWire.Operation) -> String? {
    switch operation {
    case let .taskUpdate(op): return op.baseRevision.rawValue
    case let .taskDelete(op): return op.baseRevision.rawValue
    case let .taskComplete(op): return op.baseRevision.rawValue
    case let .listUpdate(op): return op.baseRevision.rawValue
    default: return nil
    }
}

/// Scripted stand-in for the SGEntitlement Tasks facade. Unscripted mutation and batch calls time
/// out with an unknown outcome (the scripted per-call timeout); unscripted change pages are empty and
/// keep the cursor; unscripted snapshots fail.
final class ScriptedServer: SGTasksCloudTransport {
    var principalValue: String? = principalA
    var linked = true
    /// Whether this build has a Tasks backend at all (the facade's actual readiness). Every case
    /// states it explicitly through this flag; an unconfigured build must never reach a call here.
    var configured = true
    var snapshotScript: [Result<SGTasksWire.SnapshotResponse, SGTasksError>] = []
    var changesScript: [Result<SGTasksWire.ChangesResponse, SGTasksError>] = []
    var mutationScript: [(SGTasksWire.SealedMutation) -> Result<SGTasksWire.MutationResponse, SGTasksError>] = []
    var onMutation: ((SGTasksWire.SealedMutation) -> Void)?
    /// `POST /v1/tasks/mutations/batch` answers, in call order.
    var batchScript: [(SGTasksWire.MutationBatchRequest) -> Result<SGTasksWire.MutationBatchResponse, SGTasksError>] = []
    var onBatch: ((SGTasksWire.MutationBatchRequest) -> Void)?
    /// The binding marker the facade would report (`tasksBindingMarker`).
    var bindingMarkerValue: String? = "binding-1"
    /// The `X-Tasks-Wire` echo of unscripted change pages and of `Harness.bootstrap`'s snapshot:
    /// nil (an R3 server) unless an R4 case sets 4 (or 5, a wire-5 server).
    var defaultServerWire: Int?
    /// The build's request wire as the facade would report it (`SGTasksShippedWire.requestWire`):
    /// 4 unless a case scripts a build made for a wire-5 backend.
    var requestWireValue = SGTasksWire.wireRevision

    var requestWire: Int {
        return self.requestWireValue
    }
    /// Awaited inside every `changes` call while set (keeps a REST cycle in flight).
    var changesHold: (() async -> Void)?
    private(set) var changesCount = 0
    /// Every R3 mutation the single route carried (a `task.patch` is in `sentSealed` only).
    private(set) var sent: [SGTasksWire.MutationRequest] = []
    /// Everything the single route carried.
    private(set) var sentSealed: [SGTasksWire.SealedMutation] = []
    private(set) var sentBatches: [SGTasksWire.MutationBatchRequest] = []
    private(set) var callCount = 0
    private(set) var snapshotCount = 0
    enum Route: Equatable {
        case mutation, batch, snapshot, changes
    }
    /// Runs inside every REST call while it waits in SGEntitlement's account gate (behind a token
    /// rotation or a customer-data call), BEFORE the facade's post-gate re-check: a withdrawal or a
    /// permission change meanwhile.
    var whileInGate: ((Route) -> Void)?
    /// REST calls the post-gate re-check refused (`stillWanted` false), by route: never sent, never
    /// in `callCount`.
    private(set) var refusedInGate: [Route] = []

    /// SGEntitlement's account gate and its re-check, as the facade runs them: the call waits
    /// (`whileInGate`), then goes only while `stillWanted` holds; else nothing is sent and it ends
    /// like a call cancelled while it waited.
    private func passesGate(_ route: Route, _ stillWanted: () -> Bool) -> Bool {
        self.whileInGate?(route)
        guard stillWanted() else {
            self.refusedInGate.append(route)
            return false
        }
        return true
    }

    func mutation(_ request: SGTasksWire.SealedMutation, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationResponse, SGTasksError> {
        guard self.passesGate(.mutation, stillWanted) else { return failure(.transport(.cancelled)) }
        self.callCount += 1
        if case let .mutation(r3) = request {
            self.sent.append(r3)
        }
        self.sentSealed.append(request)
        self.onMutation?(request)
        guard !self.mutationScript.isEmpty else {
            return failure(.transport(.timeout), outcomeUnknown: true)
        }
        return self.mutationScript.removeFirst()(request)
    }

    func mutationBatch(_ request: SGTasksWire.MutationBatchRequest, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        guard self.passesGate(.batch, stillWanted) else { return failure(.transport(.cancelled)) }
        self.callCount += 1
        self.sentBatches.append(request)
        self.onBatch?(request)
        guard !self.batchScript.isEmpty else {
            return failure(.transport(.timeout), outcomeUnknown: true)
        }
        return self.batchScript.removeFirst()(request)
    }

    func bindingMarker(accountPeerId: Int64) -> String? {
        return self.bindingMarkerValue
    }

    func snapshot(accountPeerId: Int64, cursor: SGTasksWire.Cursor?, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.SnapshotResponse, SGTasksError> {
        guard self.passesGate(.snapshot, stillWanted) else { return failure(.transport(.cancelled)) }
        self.callCount += 1
        self.snapshotCount += 1
        guard !self.snapshotScript.isEmpty else { return failure(.unavailable) }
        return self.snapshotScript.removeFirst()
    }

    func changes(accountPeerId: Int64, cursor: SGTasksWire.Cursor, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.ChangesResponse, SGTasksError> {
        guard self.passesGate(.changes, stillWanted) else { return failure(.transport(.cancelled)) }
        self.callCount += 1
        self.changesCount += 1
        if let hold = self.changesHold {
            await hold()
        }
        guard !self.changesScript.isEmpty else {
            return .success(SGTasksWire.ChangesResponse(changes: [], nextCursor: cursor, hasMore: false, serverTime: instant(), serverWire: self.defaultServerWire))
        }
        return self.changesScript.removeFirst()
    }

    func ownTelegramId(accountPeerId: Int64) -> SGTasksWire.TelegramId? {
        return ownTg
    }

    func isLinked(accountPeerId: Int64) -> Bool {
        return self.linked
    }

    func principal(accountPeerId: Int64) -> String? {
        return self.principalValue
    }

    var isConfigured: Bool {
        return self.configured
    }

    /// nil keeps the repository deaf to session changes; a case sets it before opening the
    /// repository to deliver a (late) session notice itself.
    var sessionNotice: Notification.Name?

    var sessionChangeNotification: Notification.Name? {
        return self.sessionNotice
    }
}

/// Real file system with injectable failures for the purge contract.
final class FaultyFileSystem: SGTasksCloudFileSystem {
    private let real = SGTasksCloudDefaultFileSystem()
    var failMarkerWrite = false
    var failMove = false
    var failStoreRemove = false

    private func isStoreFile(_ path: String) -> Bool {
        return path.contains(".sqlite") || path.contains(".purging-")
    }

    func fileExists(atPath path: String) -> Bool { return self.real.fileExists(atPath: path) }
    func createProtectedDirectory(at url: URL) throws { try self.real.createProtectedDirectory(at: url) }
    func excludeFromBackup(_ url: URL) throws { try self.real.excludeFromBackup(url) }
    func contentsOfDirectory(atPath path: String) throws -> [String] { return try self.real.contentsOfDirectory(atPath: path) }
    func applyProtection(toPath path: String) throws { try self.real.applyProtection(toPath: path) }

    func writeAtomically(_ data: Data, toPath path: String) throws {
        if self.failMarkerWrite { throw CocoaError(.fileWriteNoPermission) }
        try self.real.writeAtomically(data, toPath: path)
    }

    func moveItem(atPath source: String, toPath destination: String) throws {
        if self.failMove { throw CocoaError(.fileWriteNoPermission) }
        try self.real.moveItem(atPath: source, toPath: destination)
    }

    func removeItem(atPath path: String) throws {
        if self.failStoreRemove && self.isStoreFile(path) { throw CocoaError(.fileWriteNoPermission) }
        try self.real.removeItem(atPath: path)
    }
}

final class Harness {
    let directory: URL
    let storeDirectory: URL
    /// The single cloud root of builds before origin scoping (`zenlygram-tasks-cloud`): never
    /// opened, read or imported from by this build; only explicit logout / remove-all purge it.
    let preOriginStoreDirectory: URL
    let fileSystem = FaultyFileSystem()
    let notificationCenter = NotificationCenter()
    var files: SGTasksCloudStoreFiles
    var preOriginFiles: SGTasksCloudStoreFiles
    let server = ScriptedServer()
    let legacyDefaults: UserDefaults
    let legacySuite: String
    var legacy: TodoDatabase
    var clock = Date(timeIntervalSince1970: baseTime)
    var holdDuration: TimeInterval = 3600
    /// Set by realtime cases before opening a repository (nil: no realtime, as before).
    var realtime: SGTasksCloudRealtimeEnvironment?
    /// Realtime repository cases run the REAL automatic cycle (`runCycles`) when true.
    var automaticSync = false
    var pollInterval: TimeInterval = 3600
    /// When set, the repository's REST poll is armed on this manual clock (advanced by the case on
    /// the repository queue) instead of `queue.asyncAfter`.
    var pollScheduler: SGTasksRealtimeTestScheduler?
    /// The local create gate the repository reads for the §7.4 requeue of a refused user create.
    var creationAllowed = true

    init() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("sgtasks-cloud-tests-\(UUID().uuidString)")
        self.storeDirectory = self.directory.appendingPathComponent("cloud", isDirectory: true)
        self.preOriginStoreDirectory = self.directory.appendingPathComponent("cloud-pre-origin", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.files = SGTasksCloudStoreFiles(directory: self.storeDirectory, fileSystem: self.fileSystem)
        self.preOriginFiles = SGTasksCloudStoreFiles(directory: self.preOriginStoreDirectory, fileSystem: self.fileSystem)
        self.legacySuite = "sgtasks-cloud-tests.\(UUID().uuidString)"
        self.legacyDefaults = UserDefaults(suiteName: self.legacySuite)!
        self.legacy = TodoDatabase(dbPath: self.directory.appendingPathComponent("legacy.sqlite").path, defaults: self.legacyDefaults)
    }

    deinit {
        self.legacyDefaults.removePersistentDomain(forName: self.legacySuite)
        try? FileManager.default.removeItem(at: self.directory)
    }

    /// A fresh process: new files manager (no in-memory purge state), same directory.
    func simulateRestart() {
        self.files = SGTasksCloudStoreFiles(directory: self.storeDirectory, fileSystem: self.fileSystem)
        self.preOriginFiles = SGTasksCloudStoreFiles(directory: self.preOriginStoreDirectory, fileSystem: self.fileSystem)
    }

    var environment: SGTasksCloudRepository.Environment {
        return self.makeEnvironment(files: self.files, preOriginFiles: self.preOriginFiles, originScope: originX)
    }

    func makeEnvironment(files: SGTasksCloudStoreFiles, preOriginFiles: SGTasksCloudStoreFiles, originScope: SGEntitlementStoreScope) -> SGTasksCloudRepository.Environment {
        var environment = SGTasksCloudRepository.Environment(
            files: files, preOriginFiles: preOriginFiles, originScope: originScope, transport: self.server,
            // Strong on purpose: every repository built from this environment keeps its harness —
            // and so the directory `deinit` unlinks and the `legacy` SQLite database — alive until
            // the repository itself is gone. No cycle: the harness stores neither an environment
            // nor a repository.
            legacy: { self.legacy },
            now: { self.clock },
            holdDuration: self.holdDuration, pollInterval: self.pollInterval, automaticSync: self.automaticSync,
            notificationCenter: self.notificationCenter, observesApplicationLifecycle: false,
            realtime: self.realtime
        )
        environment.creationAllowed = { _ in self.creationAllowed }
        // wf15 §5.3: the durable manual invitation answers go to this harness's own suite (removed
        // with it), never to the host's standard defaults.
        environment.defaults = self.legacyDefaults
        if let scheduler = self.pollScheduler {
            environment.schedulePoll = { _, delay, work in
                _ = scheduler.schedule(after: delay) {
                    // A cancelled poll (`pollWork.cancel()`) does nothing, as on a dispatch queue.
                    if !work.isCancelled {
                        work.perform()
                    }
                }
            }
        }
        return environment
    }

    func repository(_ accountPeerId: Int64 = 42) -> SGTasksCloudRepository {
        return SGTasksCloudRepository(accountPeerId: accountPeerId, environment: self.environment)
    }

    /// The same native account in a build for ANOTHER backend origin: its own cloud root, the same
    /// device-local Tasks database (so the same import-mapping table) and the same server principal.
    func otherOriginRepository(_ accountPeerId: Int64 = 42) -> SGTasksCloudRepository {
        let files = SGTasksCloudStoreFiles(directory: self.directory.appendingPathComponent("cloud-other-origin", isDirectory: true), fileSystem: self.fileSystem)
        return SGTasksCloudRepository(accountPeerId: accountPeerId, environment: self.makeEnvironment(files: files, preOriginFiles: self.preOriginFiles, originScope: originY))
    }

    /// A repository of a build before origin scoping, whose only cloud root was the pre-origin
    /// directory (it had no older root of its own; an unused directory stands in for one).
    func preOriginBuildRepository(_ accountPeerId: Int64) -> SGTasksCloudRepository {
        let files = SGTasksCloudStoreFiles(directory: self.preOriginStoreDirectory, fileSystem: self.fileSystem)
        let none = SGTasksCloudStoreFiles(directory: self.directory.appendingPathComponent("cloud-none", isDirectory: true), fileSystem: self.fileSystem)
        return SGTasksCloudRepository(accountPeerId: accountPeerId, environment: self.makeEnvironment(files: files, preOriginFiles: none, originScope: originX))
    }

    /// Every file in the pre-origin root, by name, byte for byte.
    func preOriginContents() throws -> [String: Data] {
        var out: [String: Data] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: self.preOriginStoreDirectory.path)) ?? []
        for name in names {
            out[name] = try Data(contentsOf: self.preOriginStoreDirectory.appendingPathComponent(name))
        }
        return out
    }

    func bootstrap(_ repository: SGTasksCloudRepository, items: [SGTasksWire.Projection] = []) async throws {
        self.server.snapshotScript.append(.success(SGTasksWire.SnapshotResponse(items: items, nextCursor: nil, changesCursor: cursor("c1"), serverTime: instant(), serverWire: self.server.defaultServerWire)))
        await repository.syncNow()
        try check(repository.state.hasCompleteSnapshot, "Bootstrap snapshot did not complete")
    }

    func cloudScalar(_ sql: String, accountPeerId: Int64 = 42) throws -> Int64 {
        var connection: OpaquePointer?
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(connection) }
        guard sqlite3_open_v2(self.files.path(accountPeerId: accountPeerId), &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw CloudTestFailure.assertion("SQL failed: \(sql)") }
        return sqlite3_column_int64(statement, 0)
    }

    /// The first column of the first row as text; nil for no row or NULL.
    func cloudText(_ sql: String, accountPeerId: Int64 = 42) throws -> String? {
        var connection: OpaquePointer?
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(connection) }
        guard sqlite3_open_v2(self.files.path(accountPeerId: accountPeerId), &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw CloudTestFailure.assertion("SQL failed: \(sql)") }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            guard step == SQLITE_DONE else { throw CloudTestFailure.assertion("SQL failed: \(sql)") }
            return nil
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func cloudExecute(_ sql: String, accountPeerId: Int64 = 42) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(self.files.path(accountPeerId: accountPeerId), &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw CloudTestFailure.assertion("SQL failed: \(sql)") }
    }

    /// Fixture reset between sub-cases: empties the outbox and refreshes the repository's board.
    func clearOutbox(_ repository: SGTasksCloudRepository) throws {
        try self.cloudExecute("DELETE FROM outbox;", accountPeerId: repository.accountPeerId)
        repository.onQueue { repository.rebuildState() }
    }

    func outboxBodies(accountPeerId: Int64 = 42) throws -> [Data] {
        var connection: OpaquePointer?
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(connection) }
        guard sqlite3_open_v2(self.files.path(accountPeerId: accountPeerId), &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(connection, "SELECT body FROM outbox ORDER BY seq;", -1, &statement, nil) == SQLITE_OK else { throw CloudTestFailure.assertion("outbox read failed") }
        var out: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0))))
        }
        return out
    }
}

/// Runs every main-queue block enqueued before this call; the repository posts its change notice
/// with `DispatchQueue.main.async`.
func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

/// The board's consumer contract (`tasksCloudStateSignal`): the current state first, then the state
/// re-read on every change notice of this repository. Records what a subscriber would render.
private final class StatePublicationRecorder {
    private(set) var published: [SGTasksCloudState] = []
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(_ repository: SGTasksCloudRepository, center: NotificationCenter) {
        self.center = center
        self.published.append(repository.state)
        self.observer = center.addObserver(forName: SGTasksCloudRepository.didChangeNotification, object: repository, queue: nil) { [weak self, weak repository] _ in
            guard let self = self, let repository = repository else { return }
            self.published.append(repository.state)
        }
    }

    deinit {
        if let observer = self.observer {
            self.center.removeObserver(observer)
        }
    }
}

/// One repository bound to principal A — a complete snapshot with an own task, a shared task, a
/// list and a pending invitation, plus one queued local draft — listening for a session notice the
/// case delivers itself (or never).
private struct PrincipalABoard {
    static let shadowRowCount: Int64 = 4

    let harness: Harness
    let repository: SGTasksCloudRepository
    let notice: Notification.Name
    let shadowTaskIds: [SGTasksWire.UUID]
    let draftId: SGTasksWire.UUID

    static func make(observesNotice: Bool = true) async throws -> PrincipalABoard {
        let harness = try Harness()
        let notice = Notification.Name("sgtasks-cloud-tests-session-\(UUID().uuidString)")
        if observesNotice {
            harness.server.sessionNotice = notice
        }
        let repository = harness.repository()
        let owned = SGTasksWire.UUID.generate()
        let shared = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [
            ownerTask(owned, rev: "1", title: "A's own task"),
            assignedTask(shared, rev: "1", title: "A's shared task", invitation: SGTasksWire.UUID.generate()),
            list(SGTasksWire.UUID.generate(), rev: "1", title: "A's list"),
            .invitation(SGTasksWire.Invitation(id: SGTasksWire.UUID.generate(), taskId: SGTasksWire.UUID.generate(), taskRevision: revision("1"), ownerTgId: otherTg, title: "A's offer", dueAt: nil, expiresAt: instant(86400)))
        ])
        let draftId = try repository.createTask(SGTasksCloudTaskDraft(title: "Draft"))
        await drainMainQueue()
        let board = PrincipalABoard(harness: harness, repository: repository, notice: notice, shadowTaskIds: [owned, shared], draftId: draftId)
        let bound = repository.state
        try check(bound.hasCompleteSnapshot && bound.tasks.count == 3 && bound.lists.count == 1 && bound.invitations.count == 1 && bound.entries.map { $0.status } == [.queued], "Fixture is not a complete A board with a queued draft")
        try board.checkDurableUntouched("Fixture")
        return board
    }

    /// A read under a mismatched binding: none of A's server rows, none of the draft's overlay or a
    /// sendable entry for it, no snapshot/sync metadata, and no complete-board (success) claim.
    func checkHidden(_ state: SGTasksCloudState, _ when: String) throws {
        try check(state.tasks.isEmpty && state.lists.isEmpty && state.invitations.isEmpty && state.blocks.isEmpty, "\(when): principal A's board (shadow or overlay) was published")
        try check(state.entries.allSatisfy { $0.status == .accountChanged }, "\(when): principal A's draft was published as sendable")
        try check(!state.hasCompleteSnapshot, "\(when): a complete board was claimed for the new principal")
        try check(state.lastSyncedAt == nil && state.serverTime == nil && state.serverTimeReceivedAt == nil, "\(when): principal A's sync metadata was published")
    }

    /// Reading changed nothing durable: A's binding, snapshot, shadow and queued draft are intact.
    func checkDurableUntouched(_ when: String) throws {
        let principal = try self.harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'principal' AND value = '\(principalA)';")
        let snapshot = try self.harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'snapshot_complete' AND value = '1';")
        try check(principal == 1 && snapshot == 1, "\(when): a read changed the stored binding or snapshot")
        try check(try self.harness.cloudScalar("SELECT COUNT(*) FROM shadow;") == Self.shadowRowCount, "\(when): a read changed the stored shadow")
        let outbox = try self.harness.cloudScalar("SELECT COUNT(*) FROM outbox;")
        let queued = try self.harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE state = 'queued';")
        try check(outbox == 1 && queued == 1, "\(when): a read changed the outbox")
    }

    /// After an actual fence (session notice / start): the subscriber's latest value is the
    /// repository's state, A's shadow is gone, and the draft survives only as a retired entry
    /// (copy/discard; a previous-account operation is never projected onto the board).
    func checkFencedPublished(_ recorder: StatePublicationRecorder, _ when: String) async throws {
        self.repository.onQueue {}
        await drainMainQueue()
        guard let last = recorder.published.last else { throw CloudTestFailure.assertion("\(when): nothing was published") }
        try check(last == self.repository.state, "\(when): the subscriber was left on a stale value")
        try check(!last.tasks.contains { self.shadowTaskIds.contains($0.id) } && last.lists.isEmpty && last.invitations.isEmpty && !last.hasCompleteSnapshot, "\(when): principal A's shadow was published")
        try check(last.entries.map { $0.status } == [.accountChanged] && !last.tasks.contains { $0.id == self.draftId }, "\(when): the draft was not kept as a retired entry for copy/discard")
        try check(try self.harness.cloudScalar("SELECT COUNT(*) FROM shadow;") == 0, "\(when): principal A's shadow kept on disk after the fence")
    }

    /// Principal B's first snapshot reaches the subscriber, and no publication carried A's shadow.
    func checkPrincipalBPublishes(_ recorder: StatePublicationRecorder) async throws {
        let taskB = SGTasksWire.UUID.generate()
        self.harness.server.snapshotScript = [.success(SGTasksWire.SnapshotResponse(items: [ownerTask(taskB, rev: "1", title: "B's task")], nextCursor: nil, changesCursor: cursor("b1"), serverTime: instant()))]
        await self.repository.syncNow()
        self.repository.onQueue {}
        await drainMainQueue()
        guard let last = recorder.published.last else { throw CloudTestFailure.assertion("Nothing was published") }
        try check(last == self.repository.state, "The subscriber was left on a stale value after B's snapshot")
        try check(last.hasCompleteSnapshot && last.tasks.contains { $0.id == taskB }, "Principal B's board was never published")
        try check(recorder.published.allSatisfy { state in !state.tasks.contains { self.shadowTaskIds.contains($0.id) } && state.lists.isEmpty && state.invitations.isEmpty }, "A publication after the rebind carried principal A's shadow")
        try check(try self.harness.cloudScalar("SELECT COUNT(*) FROM shadow;") == 1, "Principal A's shadow survived B's snapshot")
    }
}

@main
private struct SGTasksCloudRepositoryTests {
    /// No argument: every case (legacy repository + realtime). `--realtime-only`: only the realtime
    /// repository cases and the controller cases. Anything else fails closed before any test runs.
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let cases: [(String, () async throws -> Void)]
        if arguments.isEmpty {
            cases = Self.legacyCases + Self.realtimeCases + SGTasksCloudR4Tests.cases + SGTasksAutoAcceptTests.cases + SGTasksLegacyAssigneeOfferTests.cases + SGTasksMigrationTests.cases
        } else if arguments == ["--realtime-only"] {
            cases = Self.realtimeCases
        } else {
            print("FAIL: unsupported arguments (only --realtime-only is accepted)")
            exit(2)
        }
        var failures: [String] = []
        // FIRST, before anything installs a permission source: the shipped default is fail-closed.
        do {
            try await SGTasksCloudR4Tests.defaultPermissionSendsNothing()
            print("PASS: the default traffic permission (.forbidden) sends no Tasks request at all")
        } catch {
            failures.append("default permission")
            print("FAIL: the default traffic permission (.forbidden): \(error)")
        }
        // The R3 cases run exactly as before under `.legacy`; every R4 case installs its own.
        SGTasksCloudRepository.trafficPermission = { _ in .legacy }
        for (name, test) in cases {
            do {
                try await test()
                print("PASS: \(name)")
            } catch {
                failures.append(name)
                print("FAIL: \(name): \(error)")
            }
        }
        guard failures.isEmpty else {
            print("FAIL: \(failures.count) of \(cases.count + 1) cloud repository behavior tests")
            exit(1)
        }
        print("PASS: \(cases.count + 1) cloud repository behavior tests")
    }

    /// The repository cases that predate realtime (run by default only).
    static let legacyCases: [(String, () async throws -> Void)] = [
            ("local mutation and enqueue are atomic, durable and credential-free", atomicEnqueueSurvivesRestart),
            ("timeouts and crashes resend the identical sealed identity", sealedReplay),
            ("snapshot is staged, delta-applied, and never reconciled when incomplete", snapshotStaging),
            ("dependency chains: acknowledged creates precede dependents, base from receipt", dependencyOrdering),
            ("403 creation refusal blocks only its chain; retry reuses the id", creationRefusal),
            ("409 conflict needs explicit choice; reapply uses fresh revision and new id", conflictResolution),
            ("422 invalid / mismatch / 429 / bounded backoff are handled separately", refusalClasses),
            ("tasks_account_not_linked pauses durably without wiping or retrying", unlinkedPause),
            ("lost shared access removes cached content and commands", sharedAccessLoss),
            ("own 404 drops the overlay; a copy is a new create", ownNotFound),
            ("held delete: Undo, commit, deinit, timeout, background, restart", heldDeleteLifecycle),
            ("held delete seals the hold-time base and surfaces a later conflict", heldDeleteConflict),
            ("purge fences a late response and recreates nothing", purgeFencesLateResponse),
            ("purge fails closed across unlink/marker failures and restart", purgeFailsClosed),
            ("launch reconciliation removes only signed-out accounts", reconcileAccounts),
            ("principal change retires old-scope operations and shadow", principalFence),
            ("explicit import: consent snapshot, mapping reuse, annotations, re-login", explicitImport),
            ("confirmed targets, server-clock expiry, pending answers and entry drafts", confirmedTargets),
            ("known-unsent offline failures spend no attempts; offline pull skips the drain", offlineSpendsNoAttempts),
            ("A->B move keeps both list fences; acks retire only on shadow proof", acknowledgementCoverage),
            ("a queued block survives removal of its invitation", blockSurvivesInvitationRemoval),
            ("a rebind is fenced at once, without a sync", immediatePrincipalFence),
            ("import statuses: blocked, pending, resend of a refused attempt, removed from cloud", importStatuses),
            ("a proven delete retires earlier acks; secondary-key removal proves nothing", deleteAndSecondaryKeyProof),
            ("cloud retirement never waits for the local database; import provenance is queued durably", { try await durableAckProvenance(purgeBeforeFlush: false) }),
            ("logout flushes recovered import provenance before purging the cloud store", { try await durableAckProvenance(purgeBeforeFlush: true) }),
            ("failed later list edits block import instead of claiming an in-flight copy", failedLaterImportEdit),
            ("same-principal rotation and signed-out reads keep the bound board and drafts", samePrincipalReadsKeepBoard),
            ("a rebind without its session notice: no read publishes the old principal; B's sync publishes B", rebindBeforeSessionNotice),
            ("a rebind before a late session notice: first read hides the old principal; the fence reaches the subscriber", rebindThenLateSessionNotice),
            ("a stopped board's next subscriber never sees the old principal after a silent rebind", rebindWhileBoardStopped),
            ("a store reopened under a new principal hides old-scope work until the board's start fences it", reopenedUnderNewPrincipal),
            ("a storage loss during the rebind fence publishes storageUnavailable, not a stale or loading board", storageLossDuringRebindFence),
            ("an unconfigured build without a session is notConfigured: no link recovery, no request, local edits kept", unconfiguredWithoutSession),
            ("an unconfigured successor of a bound board is notConfigured and sends nothing", unconfiguredSuccessorOfBoundBoard),
            ("an unconfigured build hands over to a configured one: no session pauses, a bound session snapshots", unconfiguredHandsOverToConfigured),
            ("a configured successor leaves a stale notConfigured pause and resumes the same business id", configuredSuccessorLeavesStalePause),
            ("a configured successor leaving a stale notConfigured pause still fences a rebind", configuredSuccessorKeepsPrincipalFence),
            ("a configured successor never clears a not-linked, invalid-session or no-session pause", configuredSuccessorKeepsAuthPauses),
            ("explicit logout and final logout purge exactly the owned pre-origin stores", explicitRemovalPurgesOwnedPreOriginStores),
            ("launch reconciliation never touches the pre-origin root, not even with no accounts", launchReconciliationLeavesPreOriginRoot),
            ("the current store never reads, sends, copies into or wipes the pre-origin root", currentStoreIgnoresPreOriginRoot),
            ("an acknowledged import on one origin never suppresses the same principal's offer on another", acknowledgedImportOnOneOriginNeverSuppressesAnother),
            ("a reserved, unacknowledged import identity is never replayed on another origin", reservedImportIdentityNeverReplaysOnAnotherOrigin),
            ("bare pre-origin import mappings never decide an offer and stay byte-identical", bareImportMappingsNeverDecideAndStayUntouched),
            ("quick add: a create with a Masʼul seals annotation null and chains one invitation.request sealed from the create's receipt; a draft annotation is never sealed; refused picks queue nothing", quickAddAssigneeSealsAnnotation)
    ]

    /// The realtime repository cases plus the realtime controller cases (`--realtime-only`).
    static let realtimeCases: [(String, () async throws -> Void)] = [
            ("realtime (repository): follows board, foreground, durable pause and purge", realtimeFollowsRepositoryLifecycle),
            ("realtime (repository): a 429 on a realtime call closes the shared account gate", realtimeRateLimitGatesRest),
            ("realtime (repository): rotation revalidates, re-bind replaces, account switch retires", realtimeSessionNotices),
            ("realtime (repository, real cycle): N hints within 250 ms make exactly one changes call", realtimeHintsCoalesceIntoOneRestCall),
            ("realtime (repository, real cycle): hints during a running cycle make exactly one follow-up", realtimeHintDuringCycleRunsOneFollowUp),
            ("realtime (repository, real cycle): a gated hint sends no REST before Retry-After", realtimeGatedHintWaitsForRetryAfter),
            ("realtime (repository, real cycle): background closes, foreground pulls at once and reconnects", realtimeForegroundPullsImmediately),
            ("realtime (repository, real socket): auth refusal pauses durably; linking reconnects; re-bind replaces the generation", realtimeRealSocketRefusalAndRebind),
            ("realtime (repository, real socket): a REST 429 holds both the metadata GET and the auth POST", realtimeRest429HoldsGetAndPost),
            ("realtime (repository, real socket): an auth POST 429 closes the shared REST gate", realtimeAuth429GatesRest),
            ("realtime (repository, real socket): a healthy connection asks no extra GET; rotation keeps it", realtimeHealthyConnectionNoExtraGet),
            ("realtime (repository): metadata 401/403 map to the durable session/link pauses", realtimeMetadataSessionRefusals),
            ("realtime (repository, real cycle): the kill switch keeps the truthful 60 s REST poll", realtimeDisabledKeepsRestPoll),
            ("realtime (repository, real cycle): persistent malformed metadata rests; the REST poll continues", realtimeMalformedMetadataRestsWhileRestPolls),
            ("realtime (repository, real socket): a protocol violation after establishment rests; the REST poll continues", realtimeProtocolViolationRestsWhileRestPolls)
    ] + SGTasksCloudRealtimeTests.cases

    // MARK: - Realtime wiring (scripted sockets, never a WebSocket)

    /// A harness whose repositories run realtime against a scripted service and manual clock.
    private static func realtimeHarness() throws -> (Harness, SGTasksRealtimeTestService, SGTasksRealtimeTestScheduler) {
        let harness = try Harness()
        let service = SGTasksRealtimeTestService()
        let scheduler = SGTasksRealtimeTestScheduler()
        harness.realtime = SGTasksCloudRealtimeEnvironment(service: service, makeScheduler: { _ in scheduler }, random: { 1.0 })
        return (harness, service, scheduler)
    }

    /// Runs every block the controller hopped onto the repository queue.
    private static func flush(_ repository: SGTasksCloudRepository) {
        repository.onQueue {}
    }

    /// Board started → GET → socket → fresh auth → subscribed; returns the live socket.
    private static func goLive(_ repository: SGTasksCloudRepository, _ service: SGTasksRealtimeTestService) throws -> SGTasksRealtimeTestSocket {
        let gets = service.metadataCompletions.count
        repository.start()
        flush(repository)
        try check(service.metadataCompletions.count == gets + 1, "Starting the board asked no realtime metadata")
        service.metadataCompletions.last!(.success(realtimeEnabled()))
        flush(repository)
        guard let socket = service.lastSocket, socket.started == 1, socket.stopped == 0 else { throw CloudTestFailure.assertion("No socket opened") }
        socket.requestAuthorization()
        flush(repository)
        service.authorizeCalls.last!.completion(.success(realtimeSubscription()))
        flush(repository)
        try check(socket.delivered.count == 1, "The authorization never reached the socket")
        socket.events(.subscribed)
        flush(repository)
        try check(repository.realtimeStatus == .live, "Not live after the subscription: \(repository.realtimeStatus)")
        return socket
    }

    private static func realtimeFollowsRepositoryLifecycle() async throws {
        let (harness, service, _) = try realtimeHarness()
        // The registry instance, so the explicit logout path (`purgeAccount`) reaches it; the static
        // environment is restored for the cases that follow.
        let savedEnvironment = SGTasksCloudRepository.environment
        defer { SGTasksCloudRepository.environment = savedEnvironment }
        SGTasksCloudRepository.environment = harness.environment
        let repository = SGTasksCloudRepository.repository(accountPeerId: 42)
        try await harness.bootstrap(repository)
        try check(service.metadataCompletions.isEmpty && repository.realtimeStatus == .off, "Realtime ran before the board was visible")

        let socket = try goLive(repository, service)
        repository.stop()
        try check(socket.stopped == 1 && repository.realtimeStatus == .off, "Leaving the board kept the socket")

        let second = try goLive(repository, service)
        repository.applicationDidEnterBackground()
        try check(second.stopped == 1 && repository.realtimeStatus == .off, "Background kept the socket")
        second.events(.invalidated)
        second.events(.subscribed)
        flush(repository)
        try check(repository.realtimeStatus == .off, "A late callback after background reported live")
        let gets = service.metadataCompletions.count
        repository.applicationWillEnterForeground()
        try check(service.metadataCompletions.count == gets + 1, "Foreground did not start a fresh attempt")
        service.metadataCompletions.last!(.success(realtimeEnabled()))
        flush(repository)
        let third = try service.lastSocket.orThrow("No socket after foreground")
        third.requestAuthorization()
        flush(repository)

        // tasks_account_not_linked on the auth POST: the repository's durable pause, no retry.
        let refusal = SGTasksError(kind: .accountNotLinked, retryAfter: nil, serverTime: nil, outcomeUnknown: false)
        service.authorizeCalls.last!.completion(.failure(refusal))
        third.events(.closed(.authorization(refusal)))
        flush(repository)
        try check(repository.state.phase == .pausedNotLinked, "The realtime refusal did not pause the account: \(repository.state.phase)")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'pause' AND value = 'not_linked';") == 1, "The pause is not durable")
        try check(repository.realtimeStatus == .off, "A paused account kept realtime")
        let pausedGets = service.metadataCompletions.count
        repository.start()
        flush(repository)
        try check(service.metadataCompletions.count == pausedGets, "A paused account reconnected")

        // Explicit logout: the account is purged; its socket closes and nothing late acts.
        repository.resumeAfterLinking()
        flush(repository)
        service.metadataCompletions.last!(.success(realtimeEnabled()))
        flush(repository)
        let fourth = try service.lastSocket.orThrow("No socket after linking")
        try check(fourth.started == 1, "Linking did not reconnect")
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
        try check(fourth.stopped == 1 && repository.realtime == nil, "Purge kept the socket")
        let sockets = service.sockets.count
        let authorizations = service.authorizeCalls.count
        fourth.requestAuthorization()
        fourth.events(.subscribed)
        flush(repository)
        try check(service.authorizeCalls.count == authorizations && service.sockets.count == sockets, "A purged account's late socket callback acted")
    }

    private static func realtimeRateLimitGatesRest() async throws {
        let (harness, service, _) = try realtimeHarness()
        let repository = harness.repository()
        defer { repository.stop() }
        try await harness.bootstrap(repository)
        repository.start()
        flush(repository)
        let calls = harness.server.callCount
        let limited = SGTasksError(kind: .rateLimited, retryAfter: 120, serverTime: nil, outcomeUnknown: false)
        service.metadataCompletions.last!(.failure(limited))
        flush(repository)
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'not_before_reason' AND value = 'rate_limited';") == 1, "The realtime 429 did not close the shared account gate")
        await repository.syncNow()
        try check(harness.server.callCount == calls, "A REST call went out before the shared Retry-After")
        if case .rateLimited = repository.state.phase {} else {
            throw CloudTestFailure.assertion("The board does not say rate limited: \(repository.state.phase)")
        }
        try check(repository.realtimeStatus == .fallback, "Realtime is not honest about the REST fallback")
    }

    private static func realtimeSessionNotices() async throws {
        let (harness, service, _) = try realtimeHarness()
        let notice = Notification.Name("sgtasks-realtime-session-\(UUID().uuidString)")
        harness.server.sessionNotice = notice
        let repository = harness.repository()
        defer { repository.stop() }
        try await harness.bootstrap(repository)
        let socket = try goLive(repository, service)

        // A notice with an unchanged session does nothing.
        harness.notificationCenter.post(name: notice, object: nil)
        flush(repository)
        try check(socket.revalidations == 0, "An unchanged session revalidated")

        // Refresh rotation (same principal, new marker): revalidate in place, still live.
        service.marker = SGTasksRealtime.SessionMarker(refreshToken: "r2", accountId: "acc", deviceId: "dev")
        harness.notificationCenter.post(name: notice, object: nil)
        flush(repository)
        try check(socket.revalidations == 1 && socket.stopped == 0 && repository.realtimeStatus == .live, "Rotation did not revalidate the live socket in place")

        // Same-principal re-bind: the revalidation returned another channel.
        socket.events(.closed(.channelChanged))
        flush(repository)
        try check(repository.realtimeStatus == .connecting, "The old generation is still reported live")
        try check(service.metadataCompletions.count == 2, "The re-bind did not start a fresh attempt")
        service.metadataCompletions.last!(.success(realtimeEnabled()))
        flush(repository)
        let rebound = try service.lastSocket.orThrow("No socket after the re-bind")
        socket.events(.subscribed)
        flush(repository)
        try check(repository.realtimeStatus == .connecting, "The old generation's late event reported live")

        // Account switch: another principal is bound; the socket goes and the store is fenced.
        harness.server.principalValue = principalB
        harness.notificationCenter.post(name: notice, object: nil)
        flush(repository)
        try check(rebound.stopped == 1, "The previous principal's socket survived the account switch")
        try check(service.metadataCompletions.count == 3, "No attempt under the new principal")
        rebound.requestAuthorization()
        flush(repository)
        try check(service.authorizeCalls.count == 1, "The previous principal's socket started an authorization")
    }

    // MARK: - Realtime behavior through the real cycle and the real socket

    private static func realSocketHarness(automatic: Bool) throws -> (Harness, SGTasksRealtimeSocketTestService, SGTasksRealtimeTestScheduler) {
        let harness = try Harness()
        harness.automaticSync = automatic
        let service = SGTasksRealtimeSocketTestService()
        let scheduler = SGTasksRealtimeTestScheduler()
        harness.realtime = SGTasksCloudRealtimeEnvironment(service: service, makeScheduler: { _ in scheduler }, random: { 1.0 })
        // One manual clock for realtime timers AND the repository's REST poll.
        harness.pollScheduler = scheduler
        return (harness, service, scheduler)
    }

    /// Bounded wait for asynchronous cycle work (`runCycles` runs in a `Task`).
    private static func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 3000 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CloudTestFailure.assertion("Timed out waiting for: \(what)")
    }

    private static func isIdle(_ repository: SGTasksCloudRepository) -> Bool {
        return repository.onQueue { !repository.isCycleRunning }
    }

    /// The manual clock runs its actions on the repository queue, as the dispatch scheduler would.
    private static func advance(_ repository: SGTasksCloudRepository, _ scheduler: SGTasksRealtimeTestScheduler, by interval: TimeInterval) {
        repository.onQueue {
            scheduler.advance(by: interval)
        }
    }

    /// The board is started and its metadata GET is pending: answer it and bring the REAL socket to
    /// `subscribed` (established → fresh auth POST → exact subscribe → subscription_succeeded).
    private static func connectReal(_ repository: SGTasksCloudRepository, _ service: SGTasksRealtimeSocketTestService) throws -> SGTasksRealtimeTestWebSocket {
        guard let metadata = service.metadataCompletions.last else { throw CloudTestFailure.assertion("No metadata GET pending") }
        let sockets = service.webSockets.count
        metadata(.success(realtimeEnabled()))
        flush(repository)
        guard service.webSockets.count == sockets + 1, let webSocket = service.webSockets.last else { throw CloudTestFailure.assertion("No real socket opened") }
        try check(webSocket.requests.first?.allHTTPHeaderFields == ["Origin": "https://tasks-x.example.org"], "The handshake carried more than the canonical Origin")
        let authorizations = service.authorizeCalls.count
        webSocket.establish()
        flush(repository)
        try check(service.authorizeCalls.count == authorizations + 1, "The established socket did not ask a fresh authorization")
        service.authorizeCalls.last!.completion(.success(realtimeSubscription()))
        flush(repository)
        try check(webSocket.sent.contains { $0.contains("pusher:subscribe") && $0.contains("private-tasks." + String(repeating: "A", count: 43)) }, "The socket did not subscribe to the exact channel")
        webSocket.frame(realtimeSubscribedFrame())
        flush(repository)
        try check(repository.realtimeStatus == .live, "Not live after subscription_succeeded: \(repository.realtimeStatus)")
        return webSocket
    }

    /// Bootstrapped, started, idle, then live: returns the socket and the changes count after the
    /// subscription's immediate repair pull.
    private static func liveRealCycle(_ harness: Harness, _ repository: SGTasksCloudRepository, _ service: SGTasksRealtimeSocketTestService) async throws -> (SGTasksRealtimeTestWebSocket, Int) {
        try await harness.bootstrap(repository)
        repository.start()
        flush(repository)
        try await waitFor("the start cycle") { isIdle(repository) }
        let beforeSubscribe = harness.server.changesCount
        let webSocket = try connectReal(repository, service)
        try await waitFor("the subscription's immediate REST repair") { harness.server.changesCount == beforeSubscribe + 1 && isIdle(repository) }
        return (webSocket, harness.server.changesCount)
    }

    private static func realtimeHintsCoalesceIntoOneRestCall() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: true)
        let repository = harness.repository()
        defer { repository.stop() }
        let (webSocket, base) = try await liveRealCycle(harness, repository, service)

        webSocket.frame(realtimeHintFrame())
        webSocket.frame(realtimeHintFrame())
        flush(repository)
        advance(repository, scheduler, by: 0.125)
        webSocket.frame(realtimeHintFrame())
        flush(repository)
        advance(repository, scheduler, by: 0.0625)
        try await waitFor("idle") { isIdle(repository) }
        try check(harness.server.changesCount == base, "A hint reached REST before the 250 ms window closed")
        advance(repository, scheduler, by: 0.0625)
        try await waitFor("one coalesced changes call") { harness.server.changesCount == base + 1 && isIdle(repository) }
        advance(repository, scheduler, by: 1)
        try await waitFor("idle") { isIdle(repository) }
        try check(harness.server.changesCount == base + 1, "Three hints made more than one changes call")

        webSocket.frame(realtimeHintFrame())
        flush(repository)
        advance(repository, scheduler, by: 0.25)
        try await waitFor("a later hint's changes call") { harness.server.changesCount == base + 2 && isIdle(repository) }
        try check(harness.server.sent.isEmpty, "A hint sent a mutation")
    }

    private static func realtimeHintDuringCycleRunsOneFollowUp() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: true)
        let repository = harness.repository()
        defer { repository.stop() }
        let (webSocket, base) = try await liveRealCycle(harness, repository, service)
        let latch = SGTasksTestLatch()
        harness.server.changesHold = { await latch.wait() }
        webSocket.frame(realtimeHintFrame())
        flush(repository)
        advance(repository, scheduler, by: 0.25)
        try await waitFor("a changes call in flight") { latch.isWaiting }
        for _ in 0 ..< 2 {
            webSocket.frame(realtimeHintFrame())
            flush(repository)
            advance(repository, scheduler, by: 0.25)
        }
        try check(harness.server.changesCount == base + 1, "A hint started a second concurrent cycle")
        harness.server.changesHold = nil
        latch.open()
        try await waitFor("exactly one follow-up cycle") { harness.server.changesCount == base + 2 && isIdle(repository) }
        advance(repository, scheduler, by: 1)
        try await waitFor("idle") { isIdle(repository) }
        try check(harness.server.changesCount == base + 2, "Hints during a running cycle made more than one follow-up")
    }

    private static func realtimeGatedHintWaitsForRetryAfter() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: true)
        let repository = harness.repository()
        defer { repository.stop() }
        let (webSocket, base) = try await liveRealCycle(harness, repository, service)
        harness.server.changesScript = [failure(.rateLimited, retryAfter: 120)]
        webSocket.frame(realtimeHintFrame())
        flush(repository)
        advance(repository, scheduler, by: 0.25)
        try await waitFor("the rate-limited changes call") { harness.server.changesCount == base + 1 && isIdle(repository) }
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'not_before_reason' AND value = 'rate_limited';") == 1, "The 429 did not close the shared gate")

        webSocket.frame(realtimeHintFrame())
        flush(repository)
        advance(repository, scheduler, by: 0.25)
        try await waitFor("idle") { isIdle(repository) }
        try check(harness.server.changesCount == base + 1, "A hint bypassed the shared Retry-After")
        try check(repository.realtimeStatus == .live, "A REST 429 tore down a healthy socket")

        harness.clock = harness.clock.addingTimeInterval(121)
        webSocket.frame(realtimeHintFrame())
        flush(repository)
        advance(repository, scheduler, by: 0.25)
        try await waitFor("the hint after Retry-After") { harness.server.changesCount == base + 2 && isIdle(repository) }
    }

    private static func realtimeForegroundPullsImmediately() async throws {
        let (harness, service, _) = try realSocketHarness(automatic: true)
        let repository = harness.repository()
        defer { repository.stop() }
        let (webSocket, base) = try await liveRealCycle(harness, repository, service)
        repository.applicationDidEnterBackground()
        try check(webSocket.closeCount == 1 && repository.realtimeStatus == .off, "Background kept the socket")
        let gets = service.metadataCompletions.count
        repository.applicationWillEnterForeground()
        try await waitFor("the foreground REST repair") { harness.server.changesCount == base + 1 && isIdle(repository) }
        try check(service.metadataCompletions.count == gets + 1, "Foreground did not start a fresh realtime attempt")
        _ = try connectReal(repository, service)
        try await waitFor("the reconnect's REST repair") { harness.server.changesCount == base + 2 && isIdle(repository) }
    }

    private static func realtimeRealSocketRefusalAndRebind() async throws {
        let (harness, service, _) = try realSocketHarness(automatic: false)
        let notice = Notification.Name("sgtasks-realtime-real-\(UUID().uuidString)")
        harness.server.sessionNotice = notice
        let repository = harness.repository()
        defer { repository.stop() }
        try await harness.bootstrap(repository)
        repository.start()
        flush(repository)
        service.metadataCompletions.last!(.success(realtimeEnabled()))
        flush(repository)
        let refused = try service.webSockets.last.orThrow("No socket")
        refused.establish()
        flush(repository)
        service.authorizeCalls.last!.completion(.failure(SGTasksError(kind: .accountNotLinked, retryAfter: nil, serverTime: nil, outcomeUnknown: false)))
        flush(repository)
        flush(repository)
        try check(refused.closeCount == 1 && !refused.sent.contains { $0.contains("pusher:subscribe") }, "A refused authorization subscribed or kept the socket")
        try check(repository.state.phase == .pausedNotLinked, "The auth refusal did not pause: \(repository.state.phase)")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'pause' AND value = 'not_linked';") == 1, "The pause is not durable")
        try check(repository.realtimeStatus == .off && service.metadataCompletions.count == 1, "A paused account kept or retried realtime")

        repository.resumeAfterLinking()
        flush(repository)
        let live = try connectReal(repository, service)
        try check(service.metadataCompletions.count == 2, "Linking did not start exactly one fresh attempt")

        // Same-principal re-bind: the session notice revalidates the SAME socket id; the server
        // answers another channel (new generation) and the old socket is replaced.
        service.marker = SGTasksRealtime.SessionMarker(refreshToken: "r1", accountId: "acc", deviceId: "dev-rebound")
        harness.notificationCenter.post(name: notice, object: nil)
        flush(repository)
        try check(service.authorizeCalls.count == 3 && service.authorizeCalls[2].socketId == SGTasksRealtime.SocketId("123.456")!, "The re-bind did not re-authorize the same socket id")
        service.authorizeCalls[2].completion(.success(realtimeSubscription(token: "C")))
        flush(repository)
        flush(repository)
        try check(live.closeCount == 1, "The old generation's socket stayed open")
        try check(repository.realtimeStatus == .connecting && service.metadataCompletions.count == 3, "The re-bind did not reconnect with a fresh attempt")
        live.frame(realtimeHintFrame())
        live.frame(realtimeSubscribedFrame())
        flush(repository)
        try check(repository.realtimeStatus == .connecting, "The closed old generation reported live")
    }

    private static func realtimeRest429HoldsGetAndPost() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: false)
        let repository = harness.repository()
        defer { repository.stop() }
        try await harness.bootstrap(repository)
        harness.server.changesScript = [failure(.rateLimited, retryAfter: 120)]
        await repository.syncNow()
        repository.start()
        flush(repository)
        try check(service.metadataCompletions.isEmpty, "The metadata GET went out under the shared Retry-After")
        try check(repository.realtimeStatus == .fallback, "A gated realtime attempt is not REST fallback")

        harness.clock = harness.clock.addingTimeInterval(121)
        advance(repository, scheduler, by: 121)
        try check(service.metadataCompletions.count == 1, "No metadata GET after Retry-After")
        service.metadataCompletions[0](.success(realtimeEnabled()))
        flush(repository)
        let webSocket = try service.webSockets.last.orThrow("No socket")

        // The gate closes again between the GET and the socket's authorization: no POST.
        harness.server.changesScript = [failure(.rateLimited, retryAfter: 120)]
        await repository.syncNow()
        webSocket.establish()
        flush(repository)
        flush(repository)
        try check(service.authorizeCalls.isEmpty, "The auth POST went out under the shared Retry-After")
        try check(webSocket.closeCount == 1 && repository.realtimeStatus == .fallback, "The gated socket was kept")
    }

    private static func realtimeAuth429GatesRest() async throws {
        let (harness, service, _) = try realSocketHarness(automatic: false)
        let repository = harness.repository()
        defer { repository.stop() }
        try await harness.bootstrap(repository)
        repository.start()
        flush(repository)
        service.metadataCompletions.last!(.success(realtimeEnabled()))
        flush(repository)
        let webSocket = try service.webSockets.last.orThrow("No socket")
        webSocket.establish()
        flush(repository)
        service.authorizeCalls.last!.completion(.failure(SGTasksError(kind: .rateLimited, retryAfter: 90, serverTime: nil, outcomeUnknown: false)))
        flush(repository)
        flush(repository)
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'not_before_reason' AND value = 'rate_limited';") == 1, "The auth POST 429 did not close the shared gate")
        let calls = harness.server.callCount
        await repository.syncNow()
        try check(harness.server.callCount == calls, "REST went out before the auth POST's Retry-After")
        try check(webSocket.closeCount == 1 && repository.realtimeStatus == .fallback, "The refused socket was kept or reported live")
    }

    private static func realtimeHealthyConnectionNoExtraGet() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: false)
        let notice = Notification.Name("sgtasks-realtime-healthy-\(UUID().uuidString)")
        harness.server.sessionNotice = notice
        let repository = harness.repository()
        defer { repository.stop() }
        try await harness.bootstrap(repository)
        repository.start()
        flush(repository)
        let webSocket = try connectReal(repository, service)
        let sentBefore = webSocket.sent.count
        advance(repository, scheduler, by: 30)
        try check(webSocket.sent.count == sentBefore + 1 && webSocket.sent.last?.contains("pusher:ping") == true, "No application ping after the activity timeout")
        webSocket.frame(#"{"event":"pusher:pong"}"#)
        flush(repository)
        advance(repository, scheduler, by: 59)
        try check(webSocket.closeCount == 0 && repository.realtimeStatus == .live, "An answered heartbeat closed the connection")

        // Refresh rotation: same principal, new marker → the same socket id re-authorizes, same
        // channel → kept.
        service.marker = SGTasksRealtime.SessionMarker(refreshToken: "r2", accountId: "acc", deviceId: "dev")
        harness.notificationCenter.post(name: notice, object: nil)
        flush(repository)
        try check(service.authorizeCalls.count == 2, "Rotation did not revalidate")
        service.authorizeCalls[1].completion(.success(realtimeSubscription()))
        flush(repository)
        try check(webSocket.closeCount == 0 && repository.realtimeStatus == .live, "Rotation dropped a healthy connection")
        try check(service.metadataCompletions.count == 1, "A healthy connection asked GET /realtime again")
    }

    private static func realtimeMetadataSessionRefusals() async throws {
        let cases: [(SGTasksError.Kind, String, SGTasksCloudState.Phase)] = [
            (.session(.invalidToken), "session_invalid", .sessionInvalid),
            (.accountNotLinked, "not_linked", .pausedNotLinked)
        ]
        for (kind, pause, phase) in cases {
            let (harness, service, _) = try realtimeHarness()
            let repository = harness.repository()
            do {
                // Stopped even when an assertion throws.
                defer { repository.stop() }
                try await harness.bootstrap(repository)
                repository.start()
                flush(repository)
                service.metadataCompletions.last!(.failure(SGTasksError(kind: kind, retryAfter: nil, serverTime: nil, outcomeUnknown: false)))
                flush(repository)
                try check(repository.state.phase == phase, "\(kind): repository phase \(repository.state.phase)")
                try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'pause' AND value = '\(pause)';") == 1, "\(kind): the pause is not durable")
                try check(repository.realtimeStatus == .off && service.sockets.isEmpty && service.metadataCompletions.count == 1, "\(kind): realtime kept trying")
            }
        }
    }

    /// Advances the shared manual clock by one poll interval and waits for the poll's REST cycle.
    private static func pollOnce(_ harness: Harness, _ repository: SGTasksCloudRepository, _ scheduler: SGTasksRealtimeTestScheduler) async throws {
        let before = harness.server.changesCount
        advance(repository, scheduler, by: harness.pollInterval - 1)
        try await waitFor("idle before the poll is due") { isIdle(repository) }
        try check(harness.server.changesCount == before, "REST polled before its interval")
        advance(repository, scheduler, by: 1)
        try await waitFor("the REST poll") { harness.server.changesCount == before + 1 && isIdle(repository) }
    }

    private static func realtimeDisabledKeepsRestPoll() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: true)
        harness.pollInterval = 60
        let repository = harness.repository()
        defer {
            repository.stop()
            scheduler.cancelAll()
        }
        try await harness.bootstrap(repository)
        repository.start()
        flush(repository)
        service.metadataCompletions.last!(.success(SGTasksRealtime.Metadata(availability: .disabled, activityTimeout: 30)))
        flush(repository)
        try check(repository.realtimeStatus == .disabled && service.webSockets.isEmpty, "The kill switch is not reported truthfully")
        try await waitFor("the start cycle") { isIdle(repository) }
        // The repository's own 60 s poll keeps the board current without any hint.
        try await pollOnce(harness, repository, scheduler)
        try await pollOnce(harness, repository, scheduler)
        try check(repository.realtimeStatus == .disabled && service.metadataCompletions.count == 1, "The poll touched the realtime state")
    }

    /// A 200 metadata body that breaks the wire is deterministic: realtime rests (no GET/POST
    /// growth) while the REST poll carries on.
    private static func realtimeMalformedMetadataRestsWhileRestPolls() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: true)
        harness.pollInterval = 60
        let repository = harness.repository()
        defer {
            repository.stop()
            scheduler.cancelAll()
        }
        try await harness.bootstrap(repository)
        repository.start()
        flush(repository)
        service.metadataCompletions.last!(.failure(SGTasksError(kind: .malformedResponse, retryAfter: nil, serverTime: nil, outcomeUnknown: false)))
        flush(repository)
        try await waitFor("the start cycle") { isIdle(repository) }
        try check(repository.realtimeStatus == .fallback, "Malformed metadata is not reported as REST fallback")
        for _ in 0 ..< 5 {
            try await pollOnce(harness, repository, scheduler)
        }
        try check(service.metadataCompletions.count == 1 && service.authorizeCalls.isEmpty && service.webSockets.isEmpty, "Malformed metadata kept spending the reads budget")
        // The next foreground is a fresh, single attempt.
        repository.applicationDidEnterBackground()
        repository.applicationWillEnterForeground()
        try check(service.metadataCompletions.count == 2, "Foreground did not start exactly one fresh attempt after rest")
    }

    /// An invalid frame after the connection was established is deterministic too.
    private static func realtimeProtocolViolationRestsWhileRestPolls() async throws {
        let (harness, service, scheduler) = try realSocketHarness(automatic: true)
        harness.pollInterval = 60
        let repository = harness.repository()
        defer {
            repository.stop()
            scheduler.cancelAll()
        }
        let (webSocket, _) = try await liveRealCycle(harness, repository, service)
        webSocket.frame("not a pusher frame")
        flush(repository)
        try check(webSocket.closeCount == 1 && repository.realtimeStatus == .fallback, "A protocol violation kept the socket or claimed live")
        for _ in 0 ..< 5 {
            try await pollOnce(harness, repository, scheduler)
        }
        try check(service.metadataCompletions.count == 1 && service.authorizeCalls.count == 1 && service.webSockets.count == 1, "A deterministic violation kept reconnecting")
    }

    private static func atomicEnqueueSurvivesRestart() async throws {
        let harness = try Harness()
        var repository: SGTasksCloudRepository? = harness.repository()
        try await harness.bootstrap(repository!)
        let id = try repository!.createTask(SGTasksCloudTaskDraft(title: "  Buy milk \n"))
        try expectError(.invalidTitle) { _ = try repository!.createTask(SGTasksCloudTaskDraft(title: "\u{200B}")) }
        let state = repository!.state
        try check(state.tasks.count == 1 && state.tasks[0].title == "Buy milk" && state.tasks[0].isPending, "Optimistic row missing")
        try check(state.entries.count == 1 && state.entries[0].status == .queued, "Enqueue did not commit with the row")
        let before = try harness.outboxBodies()
        repository = nil
        let reopened = harness.repository()
        try check(reopened.state.tasks.map { $0.id } == [id], "Restart lost the optimistic task")
        try check(try harness.outboxBodies() == before, "Restart changed the sealed bytes")
        let leaked = try harness.cloudScalar("SELECT COUNT(*) FROM outbox WHERE CAST(body AS TEXT) LIKE '%creation_proof%' OR CAST(body AS TEXT) LIKE '%jws%';")
        try check(leaked == 0, "Outbox persisted transport evidence")
        let request = try SGTasksWire.MutationRequest(wireJSON: before[0])
        try check(request.operation.kind == .taskCreate, "Persisted bytes are not the task.create mutation")
    }

    private static func sealedReplay() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        let id = try repository.createTask(SGTasksCloudTaskDraft(title: "Replay"))
        await repository.syncNow()
        try check(harness.server.sent.count == 1 && repository.state.entries[0].status == .queued && repository.state.entries[0].attempts == 1, "Timeout not retried later")
        await repository.syncNow()
        try check(harness.server.sent.count == 1, "Backoff did not delay the retry")
        harness.clock = harness.clock.addingTimeInterval(600)
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        harness.server.changesScript = [changesPage([]), changesPage([upsert(ownerTask(id, rev: "1", title: "Replay"))])]
        await repository.syncNow()
        try check(harness.server.sent.count == 2 && harness.server.sent[0].wireJSON == harness.server.sent[1].wireJSON, "Retry changed the business identity")
        try check(repository.state.entries.isEmpty && repository.state.tasks.first?.revision?.rawValue == "1" && repository.state.tasks.first?.isPending == false, "Acknowledged create not reconciled")

        // A crash while sending: the row returns to the queue with the same bytes.
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Crash"))
        let stored = try harness.outboxBodies()
        try harness.cloudExecute("UPDATE outbox SET state = 'sending', sent_once = 1;")
        let restarted = harness.repository()
        try check(restarted.state.entries.first?.status == .queued, "Interrupted send not requeued")
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        await restarted.syncNow()
        try check(harness.server.sent.last?.wireJSON == stored.first, "Resend after crash changed the bytes")
    }

    private static func snapshotStaging() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate(), c = SGTasksWire.UUID.generate(), l = SGTasksWire.UUID.generate()
        harness.server.snapshotScript = [
            .success(SGTasksWire.SnapshotResponse(items: [ownerTask(a, rev: "1", title: "A"), ownerTask(b, rev: "1", title: "B")], nextCursor: cursor("p2"), changesCursor: cursor("c-S"), serverTime: instant())),
            .success(SGTasksWire.SnapshotResponse(items: [list(l, rev: "1", title: "L")], nextCursor: nil, changesCursor: cursor("c-S"), serverTime: instant()))
        ]
        harness.server.changesScript = [changesPage([remove(.task(b)), upsert(ownerTask(c, rev: "1", title: "C"))], next: "c-H")]
        await repository.syncNow()
        try check(Set(repository.state.tasks.map { $0.id }) == [a, c] && repository.state.lists.map { $0.id } == [l], "Post-watermark delta not applied before reconcile")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'changes_cursor' AND value = 'c-H';") == 1, "Cursor did not advance to the delta watermark")

        let pending = try repository.createTask(SGTasksCloudTaskDraft(title: "Local only"))
        try harness.cloudExecute("UPDATE outbox SET state = 'held', hold_token = 'x';") // keep it unsent during this case
        harness.server.changesScript = [failure(.resyncRequired)]
        harness.server.snapshotScript = [
            .success(SGTasksWire.SnapshotResponse(items: [ownerTask(a, rev: "2", title: "A2")], nextCursor: cursor("p2"), changesCursor: cursor("c-T"), serverTime: instant())),
            failure(.unavailable)
        ]
        await repository.syncNow()
        try check(Set(repository.state.tasks.map { $0.id }) == [a, c, pending] && repository.state.tasks.first(where: { $0.id == a })?.title == "A", "Incomplete pagination changed the shadow")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox;") == 1, "Incomplete pagination touched the outbox")
        guard case let .unavailable(retryAt) = repository.state.phase, let retryAt = retryAt else {
            throw CloudTestFailure.assertion("Incomplete snapshot did not expose its retry deadline")
        }
        let callsBeforeRetry = harness.server.callCount
        await repository.syncNow()
        try check(harness.server.callCount == callsBeforeRetry, "Incomplete snapshot bypassed its retry gate")
        harness.clock = retryAt

        try harness.cloudExecute("UPDATE outbox SET state = 'queued', hold_token = NULL;")
        harness.server.snapshotScript = [.success(SGTasksWire.SnapshotResponse(items: [ownerTask(a, rev: "2", title: "A2")], nextCursor: nil, changesCursor: cursor("c-U"), serverTime: instant()))]
        harness.server.mutationScript = [{ _ in failure(.unavailable, retryAfter: 30) }]
        await repository.syncNow()
        let ids = Set(repository.state.tasks.map { $0.id })
        try check(ids == [a, pending] && repository.state.tasks.first(where: { $0.id == a })?.title == "A2", "Complete resnapshot did not reconcile, or dropped a pending local create")
    }

    private static func dependencyOrdering() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        let listId = try repository.createList(title: "Ishlar")
        let taskId = try repository.createTask(SGTasksCloudTaskDraft(listId: listId, title: "Hisobot"))
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(listId: listId, title: "Hisobot 2"))
        harness.server.mutationScript = [{ ack($0, revision: "1") }, { ack($0, revision: "1") }, { ack($0, revision: "2") }]
        await repository.syncNow()
        let kinds = harness.server.sent.map { $0.operation.kind }
        try check(kinds == [.listCreate, .taskCreate, .taskUpdate], "Dependents were sent before their acknowledged creates: \(kinds)")
        try check(baseRevision(harness.server.sent[2].operation) == "1", "Dependent update was not sealed with the create receipt revision")
        if case let .taskUpdate(op) = harness.server.sent[2].operation {
            try check(op.content.title == "Hisobot 2" && op.content.listId == listId, "Dependent update content changed")
        }
    }

    private static func creationRefusal() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        let listId = try repository.createList(title: "Blocked")
        _ = try repository.createTask(SGTasksCloudTaskDraft(listId: listId, title: "Inside"))
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Independent"))
        harness.server.mutationScript = [{ _ in failure(.creationNotPermitted) }, { ack($0, revision: "1") }]
        await repository.syncNow()
        try check(harness.server.sent.map { $0.operation.kind } == [.listCreate, .taskCreate], "Independent chain did not continue")
        if case let .taskCreate(op) = harness.server.sent[1].operation {
            try check(op.content.listId == nil, "Dependent of the refused list was sent")
        }
        let statuses = repository.state.entries.map { $0.status }
        try check(statuses.contains(.creationNotPermitted) && statuses.contains(.waitingForDependency), "Blocked draft / dependency state missing: \(statuses)")
        try check(repository.state.lists.first?.problem == .creationNotPermitted, "Blocked list not flagged")
        let sentBefore = harness.server.sent.count
        await repository.syncNow()
        try check(harness.server.sent.count == sentBefore, "Refused creation was retried automatically")
        let blocked = repository.state.entries.first { $0.status == .creationNotPermitted }!
        try check(blocked.allowedActions == [.retry, .discard], "Blocked draft actions")
        try check(repository.onQueue({ repository.nextSendDate() }) == nil, "Blocked chains still wake the scheduler")
        try repository.retry(entryId: blocked.id)
        harness.server.mutationScript = [{ ack($0, revision: "1") }, { ack($0, revision: "1") }]
        await repository.syncNow()
        try check(harness.server.sent[sentBefore].mutationId == harness.server.sent[0].mutationId, "Explicit retry did not reuse the unchanged id")
        try check(harness.server.sent.last?.operation.kind == .taskCreate, "Dependent did not follow the accepted list")
    }

    private static func conflictResolution() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let taskId = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [ownerTask(taskId, rev: "2", title: "Old")])
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "Mine"))
        harness.server.mutationScript = [{ _ in failure(.conflict(.revisionChanged)) }]
        await repository.syncNow()
        let conflicted = repository.state.entries[0]
        try check(conflicted.status == .conflict(.revisionChanged), "Conflict not surfaced")
        try check(repository.state.tasks[0].title == "Old" && repository.state.tasks[0].problem == .conflict(.revisionChanged), "Stale local change shown as accepted")
        harness.server.changesScript = [changesPage([upsert(ownerTask(taskId, rev: "3", title: "Theirs"))])]
        let sentBefore = harness.server.sent.count
        await repository.syncNow()
        try check(harness.server.sent.count == sentBefore, "Conflict resent without a user choice")
        try check(repository.state.tasks[0].title == "Theirs", "Re-fetch did not reveal the current row")
        try repository.reapplyOnCurrentVersion(entryId: conflicted.id)
        harness.server.mutationScript = [{ ack($0, revision: "4") }]
        await repository.syncNow()
        let resent = harness.server.sent.last!
        try check(resent.mutationId != harness.server.sent[0].mutationId && baseRevision(resent.operation) == "3", "Reapply did not use a new id on the fresh revision")
    }

    private static func refusalClasses() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        for title in ["a", "b", "c", "d"] {
            _ = try repository.createTask(SGTasksCloudTaskDraft(title: title))
        }
        harness.server.mutationScript = [{ _ in failure(.invalidRequest) }, { _ in failure(.mutationMismatch) }, { _ in failure(.rateLimited, retryAfter: 120) }]
        await repository.syncNow()
        try check(harness.server.sent.count == 3, "Rate limit did not stop the drain")
        let entries = repository.state.entries
        try check(entries[0].status == .invalid && entries[1].status == .integrityQuarantine && entries[2].status == .queued, "Refusals not separated")
        try check(entries[2].attempts == 0 && repository.state.phase == .rateLimited(retryAt: harness.clock.addingTimeInterval(120)), "429 spent a row attempt or no account gate")
        try expectError(.actionNotAllowed) { try repository.retry(entryId: entries[1].id) }
        // Account-wide Retry-After: neither an explicit refresh nor a new local change goes out early.
        let callsBefore = harness.server.callCount
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "e"))
        repository.refresh()
        await repository.syncNow()
        try check(harness.server.callCount == callsBefore, "A request bypassed the server Retry-After")
        harness.clock = harness.clock.addingTimeInterval(121)
        harness.server.mutationScript = [{ ack($0, revision: "1") }, { ack($0, revision: "1") }, { ack($0, revision: "1") }]
        await repository.syncNow()
        let lateTitles = harness.server.sent.suffix(3).compactMap { request -> String? in
            if case let .taskCreate(op) = request.operation { return op.content.title } else { return nil }
        }
        try check(lateTitles == ["c", "d", "e"], "Gate release did not resume the same rows in order: \(lateTitles)")
        let invalidId = harness.server.sent[0].mutationId
        try repository.repair(entryId: entries[0].id, taskDraft: SGTasksCloudTaskDraft(title: "a fixed"))
        let repaired = try SGTasksWire.MutationRequest(wireJSON: try harness.outboxBodies()[0])
        try check(repaired.mutationId != invalidId, "Repair reused the refused mutation id")

        let stalledHarness = try Harness()
        let stalled = stalledHarness.repository()
        try await stalledHarness.bootstrap(stalled)
        _ = try stalled.createTask(SGTasksCloudTaskDraft(title: "Offline"))
        for _ in 0 ..< 12 {
            await stalled.syncNow()
            stalledHarness.clock = stalledHarness.clock.addingTimeInterval(1000)
        }
        try check(stalledHarness.server.sent.count == SGTasksCloudRepository.maximumAutomaticAttempts, "Automatic retry is not bounded")
        try check(stalled.state.entries[0].status == .stalled, "Exhausted retries not surfaced as stalled")
    }

    private static func unlinkedPause() async throws {
        let harness = try Harness()
        var repository = harness.repository()
        let taskId = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [ownerTask(taskId, rev: "1", title: "Kept")])
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Waits"))
        harness.server.mutationScript = [{ _ in failure(.accountNotLinked) }]
        await repository.syncNow()
        try check(repository.state.phase == .pausedNotLinked, "Unlinked account not paused")
        try check(repository.state.entries[0].status == .queued && repository.state.entries[0].attempts == 0, "Pause counted as a failed attempt")
        try check(repository.state.tasks.contains { $0.id == taskId }, "Pause cleared the cache")
        let calls = harness.server.callCount
        await repository.syncNow()
        repository = harness.repository()
        await repository.syncNow()
        try check(harness.server.callCount == calls && repository.state.phase == .pausedNotLinked, "Paused account retried automatically")
        // An ordinary refresh (pull-to-refresh, retry button, rotation) never ends this pause.
        repository.refresh()
        await repository.syncNow()
        try check(harness.server.callCount == calls && repository.state.phase == .pausedNotLinked, "refresh() cleared the not-linked pause")
        repository.resumeAfterLinking()
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        await repository.syncNow()
        try check(harness.server.sent.count == 2 && harness.server.sent[0].mutationId == harness.server.sent[1].mutationId, "Resume after linking did not reuse the business id")
    }

    private static func sharedAccessLoss() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let shared = SGTasksWire.UUID.generate(), secondShared = SGTasksWire.UUID.generate()
        let invitation = SGTasksWire.UUID.generate(), secondInvitation = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [
            assignedTask(shared, rev: "4", title: "Owner private title", invitation: invitation),
            assignedTask(secondShared, rev: "1", title: "Second shared", invitation: secondInvitation)
        ])
        try expectError(.notOwner) { try repository.updateTask(id: shared, draft: SGTasksCloudTaskDraft(title: "x")) }
        try repository.setTaskCompleted(id: shared, isCompleted: true)
        harness.server.changesScript = [changesPage([remove(.task(shared))])]
        await repository.syncNow()
        try check(!repository.state.tasks.contains { $0.id == shared } && repository.state.entries.isEmpty, "Lost shared task or its command survived")
        try check(repository.state.notices.map { $0.kind } == [.sharedAccessLost], "No content-free access-loss notice")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM shadow WHERE CAST(body AS TEXT) LIKE '%Owner private title%';") == 0, "Shared content remained in the cache")
        // Removed shared content is folded out of the WAL as well (logical overwrite, not a physical erase).
        for suffix in ["", "-wal"] {
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: harness.files.path(accountPeerId: 42) + suffix))) ?? Data()
            try check(bytes.range(of: Data("Owner private title".utf8)) == nil, "Lost shared content still readable in the store file\(suffix)")
        }

        try repository.setTaskCompleted(id: secondShared, isCompleted: true)
        harness.server.mutationScript = [{ _ in failure(.notFound) }]
        await repository.syncNow()
        try check(!repository.state.tasks.contains { $0.id == secondShared } && repository.state.entries.isEmpty, "404 on a shared task kept an accessible copy")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM outbox;") == 0, "404 on a shared task kept its command")
    }

    private static func ownNotFound() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let taskId = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [ownerTask(taskId, rev: "1", title: "Server")])
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "Draft text"))
        harness.server.mutationScript = [{ _ in failure(.notFound) }]
        await repository.syncNow()
        let entry = repository.state.entries[0]
        try check(entry.status == .notFound && entry.allowedActions.contains(.recreateCopy), "Own 404 not surfaced")
        try check(repository.state.tasks[0].title == "Server" && repository.state.notices.map { $0.kind } == [.ownResourceMissing], "Overlay not dropped with notice")
        let copy = try repository.recreateAsNewCopy(entryId: entry.id)
        try check(copy != taskId && repository.state.tasks.contains { $0.id == copy && $0.title == "Draft text" }, "Copy is not a new create with the draft")
    }

    private static func heldDeleteLifecycle() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let t1 = SGTasksWire.UUID.generate(), t2 = SGTasksWire.UUID.generate(), t3 = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [ownerTask(t1, rev: "2", title: "One"), ownerTask(t2, rev: "1", title: "Two"), ownerTask(t3, rev: "1", title: "Three")])

        let undoable = try repository.deleteTask(id: t1)
        try check(!repository.state.tasks.contains { $0.id == t1 } && repository.state.entries[0].status == .held, "Held delete not applied locally")
        await repository.syncNow()
        try check(harness.server.sent.isEmpty, "Held delete was sent")
        try check(undoable.undo() && !undoable.isValid && repository.state.tasks.contains { $0.id == t1 } && repository.state.entries.isEmpty, "Undo did not restore atomically")
        try check(!undoable.undo(), "Undo handle worked twice")

        do {
            _ = try repository.deleteTask(id: t1)
        }
        try check(repository.state.entries.first?.status == .queued, "Handle deinit did not promote")
        try harness.clearOutbox(repository)

        let committed = try repository.deleteTask(id: t1)
        committed.commit()
        try check(!committed.undo() && repository.state.entries.first?.status == .queued, "Commit not exactly once")
        try harness.clearOutbox(repository)

        let background = try repository.deleteTask(id: t2)
        repository.promoteAllHolds()
        try check(!background.isValid && repository.state.entries.first?.status == .queued, "Background/departure did not promote")
        try harness.clearOutbox(repository)

        let survivor = try repository.deleteTask(id: t3)
        let restarted = harness.repository()
        try check(restarted.state.entries.first?.status == .queued, "Restart did not promote the surviving hold")
        try check(!survivor.undo(), "Stale handle undid after restart promotion")
        try harness.clearOutbox(repository)

        harness.holdDuration = 0.05
        let timed = harness.repository()
        let timeout = try timed.deleteTask(id: t2)
        try await Task.sleep(nanoseconds: 400_000_000)
        try check(!timeout.isValid && timed.state.entries.first?.status == .queued, "Timeout did not promote")
        try harness.clearOutbox(repository)

        let neverSent = harness.repository()
        let local = try neverSent.createTask(SGTasksCloudTaskDraft(title: "Never sent"))
        try neverSent.deleteTask(id: local).commit()
        try check(neverSent.state.entries.isEmpty && !neverSent.state.tasks.contains { $0.id == local }, "Never-sent create+delete did not cancel both")
        let sentBefore = harness.server.sent.count
        await neverSent.syncNow()
        try check(harness.server.sent.count == sentBefore, "Cancelled create/delete reached the network")
    }

    private static func heldDeleteConflict() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let taskId = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [ownerTask(taskId, rev: "2", title: "Before")])
        let handle = try repository.deleteTask(id: taskId)
        harness.server.changesScript = [changesPage([upsert(ownerTask(taskId, rev: "3", title: "Edited elsewhere"))])]
        await repository.syncNow()
        handle.commit()
        harness.server.mutationScript = [{ _ in failure(.conflict(.revisionChanged)) }]
        await repository.syncNow()
        try check(baseRevision(harness.server.sent[0].operation) == "2", "Promotion rebased the delete onto a later revision")
        try check(repository.state.tasks.first?.title == "Edited elsewhere" && repository.state.entries.first?.status == .conflict(.revisionChanged), "Conflict did not reveal the current row")
    }

    private static func purgeFencesLateResponse() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        let repository = SGTasksCloudRepository.repository(accountPeerId: 42)
        try await harness.bootstrap(repository)
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Private"))
        harness.server.onMutation = { _ in SGTasksCloudRepository.purgeAccount(accountPeerId: 42) }
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        await repository.syncNow()
        harness.server.onMutation = nil
        try check(!harness.files.storeExists(accountPeerId: 42) && !harness.files.hasPendingPurge(accountPeerId: 42), "Late response recreated the purged store")
        try check(repository.state == .empty, "Purged instance still exposes state")
        try expectError(.accountRemoved) { _ = try repository.createTask(SGTasksCloudTaskDraft(title: "After")) }
        let fresh = SGTasksCloudRepository.repository(accountPeerId: 42)
        try check(fresh !== repository && fresh.state.tasks.isEmpty && fresh.state.entries.isEmpty, "Re-login saw the old account's data")
        try check(SGTasksCloudRepository.unsentChangeCount(accountPeerId: 42) == 0, "Fresh store unsent count")
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
    }

    private static func purgeFailsClosed() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        _ = try SGTasksCloudRepository.repository(accountPeerId: 42).createTask(SGTasksCloudTaskDraft(title: "Must not reappear"))

        harness.fileSystem.failMove = true
        harness.fileSystem.failStoreRemove = true
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
        try check(harness.files.hasPendingPurge(accountPeerId: 42), "Failed unlink not recorded")
        try check(SGTasksCloudRepository.unsentChangeCount(accountPeerId: 42) == nil, "Unreadable purge state reported as a count")
        let blocked = SGTasksCloudRepository.repository(accountPeerId: 42)
        try check(blocked.state.phase == .storageUnavailable && blocked.state.tasks.isEmpty, "Old store opened after failed purge")
        try expectError(.storageUnavailable) { _ = try blocked.createTask(SGTasksCloudTaskDraft(title: "x")) }

        harness.simulateRestart()
        SGTasksCloudRepository.environment = harness.environment
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
        try check(SGTasksCloudRepository.repository(accountPeerId: 42).state.phase == .storageUnavailable, "Durable marker lost across restart")

        harness.fileSystem.failMove = false
        harness.fileSystem.failStoreRemove = false
        harness.simulateRestart()
        SGTasksCloudRepository.environment = harness.environment
        let recovered = SGTasksCloudRepository.repository(accountPeerId: 42)
        try check(recovered.state.phase != .storageUnavailable && recovered.state.tasks.isEmpty && recovered.state.entries.isEmpty, "Recovery exposed old data or stayed closed")
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)

        // No durable marker possible: the rename alone keeps the old store unreachable.
        _ = try SGTasksCloudRepository.repository(accountPeerId: 7).createTask(SGTasksCloudTaskDraft(title: "Second"))
        harness.fileSystem.failMarkerWrite = true
        harness.fileSystem.failStoreRemove = true
        SGTasksCloudRepository.purgeAccount(accountPeerId: 7)
        try check(!harness.files.storeExists(accountPeerId: 7) && harness.files.hasPendingPurge(accountPeerId: 7), "Store not renamed away when the marker failed")
        harness.simulateRestart()
        SGTasksCloudRepository.environment = harness.environment
        try check(SGTasksCloudRepository.repository(accountPeerId: 7).state.phase == .storageUnavailable, "Leftover tombstone did not fail closed after restart")
        harness.fileSystem.failMarkerWrite = false
        harness.fileSystem.failStoreRemove = false
        SGTasksCloudRepository.purgeAccount(accountPeerId: 7)
        try check(harness.files.storedAccountPeerIds() == [], "Purge left files behind")
    }

    private static func reconcileAccounts() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        _ = try SGTasksCloudRepository.repository(accountPeerId: 1).createTask(SGTasksCloudTaskDraft(title: "Gone"))
        _ = try SGTasksCloudRepository.repository(accountPeerId: 2).createTask(SGTasksCloudTaskDraft(title: "Stays"))
        SGTasksCloudRepository.reconcileAccounts(activeAccountPeerIds: [2])
        try check(!harness.files.storeExists(accountPeerId: 1) && harness.files.storeExists(accountPeerId: 2), "Reconciliation removed the wrong store")
        try check(SGTasksCloudRepository.unsentChangeCount(accountPeerId: 2) == 1, "Active account lost its outbox")
        SGTasksCloudRepository.removeAllCloudData()
        try check(harness.files.storedAccountPeerIds() == [], "Final wipe left a store")
    }

    private static func principalFence() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let taskId = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [ownerTask(taskId, rev: "1", title: "Old account")])
        try repository.updateTask(id: taskId, draft: SGTasksCloudTaskDraft(title: "Edited"))
        let created = try repository.createTask(SGTasksCloudTaskDraft(title: "Draft"))

        // A response arriving after the binding changed is never applied.
        harness.server.onMutation = { _ in harness.server.principalValue = principalB }
        harness.server.mutationScript = [{ ack($0, revision: "2") }]
        await repository.syncNow()
        try check(harness.server.sent.count == 1, "Old-scope operations kept draining after the rebind")
        try check(repository.state.entries.allSatisfy { $0.status == .accountChanged }, "Old-scope operations not retired")
        try check(repository.state.tasks.isEmpty && !repository.state.hasCompleteSnapshot, "Old principal's shadow still shown")

        harness.server.onMutation = nil
        harness.server.snapshotScript = [.success(SGTasksWire.SnapshotResponse(items: [], nextCursor: nil, changesCursor: cursor("new"), serverTime: instant()))]
        await repository.syncNow()
        try check(harness.server.sent.count == 1, "Old sealed mutation sent under the new principal")
        let draftEntry = repository.state.entries.first { $0.kind == .taskCreate }!
        try expectError(.actionNotAllowed) { try repository.retry(entryId: draftEntry.id) }
        let copy = try repository.recreateAsNewCopy(entryId: draftEntry.id)
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        await repository.syncNow()
        try check(copy != created, "Copy reused the old-scope id")
        if case let .taskCreate(op) = harness.server.sent.last!.operation {
            try check(op.taskId == copy && harness.server.sent.last!.mutationId != harness.server.sent[0].mutationId, "New-scope create is not a fresh identity")
        }
    }

    private static func explicitImport() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        let legacy = harness.legacy
        let good = try legacy.createQuickTask(folderId: nil, title: "Hisobot", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 123456789, displayName: "Ali"), dueAt: 1_792_512_000)
        _ = try legacy.createQuickTask(folderId: nil, title: "Group note", inboxTitle: "Inbox", assignee: TodoAssignee(peerId: 8_589_934_597, displayName: "Group"))
        let work = try legacy.createFolder(title: "Work")
        _ = try legacy.createQuickTask(folderId: work.id, title: "Plain", inboxTitle: "Unused")
        try legacy.setTaskCompleted(id: good.id, isCompleted: true)
        let originals = legacy.loadTasks()

        let repository = SGTasksCloudRepository.repository(accountPeerId: 42)
        try expectError(.importRequiresCompleteSnapshot) { _ = try repository.prepareLegacyImport() }
        try await harness.bootstrap(repository)
        let preview = try repository.prepareLegacyImport()
        try check(preview.folders.count == 2 && preview.folders.contains { $0.isLegacyInbox && $0.status == .importable }, "Local Inbox must import as a real list")
        try check(preview.tasks.first { $0.legacyId != good.id && $0.title == "Group note" }?.status == .needsCorrection(.annotationNotConvertible), "Unconvertible annotation not flagged")
        let result = try repository.commitLegacyImport(preview)
        try check(result.enqueuedLists == 2 && result.enqueuedTasks == 2 && result.needsCorrection == 1, "Unexpected import counts \(result)")
        let requests = try harness.outboxBodies().map { try SGTasksWire.MutationRequest(wireJSON: $0) }
        try check(!requests.contains { $0.operation.kind == .inviteRequest }, "Annotation became an invitation")
        let scopeA = SGTasksCloudRepository.importScope(origin: originX, principal: principalA)
        let mappings = try legacy.existingCloudImportMappings(accountPeerId: 42, principalScope: scopeA)
        try check(Set(requests.map { $0.mutationId.rawValue }) == Set(mappings.map { $0.createMutationId }), "Creates do not use the durable mapping ids")
        let goodCreate = requests.compactMap { request -> SGTasksWire.TaskCreate? in
            if case let .taskCreate(op) = request.operation, op.content.title == "Hisobot" { return op } else { return nil }
        }.first!
        try check(goodCreate.content.annotation?.telegramUserId.rawValue == "123456789" && goodCreate.isCompleted && goodCreate.content.listId != nil && goodCreate.createdAt != nil, "Imported task lost metadata or was re-filed")

        let again = try repository.commitLegacyImport(try repository.prepareLegacyImport())
        let outboxAfterRepeat = try harness.outboxBodies().count
        try check(again.enqueuedLists == 0 && again.enqueuedTasks == 0 && outboxAfterRepeat == 4, "Repeated consent duplicated the import")
        try check(legacy.loadTasks() == originals, "Import modified local originals")

        // Re-login: the account store goes, the content-free mapping stays and is reused.
        let listIds = requests.compactMap { request -> SGTasksWire.UUID? in
            if case let .listCreate(op) = request.operation { return op.listId } else { return nil }
        }
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
        try check(try legacy.existingCloudImportMappings(accountPeerId: 42, principalScope: scopeA) == mappings, "Per-account logout removed the import mapping")
        let relogged = SGTasksCloudRepository.repository(accountPeerId: 42)
        try await harness.bootstrap(relogged, items: listIds.map { list($0, rev: "1", title: "Imported") })
        let afterRelogin = try relogged.prepareLegacyImport()
        try check(afterRelogin.folders.filter { $0.status == .alreadyInCloud }.count == 2, "Re-login did not recognise the existing mapping")

        // Re-login bound to ANOTHER canonical server account: the old ids are never replayed there.
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
        harness.server.principalValue = principalB
        let rebound = SGTasksCloudRepository.repository(accountPeerId: 42)
        try await harness.bootstrap(rebound)
        let previewB = try rebound.prepareLegacyImport()
        try check(previewB.folders.allSatisfy { $0.status == .importable }, "New server account inherited the old import state")
        _ = try rebound.commitLegacyImport(previewB)
        let idsB = Set(try harness.outboxBodies().map { try SGTasksWire.MutationRequest(wireJSON: $0).mutationId.rawValue })
        try check(idsB.isDisjoint(with: Set(mappings.map { $0.createMutationId })) && idsB.count == 4, "Old server account's ids enqueued under the new one")

        legacy.removeAllData()
        try expectError(.importSnapshotStale) { _ = try rebound.commitLegacyImport(previewB) }
        try check(try legacy.existingCloudImportMappings(accountPeerId: 42, principalScope: scopeA).isEmpty, "Final wipe kept the mapping")
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
    }

    private static func confirmedTargets() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let taskId = SGTasksWire.UUID.generate(), listId = SGTasksWire.UUID.generate()
        let epoch = SGTasksWire.UUID.generate(), newerEpoch = SGTasksWire.UUID.generate()
        let expired = SGTasksWire.UUID.generate(), live = SGTasksWire.UUID.generate()
        let shared = SGTasksWire.Task(id: taskId, revision: revision("3"), ownerTgId: ownTg, viewerRole: .owner, content: content("Shared"), isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: SGTasksWire.Assignment(invitationId: epoch, recipientTgId: otherTg, state: .pending, expiresAt: instant(86400)))
        try await harness.bootstrap(repository, items: [
            .task(shared),
            list(listId, rev: "4", title: "List"),
            .invitation(SGTasksWire.Invitation(id: expired, taskId: SGTasksWire.UUID.generate(), taskRevision: revision("1"), ownerTgId: otherTg, title: "Old offer", dueAt: nil, expiresAt: instant(-10))),
            .invitation(SGTasksWire.Invitation(id: live, taskId: SGTasksWire.UUID.generate(), taskRevision: revision("1"), ownerTgId: otherTg, title: "Offer", dueAt: nil, expiresAt: instant(86400)))
        ])
        try expectError(.changedElsewhere) { try repository.revokeInvitation(taskId: taskId, expectedInvitationId: newerEpoch) }
        try expectError(.changedElsewhere) { try repository.updateList(id: listId, title: "Renamed", sortOrder: 0, expectedRevision: revision("3")) }
        try check(repository.state.entries.isEmpty, "A stale confirmation enqueued an operation")
        try repository.revokeInvitation(taskId: taskId, expectedInvitationId: epoch)

        // Expiry uses the cached server clock advanced by local elapsed time, not the device date.
        try expectError(.invitationExpired) { try repository.respondToInvitation(id: expired, accept: true) }
        try repository.respondToInvitation(id: live, accept: true)
        try expectError(.alreadyPending) { try repository.respondToInvitation(id: live, accept: false) }
        try expectError(.alreadyPending) { try repository.blockSender(invitationId: live) }
        harness.clock = harness.clock.addingTimeInterval(2 * 86400)
        let estimated = repository.state.estimatedServerNow(localNow: harness.clock)
        try check(estimated == Date(timeIntervalSince1970: baseTime + 2 * 86400), "Server clock estimate ignores elapsed time")

        // Repair starts from the refused entry's own sealed content, not from later overlay edits.
        let other = SGTasksWire.UUID.generate()
        try harness.clearOutbox(repository)
        // The task carries a legacy annotation on the server. wf15 §4.1 (review E-1): an edit seals the
        // task's CURRENT annotation whatever its draft carries — a draft naming someone else (first
        // edit) or nobody (second edit) neither rewrites nor clears it.
        let ali = SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId("123456789")!, displayName: "Ali")
        harness.server.changesScript = [changesPage([upsert(.task(SGTasksWire.Task(id: other, revision: revision("1"), ownerTgId: ownTg, viewerRole: .owner, content: content("Base", annotation: ali), isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: nil)))])]
        await repository.syncNow()
        try repository.updateTask(id: other, draft: SGTasksCloudTaskDraft(title: "First edit", annotation: SGTasksCloudAnnotationDraft(cloudUserPeerId: 555, displayName: "Somebody else"), sortOrder: 7))
        try repository.updateTask(id: other, draft: SGTasksCloudTaskDraft(title: "Second edit", sortOrder: 7))
        let firstEntry = repository.state.entries.first { $0.kind == .taskUpdate }!
        let draft = repository.entryTaskDraft(entryId: firstEntry.id)
        try check(draft == SGTasksCloudTaskDraft(title: "First edit", annotation: SGTasksCloudAnnotationDraft(cloudUserPeerId: 123456789, displayName: "Ali"), sortOrder: 7), "Entry draft is not the sealed content")
        let updates = try harness.outboxBodies().compactMap { body -> SGTasksWire.TaskUpdate? in
            if case let .mutation(request) = try SGTasksWire.SealedMutation(wireJSON: body), case let .taskUpdate(op) = request.operation { return op }
            return nil
        }
        try check(updates.map { $0.content.title } == ["First edit", "Second edit"] && updates.allSatisfy { $0.content.annotation == ali }, "An R3 full update rewrote or cleared the annotation: \(updates.map { $0.content.annotation })")
        try check(repository.state.tasks.first { $0.id == other }?.annotation == ali, "The overlay lost the annotation")
        try check(repository.state.tasks.first { $0.id == other }?.title == "Second edit" && repository.entryListTitle(entryId: firstEntry.id) == nil, "Overlay or entry title lookup wrong")
        try check(SGTasksCloudRepository.cloudUserPeerId(SGTasksWire.TelegramId(int64: 5_000_000_000)!).flatMap { SGTasksWire.TelegramId(cloudUserPeerId: $0) }?.int64Value == 5_000_000_000, "Raw ids >= 2^32 do not round-trip")
        // "Masʼulni olib tashlash", then a Save with a draft captured before it: the R3 full update
        // carries no annotation (the clear is not undone).
        try repository.removeLegacyAnnotation(taskId: other)
        try repository.updateTask(id: other, draft: SGTasksCloudTaskDraft(title: "Third edit", annotation: SGTasksCloudAnnotationDraft(cloudUserPeerId: 123456789, displayName: "Ali"), sortOrder: 7))
        let afterClear = try harness.outboxBodies().compactMap { body -> SGTasksWire.TaskUpdate? in
            if case let .mutation(request) = try SGTasksWire.SealedMutation(wireJSON: body), case let .taskUpdate(op) = request.operation { return op }
            return nil
        }
        try check(afterClear.count == 4 && afterClear[2].content.annotation == nil && afterClear[2].content.title == "Second edit", "The R3 clear is not the shown content without the annotation")
        try check(afterClear[3].content.title == "Third edit" && afterClear[3].content.annotation == nil, "A Save after the clear wrote the annotation back: \(String(describing: afterClear[3].content.annotation))")
    }

    /// The Cloud composer's assignee (the owner-only annotation the owner writes into a cloud task):
    /// a create draft with one seals `annotation` as the contact's raw Telegram id plus the name as
    /// validated (trimmed), and the optimistic row shows it; a quick add without one keeps
    /// `annotation` nil. The contact is `otherTg`, not the harness's own id (`ownTg`), so the
    /// assertions tell the chosen contact's id apart from the owner's. Neither makes an invitation.
    /// A draft the repository cannot seal is refused with the error the board surfaces
    /// (`invalidAnnotation` / `annotationNotConvertible`), and nothing is queued for it.
    /// wf15 §4.1 / §4.2 item 4 (inverted from the R4 case of the same name): the Masʼul of a quick
    /// add is an assignment — the create seals `annotation: null` and one `invitation.request`
    /// chains behind it on the task key, sealed from the create's receipt. The owner-only annotation
    /// is never written by this client, not even from an older call site's draft.
    private static func quickAddAssigneeSealsAnnotation() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        let plain = try repository.createTask(SGTasksCloudTaskDraft(title: "Plain", dueAt: 1_800_003_600))
        let assigned = try repository.createTask(SGTasksCloudTaskDraft(title: "Assigned"), assignee: 987654321)
        let optimistic = repository.state.tasks.first { $0.id == assigned }
        try check(optimistic?.annotation == nil, "The optimistic row carries an annotation")
        try check(optimistic?.assignment?.recipientTgId == otherTg && optimistic?.assignment?.state == .pending && optimistic?.assignment?.isPending == true, "The optimistic row does not show the pending assignment")
        try check(repository.state.tasks.first { $0.id == plain }?.annotation == nil, "A quick add without an assignee shows one")
        let legacyDraft = try repository.createTask(SGTasksCloudTaskDraft(title: "Legacy draft", annotation: SGTasksCloudAnnotationDraft(cloudUserPeerId: 987654321, displayName: "Ali Valiyev")))
        let legacyRow = repository.state.tasks.first { $0.id == legacyDraft }
        try check(legacyRow?.annotation == nil && legacyRow?.assignment == nil, "A draft annotation was sealed or became an invitation")

        harness.server.mutationScript = [{ ack($0, revision: "1") }, { ack($0, revision: "1") }, { ack($0, revision: "1") }, { ack($0, revision: "1") }]
        await repository.syncNow()
        let creates = harness.server.sent.compactMap { request -> SGTasksWire.TaskCreate? in
            if case let .taskCreate(op) = request.operation { return op }
            return nil
        }
        let invites = harness.server.sent.compactMap { request -> SGTasksWire.InviteRequest? in
            if case let .inviteRequest(op) = request.operation { return op }
            return nil
        }
        try check(creates.count == 3 && invites.count == 1 && harness.server.sent.count == 4, "Three creates and one invitation were not sent exactly once: \(harness.server.sent.map { $0.operation.kind })")
        try check(creates.allSatisfy { $0.content.annotation == nil }, "A create sealed an annotation")
        try check(creates.first { $0.taskId == plain }?.content.dueAt == 1_800_003_600, "The plain quick add lost its due date")
        let createIndex = harness.server.sent.firstIndex { request in
            if case let .taskCreate(op) = request.operation { return op.taskId == assigned }
            return false
        }
        let inviteIndex = harness.server.sent.firstIndex { $0.operation.kind == .inviteRequest }
        try check(createIndex != nil && inviteIndex != nil && createIndex! < inviteIndex!, "The invitation did not follow its create")
        try check(invites[0].taskId == assigned && invites[0].recipientTgId == otherTg && invites[0].baseRevision.rawValue == "1", "The invitation is not sealed from the create's receipt to the picked contact: \(invites[0])")

        // Pick-time refusals queue nothing, the create included: self and a packed id that is not a
        // Telegram user (a group); the pre-check answers the same.
        let entriesBefore = repository.state.entries.count
        let tasksBefore = repository.state.tasks.count
        try expectError(.selfAssignment) { _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Self"), assignee: 123456789) }
        try expectError(.recipientNotConvertible) { _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Group"), assignee: 8_589_934_597) }
        try expectError(.selfAssignment) { try repository.checkAssignment(recipientCloudUserPeerId: 123456789) }
        try expectError(.recipientNotConvertible) { try repository.checkAssignment(recipientCloudUserPeerId: 8_589_934_597) }
        try repository.checkAssignment(recipientCloudUserPeerId: 987654321)
        try check(repository.state.tasks.count == tasksBefore && repository.state.entries.count == entriesBefore, "A refused assignee still created or queued something")
    }

    private static func offlineSpendsNoAttempts() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        try await harness.bootstrap(repository)
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Offline"))
        harness.server.mutationScript = [{ _ in failure(.transport(.dns)) }]
        await repository.syncNow()
        let entry = repository.state.entries[0]
        try check(entry.status == .queued && entry.attempts == 0, "A certainly-unsent failure spent an attempt")
        if case .offline = repository.state.phase {} else { throw CloudTestFailure.assertion("Offline phase missing") }
        harness.clock = harness.clock.addingTimeInterval(600)
        harness.server.changesScript = [failure(.transport(.noRoute))]
        await repository.syncNow()
        try check(harness.server.sent.count == 1 && repository.state.entries[0].attempts == 0, "Drain ran although the pull was offline")
        // The user's explicit refresh may pass a local offline backoff (never a server Retry-After).
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        repository.refresh()
        await repository.syncNow()
        try check(harness.server.sent.count == 2 && harness.server.sent[0].wireJSON == harness.server.sent[1].wireJSON, "Explicit refresh did not resend the same identity")
    }

    private static func acknowledgementCoverage() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate(), t = SGTasksWire.UUID.generate(), d = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [list(a, rev: "1", title: "A"), list(b, rev: "1", title: "B"), ownerTask(t, rev: "1", title: "Move", list: a), ownerTask(d, rev: "1", title: "Delete")])
        try repository.updateTask(id: t, draft: SGTasksCloudTaskDraft(listId: b, title: "Move", sortOrder: 0))
        harness.server.mutationScript = [{ _ in failure(.transport(.timeout), outcomeUnknown: true) }]
        await repository.syncNow()
        // Unknown outcome: both source and destination lists stay fenced.
        try expectError(.listHasPendingChanges) { try repository.deleteList(id: a, expectedRevision: revision("1")) }
        try expectError(.listHasPendingChanges) { try repository.deleteList(id: b, expectedRevision: revision("1")) }

        harness.clock = harness.clock.addingTimeInterval(600)
        try repository.deleteTask(id: d).commit()
        harness.server.mutationScript = [{ ack($0, revision: "2") }, { ack($0, revision: "2") }]
        harness.server.changesScript = [changesPage([]), changesPage([])]
        await repository.syncNow()
        // has_more=false without the rows: nothing is proven, the acknowledged overlay stays.
        try check(repository.state.entries.count == 2 && repository.state.entries.allSatisfy { $0.status == .awaitingSync }, "Acknowledgements retired without shadow proof")
        try check(repository.state.tasks.first { $0.id == t }?.listId == b && !repository.state.tasks.contains { $0.id == d }, "Board reverted to the stale shadow")
        try expectError(.listHasPendingChanges) { try repository.deleteList(id: a, expectedRevision: revision("1")) }

        let moved = SGTasksWire.Task(id: t, revision: revision("2"), ownerTgId: ownTg, viewerRole: .owner, content: content("Move", list: b), isCompleted: false, completedAt: nil, createdAt: instant(), updatedAt: instant(), assignment: nil)
        harness.server.changesScript = [changesPage([upsert(.task(moved), at: "7"), upsert(list(a, rev: "2", title: "A"), at: "8"), upsert(list(b, rev: "2", title: "B"), at: "9"), remove(.task(d), at: "10")])]
        await repository.syncNow()
        try check(repository.state.entries.isEmpty, "Proven acknowledgements were not retired")
        try repository.deleteList(id: a, expectedRevision: revision("2"))
        try check(repository.state.tasks.contains { $0.id == t && $0.listId == b }, "Deleting the source list removed the moved task")
    }

    private static func blockSurvivesInvitationRemoval() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let invitation = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [.invitation(SGTasksWire.Invitation(id: invitation, taskId: SGTasksWire.UUID.generate(), taskRevision: revision("1"), ownerTgId: otherTg, title: "Spam", dueAt: nil, expiresAt: instant(86400)))])
        try repository.blockSender(invitationId: invitation)
        harness.server.changesScript = [changesPage([remove(.invitation(invitation))])]
        harness.server.mutationScript = [{ ack($0, revision: nil) }]
        await repository.syncNow()
        try check(harness.server.sent.map { $0.operation.kind } == [.senderBlock], "The queued block was dropped with its invitation")
        try check(repository.state.blocks.map { $0.id } == [otherTg], "Acknowledged block not shown until synced")
    }

    private static func immediatePrincipalFence() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let shared = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [assignedTask(shared, rev: "1", title: "Other owner's task", invitation: SGTasksWire.UUID.generate())])
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Draft"))
        harness.server.principalValue = principalB
        let calls = harness.server.callCount
        repository.refresh()
        try check(harness.server.callCount == calls, "Fence needed the network")
        try check(repository.state.tasks.allSatisfy { $0.viewerRole == .owner && $0.ownerTgId == ownTg && $0.revision == nil }, "Old account's shadow still visible after rebind")
        try check(repository.state.entries.map { $0.status } == [.accountChanged], "Old-scope draft not retired at once")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM shadow;") == 0, "Old shadow kept on disk")
    }

    private static func importStatuses() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        let folder = try harness.legacy.createFolder(title: "Work")
        _ = try harness.legacy.createQuickTask(folderId: folder.id, title: "First", inboxTitle: "Unused")
        let repository = SGTasksCloudRepository.repository(accountPeerId: 42)
        try await harness.bootstrap(repository)
        _ = try repository.commitLegacyImport(try repository.prepareLegacyImport())
        harness.server.mutationScript = [{ _ in failure(.creationNotPermitted) }]
        await repository.syncNow()

        var preview = try repository.prepareLegacyImport()
        try check(preview.folders.first?.status == .importBlocked && preview.tasks.first?.status == .importPending, "Refused import not shown as blocked/pending")
        var result = try repository.commitLegacyImport(preview)
        try check(result.enqueuedLists == 0 && result.enqueuedTasks == 0 && result.blocked == 1, "Consent re-created a blocked import")

        // The user discards the refused list; its never-sent child goes with it. The definite 403
        // means nothing was committed, so consent may resend the SAME reserved identity.
        let refused = repository.state.entries.first { $0.kind == .listCreate }!
        let firstListMutation = harness.server.sent[0].mutationId
        try repository.discard(entryId: refused.id)
        try check(repository.state.entries.isEmpty, "Dependent of a definitely refused list survived its discard")
        preview = try repository.prepareLegacyImport()
        try check(preview.folders.first?.status == .resendPreviousAttempt && preview.tasks.first?.status == .importable, "Attempted import not offered as a resend")
        result = try repository.commitLegacyImport(preview)
        try check(result.enqueuedLists == 1 && result.enqueuedTasks == 1 && result.resentPreviousAttempts == 1, "Resend counts \(result)")
        harness.server.mutationScript = [{ ack($0, revision: "1") }, { ack($0, revision: "1") }]
        await repository.syncNow()
        try check(harness.server.sent[1].mutationId == firstListMutation, "Resend changed the reserved identity")

        // Acknowledged and then deleted in the cloud: never re-created, never counted as enqueued.
        let taskId = harness.server.sent.compactMap { request -> SGTasksWire.UUID? in
            if case let .taskCreate(op) = request.operation { return op.taskId } else { return nil }
        }.last!
        harness.server.changesScript = [changesPage([remove(.task(taskId))])]
        await repository.syncNow()
        preview = try repository.prepareLegacyImport()
        try check(preview.tasks.first?.status == .removedFromCloud, "Cloud deletion not recognised")
        result = try repository.commitLegacyImport(preview)
        try check(result.enqueuedTasks == 0 && result.removedFromCloud == 1, "A removed import was replayed")
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
    }

    private static func deleteAndSecondaryKeyProof() async throws {
        let harness = try Harness()
        let repository = harness.repository()
        let a = SGTasksWire.UUID.generate(), b = SGTasksWire.UUID.generate(), t = SGTasksWire.UUID.generate()
        try await harness.bootstrap(repository, items: [list(a, rev: "1", title: "A"), list(b, rev: "1", title: "B"), ownerTask(t, rev: "1", title: "Move", list: a)])

        // Offline create, then delete; both acknowledged; the coalesced rows never reach the shadow.
        let local = try repository.createTask(SGTasksCloudTaskDraft(title: "Short-lived"))
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        harness.server.changesScript = [changesPage([]), changesPage([])]
        await repository.syncNow()
        try repository.deleteTask(id: local).commit()
        harness.server.mutationScript = [{ ack($0, revision: "2") }]
        harness.server.changesScript = [changesPage([]), changesPage([])]
        await repository.syncNow()
        try check(!repository.state.tasks.contains { $0.id == local } && repository.state.entries.isEmpty, "A proven delete left its earlier create applied")

        // A move A->B is acknowledged; another device removes list A before T's own row arrives.
        try repository.updateTask(id: t, draft: SGTasksCloudTaskDraft(listId: b, title: "Move", sortOrder: 0))
        harness.server.mutationScript = [{ ack($0, revision: "2") }]
        harness.server.changesScript = [changesPage([]), changesPage([remove(.list(a))])]
        await repository.syncNow()
        try check(repository.state.entries.map { $0.status } == [.awaitingSync], "Removal of a secondary key retired the move")
        try check(repository.state.tasks.first { $0.id == t }?.listId == b, "Moved task lost its destination")
    }

    private static func durableAckProvenance(purgeBeforeFlush: Bool) async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        _ = try harness.legacy.createFolder(title: "Work")
        let repository = SGTasksCloudRepository.repository(accountPeerId: 42)
        try await harness.bootstrap(repository)
        _ = try repository.commitLegacyImport(try repository.prepareLegacyImport())
        let plain = try repository.createTask(SGTasksCloudTaskDraft(title: "Not imported"))
        let good = harness.legacy
        // The local Tasks database becomes unwritable around the acknowledgement.
        harness.legacy = TodoDatabase(dbPath: harness.directory.appendingPathComponent("missing/legacy.sqlite").path, defaults: harness.legacyDefaults)
        harness.server.mutationScript = [{ ack($0, revision: "1") }, { ack($0, revision: "1") }]
        let listId = try SGTasksWire.MutationRequest(wireJSON: try harness.outboxBodies()[0]).operation
        guard case let .listCreate(op) = listId else { throw CloudTestFailure.assertion("Import did not enqueue a list") }
        harness.server.changesScript = [changesPage([]), changesPage([upsert(list(op.listId, rev: "1", title: "Work")), upsert(ownerTask(plain, rev: "1", title: "Not imported"))])]
        await repository.syncNow()
        // The cloud board retires proven acks although the local database cannot be written.
        try check(repository.state.entries.isEmpty, "Cloud retirement waited for the local Tasks database")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM import_ack_pending;") == 2, "Acknowledged provenance not queued")
        // Removed in the cloud meanwhile: the queued acknowledgement already counts, no resend is offered.
        harness.server.changesScript = [changesPage([remove(.list(op.listId))])]
        await repository.syncNow()
        harness.legacy = good
        let preview = try repository.prepareLegacyImport()
        try check(preview.folders.first?.status == .removedFromCloud, "Queued acknowledgement ignored by the preview")
        if purgeBeforeFlush {
            SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
            let reopened = SGTasksCloudRepository.repository(accountPeerId: 42)
            try await harness.bootstrap(reopened)
            let afterLogin = try reopened.prepareLegacyImport()
            try check(afterLogin.folders.first?.status == .removedFromCloud, "Logout lost acknowledged import provenance and offered a resend")
        } else {
            await repository.syncNow()
            try check(try harness.cloudScalar("SELECT COUNT(*) FROM import_ack_pending;") == 0, "Pending provenance not flushed after recovery")
        }
        let mapping = try good.existingCloudImportMappings(accountPeerId: 42, principalScope: SGTasksCloudRepository.importScope(origin: originX, principal: principalA))
        try check(mapping.first?.isAcknowledged == true, "Acknowledged provenance missing")
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
    }

    private static func failedLaterImportEdit() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        let folder = try harness.legacy.createFolder(title: "Work")
        let repository = SGTasksCloudRepository.repository(accountPeerId: 42)
        try await harness.bootstrap(repository)
        _ = try repository.commitLegacyImport(try repository.prepareLegacyImport())
        let request = try SGTasksWire.MutationRequest(wireJSON: try harness.outboxBodies()[0])
        guard case let .listCreate(op) = request.operation else { throw CloudTestFailure.assertion("Expected imported list create") }
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        harness.server.changesScript = [changesPage([]), changesPage([upsert(list(op.listId, rev: "1", title: "Work"))])]
        await repository.syncNow()
        try check(repository.state.entries.isEmpty, "Authoritative list did not retire its create")

        try repository.updateList(id: op.listId, title: "Renamed", sortOrder: 0, expectedRevision: revision("1"))
        harness.server.mutationScript = [{ _ in failure(.notFound) }]
        await repository.syncNow()
        harness.server.changesScript = [changesPage([remove(.list(op.listId))])]
        await repository.syncNow()
        _ = try harness.legacy.createQuickTask(folderId: folder.id, title: "New child", inboxTitle: "Unused")
        let preview = try repository.prepareLegacyImport()
        try check(preview.folders.first?.status == .importBlocked, "Failed later edit was labelled as copying in progress")
        try check(preview.tasks.first?.status == .needsCorrection(.parentFolderNeedsCorrection), "Child was allowed under a missing blocked list")
        let result = try repository.commitLegacyImport(preview)
        try check(result.enqueuedLists == 0 && result.enqueuedTasks == 0, "Import queued work under a missing blocked list")
        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
    }

    /// Control: token rotation under the same principal, and a signed-out (no principal) read, are
    /// not rebinds — the bound board, its shadow and the queued draft stay exactly as they were.
    private static func samePrincipalReadsKeepBoard() async throws {
        let board = try await PrincipalABoard.make()
        let harness = board.harness
        let repository = board.repository
        let bound = repository.state
        let calls = harness.server.callCount

        harness.server.principalValue = principalA
        let recorder = StatePublicationRecorder(repository, center: harness.notificationCenter)
        try check(recorder.published.first == bound, "A same-principal read changed the board")
        harness.notificationCenter.post(name: board.notice, object: nil)
        try check(repository.state == bound, "A same-principal session notice changed the board")

        harness.server.principalValue = nil
        try check(repository.state == bound, "A signed-out read dropped the bound board or its draft")
        harness.notificationCenter.post(name: board.notice, object: nil)
        try check(repository.state == bound, "A signed-out session notice dropped the bound board or its draft")
        harness.server.principalValue = principalA
        try check(repository.state == bound, "Signing back in to the same principal changed the board")

        repository.onQueue {}
        await drainMainQueue()
        try check(recorder.published.count == 1, "Same-principal or signed-out reads published a change")
        try check(harness.server.callCount == calls, "Reads needed the network")
        try board.checkDurableUntouched("Same-principal and signed-out reads")
    }

    /// The binding moves to B and B's session notice is never delivered: no read publishes A's
    /// board or touches the store, and B's first sync then publishes B.
    private static func rebindBeforeSessionNotice() async throws {
        let board = try await PrincipalABoard.make()
        let harness = board.harness
        let calls = harness.server.callCount

        harness.server.principalValue = principalB
        let recorder = StatePublicationRecorder(board.repository, center: harness.notificationCenter)
        try board.checkHidden(recorder.published[0], "First read after the rebind")
        try board.checkHidden(board.repository.state, "Repeated read after the rebind")
        try board.checkDurableUntouched("Reads after the rebind")
        try check(harness.server.callCount == calls, "A read needed the network")

        try await board.checkPrincipalBPublishes(recorder)
        let state = board.repository.state
        try check(state.entries.map { $0.status } == [.accountChanged] && !state.tasks.contains { $0.id == board.draftId }, "B's sync did not keep A's draft as a retired entry")
    }

    /// The binding moves to B while B's session notice is still queued on main: the subscriber's
    /// first value hides A, and the notice's fence then reaches the same subscriber.
    private static func rebindThenLateSessionNotice() async throws {
        let board = try await PrincipalABoard.make()
        let harness = board.harness

        harness.server.principalValue = principalB
        let recorder = StatePublicationRecorder(board.repository, center: harness.notificationCenter)
        try board.checkHidden(recorder.published[0], "First read before the session notice")
        try board.checkDurableUntouched("Read before the session notice")

        harness.notificationCenter.post(name: board.notice, object: nil)
        try await board.checkFencedPublished(recorder, "After the late session notice")
        try await board.checkPrincipalBPublishes(recorder)
    }

    /// Board departure stops polling but not the repository: a rebind lands while no board is
    /// subscribed, and the re-opened board reads state before it calls `start()`.
    private static func rebindWhileBoardStopped() async throws {
        let board = try await PrincipalABoard.make()
        let harness = board.harness
        let repository = board.repository
        repository.start()
        repository.stop()
        repository.onQueue {}
        await drainMainQueue()

        harness.server.principalValue = principalB
        let recorder = StatePublicationRecorder(repository, center: harness.notificationCenter)
        try board.checkHidden(recorder.published[0], "Re-opened board's first read")
        try board.checkDurableUntouched("Re-opened board's first read")

        repository.start()
        try await board.checkFencedPublished(recorder, "After the re-opened board's start()")
        harness.notificationCenter.post(name: board.notice, object: nil)
        try await board.checkFencedPublished(recorder, "After the late session notice")
        try await board.checkPrincipalBPublishes(recorder)
        repository.stop()
    }

    /// A process restart after the rebind: the store still belongs to A and B is bound before any
    /// start/refresh/session notice; the first read hides A until the board's start() fences.
    private static func reopenedUnderNewPrincipal() async throws {
        var original: PrincipalABoard? = try await PrincipalABoard.make()
        let harness = original!.harness
        let shadowTaskIds = original!.shadowTaskIds
        let draftId = original!.draftId
        let notice = original!.notice
        original = nil

        harness.server.principalValue = principalB
        let board = PrincipalABoard(harness: harness, repository: harness.repository(), notice: notice, shadowTaskIds: shadowTaskIds, draftId: draftId)
        let recorder = StatePublicationRecorder(board.repository, center: harness.notificationCenter)
        try board.checkHidden(recorder.published[0], "Reopened first read")
        try board.checkDurableUntouched("Reopened first read")

        board.repository.start()
        try await board.checkFencedPublished(recorder, "After the reopened board's start()")
        board.repository.stop()
    }

    /// Model an unusable, closed connection during the rebind fence. The subscriber must see
    /// storageUnavailable — never a stale A board or endless loading — without wiping disk data.
    /// An I/O error that leaves the connection open is a separate failure path.
    private static func storageLossDuringRebindFence() async throws {
        let board = try await PrincipalABoard.make()
        let harness = board.harness
        let repository = board.repository

        harness.server.principalValue = principalB
        let recorder = StatePublicationRecorder(repository, center: harness.notificationCenter)
        try board.checkHidden(recorder.published[0], "First read after the rebind")

        repository.onQueue { repository.store?.close() }
        harness.notificationCenter.post(name: board.notice, object: nil)
        repository.onQueue {}
        await drainMainQueue()
        guard let last = recorder.published.last else { throw CloudTestFailure.assertion("Nothing was published") }
        try check(last == repository.state, "The subscriber was left on a stale value after the storage loss")
        try check(last.phase == .storageUnavailable, "A failed rebind fence did not publish storageUnavailable")
        try board.checkHidden(last, "After the storage loss")
        try board.checkDurableUntouched("After the storage loss")
    }

    // MARK: Backend readiness (configured / not configured)

    private static func pauseRows(_ harness: Harness, _ reason: String) throws -> Int64 {
        return try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'pause' AND value = '\(reason)';")
    }

    /// No backend in this build and no session: the board must say "not configured" (whose gate
    /// offers no linking), never "not signed in" (whose gate offers a Link that cannot work), and
    /// nothing — start, refresh, a completed link, a local edit — may make a request.
    private static func unconfiguredWithoutSession() async throws {
        let harness = try Harness()
        harness.server.configured = false
        harness.server.principalValue = nil
        harness.server.linked = false
        let repository = harness.repository()
        try check(repository.state.phase == .notConfigured, "First read of an unconfigured build is \(repository.state.phase), not notConfigured")

        repository.start()
        await repository.syncNow()
        try check(repository.state.phase == .notConfigured, "A cycle without a session reported \(repository.state.phase) instead of notConfigured")
        repository.refresh()
        await repository.syncNow()
        try check(repository.state.phase == .notConfigured, "An explicit refresh left notConfigured for \(repository.state.phase)")
        repository.resumeAfterLinking()
        await repository.syncNow()
        try check(repository.state.phase == .notConfigured, "A link completion left notConfigured for \(repository.state.phase)")

        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Kept on this device"))
        await repository.syncNow()
        let entries = repository.state.entries
        try check(entries.count == 1 && entries[0].attempts == 0, "The local edit was dropped or counted as an attempt")
        try check(harness.server.callCount == 0, "An unconfigured build reached the network")
        try check(try pauseRows(harness, "not_signed_in") == 0, "A missing session was recorded as the pause reason of an unconfigured build")
        try check(repository.state.phase == .notConfigured, "A local edit left notConfigured for \(repository.state.phase)")
        repository.stop()
    }

    /// A board bound to A by a configured build, reopened by a build without a backend: the
    /// gate is notConfigured, no request is made, and A's binding, snapshot and draft stay as-is.
    private static func unconfiguredSuccessorOfBoundBoard() async throws {
        var original: PrincipalABoard? = try await PrincipalABoard.make()
        let harness = original!.harness
        let shadowTaskIds = original!.shadowTaskIds
        let draftId = original!.draftId
        let notice = original!.notice
        original = nil

        harness.simulateRestart()
        harness.server.configured = false
        let calls = harness.server.callCount
        let board = PrincipalABoard(harness: harness, repository: harness.repository(), notice: notice, shadowTaskIds: shadowTaskIds, draftId: draftId)
        try check(board.repository.state.phase == .notConfigured, "First read of an unconfigured successor is \(board.repository.state.phase)")
        board.repository.start()
        await board.repository.syncNow()
        board.repository.refresh()
        await board.repository.syncNow()
        try check(board.repository.state.phase == .notConfigured, "An unconfigured successor's cycle reported \(board.repository.state.phase)")
        try check(harness.server.callCount == calls, "An unconfigured successor reached the network")
        try board.checkDurableUntouched("Unconfigured successor")
        board.repository.stop()
    }

    /// Build 1 has no backend and no session; build 2 has one. Without a session build 2 pauses as
    /// not signed in (a real Link is now possible) with no request; once a session is bound the
    /// session notice re-evaluates the binding and the first snapshot runs.
    private static func unconfiguredHandsOverToConfigured() async throws {
        let harness = try Harness()
        let notice = Notification.Name("sgtasks-cloud-tests-session-\(UUID().uuidString)")
        harness.server.sessionNotice = notice
        harness.server.configured = false
        harness.server.principalValue = nil
        var earlier: SGTasksCloudRepository? = harness.repository()
        earlier!.start()
        await earlier!.syncNow()
        try check(earlier!.state.phase == .notConfigured, "Build 1 was not notConfigured: \(earlier!.state.phase)")
        earlier!.stop()
        earlier = nil

        harness.simulateRestart()
        harness.server.configured = true
        let successor = harness.repository()
        successor.start()
        await successor.syncNow()
        try check(successor.state.phase == .notSignedIn, "A configured build without a session is \(successor.state.phase), not notSignedIn")
        try check(harness.server.callCount == 0, "A configured build without a session reached the network")

        harness.server.principalValue = principalA
        harness.server.snapshotScript = [.success(SGTasksWire.SnapshotResponse(items: [], nextCursor: nil, changesCursor: cursor("c1"), serverTime: instant()))]
        harness.notificationCenter.post(name: notice, object: nil)
        await successor.syncNow()
        try check(successor.state.hasCompleteSnapshot && successor.state.phase == .idle, "A bound session did not resume after the session notice: \(successor.state.phase)")
        try check(try harness.cloudScalar("SELECT COUNT(*) FROM meta WHERE key = 'principal' AND value = '\(principalA)';") == 1, "The first binding was not recorded")
        successor.stop()
    }

    /// An earlier build without a backend left a durable notConfigured pause. The configured
    /// successor's board start leaves it on its own (no refresh, no session notice) and the queued
    /// draft goes out with its original business id.
    private static func configuredSuccessorLeavesStalePause() async throws {
        let harness = try Harness()
        var earlier: SGTasksCloudRepository? = harness.repository()
        try await harness.bootstrap(earlier!)
        _ = try earlier!.createTask(SGTasksCloudTaskDraft(title: "Waits for a configured build"))
        harness.server.changesScript = [failure(.notConfigured)]
        await earlier!.syncNow()
        try check(earlier!.state.phase == .notConfigured, "Fixture did not pause as notConfigured: \(earlier!.state.phase)")
        try check(harness.server.sent.isEmpty, "Fixture sent the draft")
        let queuedBody = try harness.outboxBodies()
        earlier = nil

        harness.simulateRestart()
        let successor = harness.repository()
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        successor.start()
        await successor.syncNow()
        try check(successor.state.phase == .idle, "A configured successor stayed in \(successor.state.phase)")
        try check(try pauseRows(harness, "not_configured") == 0, "The stale notConfigured pause is still stored")
        let original = try SGTasksWire.MutationRequest(wireJSON: queuedBody[0])
        try check(harness.server.sent.map { $0.mutationId } == [original.mutationId], "The queued draft was not sent once with its original business id")
        successor.stop()
    }

    /// Leaving a stale notConfigured pause never bypasses the principal fence: a store bound to A,
    /// reopened by a configured build bound to B, retires A's draft and shows only B.
    private static func configuredSuccessorKeepsPrincipalFence() async throws {
        var original: PrincipalABoard? = try await PrincipalABoard.make()
        let harness = original!.harness
        harness.server.changesScript = [failure(.notConfigured)]
        await original!.repository.syncNow()
        try check(original!.repository.state.phase == .notConfigured, "Fixture did not pause as notConfigured")
        try original!.checkDurableUntouched("Stale notConfigured fixture")
        let shadowTaskIds = original!.shadowTaskIds
        let draftId = original!.draftId
        let notice = original!.notice
        original = nil

        harness.simulateRestart()
        harness.server.principalValue = principalB
        let board = PrincipalABoard(harness: harness, repository: harness.repository(), notice: notice, shadowTaskIds: shadowTaskIds, draftId: draftId)
        let recorder = StatePublicationRecorder(board.repository, center: harness.notificationCenter)
        board.repository.start()
        try await board.checkFencedPublished(recorder, "Configured successor's start() under B")
        try await board.checkPrincipalBPublishes(recorder)
        try check(harness.server.sent.isEmpty, "A's draft was sent under B")
        try check(board.repository.state.entries.map { $0.status } == [.accountChanged], "A's draft is no longer a retired entry")
        try check(try pauseRows(harness, "not_configured") == 0, "The stale notConfigured pause is still stored")
        board.repository.stop()
    }

    /// Being configured is no reason to end any other pause: a configured successor's start and
    /// cycle keep not-linked, invalid-session and no-session pauses, durably and without a request.
    private static func configuredSuccessorKeepsAuthPauses() async throws {
        let pauses: [(reason: String, kind: SGTasksError.Kind?, phase: SGTasksCloudState.Phase)] = [
            ("not_linked", .accountNotLinked, .pausedNotLinked),
            ("session_invalid", .session(.invalidToken), .sessionInvalid),
            ("not_signed_in", nil, .notSignedIn)
        ]
        for pause in pauses {
            let harness = try Harness()
            var earlier: SGTasksCloudRepository? = harness.repository()
            if let kind = pause.kind {
                harness.server.snapshotScript = [failure(kind)]
            } else {
                harness.server.principalValue = nil
            }
            await earlier!.syncNow()
            try check(earlier!.state.phase == pause.phase, "\(pause.reason): fixture did not pause (\(earlier!.state.phase))")
            // A restart means the earlier build's connection is gone: assert it, not assume it.
            // Quiesce first, with the suite's existing barriers: nothing of the earlier build may be
            // in flight on its queue, and every change notice it enqueued on main (each briefly
            // re-retains it to post) has run. Its own strong `Task` exists only with automatic sync.
            earlier!.onQueue {}
            await drainMainQueue()
            let isEarlierReleased = { [weak earlier] in earlier == nil }
            earlier = nil
            if !isEarlierReleased() {
                // The case fails either way; this only records whether the remaining owner lets go
                // after one more main-queue turn (a reference held past its main block).
                await drainMainQueue()
                let laterRelease = isEarlierReleased()
                throw CloudTestFailure.assertion("\(pause.reason): the earlier build's repository (and its SQLite connection) outlived the quiesced, simulated restart [released after one more main-queue turn: \(laterRelease)]")
            }

            harness.simulateRestart()
            let successor = harness.repository()
            let calls = harness.server.callCount
            successor.start()
            await successor.syncNow()
            let phase = successor.state.phase
            let trace = phase == .storageUnavailable ? " " + storageTrace(harness, successor) : ""
            try check(phase == pause.phase, "\(pause.reason): a configured successor ended the pause (\(phase))\(trace)")
            try check(harness.server.callCount == calls, "\(pause.reason): a configured successor made a request past the pause")
            try check(try pauseRows(harness, pause.reason) == 1, "\(pause.reason): the durable pause was cleared")
            successor.stop()
        }
    }

    /// Failure-only, content-free trace of a store the repository could not use: the files in the
    /// store directory, whether the repository still holds a store, and the product's own open and
    /// recovery reads replayed on a separate connection with their SQLite result codes.
    private static func storageTrace(_ harness: Harness, _ repository: SGTasksCloudRepository) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: harness.storeDirectory.path))?.sorted().joined(separator: ",") ?? "<unlistable>"
        let holdsStore = repository.onQueue { repository.store != nil }
        var steps: [String] = []
        do {
            let store = try SGTasksCloudStore(path: harness.files.path(accountPeerId: repository.accountPeerId))
            defer { store.close() }
            steps.append("open=ok")
            let reads: [(String, () throws -> Void)] = [
                ("requeue", { try store.transaction { try store.requeueInterruptedSends() } }),
                ("pause", { _ = try store.meta("pause") }),
                ("principal", { _ = try store.meta("principal") }),
                ("entries", { _ = try store.entries() }),
                ("shadow", { _ = try store.rows(.shadow) }),
                ("notices", { _ = try store.notices() })
            ]
            for (name, read) in reads {
                do {
                    try read()
                    steps.append("\(name)=ok")
                } catch let error as SGTasksCloudStoreError {
                    steps.append("\(name)=sqlite \(error.code)")
                } catch {
                    steps.append("\(name)=\(type(of: error))")
                }
            }
        } catch let error as SGTasksCloudStoreError {
            steps.append("open=sqlite \(error.code)")
        } catch {
            steps.append("open=\(type(of: error))")
        }
        return "[trace files=\(names) repositoryHoldsStore=\(holdsStore) \(steps.joined(separator: " "))]"
    }

    // MARK: Origin scoping: the pre-origin root

    /// Seeds the pre-origin root as an earlier build left it: per account a synced task and a
    /// queued, never-sent draft. The earlier build's repositories are closed afterwards.
    private static func seedPreOrigin(_ harness: Harness, _ accountPeerIds: [Int64]) async throws {
        for accountPeerId in accountPeerIds {
            var repository: SGTasksCloudRepository? = harness.preOriginBuildRepository(accountPeerId)
            try await harness.bootstrap(repository!, items: [ownerTask(SGTasksWire.UUID.generate(), rev: "1", title: "Pre-origin task \(accountPeerId)")])
            _ = try repository!.createTask(SGTasksCloudTaskDraft(title: "Pre-origin draft \(accountPeerId)"))
            // The pre-origin build is gone before the current one runs: assert it, not assume it.
            // Quiesce first (its queue, then the change notices it enqueued on main, each of which
            // briefly re-retains it); else its WAL connection may close after a case's `before`
            // snapshot, and that close's checkpoint rewrites the pre-origin files.
            repository!.onQueue {}
            await drainMainQueue()
            let isReleased = { [weak repository] in repository == nil }
            repository = nil
            try check(isReleased(), "Fixture: the pre-origin build's repository (and its SQLite connection) outlived it")
        }
    }

    private static func preOriginContents(_ harness: Harness, of accountPeerIds: Set<Int64>) throws -> [String: Data] {
        return try harness.preOriginContents().filter { name, _ in
            accountPeerIds.contains { name.hasPrefix("\($0).") }
        }
    }

    /// Logout of one account (the SGAccountCleanup diff after launch) removes that account's
    /// pre-origin store too, even one the current build never opened; other accounts' stores stay
    /// byte-identical. The last logout (remove-all) leaves neither root holding any store.
    private static func explicitRemovalPurgesOwnedPreOriginStores() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        SGTasksCloudRepository.removeAllCloudData()
        try await seedPreOrigin(harness, [42, 7, 9])
        _ = try SGTasksCloudRepository.repository(accountPeerId: 42).createTask(SGTasksCloudTaskDraft(title: "Current draft"))
        let others = try preOriginContents(harness, of: [7, 9])
        try check(!others.isEmpty, "Fixture left no pre-origin stores for the other accounts")

        SGTasksCloudRepository.purgeAccount(accountPeerId: 42)
        try check(!harness.files.storeExists(accountPeerId: 42), "Logout kept the account's current store")
        try check(harness.preOriginFiles.storedAccountPeerIds() == [7, 9], "Logout kept the account's pre-origin store or removed another account's: \(String(describing: harness.preOriginFiles.storedAccountPeerIds()))")
        try check(try preOriginContents(harness, of: [7, 9]) == others, "Logout changed another account's pre-origin store")

        // Signed in before the update and never opened since: only the pre-origin root has it.
        SGTasksCloudRepository.purgeAccount(accountPeerId: 9)
        try check(harness.preOriginFiles.storedAccountPeerIds() == [7], "Logout of an account known only to the pre-origin root kept its store")

        SGTasksCloudRepository.removeAllCloudData()
        try check(harness.preOriginFiles.storedAccountPeerIds() == [], "The last logout left a pre-origin store")
        try check(harness.files.storedAccountPeerIds() == [], "The last logout left a current store")
    }

    /// Launch reconciliation may run at the cutover launch, against a current root that is still
    /// empty: it applies the signed-out rule to the current root only and never touches the
    /// pre-origin root — neither for signed-out accounts nor when it sees no account at all.
    private static func launchReconciliationLeavesPreOriginRoot() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        SGTasksCloudRepository.removeAllCloudData()
        try await seedPreOrigin(harness, [1, 2])
        _ = try SGTasksCloudRepository.repository(accountPeerId: 1).createTask(SGTasksCloudTaskDraft(title: "Gone"))
        _ = try SGTasksCloudRepository.repository(accountPeerId: 2).createTask(SGTasksCloudTaskDraft(title: "Stays"))
        let before = try harness.preOriginContents()
        try check(!before.isEmpty, "Fixture left no pre-origin store")

        SGTasksCloudRepository.reconcileAccounts(activeAccountPeerIds: [2])
        try check(!harness.files.storeExists(accountPeerId: 1) && harness.files.storeExists(accountPeerId: 2), "Reconciliation removed the wrong current store")
        try check(try harness.preOriginContents() == before, "Launch reconciliation touched the pre-origin root")

        SGTasksCloudRepository.reconcileAccounts(activeAccountPeerIds: [])
        try check(harness.files.storedAccountPeerIds() == [], "Reconciliation without accounts kept a current store")
        try check(try harness.preOriginContents() == before, "A launch without accounts wiped the pre-origin root")
        SGTasksCloudRepository.removeAllCloudData()
    }

    /// Opening, reading, syncing and editing the current store never shows, counts or sends
    /// pre-origin content, and never creates, copies into, rewrites or removes a pre-origin file.
    private static func currentStoreIgnoresPreOriginRoot() async throws {
        let harness = try Harness()
        SGTasksCloudRepository.environment = harness.environment
        SGTasksCloudRepository.removeAllCloudData()
        try await seedPreOrigin(harness, [42])
        let before = try harness.preOriginContents()
        try check(!before.isEmpty, "Fixture left no pre-origin store")
        try check(harness.server.sent.isEmpty, "Fixture sent its draft")

        let repository = SGTasksCloudRepository.repository(accountPeerId: 42)
        try check(repository.state.tasks.isEmpty && repository.state.entries.isEmpty && !repository.state.hasCompleteSnapshot, "The current store showed pre-origin content")
        try check(SGTasksCloudRepository.unsentChangeCount(accountPeerId: 42) == 0, "Pre-origin drafts were counted as unsent")
        try await harness.bootstrap(repository)
        _ = try repository.createTask(SGTasksCloudTaskDraft(title: "Current draft"))
        try check(SGTasksCloudRepository.unsentChangeCount(accountPeerId: 42) == 1, "The unsent count is not the current store's own")
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        await repository.syncNow()
        let titles = harness.server.sent.compactMap { request -> String? in
            if case let .taskCreate(op) = request.operation { return op.content.title } else { return nil }
        }
        try check(titles == ["Current draft"], "A pre-origin draft was sent: \(titles)")
        try check(!repository.state.tasks.contains { $0.title.hasPrefix("Pre-origin") }, "Pre-origin content reached the board")
        try check(harness.files.storeExists(accountPeerId: 42), "The current store was not created in the current root")
        try check(try harness.preOriginContents() == before, "The current build created, copied into, rewrote or removed a pre-origin file")
        SGTasksCloudRepository.removeAllCloudData()
    }

    // MARK: Origin scoping: explicit import mappings

    /// Origin X imported the local folder, the server acknowledged it, and it was then removed in
    /// X's cloud. The same native account bound to the SAME principal on another origin has never
    /// seen it: that origin offers it as importable and its consent creates its own copy.
    private static func acknowledgedImportOnOneOriginNeverSuppressesAnother() async throws {
        let harness = try Harness()
        _ = try harness.legacy.createFolder(title: "Work")
        let onX = harness.repository()
        try await harness.bootstrap(onX)
        _ = try onX.commitLegacyImport(try onX.prepareLegacyImport())
        let reserved = try SGTasksWire.MutationRequest(wireJSON: try harness.outboxBodies()[0])
        guard case let .listCreate(createdOnX) = reserved.operation else { throw CloudTestFailure.assertion("Fixture: origin X did not enqueue a list") }
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        harness.server.changesScript = [changesPage([]), changesPage([upsert(list(createdOnX.listId, rev: "1", title: "Work"))])]
        await onX.syncNow()
        harness.server.changesScript = [changesPage([remove(.list(createdOnX.listId))])]
        await onX.syncNow()
        try check(try onX.prepareLegacyImport().folders.first?.status == .removedFromCloud, "Fixture: origin X holds no acknowledged, removed import")

        let onY = harness.otherOriginRepository()
        try await harness.bootstrap(onY)
        let preview = try onY.prepareLegacyImport()
        try check(preview.folders.first?.status == .importable, "Origin X's acknowledgement decided the other origin's offer: \(String(describing: preview.folders.first?.status))")
        let result = try onY.commitLegacyImport(preview)
        try check(result.enqueuedLists == 1 && result.removedFromCloud == 0, "The other origin's consent did not enqueue its own copy: \(result)")
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        await onY.syncNow()
        guard let sentOnY = harness.server.sent.last, case let .listCreate(createdOnY) = sentOnY.operation else { throw CloudTestFailure.assertion("The other origin sent no list create") }
        try check(createdOnY.listId != createdOnX.listId && sentOnY.mutationId != reserved.mutationId, "The other origin reused origin X's import identity")
    }

    /// Origin X handed its import create to the network with an unknown outcome (a reserved,
    /// unacknowledged identity). The other origin, same principal, never resends X's id: it offers
    /// a fresh import and sends a new identity.
    private static func reservedImportIdentityNeverReplaysOnAnotherOrigin() async throws {
        let harness = try Harness()
        _ = try harness.legacy.createFolder(title: "Work")
        let onX = harness.repository()
        try await harness.bootstrap(onX)
        _ = try onX.commitLegacyImport(try onX.prepareLegacyImport())
        let queued = try SGTasksWire.MutationRequest(wireJSON: try harness.outboxBodies()[0])
        // Unscripted: the send times out with an unknown outcome.
        await onX.syncNow()
        try check(harness.server.sent.map { $0.mutationId } == [queued.mutationId], "Fixture: origin X did not hand its import to the network exactly once")
        guard case let .listCreate(createdOnX) = queued.operation else { throw CloudTestFailure.assertion("Fixture: origin X did not send a list create") }
        try check(try onX.prepareLegacyImport().folders.first?.status == .importPending, "Fixture: origin X's attempt is not still pending")

        let onY = harness.otherOriginRepository()
        try await harness.bootstrap(onY)
        let preview = try onY.prepareLegacyImport()
        try check(preview.folders.first?.status == .importable, "Origin X's reserved attempt was offered on the other origin: \(String(describing: preview.folders.first?.status))")
        let result = try onY.commitLegacyImport(preview)
        try check(result.enqueuedLists == 1 && result.resentPreviousAttempts == 0, "The other origin's consent resent instead of creating: \(result)")
        harness.server.mutationScript = [{ ack($0, revision: "1") }]
        await onY.syncNow()
        try check(harness.server.sent.count == 2, "The other origin did not send exactly its own create")
        guard case let .listCreate(createdOnY) = harness.server.sent[1].operation else { throw CloudTestFailure.assertion("The other origin sent no list create") }
        try check(harness.server.sent[1].mutationId != queued.mutationId && createdOnY.listId != createdOnX.listId, "The other origin replayed origin X's reserved identity")
    }

    /// A build before origin scoping imported the folder and saw it acknowledged under the bare
    /// (principal-only) scope. This build neither lets that row decide its offer nor rewrites it:
    /// the bare rows are identical after the preview and after an explicit new import, which gets
    /// fresh identities of its own.
    private static func bareImportMappingsNeverDecideAndStayUntouched() async throws {
        let harness = try Harness()
        _ = try harness.legacy.createFolder(title: "Work")
        let bareScope = bareImportScope(principalA)
        let minted = try harness.legacy.cloudImportMappings(for: try harness.legacy.cloudImportSnapshot(), accountPeerId: 42, principalScope: bareScope) {
            (cloudId: SGTasksWire.UUID.generate().rawValue, mutationId: SGTasksWire.UUID.generate().rawValue)
        }
        try harness.legacy.recordCloudImportAttempt(createMutationId: minted[0].createMutationId, acknowledged: true)
        let bare = try harness.legacy.existingCloudImportMappings(accountPeerId: 42, principalScope: bareScope)
        try check(bare.count == 1 && bare[0].isAcknowledged, "Fixture: no acknowledged bare mapping")

        let repository = harness.repository()
        try await harness.bootstrap(repository)
        let preview = try repository.prepareLegacyImport()
        try check(preview.folders.first?.status == .importable, "A bare pre-origin mapping decided this origin's offer: \(String(describing: preview.folders.first?.status))")
        try check(try harness.legacy.existingCloudImportMappings(accountPeerId: 42, principalScope: bareScope) == bare, "The preview changed the bare mappings")
        let result = try repository.commitLegacyImport(preview)
        try check(result.enqueuedLists == 1 && result.removedFromCloud == 0, "The explicit import did not enqueue a fresh copy: \(result)")
        let created = try SGTasksWire.MutationRequest(wireJSON: try harness.outboxBodies()[0])
        guard case let .listCreate(op) = created.operation else { throw CloudTestFailure.assertion("The explicit import enqueued no list create") }
        try check(created.mutationId.rawValue != bare[0].createMutationId && op.listId.rawValue != bare[0].cloudId, "This origin reused the bare mapping's identity")
        try check(try harness.legacy.existingCloudImportMappings(accountPeerId: 42, principalScope: bareScope) == bare, "The explicit import rewrote or removed the bare mappings")
    }
}
