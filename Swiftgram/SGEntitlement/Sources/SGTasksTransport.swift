import Foundation

/// Zenlygram — the Tasks routes (`/v1/tasks/mutations`, `/mutations/batch`, `/snapshot`,
/// `/changes`, `/realtime`, `/realtime/auth`) over the existing DeviceAuth identity, on wire R4.
/// Internal: the public surface is the named facade on `SGEntitlement` (`SGEntitlementTasks.swift`);
/// there is no path, header or signer parameter.
///
/// Per call (`x-authentication.native_rotation`):
/// 1. The account's stored refresh token is captured, then the account's gate — the one rotation
///    holds (`SGEntitlementAccountGate`) — is awaited. A call whose token changed while it waited is
///    abandoned (`credentialChanged`); nothing is sent.
/// 2. Immediately before EACH network attempt the call must not be cancelled, the caller's
///    `stillWanted` (when given) must still hold, and the token is re-read and must still be the
///    captured one; DeviceAuth headers (fresh nonce, transmit timestamp, signature) and, for a
///    create, the sponsor proof are produced for that attempt only. A call no longer wanted ends
///    exactly like one cancelled before sending (`.transport(.cancelled)`, nothing sent).
/// 3. The request goes out with exactly `Authorization: Bearer`, `X-Device-Id/Nonce/Ts/Sig`,
///    `Accept`, `X-Tasks-Wire` = the build's request wire (`Environment.requestWire`: 4, or 5 for a
///    build made for a wire-5 backend), and for a mutation `Content-Type` plus `Idempotency-Key` = the
///    mutation id (the batch id for a batch) — no app/OS version, no `X-Refresh-Token`, no query or
///    body credential. The idle timeout is the client's existing 5 s (whole exchange 10 s); the
///    batch call alone has 10 s idle / 20 s whole, because the server's window starts only after
///    the whole body has arrived. No redirect is followed, the body is bounded while it arrives,
///    and cancelling the caller cancels the request at once.
/// 4. At most ONE retry, and only the existing ones for an HTTP 401: `clock_skew` re-signs with the
///    server time, `nonce_replayed` / bare 401 rebuilds the credential set.
/// 5. Whatever the answer, if the stored token is no longer the captured one the call ends as
///    `credentialChanged` (keeping `outcomeUnknown`): nothing of the old session is applied or
///    reported. Otherwise an HTTP 401 of the DeviceAuth family — of the envelope, or of a batch item
///    (`x-error-codes.batch_items`) — is handed to `applySessionFailure` for the exact captured
///    credential, with its body `reason`; every other status, Tasks refusals and
///    `tasks_account_not_linked` included, changes no session state. Only HTTP 200 is success; any
///    other 2xx and any 5xx may have committed a mutation.
/// 6. The answer's `X-Tasks-Wire` echo is recorded in every typed REST result (`serverWire`, nil
///    when absent).
///
/// Nothing here logs. Request bodies, tokens, proofs and response content never leave this type
/// except as the typed result.
struct SGTasksTransport {
    /// `POST` answers are one receipt or one error.
    static let mutationResponseLimit = 65536
    /// A batch answer: at most 100 receipts or item errors, no content.
    static let batchResponseLimit = 262144
    /// The batch call's idle timeout (whole exchange twice it, `SGTasksBoundedExchange`).
    static let batchIdleTimeout: TimeInterval = 10
    /// `x-wire-negotiation`: sent once on every Tasks request with the build's request wire
    /// (`Environment.requestWire`); an R4/R5 server echoes the request's value.
    static let wireHeader = "X-Tasks-Wire"
    /// A page is at most 100 projections. No assumption is made about how the server escapes
    /// Unicode: a legal task row's text is ≤ 28 KiB of UTF-8 (title 8192 + description 16384 +
    /// annotation 4096 bytes), and `\uXXXX` escaping can grow each UTF-8 byte up to six-fold, so a
    /// legal page stays under ~17 MiB plus framing. 32 MiB bounds it with margin; anything past it is
    /// refused while it streams in.
    static let readResponseLimit = 32 << 20

