import Foundation
// `@testable`: the repository cases drive the REAL `SGTasksRealtimeSocket` through its internal
// WebSocket seam (`run-cloud-tests.sh` builds the core with `-enable-testing`).
@testable import SGEntitlement

// Host tests for the Tasks cloud realtime controller (`SGTasksCloudRealtime`), driven through a
// deterministic scheduler, a scripted service and scripted sockets. Every assertion is about what
// the controller asked the network for, which socket it kept, what it reported and which REST pull
// it requested. Compiled into the cloud test executable (`run-cloud-tests.sh`), whose runner appends
// `SGTasksCloudRealtimeTests.cases`; the repository-level realtime cases there use the real-socket
// fixtures below.

/// A scripted WebSocket under the REAL Pusher socket: records the handshake and what was sent, and
/// delivers server frames on the test thread.
final class SGTasksRealtimeTestWebSocket: SGTasksRealtimeWebSocket {
    private let lock = NSLock()
    private var events: ((SGTasksRealtimeWebSocketEvent) -> Void)?
    private var sentFrames: [String] = []
    private var closes = 0
    private(set) var requests: [URLRequest] = []

    func open(_ request: URLRequest, events: @escaping (SGTasksRealtimeWebSocketEvent) -> Void) {
        self.lock.lock()
        self.requests.append(request)
        self.events = events
        self.lock.unlock()
    }

    func send(_ text: String) {
        self.lock.lock()
        self.sentFrames.append(text)
        self.lock.unlock()
    }

    func close() {
        self.lock.lock()
        self.closes += 1
        self.lock.unlock()
    }

    var sent: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.sentFrames
    }

    var closeCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.closes
    }

    private func deliver(_ event: SGTasksRealtimeWebSocketEvent) {
        self.lock.lock()
        let events = self.events
        self.lock.unlock()
        events?(event)
    }

    /// Open, then `pusher:connection_established` (data as a JSON-encoded string, as Reverb sends it).
    func establish(socketId: String = "123.456", timeout: Int = 30) {
        self.deliver(.opened)
        self.frame(#"{"event":"pusher:connection_established","data":"{\"socket_id\":\"\#(socketId)\",\"activity_timeout\":\#(timeout)}"}"#)
    }

    func frame(_ text: String) {
        self.deliver(.text(text))
    }

    func failTransport() {
        self.deliver(.failed)
    }
}

/// The realtime service with the REAL socket: metadata and the auth POST are scripted answers
/// (the SGEntitlement facade's results), the Pusher connection itself is `SGTasksRealtimeSocket`.
final class SGTasksRealtimeSocketTestService: SGTasksCloudRealtimeService {
    var marker: SGTasksRealtime.SessionMarker? = SGTasksRealtime.SessionMarker(refreshToken: "r1", accountId: "acc", deviceId: "dev")
    private(set) var metadataCompletions: [(Result<SGTasksRealtime.Metadata, SGTasksError>) -> Void] = []
    private(set) var authorizeCalls: [(socketId: SGTasksRealtime.SocketId, completion: (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void)] = []
    private(set) var webSockets: [SGTasksRealtimeTestWebSocket] = []

    func metadata(accountPeerId: Int64, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Metadata, SGTasksError>) -> Void) {
        self.metadataCompletions.append(completion)
    }

    func authorize(accountPeerId: Int64, socketId: SGTasksRealtime.SocketId, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void) {
        self.authorizeCalls.append((socketId, completion))
    }

    func sessionMarker(accountPeerId: Int64) -> SGTasksRealtime.SessionMarker? {
        return self.marker
    }

    func makeSocket(metadata: SGTasksRealtime.Metadata, scheduler: SGTasksRealtimeScheduler, authorize: @escaping SGTasksRealtimeSocket.Authorize, events: @escaping (SGTasksRealtimeSocket.Event) -> Void) -> SGTasksCloudRealtimeSocketHandle? {
        let webSocket = SGTasksRealtimeTestWebSocket()
        guard let socket = SGTasksRealtimeSocket(metadata: metadata, scheduler: scheduler, webSocket: webSocket, authorize: authorize, events: events) else {
            return nil
        }
        self.webSockets.append(webSocket)
        return socket
    }
}

/// Holds an async call until the test opens it.
final class SGTasksTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    var isWaiting: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            if self.isOpen {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func open() {
        self.lock.lock()
        self.isOpen = true
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume()
    }
}

/// The `subscription_succeeded` frame for the fixture subscription's channel.
func realtimeSubscribedFrame(token: Character = "A") -> String {
    return #"{"event":"pusher_internal:subscription_succeeded","channel":"private-tasks.\#(String(repeating: token, count: 43))","data":"{}"}"#
}

func realtimeHintFrame(token: Character = "A") -> String {
    return #"{"event":"tasks.changed","channel":"private-tasks.\#(String(repeating: token, count: 43))","data":"{\"v\":1}"}"#
}

