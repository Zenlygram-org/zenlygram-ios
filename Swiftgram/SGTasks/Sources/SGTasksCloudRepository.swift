import Foundation
#if canImport(UIKit)
import UIKit
#endif
import SGEntitlement

// MARK: - Zenlygram Tasks cloud repository (one per native account)
//
// Owns the account's cloud store: server shadow, optimistic overlay (derived from unresolved outbox
// rows), durable outbox, sync cursors, held deletes and import enqueue. Every local mutation and its
// business-operation enqueue commit in ONE SQLite transaction on `queue`. Network results are fenced:
// once the account is purged the instance is invalidated and a late response can neither write nor
// reopen its store. The UI reads `state` and observes `didChangeNotification`; it never runs SQL or
// an independent sync worker. No credential, JWS, nonce or creation proof is ever persisted here.

public final class SGTasksCloudRepository {
    public static let didChangeNotification = Notification.Name("SGTasksCloudRepositoryDidChange")
    /// R4: the server answered 403 `tasks_consent_required` (any route, a batch item, realtime);
    /// `userInfo["accountPeerId"]`: Int64, `["effectiveAt"]`: String (wire instant) when given.
    /// Posted on the main queue each time a fence is recorded; the sync coordinator relays it.
    public static let consentFencedNotification = Notification.Name("SGTasksCloudRepositoryConsentFenced")

    // MARK: Traffic permission (design 30 §5.1; fail closed)

    private static let permissionLock = NSLock()
    private static var permissionSource: (Int64) -> SGTasksSyncPermission = { _ in .forbidden }

    /// Whether an account may send Tasks requests at all. The default answers `.forbidden` for every
    /// account: no Tasks request (realtime included) until the sync coordinator installs the real
    /// source. Host cases that exercise R3 behaviour install `{ _ in .legacy }` explicitly. Read on
    /// every decision (never cached); the coordinator calls `permissionChanged()` after a change.
    static var trafficPermission: (Int64) -> SGTasksSyncPermission {
        get {
            self.permissionLock.lock()
            defer { self.permissionLock.unlock() }
            return self.permissionSource
        }
        set {
            self.permissionLock.lock()
            self.permissionSource = newValue
            self.permissionLock.unlock()
        }
    }

    struct Environment {
        /// This build's cloud root: scoped to the backend origin it talks to.
        let files: SGTasksCloudStoreFiles
        /// The single cloud root of builds before origin scoping. Never opened, read, copied or
        /// imported from; only an explicit logout (`purgeAccount`) or the last logout
        /// (`removeAllCloudData`) purges the owned stores in it. Launch reconciliation never does.
        let preOriginFiles: SGTasksCloudStoreFiles
        /// The validated backend origin this build talks to — the same one `files` is scoped to.
        /// Explicit-import mappings are scoped by it together with the server principal, so the
        /// same principal on another origin never inherits this origin's import identities.
        let originScope: SGEntitlementStoreScope
        let transport: SGTasksCloudTransport
        let legacy: () -> TodoDatabase
        let now: () -> Date
        let holdDuration: TimeInterval
        let pollInterval: TimeInterval
        /// false in host tests: cycles run only through `syncNow()`.
        let automaticSync: Bool
        let notificationCenter: NotificationCenter
        let observesApplicationLifecycle: Bool
        /// Content-free realtime hints (nil: none — host tests that do not exercise them, and
        /// builds without the entitlement facade).
        var realtime: SGTasksCloudRealtimeEnvironment? = nil
        /// Arms the repository's bounded REST poll on its own queue. Production (and every case that
        /// does not set it) is `queue.asyncAfter`; host tests inject a manual clock advanced on the
        /// same queue. Cancellation stays the work item's own (`pollWork.cancel()`).
        var schedulePoll: (DispatchQueue, TimeInterval, DispatchWorkItem) -> Void = { queue, delay, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        /// The local create gate (§7.4: a refused user create is requeued automatically only while
        /// it allows creating). Production: `SGEntitlement.shared.gate(.createTask)`.
        var creationAllowed: (Int64) -> Bool = { _ in true }
        /// The durable, per-account records outside the purgeable store (wf15 §5.3: the manual
        /// invitation answers, `sgtasks.inviteAnswers.<accountPeerId>`). Production: `.standard`;
        /// host tests inject a suite of their own.
        var defaults: UserDefaults = .standard

        static func production() -> Environment {
            #if !SGTASKS_HOST_TESTS
            let transport: SGTasksCloudTransport = SGTasksCloudEntitlementTransport.shared
            let originScope = SGEntitlementStoreScope.shipped
            let realtime: SGTasksCloudRealtimeEnvironment? = SGTasksCloudRealtimeEnvironment(
                service: SGTasksCloudEntitlementRealtimeService.shared,
                makeScheduler: { queue in SGTasksRealtimeDispatchScheduler(queue: queue) },
                random: { Double.random(in: 0 ..< 1) }
            )
            let creationAllowed: (Int64) -> Bool = { _ in SGEntitlement.shared.gate(.createTask).isAllowed }
            #else
            // Host builds have no shipped configuration (SG_CONFIG); they never reach a backend.
            let transport: SGTasksCloudTransport = SGTasksCloudUnconfiguredTransport()
            let originScope = SGEntitlementStoreScope.unconfigured
            let realtime: SGTasksCloudRealtimeEnvironment? = nil
            let creationAllowed: (Int64) -> Bool = { _ in true }
            #endif
            let base = SGTasksCloudStoreFiles.applicationSupportBase()
            let fileSystem = SGTasksCloudDefaultFileSystem.shared
            return Environment(
                files: SGTasksCloudStoreFiles(directory: SGTasksCloudStoreFiles.originDirectory(in: base, originToken: originScope.storageToken), fileSystem: fileSystem),
                preOriginFiles: SGTasksCloudStoreFiles(directory: SGTasksCloudStoreFiles.legacyDirectory(in: base), fileSystem: fileSystem),
                originScope: originScope,
                transport: transport,
                legacy: { TodoDatabase.shared },
                now: Date.init,
                holdDuration: 8.0,
                pollInterval: 60.0,
                automaticSync: true,
                notificationCenter: .default,
                observesApplicationLifecycle: true,
                realtime: realtime,
                creationAllowed: creationAllowed
            )
        }
    }

