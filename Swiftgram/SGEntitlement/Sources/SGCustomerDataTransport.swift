import Foundation

/// Zenlygram — the customer-data routes (`SGEntitlementCustomerDataRoute`: `/v1/profile/consents`,
/// `/sync`, `/me`, `/events` and `/v1/account/delete`) over the existing DeviceAuth identity.
/// Internal, a sibling of `SGTasksTransport` with the same per-call rules; the public surface is the
/// facade on `SGEntitlement` (`SGEntitlementCustomerData.swift`). A success body is handed back
/// undecoded: the caller's own core decodes it.
///
/// Per call:
/// 1. The account's stored refresh token is captured, then the account's gate — the one rotation
///    holds (`SGEntitlementAccountGate`) — is awaited.
/// 2. Immediately before EACH attempt the call must not be cancelled, the caller's `stillWanted`
///    (when given) must still hold (else `notWanted`, nothing signed or sent), and the token is
///    re-read and must still be the captured one (else `credentialChanged`, nothing sent); a fresh
///    DeviceAuth set (nonce, transmit timestamp, signature) is made for that attempt only.
/// 3. The request carries exactly `Authorization: Bearer`, `X-Device-Id/Nonce/Ts/Sig`, `Accept`, and
///    with a body `Content-Type: application/json`; `account/delete` adds the caller's
///    `Idempotency-Key`. No app/OS version header and never a credential in a body: a body whose top
///    level holds a reserved credential key is refused before anything is sent (C§0.1). No redirect
///    is followed and the answer is bounded while it arrives (64 KiB, `profile/me` 1 MiB). Whole
///    exchange: `profile/events` 20 s, every other route 10 s.
/// 4. At most ONE retry, and only the existing ones for an HTTP 401: `clock_skew` re-signs with the
///    server time, `nonce_replayed` / bare 401 rebuilds the credential set.
/// 5. Whatever the answer, if the stored token is no longer the captured one the call ends as
///    `credentialChanged`: nothing of the old session is applied or reported. Otherwise an HTTP 401
///    of the DeviceAuth family is handed to `applySessionFailure` for the exact captured credential;
///    no other answer changes session state.
///
/// One extra mode, `sendPresentingRemovedCredential`, is the logout final send
/// (`SGEntitlement.logout`): the session was already removed locally, so there is no stored token to
/// re-check — nor a rotation that could still store a successor for it, so no gate to wait behind —
/// the whole send keeps to the caller's deadline, and nothing about the answer is applied.
///
/// Nothing here logs. Request bodies, tokens and response content never leave this type except as
/// the typed result.
struct SGCustomerDataTransport {
    /// Every route but `profile/me` answers a receipt, a small result list or one error.
    static let defaultResponseLimit = 64 * 1024
    /// The "right to know" answer.
    static let profileMeResponseLimit = 1 << 20
    static let maxRetryAfter = 86400
    /// Top-level body keys the server's DeviceAuth guards would read as credentials (C§0.1). No
    /// customer-data body may carry one.
    static let reservedBodyKeys: Set<String> = ["refresh_token", "device_id", "nonce", "ts", "sig"]

    struct HTTPAnswer: Equatable {
        let status: Int
        let body: Data
        let retryAfter: Int?
    }

    /// `timeout` bounds the WHOLE exchange; the idle bound is half of it.
    typealias Fetch = (_ request: URLRequest, _ timeout: TimeInterval, _ limit: Int) async -> Result<HTTPAnswer, SGEntitlementFailureClass>

    struct Environment {
        let baseURL: URL
        /// The whole-exchange bound of one attempt of the route (`exchangeTimeout`).
        let timeout: (SGEntitlementCustomerDataRoute) -> TimeInterval
        let gate: SGEntitlementAccountGate
        /// The account's stored refresh token right now (nil: no session).
        let storedRefreshToken: (Int64) -> String?
        /// A fresh DeviceAuth credential set for one attempt (`SGEntitlementDeviceIdentity`).
        let deviceCredentials: () -> SGEntitlementDeviceCredentials?
        /// Every `server_time` read from a body feeds the clock high-water mark.
        let noteServerTime: (Date) -> Void
        /// `clock_skew`: adopt the server's offset before the single re-signed retry.
        let adoptServerOffset: (Date) -> Void
        /// `SGEntitlement.apply` for the exact captured credential.
        let applySessionFailure: (SGEntitlementRequestError, SGEntitlementSessionCredential) -> Void
        let fetch: Fetch
        /// Monotonic seconds, for the removed-credential mode's deadline.
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    /// Which session an exchange presents.
    private enum Presenting {
        /// The account's stored session, captured at the call and re-checked around every attempt.
        case stored
        /// A session already removed from the store (the logout final send), kept to `deadline`.
        case removed(deadline: TimeInterval)
    }

    let environment: Environment

