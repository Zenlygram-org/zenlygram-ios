import Foundation
import Network
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import SGEntitlement
import SGCustomerSyncCore

// MARK: - Zenlygram Tasks R4: the app-level sync coordinator (design 30 §5.1, §5.8)
//
// Production only: the main app, never an extension (`start` returns at once there), never a host
// script. The one SGTasks file that imports SGCustomerSyncCore, UIKit and Network. It gathers the
// inputs — the customer layer's gate, the signed-in accounts, the app lifecycle, the network path,
// the repositories' changes — and performs what the pure `SGTasksSyncPolicy` decides: each account's
// traffic permission, driving or stopping its repository, the re-grant resume, the consent-time
// claim and the migration steps of the device rows, the cut-over and the write fence of the local
// board, and the mapping of Tasks analytics onto `SGAnalytics`. wf15 §5.3 (D2): for every driven
// `allowed` account it also gathers the device-local inputs of the automatic accept — the account's
// Telegram contacts (`Contacts.List`), its Telegram blocked list (`BlockedPeersContext`, read to the
// end once per process and per re-grant) and the pending senders' cached `IsBlocked` flag, with the
// set of senders whose flag has been read (a sender outside it is never accepted automatically: a
// block made after the one-time list read is known only from that flag) — and hands them to the
// repository (`runAutoAccept`) debounced, on every change and after every cycle; none of it is
// stored or sent anywhere. When the sources are torn down the repository's copy is cleared too.
//
// Threading: decisions, repository calls and migration steps run on `queue` (one step at a time:
// its local part is short and runs there). The cut-over cache and the step flag are lock-guarded
// values; the write fence reads only those, so a database-queue call into it never re-enters the
// device database. Nothing here is persisted: every input is re-read after a launch.

public final class SGTasksSyncCoordinator: SGTasksMigrationFence {
    public static let shared = SGTasksSyncCoordinator()

    /// Posted on the main queue when an account's cut-over changed; `userInfo["accountPeerId"]`: Int64.
    public static let cutOverDidChangeNotification = Notification.Name("SGTasksSyncCoordinatorCutOverDidChange")
    /// The relay of `SGTasksCloudRepository.consentFencedNotification` (a 403 `tasks_consent_required`,
    /// §5.3): `userInfo["accountPeerId"]`: Int64, `["effectiveAt"]`: String when the server gave one.
    /// The customer layer may take it as a reason to reconcile consent early (optional).
    public static let consentFencedNotification = Notification.Name("SGTasksSyncCoordinatorConsentFenced")

