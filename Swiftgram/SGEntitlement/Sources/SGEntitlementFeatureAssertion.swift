import Foundation

/// Zenlygram — a one-time assertion that a separate first-party service accepts as proof of the
/// Telegram account linked on this device.
///
/// Backend contract (the server must implement it exactly like this):
///
///     POST /v1/assertions            auth: device (Bearer refresh token + X-Device-Id/Nonce/Ts/Sig)
///     body:    {"audience": "<service audience>"}
///     200:     {"assertion": "<compact JWS>", "expires_at": "<RFC 3339>"}
///     errors:  the usual DeviceAuth 401 family; 403 for an unbound session; 422 for an audience
///              the server does not issue for.
///
/// The JWS is ES256, `aud` = the requested audience, carries the bound Telegram user id and a
/// single-use `jti`, has a short lifetime and is never a subscription token (`typ` is not "JWT").
/// The relying service verifies it with this server's published JWKS; the two servers never talk to
/// each other directly. Nothing here is cached or stored: every call mints a fresh assertion.
public struct SGEntitlementFeatureAssertion: Equatable, Decodable {
    public let assertion: String
    public let expiresAt: String?
}

extension SGEntitlement {
    /// A fresh single-use assertion for `audience`, minted for the Telegram account
    /// `accountPeerId` (`PeerId.toInt64()`) through that account's own linked session.
    ///
    /// Waits behind any refresh-token rotation of the same account (the shared account gate), so the
    /// request never presents a token a rotation already replaced. Session failures are applied to
    /// the session that made the request (`apply(_:credential:)`). An account with no binding answers
    /// `.session(.unauthenticated)` with the message "not linked" and sends nothing.
    public func featureAssertion(audience: String, accountPeerId: Int64) async -> Result<String, SGEntitlementRequestError> {
        guard !SGEntitlement.isAppExtension, let client = self.client else {
            return .failure(SGEntitlementRequestError(failure: .offline(.unknown), message: "no endpoint configured"))
        }
        return await self.featureAssertion(audience: audience, accountPeerId: accountPeerId, client: client)
    }

    /// The exchange itself on `client` — the configured one in the app; tests pass a client bound to
    /// a scripted origin and to this instance's own store and identity.
    func featureAssertion(audience: String, accountPeerId: Int64, client: SGEntitlementClient) async -> Result<String, SGEntitlementRequestError> {
        await client.accountGate.acquire(accountPeerId: accountPeerId)
        guard let credential = self.sessionCredential(accountPeerId: accountPeerId) else {
            client.accountGate.release(accountPeerId: accountPeerId)
            return .failure(SGEntitlementRequestError(failure: .session(.unauthenticated), message: "not linked"))
        }
        let result = await client.featureAssertion(credential: credential, audience: audience)
        client.accountGate.release(accountPeerId: accountPeerId)
        switch result {
        case let .success(answer):
            return .success(answer.assertion)
        case let .failure(error):
            self.apply(error, credential: credential)
            return .failure(error)
        }
    }
}
