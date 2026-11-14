import Foundation

/// Zenlygram — the customer-data backend (consents, profile sync, "My data", events, account
/// deletion), as named account-bound calls (`SGCustomerDataTransport`), plus the per-binding
/// receipts and records the main app's consent pipeline keeps with the session.
///
/// Main app only: in an extension (`isExtensionProcess`) every call answers `.notConfigured` and
/// sends nothing, and every value below is nil. `accountPeerId` is the same `PeerId.toInt64()` every
/// other `SGEntitlement` API takes; the session a call runs under is the account's current binding,
/// captured at send. Bodies are the caller's: nothing here builds, decodes or logs one.
extension SGEntitlement {
    public enum CustomerDataFailure: Error, Equatable {
        /// An extension, or a build without the authenticated backend (or before `configure(...)`).
        /// Nothing was sent.
        case notConfigured
        /// The account holds no session. Nothing was sent.
        case notLinked
        /// The account's session changed (rotation, logout, re-bind) while the call waited or was in
        /// flight: its answer was discarded. Calling again uses the current session.
        case credentialChanged
        /// The caller's `stillWanted` answered false when the call's turn came (the account's gate
        /// held, an attempt about to be signed): nothing was signed or sent. Not a failure of the
        /// route.
        case notWanted
        /// A non-2xx answer (`status`, `code`, `reason`, `responseBody`), a transport failure or a
        /// local refusal. A 401 of the DeviceAuth family was already applied (`apply`) to the exact
        /// session the call presented.
        case request(SGEntitlementRequestError)
    }

    /// Sends `body` (exact bytes; nil for `profileMe`) on `route` under the account's CURRENT session
    /// and answers the 2xx body undecoded. `idempotencyKey` is sent only for `accountDelete`.
    ///
    /// `stillWanted` is the caller's own condition for sending at all (nil: none). The call can wait
    /// in the account's gate behind a token rotation, a Tasks attempt or another customer-data call,
    /// so the condition is asked again once the gate is held, right before each attempt is signed;
    /// false ends the call as `.notWanted`. It is never the task's cancellation, which aborts a
    /// request already on the wire.
    public func customerData(_ route: SGEntitlementCustomerDataRoute, body: Data?, accountPeerId: Int64, idempotencyKey: String? = nil, stillWanted: (() -> Bool)? = nil) async -> Result<Data, CustomerDataFailure> {
        guard let client = self.customerDataClient() else {
            return .failure(.notConfigured)
        }
        guard self.sessionCredential(accountPeerId: accountPeerId) != nil else {
            return .failure(.notLinked)
        }
        let transport = await self.customerDataTransport(client: client)
        return await transport.send(route, body: body, accountPeerId: accountPeerId, idempotencyKey: idempotencyKey, stillWanted: stillWanted)
    }

    /// The backend authority customer-data keys are scoped to (`SGEntitlementStoreScope.identifier`),
    /// or nil in a build without the authenticated backend or in an extension. A build constant:
    /// correct before `configure(...)`.
    public var customerDataAuthority: String? {
        guard !self.isExtensionProcess, case .origin = self.sessionStore.scope else {
            return nil
        }
        return self.sessionStore.scope.identifier
    }

    /// `customerDataAuthority`'s path-safe, opaque form (`SGEntitlementStoreScope.storageToken`), for
    /// directory names.
    public var customerDataStorageToken: String? {
        guard !self.isExtensionProcess, case .origin = self.sessionStore.scope else {
            return nil
        }
        return self.sessionStore.scope.storageToken
    }

    /// Records that the binding `credential` presented delivered the profile snapshot `digest` at
    /// `at`. Written only while that session is still the account's stored one: false — nothing
    /// written — after a logout, a re-bind, a rotation or a server drop.
    @discardableResult
    public func recordProfileSync(accountPeerId: Int64, credential: SGEntitlementSessionCredential, digest: String, at: Date) -> Bool {
        guard !self.isExtensionProcess, credential.accountPeerId == accountPeerId, !credential.refreshToken.isEmpty else {
            return false
        }
        let stored = self.sessionStore.updateSession(accountPeerId: accountPeerId, if: { $0.refreshToken == credential.refreshToken }, { material in
            material.profileSyncDigest = digest
            material.profileSyncedAt = at
        })
        if case .success = stored {
            return true
        }
        return false
    }