enum SGTasksRealtimeTestFailure: Error {
    case assertion(String)
}

func realtimeCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw SGTasksRealtimeTestFailure.assertion(message)
    }
}

/// A manual clock: actions run only when the test advances past their due time. Its state (items,
/// cancellation, now) is under one lock; actions always run OUTSIDE the lock, so an action may
/// schedule or cancel. Repository cases advance it on the repository queue (the owner queue the
/// dispatch scheduler would use), while sockets may schedule from the test thread.
final class SGTasksRealtimeTestScheduler: SGTasksRealtimeScheduler, @unchecked Sendable {
    private final class Item: SGTasksRealtimeCancellable {
        let due: TimeInterval
        let order: Int
        let action: () -> Void
        private let lock: NSLock
        private var cancelled = false

        init(due: TimeInterval, order: Int, lock: NSLock, action: @escaping () -> Void) {
            self.due = due
            self.order = order
            self.lock = lock
            self.action = action
        }

        func cancel() {
            self.lock.lock()
            self.cancelled = true
            self.lock.unlock()
        }

        /// Caller holds the scheduler lock.
        var isCancelledLocked: Bool {
            return self.cancelled
        }

        /// Caller holds the scheduler lock.
        func cancelLocked() {
            self.cancelled = true
        }
    }

    private let lock = NSLock()
    private var nowValue: TimeInterval = 0
    private var items: [Item] = []
    private var counter = 0

    var now: TimeInterval {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.nowValue
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SGTasksRealtimeCancellable {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.counter += 1
        let item = Item(due: self.nowValue + max(delay, 0), order: self.counter, lock: self.lock, action: action)
        self.items.append(item)
        return item
    }

    var pendingDelays: [TimeInterval] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.items.filter { !$0.isCancelledLocked }.map { $0.due - self.nowValue }.sorted()
    }

    func advance(by interval: TimeInterval) {
        self.lock.lock()
        let target = self.nowValue + interval
        self.lock.unlock()
        while true {
            self.lock.lock()
            guard let next = self.items.filter({ !$0.isCancelledLocked && $0.due <= target }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) else {
                self.nowValue = target
                self.items.removeAll { $0.isCancelledLocked }
                self.lock.unlock()
                return
            }
            self.nowValue = next.due
            next.cancelLocked()
            self.lock.unlock()
            next.action()
        }
    }

    /// Cancels everything still pending (case cleanup).
    func cancelAll() {
        self.lock.lock()
        for item in self.items {
            item.cancelLocked()
        }
        self.items.removeAll()
        self.lock.unlock()
    }
}

final class SGTasksRealtimeTestSocket: SGTasksCloudRealtimeSocketHandle {
    let metadata: SGTasksRealtime.Metadata
    let authorize: SGTasksRealtimeSocket.Authorize
    let events: (SGTasksRealtimeSocket.Event) -> Void
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var revalidations = 0
    /// What the socket's authorize completion received (only when the controller delivered it).
    private(set) var delivered: [Result<SGTasksRealtime.Subscription, SGTasksError>] = []

    init(metadata: SGTasksRealtime.Metadata, authorize: @escaping SGTasksRealtimeSocket.Authorize, events: @escaping (SGTasksRealtimeSocket.Event) -> Void) {
        self.metadata = metadata
        self.authorize = authorize
        self.events = events
    }

    func start() {
        self.started += 1
    }

    func stop() {
        self.stopped += 1
    }

    func revalidate() {
        self.revalidations += 1
    }

    /// The socket received `connection_established` and asks for its authorization.
    func requestAuthorization(_ raw: String = "123.456") {
        self.authorize(SGTasksRealtime.SocketId(raw)!) { [weak self] result in
            self?.delivered.append(result)
        }
    }
}

final class SGTasksRealtimeTestService: SGTasksCloudRealtimeService {
    var marker: SGTasksRealtime.SessionMarker? = SGTasksRealtime.SessionMarker(refreshToken: "r1", accountId: "acc", deviceId: "dev")
    private(set) var metadataCompletions: [(Result<SGTasksRealtime.Metadata, SGTasksError>) -> Void] = []
    private(set) var authorizeCalls: [(socketId: SGTasksRealtime.SocketId, completion: (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void)] = []
    private(set) var sockets: [SGTasksRealtimeTestSocket] = []
    /// The post-gate re-check (`stillWanted`) each named call carried, in call order.
    private(set) var stillWantedChecks: [() -> Bool] = []

    func metadata(accountPeerId: Int64, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Metadata, SGTasksError>) -> Void) {
        self.stillWantedChecks.append(stillWanted)
        self.metadataCompletions.append(completion)
    }

