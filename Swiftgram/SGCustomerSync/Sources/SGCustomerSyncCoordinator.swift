import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import SGEntitlement
import SGTasks
import SGCustomerSyncCore

/// Zenlygram — the app-side driver of `SGCustomerCoordinatorCore` (design 40 §6.6). It holds no
/// decision of its own:
///
/// 1. it gathers the events — the account observer, the app lifecycle (`SGAnalyticsLifecycle`),
///    SGEntitlement's first idle and changes, the consent store's changes, protected data, its own
///    timers, the answers of its calls, the Link-screen hooks and the user-initiated sends — and feeds
///    them to the reducer one at a time, in order, on the main queue (an event raised while effects
///    run waits for them);
/// 2. before EVERY event it reads the reducer's inputs fresh from storage: the consent store,
///    SGEntitlement's session facts, the event queue, the budgets and the cadence helpers' answers;
/// 3. it runs the returned effects in order: transport calls (each answer comes back as an event),
///    store writes, gate publishing (and the analytics accounts table), queue purges, SGEntitlement
///    receipts, the Tasks calls, sessions, timers, the automatic link and the log.
///
/// Main queue only, except the network exchanges, which run in tasks and report back on main.
final class SGCustomerSyncCoordinator {
    typealias Core = SGCustomerCoordinatorCore

    private struct TimerKey: Hashable {
        let account: Int64
        let timer: Core.Timer
    }

    private let store: SGConsentStore
    private let authority: String
    /// This build's consent texts and operator values: what a grant is checked against on every
    /// account (`Core.Facts.bundledMinValidVersion`, `renderedSha256ForRecord`).
    private let texts: SGConsentTextRepository?
    private let operatorValues: SGConsentOperatorValues
    private let pipeline: SGAnalyticsPipeline
    private let queueStore: SGAnalyticsQueueStore
    private let transport: SGCustomerTransportLive
    private let accounts = SGCustomerAccountObserver()
    private let profiles = SGProfileReader()
    private let autoLink = SGAutoLinkRunner()
    private var lifecycle: SGAnalyticsLifecycle?
    private var observers: [NSObjectProtocol] = []
    private let presentationDataDisposable = MetaDisposable()

    private var state: Core.State
    /// The signed-in accounts the reducer was last told about: packed id → RAW Telegram id.
    private var signedIn: [Int64: Int64] = [:]
    private var primary: Int64?
    /// The clearance last published per signed-in account.
    private var published: [Int64: SGCustomerDataGate.Clearance] = [:]
    private var accountsTable: (accounts: [SGAnalyticsPipeline.Account], active: Int64?)?

    private var pending: [Core.Event] = []
    private var isRunning = false
    /// An `.accountsChanged` asked for the reconciliation inputs (`knownTelegramUserIds`, the queue
    /// owners) and they have not been readable yet.
    private var needsReconcileInputs = false

    private var timers: [TimerKey: (item: DispatchWorkItem, generation: UInt64)] = [:]
    private var timerGeneration: UInt64 = 0
    /// The `didEnterBackground` being handled: the batches it sends hold its background task.
    private var backgroundFlush: SGAnalyticsLifecycle.Flush?
    private var uiLanguage: String?
    private var deviceFacts: SGCustomerDeviceFacts
    // §6.2 per-account memory (not persisted).
    private let receipts = SGCustomerSyncReceipts()
    private var lastSyncAttemptAt: [Int64: Date] = [:]
    private var digestPendingSince: [Int64: (digest: String, since: Date)] = [:]
    private var batchLimits: [Int64: Int] = [:]
    private var lastFlushAt: [Int64: Date] = [:]
    private var flushedSinceFirstIdle = Set<Int64>()
    private var deletionReports: [Int64: SGCustomerDeletion.Report] = [:]