    // Bounded automatic retry: after this many failed automatic attempts an entry is `stalled` and
    // only an explicit user retry sends it again (same sealed identity).
    static let maximumAutomaticAttempts = 8
    static let retryBaseDelay: TimeInterval = 2.0
    static let retryMaximumDelay: TimeInterval = 300.0
    static let defaultRateLimitDelay: TimeInterval = 60.0
    static let maximumSnapshotPages = 200
    static let maximumChangePagesPerCycle = 50
    static let maximumSendsPerCycle = 50

    // MARK: Registry and lifecycle hooks

    private static let registryLock = NSRecursiveLock()
    private static var registry: [Int64: SGTasksCloudRepository] = [:]
    static var environment = Environment.production()

    /// The shared repository for a native account (`account.peerId.toInt64()`). An instance whose
    /// store could not be opened (e.g. an unfinished purge) is replaced on the next access, so the
    /// open — and the pending purge before it — is retried instead of staying closed for the process.
    public static func repository(accountPeerId: Int64) -> SGTasksCloudRepository {
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        if let existing = self.registry[accountPeerId], !existing.isInvalidated {
            if existing.onQueue({ existing.store != nil }) {
                return existing
            }
            existing.invalidate()
        }
        let repository = SGTasksCloudRepository(accountPeerId: accountPeerId, environment: self.environment)
        self.registry[accountPeerId] = repository
        return repository
    }

    /// Per-account logout / removal (the explicit account-removal path, never launch
    /// reconciliation). Synchronous: fences and cancels the account's work, closes and unlinks its
    /// cloud store (shadow, shared cache, overlay, outbox, cursors, holds), then this account's
    /// store in the pre-origin root, if any. Fail-closed: an incomplete unlink leaves a durable
    /// marker and the account opens as storage-unavailable. The content-free legacy import mapping
    /// is intentionally kept (removed by the final wipe).
    public static func purgeAccount(accountPeerId: Int64) {
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        self.purgeCurrentStore(accountPeerId: accountPeerId)
        self.purgePreOriginStore(accountPeerId: accountPeerId)
    }

    /// Launch reconciliation: removes the current-root stores of accounts that are no longer
    /// signed in. It may run at the origin cutover against a still-empty current root, so it never
    /// touches the pre-origin root (that is left to explicit logout and the last logout).
    public static func reconcileAccounts(activeAccountPeerIds: Set<Int64>) {
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        var candidates = Set(self.registry.keys)
        if let stored = self.environment.files.storedAccountPeerIds() {
            candidates.formUnion(stored)
        } else {
            print("[SGTasksCloud] store directory unreadable; reconciliation retried on next launch")
        }
        for accountPeerId in candidates where !activeAccountPeerIds.contains(accountPeerId) {
            self.purgeCurrentStore(accountPeerId: accountPeerId)
        }
    }

    /// Final logout of the last account: every account store goes, in both roots.
    public static func removeAllCloudData() {
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        var candidates = Set(self.registry.keys)
        candidates.formUnion(self.environment.files.storedAccountPeerIds() ?? [])
        for accountPeerId in candidates {
            self.purgeCurrentStore(accountPeerId: accountPeerId)
        }
        guard let preOrigin = self.environment.preOriginFiles.storedAccountPeerIds() else {
            print("[SGTasksCloud] pre-origin directory unreadable; its stores stay until the next logout")
            return
        }
        for accountPeerId in preOrigin {
            self.purgePreOriginStore(accountPeerId: accountPeerId)
        }
    }

    /// Under `registryLock`. The account's store in this build's root, with its live instance.
    private static func purgeCurrentStore(accountPeerId: Int64) {
        let live = self.registry.removeValue(forKey: accountPeerId)
        if let live = live {
            live.onQueue { live.flushPendingImportAcks() }
            live.invalidate()
        }
        if !self.environment.files.purge(accountPeerId: accountPeerId) {
            print("[SGTasksCloud] purge incomplete; account store stays fenced")
        }
    }

    /// Under `registryLock`. Only this account's files in the pre-origin root (never opened, so
    /// there is no connection to close); an account that has none there is not touched at all.
    private static func purgePreOriginStore(accountPeerId: Int64) {
        let files = self.environment.preOriginFiles
        if let stored = files.storedAccountPeerIds(), !stored.contains(accountPeerId) {
            return
        }
        if !files.purge(accountPeerId: accountPeerId) {
            print("[SGTasksCloud] pre-origin purge incomplete; retried by the next logout")
        }
    }

    /// Unsent (not yet acknowledged) USER changes (`origin = user`), the deferred assignments of
    /// wf15 §12.2 included (they wait outside the outbox and die with the store); nil when it cannot
    /// be read. Never pretend zero. Pending migration creates are not counted: they are re-derived
    /// from the local archive (`unsentChangeCounts` reports them).
    public static func unsentChangeCount(accountPeerId: Int64) -> Int? {
        return self.unsentChangeCounts(accountPeerId: accountPeerId)?.user
    }

    /// Unsent changes split by origin (`user` includes the deferred assignments); nil = unknown
    /// (never a fake zero). Live from the open repository, else from the file.
    public static func unsentChangeCounts(accountPeerId: Int64) -> (user: Int, migration: Int)? {
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        if let live = self.registry[accountPeerId], !live.isInvalidated {
            return live.unsentCounts()
        }
        let files = self.environment.files
        if files.hasPendingPurge(accountPeerId: accountPeerId) {
            return nil
        }
        guard files.storeExists(accountPeerId: accountPeerId) else { return (user: 0, migration: 0) }
        do {
            let connection = try SGTasksCloudSQLite(path: files.path(accountPeerId: accountPeerId), readOnly: true)
            defer { connection.close() }
            return try SGTasksCloudStore.unsentCounts(connection)
        } catch {
            return nil
        }
    }

    /// The registry holds a non-invalidated repository of the account (one whose store did not open
    /// included: the next `repository(accountPeerId:)` replaces it).
    static func hasLiveRepository(accountPeerId: Int64) -> Bool {
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        guard let live = self.registry[accountPeerId] else { return false }
        return !live.isInvalidated
    }

