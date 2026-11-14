import Foundation
import CryptoKit

// MARK: Zenlygram — the signed monetization policy (contracts `monetization-policy.v1` / `.v2`).
//
// `GET /v1/monetization` answers ONE question for every install: is Zenlygram free for everyone, or
// does it sell subscriptions? Every install starts FREE and stays free until the owner deliberately
// enables paid mode on the server. The answer is a JWS signed ES256 for another purpose than the
// entitlement (`aud: zenlygram-monetization`), so the two can never be mistaken for each other. It
// is verified with the entitlement's pinned ring in a build without an explicit public policy, and
// with that policy's OWN ring (`SGEntitlementPublicPolicyConfiguration`) in a build with one.
// Nothing here grants an account anything: the policy carries no identity,
// and genuine paid rights stay in the entitlement's `account_ent` / `account_until`.
//
// Two claim SHAPES exist, and the client chooses which it is sent (`SGEntitlementPolicyEndpoint`'s
// `Accept` header): the frozen v1 — exactly `iss, aud, ver: 1, mode, revision, iat, exp` — and v2,
// the same seven plus `trial_days` (0...30: the server's OWN trial, offered to eligible accounts
// while paid; 0 = none). `trial_days` is an offer the paywall shows, never purchase admission and
// never the trial's real end (that is `trial_ends_at` from `POST /v1/trial/start`).
//
// Rules this file enforces (the contract's `x-signing` / `x-client-state`):
//  - only the exact header and exactly one of the two exact claim sets authenticates, with `ver`
//    naming that set (seven claims are 1, eight are 2); unknown or account-shaped claims do not;
//  - a NEWLY FETCHED policy must also be inside its signed window (± 300 s of skew, ≤ 24 h lifetime);
//    a previously accepted one is re-verified on load but never re-expired — expiry does not change
//    an authenticated mode, and a stored v2 keeps its `trial_days`;
//  - acceptance follows `(revision, iat)` alone, whatever the shape: a v1 with a newer `iat` wins
//    over a stored v2 and hides the trial until the next v2 (fail-safe); an equal tuple is
//    idempotent for the same mode and shape, adopts a v1 -> v2 upgrade, keeps a v2 against a v1,
//    and is a conflict for another mode or another `trial_days`;
//  - no timer, no network failure and no build setting can turn paid mode on or offer a trial: only
//    a newer signed policy can.
//
// Foundation + CryptoKit only, so it runs on the host (`Tests/run-policy-core-tests.sh`).

/// Whether Zenlygram sells subscriptions right now.
public enum SGEntitlementPolicyMode: String, Equatable, Hashable, CaseIterable {
    /// Everyone gets the shipped Pro capabilities; nothing new is sold. The initial mode.
    case free
    /// Subscriptions are offered; access comes from genuine paid grants and StoreKit.
    case paid
}

/// One authenticated policy, with the exact signed bytes it came from.
public struct SGEntitlementPolicy: Equatable {
    public let mode: SGEntitlementPolicyMode
    public let revision: Int64
    public let issuedAt: Int64
    public let expiresAt: Int64
    /// The claim shape the token was minted in: 1 (the frozen seven claims) or 2 (plus `trial_days`).
    public let version: Int64
    /// The server's own trial, in days, offered to eligible accounts while paid: the signed
    /// `trial_days` of a v2 token; 0 for a v1 token (which cannot say) and whenever none is offered.
    public let trialDays: Int
    /// The compact JWS, persisted and re-verified as is.
    public let token: String

    /// Whether the paywall may show the server's trial: paid, with a signed non-zero `trial_days`.
    /// Never from a free policy, however many days it names (the server folds those to 0 anyway).
    public var offersServerTrial: Bool {
        return self.mode == .paid && self.trialDays > 0
    }

