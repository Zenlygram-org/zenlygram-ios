import Foundation
import SGEntitlement

// MARK: - Zenlygram Tasks cloud realtime (content-free invalidation hints)
//
// The repository's realtime controller: it runs ONE Pusher connection only while the Cloud board is
// visible, the app is in the foreground, the account has a server principal, no durable pause holds
// and the build has a Tasks backend. It never touches task content: a hint (and a successful
// (re)connect, and foreground) only asks the repository for its existing REST cycle, whose
// single-flight, Retry-After gate and backoff stay authoritative. While the socket is unavailable
// the repository's 60 s REST polling continues and the status says so (`fallback` / `disabled`),
// never `live`.
//
// Every asynchronous input — metadata, authorization, socket events, timers — carries the attempt
// number it was started under and is dropped when the attempt changed (stop, background, logout,
// account switch, pause, a newer attempt). A changed session under the SAME principal revalidates
// the live socket: the server's channel tells a refresh rotation (same channel, keep) from a re-bind
// (new generation, reconnect with fresh authorization).

/// What the board may say about realtime. `live` only after `subscription_succeeded` on the exact
/// channel; `fallback` / `disabled` mean the 60 s REST refresh is what keeps the board current.
public enum SGTasksCloudRealtimeStatus: Equatable {
    /// Not wanted now (board hidden, background, paused, no principal, no backend).
    case off
    case connecting
    case live
    /// Outage, backoff or given up until the next foreground / board start: REST polling only.
    case fallback
    /// The server's intentional kill switch: REST polling only.
    case disabled
}

protocol SGTasksCloudRealtimeSocketHandle: AnyObject {
    func start()
    func stop()
    func revalidate()
}

extension SGTasksRealtimeSocket: SGTasksCloudRealtimeSocketHandle {}

/// The realtime side of the network seam (production: `SGTasksCloudEntitlementRealtimeService`,
/// host tests: a scripted fake). Completion-based so a test decides exactly when an answer lands.
protocol SGTasksCloudRealtimeService: AnyObject {
    /// `stillWanted` on both named calls: SGEntitlement's post-gate re-check
    /// (`SGTasksCloudTransport`); a refused call sends nothing and answers `.transport(.cancelled)`.
    func metadata(accountPeerId: Int64, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Metadata, SGTasksError>) -> Void)
    func authorize(accountPeerId: Int64, socketId: SGTasksRealtime.SocketId, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void)
    /// The opaque marker of the stored session (nil: none).
    func sessionMarker(accountPeerId: Int64) -> SGTasksRealtime.SessionMarker?
    /// nil only for metadata that is not `enabled`.
    func makeSocket(metadata: SGTasksRealtime.Metadata, scheduler: SGTasksRealtimeScheduler, authorize: @escaping SGTasksRealtimeSocket.Authorize, events: @escaping (SGTasksRealtimeSocket.Event) -> Void) -> SGTasksCloudRealtimeSocketHandle?
}

struct SGTasksCloudRealtimeEnvironment {
    let service: SGTasksCloudRealtimeService
    /// A scheduler that runs its actions on the given (repository) queue.
    let makeScheduler: (DispatchQueue) -> SGTasksRealtimeScheduler
    /// Uniform in 0..<1 (reconnect jitter).
    let random: () -> Double
}

final class SGTasksCloudRealtime {
    /// What decides whether a connection is wanted at all.
    struct Conditions: Equatable {
        var visible: Bool
        var foreground: Bool
        var principal: String?
        var paused: Bool
        var configured: Bool

        var wantsConnection: Bool {
            return self.visible && self.foreground && self.principal != nil && !self.paused && self.configured
        }
    }

    /// The owner's side. All calls are made on the owner's queue.
    struct Hooks {
        /// Runs a block on the owner's queue (socket and network callbacks arrive anywhere).
        let perform: (@escaping () -> Void) -> Void
        /// The existing REST cycle (single-flight, gated).
        let requestPull: () -> Void
        /// Seconds until the account's Retry-After / backoff gate opens; nil when open.
        let gateDelay: () -> TimeInterval?
        /// The principal bound right now (strong fence on every callback).
        let currentPrincipal: () -> String?
        /// A refusal the repository's own rules handle (durable pauses, the 429 gate).
        let refused: (SGTasksError) -> Void
        let statusChanged: (SGTasksCloudRealtimeStatus) -> Void
        /// Whether a Tasks request may still go out — the repository's CURRENT traffic permission —
        /// handed to both named calls as SGEntitlement's post-gate re-check. Any thread. A refused
        /// call is a transient failure here; the repository's `update` (which follows every
        /// permission change) closes realtime.
        let stillWanted: () -> Bool
    }

