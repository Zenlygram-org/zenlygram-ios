import Foundation

/// Zenlygram — the analytics sink of the main app (design 40 §10.3–10.6, contract §3.3, §3.6): it
/// owns the accounts table, the per-account sessions, the per-session dedup and aggregation, `seq`,
/// the on-disk queue and the batch hand-out. Everything runs on one serial queue
/// (`uz.zenlygram.customer.analytics`); `receive` hops onto it and returns at once, every other
/// method runs on it synchronously (inline when already there) and must not be called from a sink
/// callback.
///
/// Rules:
/// - The owning account is the explicit `accountPeerId`, else the active one. An account the table
///   does not list as allowed to record (`recordEvents` clearance) gets nothing: its event is
///   dropped before storage, never attributed to another account.
/// - `screen.view` is dropped when the same screen was this session's last view < 30 s ago, and
///   when the account has had no session in THIS process (no attribution to an earlier process's
///   session). `feature.used` is kept once per feature per session.
/// - `error.occurred` (per domain and code) and `tasks.sync_issue` (per kind) are counted per session
///   (`count` ≤ 1000) and emitted at session end and before every batch hand-out.
/// - Events between sessions use the account's most recent session (the sessions sidecar, also
///   from an earlier process) and continue its `seq`; an account that never had a session drops
///   them. `seq` strictly increases per (account, session); `app.session_start` is 0.
/// - Until both the accounts table and the context are set, at most 100 calls wait in order.
public final class SGAnalyticsPipeline: SGAnalyticsSink {
    /// One signed-in account as the coordinator publishes it.
    public struct Account: Equatable {
        /// The packed `PeerId.toInt64()`.
        public let accountPeerId: Int64
        /// The RAW Telegram user id (queue files, sessions).
        public let tg: Int64
        /// The account's clearance holds `recordEvents`.
        public let recordingAllowed: Bool

        public init(accountPeerId: Int64, tg: Int64, recordingAllowed: Bool) {
            self.accountPeerId = accountPeerId
            self.tg = tg
            self.recordingAllowed = recordingAllowed
        }
    }

    public static let queueLabel = "uz.zenlygram.customer.analytics"
    /// The same screen again within this many seconds is not a new view.
    public static let screenDedupInterval: TimeInterval = 30
    public static let maxAggregateCount = 1000
    static let maxWaitingCalls = 100

    private enum Call {
        case input(SGAnalyticsInput, accountPeerId: Int64?, at: Date)
        case sessionStart(accountPeerId: Int64, trigger: SGAnalyticsSessionTrigger, at: Date)
        case sessionEnd(accountPeerId: Int64, reason: SGAnalyticsSessionEndReason, at: Date)
    }

    private struct ErrorKey: Hashable {
        let domain: SGAnalyticsErrorDomain
        let code: SGAnalyticsErrorCode
    }

    private struct Session {
        let id: String
        var lastSeq: Int
        /// `uptime` at start; nil for a session continued from an earlier process.
        var startedAt: TimeInterval?
        var isOpen: Bool
        var lastScreen: SGAnalyticsScreen?
        var lastScreenAt: TimeInterval = 0
        var featuresUsed = Set<SGAnalyticsFeature>()
        var errors: [(key: ErrorKey, count: Int)] = []
        var syncIssues: [(kind: SGAnalyticsTasksSyncIssueKind, count: Int)] = []
    }

    private let store: SGAnalyticsQueueStore
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let uptime: () -> TimeInterval
    private let makeId: () -> String

    private var accounts: [Int64: Account] = [:]
    private var accountsKnown = false
    private var activeAccountPeerId: Int64?
    private var context: SGAnalyticsContext?
    private var waiting: [Call] = []
    /// By RAW Telegram id.
    private var sessions: [Int64: Session] = [:]
    private var startedThisProcess = Set<Int64>()
    private var inFlight: [Int64: String] = [:]

