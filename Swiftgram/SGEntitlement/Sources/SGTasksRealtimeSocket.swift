import Foundation

// MARK: - Zenlygram Tasks realtime: one Pusher protocol 7 connection
//
// A connection lives exactly once: open → `pusher:connection_established` (socket id) → a FRESH
// signed REST authorization for that socket id → `pusher:subscribe` with the exact returned
// channel/auth → `pusher_internal:subscription_succeeded` on that channel (only now "subscribed")
// → content-free `tasks.changed` hints. Any failure ends it with one terminal `closed` event; the
// owner decides about reconnecting (a new instance, a new socket id, a new authorization).
//
// Every input — WebSocket callbacks, timers, the authorization result — is checked against the
// connection's phase under its lock: once `stop()` or the terminal close has run, a LATER input
// sends, schedules and reports nothing, and an authorization for an older socket id or an older
// revalidation is dropped. Call-outs (send, authorize, events) happen outside the lock and re-check
// the phase just before, which is check-then-call, not atomic: one call-out that already passed its
// check can still run concurrently with a `stop()` on another thread. The owner's own serial-queue
// attempt fence (`SGTasksCloudRealtime`) is what guarantees nothing of a stopped attempt is acted
// on. Nothing here logs, persists, or feeds the entitlement clock.

public protocol SGTasksRealtimeCancellable: AnyObject {
    func cancel()
}

/// The timer seam. Production runs blocks on a dispatch queue; tests advance a manual clock.
public protocol SGTasksRealtimeScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SGTasksRealtimeCancellable
}

public final class SGTasksRealtimeDispatchScheduler: SGTasksRealtimeScheduler {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    private final class Work: SGTasksRealtimeCancellable {
        let item: DispatchWorkItem

        init(_ item: DispatchWorkItem) {
            self.item = item
        }

        func cancel() {
            self.item.cancel()
        }
    }

    public func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SGTasksRealtimeCancellable {
        let item = DispatchWorkItem(block: action)
        self.queue.asyncAfter(deadline: .now() + max(delay, 0), execute: item)
        return Work(item)
    }
}

/// The raw WebSocket seam (internal: production is `SGTasksRealtimeURLSessionWebSocket`).
enum SGTasksRealtimeWebSocketEvent: Equatable {
    case opened
    case text(String)
    case binary
    /// The peer closed; `code` is the WebSocket close code.
    case closed(code: Int?)
    case failed
}

protocol SGTasksRealtimeWebSocket: AnyObject {
    func open(_ request: URLRequest, events: @escaping (SGTasksRealtimeWebSocketEvent) -> Void)
    func send(_ text: String)
    func close()
}

public final class SGTasksRealtimeSocket {
    public enum CloseReason: Equatable {
        /// Lost transport, refused handshake or an unanswered connect.
        case transport
        /// No frame within the dead-connection deadline (≤ 2 × activity timeout).
        case heartbeatTimeout
        /// A frame broke the protocol (size, shape, wrong channel/key, binary).
        case protocolViolation
        /// The REST authorization refused (session, link, rate limit, outage, credential change).
        case authorization(SGTasksError)
        /// `pusher:subscription_error`.
        case subscriptionRefused
        /// A Pusher close / error code (4000–4299 ranges decide the reconnect policy).
        case server(code: Int?)
        /// A revalidation returned another channel: the server rotated this binding's generation
        /// (re-bind). Reconnect immediately with a fresh authorization.
        case channelChanged
    }

    public enum Event: Equatable {
        /// `subscription_succeeded` on the exact channel.
        case subscribed
        /// A content-free `tasks.changed` on the subscribed channel.
        case invalidated
        /// Terminal. Never emitted for `stop()`.
        case closed(CloseReason)
    }

    public typealias Authorize = (SGTasksRealtime.SocketId, @escaping (Result<SGTasksRealtime.Subscription, SGTasksError>) -> Void) -> Void