    /// The acceptance order: lexicographic `(revision, iat)`.
    func isOrdered(before other: SGEntitlementPolicy) -> Bool {
        if self.revision != other.revision {
            return self.revision < other.revision
        }
        return self.issuedAt < other.issuedAt
    }

    func hasSameIssuance(as other: SGEntitlementPolicy) -> Bool {
        return self.revision == other.revision && self.issuedAt == other.issuedAt
    }
}

/// Why a policy did not authenticate (or, when fetched, was not current). Shared by the two public
/// policies' verifiers (`SGEntitlementPolicyVerifier`, `SGAppUpdatePolicyVerifier`).
public enum SGEntitlementPolicyFailure: Error, Equatable, Hashable {
    /// Not the compact form, not base64url / JSON, or not exactly `{alg: ES256, typ: JWT, kid}`.
    case malformed
    /// The `kid` is not pinned in this build.
    case unknownKid(String)
    case badSignature
    /// Not a policy of the verifier's purpose: another issuer or audience (the OTHER public policy's
    /// token included), a claim set the verifier's contract does not define (a missing claim, any
    /// claim added — an entitlement / account-shaped token included), or a `ver` that does not name
    /// the set it came with. For the monetization policy that is neither the seven v1 claims nor
    /// the eight v2 claims; for the app-update policy, not exactly its eight.
    case wrongPurpose
    /// A known claim set, but with a wrong type or out of range (`exp <= iat`, a lifetime over
    /// 24 h, a `trial_days` outside 0...30 or not an integer, a platform object that is not exactly
    /// `{min, latest}` with `min <= latest`).
    case invalidClaims
    /// Fetched, and issued more than the allowed skew after `effectiveNow`.
    case notYetValid
    /// Fetched, and expired more than the allowed skew before `effectiveNow`.
    case expired
}

/// Zenlygram — the signed envelope the two public policies share (`GET /v1/monetization`,
/// `GET /v1/app-policy`): the compact JWS form (length and alphabet, three non-empty parts), the
/// exact `{alg: ES256, typ: JWT, kid}` header, the pinned ring and the P-256 signature over the
/// signing input. It authenticates BYTES and hands back the claims; what the claims must say is
/// each verifier's own business (`SGEntitlementPolicyVerifier` for `aud: zenlygram-monetization`,
/// `SGAppUpdatePolicyVerifier` for `aud: zenlygram-app-policy`), and each refuses the other's
/// audience. No claim is read before the signature verified.
enum SGSignedPolicyJWS {
    static let minimumTokenLength = 100
    static let maximumTokenLength = 8192

    private static let headerKeys: Set<String> = ["alg", "typ", "kid"]

    /// The claims of an authentic policy token, or why it is not one. Says nothing about time or
    /// purpose.
    static func authenticate(_ token: String, pinnedKeys: SGEntitlementPinnedKeys) -> Result<[String: Any], SGEntitlementPolicyFailure> {
        let bytes = token.utf8
        guard bytes.count >= self.minimumTokenLength, bytes.count <= self.maximumTokenLength, bytes.allSatisfy(self.isCompactByte) else {
            return .failure(.malformed)
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts.contains(where: { $0.isEmpty }),
              let headerData = SGEntitlementCrypto.base64urlDecode(String(parts[0])),
              let payloadData = SGEntitlementCrypto.base64urlDecode(String(parts[1])),
              let signatureData = SGEntitlementCrypto.base64urlDecode(String(parts[2])),
              let header = (try? JSONSerialization.jsonObject(with: headerData, options: [])) as? [String: Any]
        else {
            return .failure(.malformed)
        }

        // The exact header: ES256 pinned, `alg` never selects anything, no key-locating extras.
        guard Set(header.keys) == self.headerKeys,
              header["alg"] as? String == "ES256",
              header["typ"] as? String == "JWT",
              let kid = header["kid"] as? String, !kid.isEmpty
        else {
            return .failure(.malformed)
        }
        guard let pinned = pinnedKeys.value(forKid: kid) else {
            return .failure(.unknownKid(kid))
        }
        guard let point = SGEntitlementCrypto.p256X963(fromPinnedKey: pinned),
              let key = try? P256.Signing.PublicKey(x963Representation: point)
        else {
            return .failure(.malformed)
        }
        guard signatureData.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
        else {
            return .failure(.badSignature)
        }

        // Only now, authentic, are the claims read.
        guard let claims = (try? JSONSerialization.jsonObject(with: payloadData, options: [])) as? [String: Any] else {
            return .failure(.malformed)
        }
        return .success(claims)
    }

    /// A JSON integer exactly: not a boolean, not a fractional number, not a string.
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber)
        else {
            return nil
        }
        return number.int64Value
    }

    /// `[A-Za-z0-9_-]` and the two separating dots.
    private static func isCompactByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
            return true
        default:
            return false
        }
    }
}

