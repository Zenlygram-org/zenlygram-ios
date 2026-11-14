import Foundation

/// Zenlygram — the JWS header. `alg` is pinned to ES256 by the verifier; it never selects the
/// algorithm, and `"none"` is rejected like anything else that is not ES256.
public struct SGEntitlementTokenHeader: Equatable, Decodable {
    public let alg: String
    public let kid: String
    public let typ: String?
}

/// Zenlygram — the entitlement token's claims (client contract §4.1, `TokenService.php:59-91`).
///
/// Decoding is deliberately lenient, because a claim this build does not understand must never cost
/// a paying user their access (invariant I2):
/// - `until` is an optional STRING, never a throwing date type. `null` means locked.
/// - `tgid` is ABSENT (not null) for an Apple-only account.
/// - `ent` may be `[]` (a lapsed account) or `["*"]` (the operator escape hatch).
/// - `ver` may be higher than this build knows; the token is still honoured with the claims we do
///   understand.
/// - `grace_days`, if a future server omits it, falls back to the design's 14 rather than 0 —
///   erring toward the user, which is the correct direction.
public struct SGEntitlementClaims: Equatable, Decodable {
    public static let expectedIssuer = "zenlygram"
    public static let defaultGraceDays = 14

    public let iss: String
    /// `accounts.id`, a 26-char ULID. Opaque; never parsed.
    public let sub: String
    public let tgid: Int64?
    /// `devices.id` — the binding this token was minted for. Checked against the stored device id.
    public let dev: String
    /// Informational. Gate on `ent`, never on `tier`.
    public let tier: String?
    public let ent: [String]
    /// The SUBSCRIPTION horizon, RFC 3339 `Z`, or nil for "locked".
    public let until: String?
    public let graceDays: Int
    public let iat: Int64
    /// The TOKEN horizon. `exp - iat` is 72 h normally and 24 h once the account has a refund —
    /// never assume 72.
    public let exp: Int64
    public let jti: String?
    public let ver: Int?
    /// P7: the Apple original this account owns, the server event its state is at, and the exact
    /// receipts revoked (`SGEntitlementAppleSourceClaim`). Strict, unlike the claims above: a
    /// malformed `apple_source` makes the whole token malformed, so a token whose provenance cannot be
    /// read never replaces the last verified one.
    public let appleSource: SGEntitlementAppleSourceClaim
    /// The account's GENUINE rights (`account_ent` / `account_until`): paid, trial, manual or VIP,
    /// independent of the monetization mode and never widened by the operator wildcard. nil on a
    /// legacy token that predates them, or when either claim is missing or malformed. In paid mode
    /// only this grants from a token — the legacy `ent` / `until` above, which the server widens
    /// for old clients while free, is never paid proof (`SGEntitlementEvaluator`).
    public let accountGrant: SGEntitlementAccountGrant?

    fileprivate enum CodingKeys: String, CodingKey {
        case iss
        case sub
        case tgid
        case dev
        case tier
        case ent
        case until
        case graceDays = "grace_days"
        case iat
        case exp
        case jti
        case ver
        case appleSource = "apple_source"
        case accountEnt = "account_ent"
        case accountUntil = "account_until"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.iss = try container.decode(String.self, forKey: .iss)
        self.sub = try container.decodeIfPresent(String.self, forKey: .sub) ?? ""
        self.tgid = try container.decodeIfPresent(Int64.self, forKey: .tgid)
        self.dev = try container.decodeIfPresent(String.self, forKey: .dev) ?? ""
        self.tier = try container.decodeIfPresent(String.self, forKey: .tier)
        self.ent = try container.decodeIfPresent([String].self, forKey: .ent) ?? []
        self.until = try container.decodeIfPresent(String.self, forKey: .until)
        self.graceDays = try container.decodeIfPresent(Int.self, forKey: .graceDays) ?? SGEntitlementClaims.defaultGraceDays
        self.iat = try container.decode(Int64.self, forKey: .iat)
        self.exp = try container.decode(Int64.self, forKey: .exp)
        self.jti = try container.decodeIfPresent(String.self, forKey: .jti)
        self.ver = try container.decodeIfPresent(Int.self, forKey: .ver)
        if !container.contains(.appleSource) {
            self.appleSource = .omitted
        } else if try container.decodeNil(forKey: .appleSource) {
            self.appleSource = .none
        } else {
            self.appleSource = .source(try container.decode(SGEntitlementAppleSource.self, forKey: .appleSource))
        }
        self.accountGrant = SGEntitlementAccountGrant.decode(from: container)
    }