    /// The withdrawal discard on the account's bare store, for `retireForConsentWithdrawal` while
    /// no repository of the account is open in this process (the launch re-run of a withdrawal,
    /// design 40 §6.6): no repository is built, so its outbox and board are not decoded. nil = not
    /// taken (a repository is open, the store does not open, or the transaction threw and rolled
    /// back); the caller then discards through the repository. Holds `registryLock` for the whole
    /// call and hops to no queue. Production creates repositories only through
    /// `repository(accountPeerId:)`, under this lock, so with none registered no migration step can
    /// be in flight and nothing else writes the store; an instance outside the registry (host tests
    /// only) would make this a second writer whose in-memory flag and board never change. A
    /// repository opened later reads `consent_withdrawn` at open (`recoverAfterOpen`) and refuses
    /// every outbox insert until `resumeAfterConsentRegrant`.
    /// Written here, exactly: every non-acknowledged outbox row deleted, `consent_withdrawn` = 1,
    /// `consent_epoch` + 1, the three consent-fence keys cleared, and the WAL folded (a TRUNCATE
    /// checkpoint; closing the only connection folds it as well). Left to the next
    /// repository open, harmlessly: the content-free `import_ack_pending` ids (a no-op flush once
    /// `releaseCloudDevice(.withdrawn)` has deleted the account's mappings), the once-per-store
    /// `batch_refusals_repaired` repair and the undecodable-shadow cleanup, and the quarantine of an
    /// acknowledged row the current codec cannot decode (it stays `acked` until then). Returns the
    /// discarded USER changes.
    static func discardWithoutRepository(accountPeerId: Int64) -> Int? {
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        guard !Self.hasLiveRepository(accountPeerId: accountPeerId) else { return nil }
        guard let store = Self.openStore(files: self.environment.files, accountPeerId: accountPeerId) else { return nil }
        defer { store.close() }
        guard let discarded = try? Self.withdrawalDiscard(store) else { return nil }
        // The discarded rows held the user's text: fold the WAL back, as the repository does.
        try? store.checkpoint()
        return discarded
    }

    // MARK: Instance

    public let accountPeerId: Int64
    let environment: Environment
    let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    var store: SGTasksCloudStore?
    private(set) var isInvalidated = false

    private let stateLock = NSLock()
    private var cachedState = SGTasksCloudState.empty
    /// The server account whose data `cachedState` presents: the store's bound principal when it
    /// was built; nil when it presents nothing account-scoped (unbound store, no store, failed read,
    /// invalidated). Written together with `cachedState` under `stateLock`.
    private var cachedStatePrincipal: String?
    var phase: SGTasksCloudState.Phase = .idle
    /// Durable pause (not linked / no session / invalid session / not configured): no automatic
    /// cycle until a session change notification or an explicit refresh. A not-configured pause
    /// also ends when a configured build starts the board or runs a cycle; a build without a
    /// backend records no pause at all (its phase is notConfigured regardless).
    var pauseReason: String?

    var isStarted = false
    var isCycleRunning = false
    var isCycleRequested = false
    var pullFailures = 0
    /// The canonical server account the running cycle captured, and the fence generation; a
    /// principal change (rebind/merge on the same native account) bumps the generation, so results
    /// of requests made for the previous principal are never applied.
    var cyclePrincipal: String?
    var cycleGeneration: UInt64 = 0
    var principalGeneration: UInt64 = 0
    /// Shared content was removed in a write; fold the WAL back after that transaction.
    var needsPrivacyCheckpoint = false
    /// The next cycle was requested by the user (may pass a local offline backoff, never a
    /// server Retry-After).
    var pendingExplicitCycle = false
    private var pollWork: DispatchWorkItem?
    private var holdTimers: [Int64: DispatchWorkItem] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Content-free realtime hints for this account (`SGTasksCloudRealtime`); on queue.
    var realtime: SGTasksCloudRealtime?
    /// The app is in the foreground (tracked from the lifecycle notifications; a board is only
    /// started while visible). On queue.
    var isForeground = true
    /// What the board may say about realtime; under `stateLock`.
    private var cachedRealtimeStatus: SGTasksCloudRealtimeStatus = .off
    /// Durable `consent_withdrawn` (meta), mirrored on the queue: no request and no outbox insert
    /// while set (`discardAfterConsentWithdrawal` until `resumeAfterConsentRegrant`).
    var isConsentWithdrawn = false
    /// The app-level driver runs this account's cycles (launch, foreground, timer, ...); a driven
    /// repository continues at once while its cycle left eligible entries. On queue.
    var isDriven = false
    /// What the cycle that just ended acknowledged (continuation). On queue.
    var lastCycleAcknowledged = 0
    /// The running cycle runs the R4 engine (`permission == .allowed`), captured at its start so
    /// one cycle never mixes engines. On queue.
    var cycleIsR4 = false
    /// The contract §3.4 code of the running cycle's failure, emitted once as `error.occurred`
    /// (`tasks_sync`) when the cycle ends. On queue.
    var cycleErrorCode: String?
    /// Mutation ids of a multi-item batch a 422 refused as a whole: while one of them is still
    /// queued and was not sent alone, every batch carries one entry (`SGTasksCloudBatch`). On queue,
    /// in memory only.
    var batchSplitIds = Set<String>()
    /// Waiters for the running cycles to end (`flush`). On queue.
    private var cycleWaiters: [() -> Void] = []
    /// wf15 §5.3 (D2): the last device-local inputs of the automatic accept the coordinator handed
    /// in (`runAutoAccept`); every pull re-runs the policy with them. nil until the first call
    /// (nothing is accepted automatically before the coordinator knows the contacts) and again
    /// once the coordinator tore its sources down, the permission stopped being `allowed` or the
    /// consent was withdrawn (`clearAutoAcceptInputs`). On queue.
    var autoAcceptInputs: SGTasksAutoAcceptInputs?

    init(accountPeerId: Int64, environment: Environment) {
        self.accountPeerId = accountPeerId
        self.environment = environment
        self.queue = DispatchQueue(label: "uz.zenlygram.tasks.cloud.\(accountPeerId)")
        self.queue.setSpecific(key: self.queueKey, value: true)
        self.store = self.openStore()
        self.onQueue {
            self.recoverAfterOpen()
            self.rebuildState(notify: false)
        }
        self.installObservers()
        if let realtime = environment.realtime {
            self.realtime = Self.makeRealtime(for: self, environment: realtime)
        }
    }

    deinit {
        for observer in self.observers {
            self.environment.notificationCenter.removeObserver(observer)
        }
    }

    private func openStore() -> SGTasksCloudStore? {
        return Self.openStore(files: self.environment.files, accountPeerId: self.accountPeerId)
    }