    /// - Parameters:
    ///   - store: the account queues of the current backend origin.
    ///   - uptime: monotonic seconds (`ProcessInfo.systemUptime`): session durations, the screen dedup.
    ///   - makeId: uuid4 for event, session and batch ids.
    public init(store: SGAnalyticsQueueStore, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, makeId: @escaping () -> String = { SGCustomerTime.uuid4() }) {
        self.store = store
        self.queue = DispatchQueue(label: SGAnalyticsPipeline.queueLabel)
        self.uptime = uptime
        self.makeId = makeId
        self.queue.setSpecific(key: self.queueKey, value: ())
    }

    // MARK: - SGAnalyticsSink

    public func receive(_ input: SGAnalyticsInput, accountPeerId: Int64?, at: Date) {
        self.queue.async {
            self.handle(.input(input, accountPeerId: accountPeerId, at: at))
        }
    }

    // MARK: - Driver (SGCustomerSync)

    /// The signed-in accounts and the active one, from the gate (on every clearance or account
    /// change). An account no longer allowed to record loses its in-memory session state.
    public func setAccounts(_ accounts: [Account], activeAccountPeerId: Int64?) {
        self.sync {
            var table: [Int64: Account] = [:]
            for account in accounts {
                table[account.accountPeerId] = account
            }
            self.accounts = table
            self.activeAccountPeerId = activeAccountPeerId
            self.accountsKnown = true
            let recording = Set(accounts.filter(\.recordingAllowed).map(\.tg))
            self.sessions = self.sessions.filter { recording.contains($0.key) }
            self.startedThisProcess.formIntersection(recording)
            self.drainWaiting()
        }
    }

    /// The context new events are recorded under (device facts; set at start and on every change).
    public func setContext(_ context: SGAnalyticsContext) {
        self.sync {
            self.context = context
            self.drainWaiting()
        }
    }

    /// Starts the account's session (`app.session_start`, `seq` 0) unless one is open.
    public func sessionStart(accountPeerId: Int64, trigger: SGAnalyticsSessionTrigger, at: Date) {
        self.sync {
            self.handle(.sessionStart(accountPeerId: accountPeerId, trigger: trigger, at: at))
        }
    }

    /// Ends the account's open session: its aggregates, then `app.session_end` with the foreground
    /// seconds since its start.
    public func sessionEnd(accountPeerId: Int64, reason: SGAnalyticsSessionEndReason, at: Date) {
        self.sync {
            self.handle(.sessionEnd(accountPeerId: accountPeerId, reason: reason, at: at))
        }
    }

    /// Events queued for the account (flush triggers).
    public func queuedCount(tg: Int64) -> Int {
        return self.sync {
            self.store.count(tg: tg)
        }
    }

    /// The account's next batch, or nil (one already in flight, nothing to send). The session's
    /// aggregates are queued first; events outside the `sent_at` window are deleted.
    public func nextBatch(tg: Int64, limit: Int, maxBytes: Int, sentAt: Date) -> SGAnalyticsBatch? {
        return self.sync {
            guard self.inFlight[tg] == nil else {
                return nil
            }
            if let context = self.context, self.isRecording(tg: tg), var session = self.sessions[tg] {
                self.emitAggregates(&session, tg: tg, context: context, at: sentAt)
                self.sessions[tg] = session
            }
            let selection = SGAnalyticsBatcher.select(self.store.entries(tg: tg), limit: limit, maxBytes: maxBytes, sentAt: sentAt) { id in
                self.store.context(tg: tg, id: id)
            }
            if !selection.expired.isEmpty {
                self.store.remove(tg: tg, ids: Set(selection.expired))
            }
            guard let contextId = selection.contextId, let context = self.store.context(tg: tg, id: contextId), !selection.events.isEmpty else {
                return nil
            }
            let batchId = self.makeId()
            self.inFlight[tg] = batchId
            return SGAnalyticsBatch(
                tg: tg,
                batchId: batchId,
                sentAt: sentAt,
                body: SGAnalyticsBatcher.envelope(batchId: batchId, sentAt: sentAt, context: context, events: selection.events.map(\.event)),
                eventIds: selection.events.map(\.id),
                generation: self.store.generation(tg: tg)
            )
        }
    }

