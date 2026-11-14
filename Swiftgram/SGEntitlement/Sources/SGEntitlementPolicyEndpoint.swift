import Foundation

/// Zenlygram — where a signed public policy is fetched from, and the one anonymous GET that fetches
/// it: the monetization policy (`SGEntitlementPolicy`, `GET /v1/monetization`) and the app-update
/// policy (`SGAppUpdatePolicy`, `GET /v1/app-policy`) of the same origin, each an endpoint of its own
/// with its own `Accept`.
///
/// Deliberately NOT the entitlement client: it holds a URL, a timeout, the `Accept` it declares and
/// (tests only) a scripted `URLProtocol` origin — no store, no device identity, no clock and no
/// session. The request carries no `Authorization`, no device id, no nonce or proof (a policy names
/// no one and grants nothing, so nothing identifying is sent); no redirect is followed and no cookie
/// or URL cache is used; the body is bounded WHILE it arrives (`SGEntitlementBoundedFetch`), the
/// request idles out after `timeout` and the whole exchange is capped at twice that; and the
/// response's unsigned `server_time` is never read — only the signed `iat` / `exp`, checked by the
/// caller against the policy clock, decide anything.
///
/// Foundation only, so it runs on the host (`Tests/run-policy-core-tests.sh`).
public struct SGEntitlementPolicyEndpoint {
    /// The contracts' response ceiling, for `GET /v1/monetization` and `GET /v1/app-policy` alike.
    static let responseLimit = 16384
    /// The only path an explicitly configured policy endpoint (`sg_config.public_policy_url`) may
    /// name. The app-update endpoint is never configured: it is derived from that endpoint's origin.
    static let path = "/v1/monetization"
    /// The app-update policy's path on the same origin (`appPolicy(origin:)`).
    static let appPolicyPath = "/v1/app-policy"
    /// What this build can read of the monetization policy, in order of preference: the v2 claim
    /// shape (`trial_days`) by its exact vendor media type, then the frozen v1 shape. The server
    /// mints v2 ONLY for a request that lists that exact type with a non-zero q — never for
    /// `application/json`, `*/*` or `application/*+json` — so a client is never sent a shape it did
    /// not declare, and the verifier (`SGEntitlementPolicyVerifier`) refuses every other one.
    static let monetizationAccept = "application/vnd.zenlygram.monetization.v2+json, application/json;q=0.9"
    /// What this build can read of the app-update policy: its v1 shape by the exact vendor type,
    /// then plain JSON (which the server answers with v1 as well). A future shape is a new vendor
    /// type, never sent to a client that did not declare it; `SGAppUpdatePolicyVerifier` refuses
    /// every other one.
    static let appPolicyAccept = "application/vnd.zenlygram.app-policy.v1+json, application/json;q=0.9"

    public let url: URL
    public let timeout: TimeInterval
    /// The `Accept` this endpoint declares: `monetizationAccept` or `appPolicyAccept`. The server
    /// mints the shape the client declared, so the header names exactly what the matching verifier
    /// reads.
    public let accept: String
    /// Tests only: a scripted `URLProtocol` origin. nil in the app.
    let protocolClasses: [AnyClass]?

    private init(unchecked url: URL, timeout: TimeInterval, accept: String, protocolClasses: [AnyClass]?) {
        self.url = url
        self.timeout = timeout
        self.accept = accept
        self.protocolClasses = protocolClasses
    }

    /// An explicitly configured endpoint (`sg_config.public_policy_url`): exactly
    /// `https://host[:port]/v1/monetization`, with no userinfo, no query and no fragment. Anything
    /// else is no endpoint at all.
    public init?(url: URL, timeout: TimeInterval = 5.0) {
        self.init(url: url, timeout: timeout, protocolClasses: nil)
    }

    init?(url: URL, timeout: TimeInterval = 5.0, protocolClasses: [AnyClass]?) {
        guard SGEntitlementPolicyEndpoint.origin(of: url) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == SGEntitlementPolicyEndpoint.path
        else {
            return nil
        }
        self.init(unchecked: url, timeout: timeout, accept: SGEntitlementPolicyEndpoint.monetizationAccept, protocolClasses: protocolClasses)
    }

    /// The endpoint an authenticated build has always used: `{api_url}/v1/monetization`, derived from
    /// the entitlement client's base URL exactly as before, with no new validation — a build without
    /// an explicit public endpoint keeps its behavior.
    static func legacy(baseURL: URL, timeout: TimeInterval, protocolClasses: [AnyClass]?) -> SGEntitlementPolicyEndpoint {
        return SGEntitlementPolicyEndpoint(unchecked: baseURL.appendingPathComponent("monetization"), timeout: timeout, accept: SGEntitlementPolicyEndpoint.monetizationAccept, protocolClasses: protocolClasses)
    }