    static let foregroundDriveInterval: TimeInterval = 300
    static let backgroundFlushTimeout: TimeInterval = 20
    static let firstDriveJitter: TimeInterval = 5
    /// A cycle posts several board changes, a gate change several notices: decide once per burst.
    static let evaluationDelay: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "uz.zenlygram.tasks.sync-coordinator", qos: .utility)

    // Lock-guarded (read by the write fence and the board from any thread).
    private let lock = NSLock()
    private var stepRunning = false
    private var cutOvers: [Int64: TasksCutOver] = [:]
    private var progresses: [Int64: SGTasksMigrationProgress] = [:]

    // Main queue.
    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    private let accountsDisposable = MetaDisposable()

    // On `queue`.
    private var sharedContext: SharedAccountContext?
    private var accounts: Set<Int64> = []
    /// The signed-in accounts' contexts (the automatic accept reads their Telegram data).
    private var contexts: [Int64: AccountContext] = [:]
    /// wf15 §5.3: the automatic accept's device-local sources, per driven `allowed` account.
    private var autoAcceptSources: [Int64: SGTasksAutoAcceptSources] = [:]
    /// Accounts whose repository this coordinator opened (driven, consent seen, or a gate change).
    private var touchedAccounts: Set<Int64> = []
    private var drivenAccounts: Set<Int64> = []
    private var isFirstDriveDue = false
    private var isForeground = true
    private var isPathSatisfied = true
    private var pendingAccounts: Set<Int64> = []
    private var pendingReasons: [Int64: SGTasksDriveReason] = [:]
    private var pendingGateChanges: Set<Int64> = []
    private var isEvaluationScheduled = false
    private var timer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?

    private init() {
    }

    // MARK: Start

    /// AppDelegate's Swiftgram start block, after `SGAccountCleanup.start` (and, from design 40's
    /// I-3 on, after `SGCustomerSync.shared.start`, so the gate is published before the first read).
    /// Main queue, idempotent, no network. Installs the traffic permission (until now every Tasks
    /// request was refused), the write fence and the analytics sink; the first drive follows the
    /// entitlement's first idle (8 s) plus up to 5 s.
    public func start(sharedContext: SharedAccountContext) {
        assert(Thread.isMainThread)
        guard !SGEntitlement.isAppExtension, !self.isStarted else { return }
        self.isStarted = true
        let isForeground = UIApplication.shared.applicationState != .background

        SGTasksCloudRepository.trafficPermission = { accountPeerId in
            return SGTasksSyncCoordinator.permission(accountPeerId: accountPeerId)
        }
        TodoStorage.writeFence = { [weak self] accountPeerId in
            return self?.writeFence(accountPeerId: accountPeerId) ?? .open
        }
        SGTasksAnalytics.sink = { event, accountPeerId in
            SGTasksSyncCoordinator.record(event, accountPeerId: accountPeerId)
        }

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.applicationWillEnterForeground()
            }
        })
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applicationDidEnterBackground()
        })
        self.observers.append(center.addObserver(forName: SGEntitlement.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            // A session, link or entitlement change: the binding (scope) may differ.
            self?.queue.async {
                self?.scheduleEvaluation(nil, reason: .session)
            }
        })
        self.observers.append(center.addObserver(forName: SGCustomerDataGate.didChangeNotification, object: nil, queue: nil) { [weak self] notification in
            let accountPeerId = notification.userInfo?[SGCustomerDataGate.accountPeerIdKey] as? Int64
            self?.queue.async {
                self?.scheduleEvaluation(accountPeerId.map { [$0] }, reason: .consent, gateChanged: true)
            }
        })
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.didChangeNotification, object: nil, queue: nil) { [weak self] notification in
            // A cycle ended (a complete snapshot may be there now): claim, step, cut-over; no drive.
            guard let accountPeerId = notification.userInfo?["accountPeerId"] as? Int64 else { return }
            self?.queue.async {
                self?.scheduleEvaluation([accountPeerId], reason: nil)
            }
        })
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.migrationDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.scheduleEvaluation(nil, reason: nil)
            }
        })
        self.observers.append(center.addObserver(forName: SGTasksCloudRepository.consentFencedNotification, object: nil, queue: nil) { notification in
            NotificationCenter.default.post(name: SGTasksSyncCoordinator.consentFencedNotification, object: nil, userInfo: notification.userInfo)
        })

        self.accountsDisposable.set((sharedContext.activeAccountContexts
        |> map { activeAccounts -> [Int64: AccountContext] in
            var contexts: [Int64: AccountContext] = [:]
            for (_, context, _) in activeAccounts.accounts {
                contexts[context.account.peerId.toInt64()] = context
            }
            return contexts
        }
        |> distinctUntilChanged(isEqual: { previous, current in
            // By instance: a re-login of the same account is a new context (new engine, new data).
            return previous.count == current.count && previous.allSatisfy { current[$0.key] === $0.value }
        })
        |> deliverOnMainQueue).startStrict(next: { [weak self] current in
            self?.queue.async {
                self?.accountsChanged(current)
            }
        }))

        self.queue.async { [weak self] in
            guard let self = self else { return }
            self.sharedContext = sharedContext
            self.isForeground = isForeground
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                // Delivered on `queue` (started below).
                self?.pathChanged(isSatisfied: path.status == .satisfied)
            }
            monitor.start(queue: self.queue)
            self.pathMonitor = monitor
            let delay = SGEntitlementScheduler.firstIdleDelay + Double.random(in: 0 ... Self.firstDriveJitter)
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.firstDrive()
            }
        }
    }

    // MARK: Public reads

    /// The account's traffic permission now (the customer layer's gate, mapped by `SGTasksSyncPolicy`).
    public func permission(accountPeerId: Int64) -> SGTasksSyncPermission {
        return Self.permission(accountPeerId: accountPeerId)
    }

    /// The account's cut-over (§7.5), recomputed on every input change; `.none` before the first.
    public func cutOver(accountPeerId: Int64) -> TasksCutOver {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cutOvers[accountPeerId] ?? .none
    }

    /// The account's migration progress; nil without a record.
    public func migrationProgress(accountPeerId: Int64) -> SGTasksMigrationProgress? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.progresses[accountPeerId]
    }

    /// One bounded cycle of the account now; `completion` (main queue) gets the unsent counts (user,
    /// migration) when it ended or `timeout` passed, nil when unknown.
    public func flush(accountPeerId: Int64, timeout: TimeInterval, completion: @escaping ((user: Int, migration: Int)?) -> Void) {
        let repository = SGTasksCloudRepository.repository(accountPeerId: accountPeerId)
        Task {
            let counts = await repository.flush(timeout: timeout)
            DispatchQueue.main.async {
                completion(counts)
            }
        }
    }

    /// A migration step's local part is copying the device database (the write fence's `.migrating`).
    var isMigrationStepRunning: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stepRunning
    }

    // MARK: Installed sources

    static func permission(accountPeerId: Int64) -> SGTasksSyncPermission {
        let gate = SGCustomerDataGate.shared
        let clearance = gate.clearance(accountPeerId: accountPeerId)
        return SGTasksSyncPolicy.permission(SGTasksSyncPolicy.GateInputs(
            isTasksConfigured: SGEntitlement.shared.isTasksConfigured,
            isPipelineActive: gate.isPipelineActive,
            tasksSync: clearance.contains(.tasksSync),
            recordEvents: clearance.contains(.recordEvents)
        ))
    }

    /// Cached values only: called on the device database's queue.
    private func writeFence(accountPeerId: Int64) -> TodoWriteFence {
        self.lock.lock()
        defer { self.lock.unlock() }
        return SGTasksSyncPolicy.writeFence(migrationStepRunning: self.stepRunning, cutOver: self.cutOvers[accountPeerId] ?? .none)
    }

    /// Taxonomy v1 by raw value (contract §3.2); a value the registry does not know is dropped.
    static func record(_ event: SGTasksAnalyticsEvent, accountPeerId: Int64?) {
        switch event {
        case let .taskCreated(cloud, hasDue, priority, inList):
            SGAnalytics.record(.tasksTaskCreated(scope: Self.scope(cloud), hasDue: hasDue, priority: priority, inList: inList), accountPeerId: accountPeerId)
        case let .taskCompleted(cloud, reopened):
            SGAnalytics.record(.tasksTaskCompleted(scope: Self.scope(cloud), reopened: reopened), accountPeerId: accountPeerId)
        case let .taskDeleted(cloud):
            SGAnalytics.record(.tasksTaskDeleted(scope: Self.scope(cloud)), accountPeerId: accountPeerId)
        case let .listCreated(cloud):
            SGAnalytics.record(.tasksListCreated(scope: Self.scope(cloud)), accountPeerId: accountPeerId)
        case let .listDeleted(cloud, tasks):
            SGAnalytics.record(.tasksListDeleted(scope: Self.scope(cloud), tasks: tasks), accountPeerId: accountPeerId)
        case let .shared(action):
            guard let action = SGAnalyticsTasksSharedAction(rawValue: action) else { return }
            SGAnalytics.record(.tasksShared(action: action), accountPeerId: accountPeerId)
        case let .migration(phase, lists, tasks, skipped, durationS, errorCode):
            guard let phase = SGAnalyticsTasksMigrationPhase(rawValue: phase) else { return }
            let code = errorCode.map { SGAnalyticsErrorCode($0) ?? .unknown }
            SGAnalytics.record(.tasksMigration(phase: phase, lists: lists, tasks: tasks, skipped: skipped, durationS: durationS, errorCode: code), accountPeerId: accountPeerId)
        case let .syncIssue(kind):
            guard let kind = SGAnalyticsTasksSyncIssueKind(rawValue: kind), let accountPeerId = accountPeerId else { return }
            SGAnalytics.tasksSyncIssue(kind, count: 1, accountPeerId: accountPeerId)
        case let .error(domain, code):
            guard let domain = SGAnalyticsErrorDomain(rawValue: domain) else { return }
            SGAnalytics.error(domain, SGAnalyticsErrorCode(code) ?? .unknown, accountPeerId: accountPeerId)
        case let .screen(name):
            guard let screen = SGAnalyticsScreen(rawValue: name) else { return }
            SGAnalytics.screen(screen, accountPeerId: accountPeerId)
        case let .featureUsed(name):
            guard let feature = SGAnalyticsFeature(rawValue: name) else { return }
            SGAnalytics.featureUsed(feature, accountPeerId: accountPeerId)
        case .paywallEntry:
            SGAnalytics.notePaywallEntry(.tasks)
        }
    }

    private static func scope(_ cloud: Bool) -> SGAnalyticsTasksScope {
        return cloud ? .cloud : .local
    }

    // MARK: Migration fence

    public func raise() {
        self.lock.lock()
        self.stepRunning = true
        self.lock.unlock()
    }

    /// On `queue` (the step runs there): the cut-over reads the step's new record before the fence
    /// drops, so no write slips through as `.open` between the two.
    public func lower(accountPeerId: Int64) {
        self.recomputeCutOvers()
        self.lock.lock()
        self.stepRunning = false
        self.lock.unlock()
    }

    // MARK: Inputs (on `queue`)

    private func accountsChanged(_ contexts: [Int64: AccountContext]) {
        let current = Set(contexts.keys)
        let added = current.subtracting(self.accounts)
        let removed = self.accounts.subtracting(current)
        // An account whose context was replaced (re-login) reads its Telegram data afresh.
        for (account, context) in contexts where self.contexts[account] !== context {
            // Only a repository this coordinator already drives is told (an added account has none
            // yet, and a removed one's was purged by the logout).
            let isKnown = !added.contains(account) && self.touchedAccounts.contains(account)
            self.tearDownAutoAccept(account, repository: isKnown ? SGTasksCloudRepository.repository(accountPeerId: account) : nil)
        }
        self.accounts = current
        self.contexts = contexts
        // A removed account's repository is purged by SGAccountCleanup; it is never touched again.
        self.touchedAccounts.subtract(removed)
        self.drivenAccounts.subtract(removed)
        self.pendingAccounts.subtract(removed)
        self.pendingGateChanges.subtract(removed)
        for account in removed {
            self.pendingReasons.removeValue(forKey: account)
            self.tearDownAutoAccept(account, repository: nil)
        }
        self.scheduleEvaluation(added, reason: .session)
        self.recomputeCutOvers()
    }

    private func firstDrive() {
        self.isFirstDriveDue = true
        if self.isForeground {
            self.startTimer()
        }
        self.scheduleEvaluation(nil, reason: .launch)
    }

    private func applicationWillEnterForeground() {
        self.isForeground = true
        if self.isFirstDriveDue {
            self.startTimer()
        }
        self.scheduleEvaluation(nil, reason: .foreground)
    }

    /// Main queue: a background task holds the process while every driven account flushes (20 s
    /// each, concurrently); it ends on completion or expiration.
    private func applicationDidEnterBackground() {
        let task = SGTasksBackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: "zenlygram.tasks.flush") {
            task.end()
        }
        self.queue.async {
            self.isForeground = false
            self.stopTimer()
            let accounts = self.drivenAccounts.intersection(self.accounts)
            guard !accounts.isEmpty else {
                DispatchQueue.main.async {
                    task.end()
                }
                return
            }
            let group = DispatchGroup()
            for account in accounts {
                let repository = SGTasksCloudRepository.repository(accountPeerId: account)
                group.enter()
                Task {
                    _ = await repository.flush(timeout: Self.backgroundFlushTimeout)
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                task.end()
            }
        }
    }

    private func pathChanged(isSatisfied: Bool) {
        let regained = isSatisfied && !self.isPathSatisfied
        self.isPathSatisfied = isSatisfied
        if regained {
            self.scheduleEvaluation(nil, reason: .network)
        }
    }

    private func startTimer() {
        guard self.timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + Self.foregroundDriveInterval, repeating: Self.foregroundDriveInterval)
        timer.setEventHandler { [weak self] in
            self?.timerFired()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        self.timer?.cancel()
        self.timer = nil
    }

    private func timerFired() {
        guard self.isForeground, self.isFirstDriveDue else { return }
        for account in self.drivenAccounts.intersection(self.accounts) {
            SGTasksCloudRepository.repository(accountPeerId: account).requestDrive(.timer)
        }
    }

    // MARK: Decisions (on `queue`)

    /// nil = every signed-in account. `reason` asks driven accounts for a cycle (nil: none, e.g.
    /// after a repository change, which would loop); `gateChanged` calls `permissionChanged()`.
    private func scheduleEvaluation(_ accounts: Set<Int64>?, reason: SGTasksDriveReason?, gateChanged: Bool = false) {
        let targets = (accounts ?? self.accounts).intersection(self.accounts)
        for account in targets {
            self.pendingAccounts.insert(account)
            if let reason = reason {
                self.pendingReasons[account] = reason
            }
            if gateChanged {
                self.pendingGateChanges.insert(account)
            }
        }
        guard !self.isEvaluationScheduled else { return }
        self.isEvaluationScheduled = true
        self.queue.asyncAfter(deadline: .now() + Self.evaluationDelay) { [weak self] in
            self?.runEvaluations()
        }
    }

    private func runEvaluations() {
        self.isEvaluationScheduled = false
        let targets = self.pendingAccounts.intersection(self.accounts)
        let reasons = self.pendingReasons
        let gateChanges = self.pendingGateChanges
        self.pendingAccounts.removeAll()
        self.pendingReasons.removeAll()
        self.pendingGateChanges.removeAll()
        for account in targets.sorted() {
            self.evaluate(account, reason: reasons[account], gateChanged: gateChanges.contains(account))
        }
        self.recomputeCutOvers()
    }

    private func evaluate(_ account: Int64, reason: SGTasksDriveReason?, gateChanged: Bool) {
        let permission = Self.permission(accountPeerId: account)
        let hasConsent = permission == .waiting || permission == .allowed
        // `.legacy` is exactly R3, and an account without consent is left alone unless this
        // coordinator already took it on (a withdrawal must stop what was driven).
        guard hasConsent || self.touchedAccounts.contains(account) else { return }
        let repository = SGTasksCloudRepository.repository(accountPeerId: account)
        self.touchedAccounts.insert(account)
        if gateChanged {
            repository.permissionChanged()
        }
        if self.isFirstDriveDue {
            let flags = repository.onQueue { (isDriven: repository.isDriven, isWithdrawn: repository.isConsentWithdrawn) }
            if SGTasksSyncPolicy.needsRegrantResume(permission, consentWithdrawnFlag: flags.isWithdrawn) {
                repository.resumeAfterConsentRegrant()
            }
            switch SGTasksSyncPolicy.driveAction(permission, isDriven: flags.isDriven) {
            case .drive:
                repository.startDriving()
                self.drivenAccounts.insert(account)
                if let reason = reason {
                    repository.requestDrive(reason)
                }
            case .stop:
                repository.stopDriving()
                self.drivenAccounts.remove(account)
            case .none:
                break
            }
        }
        // wf15 §5.3 (D2): the automatic accept's device-local inputs follow the permission — read
        // while the account is `allowed` and driven, torn down otherwise (the repository's copy of
        // them is cleared with the sources), so a later re-grant re-reads the blocked list and the
        // policy fails closed until it has (revision 3). Every evaluation (a cycle ended, the gate
        // changed, a drive occasion) re-runs the policy, debounced; the senders' cached block flags
        // follow the pending invitations.
        if permission == .allowed && self.drivenAccounts.contains(account) {
            self.ensureAutoAcceptSources(account)
            self.updateSenderSubscriptions(account, repository: repository)
            self.scheduleAutoAcceptRun(account)
        } else {
            self.tearDownAutoAccept(account, repository: repository)
        }
        let database = SGTasksCloudRepository.environment.legacy()
        var record = try? database.cloudMigrationRecord(accountPeerId: account)
        if SGTasksSyncPolicy.shouldClaimDevice(permission, record: record) {
            record = try? SGTasksMigration.claimAtConsent(accountPeerId: account, locale: self.claimLocale(), database: database)
        }
        // A step after a complete snapshot (`runStep` re-checks every precondition itself).
        guard permission == .allowed, self.isFirstDriveDue, repository.state.hasCompleteSnapshot else { return }
        guard record != nil, record?.state != .skipped else { return }
        if let progress = try? SGTasksMigration.runStep(repository: repository, locale: self.claimLocale(), fence: self) {
            self.lock.lock()
            self.progresses[account] = progress
            self.lock.unlock()
        }
    }

    // MARK: The automatic accept's sources (wf15 §5.3, D2; on `queue`)

    /// Opens the account's contact and blocked-list reads once (idempotent). The contact set is the
    /// raw Telegram user ids of `Contacts.List`'s `.user` peers (a local Postbox view: empty until
    /// Postbox has loaded the contacts, so invitations wait until the set-change re-run). The
    /// blocked list is read as the Privacy settings screen reads it (`BlockedPeersContext`,
    /// `loadMore()`, main queue by its contract) to its end: `canLoadMore == false`, or — a list
    /// answered in slices never says so — the total count reached, or a load that added no peer.
    /// It counts as loaded once that first full read finished in this process, and nothing is
    /// requested after it.
    private func ensureAutoAcceptSources(_ account: Int64) {
        guard self.autoAcceptSources[account] == nil, let context = self.contexts[account] else { return }
        let sources = SGTasksAutoAcceptSources()
        self.autoAcceptSources[account] = sources
        let queue = Queue(queue: self.queue)
        sources.contacts.set((context.engine.data.subscribe(TelegramEngine.EngineData.Item.Contacts.List(includePresences: false))
        |> map { contacts -> Set<Int64> in
            var ids = Set<Int64>()
            for peer in contacts.peers {
                if case .user = peer {
                    ids.insert(peer.id.id._internalGetInt64Value())
                }
            }
            return ids
        }
        |> distinctUntilChanged
        |> deliverOn(queue)).startStrict(next: { [weak self, weak sources] ids in
            guard let self = self, let sources = sources, self.autoAcceptSources[account] === sources else { return }
            sources.contactTgIds = ids
            self.scheduleAutoAcceptRun(account)
        }))
        let coordinatorQueue = self.queue
        DispatchQueue.main.async { [weak self, weak sources] in
            guard let sources = sources else { return }
            let blocked = BlockedPeersContext(account: context.account, subject: .blocked)
            sources.blockedContext = blocked
            // Main queue: the peer count when the last page was asked for, and the read's end.
            var countAtLastRequest: Int?
            var finished = false
            sources.blockedList.set((blocked.state
            |> deliverOnMainQueue).startStrict(next: { [weak self, weak sources, weak blocked] state in
                guard let blocked = blocked else { return }
                if !finished && !state.isLoadingMore {
                    if SGTasksSyncPolicy.blockedListReadEnded(canLoadMore: state.canLoadMore, peerCount: state.peers.count, totalCount: state.totalCount, peerCountAtLastRequest: countAtLastRequest) {
                        finished = true
                    } else {
                        countAtLastRequest = state.peers.count
                        blocked.loadMore()
                    }
                }
                var ids = Set<Int64>()
                for peer in state.peers where peer.peerId.namespace == Namespaces.Peer.CloudUser {
                    ids.insert(peer.peerId.id._internalGetInt64Value())
                }
                let loaded = finished
                coordinatorQueue.async {
                    guard let self = self, let sources = sources, self.autoAcceptSources[account] === sources else { return }
                    sources.blockedListIds = ids
                    sources.blockedListLoaded = sources.blockedListLoaded || loaded
                    self.scheduleAutoAcceptRun(account)
                }
            }))
        }
    }

    /// The pending invitations' senders get their cached `IsBlocked` flag subscribed (a block made
    /// in this app or on another device after the list was read counts at once); re-subscribed when
    /// that set changes. Until a subscription has delivered its first value its senders are not
    /// "checked" and the policy leaves their invitations alone (fail closed): the cycle whose pull
    /// delivered a first-time sender's invitation runs the policy before this subscription exists,
    /// so that sender is accepted by the run the first value schedules, about a second later.
    private func updateSenderSubscriptions(_ account: Int64, repository: SGTasksCloudRepository) {
        guard let sources = self.autoAcceptSources[account], let context = self.contexts[account] else { return }
        let ids = Set(repository.state.invitations.map { $0.ownerTgId.int64Value })
        guard ids != sources.senderIds else { return }
        sources.senderIds = ids
        // No flag of the new set has been read yet. The repository still holds the inputs handed in
        // before; `evaluate` schedules the run that replaces them right after this call.
        sources.checkedSenderIds = []
        guard !ids.isEmpty else {
            sources.senders.set(nil)
            if !sources.blockedSenderIds.isEmpty {
                sources.blockedSenderIds = []
                self.scheduleAutoAcceptRun(account)
            }
            return
        }
        let peerIds = ids.sorted().map { EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value($0)) }
        sources.senders.set((context.engine.data.subscribe(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.IsBlocked.init(id:))))
        |> map { result -> Set<Int64> in
            var blocked = Set<Int64>()
            for (peerId, item) in result where item.knownValue == true {
                blocked.insert(peerId.id._internalGetInt64Value())
            }
            return blocked
        }
        |> distinctUntilChanged
        |> deliverOn(Queue(queue: self.queue))).startStrict(next: { [weak self, weak sources] blocked in
            // A value of a subscription that was replaced meanwhile says nothing about the new set.
            guard let self = self, let sources = sources, self.autoAcceptSources[account] === sources, sources.senderIds == ids else { return }
            sources.blockedSenderIds = blocked
            sources.checkedSenderIds = ids
            self.scheduleAutoAcceptRun(account)
        }))
    }

    /// One debounced run per burst (`evaluationDelay`): the repository gets the inputs and runs the
    /// policy over its pending invitations on its own queue.
    private func scheduleAutoAcceptRun(_ account: Int64) {
        guard let sources = self.autoAcceptSources[account] else { return }
        sources.runWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let sources = self.autoAcceptSources[account], self.accounts.contains(account) else { return }
            SGTasksCloudRepository.repository(accountPeerId: account).runAutoAccept(sources.inputs)
        }
        sources.runWork = work
        self.queue.asyncAfter(deadline: .now() + Self.evaluationDelay, execute: work)
    }

    /// `repository` (when the coordinator may still touch it) forgets the inputs handed in: the
    /// policy does nothing until sources opened afresh hand in new, fail-closed ones.
    private func tearDownAutoAccept(_ account: Int64, repository: SGTasksCloudRepository?) {
        guard let sources = self.autoAcceptSources.removeValue(forKey: account) else { return }
        sources.dispose()
        repository?.clearAutoAcceptInputs()
    }

    private func claimLocale() -> TodoCloudMigrationRecord.Locale {
        let languageCode = self.sharedContext?.currentPresentationData.with { $0 }.strings.primaryComponent.languageCode ?? "en"
        return TodoCloudMigrationRecord.Locale(languageCode: languageCode)
    }

    /// Every signed-in account's cut-over from the device database, the gate, the bindings and, for an
    /// account with consent and a copy, its cloud store (I1; `TasksCutOver.Inputs.read`). Never under
    /// `lock` while reading the database or a store (the write fence takes `lock` on the database's
    /// queue).
    private func recomputeCutOvers() {
        let database = SGTasksCloudRepository.environment.legacy()
        var scopes: [Int64: String] = [:]
        for account in self.accounts {
            scopes[account] = SGTasksCloudRepository.currentImportScope(accountPeerId: account)
        }
        // `ownerActive`: the marker's account is signed in here and its copy exists in the scope of
        // its current binding.
        var activeOwner: Int64?
        if let owner = try? database.cloudDeviceOwner(), self.accounts.contains(owner.accountPeerId),
           let ownerRecord = try? database.cloudMigrationRecord(accountPeerId: owner.accountPeerId),
           ownerRecord.state == .enqueued || ownerRecord.state == .completed,
           let recordScope = ownerRecord.principalScope, recordScope == scopes[owner.accountPeerId] {
            activeOwner = owner.accountPeerId
        }
        var next: [Int64: TasksCutOver] = [:]
        var nextProgress: [Int64: SGTasksMigrationProgress] = [:]
        for account in self.accounts {
            let inputs = TasksCutOver.Inputs.read(accountPeerId: account, permission: Self.permission(accountPeerId: account), currentScope: scopes[account], ownerActive: activeOwner != nil && activeOwner != account, database: database, repository: {
                // I1 of an account with consent and a copy. A Telegram logout purged its store and kept
                // the record, so after a re-login the store is empty until the account is linked again
                // and its snapshot lands (or the step re-enqueues); the repository's change notice then
                // re-evaluates. `evaluate` opens such an account's repository as soon as consent is
                // seen anyway: from here on this coordinator tracks it.
                self.touchedAccounts.insert(account)
                return SGTasksCloudRepository.repository(accountPeerId: account)
            })
            next[account] = TasksCutOver.evaluate(inputs)
            if let record = inputs.record {
                let repository = self.touchedAccounts.contains(account) ? SGTasksCloudRepository.repository(accountPeerId: account) : nil
                nextProgress[account] = SGTasksMigration.progress(record, repository: repository)
            }
        }
        self.lock.lock()
        let changed = Set(next.keys).union(self.cutOvers.keys).filter { next[$0] != self.cutOvers[$0] }
        self.cutOvers = next
        self.progresses = nextProgress
        self.lock.unlock()
        guard !changed.isEmpty else { return }
        DispatchQueue.main.async {
            for account in changed.sorted() {
                NotificationCenter.default.post(name: SGTasksSyncCoordinator.cutOverDidChangeNotification, object: nil, userInfo: ["accountPeerId": account])
            }
        }
    }
}

