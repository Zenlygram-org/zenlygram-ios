import Foundation

// MARK: Zenlygram — the signed app-update policy (contract `app-update-policy.v1`).
//
// `GET /v1/app-policy` answers ONE question for every install: is this version of the app still
// supported, and is there a newer one? The answer is a JWS signed ES256 on the same pinned ring as
// the monetization policy, for a purpose of its own (`aud: zenlygram-app-policy`), so neither policy
// can ever be read as the other and neither as an entitlement. It carries no identity and grants
// nothing: it names, per platform, the oldest version still supported (`min`) and the newest
// released (`latest`) — or `null`, no constraint.
//
// Rules this file enforces (the contract's `x-signing` / `x-client-state`):
//  - only the exact header and exactly the eight claims `iss, aud, ver: 1, revision, ios, android,
//    iat, exp` authenticate; each platform is `null` or exactly `{min, latest}`, two version strings
//    of the pattern below with `min <= latest`; any other key, type or pattern is refused — a shape
//    this client did not declare (`SGEntitlementPolicyEndpoint.appPolicyAccept`) is never tolerated;
//  - a NEWLY FETCHED policy must be inside its signed window (± 300 s of skew, ≤ 24 h lifetime); a
//    previously accepted one is re-verified on load but never re-expired;
//  - acceptance follows `(revision, iat)` alone: an equal tuple with the same constraints is
//    idempotent, with other constraints a conflict (the accepted policy stands); older is rejected;
//  - the DECISION fails open: nothing accepted, no constraint for this platform or an installed
//    version the pattern cannot read shows nothing. A block (installed below `min`) never outlives
//    30 days without a successful fetch (`SGAppUpdateDecision.blockValve`); a reminder (installed
//    below `latest`) is shown once per distinct `latest`. The build number is never compared.
//
// Foundation only, so it runs on the host (`Tests/run-policy-core-tests.sh`).

/// A release version as the policy names it and as `CFBundleShortVersionString` carries it:
/// `^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$` — two to four numeric components, compared component-wise as
/// integers with missing components read as 0 (`12.9` == `12.9.0`, `12.9.2` < `12.10.0`,
/// `1.2.3.4` > `1.2.3`). Anything else — a `-debug` suffix, a `v` prefix, a build number, a single
/// component — is not a version, and a decision made from one fails open.
public struct SGAppUpdateVersion: Hashable, Comparable, CustomStringConvertible {
    static let minimumComponents = 2
    static let maximumComponents = 4
    static let maximumComponentDigits = 5

    /// The text exactly as signed or as installed.
    public let text: String
    /// Two to four components, as written (no padding).
    public let components: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= SGAppUpdateVersion.minimumComponents, parts.count <= SGAppUpdateVersion.maximumComponents else {
            return nil
        }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.count <= SGAppUpdateVersion.maximumComponentDigits,
                  part.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                  let value = Int(part)
            else {
                return nil
            }
            components.append(value)
        }
        self.text = text
        self.components = components
    }

    /// The components padded with zeros to the maximum: what equality and order are decided on.
    private var padded: [Int] {
        return self.components + Array(repeating: 0, count: SGAppUpdateVersion.maximumComponents - self.components.count)
    }

    public static func == (lhs: SGAppUpdateVersion, rhs: SGAppUpdateVersion) -> Bool {
        return lhs.padded == rhs.padded
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.padded)
    }

    public static func < (lhs: SGAppUpdateVersion, rhs: SGAppUpdateVersion) -> Bool {
        return lhs.padded.lexicographicallyPrecedes(rhs.padded)
    }

    public var description: String {
        return self.text
    }
}

/// One platform's constraint: the oldest version still supported and the newest released,
/// `min <= latest` by construction.
public struct SGAppUpdateVersions: Equatable {
    public let min: SGAppUpdateVersion
    public let latest: SGAppUpdateVersion

    /// nil when `min > latest`: not a constraint the contract allows.
    public init?(min: SGAppUpdateVersion, latest: SGAppUpdateVersion) {
        guard min <= latest else {
            return nil
        }
        self.min = min
        self.latest = latest
    }
}