    func authorize(accountPeerId: Int64, socketId: SGTasksRealtime.SocketId, stillWanted: @escaping () -> Bool, completion: @escaping (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void) {
        self.stillWantedChecks.append(stillWanted)
        self.authorizeCalls.append((socketId, completion))
    }

    func sessionMarker(accountPeerId: Int64) -> SGTasksRealtime.SessionMarker? {
        return self.marker
    }

    func makeSocket(metadata: SGTasksRealtime.Metadata, scheduler: SGTasksRealtimeScheduler, authorize: @escaping SGTasksRealtimeSocket.Authorize, events: @escaping (SGTasksRealtimeSocket.Event) -> Void) -> SGTasksCloudRealtimeSocketHandle? {
        guard case .enabled = metadata.availability else {
            return nil
        }
        let socket = SGTasksRealtimeTestSocket(metadata: metadata, authorize: authorize, events: events)
        self.sockets.append(socket)
        return socket
    }

    var lastSocket: SGTasksRealtimeTestSocket? {
        return self.sockets.last
    }
}

let realtimeApiBase = URL(string: "https://tasks-x.example.org/v1")!
let realtimeKey = "appkey20charsxyz0123"

func realtimeEnabled(timeout: Int = 30) -> SGTasksRealtime.Metadata {
    return SGTasksRealtime.Metadata(availability: .enabled(SGTasksRealtime.Endpoint(wsURL: "wss://tasks-x.example.org/realtime/app/\(realtimeKey)", apiBaseURL: realtimeApiBase)!), activityTimeout: timeout)
}

func realtimeSubscription(_ socketId: String = "123.456", token: Character = "A") -> SGTasksRealtime.Subscription {
    return SGTasksRealtime.Subscription(socketId: SGTasksRealtime.SocketId(socketId)!, channel: "private-tasks." + String(repeating: token, count: 43), auth: realtimeKey + ":" + String(repeating: "0f", count: 32))!
}

/// One controller with every seam visible. `perform` runs at once (the owner queue is the test).
final class SGTasksRealtimeRig {
    let scheduler = SGTasksRealtimeTestScheduler()
    let service = SGTasksRealtimeTestService()
    var gateDelay: TimeInterval?
    var principal: String? = "01principal-a"
    /// What the hooks' `stillWanted` answers (the repository's traffic permission).
    var trafficPermitted = true
    var random = 1.0
    private(set) var pulls = 0
    private(set) var refusals: [SGTasksError] = []
    private(set) var statuses: [SGTasksCloudRealtimeStatus] = []
    var controller: SGTasksCloudRealtime!

    init() {
        self.controller = SGTasksCloudRealtime(
            accountPeerId: 42,
            service: self.service,
            scheduler: self.scheduler,
            random: { [unowned self] in self.random },
            hooks: SGTasksCloudRealtime.Hooks(
                perform: { block in block() },
                requestPull: { [unowned self] in self.pulls += 1 },
                gateDelay: { [unowned self] in self.gateDelay },
                currentPrincipal: { [unowned self] in self.principal },
                refused: { [unowned self] error in self.refusals.append(error) },
                statusChanged: { [unowned self] status in self.statuses.append(status) },
                stillWanted: { [unowned self] in self.trafficPermitted }
            )
        )
    }

    var conditions: SGTasksCloudRealtime.Conditions {
        return SGTasksCloudRealtime.Conditions(visible: true, foreground: true, principal: self.principal, paused: false, configured: true)
    }

    func want() {
        self.controller.update(self.conditions)
    }

    /// A retry timer fired: the new attempt asked GET /realtime; answer it and return the socket.
    func reconnect(metadata: SGTasksRealtime.Metadata = realtimeEnabled()) throws -> SGTasksRealtimeTestSocket {
        let sockets = self.service.sockets.count
        guard let completion = self.service.metadataCompletions.last else {
            throw SGTasksRealtimeTestFailure.assertion("The reconnect asked no metadata")
        }
        completion(.success(metadata))
        guard self.service.sockets.count == sockets + 1, let socket = self.service.lastSocket, socket.started == 1 else {
            throw SGTasksRealtimeTestFailure.assertion("The reconnect opened no fresh socket")
        }
        return socket
    }