    /// The account's store in `files`, created when missing (the repository's open and the bare
    /// withdrawal discard, `discardWithoutRepository`); nil when it cannot be opened.
    private static func openStore(files: SGTasksCloudStoreFiles, accountPeerId: Int64) -> SGTasksCloudStore? {
        if files.hasPendingPurge(accountPeerId: accountPeerId) {
            // Finish the earlier purge first; never read an old account's shadow on re-login.
            guard files.purge(accountPeerId: accountPeerId) else { return nil }
        }
        do {
            try files.prepareDirectory()
            let store = try SGTasksCloudStore(path: files.path(accountPeerId: accountPeerId))
            do {
                try files.applyFileProtection(accountPeerId: accountPeerId)
            } catch {
                store.close()
                return nil
            }
            return store
        } catch {
            return nil
        }
    }

    /// Restart recovery: interrupted sends resume with the same sealed identity; surviving holds
    /// are promoted because their UI handle is gone; undecodable sealed rows are quarantined.
    private func recoverAfterOpen() {
        guard let store = self.store else { return }
        do {
            try store.transaction {
                try store.requeueInterruptedSends()
                for entry in try store.entries() {
                    // Any sealed mutation (an R4 `task.patch` included) restores; only bytes that
                    // decode as none of them, or not as the kind recorded beside them, are quarantined.
                    let restored = try? SGTasksWire.SealedMutation(wireJSON: entry.body)
                    if restored?.kind != entry.kind, entry.state != .quarantined {
                        try store.setState(seq: entry.seq, .quarantined)
                    }
                }
                // Once per store: what an older build marked invalid for a whole-batch 422.
                try self.repairBatchRefusals(store: store)
            }
            self.isConsentWithdrawn = try store.meta("consent_withdrawn") == "1"
            self.pauseReason = try store.meta("pause")
            if self.pauseReason != nil {
                self.phase = Self.phase(forPause: self.pauseReason)
            }
            for entry in try store.entries() where entry.state == .held {
                self.promoteHoldOnQueue(seq: entry.seq)
            }
            self.flushPendingImportAcks()
        } catch {
            self.failStorage()
        }
    }

