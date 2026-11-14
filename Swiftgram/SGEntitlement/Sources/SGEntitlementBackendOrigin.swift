import Foundation
import CryptoKit

// MARK: Zenlygram — the authenticated backend origin, the storage scope derived from it, and the single
// Apple predicate. Pure (Foundation + CryptoKit, no `SG_CONFIG`): the shipped values live in
// `SGEntitlementShippedConfiguration.swift`, and these run on the host
// (`Tests/run-backend-origin-tests.sh`).

/// The authenticated entitlement backend a build ships: the canonical root `https://host[:port]` of
/// `sg_config.api_url`, with the `/v1` prefix appended.
///
/// Only that root is accepted (trailing slashes aside). HTTP, userinfo, a query, a fragment, any path,
/// a malformed or non-canonical port, a host that is not a plain DNS name or a canonical IPv4 dotted
/// quad, and upstream Swiftgram's default host are all refused — a refused value means "no
/// authenticated backend", never a guess.
///
/// `authority` is the lowercased host plus the port exactly as written (an explicit `:443` included):
/// the same string `SGEntitlement.appleTrustDomain` has always derived from the base URL, so the Apple
/// provenance ledger keeps its domain, and the namespace every origin-bound store is scoped by.
public struct SGEntitlementBackendOrigin: Equatable, Hashable {
    /// `host` or `host:port`.
    public let authority: String
    /// `https://{authority}/v1`.
    public let baseURL: URL

    private static let maximumHostLength = 253
    private static let maximumLabelLength = 63
    private static let portRange = 1 ... 65535

    public init?(apiUrl raw: String, upstreamDefaultApiUrl: String) {
        var value = raw
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard let separator = value.range(of: "://"), value[..<separator.lowerBound].lowercased() == "https" else {
            return nil
        }
        guard let parsed = SGEntitlementBackendOrigin.parseAuthority(String(value[separator.upperBound...])) else {
            return nil
        }
        if let upstream = URL(string: upstreamDefaultApiUrl)?.host?.lowercased(), parsed.host == upstream {
            // Upstream Swiftgram's API host: reaching it means `api_url` was left out of `sg_config`.
            return nil
        }
        let authority = parsed.port.map { "\(parsed.host):\($0)" } ?? parsed.host
        guard let baseURL = URL(string: "https://\(authority)/v1") else {
            return nil
        }
        self.authority = authority
        self.baseURL = baseURL
    }

    /// `host[:port]` with the host lowercased, or nil for anything but LDH labels (or IPv4 digits)
    /// and an optional canonical decimal port.
    private static func parseAuthority(_ raw: String) -> (host: String, port: String?)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else {
            return nil
        }
        let host = parts[0].lowercased()
        guard self.isHostName(host) else {
            return nil
        }
        guard parts.count == 2 else {
            return (host, nil)
        }
        let port = String(parts[1])
        guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }), !port.hasPrefix("0"), let number = Int(port), self.portRange.contains(number) else {
            return nil
        }
        return (host, port)
    }

    /// LDH labels, or — when the last label starts with a digit, which the resolver (`inet_aton`)
    /// reads as an IPv4 literal in shorthand, decimal, octal and hex forms too — exactly the canonical
    /// dotted quad, so one server cannot sit under several authorities. Private and loopback quads are
    /// a build-time choice and stay accepted.
    private static func isHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= self.maximumHostLength else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if let last = labels.last, let first = last.first, first.isASCII, first.isNumber {
            return labels.count == 4 && labels.allSatisfy(self.isCanonicalOctet)
        }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= self.maximumLabelLength, label.first != "-", label.last != "-" else {
                return false
            }
            return label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    /// `0`...`255` in decimal, no sign and no leading zero.
    private static func isCanonicalOctet(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 3, label.allSatisfy({ $0.isASCII && $0.isNumber }), label == "0" || label.first != "0", let value = Int(label) else {
            return false
        }
        return value <= 255
    }
}

/// Zenlygram — the namespace of every ORIGIN-BOUND item (sessions, device id and keys, the Apple
/// outbox, the trial ledger, the extension mirror, the Tasks cloud store): `base@identifier`.
///
/// A build for a new backend origin starts fresh under its own names and never reads, copies,
/// rewrites or deletes another origin's items or the bare pre-origin (`.com`-era) ones. The clock
/// high-water mark and the local grace record are per INSTALL and are never scoped.
public enum SGEntitlementStoreScope: Equatable, Hashable {
    /// No authenticated backend in this build. `!` never occurs in a host, so this can never collide
    /// with an origin (not even a host literally named `unconfigured`).
    case unconfigured
    case origin(SGEntitlementBackendOrigin)

    private static let unconfiguredIdentifier = "!unconfigured"

    /// The origin's authority, or `!unconfigured`.
    public var identifier: String {
        switch self {
        case .unconfigured:
            return SGEntitlementStoreScope.unconfiguredIdentifier
        case let .origin(origin):
            return origin.authority
        }
    }

    /// `base@identifier` — never the bare `base`.
    public func scopedKey(_ base: String) -> String {
        return "\(base)@\(self.identifier)"
    }

    /// Lowercase hex SHA-256 of `identifier`: an opaque, path-safe name for a directory that must
    /// neither reveal nor be parsed as the origin.
    public var storageToken: String {
        return SHA256.hash(data: Data(self.identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Zenlygram — the single Apple predicate. Apple work — the `Transaction.updates` listener, snapshot
/// refresh, provenance re-read, outbox drain and delivery, Restore, products and purchase — and the
/// StoreKit FALLBACK grant run only when the build EXPLICITLY sets `apple_backend_enabled`, ships the
/// authenticated configuration and a product list, and is not public-policy-only. An authenticated
/// build with a product list but no flag is held: neither is activation authority on its own.
public struct SGEntitlementAppleBackendConfiguration: Equatable {
    /// `sg_config.apple_backend_enabled`.
    public let isFlagEnabled: Bool
    /// `sg_config.iaps`.
    public let productIds: [String]

    public init(isFlagEnabled: Bool, productIds: [String]) {
        self.isFlagEnabled = isFlagEnabled
        self.productIds = productIds
    }

    /// Never enabled, whatever else the build ships. Test instances default to it.
    public static let held = SGEntitlementAppleBackendConfiguration(isFlagEnabled: false, productIds: [])

    /// An empty list, or one with an empty id, is a misconfiguration and holds.
    public func isEnabled(isAuthenticatedEntitlementConfigured: Bool, isPublicPolicyOnly: Bool) -> Bool {
        guard self.isFlagEnabled, isAuthenticatedEntitlementConfigured, !isPublicPolicyOnly else {
            return false
        }
        return !self.productIds.isEmpty && self.productIds.allSatisfy { !$0.isEmpty }
    }
}