    /// Wanted → metadata → socket → auth → subscribed (live).
    @discardableResult
    func goLive(metadata: SGTasksRealtime.Metadata = realtimeEnabled()) throws -> SGTasksRealtimeTestSocket {
        let metadataCalls = self.service.metadataCompletions.count
        self.want()
        if self.service.metadataCompletions.count > metadataCalls {
            self.service.metadataCompletions.last!(.success(metadata))
        }
        guard let socket = self.service.lastSocket, socket.stopped == 0 else {
            throw SGTasksRealtimeTestFailure.assertion("No socket was opened")
        }
        try realtimeCheck(socket.started == 1, "The socket was not started exactly once")
        let authorizations = self.service.authorizeCalls.count
        socket.requestAuthorization()
        try realtimeCheck(self.service.authorizeCalls.count == authorizations + 1, "The socket's authorization did not reach the service")
        self.service.authorizeCalls.last!.completion(.success(realtimeSubscription()))
        socket.events(.subscribed)
        try realtimeCheck(self.controller.status == .live, "Not live after subscription_succeeded")
        return socket
    }
}

enum SGTasksCloudRealtimeTests {
    static let cases: [(String, () async throws -> Void)] = [
        ("realtime: connects only while visible, foreground, bound, unpaused and configured", onlyWhileWanted),
        ("realtime: live only after the exact subscription; then an immediate REST repair", liveAfterSubscriptionThenRepair),
        ("realtime: every departure closes the socket, cancels timers and drops late callbacks", departuresFenceEverything),
        ("realtime: an account switch never authorizes the old attempt and reconnects under the new principal", accountSwitch),
        ("realtime: refresh rotation keeps the socket; a same-principal re-bind replaces it", rotationVersusRebind),
        ("realtime: a session change before the socket is live restarts it with fresh authorization", sessionChangeBeforeLive),
        ("realtime: hints coalesce into one REST pull per 250 ms; none before live", hintsCoalesce),
        ("realtime: bounded exponential 1...60 s reconnect with jitter, one metadata GET per attempt, never exhausted", boundedReconnect),
        ("realtime: the backoff is forgiven only after a stable activity timeout", stableResetsBackoff),
        ("realtime: the account gate holds the GET and the auth POST; a 429 feeds the gate", gateAndRateLimit),
        ("realtime: session and link refusals pause durably through the repository, no retry", pauseRefusals),
        ("realtime: Pusher close-code ranges decide reconnect, backoff or rest", closeCodeRanges),
        ("realtime: the kill switch is reported truthfully and rechecked rarely", killSwitch),
        ("realtime: a credential change during authorization retries, never pauses", credentialChangedRetries),
        ("realtime: deterministic failures rest until foreground, start or a session change", deterministicFailuresRest)
    ]

    private static func onlyWhileWanted() async throws {
        let variants: [(String, (inout SGTasksCloudRealtime.Conditions) -> Void)] = [
            ("hidden", { $0.visible = false }),
            ("background", { $0.foreground = false }),
            ("no principal", { $0.principal = nil }),
            ("paused", { $0.paused = true }),
            ("unconfigured", { $0.configured = false })
        ]
        for (name, change) in variants {
            let rig = SGTasksRealtimeRig()
            var conditions = rig.conditions
            change(&conditions)
            rig.controller.update(conditions)
            try realtimeCheck(rig.service.metadataCompletions.isEmpty && rig.service.sockets.isEmpty, "\(name): realtime asked the network")
            try realtimeCheck(rig.controller.status == .off, "\(name): status is not off")
        }
        let rig = SGTasksRealtimeRig()
        rig.want()
        rig.want()
        try realtimeCheck(rig.service.metadataCompletions.count == 1, "A repeated update started a second attempt")
        try realtimeCheck(rig.controller.status == .connecting, "Not connecting while the metadata GET runs")
    }

    private static func liveAfterSubscriptionThenRepair() async throws {
        let rig = SGTasksRealtimeRig()
        rig.want()
        rig.service.metadataCompletions[0](.success(realtimeEnabled()))
        let socket = try rig.service.lastSocket.orThrow("no socket")
        socket.requestAuthorization()
        rig.service.authorizeCalls[0].completion(.success(realtimeSubscription()))
        try realtimeCheck(socket.delivered.count == 1, "The authorization never reached the socket")
        try realtimeCheck(rig.controller.status == .connecting && rig.pulls == 0, "Live or pulling before subscription_succeeded")
        socket.events(.subscribed)
        try realtimeCheck(rig.controller.status == .live, "Not live after the subscription")
        try realtimeCheck(rig.pulls == 1, "No immediate REST repair after (re)connect")
    }

    private static func departuresFenceEverything() async throws {
        let departures: [(String, (SGTasksRealtimeRig) -> Void)] = [
            ("stop", { $0.controller.stop() }),
            ("background", { rig in var c = rig.conditions; c.foreground = false; rig.controller.update(c) }),
            ("board hidden", { rig in var c = rig.conditions; c.visible = false; rig.controller.update(c) }),
            ("logout", { rig in rig.principal = nil; var c = rig.conditions; c.principal = nil; rig.controller.update(c) }),
            ("pause", { rig in var c = rig.conditions; c.paused = true; rig.controller.update(c) })
        ]
        for (name, depart) in departures {
            let rig = SGTasksRealtimeRig()
            let socket = try rig.goLive()
            socket.events(.invalidated)
            try realtimeCheck(!rig.scheduler.pendingDelays.isEmpty, "\(name): fixture has no pending timer")
            depart(rig)
            try realtimeCheck(socket.stopped == 1, "\(name): the socket was not closed")
            try realtimeCheck(rig.scheduler.pendingDelays.isEmpty, "\(name): a timer survived")
            try realtimeCheck(rig.controller.status == .off, "\(name): status is not off")
            let pulls = rig.pulls
            let statuses = rig.statuses.count
            socket.events(.invalidated)
            socket.events(.subscribed)
            socket.events(.closed(.transport))
            rig.scheduler.advance(by: 3600)
            socket.requestAuthorization()
            try realtimeCheck(rig.pulls == pulls && rig.statuses.count == statuses, "\(name): a late socket callback acted")
            try realtimeCheck(rig.service.authorizeCalls.count == 1, "\(name): a late socket started a fresh authorization")
            try realtimeCheck(rig.service.sockets.count == 1, "\(name): something reconnected while not wanted")
        }

        // A metadata answer that lands after the departure opens nothing.
        let late = SGTasksRealtimeRig()
        late.want()
        late.controller.stop()
        late.service.metadataCompletions[0](.success(realtimeEnabled()))
        try realtimeCheck(late.service.sockets.isEmpty, "A late metadata answer opened a socket")
    }