    private func installObservers() {
        let center = self.environment.notificationCenter
        if let name = self.environment.transport.sessionChangeNotification {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.resumeAfterSessionChange()
            })
        }
        #if canImport(UIKit)
        if self.environment.observesApplicationLifecycle {
            self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.promoteAllHolds()
                self?.applicationDidEnterBackground()
            })
            self.observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.applicationWillEnterForeground()
            })
        }
        #endif
    }

    // MARK: Queue and state plumbing

    @discardableResult
    func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: self.queueKey) == true {
            return try body()
        }
        return try self.queue.sync(execute: body)
    }

    /// The board to show. Pure: no SQL, no queue hop, no rebuild — callable from any thread, on the
    /// queue included. While the bound server account differs from the one the cached board was
    /// built for (a rebind whose fence has not run yet: the session notice is queued on main), the
    /// previous account's board is withheld; the fence's rebuild then publishes the new one.
    public var state: SGTasksCloudState {
        // Outside `stateLock`: the principal source takes its own lock.
        let boundPrincipal = self.environment.transport.principal(accountPeerId: self.accountPeerId)
        self.stateLock.lock()
        let cached = self.cachedState
        let cachedScope = self.cachedStatePrincipal
        self.stateLock.unlock()
        guard let current = boundPrincipal, let scope = cachedScope, current != scope else {
            // Same principal, no session (offline/signed out keeps the board) or nothing scoped.
            return cached
        }
        return Self.withheldState(cached)
    }

    /// Whether the board is kept current by realtime hints (`live`) or by the 60 s REST refresh
    /// (`fallback` / `disabled`). Pure, like `state`; changes post `didChangeNotification`.
    public var realtimeStatus: SGTasksCloudRealtimeStatus {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.cachedRealtimeStatus
    }

    /// On queue (the controller's status hook).
    func publishRealtimeStatus(_ status: SGTasksCloudRealtimeStatus) {
        self.stateLock.lock()
        let changed = self.cachedRealtimeStatus != status
        self.cachedRealtimeStatus = status
        self.stateLock.unlock()
        if changed {
            self.postChange()
        }
    }

    /// What may be shown before a rebind is fenced: the phase verbatim (storage/configuration
    /// gates and the consent hold stay visible) and the native account's own Telegram id — nothing of the previous
    /// account's board, entries or sync metadata, and never a complete (empty-success) board.
    private static func withheldState(_ state: SGTasksCloudState) -> SGTasksCloudState {
        var withheld = SGTasksCloudState.empty
        withheld.phase = state.phase
        withheld.phaseRefinement = state.phaseRefinement
        withheld.ownTelegramId = state.ownTelegramId
        return withheld
    }

    private func invalidate() {
        self.onQueue {
            self.isInvalidated = true
            // Purge / logout: the socket closes and every realtime timer and callback is dead.
            self.realtime?.stop()
            self.realtime = nil
            self.pollWork?.cancel()
            self.pollWork = nil
            for (_, work) in self.holdTimers {
                work.cancel()
            }
            self.holdTimers.removeAll()
            self.store?.close()
            self.store = nil
            self.stateLock.lock()
            self.cachedState = .empty
            self.cachedStatePrincipal = nil
            self.stateLock.unlock()
        }
    }

    func failStorage() {
        self.store?.close()
        self.store = nil
        self.phase = .storageUnavailable
        self.updateRealtime()
    }

    private func unsentCounts() -> (user: Int, migration: Int)? {
        return self.onQueue {
            guard let store = self.store else { return nil }
            return try? store.unsentCounts()
        }
    }

    /// Recomputes the visible board from shadow + overlay. Undecodable shadow rows are dropped and a
    /// full resnapshot is requested (integrity: never show bytes the strict codec refuses).
    func rebuildState(notify: Bool = true) {
        self.checkpointIfNeeded()
        var next = SGTasksCloudState.empty
        if self.store == nil && !self.isInvalidated {
            next.phase = .storageUnavailable
        } else if self.store != nil && !self.environment.transport.isConfigured {
            // No backend in this build: that, not a missing session or link, is what the board says.
            next.phase = .notConfigured
        } else {
            next.phase = self.phase
        }
        var nextScope: String?
        if let store = self.store {
            do {
                var projections: [SGTasksWire.Projection] = []
                // The shadow belongs to the stored server account; when another one is bound now (the
                // fence has not run yet), none of it is shown.
                let currentPrincipal = self.environment.transport.principal(accountPeerId: self.accountPeerId)
                let storedPrincipal = try store.meta("principal")
                let shadowVisible = currentPrincipal == nil || storedPrincipal == nil || currentPrincipal == storedPrincipal
                for row in shadowVisible ? try store.rows(.shadow) : [] {
                    if let projection = try? SGTasksWire.Projection(wireJSON: row.body) {
                        projections.append(projection)
                    } else {
                        try store.remove(.shadow, kind: row.kind, id: row.id)
                        try store.setMeta("needs_resnapshot", "1")
                    }
                }
                var decoded: [SGTasksCloudDecodedEntry] = []
                var undecodable: [SGTasksCloudEntry] = []
                for entry in try store.entries() {
                    if let mutation = try? SGTasksWire.SealedMutation(wireJSON: entry.body), mutation.kind == entry.kind {
                        decoded.append(SGTasksCloudDecodedEntry(stored: entry, mutation: mutation))
                    } else {
                        undecodable.append(SGTasksCloudEntry(id: entry.seq, kind: entry.operationClass, resourceId: "", status: .integrityQuarantine, attempts: entry.attempts, nextAttemptAt: nil, displayTitle: nil, lastServerTime: entry.serverTime, mutationKind: entry.kind))
                    }
                }
                let ownId = self.environment.transport.ownTelegramId(accountPeerId: self.accountPeerId)
                let board = SGTasksCloudOverlay.build(shadow: projections, entries: decoded, ownTelegramId: ownId)
                next.lists = board.lists
                next.tasks = board.tasks
                next.invitations = board.invitations
                next.blocks = board.blocks
                next.entries = (board.entries + undecodable).sorted { $0.id < $1.id }
                next.notices = try store.notices()
                next.resolutionNotices = try store.resolutionNotices()
                next.deferredAssignments = try Self.deferredAssignments(store)
                next.automaticAcceptInvitationIds = try Self.automaticAcceptInvitationIds(store)
                next.ownTelegramId = ownId
                next.hasCompleteSnapshot = try store.meta("snapshot_complete") == "1"
                next.lastSyncedAt = try store.meta("last_synced_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                next.serverTime = try store.meta("server_time").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                next.serverTimeReceivedAt = try store.meta("server_time_received_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                // An unbound store holds no server-account data yet (its drafts adopt the first
                // binding), so only a bound one can be shown under the wrong account.
                nextScope = storedPrincipal
            } catch {
                self.failStorage()
                next = .empty
                next.phase = .storageUnavailable
            }
        }
        next.phaseRefinement = self.currentPhaseRefinement()
        self.stateLock.lock()
        // A scope change alone is published too: a subscriber shown the withheld board must re-read
        // once the fence rebinds the store, even when the rebuilt board compares equal.
        let changed = self.cachedState != next || self.cachedStatePrincipal != nextScope
        self.cachedState = next
        self.cachedStatePrincipal = nextScope
        self.stateLock.unlock()
        if notify && changed {
            self.postChange()
        }
    }

    private func postChange() {
        let center = self.environment.notificationCenter
        let accountPeerId = self.accountPeerId
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isInvalidated else { return }
            center.post(name: Self.didChangeNotification, object: self, userInfo: ["accountPeerId": accountPeerId])
        }
    }

    /// Runs one atomic local change (projection + enqueue) and refreshes the board.
    func mutate<T>(_ body: (SGTasksCloudStore, SGTasksCloudState) throws -> T) throws -> T {
        return try self.onQueue {
            guard !self.isInvalidated else { throw SGTasksCloudError.accountRemoved }
            // Never decide a new local change against a previous server account's data.
            self.fenceIfPrincipalChanged()
            guard let store = self.store else { throw SGTasksCloudError.storageUnavailable }
            let current = self.state
            let result: T
            do {
                result = try store.transaction { try body(store, current) }
            } catch let error as SGTasksCloudError {
                throw error
            } catch is SGTasksCloudStoreError {
                if !store.isOpen { self.failStorage() }
                self.rebuildState()
                throw SGTasksCloudError.storageUnavailable
            }
            self.rebuildState()
            self.requestCycle(explicit: false)
            return result
        }
    }

    static let notConfiguredPause = "not_configured"

    /// On queue. A `not_configured` pause records a build without a Tasks backend, nothing about
    /// the account. Once this build has one it is stale and ends here — and only it: not-linked,
    /// no-session and invalid-session pauses are never ended by configuration.
    func leaveStaleConfigurationPause() {
        guard self.pauseReason == Self.notConfiguredPause, self.environment.transport.isConfigured else { return }
        self.setPause(nil)
    }

    static func phase(forPause reason: String?) -> SGTasksCloudState.Phase {
        switch reason {
        case "not_linked": return .pausedNotLinked
        case "not_signed_in": return .notSignedIn
        case Self.notConfiguredPause: return .notConfigured
        case "session_invalid": return .sessionInvalid
        default: return .idle
        }
    }

    // MARK: Lifecycle

    /// Board visible: run a cycle now and keep bounded polling while started. A configured build
    /// first leaves a stale not-configured pause (only that one; then the usual principal fence).
    public func start() {
        self.onQueue {
            guard !self.isInvalidated else { return }
            self.isStarted = true
            self.leaveStaleConfigurationPause()
            self.fenceIfPrincipalChanged()
            self.requestCycle(explicit: false)
            self.updateRealtime()
        }
    }

    /// Board departure: stops polling and promotes held deletes (their Undo handle is leaving).
    public func stop() {
        self.onQueue {
            self.isStarted = false
            self.pollWork?.cancel()
            self.pollWork = nil
            self.updateRealtime()
        }
        self.promoteAllHolds()
    }

    static let notLinkedPause = "not_linked"

    /// Explicit user refresh: runs a cycle and clears a session-type pause (no session, invalid
    /// session, not configured). It never clears the `tasks_account_not_linked` pause: only a
    /// completed Telegram link does (`resumeAfterLinking`).
    public func refresh() {
        self.onQueue {
            guard !self.isInvalidated else { return }
            self.fenceIfPrincipalChanged()
            self.requestCycle(explicit: true)
        }
    }

    /// Call ONLY after the existing Telegram linking flow reported a completed link for this
    /// account: clears the not-linked pause and resumes the same business ids (a rejected cursor
    /// resnapshots). A refused attempt simply pauses again; nothing is wiped.
    public func resumeAfterLinking() {
        self.onQueue {
            guard !self.isInvalidated else { return }
            self.fenceIfPrincipalChanged()
            if self.pauseReason == Self.notLinkedPause {
                self.setPause(nil)
            }
            self.requestCycle(explicit: true)
        }
    }

    /// Session/link changes (rotation, policy refresh, re-sign-in) may end a session-type pause;
    /// they never end the not-linked pause.
    private func resumeAfterSessionChange() {
        self.onQueue {
            guard !self.isInvalidated else { return }
            // A rebind/merge is fenced immediately, paused or not.
            self.fenceIfPrincipalChanged()
            // Realtime: a changed principal tears down (update); a changed session under the same
            // principal revalidates the socket's channel (rotation keeps it, re-bind replaces it).
            self.updateRealtime()
            self.realtime?.sessionChanged()
            guard let reason = self.pauseReason else { return }
            if reason == Self.notLinkedPause {
                // Only a different binding than the one the server called unlinked ends it here.
                let paused = (try? self.store?.meta("pause_binding")) ?? nil
                guard self.environment.transport.bindingMarker(accountPeerId: self.accountPeerId) != paused else { return }
                self.setPause(nil)
                self.rebuildState()
            }
            self.requestCycle(explicit: true)
        }
    }

    func setPause(_ reason: String?) {
        self.pauseReason = reason
        try? self.store?.setMeta("pause", reason)
        // A not-linked pause belongs to the binding it was answered for: a NEW binding (re-bind,
        // another server account) ends it at the next session change, never a refresh rotation.
        let binding = reason == Self.notLinkedPause ? self.environment.transport.bindingMarker(accountPeerId: self.accountPeerId) : nil
        try? self.store?.setMeta("pause_binding", binding)
        self.phase = Self.phase(forPause: reason)
        self.updateRealtime()
    }

    /// On queue. Single-flight; automatic requests are ignored while paused, and an explicit
    /// request clears every pause except not-linked.
    func requestCycle(explicit: Bool) {
        guard !self.isInvalidated, self.store != nil else { return }
        if explicit, let reason = self.pauseReason, reason != Self.notLinkedPause {
            self.setPause(nil)
        }
        if explicit {
            self.pullFailures = 0
        }
        if self.pauseReason != nil {
            return
        }
        if explicit {
            self.pendingExplicitCycle = true
        }
        guard self.environment.automaticSync else { return }
        if self.isCycleRunning {
            self.isCycleRequested = true
            return
        }
        self.isCycleRunning = true
        self.pollWork?.cancel()
        self.pollWork = nil
        Task { [self] in
            await self.runCycles()
        }
    }

    private func runCycles() async {
        while true {
            self.onQueue { self.isCycleRequested = false }
            await self.performCycle()
            let again: Bool = self.onQueue {
                if self.isCycleRequested && !self.isInvalidated && self.pauseReason == nil {
                    return true
                }
                if self.shouldContinueDriving() {
                    return true
                }
                self.cyclesEnded()
                return false
            }
            if !again { return }
        }
    }

    /// On queue. The single-flight cycle loop ended: wake `flush` waiters, arm the board's poll.
    func cyclesEnded() {
        self.isCycleRunning = false
        let waiters = self.cycleWaiters
        self.cycleWaiters.removeAll()
        for waiter in waiters {
            waiter()
        }
        self.scheduleNextCycle()
    }

    /// On queue. Continuation (§7.2): a driven repository whose cycle made progress and left due,
    /// eligible entries — with no account gate, pause or consent hold — runs the next cycle at once.
    private func shouldContinueDriving() -> Bool {
        guard self.isDriven, self.lastCycleAcknowledged > 0, !self.isInvalidated, self.pauseReason == nil, self.permitsTraffic, self.isGateOpen() else {
            return false
        }
        guard let next = self.nextSendDate() else { return false }
        return next <= self.environment.now()
    }

    /// Bounded active sync, only while started: the poll interval, shortened only by a send that
    /// can actually happen (same eligibility as the drain) and never earlier than the account gate.
    /// Blocked chains, held deletes and unsealed rows waiting for a sync do not wake the loop.
    private func scheduleNextCycle() {
        // Without a backend there is nothing to poll for (a session change still requests a cycle);
        // under a consent hold nothing may be asked (`permissionChanged` requests the next cycle).
        guard self.isStarted, !self.isInvalidated, self.pauseReason == nil, self.environment.transport.isConfigured, self.permitsTraffic else { return }
        let now = self.environment.now()
        var target = now.addingTimeInterval(self.environment.pollInterval)
        if let send = self.nextSendDate() {
            target = min(target, send)
        }
        if let gate = self.accountGate(), gate.until > target {
            target = gate.until
        }
        let delay = max(target.timeIntervalSince(now), 1.0)
        let work = DispatchWorkItem { [weak self] in
            self?.requestCycle(explicit: false)
        }
        self.pollWork = work
        self.environment.schedulePoll(self.queue, delay, work)
    }

    static func backoff(attempt: Int) -> TimeInterval {
        let exponent = Double(max(attempt - 1, 0))
        return min(Self.retryBaseDelay * pow(2.0, exponent), Self.retryMaximumDelay)
    }

    // MARK: Held deletes (durable Undo)

    func scheduleHoldTimer(seq: Int64) {
        let work = DispatchWorkItem { [weak self] in
            self?.promoteHoldOnQueue(seq: seq)
        }
        self.holdTimers[seq] = work
        self.queue.asyncAfter(deadline: .now() + self.environment.holdDuration, execute: work)
    }

    func isHoldActive(seq: Int64, token: String) -> Bool {
        return self.onQueue {
            guard let entry = try? self.store?.entry(seq: seq) else { return false }
            return entry.state == .held && entry.holdToken == token
        }
    }

    /// Undo: atomically removes the hold; the task reappears with the same identity.
    func cancelHold(seq: Int64, token: String) -> Bool {
        return self.onQueue {
            guard !self.isInvalidated, let store = self.store else { return false }
            self.holdTimers.removeValue(forKey: seq)?.cancel()
            let removed = (try? store.transaction { try store.deleteHeld(seq: seq, token: token) }) ?? false
            self.rebuildState()
            return removed
        }
    }

    func promoteHold(seq: Int64) {
        self.onQueue {
            self.promoteHoldOnQueue(seq: seq)
        }
    }

    /// Exactly-once held -> queued. A never-sent create + delete cancels both locally.
    private func promoteHoldOnQueue(seq: Int64) {
        self.holdTimers.removeValue(forKey: seq)?.cancel()
        guard !self.isInvalidated, let store = self.store else { return }
        var promoted = false
        do {
            try store.transaction {
                guard let entry = try store.entry(seq: seq), entry.state == .held else { return }
                if entry.cancelsCreate, let taskKey = entry.keys.first(where: { $0.hasPrefix("task:") }) {
                    let chain = try store.entries().filter { $0.keys.contains(taskKey) }
                    if chain.allSatisfy({ !$0.sentOnce && $0.state != .acked }) {
                        for item in chain {
                            try store.deleteEntry(seq: item.seq)
                        }
                        promoted = true
                        return
                    }
                }
                if try store.promoteHeld(seq: seq) {
                    promoted = true
                }
            }
        } catch {
            if !store.isOpen { self.failStorage() }
        }
        if promoted {
            // The delete is the user's committed action now (an Undo can no longer take it back).
            self.emitAnalytics(.taskDeleted(cloud: true))
        }
        self.rebuildState()
        self.requestCycle(explicit: false)
    }

    /// App background / board departure: every outstanding hold commits.
    public func promoteAllHolds() {
        self.onQueue {
            guard !self.isInvalidated, let entries = try? self.store?.entries() else { return }
            for entry in entries where entry.state == .held {
                self.promoteHoldOnQueue(seq: entry.seq)
            }
        }
    }
}