public enum SGEntitlementPolicyVerifier {
    static let issuer = "zenlygram"
    static let audience = "zenlygram-monetization"
    /// The frozen shape: exactly `claimKeysV1`.
    static let versionV1: Int64 = 1
    /// The shape with `trial_days`: exactly `claimKeysV2`. Minted only for a client whose `Accept`
    /// lists its vendor type (`SGEntitlementPolicyEndpoint.monetizationAccept`).
    static let versionV2: Int64 = 2
    public static let maximumLifetime: Int64 = 86400
    public static let maximumClockSkew: Int64 = 300
    /// The contract's ceiling for `trial_days`.
    public static let maximumTrialDays = 30
    static let maximumRevision: Int64 = 9_007_199_254_740_991

    private static let claimKeysV1: Set<String> = ["iss", "aud", "ver", "mode", "revision", "iat", "exp"]
    private static let claimKeysV2: Set<String> = SGEntitlementPolicyVerifier.claimKeysV1.union(["trial_days"])

    /// Authentic (`SGSignedPolicyJWS`), exactly one of the two shapes, and the policy's purpose.
    /// Says nothing about time: a stored policy is re-verified with this alone.
    public static func authenticate(_ token: String, pinnedKeys: SGEntitlementPinnedKeys) -> Result<SGEntitlementPolicy, SGEntitlementPolicyFailure> {
        switch SGSignedPolicyJWS.authenticate(token, pinnedKeys: pinnedKeys) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(claims):
            return self.policy(claims: claims, token: token)
        }
    }

    /// `authenticate` plus the signed window, against `effectiveNow`. Only for a policy just
    /// fetched: the response's own unsigned `server_time` is never consulted.
    public static func verifyFetched(_ token: String, pinnedKeys: SGEntitlementPinnedKeys, now: Date) -> Result<SGEntitlementPolicy, SGEntitlementPolicyFailure> {
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

    private static func policy(claims: [String: Any], token: String) -> Result<SGEntitlementPolicy, SGEntitlementPolicyFailure> {
        // Exactly one of the two claim sets, and `ver` must name that set: seven claims are version
        // 1, eight (with `trial_days`) are version 2. Any other set — a claim missing, a claim
        // added, an account-shaped one — and any other `ver` is another purpose. A shape this
        // build does not know is never read as "unknown claims ignored": it would freeze the mode.
        let keys = Set(claims.keys)
        let version: Int64
        if keys == self.claimKeysV1 {
            version = self.versionV1
        } else if keys == self.claimKeysV2 {
            version = self.versionV2
        } else {
            return .failure(.wrongPurpose)
        }
        guard claims["iss"] as? String == self.issuer,
              claims["aud"] as? String == self.audience,
              SGSignedPolicyJWS.integer(claims["ver"]) == version
        else {
            return .failure(.wrongPurpose)
        }
        guard let rawMode = claims["mode"] as? String, let mode = SGEntitlementPolicyMode(rawValue: rawMode),
              let revision = SGSignedPolicyJWS.integer(claims["revision"]), revision >= 0, revision <= self.maximumRevision,
              let issuedAt = SGSignedPolicyJWS.integer(claims["iat"]), issuedAt >= 1,
              let expiresAt = SGSignedPolicyJWS.integer(claims["exp"]), expiresAt >= 1,
              expiresAt > issuedAt, expiresAt - issuedAt <= self.maximumLifetime
        else {
            return .failure(.invalidClaims)
        }
        var trialDays = 0
        if version == self.versionV2 {
            // A JSON integer in 0...30: never a boolean, a fraction or a string.
            guard let signedTrialDays = SGSignedPolicyJWS.integer(claims["trial_days"]), signedTrialDays >= 0, signedTrialDays <= Int64(self.maximumTrialDays) else {
                return .failure(.invalidClaims)
            }
            trialDays = Int(signedTrialDays)
        }
        return .success(SGEntitlementPolicy(mode: mode, revision: revision, issuedAt: issuedAt, expiresAt: expiresAt, version: version, trialDays: trialDays, token: token))
    }
}