    static let coalesceInterval: TimeInterval = 0.25
    static let minimumReconnectDelay: TimeInterval = 1.0
    static let maximumReconnectDelay: TimeInterval = 60.0
    /// The intentional kill switch (`enabled: false`) is re-read this rarely while the board stays
    /// open (a design choice; the contract only requires the truthful 60 s REST fallback meanwhile).
    static let disabledRecheckInterval: TimeInterval = 300.0

    private enum Phase {
        case idle
        case fetchingMetadata
        case connected(SGTasksCloudRealtimeSocketHandle)
        case waiting
    }

    private let accountPeerId: Int64
    private let service: SGTasksCloudRealtimeService
    private let scheduler: SGTasksRealtimeScheduler
    private let random: () -> Double
    private let hooks: Hooks

    private var conditions = Conditions(visible: false, foreground: false, principal: nil, paused: false, configured: false)
    private var phase: Phase = .idle
    private var attempt: UInt64 = 0
    private var attemptPrincipal: String?
    private var marker: SGTasksRealtime.SessionMarker?
    /// The current attempt's validated metadata (G5: every new connection attempt — cold start,
    /// reconnect, re-bind — asks `GET /v1/tasks/realtime` once; nothing is reused across attempts).
    private var metadata: SGTasksRealtime.Metadata?
    private var isLive = false
    private var failures = 0
    private var isResting = false
    private var retryWork: SGTasksRealtimeCancellable?
    private var coalesceWork: SGTasksRealtimeCancellable?
    private var stableWork: SGTasksRealtimeCancellable?
    private(set) var status: SGTasksCloudRealtimeStatus = .off

    init(accountPeerId: Int64, service: SGTasksCloudRealtimeService, scheduler: SGTasksRealtimeScheduler, random: @escaping () -> Double, hooks: Hooks) {
        self.accountPeerId = accountPeerId
        self.service = service
        self.scheduler = scheduler
        self.random = random
        self.hooks = hooks
    }

    deinit {
        // The repository is going away: close the socket and cancel every timer without calling
        // back into it (its hooks hold it weakly; nothing here retains the controller).
        if case let .connected(socket) = self.phase {
            socket.stop()
        }
        self.retryWork?.cancel()
        self.coalesceWork?.cancel()
        self.stableWork?.cancel()
    }

    // MARK: Inputs (owner queue)

    func update(_ next: Conditions) {
        let wasWanted = self.conditions.wantsConnection
        self.conditions = next
        guard next.wantsConnection else {
            self.teardown(.off)
            return
        }
        if let previous = self.attemptPrincipal, previous != next.principal {
            // Account switch / merge on this native account: nothing of the old attempt survives.
            self.teardown(.off)
        }
        if !wasWanted {
            // Foreground, board start, end of a pause: a fresh budget of attempts.
            self.failures = 0
            self.isResting = false
        }
        self.connectIfIdle()
    }

    /// A session notice. Same principal and a changed session: revalidate the live socket (the
    /// server's channel decides rotation vs re-bind); a socket not yet live restarts with fresh
    /// authorization. A changed or missing principal is `update`'s business.
    func sessionChanged() {
        let current = self.service.sessionMarker(accountPeerId: self.accountPeerId)
        guard current != self.marker else {
            return
        }
        self.marker = current
        if self.isResting {
            self.isResting = false
            self.failures = 0
        }
        guard self.conditions.wantsConnection, current != nil, self.attemptPrincipal == self.hooks.currentPrincipal() else {
            return
        }
        switch self.phase {
        case let .connected(socket) where self.isLive:
            socket.revalidate()
        case .connected, .fetchingMetadata:
            self.teardown(.connecting, keepMetadata: true)
            self.connectIfIdle()
        case .idle, .waiting:
            self.connectIfIdle()
        }
    }

    func stop() {
        self.teardown(.off)
    }

    // MARK: Attempts

    private func connectIfIdle() {
        guard self.conditions.wantsConnection, !self.isResting else {
            return
        }
        switch self.phase {
        case .idle:
            self.connect()
        case .fetchingMetadata, .connected, .waiting:
            break
        }
    }