// MARK: - R4: permission, driver, flush, consent withdrawal (design 30 §5.3)

extension SGTasksCloudRepository {
    /// The account's permission right now (the installed source; never cached).
    var permission: SGTasksSyncPermission {
        return Self.trafficPermission(self.accountPeerId)
    }

    /// On queue. Any Tasks request at all (REST or realtime) may be made: `allowed` or `legacy`,
    /// and no local withdrawal.
    var permitsTraffic: Bool {
        let permission = self.permission
        return (permission == .allowed || permission == .legacy) && !self.isConsentWithdrawn
    }

    /// `permitsTraffic` from any thread: what SGEntitlement asks (`stillWanted`) once the account's
    /// gate is held, before each attempt of a Tasks call. A request built before a withdrawal or a
    /// permission change, still waiting there behind a token rotation or a customer-data call, then
    /// sends nothing.
    func stillPermitsTraffic() -> Bool {
        return self.onQueue { self.permitsTraffic }
    }

    /// The post-gate re-check of ONE REST call (`SGTasksCloudTrafficCheck`): `stillPermitsTraffic`,
    /// remembering whether it refused the call.
    func trafficCheck() -> SGTasksCloudTrafficCheck {
        return SGTasksCloudTrafficCheck { [weak self] in
            return self?.stillPermitsTraffic() ?? false
        }
    }