    struct HTTPAnswer: Equatable {
        let status: Int
        let body: Data
        let retryAfter: Int?
        /// The `X-Tasks-Wire` response header as a number; nil when absent or not one.
        let serverWire: Int?

        init(status: Int, body: Data, retryAfter: Int?, serverWire: Int? = nil) {
            self.status = status
            self.body = body
            self.retryAfter = retryAfter
            self.serverWire = serverWire
        }
    }

    /// `timeout` is the attempt's idle bound (`Call.idleTimeout`).
    typealias Fetch = (_ request: URLRequest, _ timeout: TimeInterval, _ limit: Int) async -> Result<HTTPAnswer, SGEntitlementFailureClass>

    struct Environment {
        let baseURL: URL
        let timeout: TimeInterval
        let gate: SGEntitlementAccountGate
        /// The account's stored refresh token right now (nil: no session).
        let storedRefreshToken: (Int64) -> String?
        /// A fresh DeviceAuth credential set for one attempt (`SGEntitlementDeviceIdentity`).
        let deviceCredentials: () -> SGEntitlementDeviceCredentials?
        /// Every `server_time` read from a body feeds the clock high-water mark.
        let noteServerTime: (Date) -> Void
        /// `clock_skew`: adopt the server's offset before the single re-signed retry.
        let adoptServerOffset: (Date) -> Void
        /// The sponsor JWS for a create by this owner, chosen now (`SGTasksCreationProof`).
        let creationProof: (Int64) -> String?
        /// `SGEntitlement.apply` for the exact captured credential.
        let applySessionFailure: (SGEntitlementRequestError, SGEntitlementSessionCredential) -> Void
        let fetch: Fetch
        /// The `X-Tasks-Wire` value of every request: the build's `SGTasksShippedWire.requestWire`
        /// (`sg_config.tasks_wire` clamped to 4 ... 5, wf15 §8.2) unless a test scripts it. Declared
        /// last so the memberwise initialiser keeps it optional for the facade and the tests.
        var requestWire: Int = SGTasksShippedWire.requestWire
    }

    enum Call {
        case mutation(SGTasksWire.SealedMutation)
        /// `POST /v1/tasks/mutations/batch` (R4).
        case mutationBatch(SGTasksWire.MutationBatchRequest)
        case snapshot(cursor: SGTasksWire.Cursor?, limit: Int?)
        case changes(cursor: SGTasksWire.Cursor, limit: Int?)
        /// `GET /v1/tasks/realtime`: empty query and body (reads budget, no receipt).
        case realtimeMetadata
        /// `POST /v1/tasks/realtime/auth`: exactly `{"socket_id":...}`, empty query.
        case realtimeAuth(SGTasksRealtime.SocketId)

        var isMutation: Bool {
            switch self {
            case .mutation, .mutationBatch:
                return true
            case .snapshot, .changes, .realtimeMetadata, .realtimeAuth:
                return false
            }
        }

        var limit: Int? {
            switch self {
            case .mutation, .mutationBatch, .realtimeMetadata, .realtimeAuth:
                return nil
            case let .snapshot(_, limit), let .changes(_, limit):
                return limit
            }
        }

        var responseLimit: Int {
            switch self {
            case .mutation:
                return SGTasksTransport.mutationResponseLimit
            case .mutationBatch:
                return SGTasksTransport.batchResponseLimit
            case .snapshot, .changes:
                return SGTasksTransport.readResponseLimit
            case .realtimeMetadata, .realtimeAuth:
                return SGTasksRealtime.responseLimit
            }
        }

        /// The batch call alone waits longer; every other call keeps the client's `standard`.
        func idleTimeout(_ standard: TimeInterval) -> TimeInterval {
            if case .mutationBatch = self {
                return SGTasksTransport.batchIdleTimeout
            }
            return standard
        }
    }

    let environment: Environment

    // MARK: - Calls
    //
    // `stillWanted` on every call: the caller's own condition for sending at all (nil: none), asked
    // once the account's gate is held and before each attempt (step 2).