    private func connect() {
        self.attempt &+= 1
        let attempt = self.attempt
        self.attemptPrincipal = self.conditions.principal
        self.marker = self.service.sessionMarker(accountPeerId: self.accountPeerId)
        // The shared reads budget: nothing is asked while the account's gate is closed.
        if let delay = self.hooks.gateDelay(), delay > 0 {
            self.wait(delay, status: .fallback)
            return
        }
        self.phase = .fetchingMetadata
        self.setStatus(.connecting)
        let perform = self.hooks.perform
        self.service.metadata(accountPeerId: self.accountPeerId, stillWanted: self.hooks.stillWanted) { [weak self] result in
            perform {
                self?.metadataArrived(result, attempt: attempt)
            }
        }
    }

    private func isCurrent(_ attempt: UInt64) -> Bool {
        guard attempt == self.attempt, self.conditions.wantsConnection else {
            return false
        }
        guard self.hooks.currentPrincipal() == self.attemptPrincipal else {
            // The binding moved under this attempt: drop it; the owner's next update reconnects.
            self.teardown(.off)
            return false
        }
        return true
    }

    private func metadataArrived(_ result: Result<SGTasksRealtime.Metadata, SGTasksError>, attempt: UInt64) {
        guard self.isCurrent(attempt), case .fetchingMetadata = self.phase else {
            return
        }
        switch result {
        case let .success(metadata):
            if case .disabled = metadata.availability {
                self.metadata = nil
                self.phase = .idle
                self.wait(Self.disabledRecheckInterval, status: .disabled)
                return
            }
            self.metadata = metadata
            self.open(metadata, attempt: attempt)
        case let .failure(error):
            self.phase = .idle
            self.refused(error, attempt: attempt)
        }
    }

    private func open(_ metadata: SGTasksRealtime.Metadata, attempt: UInt64) {
        let perform = self.hooks.perform
        let accountPeerId = self.accountPeerId
        let service = self.service
        let stillWanted = self.hooks.stillWanted
        let authorize: SGTasksRealtimeSocket.Authorize = { [weak self] socketId, completion in
            perform {
                guard let self = self, self.isCurrent(attempt), case .connected = self.phase else {
                    return
                }
                if let delay = self.hooks.gateDelay(), delay > 0 {
                    // The auth POST spends the shared reads budget: not before the gate opens
                    // (`wait` closes this socket).
                    self.wait(delay, status: .fallback)
                    return
                }
                service.authorize(accountPeerId: accountPeerId, socketId: socketId, stillWanted: stillWanted) { [weak self] result in
                    perform {
                        guard let self = self, self.isCurrent(attempt) else {
                            return
                        }
                        completion(result)
                    }
                }
            }
        }
        guard let socket = self.service.makeSocket(metadata: metadata, scheduler: self.scheduler, authorize: authorize, events: { [weak self] event in
            perform {
                self?.socketEvent(event, attempt: attempt)
            }
        }) else {
            // Validated metadata that still yields no socket will do so again: rest.
            self.metadata = nil
            self.rest()
            return
        }
        self.phase = .connected(socket)
        self.isLive = false
        self.setStatus(.connecting)
        socket.start()
    }

    private func socketEvent(_ event: SGTasksRealtimeSocket.Event, attempt: UInt64) {
        guard self.isCurrent(attempt), case .connected = self.phase else {
            return
        }
        switch event {
        case .subscribed:
            self.isLive = true
            self.setStatus(.live)
            // A (re)connect may have missed hints: repair through the existing REST cycle now.
            self.hooks.requestPull()
            let timeout = TimeInterval(self.metadata?.activityTimeout ?? SGTasksRealtime.activityTimeoutRange.lowerBound)
            self.stableWork?.cancel()
            self.stableWork = self.scheduler.schedule(after: timeout) { [weak self] in
                guard let self = self, attempt == self.attempt, self.isLive else {
                    return
                }
                // Stable for an activity timeout: only now is the backoff forgiven.
                self.stableWork = nil
                self.failures = 0
            }
        case .invalidated:
            guard self.isLive, self.coalesceWork == nil else {
                return
            }
            self.coalesceWork = self.scheduler.schedule(after: Self.coalesceInterval) { [weak self] in
                guard let self = self else {
                    return
                }
                self.coalesceWork = nil
                guard attempt == self.attempt, self.isLive else {
                    return
                }
                self.hooks.requestPull()
            }
        case let .closed(reason):
            self.phase = .idle
            self.isLive = false
            self.stableWork?.cancel()
            self.stableWork = nil
            self.closed(reason, attempt: attempt)
        }
    }