    /// On queue. The R4 engine runs (batch drain, automatic resolution and retry): only `allowed`.
    /// `legacy` is exactly R3.
    var isR4Engine: Bool {
        return self.permission == .allowed && !self.isConsentWithdrawn
    }

    /// The `X-Tasks-Wire` value this build sends (`SGTasksCloudTransport.requestWire`: 4, or 5 for a
    /// build made for a wire-5 backend; wf15 §8.2). Any thread: a build constant behind the seam.
    /// R5-only behaviour (the assignee note, the background assignment hints) switches on this value
    /// together with the server's numeric echo (`SGTasksCloudOperations.serverWire`), never on the
    /// echo alone.
    var requestWire: Int {
        return self.environment.transport.requestWire
    }

    /// On queue. What `SGTasksCloudState.phaseRefinement` says now.
    func currentPhaseRefinement() -> SGTasksCloudState.PhaseRefinement? {
        let permission = self.permission
        if permission == .waiting || permission == .forbidden {
            return .consentRequired(waiting: permission == .waiting)
        }
        if self.isConsentWithdrawn {
            return .consentRequired(waiting: false)
        }
        if let fence = self.consentFence(), fence.until > self.environment.now() {
            return .consentFenced(effectiveAt: fence.effectiveAt)
        }
        return nil
    }

    /// The app-level driver takes this account (`SGTasksSyncCoordinator`); the board's own
    /// start/stop and its 60 s poll are unchanged.
    public func startDriving() {
        self.onQueue {
            guard !self.isInvalidated else { return }
            self.isDriven = true
        }
    }

    public func stopDriving() {
        self.onQueue {
            self.isDriven = false
        }
    }

    /// A driver occasion: the §7.4 automatic requeue for its reason (R4 engine only), then an
    /// automatic cycle (single-flight, gated, never past a server Retry-After).
    public func requestDrive(_ reason: SGTasksDriveReason) {
        self.onQueue {
            guard !self.isInvalidated, self.store != nil else { return }
            self.leaveStaleConfigurationPause()
            self.fenceIfPrincipalChanged()
            if self.isR4Engine {
                self.autoRequeue(for: reason)
            }
            self.requestCycle(explicit: false)
        }
    }

    /// The customer layer's gate changed for this account (`SGCustomerDataGate.didChangeNotification`
    /// via the coordinator): the consent hold is re-read, the server fence and its backoff are
    /// cleared, realtime follows, and a running board or driver gets a cycle.
    public func permissionChanged() {
        self.onQueue {
            guard !self.isInvalidated else { return }
            if self.permission != .allowed {
                // wf15 §5.3: the automatic accept's inputs do not outlive the permission they were
                // gathered under (the coordinator re-reads them after a re-grant, fail-closed).
                self.autoAcceptInputs = nil
            }
            if let store = self.store {
                let wasFenced = self.consentFence().map { $0.until > self.environment.now() } ?? false
                do {
                    try store.transaction {
                        try Self.clearConsentFence(store)
                    }
                } catch {
                    if !store.isOpen { self.failStorage() }
                }
                if wasFenced, case .unavailable = self.phase {
                    self.phase = .idle
                }
            }
            self.rebuildState()
            self.updateRealtime()
            if self.permitsTraffic && (self.isStarted || self.isDriven) {
                self.requestCycle(explicit: false)
            }
        }
    }