    private static func accountSwitch() async throws {
        let rig = SGTasksRealtimeRig()
        rig.want()
        rig.service.metadataCompletions[0](.success(realtimeEnabled()))
        let old = try rig.service.lastSocket.orThrow("no socket")
        // The binding moves to another principal before the old socket's authorization starts.
        rig.principal = "01principal-b"
        old.requestAuthorization()
        try realtimeCheck(rig.service.authorizeCalls.isEmpty, "The old principal's socket started an authorization")
        try realtimeCheck(old.stopped == 1, "The old principal's socket stayed open")
        rig.want()
        try realtimeCheck(rig.service.metadataCompletions.count == 2, "The new principal reused the old principal's metadata")
        rig.service.metadataCompletions[1](.success(realtimeEnabled()))
        let fresh = try rig.service.lastSocket.orThrow("no new socket")
        try realtimeCheck(fresh !== old && fresh.started == 1, "No fresh socket under the new principal")

        // An authorization of the old attempt that answers late is never handed to any socket.
        let racing = SGTasksRealtimeRig()
        racing.want()
        racing.service.metadataCompletions[0](.success(realtimeEnabled()))
        let socket = try racing.service.lastSocket.orThrow("no socket")
        socket.requestAuthorization()
        racing.principal = "01principal-b"
        racing.controller.update(racing.conditions)
        racing.service.authorizeCalls[0].completion(.success(realtimeSubscription()))
        try realtimeCheck(socket.delivered.isEmpty, "A late authorization reached the previous principal's socket")
    }

    private static func rotationVersusRebind() async throws {
        // Refresh rotation: the marker changes, the socket only revalidates and stays live.
        let rig = SGTasksRealtimeRig()
        let socket = try rig.goLive()
        rig.service.marker = SGTasksRealtime.SessionMarker(refreshToken: "r2", accountId: "acc", deviceId: "dev")
        rig.controller.sessionChanged()
        try realtimeCheck(socket.revalidations == 1 && socket.stopped == 0, "A changed session did not revalidate the live socket in place")
        try realtimeCheck(rig.controller.status == .live, "Revalidation alone dropped the live status")
        rig.controller.sessionChanged()
        try realtimeCheck(socket.revalidations == 1, "An unchanged marker revalidated again")

        // Same-principal re-bind: the revalidation found another channel; the old generation's
        // socket is gone, never reported live again, and a new one authorizes at once.
        socket.events(.closed(.channelChanged))
        try realtimeCheck(rig.controller.status == .connecting, "The replaced generation is still reported live")
        try realtimeCheck(rig.scheduler.pendingDelays.isEmpty, "A re-bind waited for a backoff")
        try realtimeCheck(rig.service.metadataCompletions.count == 2 && rig.service.sockets.count == 1, "The re-bind did not start a new attempt with its own metadata GET (G5)")
        rig.service.metadataCompletions[1](.success(realtimeEnabled()))
        let fresh = try rig.service.lastSocket.orThrow("no new socket")
        try realtimeCheck(fresh !== socket && fresh.started == 1, "No fresh socket for the re-bound session")
        socket.events(.invalidated)
        socket.events(.subscribed)
        try realtimeCheck(rig.controller.status == .connecting && rig.pulls == 1, "The old generation's late events still counted")
        fresh.requestAuthorization()
        try realtimeCheck(rig.service.authorizeCalls.count == 2, "The new socket did not authorize afresh")
        rig.service.authorizeCalls[1].completion(.success(realtimeSubscription(token: "C")))
        fresh.events(.subscribed)
        try realtimeCheck(rig.controller.status == .live && rig.pulls == 2, "The re-bound socket did not go live with a repair pull")
    }