    /// The account's profile receipt (`recordProfileSync`), or nil.
    public func profileSyncReceipt(accountPeerId: Int64) -> (digest: String, at: Date)? {
        guard !self.isExtensionProcess else {
            return nil
        }
        let material = self.session(accountPeerId: accountPeerId)
        guard let digest = material.profileSyncDigest, let at = material.profileSyncedAt else {
            return nil
        }
        return (digest, at)
    }

    /// Forgets the account's profile receipt (consent withdrawn): the next sync sends the whole
    /// snapshot again. Writes nothing when there is none.
    public func clearProfileSyncReceipt(accountPeerId: Int64) {
        guard !self.isExtensionProcess else {
            return
        }
        let material = self.session(accountPeerId: accountPeerId)
        guard material.profileSyncDigest != nil || material.profileSyncedAt != nil else {
            return
        }
        self.sessionStore.updateSession(accountPeerId: accountPeerId) { material in
            material.profileSyncDigest = nil
            material.profileSyncedAt = nil
        }
    }

    /// How the server ended the account's last binding, if it did (`SGEntitlementSessionEnd`).
    public func sessionEnd(accountPeerId: Int64) -> SGEntitlementSessionEnd? {
        guard !self.isExtensionProcess else {
            return nil
        }
        return self.session(accountPeerId: accountPeerId).sessionEnd
    }

    /// What `bindPermissionProvider` answers for the account — `.allowed` while none is installed.
    public func bindPermission(accountPeerId: Int64) -> SGEntitlementBindPermission {
        guard let provider = self.bindPermissionProvider else {
            return .allowed
        }
        return provider(accountPeerId)
    }

    /// The `consent` a `/bind/start` for the account carries: the provider's grant, and only while
    /// the permission is `.allowed` — a `.codeOnly` account never even asks for one.
    static func bindConsent(permission: SGEntitlementBindPermission, provider: ((Int64) -> [String: Any]?)?, accountPeerId: Int64) -> [String: Any]? {
        guard case .allowed = permission, let provider else {
            return nil
        }
        return provider(accountPeerId)
    }

    /// Whether a `/bind/start` of `purpose` may go out under `permission`: never while `.refused`;
    /// the automatic link only while `.allowed` (C§6.6); the manual code flow also while `.codeOnly`.
    static func permitsStart(_ permission: SGEntitlementBindPermission, purpose: SGEntitlementBindPurpose) -> Bool {
        switch permission {
        case .allowed:
            return true
        case .codeOnly:
            return purpose == .manual
        case .refused:
            return false
        }
    }

    /// `beginBind`'s local refusal (`consentRequiredLocalCode`): nothing was sent.
    static func consentRequiredLocalRefusal() -> SGEntitlementRequestError {
        return SGEntitlementRequestError(
            failure: .unknownRefusal(code: SGEntitlement.consentRequiredLocalCode, status: 0),
            message: "consent required on this device; bind/start not sent",
            code: SGEntitlement.consentRequiredLocalCode
        )
    }

    /// `beginBind`'s local refusal when its attempt is no longer the account's current one by the
    /// time a `/bind/start` would go out (`bindSupersededLocalCode`): a newer start, a logout of the
    /// account or a stored bind took over while it waited. Nothing was sent, so it never expires the
    /// newer attempt's pending bind on the server, which keeps one pending bind per device.
    static func bindSupersededLocalRefusal() -> SGEntitlementRequestError {
        return SGEntitlementRequestError(
            failure: .unknownRefusal(code: SGEntitlement.bindSupersededLocalCode, status: 0),
            message: "a newer bind attempt took over; bind/start not sent",
            code: SGEntitlement.bindSupersededLocalCode
        )
    }