    /// Background entry: one bounded cycle now (or the running one plus a follow-up), whatever the
    /// board or driver state; returns the unsent counts when it ended or `timeout` passed (the cycle
    /// is not cancelled: its sends keep their identities). nil = unknown.
    public func flush(timeout: TimeInterval) async -> (user: Int, migration: Int)? {
        let wait: Bool = self.onQueue {
            guard !self.isInvalidated, self.store != nil else { return false }
            if self.isCycleRunning {
                self.isCycleRequested = true
            } else {
                self.isCycleRunning = true
                self.pollWork?.cancel()
                self.pollWork = nil
                Task { [self] in
                    await self.runCycles()
                }
            }
            return true
        }
        if wait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = SGTasksCloudResumeOnce(continuation)
                self.onQueue {
                    if self.isCycleRunning {
                        self.cycleWaiters.append { once.resume() }
                    } else {
                        once.resume()
                    }
                }
                self.queue.asyncAfter(deadline: .now() + max(timeout, 0)) {
                    once.resume()
                }
            }
        }
        return self.unsentCounts()
    }

    /// Consent withdrawn (customer layer, via `retireForConsentWithdrawal`): ONE transaction deletes
    /// every unacknowledged outbox row (held deletes included), sets `consent_withdrawn` and bumps
    /// `consent_epoch`; the driver stops, realtime closes, and from then on no request is made and
    /// every outbox insert is refused (`consentWithdrawn`) until `resumeAfterConsentRegrant`. The
    /// shadow stays as a read-only cache. Returns the discarded USER changes; nil when the store
    /// is unavailable (nothing was changed then).
    @discardableResult
    public func discardAfterConsentWithdrawal() -> Int? {
        return self.onQueue {
            guard !self.isInvalidated, let store = self.store else { return nil }
            for (_, work) in self.holdTimers {
                work.cancel()
            }
            self.holdTimers.removeAll()
            let discarded: Int
            do {
                discarded = try Self.withdrawalDiscard(store)
            } catch {
                if !store.isOpen { self.failStorage() }
                self.rebuildState()
                return nil
            }
            self.isConsentWithdrawn = true
            self.isDriven = false
            // The automatic accept's device-local inputs end with the consent: a re-grant waits for
            // the coordinator's fresh ones (contacts, blocked list and sender flags re-read).
            self.autoAcceptInputs = nil
            self.pollWork?.cancel()
            self.pollWork = nil
            // The discarded rows held the user's text: fold the WAL back.
            self.needsPrivacyCheckpoint = true
            self.updateRealtime()
            self.rebuildState()
            return discarded
        }
    }

    /// The withdrawal's store writes in ONE transaction (the repository's discard above and the bare
    /// one, `discardWithoutRepository`): every unacknowledged outbox row goes, `consent_withdrawn`
    /// is set, `consent_epoch` is bumped and the consent fence is cleared. Returns the discarded
    /// USER changes.
    private static func withdrawalDiscard(_ store: SGTasksCloudStore) throws -> Int {
        return try store.transaction {
            let user = try store.deleteUnacknowledged()
            try store.setMeta("consent_withdrawn", "1")
            try store.setMeta("consent_epoch", String(try store.consentEpoch() + 1))
            try Self.clearConsentFence(store)
            return user
        }
    }

    /// Consent granted again: one transaction deletes any unacknowledged migration row left over
    /// (defensive; the epoch check lets none in), clears `consent_withdrawn` and asks for a full
    /// snapshot (the server erased the account's data at the withdrawal).
    public func resumeAfterConsentRegrant() {
        self.onQueue {
            guard !self.isInvalidated, let store = self.store else { return }
            do {
                try store.transaction {
                    try store.deleteUnacknowledgedMigration()
                    try store.setMeta("consent_withdrawn", nil)
                    try store.setMeta("needs_resnapshot", "1")
                }
            } catch {
                if !store.isOpen { self.failStorage() }
                self.rebuildState()
                return
            }
            self.isConsentWithdrawn = false
            self.rebuildState()
            self.updateRealtime()
            self.requestCycle(explicit: false)
        }
    }

    /// The consent epoch now (the migration step captures it and passes it back as
    /// `expectedConsentEpoch`); nil when unreadable.
    func consentEpoch() -> Int64? {
        return self.onQueue {
            guard let store = self.store else { return nil }
            return try? store.consentEpoch()
        }
    }
}

/// Resumes a continuation exactly once, from whichever of its callers comes first.
final class SGTasksCloudResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume()
    }
}

/// A live Undo capability for one held task delete. Undo restores atomically; commit, deinit,
/// timeout, background, board departure and restart all promote the hold exactly once.
public final class SGTasksCloudUndoHandle {
    public let taskId: SGTasksWire.UUID
    private let repository: SGTasksCloudRepository
    private let seq: Int64
    private let token: String
    private let lock = NSLock()
    private var isFinished = false

    init(taskId: SGTasksWire.UUID, repository: SGTasksCloudRepository, seq: Int64, token: String) {
        self.taskId = taskId
        self.repository = repository
        self.seq = seq
        self.token = token
    }

    deinit {
        if self.finish() {
            self.repository.promoteHold(seq: self.seq)
        }
    }

    private func finish() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.isFinished { return false }
        self.isFinished = true
        return true
    }

    public var isValid: Bool {
        self.lock.lock()
        let finished = self.isFinished
        self.lock.unlock()
        return !finished && self.repository.isHoldActive(seq: self.seq, token: self.token)
    }

    @discardableResult
    public func undo() -> Bool {
        guard self.finish() else { return false }
        return self.repository.cancelHold(seq: self.seq, token: self.token)
    }

    public func commit() {
        guard self.finish() else { return }
        self.repository.promoteHold(seq: self.seq)
    }
}

#if SGTASKS_HOST_TESTS
/// Host builds without the entitlement module: every call honestly reports `notConfigured`.
final class SGTasksCloudUnconfiguredTransport: SGTasksCloudTransport {
    private func failure<T>() -> Result<T, SGTasksError> {
        return .failure(SGTasksError(kind: .notConfigured, retryAfter: nil, serverTime: nil, outcomeUnknown: false))
    }

    func mutation(_ request: SGTasksWire.SealedMutation, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationResponse, SGTasksError> {
        return self.failure()
    }

    func mutationBatch(_ request: SGTasksWire.MutationBatchRequest, accountPeerId: Int64, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        return self.failure()
    }

    func bindingMarker(accountPeerId: Int64) -> String? {
        return nil
    }

    func snapshot(accountPeerId: Int64, cursor: SGTasksWire.Cursor?, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.SnapshotResponse, SGTasksError> {
        return self.failure()
    }

    func changes(accountPeerId: Int64, cursor: SGTasksWire.Cursor, stillWanted: @escaping () -> Bool) async -> Result<SGTasksWire.ChangesResponse, SGTasksError> {
        return self.failure()
    }

    func ownTelegramId(accountPeerId: Int64) -> SGTasksWire.TelegramId? {
        return nil
    }

    func isLinked(accountPeerId: Int64) -> Bool {
        return false
    }

    func principal(accountPeerId: Int64) -> String? {
        return nil
    }

    var isConfigured: Bool {
        return false
    }

    var sessionChangeNotification: Notification.Name? {
        return nil
    }

    /// No backend, no request: the core's own wire.
    var requestWire: Int {
        return SGTasksWire.wireRevision
    }
}
#endif