/// Why a fetched policy was not adopted.
public enum SGEntitlementPolicyRejection: Error, Equatable, Hashable {
    case verification(SGEntitlementPolicyFailure)
    /// Its `(revision, iat)` is behind the accepted one: a replay can never undo a newer decision.
    case older
    /// Same `(revision, iat)` as the accepted one, another mode — or two v2 tokens of that issuance
    /// with different `trial_days`. The server never issues either (every trial change bumps the
    /// revision); the accepted policy stands.
    case conflictingIssuance
}

public enum SGEntitlementPolicyOutcome: Equatable {
    /// A newer issuance, or the accepted issuance in its v2 shape (`trial_days` now legible).
    case adopted
    /// The same issuance again (a routine refresh), or its v1 shape while the v2 is held; nothing
    /// changed.
    case unchanged
    case rejected(SGEntitlementPolicyRejection)
}

public struct SGEntitlementPolicyAcceptance: Equatable {
    public let state: SGEntitlementPolicyState
    public let outcome: SGEntitlementPolicyOutcome
}

/// What this install currently believes, as a value.
public struct SGEntitlementPolicyState: Equatable {
    /// The last policy that verified and won the order; nil before the first one.
    public let accepted: SGEntitlementPolicy?

    public init(accepted: SGEntitlementPolicy?) {
        self.accepted = accepted
    }

    /// Nothing accepted: free.
    public static let initial = SGEntitlementPolicyState(accepted: nil)

    /// Free unless an authenticated policy says paid.
    public var mode: SGEntitlementPolicyMode {
        return self.accepted?.mode ?? .free
    }

    /// The state after a freshly fetched `token`, and what happened to it.
    ///
    /// `now` is the POLICY clock — the wall clock, never the account clock mark that unsigned
    /// `server_time` moves — floored here at the accepted policy's SIGNED `iat`, the only server
    /// time this decision trusts. The floor only ever widens the window by the clock-skew allowance
    /// around that `iat`: a policy issued within 300 s of the accepted one still verifies under a
    /// wall clock wound back. It does NOT repair a mis-set clock in general. A clock far enough
    /// behind or ahead refuses newer policies (`notYetValid` / `expired`), and the install keeps
    /// its last verified mode, exactly as offline — so a mode change reaches such a device only
    /// once its clock is right. That is a documented limit of the strict contract window, not a
    /// promise of instant cutover.
    public func accepting(fetched token: String, pinnedKeys: SGEntitlementPinnedKeys, now: Date) -> SGEntitlementPolicyAcceptance {
        var evaluationTime = now
        if let accepted = self.accepted {
            evaluationTime = max(now, Date(timeIntervalSince1970: TimeInterval(accepted.issuedAt)))
        }
        let candidate: SGEntitlementPolicy
        switch SGEntitlementPolicyVerifier.verifyFetched(token, pinnedKeys: pinnedKeys, now: evaluationTime) {
        case let .success(value):
            candidate = value
        case let .failure(failure):
            return SGEntitlementPolicyAcceptance(state: self, outcome: .rejected(.verification(failure)))
        }
        guard let current = self.accepted else {
            return SGEntitlementPolicyAcceptance(state: SGEntitlementPolicyState(accepted: candidate), outcome: .adopted)
        }
        if candidate.hasSameIssuance(as: current) {
            return self.acceptingSameIssuance(candidate, current: current)
        }
        // `(revision, iat)` alone orders policies, whatever their shape: a v1 with a newer `iat`
        // replaces a stored v2 and, carrying no `trial_days`, hides the trial — intended fail-safe.
        // The next fetch carries a newer `iat` still and, as v2, re-adopts it.
        guard current.isOrdered(before: candidate) else {
            return SGEntitlementPolicyAcceptance(state: self, outcome: .rejected(.older))
        }
        return SGEntitlementPolicyAcceptance(state: SGEntitlementPolicyState(accepted: candidate), outcome: .adopted)
    }