    /// `/bind/start` with the account's consent, and the fallbacks the contract allows (C§2.1,
    /// amendment A3), each ONCE and in the same attempt:
    /// - 422 `invalid_consent` (the consent object was malformed): `refused(consent_id)`, then the same
    ///   start without `consent` — for both purposes; the grant still reaches `/v1/profile/consents`
    ///   after the link. `mayRetry` is asked first, before `refused`, so its answer never depends on
    ///   what the refusal hook records: false (`beginBind`: a consent withdrawn while an automatic
    ///   start was in flight) still reports the refused consent, sends nothing more and answers the
    ///   local refusal (`consentRequiredLocalCode`).
    /// - 409 `consent_stale` (the consent predates an erasure of this Telegram id): a `.manual` start
    ///   is sent again without `consent`; an `.auto` one returns the failure (the auto-link runner
    ///   stops until a new grant). `mayRetry` is not asked.
    /// Without a consent nothing is retried.
    static func startWithConsentFallback<Start>(
        consent: [String: Any]?,
        purpose: SGEntitlementBindPurpose,
        send: ([String: Any]?) async -> Result<Start, SGEntitlementRequestError>,
        refused: (String) -> Void,
        mayRetry: () -> Bool = { true }
    ) async -> Result<Start, SGEntitlementRequestError> {
        let first = await send(consent)
        guard case let .failure(error) = first, let consent else {
            return first
        }
        switch error.code {
        case .some(SGEntitlement.invalidConsentCode):
            let retries = mayRetry()
            if let consentId = consent["consent_id"] as? String, !consentId.isEmpty {
                refused(consentId)
            }
            guard retries else {
                return .failure(SGEntitlement.consentRequiredLocalRefusal())
            }
            return await send(nil)
        case .some(SGEntitlement.consentStaleCode) where purpose == .manual:
            return await send(nil)
        default:
            return first
        }
    }

    static let invalidConsentCode = "invalid_consent"
    static let consentStaleCode = "consent_stale"
    /// The local refusal of `beginBind` whenever `permitsStart` is false — before the attempt, after
    /// a logout's pending `/bind/revoke`, and before an automatic consent-fallback retry.
    static let consentRequiredLocalCode = "consent_required_local"
    /// The local refusal of `beginBind` when its attempt stopped being current before a send: before
    /// the first `/bind/start` (after a logout's pending `/bind/revoke`) or before a consent-fallback
    /// retry.
    static let bindSupersededLocalCode = "bind_superseded_local"

    // MARK: - Transport

    /// The client customer-data calls may use: the main app's, once `configure(...)` has run.
    func customerDataClient() -> SGEntitlementClient? {
        guard !self.isExtensionProcess else {
            return nil
        }
        return self.client
    }

    func customerDataTransport(client: SGEntitlementClient) async -> SGCustomerDataTransport {
        let endpoint = await client.tasksEndpoint()
        let parts = self.tasksTransportParts
        let protocolClasses = endpoint.protocolClasses
        return SGCustomerDataTransport(environment: SGCustomerDataTransport.Environment(
            baseURL: endpoint.baseURL,
            timeout: SGCustomerDataTransport.exchangeTimeout,
            gate: client.accountGate,
            storedRefreshToken: { account in
                return parts.store.session(accountPeerId: account).refreshToken
            },
            deviceCredentials: {
                return parts.identity.credentials(timestamp: parts.clock.transmitTimestamp())
            },
            noteServerTime: { serverTime in
                parts.clock.note(serverTime: serverTime)
            },
            adoptServerOffset: { serverTime in
                parts.clock.adoptServerOffset(serverTime: serverTime)
            },
            applySessionFailure: { [weak self] error, credential in
                self?.apply(error, credential: credential)
            },
            fetch: { request, timeout, limit in
                // `SGTasksBoundedExchange`'s timeout is the idle bound; the exchange gets twice it.
                let answer = await SGTasksBoundedExchange.perform(request, timeout: timeout / 2.0, limit: limit, protocolClasses: protocolClasses)
                return answer.map { SGCustomerDataTransport.HTTPAnswer(status: $0.status, body: $0.body, retryAfter: $0.retryAfter) }
            }
        ))
    }
}
