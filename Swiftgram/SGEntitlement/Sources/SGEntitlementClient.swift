import Foundation

/// Zenlygram — the Zenlygram entitlement HTTP client.
///
/// An `actor`, so the session-mutating calls serialise against each other: refresh-token rotation is
/// only safe if exactly one refresh is in flight per process, and the nonce store makes concurrent
/// identical credential sets a `nonce_replayed` 401.
///
/// **Nothing here may ever run on the launch critical path** (invariant I1). The client makes no call
/// of its own accord; `SGEntitlementScheduler` decides when, and it never schedules before the first
/// idle window after launch.
public actor SGEntitlementClient {
    public struct Configuration {
        /// `https://{host}/v1`
        public var baseURL: URL
        /// 5 s. No retry storm.
        public var timeout: TimeInterval
        public var appVersion: String?
        public var osVersion: String?
        public var platform: String
        /// Tests only: a scripted `URLProtocol` origin for the client's own session, the Tasks
        /// transport and the legacy policy endpoint derived from this configuration
        /// (`SGEntitlementPolicyEndpoint.legacy`). nil in the app.
        var protocolClasses: [AnyClass]?

        public init(baseURL: URL, timeout: TimeInterval = 5.0, appVersion: String? = nil, osVersion: String? = nil, platform: String = "ios") {
            self.baseURL = baseURL
            self.timeout = timeout
            self.appVersion = appVersion
            self.osVersion = osVersion
            self.platform = platform
        }

        /// The shipped configuration: the validated origin of `SG_CONFIG.apiUrl` plus the `/v1` prefix
        /// (`SGEntitlementBackendOrigin`).
        ///
        /// Returns nil — i.e. the app never contacts ANY entitlement server — unless this build ships
        /// at least one pinned signing key AND `api_url` is a canonical HTTPS root that is not
        /// upstream Swiftgram's default. Both halves are load-bearing, and one alone is not enough:
        /// `SGConfig`'s defaults still point `apiUrl` at upstream Swiftgram's host, so a config that set
        /// only some other field would otherwise send this install's device id, its Secure Enclave
        /// public key and its device name to somebody else's server — and could not verify a token from
        /// it anyway. An unsafe value (HTTP, userinfo, a query, a fragment, a path, a bad port) is
        /// refused the same way, never repaired. Everything the user owns keeps working; only the
        /// network half is inert.
        public static func shipped(appVersion: String?, osVersion: String?) -> Configuration? {
            guard !SGEntitlementPinnedKeys.shipped.isEmpty, let origin = Configuration.shippedOrigin else {
                return nil
            }
            return Configuration(baseURL: origin.baseURL, appVersion: appVersion, osVersion: osVersion)
        }
    }

    /// Which credentials a route wants.
    private enum AuthTier {
        case none
        /// The full five-credential set for one Telegram account's binding, around the refresh token
        /// the CALLER captured (`SGEntitlementSessionCredential`). Never re-read from the store here:
        /// the token sent — on the first try and on every retry — must be the one the caller will
        /// compare the response against.
        ///
        /// `proof` adds `X-Device-Proof` over the SAME nonce and timestamp: only the EXPLICIT Restore
        /// claim (`apple-restore`). A background bound attach never carries it.
        case device(SGEntitlementSessionCredential, proof: ProofIntent?)
        /// `/bind/poll`: the poll token, plus a `bind-merge` proof with the key `/bind/start`
        /// registered (`SGEntitlementDeviceProof.prepareBindPoll`). A known different key is never
        /// polled; only a start with no registered key (legacy) polls proofless.
        case pollToken(String, registeredPublicKey: String?)
        /// `/bind/attest`: the poll token travels in the BODY only (no `Authorization`), and the
        /// MANDATORY `bind-attest` proof by the key `/bind/start` registered signs the exact raw body
        /// bytes. A start without a registered key, or a key change, sends nothing.
        case bindAttest(registeredPublicKey: String?, rawBody: Data)
        /// `/apple/attach` while unbound: NO `Authorization` header. Always the `apple-orphan` proof
        /// over the exact receipt plus `device_pubkey` in the body, atomically — never the legacy
        /// unsigned form. The raw device id alone is no longer merge authority.
        case anonymous(proofPayload: String)
    }

    /// What an `X-Device-Proof` signs besides the request's own path/mode.
    private struct ProofIntent {
        let mode: SGEntitlementDeviceProofMode
        let payload: String
    }

    private let configuration: Configuration
    private let session: URLSession
    private let store: SGEntitlementStore
    private let clock: SGEntitlementClock
    private let identity: SGEntitlementDeviceIdentity
    /// Refresh-token rotation and every Tasks network attempt take this per-account gate
    /// (`SGEntitlementAccountGate`): no Tasks request presents a token a rotation is replacing.
    nonisolated let accountGate = SGEntitlementAccountGate()

    public init(
        configuration: Configuration,
        store: SGEntitlementStore = .shared,
        clock: SGEntitlementClock = .shared,
        identity: SGEntitlementDeviceIdentity = .shared
    ) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout * 2.0
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Tests only: the scripted origin (nil in the app), as the Tasks transport and the legacy
        // policy endpoint already honour it.
        if let protocolClasses = configuration.protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }
        // Redirects are refused, as in the policy and Tasks transports: a 3xx is itself the answer, so
        // no bearer, DeviceAuth header or 307/308 body ever leaves for the `Location` host, and nothing
        // that host says (its `server_time` included) is read.
        self.session = URLSession(configuration: sessionConfiguration, delegate: SGEntitlementRedirectRefusal(), delegateQueue: nil)
        self.store = store
        self.clock = clock
        self.identity = identity
    }

    deinit {
        // The session retains its delegate until invalidated; in-flight requests still complete.
        self.session.finishTasksAndInvalidate()
    }

    // MARK: - Bind

    /// `POST /v1/bind/start`. `src: "ios"` is what makes the bot's reply obey guideline 3.1.3(b) —
    /// no price, no plan keyboard, no Mini App button. Always send it.
    ///
    /// `publicKey` is the device key the caller captured (`SGEntitlement.beginBind`); the returned
    /// start records it, so `completeBind` can tell whether the device still holds that key.
    ///
    /// `consent` is the account's local grant (a grant ConsentEvent object), sent as `"consent"` —
    /// `SGEntitlement.beginBind` attaches it only when the account may link with it. nil sends the
    /// body exactly as before.
    public func bindStart(deviceName: String, publicKey: String, consent: [String: Any]? = nil) async -> Result<SGEntitlementBindStart, SGEntitlementRequestError> {
        guard let deviceId = self.identity.deviceId() else {
            return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "no device identity"))
        }
        let body = SGEntitlementClient.bindStartBody(
            deviceId: deviceId,
            publicKey: publicKey,
            platform: self.configuration.platform,
            deviceName: deviceName,
            appVersion: self.configuration.appVersion,
            osVersion: self.configuration.osVersion,
            consent: consent
        )
        let result: Result<SGEntitlementBindStart, SGEntitlementRequestError> = await self.request(path: "bind/start", method: "POST", body: body, auth: .none, idempotencyKey: nil)
        return result.map { start in
            var start = start
            start.registeredPublicKey = publicKey
            return start
        }
    }

    /// The `/bind/start` body (pure). `consent` goes in as `"consent"` only when given and when it is
    /// a valid JSON object — anything else is left out, exactly as the server's own `invalid_consent`
    /// fallback would (the grant still reaches `/v1/profile/consents` after the link).
    static func bindStartBody(deviceId: String, publicKey: String, platform: String, deviceName: String, appVersion: String?, osVersion: String?, consent: [String: Any]?) -> [String: Any] {
        var body: [String: Any] = [
            "device_id": deviceId,
            "device_pubkey": publicKey,
            "platform": platform,
            "device_name": String(deviceName.prefix(128)),
            "src": "ios"
        ]
        if let appVersion {
            body["app_version"] = String(appVersion.prefix(32))
        }
        if let osVersion {
            body["os_version"] = String(osVersion.prefix(32))
        }
        if let consent, JSONSerialization.isValidJSONObject(consent) {
            body["consent"] = consent
        }
        return body
    }

    /// `POST /v1/bind/poll`.
    ///
    /// TIMEOUT HAZARD: the server consumes the row BEFORE writing the response and this route has no
    /// idempotency replay. On a timeout, retry once; if the retry answers `consumed` with no refresh
    /// token the material is lost — restart from `/bind/start`.
    ///
    /// `registeredPublicKey` is `SGEntitlementBindStart.registeredPublicKey`: with it, the poll proves
    /// (`bind-merge`) that the key which made this install's anonymous purchases is the one binding.
    /// When the install key is no longer that key, nothing is sent and the answer is `.restartBind`.
    public func bindPoll(pollToken: String, registeredPublicKey: String? = nil) async -> Result<SGEntitlementBindPollResult, SGEntitlementRequestError> {
        let result: Result<SGEntitlementBindPollEnvelope, SGEntitlementRequestError> = await self.request(
            path: "bind/poll",
            method: "POST",
            body: ["poll_token": pollToken],
            auth: .pollToken(pollToken, registeredPublicKey: registeredPublicKey),
            idempotencyKey: nil
        )
        switch result {
        case let .success(envelope):
            return .success(envelope.resolved)
        case let .failure(error):
            if error.message == SGEntitlementClient.bindKeyChangedMarker {
                return .success(.restartBind)
            }
            return .failure(error)
        }
    }

    /// The local, never-sent outcome of `prepareBindPoll` (`.restartBind`), carried out of the
    /// generic transport and turned into `SGEntitlementBindPollResult.restartBind` by `bindPoll`.
    private static let bindKeyChangedMarker = "bind key changed; poll not sent"

    /// `POST /v1/bind/attest` (bind-attest v1): hands Telegram-signed Mini App `initData` for THIS
    /// bind to the server, which confirms the bind for the Telegram user it names. `true` only for
    /// `200 state: "confirmed"`; the caller then polls `/bind/poll` for the session as usual.
    ///
    /// Every other outcome (any error, a key change, an unsigned request) is `false` or a failure
    /// and means: fall back to the code flow. Neither `initData` nor the poll token is ever logged.
    public func bindAttest(pollToken: String, registeredPublicKey: String?, initData: String) async -> Result<Bool, SGEntitlementRequestError> {
        guard let body = SGEntitlementDeviceProof.bindAttestBody(pollToken: pollToken, initData: initData) else {
            return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "bad body"))
        }
        let result: Result<SGEntitlementBindAttestEnvelope, SGEntitlementRequestError> = await self.request(
            path: "bind/attest",
            method: "POST",
            body: nil,
            auth: .bindAttest(registeredPublicKey: registeredPublicKey, rawBody: body),
            idempotencyKey: nil
        )
        return result.map { $0.state == "confirmed" }
    }

    /// `POST /v1/bind/revoke`. Logout of ONE Telegram account on this device.
    ///
    /// It does NOT cancel the subscription: signing back in restores it and the paid period is
    /// untouched. The caller has ALREADY deleted the local material (`SGEntitlement.logout`) and
    /// hands over the credential it captured while doing so; this never reads or writes the store,
    /// so a session bound after the logout cannot be the one that is revoked from here.
    public func bindRevoke(credential: SGEntitlementSessionCredential) async -> Result<Bool, SGEntitlementRequestError> {
        let result: Result<SGEntitlementOkEnvelope, SGEntitlementRequestError> = await self.request(
            path: "bind/revoke",
            method: "POST",
            body: [:],
            auth: .device(credential, proof: nil),
            idempotencyKey: nil
        )
        switch result {
        case let .success(envelope):
            return .success(envelope.ok ?? true)
        case let .failure(error):
            // Any 401 here means "already logged out".
            if case .session = error.failure {
                return .success(true)
            }
            return .failure(error)
        }
    }

    // MARK: - Entitlement

    /// `GET /v1/entitlement` — 60/h/device, does NOT rotate. Prefer this for routine refreshes.
    public func fetchEntitlement(credential: SGEntitlementSessionCredential) async -> Result<SGEntitlementFetchResult, SGEntitlementRequestError> {
        return await self.request(path: "entitlement", method: "GET", body: nil, auth: .device(credential, proof: nil), idempotencyKey: nil)
    }

    /// `POST /v1/entitlement/refresh` — 20/h/device, ROTATES.
    ///
    /// The old refresh token stays valid for a 60 s overlap; presenting it after that is the theft
    /// signal and the WHOLE binding is revoked. So the new token is persisted — and proven persisted
    /// by a read-back — before this function returns it. If persisting fails the response is
    /// DISCARDED and the old token is kept. It is accepted only within the server's overlap;
    /// retrying it after that window can revoke the binding.
    ///
    /// The rotation write carries the successor refresh token and an optional APNs delivery digest,
    /// never the unverified JWS. Writing that JWS could replace a known-good token with one that
    /// cannot verify, violating contract §4.2. A server-side key rotation this build cannot follow
    /// would otherwise drop a paying user straight into `.degraded(.unverifiable)` with nothing to
    /// fall back to. `SGEntitlement.adopt(entitlement:credential:)` is the only writer of
    /// `material.entitlement` (and of `material.until`, which describes that same token), and it
    /// writes only after `SGEntitlementTokenVerifier` has said yes.
    ///
    /// The successor is stored only while `credential`'s token — the one this request presented — is
    /// STILL the stored one: a logout (`clearSession`) or a re-bind that landed while the request was
    /// in flight owns the slot now, and writing here would resurrect the logged-out binding or
    /// clobber the new one. The caller adopts the response's JWS under the credential of the NEW
    /// token (`SGEntitlementRefreshResult.refreshToken`).
    public func refreshEntitlement(credential: SGEntitlementSessionCredential, pushToken: String? = nil) async -> Result<SGEntitlementRefreshResult, SGEntitlementRequestError> {
        switch await self.rotateEntitlement(credential: credential, pushToken: pushToken) {
        case let .rotated(result):
            return .success(result)
        case .sessionChanged, .notPersisted:
            // Do not adopt a response for a replaced session or an unpersisted successor.
            return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "rotation not persisted"))
        case let .failed(error):
            return .failure(error)
        }
    }

    /// `refreshEntitlement` with the outcome of persisting the successor kept apart, so a rotation
    /// that a logout or re-bind made obsolete is not mistaken for a transport failure.
    func rotateEntitlement(credential: SGEntitlementSessionCredential, pushToken: String?) async -> SGEntitlementRotationOutcome {
        // Shared with the Tasks transport: wait for an in-flight Tasks attempt on this account, then
        // rotate only if the token is still the stored one (a logout or re-bind owns the slot now).
        let account = credential.accountPeerId
        await self.accountGate.acquire(accountPeerId: account)
        defer {
            self.accountGate.release(accountPeerId: account)
        }
        guard self.store.session(accountPeerId: account).refreshToken == credential.refreshToken else {
            return .sessionChanged
        }
        var body: [String: Any] = [:]
        if let appVersion = self.configuration.appVersion {
            body["app_version"] = appVersion
        }
        if let osVersion = self.configuration.osVersion {
            body["os_version"] = osVersion
        }
        if let pushToken {
            body["push_token"] = pushToken
        }
        let result: Result<SGEntitlementRefreshEnvelope, SGEntitlementRequestError> = await self.request(
            path: "entitlement/refresh",
            method: "POST",
            body: body,
            auth: .device(credential, proof: nil),
            idempotencyKey: nil
        )
        switch result {
        case let .success(envelope):
            let answer = SGEntitlementRefreshResult(
                entitlement: envelope.entitlement,
                refreshToken: envelope.refreshToken,
                expiresAt: envelope.expiresAt,
                until: envelope.until
            )
            return SGEntitlementClient.persistRotation(answer, presented: credential, deliveredPushToken: pushToken, store: self.store)
        case let .failure(error):
            return .failed(error)
        }
    }

    /// Persists a rotation the server answered: the successor refresh token is written only while
    /// `credential`'s token — the one the request presented — is still the account's stored one.
    /// The same write records the receipt for `deliveredPushToken` (its digest, never the token),
    /// so the receipt can only ever describe the binding that received it; a rotation that carried
    /// no token keeps the receipt the binding already holds.
    ///
    /// One immediate retry: a Keychain refusal is usually transient, and the window in which the OLD
    /// token is still accepted is only 60 s wide. A refused precondition is not transient — the
    /// session changed hands (logout, re-bind) — so it is not retried and is reported as such.
    static func persistRotation(_ answer: SGEntitlementRefreshResult, presented credential: SGEntitlementSessionCredential, deliveredPushToken: String?, store: SGEntitlementStore) -> SGEntitlementRotationOutcome {
        let receipt = deliveredPushToken.map(SGEntitlementPushTelemetry.digest)
        let persist: () -> Result<SGEntitlementSessionMaterial, SGEntitlementStoreError> = {
            return store.updateSession(accountPeerId: credential.accountPeerId, if: { material in
                return material.refreshToken == credential.refreshToken
            }, { material in
                material.refreshToken = answer.refreshToken
                if let receipt {
                    material.pushTokenDigest = receipt
                }
            })
        }
        var stored = persist()
        if case let .failure(error) = stored, error != .preconditionFailed {
            stored = persist()
        }
        switch stored {
        case .success:
            return .rotated(answer)
        case .failure(.preconditionFailed):
            return .sessionChanged
        case .failure:
            return .notPersisted
        }
    }

    /// `POST /v1/trial/start` — 3/h/device. Requires a bound device (a linked Telegram account); an
    /// IAP does not. Every refusal must be shown NEXT TO the purchase options, never as a dead end.
    public func startTrial(credential: SGEntitlementSessionCredential, idempotencyKey: String) async -> Result<SGEntitlementTrialResult, SGEntitlementRequestError> {
        return await self.request(path: "trial/start", method: "POST", body: [:], auth: .device(credential, proof: nil), idempotencyKey: idempotencyKey)
    }

    /// `POST /v1/assertions` `{audience}` — auth: device. A one-time, audience-bound assertion for the
    /// account this session is bound to (`SGEntitlementFeatureAssertion.swift` has the contract).
    /// Never retried with the same answer: every call mints a new single-use assertion.
    public func featureAssertion(credential: SGEntitlementSessionCredential, audience: String) async -> Result<SGEntitlementFeatureAssertion, SGEntitlementRequestError> {
        return await self.request(path: "assertions", method: "POST", body: ["audience": audience], auth: .device(credential, proof: nil), idempotencyKey: nil)
    }

    // MARK: - Apple

    /// `POST /v1/apple/prepare`. For a LINKED account's new purchase it is mandatory: every failure,
    /// `401` included, refuses the purchase (`SGIAPPurchaseAdmission`). An unlinked install never
    /// calls it and buys with no `appAccountToken`.
    public func applePrepare(credential: SGEntitlementSessionCredential, productId: String, idempotencyKey: String) async -> Result<SGEntitlementApplePrepare, SGEntitlementRequestError> {
        return await self.request(
            path: "apple/prepare",
            method: "POST",
            body: ["product_id": productId],
            auth: .device(credential, proof: nil),
            idempotencyKey: idempotencyKey
        )
    }

    /// `POST /v1/apple/attach`.
    ///
    /// `credential` nil is the unbound path: no `Authorization` header at all, but always
    /// `X-Device-Id`. On a 2xx the caller may `finish()` the transaction — and only then. NEVER
    /// `finish()` an unattached transaction: StoreKit redelivers an unfinished one, while a finished
    /// one is gone forever and with it the proof of a payment.
    ///
    /// `explicitRestore` is the user's Restore Purchases claim (`apple-restore` proof, bound only):
    /// it may move this receipt's still-unlinked orphan to `credential`'s account. A background or
    /// purchase-path attach must pass false. Unbound, every attach carries an `apple-orphan` proof.
    public func appleAttach(credential: SGEntitlementSessionCredential?, signedTransaction: String, idempotencyKey: String, explicitRestore: Bool = false) async -> Result<SGEntitlementAppleAttach, SGEntitlementRequestError> {
        let auth: AuthTier
        if let credential {
            auth = .device(credential, proof: explicitRestore ? ProofIntent(mode: .appleRestore, payload: signedTransaction) : nil)
        } else {
            auth = .anonymous(proofPayload: signedTransaction)
        }
        return await self.request(
            path: "apple/attach",
            method: "POST",
            body: ["signed_transaction": signedTransaction],
            auth: auth,
            idempotencyKey: idempotencyKey
        )
    }

    /// `GET /v1/health`. Optional; never gate anything on it and never call it on launch.
    public func health() async -> Result<SGEntitlementHealth, SGEntitlementRequestError> {
        return await self.request(path: "health", method: "GET", body: nil, auth: .none, idempotencyKey: nil)
    }

    /// What the Tasks and customer-data transports (`SGTasksTransport`, `SGCustomerDataTransport`)
    /// share with this client: the endpoint and the request timeout. Nothing of the generic
    /// transport, and no path or signer.
    func tasksEndpoint() -> (baseURL: URL, timeout: TimeInterval, protocolClasses: [AnyClass]?) {
        return (self.configuration.baseURL, self.configuration.timeout, self.configuration.protocolClasses)
    }

    // MARK: - Transport

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: [String: Any]?,
        auth: AuthTier,
        idempotencyKey: String?
    ) async -> Result<T, SGEntitlementRequestError> {
        let first: Result<T, SGEntitlementRequestError> = await self.perform(path: path, method: method, body: body, auth: auth, idempotencyKey: idempotencyKey)
        guard case let .failure(error) = first else {
            return first
        }
        // Exactly one retry, and only for the two causes that are recoverable with no user action.
        // Both need a COMPLETELY fresh credential set: the nonce is single-use.
        switch SGEntitlementFailureMapping.recovery(for: error.failure).retry {
        case .resignWithServerTimeOnce:
            guard let serverTime = error.serverTime else {
                return first
            }
            self.clock.adoptServerOffset(serverTime: serverTime)
            return await self.perform(path: path, method: method, body: body, auth: auth, idempotencyKey: idempotencyKey)
        case .retryOnceWithFreshCredentials:
            return await self.perform(path: path, method: method, body: body, auth: auth, idempotencyKey: idempotencyKey)
        case .backoff, .stop:
            return first
        }
    }

    private func perform<T: Decodable>(
        path: String,
        method: String,
        body: [String: Any]?,
        auth: AuthTier,
        idempotencyKey: String?
    ) async -> Result<T, SGEntitlementRequestError> {
        var url = self.configuration.baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = self.configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let idempotencyKey {
            request.setValue(String(idempotencyKey.prefix(120)), forHTTPHeaderField: "Idempotency-Key")
        }
        // Credentials are built per attempt (every retry gets a fresh nonce, timestamp and proof),
        // and BEFORE the body is serialised: an anonymous proof adds `device_pubkey` to it. The one
        // exception, `bindAttest`, carries its body already serialised and signs those bytes, which
        // are then sent unchanged (`signedBody`).
        var body = body
        var signedBody: Data?
        switch auth {
        case .none:
            break
        case let .pollToken(token, registeredPublicKey):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Decided per attempt, before anything is sent (`prepareBindPoll`): proven with the
            // registered key; a KNOWN different key never polls (the session would belong to a key
            // this install cannot sign with) and restarts the bind; an unavailable key retries; only
            // a start with no registered key at all (legacy) polls proofless.
            let identity = self.identity
            let timestamp = self.clock.transmitTimestamp()
            let preparation = SGEntitlementDeviceProof.prepareBindPoll(
                registeredPublicKey: registeredPublicKey,
                currentPublicKey: identity.publicKeySPKIBase64(),
                makeMaterial: { identity.proofMaterial(mode: .bindMerge, payload: token, timestamp: timestamp, includeDeviceAuth: false) }
            )
            switch preparation {
            case let .prove(headers):
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            case .proofless:
                break
            case .restartBind:
                return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: SGEntitlementClient.bindKeyChangedMarker))
            case .retryLater:
                return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "cannot sign bind proof; poll not sent"))
            }
        case let .bindAttest(registeredPublicKey, rawBody):
            let payload = SGEntitlementDeviceProof.payload(forRawBody: rawBody)
            let identity = self.identity
            let timestamp = self.clock.transmitTimestamp()
            let preparation = SGEntitlementDeviceProof.prepareBindPoll(
                registeredPublicKey: registeredPublicKey,
                currentPublicKey: identity.publicKeySPKIBase64(),
                makeMaterial: { identity.proofMaterial(mode: .bindAttest, payload: payload, timestamp: timestamp, includeDeviceAuth: false) }
            )
            guard case let .prove(headers) = preparation else {
                // The proof is mandatory here: no registered key, a key change or a signing failure
                // sends nothing, and the caller falls back to the code flow.
                return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "cannot sign bind attest proof; attest not sent"))
            }
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            signedBody = rawBody
        case let .anonymous(proofPayload):
            // Key and proof together or nothing (`anonymousAttachCredentials`). A signing failure is a
            // transient failure — the transaction stays unfinished in the outbox and retries — never a
            // downgrade to the legacy unsigned anonymous form.
            let material = self.identity.proofMaterial(mode: .appleOrphan, payload: proofPayload, timestamp: self.clock.transmitTimestamp(), includeDeviceAuth: false)
            guard let credentials = SGEntitlementDeviceProof.anonymousAttachCredentials(material) else {
                return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "cannot sign orphan proof"))
            }
            for (key, value) in credentials.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            body?["device_pubkey"] = credentials.devicePubkey
        case let .device(credential, proof):
            request.setValue("Bearer \(credential.refreshToken)", forHTTPHeaderField: "Authorization")
            if let proof {
                // One nonce/ts for DeviceAuth AND the proof, both from the same key.
                guard let material = self.identity.proofMaterial(mode: proof.mode, payload: proof.payload, timestamp: self.clock.transmitTimestamp(), includeDeviceAuth: true) else {
                    return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "cannot sign"))
                }
                for (key, value) in material.headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            } else {
                guard let credentials = self.identity.credentials(timestamp: self.clock.transmitTimestamp()) else {
                    return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "cannot sign"))
                }
                for (key, value) in credentials.headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
        }

        if let signedBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = signedBody
        } else if let body {
            // Load-bearing: the auth middleware reads body credentials via `isJson() ? json() : post()`,
            // so a JSON body sent without the JSON content type is invisible to it.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
                return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "bad body"))
            }
            request.httpBody = data
        }

        let transport = await self.send(request)
        switch transport {
        case let .failure(failure):
            return .failure(SGEntitlementRequestError(failure: failure))
        case let .success(payload):
            return self.decode(payload)
        }
    }

    private struct TransportPayload {
        let status: Int
        let data: Data
        let retryAfterHeader: Int?
    }

    private func send(_ request: URLRequest) async -> Result<TransportPayload, SGEntitlementFailureClass> {
        let session = self.session
        return await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    let code = (error as? URLError)?.code ?? URLError.Code.unknown
                    continuation.resume(returning: .failure(SGEntitlementFailureMapping.classify(urlErrorCode: code)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(returning: .failure(.offline(.malformedResponse)))
                    return
                }
                var retryAfter: Int?
                if let header = http.value(forHTTPHeaderField: "Retry-After") {
                    retryAfter = Int(header.trimmingCharacters(in: .whitespaces))
                }
                continuation.resume(returning: .success(TransportPayload(status: http.statusCode, data: data ?? Data(), retryAfterHeader: retryAfter)))
            }
            task.resume()
        }
    }

    private func decode<T: Decodable>(_ payload: TransportPayload) -> Result<T, SGEntitlementRequestError> {
        let object = try? JSONSerialization.jsonObject(with: payload.data, options: [])
        let dictionary = object as? [String: Any]

        // `server_time` is on EVERY response, success and error alike, and is read from the BODY:
        // the `X-Server-Time` header can be missing on framework-rendered errors. Feed it to the
        // high-water mark before anything else, so even a 500 advances the clock.
        var serverTime: Date?
        if let raw = dictionary?["server_time"] as? String, let parsed = SGEntitlementTimestamp.parse(raw) {
            serverTime = parsed
            self.clock.note(serverTime: parsed)
        }

        guard (200 ..< 300).contains(payload.status) else {
            let code = (dictionary?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let message = dictionary?["message"] as? String
            let reason = (dictionary?["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let retryAfter = (dictionary?["retry_after"] as? NSNumber)?.intValue ?? payload.retryAfterHeader
            let failure = SGEntitlementFailureMapping.classify(status: payload.status, code: code, retryAfter: retryAfter)
            return .failure(SGEntitlementRequestError(
                failure: failure,
                message: message,
                serverTime: serverTime,
                retryAfter: retryAfter,
                status: payload.status,
                code: code,
                reason: reason,
                responseBody: SGEntitlementRequestError.boundedResponseBody(payload.data)
            ))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(T.self, from: payload.data) else {
            // A 2xx we cannot read is "offline", never "unsubscribed".
            return .failure(SGEntitlementRequestError(failure: .offline(.malformedResponse), serverTime: serverTime))
        }
        return .success(decoded)
    }
}

extension SGEntitlementPolicyEndpoint {
    /// The policy endpoint of a build with no explicit public policy configuration: the
    /// authenticated base URL plus `/monetization`, exactly as before. Only the URL, the timeout and
    /// the test origin are taken from the configuration — never the client instance.
    static func legacy(_ configuration: SGEntitlementClient.Configuration) -> SGEntitlementPolicyEndpoint {
        return SGEntitlementPolicyEndpoint.legacy(baseURL: configuration.baseURL, timeout: configuration.timeout, protocolClasses: configuration.protocolClasses)
    }

    /// The app-update policy endpoint of the same build: the authenticated base URL plus
    /// `/app-policy`, derived exactly like `legacy(_:)`.
    static func legacyAppPolicy(_ configuration: SGEntitlementClient.Configuration) -> SGEntitlementPolicyEndpoint {
        return SGEntitlementPolicyEndpoint.legacyAppPolicy(baseURL: configuration.baseURL, timeout: configuration.timeout, protocolClasses: configuration.protocolClasses)
    }
}

// MARK: - Wire envelopes

private struct SGEntitlementOkEnvelope: Decodable {
    let ok: Bool?
}

private struct SGEntitlementRefreshEnvelope: Decodable {
    let entitlement: String
    let refreshToken: String
    let expiresAt: String?
    let until: String?
}

private struct SGEntitlementBindPollEnvelope: Decodable {
    let state: String
    let refreshToken: String?
    let entitlement: String?
    let account: SGEntitlementBindAccount?
    let device: SGEntitlementBindDevice?
    let mergeConflict: Bool?

    var resolved: SGEntitlementBindPollResult {
        switch self.state {
        case "confirmed":
            // A "confirmed" with no material is the lost-material case, not a success.
            guard let refreshToken = self.refreshToken, let entitlement = self.entitlement else {
                return .consumed
            }
            return .confirmed(SGEntitlementBindConfirmation(
                refreshToken: refreshToken,
                entitlement: entitlement,
                account: self.account,
                device: self.device,
                mergeConflict: self.mergeConflict
            ))
        case "denied":
            return .denied
        case "expired":
            return .expired
        case "consumed":
            return .consumed
        default:
            return .pending
        }
    }
}

/// Zenlygram — the entitlement client session's only delegate behavior: every HTTP redirect is
/// refused, so the 3xx response is delivered as the answer (and classified like any other status).
private final class SGEntitlementRedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