    /// The accepted issuance again. The server never signs two different policies under one
    /// `(revision, iat)`, so a different MODE is a conflict and the accepted policy stands. The
    /// claim SHAPE, though, is this client's choice (its `Accept` header), not the server's: the
    /// same issuance fetched as v2 after a v1 — this build's first fetch after the server started
    /// minting v2 — is adopted, its `trial_days` now legible; a v1 of an issuance held as v2 (a
    /// proxy, a cache) changes nothing; two v2 tokens must agree on `trial_days`, or they conflict.
    private func acceptingSameIssuance(_ candidate: SGEntitlementPolicy, current: SGEntitlementPolicy) -> SGEntitlementPolicyAcceptance {
        guard candidate.mode == current.mode else {
            return SGEntitlementPolicyAcceptance(state: self, outcome: .rejected(.conflictingIssuance))
        }
        if candidate.version > current.version {
            return SGEntitlementPolicyAcceptance(state: SGEntitlementPolicyState(accepted: candidate), outcome: .adopted)
        }
        if candidate.version < current.version {
            return SGEntitlementPolicyAcceptance(state: self, outcome: .unchanged)
        }
        guard candidate.trialDays == current.trialDays else {
            return SGEntitlementPolicyAcceptance(state: self, outcome: .rejected(.conflictingIssuance))
        }
        return SGEntitlementPolicyAcceptance(state: self, outcome: .unchanged)
    }

    /// A previously accepted policy, re-verified against the pinned ring and never re-expired, in
    /// the shape it was stored (a v2 keeps its `trial_days`; a v1 has none). A stored policy that
    /// no longer authenticates (another key, damaged bytes, another purpose — a v2 under a build
    /// that only knows v1 included, which then re-adopts the next fetch) is no policy at all: free.
    public static func restoring(stored token: String?, pinnedKeys: SGEntitlementPinnedKeys) -> SGEntitlementPolicyState {
        guard let token, case let .success(policy) = SGEntitlementPolicyVerifier.authenticate(token, pinnedKeys: pinnedKeys) else {
            return .initial
        }
        return SGEntitlementPolicyState(accepted: policy)
    }
}