    init(store: SGConsentStore, authority: String, texts: SGConsentTextRepository?, operatorValues: SGConsentOperatorValues, pipeline: SGAnalyticsPipeline, queueStore: SGAnalyticsQueueStore, transport: SGCustomerTransportLive) {
        self.store = store
        self.authority = authority
        self.texts = texts
        self.operatorValues = operatorValues
        self.pipeline = pipeline
        self.queueStore = queueStore
        self.transport = transport
        self.state = Core.State(isForeground: UIApplication.shared.applicationState != .background, autoLinkJitter: SGAutoLinkPolicy.firstIdleJitter({ Double.random(in: 0 ..< 1) }))
        self.deviceFacts = SGDeviceInfo.facts(uiLanguage: nil)
    }

    deinit {
        self.presentationDataDisposable.dispose()
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Start

    /// Main queue, once (`SGCustomerSync.start`). The first account set is usually there already:
    /// every account's clearance is then published before this returns.
    func start(sharedContext: SharedAccountContext) {
        assert(Thread.isMainThread)
        self.uiLanguage = sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        self.deviceFacts = SGDeviceInfo.facts(uiLanguage: self.uiLanguage)
        self.pipeline.setContext(SGAnalyticsContext(facts: self.deviceFacts))
        self.profiles.didChange = { [weak self] accountPeerId in
            // The user changed (name, username, phone, Premium): the snapshot's digest may differ.
            self?.send(.timer(account: accountPeerId, .route(.sync)))
        }

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: SGConsentStore.didChangeNotification, object: nil, queue: .main, using: { [weak self] notification in
            guard let self, let tg = notification.userInfo?[SGConsentStore.tgUserIdKey] as? Int64 else {
                return
            }
            self.send(.consentChanged(tg: tg))
            for (accountPeerId, accountTg) in self.signedIn where accountTg == tg {
                self.postSummaryChange(accountPeerId)
            }
        }))
        self.observers.append(center.addObserver(forName: SGEntitlement.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.send(.entitlementChanged)
            self?.postSummaryChange(nil)
        }))
        self.observers.append(center.addObserver(forName: SGEntitlement.didPassFirstIdleNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.send(.firstIdle)
        }))
        self.observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.send(.protectedDataAvailable)
        }))
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in
                self?.deviceChanged()
            }))
        }
        self.presentationDataDisposable.set((sharedContext.presentationData
        |> map { presentationData -> String in
            return presentationData.strings.baseLanguageCode
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).startStrict(next: { [weak self] languageCode in
            guard let self, self.uiLanguage != languageCode else {
                return
            }
            self.uiLanguage = languageCode
            self.deviceChanged()
        }))

        let lifecycle = SGAnalyticsLifecycle(coordinator: self, isForeground: self.state.isForeground)
        self.lifecycle = lifecycle
        lifecycle.start()

        self.accounts.start(sharedContext: sharedContext, onChange: { [weak self] accounts in
            self?.send(.accountsChanged(signedIn: accounts.signedIn, primary: accounts.primary))
        })
        if SGEntitlement.shared.hasPassedFirstIdleWindow {
            self.send(.firstIdle)
        }
    }

    // MARK: - Events

    /// Feeds `event` to the reducer and runs its effects; an event raised while effects run is fed
    /// after them, in order. Main queue.
    func send(_ event: Core.Event) {
        assert(Thread.isMainThread)
        self.pending.append(event)
        guard !self.isRunning else {
            return
        }
        self.isRunning = true
        while !self.pending.isEmpty {
            self.process(self.pending.removeFirst())
        }
        self.isRunning = false
        self.followClearance()
    }

    private func process(_ event: Core.Event) {
        if case let .accountsChanged(signedIn, primary) = event {
            self.accountsChanged(signedIn, primary: primary)
        }
        let now = self.now()
        let inputs = self.inputs(now: now)
        if self.needsReconcileInputs, inputs.readable, inputs.queueOwners != nil {
            self.needsReconcileInputs = false
        }
        let result = Core.reduce(self.state, event, inputs: inputs, now: now)
        self.state = result.state
        for effect in result.effects {
            self.run(effect, now: now)
        }
    }

    /// The account set changed: per-account memory of the accounts that left goes, and the analytics
    /// accounts table follows at once (a removed account records nothing more).
    private func accountsChanged(_ signedIn: [Core.SignedIn], primary: Int64?) {
        var table: [Int64: Int64] = [:]
        for account in signedIn {
            table[account.accountPeerId] = account.tg
        }
        for accountPeerId in self.signedIn.keys where table[accountPeerId] == nil {
            for (key, timer) in self.timers where key.account == accountPeerId {
                timer.item.cancel()
                self.timers[key] = nil
            }
            self.published[accountPeerId] = nil
            self.receipts.forget(account: accountPeerId)
            self.lastSyncAttemptAt[accountPeerId] = nil
            self.digestPendingSince[accountPeerId] = nil
            self.batchLimits[accountPeerId] = nil
            self.lastFlushAt[accountPeerId] = nil
            self.flushedSinceFirstIdle.remove(accountPeerId)
            self.deletionReports[accountPeerId] = nil
        }
        self.signedIn = table
        self.primary = primary
        // The launch reconciliation / logout purge needs the known ids and the queue owners.
        self.needsReconcileInputs = true
        self.pushAccountsTable()
    }

    // MARK: - Inputs (read fresh before every event)

    private func now() -> Date {
        return SGEntitlement.shared.entitlementClock.effectiveNow()
    }

    private func inputs(now: Date) -> Core.Inputs {
        let readable = self.store.isReadable
        let hints = SGCustomerHints(jsonObject: self.store.jsonObject(.hints(authority: self.authority)))
        var accounts: [Int64: Core.Facts] = [:]
        if readable {
            for (accountPeerId, tg) in self.signedIn {
                accounts[accountPeerId] = self.facts(accountPeerId: accountPeerId, tg: tg, hints: hints, now: now)
            }
        }
        let reconcile = self.needsReconcileInputs
        return Core.Inputs(
            readable: readable,
            accounts: accounts,
            knownTelegramUserIds: readable && reconcile ? self.store.knownTelegramUserIds() : [],
            queueOwners: reconcile ? self.queueStore.queueOwners() : nil,
            autoLinkInstall: SGAutoLinkInstallRecord(jsonObject: self.store.jsonObject(.autoLinkInstall(authority: self.authority))),
            appVersion: SGDeviceInfo.appVersion,
            eventsPausedUntil: hints.eventsPausedUntil
        )
    }

    private func facts(accountPeerId: Int64, tg: Int64, hints: SGCustomerHints, now: Date) -> Core.Facts {
        let entitlement = SGEntitlement.shared
        var facts = Core.Facts(store: self.store, tg: tg, authority: self.authority)
        if let texts = self.texts {
            // A grant this build treats as stale (§4.6 rows 5–6) is cleared for nothing, on every
            // account: the wall normalises the record of the primary one only.
            facts.bundledMinValidVersion = texts.minValidVersion
            facts.renderedSha256ForRecord = SGCustomerClearance.renderedSha256(record: facts.record, texts: texts, operatorValues: self.operatorValues)
        }
        let session = entitlement.session(accountPeerId: accountPeerId)
        facts.bindingDeviceId = session.isLinked ? session.deviceId : nil
        facts.sessionEnd = entitlement.sessionEnd(accountPeerId: accountPeerId).map(SGCustomerSync.sessionEnd)
        let receipt = entitlement.profileSyncReceipt(accountPeerId: accountPeerId).map { SGProfileSyncReceipt(digest: $0.digest, at: $0.at) }
        facts.hasProfileReceipt = receipt != nil
        facts.bindPermissionAllowed = entitlement.bindPermission(accountPeerId: accountPeerId) == .allowed
        facts.bindInProgress = entitlement.isBindInProgress(accountPeerId: accountPeerId)
        for route in [SGCustomerRoute.consents, .sync, .events] {
            let budget = SGCustomerBudget(route: route, jsonObject: self.store.jsonObject(.budget(route: route, authority: self.authority)))
            facts.budgetUntil[route] = budget.nextAllowedAt(now: now)
        }
        // The cadences matter only to an account that may upload (the planner gates on clearance):
        // the snapshot is read only for a linked grant, the queue only once the profile was synced.
        guard facts.isLinked, facts.record?.state == .granted else {
            self.digestPendingSince[accountPeerId] = nil
            return facts
        }
        if let snapshot = self.snapshot(accountPeerId) {
            let digest = snapshot.digest
            var changedAt: Date?
            if let receipt, receipt.digest != digest {
                if let pending = self.digestPendingSince[accountPeerId], pending.digest == digest {
                    changedAt = pending.since
                } else {
                    self.digestPendingSince[accountPeerId] = (digest, now)
                    changedAt = now
                }
            } else {
                self.digestPendingSince[accountPeerId] = nil
            }
            facts.syncDueAt = SGProfileSyncCadence.dueAt(digest: digest, receipt: receipt, digestChangedAt: changedAt, lastAttemptAt: self.lastSyncAttemptAt[accountPeerId], minIntervalS: hints.minIntervalS, isForeground: self.state.isForeground, now: now)
        }
        if receipt != nil {
            facts.queuedEvents = self.pipeline.queuedCount(tg: tg)
            facts.eventsDueAt = SGAnalyticsBatcher.flushDueAt(queued: facts.queuedEvents, flushedSinceFirstIdle: self.flushedSinceFirstIdle.contains(accountPeerId), lastFlushAt: self.lastFlushAt[accountPeerId], isForeground: self.state.isForeground, state: self.flushState(accountPeerId, hints: hints), now: now)
        }
        return facts
    }

    private func snapshot(_ accountPeerId: Int64) -> SGProfileSnapshot? {
        guard let user = self.profiles.user(accountPeerId: accountPeerId) else {
            return nil
        }
        return SGProfileSnapshot(user: user, device: self.deviceFacts)
    }

    private func flushState(_ accountPeerId: Int64, hints: SGCustomerHints) -> SGAnalyticsFlushState {
        var state = SGAnalyticsFlushState(hints: hints)
        state.batchLimit = self.batchLimits[accountPeerId] ?? SGAnalyticsBatcher.maxEvents
        return state
    }

    // MARK: - Effects

    private func run(_ effect: Core.Effect, now: Date) {
        switch effect {
        case let .publishClearance(account, clearance):
            SGCustomerDataGate.shared.publish(clearance, accountPeerId: account)
            self.published[account] = self.signedIn[account] == nil ? nil : clearance
            self.pushAccountsTable()
        case let .sessionStart(account, trigger):
            self.pipeline.sessionStart(accountPeerId: account, trigger: trigger, at: Date())
        case let .sessionEnd(account, reason):
            self.pipeline.sessionEnd(accountPeerId: account, reason: reason, at: Date())
        case let .call(account, request, budgeted):
            if budgeted {
                self.recordBudget(request.route, now: now)
            }
            self.call(account, request, now: now)
        case let .autoLink(account):
            self.runAutoLink(account)
        case let .scheduleTimer(account, timer, at):
            self.schedule(TimerKey(account: account, timer: timer), at: at, now: now)
        case let .normalise(tg, notice):
            self.wrote(self.store.markNeedsReconsent(tg: tg, notice: notice))
        case let .normaliseLinkEnded(tg, consentId):
            self.wrote(self.store.normaliseAfterConsentStale(tg: tg, consentId: consentId))
        case let .markAcked(tg, consentIds):
            self.wrote(self.store.markAcked(tg: tg, authority: self.authority, ids: consentIds))
        case let .markRejected(tg, consentId, code):
            self.wrote(self.store.markRejected(tg: tg, authority: self.authority, id: consentId, code: code))
        case let .markWithdrawnRemote(tg, effectiveAt, consentId):
            self.wrote(self.store.markWithdrawnRemote(tg: tg, effectiveAt: effectiveAt, consentId: consentId))
        case let .writeConsentsSent(tg, deviceId):
            self.wrote(self.store.setString(deviceId, for: .consentsSent(tg: tg, authority: self.authority)))
        case let .writeNotLinked(tg, deviceId):
            self.wrote(self.store.setString(deviceId, for: .notLinked(tg: tg, authority: self.authority)))
        case let .writeLinkEndedMarker(tg, handled):
            self.wrote(self.store.setJSONObject(handled.jsonObject, for: .linkEnded(tg: tg, authority: self.authority)))
        case let .writeDeletion(tg, record):
            self.wrote(self.store.setJSONObject(record?.jsonObject, for: .deletion(tg: tg, authority: self.authority)))
        case let .writeAutoLink(tg, record):
            self.wrote(self.store.setJSONObject(record?.jsonObject, for: .autoLink(tg: tg, authority: self.authority)))
        case let .writeAutoLinkInstall(install):
            self.wrote(self.store.setJSONObject(install.jsonObject, for: .autoLinkInstall(authority: self.authority)))
        case let .writeDeletedNotice(tg, at):
            self.wrote(self.store.setDeletedNotice(tg: tg, at: at))
        case let .purgeConsent(tg):
            self.wrote(self.store.purge(tg: tg))
        case let .purgeQueue(tg):
            self.pipeline.purge(tg: tg)
        case let .clearReceipt(account):
            self.receipts.clear(account: account)
        case let .recordSyncReceipt(account, minIntervalS):
            self.receipts.record(account: account, at: now)
            self.digestPendingSince[account] = nil
            if let minIntervalS {
                self.updateHints { hints in
                    hints.minIntervalS = minIntervalS
                }
            }
        case let .forgetErasedAccount(account):
            SGEntitlement.shared.forgetErasedAccount(accountPeerId: account)
        case let .tasksRetire(account):
            SGTasksCloudRepository.retireForConsentWithdrawal(accountPeerId: account)
        case let .tasksErased(account):
            SGTasksCloudRepository.purgeAfterAccountErasure(accountPeerId: account)
        case let .deletionReport(account, report):
            self.deletionReports[account] = report
            NotificationCenter.default.post(name: SGCustomerSync.deletionDidChangeNotification, object: nil, userInfo: [SGCustomerSync.accountPeerIdKey: account])
        case let .log(code):
            SGCustomerLog.log(code)
        }
    }

    /// A store write that did not land: the next pass decides again from what IS stored.
    private func wrote<T>(_ result: Result<T, SGConsentStoreError>) {
        switch result {
        case .success, .failure(.notAllowed), .failure(.invalidInput):
            break
        case .failure(.unreadable):
            SGCustomerLog.log(.consentStoreUnreadable)
        case .failure(.saveFailed):
            SGCustomerLog.log(.consentSaveFailed)
        }
    }

    // MARK: Calls

    private func call(_ account: Int64, _ request: Core.Request, now: Date) {
        switch request {
        case let .consents(body):
            self.perform(account, .consents(body)) { [weak self] outcome, _ in
                self?.send(.outcome(.consents, account: account, outcome))
                self?.postSummaryChange(account)
            }
        case .sync:
            guard let snapshot = self.snapshot(account) else {
                // Not read yet: nothing sent, the route waits its backoff (the reducer's contract).
                self.send(.outcome(.sync, account: account, .notConfigured))
                return
            }
            let body = snapshot.body(observedAt: now)
            guard body.count <= SGProfileSnapshot.maxBodyBytes else {
                SGCustomerLog.log(.profileSnapshotInvalid, route: .sync)
                self.send(.outcome(.sync, account: account, .notConfigured))
                return
            }
            let previousAttemptAt = self.lastSyncAttemptAt[account]
            self.lastSyncAttemptAt[account] = now
            self.receipts.willSend(account: account, digest: snapshot.digest, credential: SGEntitlement.shared.sessionCredential(accountPeerId: account))
            self.performIfCleared(account, .sync(body)) { [weak self] result in
                guard let self else {
                    return
                }
                guard let result else {
                    // Not cleared any more once its turn came: nothing went out, no attempt counts.
                    self.receipts.forget(account: account)
                    if self.lastSyncAttemptAt[account] == now {
                        self.lastSyncAttemptAt[account] = previousAttemptAt
                    }
                    self.send(.notSent(.sync, account: account))
                    return
                }
                self.send(.outcome(.sync, account: account, result.outcome))
            }
        case let .events(background):
            let flush = background ? self.backgroundFlush : nil
            guard let tg = self.signedIn[account], let batch = self.pipeline.nextBatch(tg: tg, limit: self.batchLimits[account] ?? SGAnalyticsBatcher.maxEvents, maxBytes: background ? SGAnalyticsBatcher.backgroundMaxBytes : SGAnalyticsBatcher.maxBytes, sentAt: Date()) else {
                self.send(.outcome(.events, account: account, .notConfigured))
                return
            }
            flush?.begin()
            self.performIfCleared(account, .events(batch.body)) { [weak self] result in
                if let result {
                    self?.eventsAnswered(account, batch: batch, outcome: result.outcome, answer: result.answer)
                } else {
                    // Not cleared any more once its turn came: nothing went out. The batch is handed
                    // back (a withdrawal purged it already).
                    self?.pipeline.complete(batch, deleteEvents: false)
                    self?.send(.notSent(.events, account: account))
                }
                flush?.end()
            }
        case let .delete(idempotencyKey):
            self.perform(account, .delete(idempotencyKey: idempotencyKey)) { [weak self] outcome, answer in
                let offline = answer.transport == .offline || answer.transport == .timeout
                self?.send(.deleteOutcome(account: account, SGCustomerDeleteOutcome(outcome: outcome, offline: offline)))
            }
        }
    }

    /// The exchange runs in a task; the answer comes back on the main queue.
    private func perform(_ account: Int64, _ request: SGCustomerRequest, completion: @escaping (SGCustomerCallOutcome, SGCustomerRawAnswer) -> Void) {
        let transport = self.transport
        Task {
            let result = await transport.perform(request, accountPeerId: account)
            SGMainQueue.deliver(result, to: { result in
                completion(result.outcome, result.answer)
            })
        }
    }

    /// `perform` for the automatic sync and events calls: nil comes back when the account was no
    /// longer cleared for the route once its turn came (`SGCustomerTransportLive.performIfCleared`).
    private func performIfCleared(_ account: Int64, _ request: SGCustomerRequest, completion: @escaping ((outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer)?) -> Void) {
        let transport = self.transport
        Task {
            let result = await transport.performIfCleared(request, accountPeerId: account)
            SGMainQueue.deliver(result, to: completion)
        }
    }

    /// An events batch answered: the batch's events are deleted or kept (`SGAnalyticsBatcher.apply`,
    /// then `SGAnalyticsPipeline.complete`), the server's hints kept, then the reducer told.
    private func eventsAnswered(_ account: Int64, batch: SGAnalyticsBatch, outcome: SGCustomerCallOutcome, answer: SGCustomerRawAnswer) {
        let hints = SGCustomerHints(jsonObject: self.store.jsonObject(.hints(authority: self.authority)))
        var flush = self.flushState(account, hints: hints)
        let deleteEvents = SGAnalyticsBatcher.apply(outcome, batchSize: batch.eventIds.count, state: &flush, now: self.now())
        self.pipeline.complete(batch, deleteEvents: deleteEvents)
        if self.signedIn[account] != nil {
            self.batchLimits[account] = flush.batchLimit
            switch outcome {
            case .notConfigured, .notLinkedLocally, .credentialChanged:
                break
            default:
                // A batch went out: the next foreground flush is an interval later.
                self.lastFlushAt[account] = self.now()
                if self.state.firstIdleAt != nil {
                    self.flushedSinceFirstIdle.insert(account)
                }
            }
        }
        let flushIntervalS = Int(flush.flushInterval)
        if hints.eventsPausedUntil != flush.pausedUntil || (hints.flushIntervalS ?? Int(SGAnalyticsBatcher.defaultFlushInterval)) != flushIntervalS {
            self.updateHints { stored in
                stored.eventsPausedUntil = flush.pausedUntil
                stored.flushIntervalS = flushIntervalS
            }
        }
        self.send(.outcome(.events, account: account, outcome))
    }

    private func updateHints(_ change: (inout SGCustomerHints) -> Void) {
        var hints = SGCustomerHints(jsonObject: self.store.jsonObject(.hints(authority: self.authority)))
        change(&hints)
        self.wrote(self.store.setJSONObject(hints.jsonObject, for: .hints(authority: self.authority)))
    }

    /// An automatic call went out: it counts in the route's device-wide budget (design 40 §7.4).
    private func recordBudget(_ route: SGCustomerRoute, now: Date) {
        guard SGCustomerBudget.limit(for: route) != nil else {
            return
        }
        var budget = SGCustomerBudget(route: route, jsonObject: self.store.jsonObject(.budget(route: route, authority: self.authority)))
        budget.record(now: now)
        self.wrote(self.store.setJSONObject(budget.jsonObject, for: .budget(route: route, authority: self.authority)))
    }

    // MARK: Automatic link

    private func runAutoLink(_ account: Int64) {
        guard let context = self.accounts.context(accountPeerId: account) else {
            // Signed out under the decision: nothing was sent; it is decided again in 5 min.
            self.send(.autoLinkFinished(account: account, .bindInProgress, attestOffered: false))
            return
        }
        self.autoLink.run(accountPeerId: account, context: context, completion: { [weak self] outcome, attestOffered in
            self?.send(.autoLinkFinished(account: account, outcome, attestOffered: attestOffered))
        })
    }

    // MARK: Timers

    /// One timer per (account, kind): a new time replaces the old. Times are on the server-offset
    /// clock the reducer decides with; the wait is wall-clock, so a timer due during sleep fires on
    /// wake.
    private func schedule(_ key: TimerKey, at: Date, now: Date) {
        self.timers[key]?.item.cancel()
        let delay = min(max(0, at.timeIntervalSince(now)), SGCustomerSyncCoordinator.maxTimerDelay)
        self.timerGeneration &+= 1
        let generation = self.timerGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.timers[key]?.generation == generation else {
                return
            }
            self.timers[key] = nil
            self.send(.timer(account: key.account, key.timer))
        }
        self.timers[key] = (item, generation)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: item)
    }

    /// The longest wait asked of the main queue at once (the reducer re-plans on every event anyway).
    private static let maxTimerDelay: TimeInterval = 8 * 86_400

    // MARK: - Follow-ups after every batch of events

    /// The profile is read exactly for the accounts that may upload it; the analytics table follows
    /// the published clearance.
    private func followClearance() {
        var reading: [Int64: AccountContext] = [:]
        for (accountPeerId, clearance) in self.published where clearance.contains(.uploadProfile) {
            if let context = self.accounts.context(accountPeerId: accountPeerId) {
                reading[accountPeerId] = context
            }
        }
        self.profiles.read(reading)
        self.pushAccountsTable()
    }

    /// `SGAnalyticsPipeline.setAccounts` when the signed-in set, a recording permission or the active
    /// account changed — before any session effect that needs it.
    private func pushAccountsTable() {
        let accounts = self.signedIn.keys.sorted().compactMap { accountPeerId -> SGAnalyticsPipeline.Account? in
            guard let tg = self.signedIn[accountPeerId] else {
                return nil
            }
            return SGAnalyticsPipeline.Account(accountPeerId: accountPeerId, tg: tg, recordingAllowed: self.published[accountPeerId]?.contains(.recordEvents) ?? false)
        }
        if let pushed = self.accountsTable, pushed.accounts == accounts, pushed.active == self.primary {
            return
        }
        self.accountsTable = (accounts, self.primary)
        self.pipeline.setAccounts(accounts, activeAccountPeerId: self.primary)
    }

    /// The time zone, the locale or the app language changed: new events carry the new context, and
    /// every account that uploads its profile re-plans its sync (the digest covers these fields).
    private func deviceChanged() {
        assert(Thread.isMainThread)
        let facts = SGDeviceInfo.facts(uiLanguage: self.uiLanguage)
        guard facts != self.deviceFacts else {
            return
        }
        self.deviceFacts = facts
        self.pipeline.setContext(SGAnalyticsContext(facts: facts))
        for (accountPeerId, clearance) in self.published.sorted(by: { $0.key < $1.key }) where clearance.contains(.uploadProfile) {
            self.send(.timer(account: accountPeerId, .route(.sync)))
        }
    }

    private func postSummaryChange(_ accountPeerId: Int64?) {
        let userInfo: [AnyHashable: Any]? = accountPeerId.map { [SGCustomerSync.accountPeerIdKey: $0] }
        NotificationCenter.default.post(name: SGCustomerSync.consentSummaryDidChangeNotification, object: nil, userInfo: userInfo)
    }

    // MARK: - User-initiated (SGCustomerSync)

    func confirmDeletion(accountPeerId: Int64) -> SGCustomerDeletion.Report? {
        self.deletionReports[accountPeerId] = nil
        self.send(.userDeleteConfirmed(account: accountPeerId, idempotencyKey: SGCustomerTime.uuid4()))
        return self.deletionReports[accountPeerId]
    }

    func deletionReport(accountPeerId: Int64) -> SGCustomerDeletion.Report? {
        return self.deletionReports[accountPeerId]
    }

    func isInFlight(_ route: SGCustomerRoute, accountPeerId: Int64) -> Bool {
        return self.state.isInFlight(route, accountPeerId: accountPeerId)
    }

    // MARK: - Lifecycle (SGAnalyticsLifecycle)

    /// `didEnterBackground`, inside the `zg.customer.flush` background task: the reducer ends the
    /// session and sends at most one batch ≤ 64 KiB per account; `flush` ends when they answered.
    func enterBackground(_ flush: SGAnalyticsLifecycle.Flush) {
        self.backgroundFlush = flush
        self.send(.background)
        self.backgroundFlush = nil
        flush.ready()
    }
}