    private func closed(_ reason: SGTasksRealtimeSocket.CloseReason, attempt: UInt64) {
        switch reason {
        case .channelChanged:
            // A re-bind rotated the server generation: a new socket, a new authorization, now.
            self.setStatus(.connecting)
            self.connect()
        case let .authorization(error):
            self.refused(error, attempt: attempt)
        case let .server(code):
            if let code = code, (4000 ... 4099).contains(code) {
                // The server asked not to reconnect: REST only until the next foreground / start.
                self.metadata = nil
                self.rest()
            } else if let code = code, (4200 ... 4299).contains(code) {
                self.failed(attempt: attempt, delay: self.jittered(Self.minimumReconnectDelay))
            } else {
                self.failed(attempt: attempt, delay: nil)
            }
        case .protocolViolation, .subscriptionRefused:
            // Deterministic (the server's frames or its refusal will be the same on the next
            // attempt): rest until the next foreground / board start / session change instead of
            // spending the shared reads budget every 30-60 s. The REST poll carries on.
            self.metadata = nil
            self.rest()
        case .transport, .heartbeatTimeout:
            self.failed(attempt: attempt, delay: nil)
        }
    }

    /// A refusal from either named call (metadata GET or the socket's auth POST).
    private func refused(_ error: SGTasksError, attempt: UInt64) {
        // R4 first: a consent fence (`tasks_consent_required`, kind `.rejected(403)`) is the
        // repository's account-wide backoff, which ends realtime through `update`.
        if case .consentRequired? = error.refinement {
            self.teardown(.off)
            self.hooks.refused(error)
            return
        }
        switch error.kind {
        case .accountNotLinked, .notSignedIn, .notConfigured, .session:
            // The repository records its durable pause; that ends realtime through `update`.
            self.teardown(.off)
            self.hooks.refused(error)
        case .rateLimited:
            // The same reads budget as snapshot/changes: the account gate is the single authority.
            self.hooks.refused(error)
            self.failed(attempt: attempt, delay: self.hooks.gateDelay())
        case .credentialChanged:
            // The session moved during the call: a fresh attempt under the current session.
            self.failed(attempt: attempt, delay: nil)
        case .transport, .unavailable, .mutationInFlight:
            self.failed(attempt: attempt, delay: error.retryAfter.map(TimeInterval.init))
        case .malformedResponse, .invalidRequest, .invalidLocalRequest, .rejected, .mutationMismatch, .notFound, .conflict, .resyncRequired, .creationNotPermitted:
            // Not a transient condition this client can fix by retrying (a 200 that broke the wire,
            // metadata off the origin, an oversized answer, a refusal): rest, never a retry storm.
            self.metadata = nil
            self.rest()
        }
    }

    /// One more consecutive transient failure: wait the bounded exponential 1...60 s with jitter, or
    /// longer when a shared Retry-After (or a 503 Retry-After) says so. Transient failures never
    /// exhaust; only the 4000-range close and non-transient refusals rest.
    private func failed(attempt: UInt64, delay minimum: TimeInterval?) {
        guard attempt == self.attempt else {
            return
        }
        self.failures += 1
        var delay = self.jittered(Self.backoffBase(failures: self.failures))
        if let minimum = minimum {
            delay = max(delay, minimum)
        }
        self.wait(delay, status: .fallback)
    }

    /// Exponential 1 s ... 60 s.
    static func backoffBase(failures: Int) -> TimeInterval {
        let exponent = Double(max(failures - 1, 0))
        return min(Self.minimumReconnectDelay * pow(2.0, exponent), Self.maximumReconnectDelay)
    }

    /// Uniform in [base / 2, base], never under 1 s.
    private func jittered(_ base: TimeInterval) -> TimeInterval {
        let fraction = min(max(self.random(), 0), 1)
        return max(Self.minimumReconnectDelay, base * (0.5 + 0.5 * fraction))
    }

    private func wait(_ delay: TimeInterval, status: SGTasksCloudRealtimeStatus) {
        self.closeSocket()
        self.retryWork?.cancel()
        let attempt = self.attempt
        self.phase = .waiting
        self.setStatus(status)
        self.retryWork = self.scheduler.schedule(after: delay) { [weak self] in
            guard let self = self, attempt == self.attempt, case .waiting = self.phase else {
                return
            }
            self.retryWork = nil
            self.phase = .idle
            self.connectIfIdle()
        }
    }

    /// No more attempts until the next foreground, board start or session change.
    private func rest() {
        self.closeSocket()
        self.retryWork?.cancel()
        self.retryWork = nil
        self.phase = .idle
        self.isResting = true
        self.setStatus(.fallback)
    }