    /// Connect: open → first frame. Bounded by the socket's own timer, not by URLSession.
    static let connectTimeout: TimeInterval = 10.0
    /// URLSession's per-request (idle) timeout on the WebSocket task. It must exceed the heartbeat's
    /// own dead deadline (≤ 2 × 120 s) so an idle but healthy socket is never dropped by it.
    static let sessionIdleTimeout: TimeInterval = 2.0 * 120.0 + 30.0

    private enum Phase {
        case idle
        case opening
        case awaitingEstablished
        case authorizing(SGTasksRealtime.SocketId)
        case subscribing(SGTasksRealtime.Subscription)
        case subscribed(SGTasksRealtime.Subscription)
        case finished
    }

    private let endpoint: SGTasksRealtime.Endpoint
    private let scheduler: SGTasksRealtimeScheduler
    private let webSocket: SGTasksRealtimeWebSocket
    private let authorize: Authorize
    private let events: (Event) -> Void

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var activityTimeout: Int
    private var idleTimer: SGTasksRealtimeCancellable?
    private var deadTimer: SGTasksRealtimeCancellable?
    private var connectTimer: SGTasksRealtimeCancellable?
    /// Bumped by every revalidation; an older answer is dropped.
    private var revalidation: UInt64 = 0
    private var isRevalidating = false
    /// A revalidation asked for while it could not run yet (first authorization / subscribe in
    /// flight, or another revalidation running): runs as soon as it can, never dropped.
    private var pendingRevalidation = false

    /// nil unless the metadata is the enabled kind (its endpoint and activity timeout were
    /// validated by the strict decoder).
    public convenience init?(metadata: SGTasksRealtime.Metadata, scheduler: SGTasksRealtimeScheduler, authorize: @escaping Authorize, events: @escaping (Event) -> Void) {
        self.init(metadata: metadata, scheduler: scheduler, webSocket: SGTasksRealtimeURLSessionWebSocket(), authorize: authorize, events: events)
    }

    init?(metadata: SGTasksRealtime.Metadata, scheduler: SGTasksRealtimeScheduler, webSocket: SGTasksRealtimeWebSocket, authorize: @escaping Authorize, events: @escaping (Event) -> Void) {
        guard case let .enabled(endpoint) = metadata.availability, SGTasksRealtime.activityTimeoutRange.contains(metadata.activityTimeout) else {
            return nil
        }
        self.endpoint = endpoint
        self.activityTimeout = metadata.activityTimeout
        self.scheduler = scheduler
        self.webSocket = webSocket
        self.authorize = authorize
        self.events = events
    }

    /// The handshake request: the rebuilt URL and the canonical Origin, nothing else — no
    /// credential, cookie or token.
    var handshakeRequest: URLRequest {
        var request = URLRequest(url: self.endpoint.url)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = SGTasksRealtimeSocket.sessionIdleTimeout
        request.setValue(self.endpoint.origin, forHTTPHeaderField: "Origin")
        return request
    }

    public func start() {
        self.lock.lock()
        guard case .idle = self.phase else {
            self.lock.unlock()
            return
        }
        self.phase = .opening
        self.connectTimer = self.scheduler.schedule(after: SGTasksRealtimeSocket.connectTimeout) { [weak self] in
            self?.connectTimedOut()
        }
        self.lock.unlock()
        self.webSocket.open(self.handshakeRequest) { [weak self] event in
            self?.handle(event)
        }
    }

    deinit {
        // Dropped without `stop()`: the URLSession retains its delegate, so the connection would
        // otherwise stay open and subscribed.
        self.stop()
    }

    /// Ends the connection silently: timers cancelled, socket closed, no event; inputs that arrive
    /// after this returns are ignored (see the header for the check-then-call window).
    public func stop() {
        self.lock.lock()
        let wasActive = self.finishLocked()
        self.lock.unlock()
        if wasActive {
            self.webSocket.close()
        }
    }