    private static func sessionChangeBeforeLive() async throws {
        let rig = SGTasksRealtimeRig()
        rig.want()
        rig.service.metadataCompletions[0](.success(realtimeEnabled()))
        let first = try rig.service.lastSocket.orThrow("no socket")
        first.requestAuthorization()
        rig.service.marker = SGTasksRealtime.SessionMarker(refreshToken: "r1", accountId: "acc", deviceId: "dev-rebound")
        rig.controller.sessionChanged()
        try realtimeCheck(first.stopped == 1, "A socket authorizing under the previous session was kept")
        try realtimeCheck(rig.service.metadataCompletions.count == 2 && rig.service.sockets.count == 1, "No fresh attempt (with its own metadata GET) under the current session")
        rig.service.metadataCompletions[1](.success(realtimeEnabled()))
        rig.service.authorizeCalls[0].completion(.success(realtimeSubscription()))
        try realtimeCheck(first.delivered.isEmpty, "The previous session's authorization reached a socket")
        let second = try rig.service.lastSocket.orThrow("no second socket")
        second.requestAuthorization()
        try realtimeCheck(rig.service.authorizeCalls.count == 2, "The fresh socket did not authorize under the current session")
    }

    private static func hintsCoalesce() async throws {
        let rig = SGTasksRealtimeRig()
        rig.want()
        rig.service.metadataCompletions[0](.success(realtimeEnabled()))
        let socket = try rig.service.lastSocket.orThrow("no socket")
        socket.events(.invalidated)
        rig.scheduler.advance(by: 1)
        try realtimeCheck(rig.pulls == 0, "A hint before the subscription pulled")
        socket.requestAuthorization()
        rig.service.authorizeCalls[0].completion(.success(realtimeSubscription()))
        socket.events(.subscribed)
        let afterConnect = rig.pulls
        socket.events(.invalidated)
        // Steps are exact binary fractions so the 250 ms boundary is not a floating-point accident.
        rig.scheduler.advance(by: 0.125)
        socket.events(.invalidated)
        socket.events(.invalidated)
        rig.scheduler.advance(by: 0.0625)
        try realtimeCheck(rig.pulls == afterConnect, "A hint pulled before the 250 ms window closed")
        rig.scheduler.advance(by: 0.0625)
        try realtimeCheck(rig.pulls == afterConnect + 1, "Hints within 250 ms did not coalesce into exactly one pull")
        socket.events(.invalidated)
        rig.scheduler.advance(by: 0.25)
        try realtimeCheck(rig.pulls == afterConnect + 2, "A later hint did not pull")
    }

    private static func boundedReconnect() async throws {
        let rig = SGTasksRealtimeRig()
        rig.random = 1.0
        let first = try rig.goLive()
        // The literal schedule: 1, 2, 4, ... doubling, capped at 60 and staying there.
        let schedule: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 60, 60, 60]
        var socket = first
        var gets = rig.service.metadataCompletions.count
        // Transient failures never exhaust: the delay doubles to the 60 s cap and stays there.
        for attempt in 1 ... 10 {
            socket.events(.closed(.transport))
            try realtimeCheck(rig.controller.status == .fallback, "Attempt \(attempt): not reported as fallback")
            let delays = rig.scheduler.pendingDelays
            try realtimeCheck(delays.count == 1, "Attempt \(attempt): not exactly one reconnect timer: \(delays)")
            let expected = schedule[attempt - 1]
            try realtimeCheck(abs(delays[0] - expected) < 0.0001, "Attempt \(attempt): delay \(delays[0]) is not \(expected)")
            rig.scheduler.advance(by: delays[0] - 0.5)
            try realtimeCheck(rig.service.metadataCompletions.count == gets, "Attempt \(attempt): reconnected before its delay")
            rig.scheduler.advance(by: 0.5)
            socket = try rig.reconnect()
            try realtimeCheck(rig.service.metadataCompletions.count == gets + 1, "Attempt \(attempt): a reconnect did not ask GET /realtime exactly once (G5)")
            gets = rig.service.metadataCompletions.count
        }

        // Jitter keeps every delay within [base / 2, base] and never under 1 s.
        let jittered = SGTasksRealtimeRig()
        jittered.random = 0.0
        let live = try jittered.goLive()
        live.events(.closed(.transport))
        try realtimeCheck(jittered.scheduler.pendingDelays == [1.0], "The first jittered delay went under 1 s: \(jittered.scheduler.pendingDelays)")
        jittered.scheduler.advance(by: 1)
        try jittered.reconnect().events(.closed(.transport))
        try realtimeCheck(jittered.scheduler.pendingDelays == [1.0], "The second delay is not base / 2: \(jittered.scheduler.pendingDelays)")
    }