    /// The app-update policy endpoint of a canonical HTTPS origin (`origin(of:)`'s form,
    /// `https://host[:port]`): exactly `https://host[:port]/v1/app-policy`, no query, no fragment,
    /// declaring `appPolicyAccept`. nil for anything that is not such an origin — a URL with a path,
    /// userinfo, a query, another scheme or a non-canonical spelling. The configured public URL
    /// itself keeps its `/v1/monetization`-only rule: the app-update endpoint is derived from its
    /// ORIGIN, never configured on its own.
    static func appPolicy(origin: String, timeout: TimeInterval = 5.0, protocolClasses: [AnyClass]? = nil) -> SGEntitlementPolicyEndpoint? {
        guard let originURL = URL(string: origin), SGEntitlementPolicyEndpoint.origin(of: originURL) == origin,
              var components = URLComponents(url: originURL, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.isEmpty
        else {
            return nil
        }
        components.percentEncodedPath = SGEntitlementPolicyEndpoint.appPolicyPath
        guard let url = components.url, SGEntitlementPolicyEndpoint.origin(of: url) == origin else {
            return nil
        }
        return SGEntitlementPolicyEndpoint(unchecked: url, timeout: timeout, accept: SGEntitlementPolicyEndpoint.appPolicyAccept, protocolClasses: protocolClasses)
    }

    /// The app-update policy endpoint of a build without an explicit public policy:
    /// `{api_url}/v1/app-policy`, beside `legacy(baseURL:)`'s `{api_url}/v1/monetization`, derived
    /// the same way with no new validation.
    static func legacyAppPolicy(baseURL: URL, timeout: TimeInterval, protocolClasses: [AnyClass]?) -> SGEntitlementPolicyEndpoint {
        return SGEntitlementPolicyEndpoint(unchecked: baseURL.appendingPathComponent("app-policy"), timeout: timeout, accept: SGEntitlementPolicyEndpoint.appPolicyAccept, protocolClasses: protocolClasses)
    }

    /// The canonical HTTPS origin, `https://host` or `https://host:port` for a non-default port —
    /// what the accepted policy's cache is scoped by. nil for a configured endpoint that never
    /// validates.
    public var origin: String? {
        return SGEntitlementPolicyEndpoint.origin(of: self.url)
    }

    /// `https://` + lowercased host (+ `:port` unless 443), or nil for anything that is not a plain
    /// HTTPS URL without userinfo, query or fragment.
    static func origin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.percentEncodedQuery == nil, components.percentEncodedFragment == nil
        else {
            return nil
        }
        let host = rawHost.lowercased()
        let printableHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = components.port, port != 443 {
            return "https://\(printableHost):\(port)"
        }
        return "https://\(printableHost)"
    }

    /// `GET` the policy. Returns the compact JWS, unverified.
    public func fetch() async -> Result<String, SGEntitlementRequestError> {
        var request = URLRequest(url: self.url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(self.accept, forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let payload = await SGEntitlementBoundedFetch.perform(request, timeout: self.timeout, limit: SGEntitlementPolicyEndpoint.responseLimit, protocolClasses: self.protocolClasses)
        switch payload {
        case let .failure(failure):
            return .failure(SGEntitlementRequestError(failure: failure))
        case let .success((status, data)):
            let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            guard (200 ..< 300).contains(status) else {
                let code = object?["error"] as? String
                let retryAfter = (object?["retry_after"] as? NSNumber)?.intValue
                return .failure(SGEntitlementRequestError(failure: SGEntitlementFailureMapping.classify(status: status, code: code, retryAfter: retryAfter), message: object?["message"] as? String, retryAfter: retryAfter))
            }
            guard let token = object?["policy_token"] as? String else {
                return .failure(SGEntitlementRequestError(failure: .offline(.malformedResponse)))
            }
            return .success(token)
        }
    }
}

/// Zenlygram — the explicit public-policy configuration (`sg_config.public_policy_url` /
/// `public_policy_keys`), separate from every authenticated entitlement input.
///
/// Its key ring verifies exactly the two public policies of that origin — the monetization policy
/// (`SGEntitlementPolicyVerifier`, `aud: zenlygram-monetization`) and the app-update policy
/// (`SGAppUpdatePolicyVerifier`, `aud: zenlygram-app-policy`), each verifier refusing the other's
/// audience — and nothing else: it never verifies an entitlement token, never becomes the
/// entitlement's pinned keys, never makes the build "enforcing" and never feeds the Apple trust
/// domain. There is no fallback to `entitlement_keys` or `public_key` — a build that names a public
/// endpoint names its keys too, or has no public policy at all.
public struct SGEntitlementPublicPolicyConfiguration {
    /// `GET /v1/monetization`, as configured.
    public let endpoint: SGEntitlementPolicyEndpoint
    /// `GET /v1/app-policy` on the same origin, derived (`SGEntitlementPolicyEndpoint.appPolicy`),
    /// with the configured endpoint's timeout and test origin.
    public let appPolicyEndpoint: SGEntitlementPolicyEndpoint
    /// `kid` -> PEM or base64 SPKI DER, policy verification only.
    public let pinnedKeys: SGEntitlementPinnedKeys
    /// The canonical HTTPS origin both accepted policies' caches are scoped by.
    public let origin: String

    /// nil unless the endpoint validates and EVERY key parses as P-256 (at least one): a ring with a
    /// damaged key is a misconfiguration, never a partial trust anchor.
    public init?(endpoint: SGEntitlementPolicyEndpoint, keysByKid: [String: String]) {
        guard let origin = endpoint.origin,
              let appPolicyEndpoint = SGEntitlementPolicyEndpoint.appPolicy(origin: origin, timeout: endpoint.timeout, protocolClasses: endpoint.protocolClasses),
              !keysByKid.isEmpty,
              keysByKid.allSatisfy({ !$0.key.isEmpty && SGEntitlementCrypto.p256X963(fromPinnedKey: $0.value) != nil })
        else {
            return nil
        }
        self.endpoint = endpoint
        self.appPolicyEndpoint = appPolicyEndpoint
        self.pinnedKeys = SGEntitlementPinnedKeys(keysByKid: keysByKid, fallbackKey: nil)
        self.origin = origin
    }
}

extension SGEntitlementPolicyTransport {
    /// The live anonymous GET against `endpoint`.
    static func live(_ endpoint: SGEntitlementPolicyEndpoint) -> SGEntitlementPolicyTransport {
        return SGEntitlementPolicyTransport(fetch: {
            return await endpoint.fetch()
        })
    }
}