/// An accepted policy's signed bytes, in the app group (non-secret: a policy names no one). One slot
/// per public policy, each under its own LAYOUT key — `zg.ent.policy.v1` for the monetization policy,
/// `zg.app.policy.v1` for the app-update policy (`SGAppUpdatePolicy`) — holding one compact JWS. The
/// key names the store's layout, not the token's `ver`: a v1 monetization install reads its first v2
/// straight into the slot it had.
///
/// Every slot is scoped (`scoped(toOrigin:)`): an explicit public policy under its canonical HTTPS
/// origin, any other build under its backend store scope (`SGEntitlementStoreScope.identifier`). Bytes
/// another origin's server signed — the bare legacy `defaultsKey` included — are never read, imported,
/// overwritten or deleted, and can never out-rank a scope's first policy.
public final class SGEntitlementPolicyStore {
    /// The monetization policy's layout key (`SGEntitlementPolicy`).
    public static let defaultsKey = "zg.ent.policy.v1"
    /// The app-update policy's layout key (`SGAppUpdatePolicy`): the same layout, its own slot.
    public static let appUpdateDefaultsKey = "zg.app.policy.v1"
    /// The app-update reminder's marker (`SGAppUpdateDecision.remind`): the `latest` the one alert
    /// was shown for, scoped like the policy it belongs to (`zg.app.policy.reminded@<origin>`).
    public static let appUpdateRemindedKey = "zg.app.policy.reminded"

    private let defaults: UserDefaults?
    /// The layout key this slot holds, before scoping (`defaultsKey` or `appUpdateDefaultsKey`).
    public let baseKey: String
    /// The canonical origin this slot is scoped to; nil for the bare, never-read-by-the-app slot.
    private let origin: String?
    /// The defaults key this store reads and writes, and no other.
    public let key: String

    public init(defaults: UserDefaults?, baseKey: String = SGEntitlementPolicyStore.defaultsKey) {
        self.defaults = defaults
        self.baseKey = baseKey
        self.origin = nil
        self.key = baseKey
    }

    private init(defaults: UserDefaults?, baseKey: String, origin: String?) {
        self.defaults = defaults
        self.baseKey = baseKey
        self.origin = origin
        self.key = origin.map { SGEntitlementPolicyStore.originKey($0, baseKey: baseKey) } ?? baseKey
    }

    /// `<baseKey>@https://host[:port]` — `zg.ent.policy.v1@…` unless another layout key is named.
    public static func originKey(_ origin: String, baseKey: String = SGEntitlementPolicyStore.defaultsKey) -> String {
        return "\(baseKey)@\(origin)"
    }

    /// The same defaults and layout key, keyed by `origin` alone.
    public func scoped(toOrigin origin: String) -> SGEntitlementPolicyStore {
        return SGEntitlementPolicyStore(defaults: self.defaults, baseKey: self.baseKey, origin: origin)
    }

    /// The same defaults and the same origin (if any) under another layout key: how the app-update
    /// policy's slot is derived from the monetization policy's — one defaults handle, two keys,
    /// identical scoping.
    public func rebased(to baseKey: String) -> SGEntitlementPolicyStore {
        return SGEntitlementPolicyStore(defaults: self.defaults, baseKey: baseKey, origin: self.origin)
    }

    public func load() -> String? {
        return self.defaults?.string(forKey: self.key)
    }

    /// Whether the write reads back. A failed write keeps the policy in memory for this process.
    @discardableResult
    func save(_ token: String) -> Bool {
        guard let defaults = self.defaults else {
            return false
        }
        defaults.set(token, forKey: self.key)
        return defaults.string(forKey: self.key) == token
    }

    /// D9 — the marker of the one-time "Zenlygram Pro is now a subscription" notice
    /// (`SGEntitlement.takePaidModeNotice`), kept next to the policy it belongs to (`<key>.noticed`,
    /// so it is scoped exactly like the policy). It follows the FLIP, not the revision: nil means
    /// the notice is pending for the current paid run — cleared when a free policy gives way to a
    /// paid one (`SGEntitlement.finishPolicyAttempt`) — and a value is the paid revision under which
    /// the notice was shown, or under which it became moot (an install whose first policy was
    /// already paid never knew Pro as free). A paid -> paid revision bump leaves it alone.
    public func loadNoticedRevision() -> Int64? {
        guard let value = self.defaults?.object(forKey: self.noticedRevisionKey) as? NSNumber else {
            return nil
        }
        return value.int64Value
    }