    private static func stableResetsBackoff() async throws {
        let rig = SGTasksRealtimeRig()
        let first = try rig.goLive(metadata: realtimeEnabled(timeout: 30))
        first.events(.closed(.transport))
        rig.scheduler.advance(by: 1)
        let second = try rig.reconnect(metadata: realtimeEnabled(timeout: 30))
        second.requestAuthorization()
        rig.service.authorizeCalls.last!.completion(.success(realtimeSubscription()))
        second.events(.subscribed)
        rig.scheduler.advance(by: 29)
        second.events(.closed(.transport))
        try realtimeCheck(rig.scheduler.pendingDelays == [2.0], "A drop before a stable activity timeout forgave the backoff: \(rig.scheduler.pendingDelays)")
        rig.scheduler.advance(by: 2)
        let third = try rig.reconnect(metadata: realtimeEnabled(timeout: 30))
        third.requestAuthorization()
        rig.service.authorizeCalls.last!.completion(.success(realtimeSubscription()))
        third.events(.subscribed)
        rig.scheduler.advance(by: 30)
        third.events(.closed(.transport))
        try realtimeCheck(rig.scheduler.pendingDelays == [1.0], "A stable subscription did not reset the backoff: \(rig.scheduler.pendingDelays)")
    }

    private static func gateAndRateLimit() async throws {
        let gated = SGTasksRealtimeRig()
        gated.gateDelay = 45
        gated.want()
        try realtimeCheck(gated.service.metadataCompletions.isEmpty, "The GET was sent while the account gate was closed")
        try realtimeCheck(gated.scheduler.pendingDelays == [45] && gated.controller.status == .fallback, "The attempt did not wait for the gate")
        gated.gateDelay = nil
        gated.scheduler.advance(by: 45)
        try realtimeCheck(gated.service.metadataCompletions.count == 1, "No attempt after the gate opened")

        // The gate closes between the GET and the socket's authorization: no POST.
        let between = SGTasksRealtimeRig()
        between.want()
        between.service.metadataCompletions[0](.success(realtimeEnabled()))
        let socket = try between.service.lastSocket.orThrow("no socket")
        between.gateDelay = 20
        socket.requestAuthorization()
        try realtimeCheck(between.service.authorizeCalls.isEmpty && socket.stopped == 1, "An auth POST was sent while the gate was closed")
        try realtimeCheck(between.scheduler.pendingDelays == [20], "The attempt did not wait for the gate")

        // A 429 on either call is the account's shared budget: the repository's gate decides.
        let limited = SGTasksRealtimeRig()
        limited.want()
        // A shared Retry-After longer than the 60 s reconnect cap still wins (G5).
        let refusal = SGTasksError(kind: .rateLimited, retryAfter: 600)
        limited.gateDelay = 600
        limited.service.metadataCompletions[0](.failure(refusal))
        try realtimeCheck(limited.refusals == [refusal], "The 429 was not handed to the repository's gate")
        try realtimeCheck(limited.scheduler.pendingDelays.first.map { $0 >= 600 } == true, "Realtime retried before Retry-After: \(limited.scheduler.pendingDelays)")
        limited.scheduler.advance(by: 599)
        try realtimeCheck(limited.service.metadataCompletions.count == 1, "A GET bypassed the shared Retry-After")
    }

    private static func pauseRefusals() async throws {
        let kinds: [SGTasksError.Kind] = [.accountNotLinked, .notSignedIn, .session(.invalidToken), .session(.deviceRevoked), .notConfigured]
        for kind in kinds {
            let rig = SGTasksRealtimeRig()
            rig.want()
            rig.service.metadataCompletions[0](.success(realtimeEnabled()))
            let socket = try rig.service.lastSocket.orThrow("no socket")
            socket.requestAuthorization()
            let refusal = SGTasksError(kind: kind)
            rig.service.authorizeCalls[0].completion(.failure(refusal))
            socket.events(.closed(.authorization(refusal)))
            try realtimeCheck(rig.refusals == [refusal], "\(kind): not handed to the repository's pause rules")
            try realtimeCheck(rig.scheduler.pendingDelays.isEmpty && rig.controller.status == .off, "\(kind): realtime retried a pause-class refusal")
        }
    }

    private static func closeCodeRanges() async throws {
        let restRig = SGTasksRealtimeRig()
        try restRig.goLive().events(.closed(.server(code: 4001)))
        try realtimeCheck(restRig.scheduler.pendingDelays.isEmpty && restRig.controller.status == .fallback, "4000-4099 reconnected")

        let backoffRig = SGTasksRealtimeRig()
        try backoffRig.goLive().events(.closed(.server(code: 4100)))
        try realtimeCheck(backoffRig.scheduler.pendingDelays == [1.0], "4100-4199 did not back off")

        let quickRig = SGTasksRealtimeRig()
        quickRig.random = 0.0
        try quickRig.goLive().events(.closed(.server(code: 4200)))
        try realtimeCheck(quickRig.scheduler.pendingDelays.first.map { $0 >= 1.0 } == true, "4200-4299 reconnected in under 1 s")

        let unknownRig = SGTasksRealtimeRig()
        try unknownRig.goLive().events(.closed(.server(code: nil)))
        try realtimeCheck(unknownRig.scheduler.pendingDelays == [1.0], "A code-less server error was not a transient backoff")
    }