/// Zenlygram — the driver's half of the profile receipt (design 40 §9.3): the snapshot each account's
/// sync in flight sent, what its `.recordSyncReceipt` writes — once, and only while the session it
/// went under is still the account's stored one (`SGEntitlement.recordProfileSync`). `.clearReceipt`
/// (a withdrawal) also forgets that snapshot: it went under the grant just withdrawn, so a late
/// `.recordSyncReceipt` has nothing to write. The reducer never emits one then; this holds it a
/// second time. Main queue.
final class SGCustomerSyncReceipts {
    typealias Record = (_ accountPeerId: Int64, _ credential: SGEntitlementSessionCredential, _ digest: String, _ at: Date) -> Void

    private struct Sent {
        let digest: String
        let credential: SGEntitlementSessionCredential?
    }

    private var sent: [Int64: Sent] = [:]
    private let recordReceipt: Record
    private let clearReceipt: (Int64) -> Void

    /// - Parameters:
    ///   - record: `SGEntitlement.recordProfileSync` (tests record the calls).
    ///   - clear: `SGEntitlement.clearProfileSyncReceipt`.
    init(record: @escaping Record = { accountPeerId, credential, digest, at in
        SGEntitlement.shared.recordProfileSync(accountPeerId: accountPeerId, credential: credential, digest: digest, at: at)
    }, clear: @escaping (Int64) -> Void = { accountPeerId in
        SGEntitlement.shared.clearProfileSyncReceipt(accountPeerId: accountPeerId)
    }) {
        self.recordReceipt = record
        self.clearReceipt = clear
    }

    /// `.call(.sync)`: the snapshot about to be sent under `credential`.
    func willSend(account: Int64, digest: String, credential: SGEntitlementSessionCredential?) {
        self.sent[account] = Sent(digest: digest, credential: credential)
    }

    /// `.recordSyncReceipt`.
    func record(account: Int64, at: Date) {
        if let sent = self.sent.removeValue(forKey: account), let credential = sent.credential {
            self.recordReceipt(account, credential, sent.digest, at)
        }
    }

    /// `.clearReceipt`: the stored receipt and the snapshot in flight.
    func clear(account: Int64) {
        self.clearReceipt(account)
        self.sent[account] = nil
    }

    /// The snapshot was not sent, or the account left.
    func forget(account: Int64) {
        self.sent[account] = nil
    }
}