    public init(
        iss: String = SGEntitlementClaims.expectedIssuer,
        sub: String,
        tgid: Int64? = nil,
        dev: String,
        tier: String? = nil,
        ent: [String],
        until: String?,
        graceDays: Int = SGEntitlementClaims.defaultGraceDays,
        iat: Int64,
        exp: Int64,
        jti: String? = nil,
        ver: Int? = 1,
        appleSource: SGEntitlementAppleSourceClaim = .omitted,
        accountGrant: SGEntitlementAccountGrant? = nil
    ) {
        self.iss = iss
        self.sub = sub
        self.tgid = tgid
        self.dev = dev
        self.tier = tier
        self.ent = ent
        self.until = until
        self.graceDays = graceDays
        self.iat = iat
        self.exp = exp
        self.jti = jti
        self.ver = ver
        self.appleSource = appleSource
        self.accountGrant = accountGrant
    }

    /// The legacy subscription horizon, or nil for "locked" / unparseable. Kept for old clients and
    /// for the free phase; in paid mode `accountGrant.untilDate` is the horizon. It can
    /// legitimately be about ten years out (VIP accounts, free-phase wildcard), so it is never
    /// clamped.
    public var untilDate: Date? {
        guard let until = self.until else {
            return nil
        }
        return SGEntitlementTimestamp.parse(until)
    }

    public var issuedAtDate: Date {
        return Date(timeIntervalSince1970: TimeInterval(self.iat))
    }

    public var expiresAtDate: Date {
        return Date(timeIntervalSince1970: TimeInterval(self.exp))
    }

    /// `exp + grace_days` — how long this device may keep trusting the token with no check-in.
    public var hardStopDate: Date {
        return self.expiresAtDate.addingTimeInterval(TimeInterval(self.graceDays) * 86400.0)
    }
}

/// Zenlygram — the genuine per-account grant a token carries (`account_ent` / `account_until`).
///
/// Both claims are required; a missing or wrongly typed one makes the grant absent, never partial.
/// Only the capability strings this client knows are kept, and the operator wildcard is dropped:
/// the server never puts it here, and a client that honoured it would turn a stray `"*"` into a
/// paid grant of everything.
public struct SGEntitlementAccountGrant: Equatable {
    public let capabilities: Set<String>
    /// RFC 3339 `Z`, or nil for "locked".
    public let until: String?

    public init(capabilities: Set<String>, until: String?) {
        let known = Set(SGEntitlementCapability.allCases.map { $0.rawValue })
        self.capabilities = capabilities.intersection(known)
        self.until = until
    }

    /// nil (locked) when `until` is null or unparseable.
    public var untilDate: Date? {
        return self.until.flatMap { SGEntitlementTimestamp.parse($0) }
    }

    fileprivate static func decode(from container: KeyedDecodingContainer<SGEntitlementClaims.CodingKeys>) -> SGEntitlementAccountGrant? {
        guard container.contains(.accountEnt), container.contains(.accountUntil),
              let capabilities = try? container.decode([String].self, forKey: .accountEnt)
        else {
            return nil
        }
        let until: String?
        if (try? container.decodeNil(forKey: .accountUntil)) == true {
            until = nil
        } else if let value = try? container.decode(String.self, forKey: .accountUntil) {
            until = value
        } else {
            return nil
        }
        return SGEntitlementAccountGrant(capabilities: Set(capabilities), until: until)
    }
}

/// Zenlygram — the server's timestamps are exactly `YYYY-MM-DDTHH:MM:SSZ`: UTC, `Z`-suffixed, no
/// fractional seconds and no offset (`ApiResponse.php:35-40`). A formatter configured with
/// `.withFractionalSeconds` will NOT parse them, which is why the plain internet-date-time option
/// is first and the fractional one is only a forward-compatible fallback.
public enum SGEntitlementTimestamp {
    private static let lock = NSLock()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func parse(_ value: String) -> Date? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let date = self.plainFormatter.date(from: value) {
            return date
        }
        return self.fractionalFormatter.date(from: value)
    }

    public static func string(from date: Date) -> String {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.plainFormatter.string(from: date)
    }
}