/// The device-local sources of one account's automatic accept (wf15 §5.3, D2): the Telegram
/// contacts, the Telegram blocked list and the pending senders' cached block flag. Owned by the
/// coordinator and mutated on its `queue`; `blockedContext` is created and released on the main
/// queue (`BlockedPeersContext`'s contract). Nothing here is persisted or sent.
private final class SGTasksAutoAcceptSources {
    let contacts = MetaDisposable()
    let blockedList = MetaDisposable()
    let senders = MetaDisposable()
    /// Main queue only.
    var blockedContext: BlockedPeersContext?
    var contactTgIds: Set<Int64> = []
    var blockedListIds: Set<Int64> = []
    var blockedListLoaded = false
    var blockedSenderIds: Set<Int64> = []
    /// The pending senders whose flag subscription is open.
    var senderIds: Set<Int64> = []
    /// The pending senders whose flag subscription has delivered a value (⊆ `senderIds`).
    var checkedSenderIds: Set<Int64> = []
    var runWork: DispatchWorkItem?

    var inputs: SGTasksAutoAcceptInputs {
        return SGTasksAutoAcceptInputs(contactTgIds: self.contactTgIds, telegramBlockedIds: self.blockedListIds.union(self.blockedSenderIds), telegramBlockedListLoaded: self.blockedListLoaded, telegramBlockCheckedSenderIds: self.checkedSenderIds)
    }

    /// On the coordinator's queue; the blocked-list context is released on the main queue, after
    /// any creation still in flight there.
    func dispose() {
        self.contacts.dispose()
        self.blockedList.dispose()
        self.senders.dispose()
        self.runWork?.cancel()
        self.runWork = nil
        DispatchQueue.main.async {
            self.blockedContext = nil
        }
    }
}

/// A background task handle, ended exactly once (main queue only).
private final class SGTasksBackgroundTask {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard self.identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.identifier)
        self.identifier = .invalid
    }
}