    /// nil makes the notice pending again.
    func saveNoticedRevision(_ revision: Int64?) {
        guard let revision else {
            self.defaults?.removeObject(forKey: self.noticedRevisionKey)
            return
        }
        self.defaults?.set(NSNumber(value: revision), forKey: self.noticedRevisionKey)
    }

    private var noticedRevisionKey: String {
        return "\(self.key).noticed"
    }

    /// The `latest` the app-update reminder was shown for (`SGAppUpdateDecision.evaluate`'s
    /// `remindedLatest`), as the policy named it; nil when no reminder was ever shown under this
    /// origin. Kept on the app-update slot (`appUpdateDefaultsKey`), scoped like it.
    public func loadRemindedLatest() -> String? {
        return self.defaults?.string(forKey: self.remindedLatestKey)
    }

    /// Written by the presenter only AFTER the alert was actually shown — never on a decision alone.
    /// nil forgets it, so the same `latest` reminds again.
    func saveRemindedLatest(_ latest: String?) {
        guard let latest else {
            self.defaults?.removeObject(forKey: self.remindedLatestKey)
            return
        }
        self.defaults?.set(latest, forKey: self.remindedLatestKey)
    }

    /// `zg.app.policy.reminded@<origin>` (the spec's key, not `<key>.reminded`).
    private var remindedLatestKey: String {
        guard let origin = self.origin else {
            return SGEntitlementPolicyStore.appUpdateRemindedKey
        }
        return SGEntitlementPolicyStore.originKey(origin, baseKey: SGEntitlementPolicyStore.appUpdateRemindedKey)
    }
}

/// One policy request at a time, and at least `minimumInterval` between attempts, success or
/// failure alike — on the MONOTONIC clock, so changing the device clock neither wedges nor floods it.
struct SGEntitlementPolicyRefreshGate {
    static let minimumInterval: TimeInterval = 60

    private var isInFlight = false
    private var lastAttemptAt: TimeInterval?

    mutating func begin(uptime: TimeInterval) -> Bool {
        if self.isInFlight {
            return false
        }
        if let last = self.lastAttemptAt, uptime - last < SGEntitlementPolicyRefreshGate.minimumInterval {
            return false
        }
        self.isInFlight = true
        self.lastAttemptAt = uptime
        return true
    }

    /// A user's purchase asks for its own fresh policy: it shares the one-request-in-flight slot
    /// (never two policy requests at once) but is not held back by a background refresh's cooldown.
    /// It counts as an attempt for that cadence.
    mutating func beginPurchaseAuthorization(uptime: TimeInterval) -> Bool {
        if self.isInFlight {
            return false
        }
        self.isInFlight = true
        self.lastAttemptAt = uptime
        return true
    }

    mutating func finish() {
        self.isInFlight = false
    }
}

/// The one request the policy refresh makes; injected so the refresh runs without a network.
struct SGEntitlementPolicyTransport {
    let fetch: () async -> Result<String, SGEntitlementRequestError>
}

/// How one policy refresh ended.
public enum SGEntitlementPolicyRefreshAttempt: Equatable {
    case adopted
    case unchanged
    /// Answered, but the policy did not verify, was out of its window or lost the order.
    case rejected
    /// Transport failure. The last verified mode stands.
    case failed
    /// Not sent: one in flight, inside the cooldown, or no transport in this build.
    case skipped
}

/// Whether a NEW App Store purchase may start, decided by a policy fetched for that purchase
/// (`SGEntitlement.authorizeNewPurchase`). Never the cached mode.
public enum SGEntitlementPurchaseAuthorization: Equatable {
    /// A freshly fetched, verified policy is paid, and it is (or equals) the newest accepted one.
    case paid
    /// A freshly fetched, verified policy is free (and was adopted).
    case free
    /// Not fetched, not verified, outside its window, older than the accepted one, conflicting, or
    /// no transport in this build.
    case unavailable
    /// Another policy request is in flight: try again in a moment.
    case busy
}