    private static func killSwitch() async throws {
        let rig = SGTasksRealtimeRig()
        rig.want()
        rig.service.metadataCompletions[0](.success(SGTasksRealtime.Metadata(availability: .disabled, activityTimeout: 30)))
        try realtimeCheck(rig.service.sockets.isEmpty, "A socket was opened against the kill switch")
        try realtimeCheck(rig.controller.status == .disabled, "The kill switch is not reported as disabled")
        try realtimeCheck(rig.scheduler.pendingDelays == [SGTasksCloudRealtime.disabledRecheckInterval], "The kill switch is not rechecked on its own interval")
        rig.scheduler.advance(by: SGTasksCloudRealtime.disabledRecheckInterval)
        try realtimeCheck(rig.service.metadataCompletions.count == 2, "The kill switch was never rechecked")

        let outage = SGTasksRealtimeRig()
        outage.want()
        outage.service.metadataCompletions[0](.failure(SGTasksError(kind: .unavailable, retryAfter: 120)))
        try realtimeCheck(outage.controller.status == .fallback, "An outage was reported as anything but REST fallback")
        try realtimeCheck(outage.scheduler.pendingDelays.first.map { $0 >= 120 } == true, "A 503 Retry-After was not honoured")
        try realtimeCheck(outage.refusals.isEmpty, "An outage was treated as a pause")
    }

    private static func deterministicFailuresRest() async throws {
        let failures: [(String, (SGTasksRealtimeRig) throws -> Void)] = [
            ("malformed metadata", { rig in
                rig.want()
                rig.service.metadataCompletions[0](.failure(SGTasksError(kind: .malformedResponse)))
            }),
            ("protocol violation after subscription", { rig in
                try rig.goLive().events(.closed(.protocolViolation))
            }),
            ("refused subscription", { rig in
                rig.want()
                rig.service.metadataCompletions[0](.success(realtimeEnabled()))
                try rig.service.lastSocket.orThrow("no socket").events(.closed(.subscriptionRefused))
            }),
            ("malformed auth answer", { rig in
                rig.want()
                rig.service.metadataCompletions[0](.success(realtimeEnabled()))
                let socket = try rig.service.lastSocket.orThrow("no socket")
                socket.events(.closed(.authorization(SGTasksError(kind: .malformedResponse))))
            })
        ]
        for (name, fail) in failures {
            let rig = SGTasksRealtimeRig()
            try fail(rig)
            try realtimeCheck(rig.scheduler.pendingDelays.isEmpty, "\(name): a reconnect was scheduled: \(rig.scheduler.pendingDelays)")
            try realtimeCheck(rig.controller.status == .fallback, "\(name): not reported as REST fallback")
            let gets = rig.service.metadataCompletions.count
            let sockets = rig.service.sockets.count
            rig.scheduler.advance(by: 24 * 3600)
            try realtimeCheck(rig.service.metadataCompletions.count == gets && rig.service.sockets.count == sockets, "\(name): a resting controller spent the reads budget")
            try realtimeCheck(rig.refusals.isEmpty, "\(name): a deterministic failure paused the account")

            // A session change ends the rest with exactly one fresh attempt.
            rig.service.marker = SGTasksRealtime.SessionMarker(refreshToken: "r9", accountId: "acc", deviceId: "dev")
            rig.controller.sessionChanged()
            try realtimeCheck(rig.service.metadataCompletions.count == gets + 1, "\(name): a session change did not end the rest")
        }

        // So does the next foreground.
        let foreground = SGTasksRealtimeRig()
        foreground.want()
        foreground.service.metadataCompletions[0](.failure(SGTasksError(kind: .malformedResponse)))
        var background = foreground.conditions
        background.foreground = false
        foreground.controller.update(background)
        foreground.want()
        try realtimeCheck(foreground.service.metadataCompletions.count == 2, "Foreground did not end the rest with one fresh attempt")
    }

    private static func credentialChangedRetries() async throws {
        let rig = SGTasksRealtimeRig()
        rig.want()
        rig.service.metadataCompletions[0](.success(realtimeEnabled()))
        let socket = try rig.service.lastSocket.orThrow("no socket")
        socket.requestAuthorization()
        let changed = SGTasksError(kind: .credentialChanged)
        rig.service.authorizeCalls[0].completion(.failure(changed))
        socket.events(.closed(.authorization(changed)))
        try realtimeCheck(rig.refusals.isEmpty, "A credential change paused the account")
        try realtimeCheck(rig.scheduler.pendingDelays.count == 1 && rig.controller.status == .fallback, "A credential change did not schedule a fresh attempt")
    }
}

extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else {
            throw SGTasksRealtimeTestFailure.assertion(message)
        }
        return value
    }
}