    /// The local session changed without a principal change (rotation or same-account re-bind):
    /// ask for a fresh authorization of THIS socket id. The same channel means a rotation (keep);
    /// another channel means the server generation changed (`closed(.channelChanged)`).
    ///
    /// Never dropped: while the first authorization or the subscribe is in flight (it may predate
    /// the change), or another revalidation is running, the request is remembered and runs as soon
    /// as the socket is subscribed / that revalidation confirmed the channel.
    public func revalidate() {
        self.lock.lock()
        switch self.phase {
        case let .subscribed(subscription):
            guard !self.isRevalidating else {
                self.pendingRevalidation = true
                self.lock.unlock()
                return
            }
            self.pendingRevalidation = false
            self.isRevalidating = true
            self.revalidation &+= 1
            let token = self.revalidation
            self.lock.unlock()
            self.authorize(subscription.socketId) { [weak self] result in
                self?.revalidated(result, socketId: subscription.socketId, token: token)
            }
        case .authorizing, .subscribing:
            self.pendingRevalidation = true
            self.lock.unlock()
        case .idle, .opening, .awaitingEstablished, .finished:
            // Not authorized yet (the coming authorization reads the current session) or over.
            self.lock.unlock()
        }
    }

    /// Re-checked just before every call-out made after the lock was released, so a `stop()` that
    /// landed in between suppresses it. (The owner still fences its own attempt: a call-out already
    /// past this check can race a concurrent stop.)
    private func isStill(_ matches: (Phase) -> Bool) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return matches(self.phase)
    }

    private static func isLive(_ phase: Phase) -> Bool {
        if case .finished = phase {
            return false
        }
        return true
    }

    // MARK: Inputs

    private func handle(_ event: SGTasksRealtimeWebSocketEvent) {
        switch event {
        case .opened:
            self.lock.lock()
            if case .opening = self.phase {
                self.phase = .awaitingEstablished
            }
            self.lock.unlock()
        case let .text(text):
            self.receive(text)
        case .binary:
            self.fail(.protocolViolation)
        case let .closed(code):
            if let code = code, (4000 ... 4299).contains(code) {
                self.fail(.server(code: code))
            } else {
                self.fail(.transport)
            }
        case .failed:
            self.fail(.transport)
        }
    }

    private func receive(_ text: String) {
        let frame: SGTasksRealtime.Frame
        do {
            frame = try SGTasksRealtime.parseFrame(text)
        } catch {
            self.fail(.protocolViolation)
            return
        }
        self.lock.lock()
        if case .finished = self.phase {
            self.lock.unlock()
            return
        }
        self.noteActivityLocked()
        var revalidateAfter = false
        var send: String?
        var emit: Event?
        var authorizeSocket: SGTasksRealtime.SocketId?
        var failure: CloseReason?
        switch (frame, self.phase) {
        case let (.connectionEstablished(socketId, frameTimeout), .awaitingEstablished), let (.connectionEstablished(socketId, frameTimeout), .opening):
            self.connectTimer?.cancel()
            self.connectTimer = nil
            // G3: the connection's own validated activity_timeout governs this connection.
            self.activityTimeout = frameTimeout
            self.phase = .authorizing(socketId)
            self.noteActivityLocked()
            authorizeSocket = socketId
        case (.connectionEstablished, _):
            failure = .protocolViolation
        case (.ping, _):
            send = SGTasksRealtime.pongFrame
        case (.pong, _):
            break
        case let (.subscriptionSucceeded(channel), .subscribing(subscription)):
            if channel == subscription.channel {
                self.phase = .subscribed(subscription)
                emit = .subscribed
                revalidateAfter = self.pendingRevalidation
            } else {
                failure = .protocolViolation
            }
        case (.subscriptionSucceeded, _):
            break
        case let (.subscriptionError(channel), .subscribing(subscription)):
            if channel == nil || channel == subscription.channel {
                failure = .subscriptionRefused
            }
        case (.subscriptionError, _):
            break
        case let (.error(code), _):
            failure = .server(code: code)
        case let (.changed(channel), .subscribed(subscription)):
            if channel == subscription.channel {
                emit = .invalidated
            }
        case (.changed, _), (.other, _):
            break
        }
        self.lock.unlock()
        if let failure = failure {
            self.fail(failure)
            return
        }
        if let send = send, self.isStill(SGTasksRealtimeSocket.isLive) {
            self.webSocket.send(send)
        }
        if let socketId = authorizeSocket {
            guard self.isStill({ phase in
                if case let .authorizing(current) = phase {
                    return current == socketId
                }
                return false
            }) else {
                return
            }
            self.authorize(socketId) { [weak self] result in
                self?.authorized(result, socketId: socketId)
            }
        }
        if let emit = emit, self.isStill(SGTasksRealtimeSocket.isLive) {
            self.events(emit)
        }
        if revalidateAfter {
            self.revalidate()
        }
    }

    private func authorized(_ result: Result<SGTasksRealtime.Subscription, SGTasksError>, socketId: SGTasksRealtime.SocketId) {
        self.lock.lock()
        guard case let .authorizing(current) = self.phase, current == socketId else {
            // Stopped, failed, or an answer for another socket: never subscribe with it.
            self.lock.unlock()
            return
        }
        switch result {
        case let .failure(error):
            self.lock.unlock()
            self.fail(.authorization(error))
        case let .success(subscription):
            guard subscription.socketId == socketId, subscription.appKey == self.endpoint.appKey, SGTasksRealtime.isValidChannel(subscription.channel), SGTasksRealtime.isValidAuth(subscription.auth, appKey: self.endpoint.appKey) else {
                self.lock.unlock()
                self.fail(.protocolViolation)
                return
            }
            self.phase = .subscribing(subscription)
            self.lock.unlock()
            if self.isStill(SGTasksRealtimeSocket.isLive) {
                self.webSocket.send(SGTasksRealtime.subscribeFrame(subscription))
            }
        }
    }

    private func revalidated(_ result: Result<SGTasksRealtime.Subscription, SGTasksError>, socketId: SGTasksRealtime.SocketId, token: UInt64) {
        self.lock.lock()
        guard token == self.revalidation, case let .subscribed(current) = self.phase, current.socketId == socketId else {
            self.lock.unlock()
            return
        }
        self.isRevalidating = false
        switch result {
        case let .failure(error):
            self.lock.unlock()
            self.fail(.authorization(error))
        case let .success(subscription):
            let sameGeneration = subscription.socketId == socketId && subscription.appKey == self.endpoint.appKey && subscription.channel == current.channel
            let again = self.pendingRevalidation
            self.lock.unlock()
            if !sameGeneration {
                self.fail(.channelChanged)
            } else if again {
                // The session changed again while this one ran: confirm the newest session too.
                self.revalidate()
            }
        }
    }

    // MARK: Heartbeat

    /// Under `lock`. Any frame proves the connection: after `activityTimeout` of silence send a
    /// ping, and close if nothing arrives within another `activityTimeout` (dead ≤ 2 ×).
    private func noteActivityLocked() {
        self.idleTimer?.cancel()
        self.deadTimer?.cancel()
        self.deadTimer = nil
        guard self.isEstablishedLocked else {
            self.idleTimer = nil
            return
        }
        let timeout = TimeInterval(self.activityTimeout)
        self.idleTimer = self.scheduler.schedule(after: timeout) { [weak self] in
            self?.idleElapsed()
        }
    }

    private var isEstablishedLocked: Bool {
        switch self.phase {
        case .authorizing, .subscribing, .subscribed:
            return true
        case .idle, .opening, .awaitingEstablished, .finished:
            return false
        }
    }

    private func idleElapsed() {
        self.lock.lock()
        guard self.isEstablishedLocked else {
            self.lock.unlock()
            return
        }
        self.idleTimer = nil
        self.deadTimer?.cancel()
        self.deadTimer = self.scheduler.schedule(after: TimeInterval(self.activityTimeout)) { [weak self] in
            self?.fail(.heartbeatTimeout)
        }
        self.lock.unlock()
        self.webSocket.send(SGTasksRealtime.pingFrame)
    }

    private func connectTimedOut() {
        self.lock.lock()
        let pending: Bool
        switch self.phase {
        case .opening, .awaitingEstablished:
            pending = true
        default:
            pending = false
        }
        self.lock.unlock()
        if pending {
            self.fail(.transport)
        }
    }

    // MARK: Termination

    /// Under `lock`. Cancels every timer; true when this call ended an active connection.
    private func finishLocked() -> Bool {
        if case .finished = self.phase {
            return false
        }
        let wasIdle: Bool
        if case .idle = self.phase {
            wasIdle = true
        } else {
            wasIdle = false
        }
        self.phase = .finished
        self.idleTimer?.cancel()
        self.idleTimer = nil
        self.deadTimer?.cancel()
        self.deadTimer = nil
        self.connectTimer?.cancel()
        self.connectTimer = nil
        self.revalidation &+= 1
        return !wasIdle
    }

    private func fail(_ reason: CloseReason) {
        self.lock.lock()
        let wasActive = self.finishLocked()
        self.lock.unlock()
        guard wasActive else {
            return
        }
        self.webSocket.close()
        self.events(.closed(reason))
    }
}