    static func exchangeTimeout(_ route: SGEntitlementCustomerDataRoute) -> TimeInterval {
        switch route {
        case .profileEvents:
            return 20.0
        case .profileConsents, .profileSync, .profileMe, .accountDelete:
            return 10.0
        }
    }

    static func responseLimit(for route: SGEntitlementCustomerDataRoute) -> Int {
        switch route {
        case .profileMe:
            return SGCustomerDataTransport.profileMeResponseLimit
        case .profileConsents, .profileSync, .profileEvents, .accountDelete:
            return SGCustomerDataTransport.defaultResponseLimit
        }
    }

    // MARK: - Calls

    /// One call under the account's CURRENT stored session. `stillWanted` is first asked once the
    /// gate is held: whatever the call waited behind there, a condition that no longer holds sends
    /// nothing (step 2).
    func send(_ route: SGEntitlementCustomerDataRoute, body: Data?, accountPeerId: Int64, idempotencyKey: String? = nil, stillWanted: (() -> Bool)? = nil) async -> Result<Data, SGEntitlement.CustomerDataFailure> {
        if let refusal = SGCustomerDataTransport.localRefusal(route, body: body) {
            return .failure(.request(refusal))
        }
        guard !Task.isCancelled else {
            return .failure(.request(SGEntitlementRequestError(failure: .offline(.cancelled))))
        }
        guard let captured = self.environment.storedRefreshToken(accountPeerId), !captured.isEmpty else {
            return .failure(.notLinked)
        }
        let gate = self.environment.gate
        await gate.acquire(accountPeerId: accountPeerId)
        defer {
            gate.release(accountPeerId: accountPeerId)
        }
        let credential = SGEntitlementSessionCredential(accountPeerId: accountPeerId, refreshToken: captured)
        return await self.attempts(route, body: body, credential: credential, idempotencyKey: idempotencyKey, presenting: .stored, stillWanted: stillWanted)
    }

    /// The logout final send: `credential` was captured as the session was removed. No re-check and
    /// no gate (step 1/2 above), nothing applied afterwards (step 5); every attempt keeps to
    /// `deadline` (`Environment.uptime` seconds) — one that would start at or past it is not sent.
    func sendPresentingRemovedCredential(_ route: SGEntitlementCustomerDataRoute, body: Data?, credential: SGEntitlementSessionCredential, deadline: TimeInterval) async -> Result<Data, SGEntitlement.CustomerDataFailure> {
        if let refusal = SGCustomerDataTransport.localRefusal(route, body: body) {
            return .failure(.request(refusal))
        }
        return await self.attempts(route, body: body, credential: credential, idempotencyKey: nil, presenting: .removed(deadline: deadline), stillWanted: nil)
    }

    // MARK: - Exchange

    private func attempts(_ route: SGEntitlementCustomerDataRoute, body: Data?, credential: SGEntitlementSessionCredential, idempotencyKey: String?, presenting: Presenting, stillWanted: (() -> Bool)?) async -> Result<Data, SGEntitlement.CustomerDataFailure> {
        let isCurrent: () -> Bool = {
            switch presenting {
            case .stored:
                return self.environment.storedRefreshToken(credential.accountPeerId) == credential.refreshToken
            case .removed:
                return true
            }
        }
        var attempt = 0
        while true {
            attempt += 1
            guard !Task.isCancelled else {
                return .failure(.request(SGEntitlementRequestError(failure: .offline(.cancelled))))
            }
            // The caller's own condition, asked now that the call's turn came: it may have waited
            // behind a rotation, a Tasks attempt or another call of the account (or a correction
            // retry follows), and what happened meanwhile — a withdrawal — decides whether it goes.
            if let stillWanted, !stillWanted() {
                return .failure(.notWanted)
            }
            guard isCurrent() else {
                return .failure(.credentialChanged)
            }
            var timeout = self.environment.timeout(route)
            if case let .removed(deadline) = presenting {
                let remaining = deadline - self.environment.uptime()
                guard remaining > 0 else {
                    return .failure(.request(SGEntitlementRequestError(failure: .offline(.timeout))))
                }
                timeout = min(timeout, remaining)
            }
            guard let device = self.environment.deviceCredentials() else {
                // The key could not sign: nothing was sent.
                return .failure(.request(SGEntitlementRequestError(failure: .offline(.unknown), message: "cannot sign")))
            }
            let request = self.makeRequest(route, body: body, refreshToken: credential.refreshToken, device: device, idempotencyKey: idempotencyKey, timeout: timeout)
            let answer: HTTPAnswer
            switch await self.environment.fetch(request, timeout, SGCustomerDataTransport.responseLimit(for: route)) {
            case let .failure(failure):
                // A session that changed while the request was out is reported as such, whatever
                // became of the request.
                guard isCurrent() else {
                    return .failure(.credentialChanged)
                }
                return .failure(.request(SGEntitlementRequestError(failure: failure)))
            case let .success(value):
                answer = value
            }

            let envelope = SGCustomerDataTransport.envelope(answer.body)
            if let serverTime = envelope.serverTime {
                self.environment.noteServerTime(serverTime)
            }
            if (200 ..< 300).contains(answer.status) {
                // An answer that outlived its session (logout, re-bind) is not delivered.
                guard isCurrent() else {
                    return .failure(.credentialChanged)
                }
                return .success(answer.body)
            }

            let error = SGCustomerDataTransport.requestError(answer, envelope: envelope)
            // The old session's failure is not this account's anymore: never applied, never retried.
            guard isCurrent() else {
                return .failure(.credentialChanged)
            }
            if attempt == 1, answer.status == 401, !Task.isCancelled, case .session = error.failure {
                switch error.recovery.retry {
                case .resignWithServerTimeOnce:
                    if let serverTime = error.serverTime {
                        self.environment.adoptServerOffset(serverTime)
                        continue
                    }
                case .retryOnceWithFreshCredentials:
                    continue
                case .backoff, .stop:
                    break
                }
            }
            if case .stored = presenting, answer.status == 401, case .session = error.failure {
                // Only an HTTP 401 of the DeviceAuth family reaches the session machinery, and only
                // for the session this request presented (`apply` re-checks it under its own lock).
                self.environment.applySessionFailure(error, credential)
            }
            return .failure(.request(error))
        }
    }