    private func closeSocket() {
        if case let .connected(socket) = self.phase {
            socket.stop()
        }
        self.isLive = false
        self.stableWork?.cancel()
        self.stableWork = nil
    }

    /// Ends the attempt: every later callback of it is dropped, every timer cancelled.
    private func teardown(_ status: SGTasksCloudRealtimeStatus, keepMetadata: Bool = false) {
        self.attempt &+= 1
        self.closeSocket()
        self.retryWork?.cancel()
        self.retryWork = nil
        self.coalesceWork?.cancel()
        self.coalesceWork = nil
        self.phase = .idle
        self.attemptPrincipal = nil
        if !keepMetadata {
            self.metadata = nil
        }
        self.setStatus(status)
    }

    private func setStatus(_ status: SGTasksCloudRealtimeStatus) {
        guard status != self.status else {
            return
        }
        self.status = status
        self.hooks.statusChanged(status)
    }
}

// MARK: - Repository wiring

extension SGTasksCloudRepository {
    /// On queue. Re-evaluates whether realtime is wanted (board, foreground, principal, pause,
    /// backend, store) after any of them may have changed.
    func updateRealtime() {
        guard let realtime = self.realtime else {
            return
        }
        let configured = self.environment.transport.isConfigured && self.store != nil && !self.isInvalidated
        // Its metadata and auth calls are Tasks requests: none under a consent hold or fence.
        let consentHeld = !self.permitsTraffic || (self.consentFence().map { $0.until > self.environment.now() } ?? false)
        realtime.update(SGTasksCloudRealtime.Conditions(
            visible: self.isStarted,
            foreground: self.isForeground,
            principal: configured ? self.environment.transport.principal(accountPeerId: self.accountPeerId) : nil,
            paused: self.pauseReason != nil || consentHeld,
            configured: configured
        ))
    }

    /// On queue. A refusal from the realtime calls, under the repository's existing rules: the
    /// durable session/link pauses and the account-wide 429 gate.
    func handleRealtimeRefusal(_ error: SGTasksError) {
        guard !self.isInvalidated, self.store != nil else {
            return
        }
        if case .consentRequired? = error.refinement {
            self.handlePullFailure(error)
            self.rebuildState()
            self.updateRealtime()
            return
        }
        switch error.kind {
        case .accountNotLinked, .notSignedIn, .notConfigured, .session, .rateLimited:
            self.handlePullFailure(error)
            self.rebuildState()
            self.updateRealtime()
        default:
            break
        }
    }

    /// App entered the background: the socket closes (REST holds stay as they are).
    func applicationDidEnterBackground() {
        self.onQueue {
            self.isForeground = false
            self.updateRealtime()
        }
    }

    /// App returns to the foreground: an immediate REST repair and, if the board is visible, a
    /// fresh realtime attempt.
    func applicationWillEnterForeground() {
        self.onQueue {
            self.isForeground = true
            guard !self.isInvalidated else {
                return
            }
            if self.isStarted {
                self.requestCycle(explicit: false)
            }
            self.updateRealtime()
        }
    }

    static func makeRealtime(for repository: SGTasksCloudRepository, environment: SGTasksCloudRealtimeEnvironment) -> SGTasksCloudRealtime {
        let queue = repository.queue
        return SGTasksCloudRealtime(
            accountPeerId: repository.accountPeerId,
            service: environment.service,
            scheduler: environment.makeScheduler(queue),
            random: environment.random,
            hooks: SGTasksCloudRealtime.Hooks(
                perform: { [weak repository] block in
                    guard let repository = repository else {
                        return
                    }
                    repository.queue.async {
                        guard !repository.isInvalidated else {
                            return
                        }
                        block()
                    }
                },
                requestPull: { [weak repository] in
                    repository?.requestCycle(explicit: false)
                },
                gateDelay: { [weak repository] in
                    guard let repository = repository, let gate = repository.accountGate() else {
                        return nil
                    }
                    let remaining = gate.until.timeIntervalSince(repository.environment.now())
                    return remaining > 0 ? remaining : nil
                },
                currentPrincipal: { [weak repository] in
                    guard let repository = repository else {
                        return nil
                    }
                    return repository.environment.transport.principal(accountPeerId: repository.accountPeerId)
                },
                refused: { [weak repository] error in
                    repository?.handleRealtimeRefusal(error)
                },
                statusChanged: { [weak repository] status in
                    repository?.publishRealtimeStatus(status)
                },
                stillWanted: { [weak repository] in
                    return repository?.stillPermitsTraffic() ?? false
                }
            )
        )
    }
}