// MARK: - Production WebSocket

/// `URLSessionWebSocketTask` on its own ephemeral session: no cookies, cache, credential storage or
/// additional headers; redirects refused; no authentication-challenge handling of its own (default
/// TLS / ATS only); a bounded message size; the opened connection must be the exact URL built from
/// the origin with HTTP 101. Closing cancels the task and invalidates the session (which retains its
/// delegate) so no callback outlives it.
final class SGTasksRealtimeURLSessionWebSocket: NSObject, SGTasksRealtimeWebSocket, URLSessionWebSocketDelegate {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var expectedURL: URL?
    private var events: ((SGTasksRealtimeWebSocketEvent) -> Void)?

    func open(_ request: URLRequest, events: @escaping (SGTasksRealtimeWebSocketEvent) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = SGTasksRealtimeSocket.sessionIdleTimeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = SGTasksRealtime.maximumFrameBytes
        self.lock.lock()
        self.session = session
        self.task = task
        self.expectedURL = request.url
        self.events = events
        self.lock.unlock()
        task.resume()
    }

    func send(_ text: String) {
        self.lock.lock()
        let task = self.task
        self.lock.unlock()
        task?.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.emit(.failed)
            }
        }
    }

    func close() {
        self.lock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        self.events = nil
        self.lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func emit(_ event: SGTasksRealtimeWebSocketEvent) {
        self.lock.lock()
        let events = self.events
        self.lock.unlock()
        events?(event)
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else {
                return
            }
            switch result {
            case let .success(.string(text)):
                self.emit(.text(text))
                self.receiveNext(task)
            case .success:
                self.emit(.binary)
            case .failure:
                self.emitTermination(task)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        self.emit(.failed)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        self.lock.lock()
        let expected = self.expectedURL
        self.lock.unlock()
        guard let response = webSocketTask.response as? HTTPURLResponse, response.statusCode == 101, let current = webSocketTask.currentRequest?.url, current == expected else {
            self.emit(.failed)
            return
        }
        self.emit(.opened)
        self.receiveNext(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.emit(.closed(code: closeCode.rawValue))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let webSocketTask = task as? URLSessionWebSocketTask {
            self.emitTermination(webSocketTask)
        } else {
            self.emit(.failed)
        }
    }

    /// A receive failure often arrives before `didCloseWith`: keep the peer's close code when the
    /// task has one (the 4000-range reconnect policy depends on it). Whether `CloseCode` keeps an
    /// application 4xxx raw value is a native-runtime question, not proven here.
    private func emitTermination(_ task: URLSessionWebSocketTask) {
        let code = task.closeCode
        if code != .invalid {
            self.emit(.closed(code: code.rawValue))
        } else {
            self.emit(.failed)
        }
    }
}