    func mutate(_ request: SGTasksWire.MutationRequest, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.MutationResponse, SGTasksError> {
        return await self.mutate(.mutation(request), accountPeerId: accountPeerId, stillWanted: stillWanted)
    }

    /// The single route with any sealed mutation (`task.patch` included). The receipt is checked to
    /// answer THIS mutation.
    func mutate(_ request: SGTasksWire.SealedMutation, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.MutationResponse, SGTasksError> {
        return await self.exchange(.mutation(request), accountPeerId: accountPeerId, stillWanted: stillWanted, decode: { value, serverWire in
            let response = try SGTasksWireCodec.decodeMutationResponse(value, serverWire: serverWire)
            guard SGTasksWireCodec.receipt(response.receipt, answers: request) else {
                throw SGTasksWire.ValidationError(path: "response.receipt")
            }
            return response
        })
    }

    /// `POST /v1/tasks/mutations/batch`. Every result is checked against its own item; an item 401
    /// of the DeviceAuth family reaches the session machinery exactly like an envelope 401, once
    /// the answer is delivered.
    func mutateBatch(_ request: SGTasksWire.MutationBatchRequest, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.MutationBatchResponse, SGTasksError> {
        let applySessionFailure = self.environment.applySessionFailure
        let decoded = await self.exchange(.mutationBatch(request), accountPeerId: accountPeerId, stillWanted: stillWanted, decode: { value, serverWire in
            return try SGTasksWireCodec.decodeBatchResponse(value, request: request, serverWire: serverWire)
        }, settle: { decoded, credential in
            // Every 401 item of one batch speaks of the same binding; `apply` acts once.
            if let failure = decoded.sessionFailures.first {
                applySessionFailure(failure, credential)
            }
        })
        return decoded.map { $0.response }
    }

    func snapshot(cursor: SGTasksWire.Cursor?, limit: Int?, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.SnapshotResponse, SGTasksError> {
        let effective = limit ?? SGTasksWire.defaultPageLimit
        return await self.exchange(.snapshot(cursor: cursor, limit: limit), accountPeerId: accountPeerId, stillWanted: stillWanted, decode: { value, serverWire in
            return try SGTasksWireCodec.decodeSnapshotResponse(value, limit: effective, serverWire: serverWire)
        })
    }

    func changes(cursor: SGTasksWire.Cursor, limit: Int?, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksWire.ChangesResponse, SGTasksError> {
        let effective = limit ?? SGTasksWire.defaultPageLimit
        return await self.exchange(.changes(cursor: cursor, limit: limit), accountPeerId: accountPeerId, stillWanted: stillWanted, decode: { value, serverWire in
            return try SGTasksWireCodec.decodeChangesResponse(value, limit: effective, serverWire: serverWire)
        })
    }

    /// `GET /v1/tasks/realtime`. `enabled` answers carry an endpoint already validated against
    /// this client's own API origin; an endpoint that is not exactly that origin's is malformed.
    func realtimeMetadata(accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksRealtime.Metadata, SGTasksError> {
        let baseURL = self.environment.baseURL
        return await self.exchange(.realtimeMetadata, accountPeerId: accountPeerId, stillWanted: stillWanted, decode: { value, _ in
            return try SGTasksRealtime.decodeMetadata(value, apiBaseURL: baseURL)
        })
    }

    /// `POST /v1/tasks/realtime/auth` for exactly one socket id. The answer is bound to it.
    func realtimeAuth(socketId: SGTasksRealtime.SocketId, accountPeerId: Int64, stillWanted: (() -> Bool)? = nil) async -> Result<SGTasksRealtime.Subscription, SGTasksError> {
        return await self.exchange(.realtimeAuth(socketId), accountPeerId: accountPeerId, stillWanted: stillWanted, decode: { value, _ in
            return try SGTasksRealtime.decodeSubscription(value, socketId: socketId)
        })
    }

    /// The receipt is for THIS mutation (`SGTasksWireCodec.receipt(_:answers:)`).
    static func receipt(_ receipt: SGTasksWire.Receipt, answers request: SGTasksWire.MutationRequest) -> Bool {
        return SGTasksWireCodec.receipt(receipt, answers: .mutation(request))
    }

    // MARK: - Exchange

    /// `decode` gets the parsed 200 body and the answer's `X-Tasks-Wire`; `settle` runs once the
    /// decoded answer is known to be this session's, right before it is delivered.
    private func exchange<T>(_ call: Call, accountPeerId: Int64, stillWanted: (() -> Bool)?, decode: (SGTasksJSON.Value, Int?) throws -> T, settle: (T, SGEntitlementSessionCredential) -> Void = { _, _ in }) async -> Result<T, SGTasksError> {
        if let limit = call.limit, !(1 ... SGTasksWire.maxPageLimit).contains(limit) {
            return .failure(SGTasksError(kind: .invalidLocalRequest))
        }
        guard !Task.isCancelled else {
            return .failure(SGTasksError(kind: .transport(.cancelled)))
        }
        guard let captured = self.environment.storedRefreshToken(accountPeerId), !captured.isEmpty else {
            return .failure(SGTasksError(kind: .notSignedIn))
        }
        let gate = self.environment.gate
        await gate.acquire(accountPeerId: accountPeerId)
        defer {
            gate.release(accountPeerId: accountPeerId)
        }
        return await self.attempts(call, accountPeerId: accountPeerId, captured: captured, stillWanted: stillWanted, decode: decode, settle: settle)
    }

    private func attempts<T>(_ call: Call, accountPeerId: Int64, captured: String, stillWanted: (() -> Bool)?, decode: (SGTasksJSON.Value, Int?) throws -> T, settle: (T, SGEntitlementSessionCredential) -> Void) async -> Result<T, SGTasksError> {
        let credential = SGEntitlementSessionCredential(accountPeerId: accountPeerId, refreshToken: captured)
        let isMutation = call.isMutation
        let isCurrent = {
            return self.environment.storedRefreshToken(accountPeerId) == captured
        }
        var attempt = 0
        while true {
            attempt += 1
            // Checked after the gate was acquired and before every attempt: a cancelled call sends
            // nothing more. Any earlier attempt of this call ended in a DeviceAuth refusal, which
            // the server answers before business processing, so nothing can have committed.
            guard !Task.isCancelled else {
                return .failure(SGTasksError(kind: .transport(.cancelled)))
            }
            // The caller's own condition (its current consent permission), asked now that the
            // call's turn came: a call that waited behind a rotation or another call of the account
            // and is no longer wanted ends like one cancelled while queued — nothing signed, no
            // proof chosen, nothing sent. Never the task's cancellation (it aborts a request on the
            // wire); `SGTasksError.Kind` stays the closed R3 set.
            if let stillWanted, !stillWanted() {
                return .failure(SGTasksError(kind: .transport(.cancelled)))
            }
            guard isCurrent() else {
                return .failure(SGTasksError(kind: .credentialChanged))
            }
            guard let device = self.environment.deviceCredentials() else {
                // The key could not sign: nothing was sent.
                return .failure(SGTasksError(kind: .transport(.unknown)))
            }
            guard let request = self.makeRequest(call, refreshToken: captured, device: device, accountPeerId: accountPeerId) else {
                return .failure(SGTasksError(kind: .invalidLocalRequest))
            }
            let limit = call.responseLimit
            let answer: HTTPAnswer
            switch await self.environment.fetch(request, call.idleTimeout(self.environment.timeout), limit) {
            case let .failure(failure):
                let error = SGTasksErrorClassifier.transport(failure, isMutation: isMutation)
                // A session that changed while the request was out is reported as such, whatever
                // became of the request; the possible commit is carried over.
                guard isCurrent() else {
                    return .failure(SGTasksError(kind: .credentialChanged, outcomeUnknown: error.outcomeUnknown))
                }
                return .failure(error)
            case let .success(value):
                answer = value
            }

            if answer.status == 200 {
                return self.success(answer, isMutation: isMutation, limit: limit, credential: credential, decode: decode, settle: settle)
            }
            if (200 ..< 300).contains(answer.status) {
                // The wire defines only 200 as success. Any other 2xx may still have committed.
                guard isCurrent() else {
                    return .failure(SGTasksError(kind: .credentialChanged, outcomeUnknown: isMutation))
                }
                return .failure(SGTasksError(kind: .malformedResponse, outcomeUnknown: isMutation))
            }

            let classified = SGTasksErrorClassifier.classify(status: answer.status, body: answer.body, retryAfterHeader: answer.retryAfter, isMutation: isMutation)
            if let serverTime = classified.error.serverTime {
                self.environment.noteServerTime(serverTime)
            }
            // The old session's failure is not this account's anymore: never applied, never retried.
            guard isCurrent() else {
                return .failure(SGTasksError(kind: .credentialChanged, outcomeUnknown: classified.error.outcomeUnknown))
            }
            if attempt == 1, !Task.isCancelled, case .session = classified.error.kind, let failure = classified.entitlementFailure {
                switch SGEntitlementFailureMapping.recovery(for: failure).retry {
                case .resignWithServerTimeOnce:
                    if let serverTime = classified.error.serverTime {
                        self.environment.adoptServerOffset(serverTime)
                        continue
                    }
                case .retryOnceWithFreshCredentials:
                    continue
                case .backoff, .stop:
                    break
                }
            }
            if case .session = classified.error.kind, let sessionError = classified.sessionError {
                // Only an HTTP 401 of the DeviceAuth family reaches the session machinery, and only
                // for the session this request presented (`apply` re-checks it under its own lock).
                // Its `reason` travels with it: `account_erased` is recorded on the session end.
                self.environment.applySessionFailure(sessionError, credential)
            }
            return .failure(classified.error)
        }
    }

    private func success<T>(_ answer: HTTPAnswer, isMutation: Bool, limit: Int, credential: SGEntitlementSessionCredential, decode: (SGTasksJSON.Value, Int?) throws -> T, settle: (T, SGEntitlementSessionCredential) -> Void) -> Result<T, SGTasksError> {
        let accountPeerId = credential.accountPeerId
        let captured = credential.refreshToken
        // A malformed answer of a session that changed meanwhile is the old session's, not this
        // account's: reported as `credentialChanged`, keeping the possible commit.
        let malformed = { () -> Result<T, SGTasksError> in
            guard self.environment.storedRefreshToken(accountPeerId) == captured else {
                return .failure(SGTasksError(kind: .credentialChanged, outcomeUnknown: isMutation))
            }
            return .failure(SGTasksError(kind: .malformedResponse, outcomeUnknown: isMutation))
        }
        let value: SGTasksJSON.Value
        do {
            value = try SGTasksJSON.parse(answer.body, maxBytes: limit, maxDepth: SGTasksWire.maxDepth)
        } catch {
            return malformed()
        }
        if case let .object(members) = value, let raw = members.first(where: { $0.name == "server_time" })?.value, case let .string(text) = raw, let serverTime = SGTasksWire.Instant(text) {
            self.environment.noteServerTime(serverTime.date)
        }
        let decoded: T
        do {
            decoded = try decode(value, answer.serverWire)
        } catch {
            return malformed()
        }
        // An answer that outlived its session (logout, re-bind) is not delivered: the account's
        // data may already be wiped, and a late result must not recreate it.
        guard self.environment.storedRefreshToken(accountPeerId) == captured else {
            return .failure(SGTasksError(kind: .credentialChanged, outcomeUnknown: isMutation))
        }
        settle(decoded, credential)
        return .success(decoded)
    }

    // MARK: - Request

    static let unreservedQueryCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// nil only when a cursor cannot be percent-encoded; nothing is sent then.
    func makeRequest(_ call: Call, refreshToken: String, device: SGEntitlementDeviceCredentials, accountPeerId: Int64) -> URLRequest? {
        var url = self.environment.baseURL.appendingPathComponent("tasks")
        var query: [String] = []
        let method: String
        switch call {
        case .mutation:
            url.appendPathComponent("mutations")
            method = "POST"
        case .mutationBatch:
            url.appendPathComponent("mutations")
            url.appendPathComponent("batch")
            method = "POST"
        case let .snapshot(cursor, limit):
            url.appendPathComponent("snapshot")
            method = "GET"
            if let cursor {
                guard let encoded = SGTasksTransport.encodeQueryValue(cursor.rawValue) else {
                    return nil
                }
                query.append("cursor=" + encoded)
            }
            if let limit {
                query.append("limit=\(limit)")
            }
        case let .changes(cursor, limit):
            url.appendPathComponent("changes")
            method = "GET"
            guard let encoded = SGTasksTransport.encodeQueryValue(cursor.rawValue) else {
                return nil
            }
            query.append("cursor=" + encoded)
            if let limit {
                query.append("limit=\(limit)")
            }
        case .realtimeMetadata:
            url.appendPathComponent("realtime")
            method = "GET"
        case .realtimeAuth:
            url.appendPathComponent("realtime")
            url.appendPathComponent("auth")
            method = "POST"
        }
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.percentEncodedQuery = query.joined(separator: "&")
            guard let withQuery = components.url else {
                return nil
            }
            url = withQuery
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = call.idleTimeout(self.environment.timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in device.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Exactly one value, on every Tasks request: the build's request wire (`sg_config.tasks_wire`,
        // 4 unless the build was made for a wire-5 backend); the server accepts nothing else.
        request.setValue(String(self.environment.requestWire), forHTTPHeaderField: SGTasksTransport.wireHeader)
        switch call {
        case let .mutation(mutation):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(mutation.mutationId.rawValue, forHTTPHeaderField: "Idempotency-Key")
            let proof = mutation.kind.isCreation ? self.environment.creationProof(accountPeerId) : nil
            request.httpBody = SGTasksTransport.body(mutation, creationProof: proof)
        case let .mutationBatch(batch):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(batch.batchId.rawValue, forHTTPHeaderField: "Idempotency-Key")
            let proof = batch.containsCreation ? self.environment.creationProof(accountPeerId) : nil
            request.httpBody = SGTasksTransport.batchBody(batch, creationProof: proof)
        case let .realtimeAuth(socketId):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = SGTasksRealtime.authRequestBody(socketId)
        case .snapshot, .changes, .realtimeMetadata:
            break
        }
        return request
    }

    /// `{"mutation":<sealed bytes>[,"creation_proof":{"jws":...}]}`. A proof that would push the
    /// request past the 64 KiB ceiling is left out: it is optional evidence, the mutation is not.
    static func body(_ mutation: SGTasksWire.MutationRequest, creationProof: String?) -> Data {
        return self.body(.mutation(mutation), creationProof: creationProof)
    }

    static func body(_ mutation: SGTasksWire.SealedMutation, creationProof: String?) -> Data {
        var bytes = Array("{\"mutation\":".utf8)
        bytes.append(contentsOf: mutation.wireJSON)
        if let creationProof, mutation.kind.isCreation, creationProof.utf8.count <= SGTasksCreationProof.maxJWSLength {
            var proof = Array(",\"creation_proof\":{\"jws\":".utf8)
            SGTasksJSON.appendString(creationProof, to: &proof)
            proof.append(UInt8(ascii: "}"))
            if bytes.count + proof.count + 1 <= SGTasksWire.maxRequestBytes {
                bytes.append(contentsOf: proof)
            }
        }
        bytes.append(UInt8(ascii: "}"))
        return Data(bytes)
    }

    /// The batch body, byte for byte (`SGTasksWireCodec.batchBody`): every item's sealed bytes, a
    /// `migration` item behind `"origin":"migration",`; one proof for the whole batch, only with a
    /// create and only while the body stays within 512 KiB.
    static func batchBody(_ batch: SGTasksWire.MutationBatchRequest, creationProof: String?) -> Data {
        let proof = creationProof.flatMap { $0.utf8.count <= SGTasksCreationProof.maxJWSLength ? $0 : nil }
        return SGTasksWireCodec.batchBody(batch, creationProof: proof)
    }

    static func encodeQueryValue(_ value: String) -> String? {
        return value.addingPercentEncoding(withAllowedCharacters: self.unreservedQueryCharacters)
    }
}

/// Zenlygram — one Tasks HTTP exchange with the policy transport's guarantees
/// (`SGEntitlementBoundedFetch`): a private ephemeral session, no cookies, no cache, redirects
/// refused, the body bounded WHILE it arrives, `timeout` idle and twice that for the whole exchange —
/// plus the `Retry-After` header a `429` carries and the `X-Tasks-Wire` echo of an R4 server.
///
/// Cancelling the calling task cancels the data task at once (`withTaskCancellationHandler`); the
/// answer is then `.offline(.cancelled)`, which for a mutation still means "may have committed".
enum SGTasksBoundedExchange {
    static func perform(_ request: URLRequest, timeout: TimeInterval, limit: Int, protocolClasses: [AnyClass]? = nil) async -> Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass> {
        let handle = TaskHandle()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout * 2.0
                configuration.httpShouldSetCookies = false
                configuration.httpCookieAcceptPolicy = .never
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                if let protocolClasses {
                    configuration.protocolClasses = protocolClasses
                }
                let delegate = Delegate(limit: limit, completion: { result in
                    continuation.resume(returning: result)
                })
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
                let task = session.dataTask(with: request)
                // Attached BEFORE `resume`: a cancellation that already arrived cancels the task
                // before it can start; a later one reaches it through `onCancel`. A cancelled task
                // still completes (with `.cancelled`), so the continuation always resumes.
                handle.attach(task)
                task.resume()
                session.finishTasksAndInvalidate()
            }
        }, onCancel: {
            handle.cancel()
        })
    }

    /// The data task, shared with the cancellation handler, which may run on any thread before or
    /// after the task exists.
    final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var isCancelled = false

        func attach(_ task: URLSessionTask) {
            self.lock.lock()
            let cancelNow = self.isCancelled
            if !cancelNow {
                self.task = task
            }
            self.lock.unlock()
            if cancelNow {
                task.cancel()
            }
        }

        func cancel() {
            self.lock.lock()
            self.isCancelled = true
            let task = self.task
            self.task = nil
            self.lock.unlock()
            task?.cancel()
        }
    }

    static func retryAfter(_ header: String?) -> Int? {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            return nil
        }
        return seconds
    }

    /// The `X-Tasks-Wire` echo: one canonical positive decimal (`4` or `5`); anything else — a list,
    /// a sign, a leading zero — is no echo at all. Which numbers mean anything is the cloud engine's
    /// call (`noteServerAnswer`), not the transport's.
    static func serverWire(_ header: String?) -> Int? {
        guard let header else {
            return nil
        }
        let digits = Array(header.trimmingCharacters(in: .whitespaces).utf8)
        guard (1 ... 3).contains(digits.count), digits[0] != UInt8(ascii: "0"), digits.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        private let limit: Int
        // Touched only on the session's serial delegate queue.
        private var body = Data()
        private var exceededLimit = false
        private var completion: ((Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass>) -> Void)?

        init(limit: Int, completion: @escaping (Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass>) -> Void) {
            self.limit = limit
            self.completion = completion
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if response.expectedContentLength > Int64(self.limit) {
                self.exceededLimit = true
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !self.exceededLimit else {
                return
            }
            guard self.body.count + data.count <= self.limit else {
                self.exceededLimit = true
                self.body = Data()
                dataTask.cancel()
                return
            }
            self.body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<SGTasksTransport.HTTPAnswer, SGEntitlementFailureClass>
            if self.exceededLimit {
                result = .failure(.offline(.malformedResponse))
            } else if let error {
                result = .failure(SGEntitlementFailureMapping.classify(urlErrorCode: (error as? URLError)?.code ?? .unknown))
            } else if let http = task.response as? HTTPURLResponse {
                result = .success(SGTasksTransport.HTTPAnswer(
                    status: http.statusCode,
                    body: self.body,
                    retryAfter: SGTasksBoundedExchange.retryAfter(http.value(forHTTPHeaderField: "Retry-After")),
                    serverWire: SGTasksBoundedExchange.serverWire(http.value(forHTTPHeaderField: SGTasksTransport.wireHeader))
                ))
            } else {
                result = .failure(.offline(.malformedResponse))
            }
            let completion = self.completion
            self.completion = nil
            completion?(result)
        }
    }
}