/// One authenticated app-update policy, with the exact signed bytes it came from.
public struct SGAppUpdatePolicy: Equatable {
    public let revision: Int64
    public let issuedAt: Int64
    public let expiresAt: Int64
    /// nil: no constraint for iOS.
    public let ios: SGAppUpdateVersions?
    /// nil: no constraint for Android. Carried as signed; this client never acts on it.
    public let android: SGAppUpdateVersions?
    /// The compact JWS, persisted and re-verified as is.
    public let token: String

    /// The acceptance order: lexicographic `(revision, iat)`.
    func isOrdered(before other: SGAppUpdatePolicy) -> Bool {
        if self.revision != other.revision {
            return self.revision < other.revision
        }
        return self.issuedAt < other.issuedAt
    }

    func hasSameIssuance(as other: SGAppUpdatePolicy) -> Bool {
        return self.revision == other.revision && self.issuedAt == other.issuedAt
    }

    /// The same platform values (what an equal issuance must agree on).
    func hasSameConstraints(as other: SGAppUpdatePolicy) -> Bool {
        return self.ios == other.ios && self.android == other.android
    }
}

public enum SGAppUpdatePolicyVerifier {
    static let issuer = "zenlygram"
    public static let audience = "zenlygram-app-policy"
    /// The only shape this client declared (`SGEntitlementPolicyEndpoint.appPolicyAccept`): exactly
    /// `claimKeys`. There is no table of tolerated versions.
    static let version: Int64 = 1
    public static let maximumLifetime: Int64 = 86400
    public static let maximumClockSkew: Int64 = 300
    static let maximumRevision: Int64 = 9_007_199_254_740_991

    private static let claimKeys: Set<String> = ["iss", "aud", "ver", "revision", "ios", "android", "iat", "exp"]
    private static let platformKeys: Set<String> = ["min", "latest"]

    /// Authentic (`SGSignedPolicyJWS`), exactly the eight claims, and the policy's purpose. Says
    /// nothing about time: a stored policy is re-verified with this alone.
    public static func authenticate(_ token: String, pinnedKeys: SGEntitlementPinnedKeys) -> Result<SGAppUpdatePolicy, SGEntitlementPolicyFailure> {
        switch SGSignedPolicyJWS.authenticate(token, pinnedKeys: pinnedKeys) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(claims):
            return self.policy(claims: claims, token: token)
        }
    }

    /// `authenticate` plus the signed window, against `now` on the policy clock. Only for a policy
    /// just fetched: the response's own unsigned `server_time` is never consulted.
    public static func verifyFetched(_ token: String, pinnedKeys: SGEntitlementPinnedKeys, now: Date) -> Result<SGAppUpdatePolicy, SGEntitlementPolicyFailure> {
        let authenticated = self.authenticate(token, pinnedKeys: pinnedKeys)
        guard case let .success(policy) = authenticated else {
            return authenticated
        }
        let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
        guard policy.issuedAt <= seconds + self.maximumClockSkew else {
            return .failure(.notYetValid)
        }
        guard policy.expiresAt > seconds - self.maximumClockSkew else {
            return .failure(.expired)
        }
        return .success(policy)
    }

    private static func policy(claims: [String: Any], token: String) -> Result<SGAppUpdatePolicy, SGEntitlementPolicyFailure> {
        // Exactly the eight claims, and `iss` / `aud` / `ver` naming this policy: a claim missing or
        // added, a monetization token (`aud: zenlygram-monetization`, a `mode`), an entitlement,
        // another `ver` — any of them is another purpose. "Unknown claims ignored" would let a shape
        // this client never declared decide whether the app may open.
        guard Set(claims.keys) == self.claimKeys,
              claims["iss"] as? String == self.issuer,
              claims["aud"] as? String == self.audience,
              SGSignedPolicyJWS.integer(claims["ver"]) == self.version
        else {
            return .failure(.wrongPurpose)
        }
        guard let revision = SGSignedPolicyJWS.integer(claims["revision"]), revision >= 0, revision <= self.maximumRevision,
              let issuedAt = SGSignedPolicyJWS.integer(claims["iat"]), issuedAt >= 1,
              let expiresAt = SGSignedPolicyJWS.integer(claims["exp"]), expiresAt >= 1,
              expiresAt > issuedAt, expiresAt - issuedAt <= self.maximumLifetime,
              case let .success(ios) = self.platform(claims["ios"]),
              case let .success(android) = self.platform(claims["android"])
        else {
            return .failure(.invalidClaims)
        }
        return .success(SGAppUpdatePolicy(revision: revision, issuedAt: issuedAt, expiresAt: expiresAt, ios: ios, android: android, token: token))
    }

    /// `null` is no constraint; exactly `{min, latest}` — two strings of the version pattern with
    /// `min <= latest` — is one. Anything else (an extra or missing key, a non-string, a value the
    /// pattern refuses, `min > latest`, a missing claim) is invalid.
    private static func platform(_ value: Any?) -> Result<SGAppUpdateVersions?, SGEntitlementPolicyFailure> {
        guard let value else {
            return .failure(.invalidClaims)
        }
        if value is NSNull {
            return .success(nil)
        }
        guard let object = value as? [String: Any], Set(object.keys) == self.platformKeys,
              let rawMin = object["min"] as? String, let min = SGAppUpdateVersion(rawMin),
              let rawLatest = object["latest"] as? String, let latest = SGAppUpdateVersion(rawLatest),
              let versions = SGAppUpdateVersions(min: min, latest: latest)
        else {
            return .failure(.invalidClaims)
        }
        return .success(versions)
    }
}