    // MARK: - Request

    func makeRequest(_ route: SGEntitlementCustomerDataRoute, body: Data?, refreshToken: String, device: SGEntitlementDeviceCredentials, idempotencyKey: String?, timeout: TimeInterval) -> URLRequest {
        var url = self.environment.baseURL
        for component in route.path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.httpMethod = route.method
        request.timeoutInterval = timeout / 2.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        for (name, value) in device.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            // Load-bearing: the server reads a JSON body only under the JSON content type.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if route == .accountDelete, let idempotencyKey, !idempotencyKey.isEmpty {
            request.setValue(String(idempotencyKey.prefix(120)), forHTTPHeaderField: "Idempotency-Key")
        }
        return request
    }

    /// Refused before anything is sent: a body on the one GET, and a body whose top level carries a
    /// reserved credential key (the server's guards fall back to body credentials).
    static func localRefusal(_ route: SGEntitlementCustomerDataRoute, body: Data?) -> SGEntitlementRequestError? {
        guard let body else {
            return nil
        }
        if route.method == "GET" {
            return SGEntitlementRequestError(failure: .refused(.invalidRequest), message: "a GET carries no body; not sent")
        }
        if let object = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any], !SGCustomerDataTransport.reservedBodyKeys.isDisjoint(with: object.keys) {
            return SGEntitlementRequestError(failure: .refused(.invalidRequest), message: "credential key in body; not sent")
        }
        return nil
    }

    // MARK: - Answer

    /// The parts of a body this transport reads: an error's stable code, `reason` and
    /// `retry_after`, and any body's top-level `server_time`. Never the `message`.
    struct Envelope: Equatable {
        var code: String?
        var reason: String?
        var retryAfter: Int?
        var serverTime: Date?
    }

    static func envelope(_ body: Data) -> Envelope {
        guard !body.isEmpty, let object = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            return Envelope()
        }
        var envelope = Envelope()
        if let code = object["error"] as? String, (1 ... 80).contains(code.unicodeScalars.count) {
            envelope.code = code
        }
        if let reason = object["reason"] as? String, (1 ... 80).contains(reason.unicodeScalars.count) {
            envelope.reason = reason
        }
        if let retryAfter = object["retry_after"] as? NSNumber {
            envelope.retryAfter = retryAfter.intValue
        }
        if let raw = object["server_time"] as? String {
            envelope.serverTime = SGEntitlementTimestamp.parse(raw)
        }
        return envelope
    }

    static func requestError(_ answer: HTTPAnswer, envelope: Envelope) -> SGEntitlementRequestError {
        let retryAfter = (answer.retryAfter ?? envelope.retryAfter).map { min(max($0, 0), SGCustomerDataTransport.maxRetryAfter) }
        return SGEntitlementRequestError(
            failure: SGCustomerDataTransport.classify(status: answer.status, code: envelope.code, retryAfter: retryAfter),
            serverTime: envelope.serverTime,
            retryAfter: retryAfter,
            status: answer.status,
            code: envelope.code,
            reason: envelope.reason,
            responseBody: SGEntitlementRequestError.boundedResponseBody(answer.body)
        )
    }

    /// The existing classification, except that the DeviceAuth family speaks in HTTP 401 only: the
    /// same code under any other status (a proxy, a framework page) is not about this session and
    /// must never drop it.
    static func classify(status: Int, code: String?, retryAfter: Int?) -> SGEntitlementFailureClass {
        let failure = SGEntitlementFailureMapping.classify(status: status, code: code, retryAfter: retryAfter)
        guard case .session = failure, status != 401 else {
            return failure
        }
        if status >= 500 {
            return .offline(.serverError)
        }
        return .unknownRefusal(code: code ?? "", status: status)
    }
}