    /// Ends `batch`; with `deleteEvents` (`SGAnalyticsBatcher.apply`) its events leave the queue —
    /// unless the account was purged since the hand-out.
    public func complete(_ batch: SGAnalyticsBatch, deleteEvents: Bool) {
        self.sync {
            guard self.inFlight[batch.tg] == batch.batchId else {
                return
            }
            self.inFlight[batch.tg] = nil
            guard deleteEvents, self.store.generation(tg: batch.tg) == batch.generation else {
                return
            }
            self.store.remove(tg: batch.tg, ids: Set(batch.eventIds))
        }
    }

    /// Withdrawal, deletion, logout: the account's queue and sessions file under every origin,
    /// its in-memory sessions and any batch in flight.
    public func purge(tg: Int64) {
        self.sync {
            self.store.purge(tg: tg)
            self.sessions[tg] = nil
            self.startedThisProcess.remove(tg)
            self.inFlight[tg] = nil
        }
    }

    /// Returns once everything `receive`d before is processed.
    public func waitUntilIdle() {
        self.sync {}
    }

    // MARK: - Processing (on the queue)

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: self.queueKey) != nil {
            return body()
        }
        return self.queue.sync(execute: body)
    }

    private func drainWaiting() {
        guard self.accountsKnown, self.context != nil, !self.waiting.isEmpty else {
            return
        }
        let calls = self.waiting
        self.waiting = []
        for call in calls {
            self.handle(call)
        }
    }

    private func handle(_ call: Call) {
        guard self.accountsKnown, let context = self.context else {
            if self.waiting.count < SGAnalyticsPipeline.maxWaitingCalls {
                self.waiting.append(call)
            }
            return
        }
        switch call {
        case let .input(input, accountPeerId, at):
            guard let tg = self.recordingAccount(accountPeerId ?? self.activeAccountPeerId) else {
                return
            }
            self.record(input, tg: tg, context: context, at: at)
        case let .sessionStart(accountPeerId, trigger, at):
            guard let tg = self.recordingAccount(accountPeerId), self.sessions[tg]?.isOpen != true else {
                return
            }
            var session = Session(id: self.makeId(), lastSeq: -1, startedAt: self.uptime(), isOpen: true)
            self.append(.sessionStart(trigger), to: &session, tg: tg, context: context, at: at)
            session.lastSeq = max(session.lastSeq, 0)
            self.sessions[tg] = session
            self.startedThisProcess.insert(tg)
        case let .sessionEnd(accountPeerId, reason, at):
            guard let tg = self.recordingAccount(accountPeerId), var session = self.sessions[tg], session.isOpen else {
                return
            }
            self.emitAggregates(&session, tg: tg, context: context, at: at)
            let now = self.uptime()
            let duration = max(0, now - (session.startedAt ?? now))
            self.append(.sessionEnd(durationS: Int(duration.rounded(.down)), reason: reason), to: &session, tg: tg, context: context, at: at)
            session.isOpen = false
            self.sessions[tg] = session
        }
    }

    /// The RAW id of the owning account when it may record, else nil.
    private func recordingAccount(_ accountPeerId: Int64?) -> Int64? {
        guard let accountPeerId, let account = self.accounts[accountPeerId], account.recordingAllowed, account.tg > 0 else {
            return nil
        }
        return account.tg
    }

    private func isRecording(tg: Int64) -> Bool {
        return self.accounts.values.contains { $0.tg == tg && $0.recordingAllowed }
    }

    private func record(_ input: SGAnalyticsInput, tg: Int64, context: SGAnalyticsContext, at: Date) {
        if case let .event(.screenView(screen)) = input {
            guard self.startedThisProcess.contains(tg), var session = self.sessions[tg] else {
                return
            }
            let now = self.uptime()
            if session.lastScreen == screen, now - session.lastScreenAt < SGAnalyticsPipeline.screenDedupInterval {
                return
            }
            if self.append(SGAnalyticsEvent.screenView(screen).payload, to: &session, tg: tg, context: context, at: at) {
                session.lastScreen = screen
                session.lastScreenAt = now
            }
            self.sessions[tg] = session
            return
        }
        guard var session = self.currentSession(tg: tg) else {
            return
        }
        switch input {
        case let .event(event):
            if case let .featureUsed(feature) = event {
                guard !session.featuresUsed.contains(feature) else {
                    return
                }
                if self.append(event.payload, to: &session, tg: tg, context: context, at: at) {
                    session.featuresUsed.insert(feature)
                }
            } else {
                self.append(event.payload, to: &session, tg: tg, context: context, at: at)
            }
        case let .error(domain, code):
            let key = ErrorKey(domain: domain, code: code)
            if let index = session.errors.firstIndex(where: { $0.key == key }) {
                session.errors[index].count = min(SGAnalyticsPipeline.maxAggregateCount, session.errors[index].count + 1)
            } else {
                session.errors.append((key, 1))
            }
        case let .tasksSyncIssue(kind, count):
            let added = max(1, count)
            if let index = session.syncIssues.firstIndex(where: { $0.kind == kind }) {
                session.syncIssues[index].count = min(SGAnalyticsPipeline.maxAggregateCount, session.syncIssues[index].count + added)
            } else {
                session.syncIssues.append((kind, min(SGAnalyticsPipeline.maxAggregateCount, added)))
            }
        }
        self.sessions[tg] = session
    }

    /// The account's session in memory, else the most recent one of the sidecar (continued; its
    /// `seq` is the highest the sidecar or the queue has given out), else nil.
    private func currentSession(tg: Int64) -> Session? {
        if let session = self.sessions[tg] {
            return session
        }
        guard let marker = self.store.session(tg: tg) else {
            return nil
        }
        let queued = self.store.entries(tg: tg).filter { $0.sessionId == marker.sessionId }.map(\.seq).max() ?? 0
        let session = Session(id: marker.sessionId, lastSeq: max(marker.seq, queued), startedAt: nil, isOpen: false)
        self.sessions[tg] = session
        return session
    }

    /// Queues the session's aggregates (`error.occurred`, then `tasks.sync_issue`) and clears them.
    private func emitAggregates(_ session: inout Session, tg: Int64, context: SGAnalyticsContext, at: Date) {
        let errors = session.errors
        let syncIssues = session.syncIssues
        session.errors = []
        session.syncIssues = []
        for error in errors {
            self.append(.errorOccurred(domain: error.key.domain, code: error.key.code, count: error.count), to: &session, tg: tg, context: context, at: at)
        }
        for issue in syncIssues {
            self.append(.tasksSyncIssue(kind: issue.kind, count: issue.count), to: &session, tg: tg, context: context, at: at)
        }
    }

    /// Queues `payload` as the session's next `seq`; false (the `seq` not spent) when it would pass
    /// 1 000 000 or the queue refused it.
    @discardableResult
    private func append(_ payload: SGAnalyticsPayload, to session: inout Session, tg: Int64, context: SGAnalyticsContext, at: Date) -> Bool {
        let seq = session.lastSeq + 1
        guard seq <= SGAnalyticsTaxonomy.maxSeq else {
            return false
        }
        let event = SGAnalyticsWireEvent(id: self.makeId(), ts: SGCustomerTime.instant(at), sessionId: session.id, seq: seq, payload: payload)
        guard event.isValid else {
            return false
        }
        guard self.store.append(tg: tg, context: context, event: event) else {
            SGCustomerLog.log(self.store.isReadable ? .analyticsQueueWriteFailed : .analyticsQueueUnreadable)
            return false
        }
        session.lastSeq = seq
        self.store.setSession(SGAnalyticsSessionMarker(sessionId: session.id, seq: seq), tg: tg)
        return true
    }
}