/// Why a fetched app-update policy was not adopted.
public enum SGAppUpdatePolicyRejection: Error, Equatable, Hashable {
    case verification(SGEntitlementPolicyFailure)
    /// Its `(revision, iat)` is behind the accepted one: a replay can never undo a newer decision.
    case older
    /// Same `(revision, iat)` as the accepted one, other platform values. The server never issues
    /// it (every change bumps the revision); the accepted policy stands.
    case conflictingIssuance
}

public enum SGAppUpdatePolicyOutcome: Equatable {
    /// A newer issuance.
    case adopted
    /// The same issuance again (a routine refresh); nothing changed.
    case unchanged
    case rejected(SGAppUpdatePolicyRejection)
}

public struct SGAppUpdatePolicyAcceptance: Equatable {
    public let state: SGAppUpdatePolicyState
    public let outcome: SGAppUpdatePolicyOutcome
}

/// What this install currently holds, as a value. Mirrors `SGEntitlementPolicyState`.
public struct SGAppUpdatePolicyState: Equatable {
    /// The last policy that verified and won the order; nil before the first one.
    public let accepted: SGAppUpdatePolicy?

    public init(accepted: SGAppUpdatePolicy?) {
        self.accepted = accepted
    }

    /// Nothing accepted: no constraint, nothing shown.
    public static let initial = SGAppUpdatePolicyState(accepted: nil)

    /// The state after a freshly fetched `token`, and what happened to it. `now` is the POLICY
    /// clock, floored at the accepted policy's signed `iat` exactly as for the monetization policy
    /// (`SGEntitlementPolicyState.accepting`): the floor only widens the window by the skew
    /// allowance around that `iat`, and a clock far enough off keeps the last accepted policy, as
    /// offline would.
    public func accepting(fetched token: String, pinnedKeys: SGEntitlementPinnedKeys, now: Date) -> SGAppUpdatePolicyAcceptance {
        var evaluationTime = now
        if let accepted = self.accepted {
            evaluationTime = max(now, Date(timeIntervalSince1970: TimeInterval(accepted.issuedAt)))
        }
        let candidate: SGAppUpdatePolicy
        switch SGAppUpdatePolicyVerifier.verifyFetched(token, pinnedKeys: pinnedKeys, now: evaluationTime) {
        case let .success(value):
            candidate = value
        case let .failure(failure):
            return SGAppUpdatePolicyAcceptance(state: self, outcome: .rejected(.verification(failure)))
        }
        guard let current = self.accepted else {
            return SGAppUpdatePolicyAcceptance(state: SGAppUpdatePolicyState(accepted: candidate), outcome: .adopted)
        }
        if candidate.hasSameIssuance(as: current) {
            // Re-signed bytes (a fresh ECDSA nonce) of the accepted issuance are a routine refresh;
            // the same issuance with other values is a conflict the server never produces.
            guard candidate.hasSameConstraints(as: current) else {
                return SGAppUpdatePolicyAcceptance(state: self, outcome: .rejected(.conflictingIssuance))
            }
            return SGAppUpdatePolicyAcceptance(state: self, outcome: .unchanged)
        }
        guard current.isOrdered(before: candidate) else {
            return SGAppUpdatePolicyAcceptance(state: self, outcome: .rejected(.older))
        }
        return SGAppUpdatePolicyAcceptance(state: SGAppUpdatePolicyState(accepted: candidate), outcome: .adopted)
    }

    /// A previously accepted policy, re-verified against the pinned ring and never re-expired. A
    /// stored policy that no longer authenticates (a rotated ring, damaged bytes, another purpose)
    /// is no policy at all: nothing is shown until the next fetch.
    public static func restoring(stored token: String?, pinnedKeys: SGEntitlementPinnedKeys) -> SGAppUpdatePolicyState {
        guard let token, case let .success(policy) = SGAppUpdatePolicyVerifier.authenticate(token, pinnedKeys: pinnedKeys) else {
            return .initial
        }
        return SGAppUpdatePolicyState(accepted: policy)
    }
}

/// What the app shows for its installed version under the accepted policy — for THIS platform
/// (`SGAppUpdatePolicy.ios`), decided offline from values alone.
public enum SGAppUpdateDecision: Equatable {
    /// Nothing: no policy, no constraint, an unreadable installed version, installed at or above
    /// `latest` (TestFlight and debug builds above the store version see nothing), a reminder already
    /// shown for this `latest`, or a block whose policy went unrefreshed for 30 days.
    case none
    /// `min <= installed < latest`: one dismissable "Zenlygram <latest> is available" per distinct
    /// `latest`. Never interrupts anything; never shown while a block is up.
    case remind(latest: SGAppUpdateVersion)
    /// `installed < min`: the full-screen "Update required" overlay, nothing else usable.
    case block(SGAppUpdateVersions)

    /// BLOCK SAFETY VALVE: a block is shown only while the accepted policy's `exp` is at most this
    /// far in the past on the policy clock — 30 days. A policy that could not be refreshed for a
    /// month (an endpoint gone, a ring rotated under the install) can brick nothing for good; the
    /// reminder is unaffected, it costs the user nothing.
    public static let blockValve: Int64 = 30 * 86400

    /// `installed` is `CFBundleShortVersionString` (never the build number); `remindedLatest` is the
    /// persisted `latest` the one reminder was shown for (`SGEntitlementPolicyStore
    /// .loadRemindedLatest`); `now` is the policy clock.
    public static func evaluate(policy: SGAppUpdatePolicy?, installed: String?, remindedLatest: String?, now: Date) -> SGAppUpdateDecision {
        // Fail open: nothing accepted, no constraint for iOS, or an installed version the pattern
        // cannot read (a `-debug` suffix) decides nothing.
        guard let policy, let constraint = policy.ios, let installed, let installedVersion = SGAppUpdateVersion(installed) else {
            return .none
        }
        if installedVersion < constraint.min {
            let seconds = Int64(now.timeIntervalSince1970.rounded(.down))
            guard policy.expiresAt >= seconds - self.blockValve else {
                return .none
            }
            return .block(constraint)
        }
        if installedVersion < constraint.latest {
            if let remindedLatest, let reminded = SGAppUpdateVersion(remindedLatest), reminded == constraint.latest {
                return .none
            }
            return .remind(latest: constraint.latest)
        }
        return .none
    }
}
