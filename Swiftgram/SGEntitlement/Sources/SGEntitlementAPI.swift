import Foundation

/// Zenlygram — a failed Zenlygram request, already classified.
///
/// The raw `message` is for logs and for support, never for direct display: user-facing copy comes
/// from `SGEntitlementMessage` / `SGStrings`.
public struct SGEntitlementRequestError: Error, Equatable {
    /// Error bodies are kept (`responseBody`) up to this size; a larger one is not kept at all.
    public static let maxResponseBodyBytes = 16 * 1024

    public let failure: SGEntitlementFailureClass
    public let message: String?
    /// `server_time` from the response BODY. It is present on EVERY response, including 401, 404,
    /// 405, 429 and 500 — the `X-Server-Time` header can be missing on framework-rendered errors.
    public let serverTime: Date?
    public let retryAfter: Int?
    /// The HTTP status of the error answer. nil when no error answer was received: a transport
    /// failure, a 2xx this build could not read, or a local refusal that sent nothing.
    public let status: Int?
    /// The answer's stable `error` code, kept as sent. `failure` alone loses it for a coded 5xx such
    /// as `attest_unavailable` 503, which `SGEntitlementFailureMapping.classify` turns into
    /// `.offline(.serverError)`.
    public let code: String?
    /// The optional `reason` of an error body — e.g. `account_erased` on a 401 `invalid_token` for
    /// the credentials of an erased account.
    public let reason: String?
    /// The raw error body, at most `maxResponseBodyBytes`, for the caller's own decoding (a
    /// `consent_required` block, an `invalid_request` field). **Never logged.**
    public let responseBody: Data?

    public init(failure: SGEntitlementFailureClass, message: String? = nil, serverTime: Date? = nil, retryAfter: Int? = nil, status: Int? = nil, code: String? = nil, reason: String? = nil, responseBody: Data? = nil) {
        self.failure = failure
        self.message = message
        self.serverTime = serverTime
        self.retryAfter = retryAfter
        self.status = status
        self.code = code
        self.reason = reason
        self.responseBody = responseBody
    }

    public var recovery: SGEntitlementRecovery {
        return SGEntitlementFailureMapping.recovery(for: self.failure)
    }

    /// `body` as `responseBody`: kept whole when it fits, otherwise not at all (a cut JSON body would
    /// only mislead its reader).
    static func boundedResponseBody(_ body: Data) -> Data? {
        guard !body.isEmpty, body.count <= SGEntitlementRequestError.maxResponseBodyBytes else {
            return nil
        }
        return body
    }
}

// MARK: - Customer data

/// Zenlygram — the customer-data routes (`SGEntitlement.customerData`), each answered under the
/// account's current DeviceAuth session. Credentials always travel as headers, never in a body.
public enum SGEntitlementCustomerDataRoute: CaseIterable {
    /// `POST /v1/profile/consents`
    case profileConsents
    /// `POST /v1/profile/sync`
    case profileSync
    /// `GET /v1/profile/me`
    case profileMe
    /// `POST /v1/profile/events`
    case profileEvents
    /// `POST /v1/account/delete`
    case accountDelete

    /// Relative to the `/v1` base URL.
    public var path: String {
        switch self {
        case .profileConsents:
            return "profile/consents"
        case .profileSync:
            return "profile/sync"
        case .profileMe:
            return "profile/me"
        case .profileEvents:
            return "profile/events"
        case .accountDelete:
            return "account/delete"
        }
    }

    public var method: String {
        switch self {
        case .profileMe:
            return "GET"
        case .profileConsents, .profileSync, .profileEvents, .accountDelete:
            return "POST"
        }
    }
}

/// Zenlygram — whether `/bind/start` may run for an account, as the main app's consent pipeline
/// decides (`SGEntitlement.bindPermissionProvider`).
public enum SGEntitlementBindPermission: Equatable {
    /// Any link, the attested one included; `bind/start` carries the account's grant when it has one.
    case allowed
    /// The manual code flow only: no attestation, no consent attached.
    case codeOnly
    /// No `bind/start` at all for this account; refused locally, nothing is sent.
    case refused
}

/// Zenlygram — the record a binding the SERVER ended leaves behind: the 401 that dropped the stored
/// refresh token (`SGEntitlement.apply`). A local logout or Unlink and a new binding never leave one.
public struct SGEntitlementSessionEnd: Codable, Equatable {
    /// The DeviceAuth code that ended it (`invalid_token`, `session_revoked`, `device_revoked`, …).
    public let code: String
    /// The error body's `reason`, e.g. `account_erased`.
    public let reason: String?
    /// When this device learned of it, on the entitlement clock (`SGEntitlementClock.effectiveNow()`).
    public let at: Date
    /// The `devices.id` of the binding that ended.
    public let deviceId: String?

    public init(code: String, reason: String?, at: Date, deviceId: String?) {
        self.code = code
        self.reason = reason
        self.at = at
        self.deviceId = deviceId
    }
}

// MARK: - Bind

/// `POST /v1/bind/start`
public struct SGEntitlementBindStart: Equatable, Decodable {
    /// 8 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.
    public let code: String
    /// `https://t.me/{bot}?start=b{code}`. **May be null** — then show the code plus
    /// "send this code to @{bot}".
    public let deeplink: String?
    /// Returned once and never again.
    public let pollToken: String
    public let expiresAt: String
    /// bind-attest v1: present when the server can verify Telegram-signed Mini App `initData` for
    /// this bind. Decoded leniently — a malformed block is nil, never a failed `/bind/start` — and
    /// used only through `validatedAttest`.
    public let attest: SGEntitlementBindAttest?
    /// The device public key (SPKI, base64) this `/bind/start` registered — set by
    /// `SGEntitlement.beginBind`, never by the server. `completeBind` refuses a confirmation when
    /// this is no longer the device's key: the new binding would hold a key nothing here can sign
    /// with.
    public internal(set) var registeredPublicKey: String?
    /// Local-only lifetime fence; never decoded from the server. A logout or a newer bind for the
    /// same Telegram account invalidates this attempt before a late confirmation can be stored.
    var attempt: SGEntitlementBindAttempt?

    private enum CodingKeys: String, CodingKey {
        case code
        case deeplink
        case pollToken
        case expiresAt
        case attest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(String.self, forKey: .code)
        self.deeplink = try container.decodeIfPresent(String.self, forKey: .deeplink)
        self.pollToken = try container.decode(String.self, forKey: .pollToken)
        self.expiresAt = try container.decode(String.self, forKey: .expiresAt)
        self.attest = (try? container.decodeIfPresent(SGEntitlementBindAttest.self, forKey: .attest)) ?? nil
    }

    /// The attestation block, but only when it is well formed (`SGEntitlementBindAttest.isWellFormed`);
    /// nil sends the flow straight to the code.
    public var validatedAttest: SGEntitlementBindAttest? {
        guard let attest = self.attest, attest.isWellFormed else {
            return nil
        }
        return attest
    }

    public var expiresAtDate: Date? {
        return SGEntitlementTimestamp.parse(self.expiresAt)
    }

    /// The deeplink, but only when it really is a Telegram link — nil otherwise, and the UI then
    /// falls back to "send this code to @{bot}".
    ///
    /// This is the ONLY server-controlled URL the app ever opens, and it is opened behind a button
    /// that says "Open Telegram". The same threat model that forbids a JWKS endpoint
    /// (`SGEntitlementPinnedKeys`: a TLS compromise or a DNS takeover must not become authority)
    /// applies here: without this check one server response could turn that button into an
    /// external-purchase call to action with no App Store release — the one thing guideline
    /// 3.1.3(b) forbids absolutely — or into a phishing page opened mid-sign-in. The live server
    /// hardcodes the `https://t.me/` prefix; that is a server property, not a client defence.
    public var validatedDeeplink: String? {
        guard let deeplink = self.deeplink, !deeplink.isEmpty else {
            return nil
        }
        guard let url = URL(string: deeplink), url.scheme?.lowercased() == "https" else {
            return nil
        }
        guard let host = url.host?.lowercased(), SGEntitlementBindStart.telegramHosts.contains(host) else {
            return nil
        }
        return deeplink
    }

    private static let telegramHosts: Set<String> = ["t.me", "telegram.me", "telegram.dog"]
}

/// The `attest` block of `POST /v1/bind/start` (bind-attest v1.1). The client, signed in to Telegram
/// as the account being linked, asks Telegram over MTProto for the bot's Main Mini App with this
/// `start_param` (`messages.requestMainWebView`, peer = bot = the bot); Telegram answers with a URL
/// whose fragment carries `initData` SIGNED BY TELEGRAM, `start_param` included. The URL is never
/// opened and no message reaches the bot: the `initData` goes to `POST /v1/bind/attest`, which
/// verifies it and confirms this one bind. The server's `url` field is not used by this client.
public struct SGEntitlementBindAttest: Equatable, Decodable, Sendable {
    /// The bot's numeric Telegram user id, as a decimal string.
    public let botId: String
    public let botUsername: String
    /// `"zb" + code`: Telegram signs it into the `initData`, which ties the assertion to this bind.
    public let startParam: String

    /// Telegram user ids fit in JSON's exact integer range; the server refuses anything larger.
    private static let maxUserId: Int64 = 9_007_199_254_740_991
    /// `/bind/attest` accepts at most 8 KiB of body; this leaves room for the poll token and JSON.
    static let maxInitDataBytes = 7 * 1024
    private static let usernameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    private static let startParamCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    public init(botId: String, botUsername: String, startParam: String) {
        self.botId = botId
        self.botUsername = botUsername
        self.startParam = startParam
    }

    /// `botId` as a Telegram user id: plain decimal digits, positive, at most 2^53−1. nil otherwise.
    public var botUserId: Int64? {
        guard !self.botId.isEmpty, self.botId.count <= 16, self.botId.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int64(self.botId) else {
            return nil
        }
        guard value > 0, value <= SGEntitlementBindAttest.maxUserId else {
            return nil
        }
        return value
    }

    /// Every field is something Telegram can be asked about unambiguously: a numeric bot id, a
    /// Telegram username (5–32 of `[A-Za-z0-9_]`, starting with a letter) and a `start_param` of
    /// 1–64 `[A-Za-z0-9_-]` (Telegram's own limit). Anything else uses the code flow.
    public var isWellFormed: Bool {
        guard self.botUserId != nil else {
            return false
        }
        let username = self.botUsername
        guard (5 ... 32).contains(username.count), username.unicodeScalars.allSatisfy({ SGEntitlementBindAttest.usernameCharacters.contains($0) }), let first = username.unicodeScalars.first, CharacterSet.letters.contains(first) else {
            return false
        }
        guard (1 ... 64).contains(self.startParam.count), self.startParam.unicodeScalars.allSatisfy({ SGEntitlementBindAttest.startParamCharacters.contains($0) }) else {
            return false
        }
        return true
    }

    /// Whether the peer `@botUsername` resolved to IN THE ACCOUNT BEING LINKED is this bind's bot,
    /// able to answer: a bot whose user id is `botId` and that has a Main Mini App
    /// (`bot_has_main_app`). Anything else — not found, not a bot, another id, no Main Mini App — is
    /// the code flow, never a request to some other bot.
    public func matchesResolvedBot(userId: Int64?, isBot: Bool, hasMainApp: Bool) -> Bool {
        guard isBot, hasMainApp, let userId, let expected = self.botUserId else {
            return false
        }
        return userId == expected
    }

    /// `init_data` for `/bind/attest`: the `tgWebAppData` parameter of the fragment of the URL
    /// `messages.requestMainWebView` returned, percent-decoded exactly ONCE. The result is itself
    /// `application/x-www-form-urlencoded` (`user=%7B…&auth_date=…&signature=…&hash=…`) and is sent
    /// as is. nil when the fragment has no such parameter, has it twice, it is empty, or it is larger
    /// than the endpoint accepts.
    public static func initData(fromWebAppURL url: String) -> String? {
        guard let hash = url.firstIndex(of: "#") else {
            return nil
        }
        let fragment = url[url.index(after: hash)...]
        var found: Substring?
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "tgWebAppData" else {
                continue
            }
            guard found == nil else {
                return nil
            }
            found = parts[1]
        }
        guard let encoded = found, let decoded = String(encoded).removingPercentEncoding, !decoded.isEmpty, decoded.utf8.count <= SGEntitlementBindAttest.maxInitDataBytes else {
            return nil
        }
        return decoded
    }
}

/// `POST /v1/bind/attest` 200: `{"schema_version":1,"state":"confirmed","server_time":"…"}`.
struct SGEntitlementBindAttestEnvelope: Decodable {
    let state: String?
}

public struct SGEntitlementBindAccount: Equatable, Decodable {
    public let id: String
    public let tgUserId: Int64?
    /// The ladder reason: `vip`, `paid`, `trial` or `locked`.
    public let status: String?
    public let until: String?
}

public struct SGEntitlementBindDevice: Equatable, Decodable {
    /// Equals the JWS `dev` claim. STORE IT: every later verification checks the token against it.
    public let id: String
}

/// The one winning `POST /v1/bind/poll`.
public struct SGEntitlementBindConfirmation: Equatable, Decodable {
    public let refreshToken: String
    public let entitlement: String
    public let account: SGEntitlementBindAccount?
    public let device: SGEntitlementBindDevice?
    /// True means the sign-in SUCCEEDED and this phone also holds an Apple-only account with a
    /// different subscription. Show a non-blocking notice; never block the session.
    public let mergeConflict: Bool?
}

public enum SGEntitlementBindPollResult: Equatable {
    case pending
    case denied
    case expired
    /// The material went somewhere else. Restart from `/bind/start` and say "that did not go
    /// through" — never "you are signed in".
    case consumed
    case confirmed(SGEntitlementBindConfirmation)
    /// Local, never from the server: the install key is no longer the key this `/bind/start`
    /// registered, so NOTHING was sent — the poll was not consumed. The server would issue the
    /// session for the old key, which this install can no longer sign with. Start a fresh
    /// `/bind/start` with the current key.
    case restartBind
}

// MARK: - Entitlement

/// `POST /v1/entitlement/refresh` — rotates the refresh token.
public struct SGEntitlementRefreshResult: Equatable {
    public let entitlement: String
    /// The NEW refresh token. Already persisted by the client before this value is handed back.
    public let refreshToken: String
    /// The new refresh token's 90-day expiry.
    public let expiresAt: String?
    public let until: String?
}

/// `GET /v1/entitlement` — does not rotate. A LAPSED account is a 200 here: the JWS simply carries
/// `ent: []` and `until: null`. Lapse is expressed in the token, never in a status code.
public struct SGEntitlementFetchResult: Equatable, Decodable {
    public let entitlement: String
    public let until: String?
}

/// `POST /v1/trial/start`
public struct SGEntitlementTrialResult: Equatable, Decodable {
    public let entitlement: String
    public let trialEndsAt: String?

    public var trialEndsAtDate: Date? {
        guard let value = self.trialEndsAt else {
            return nil
        }
        return SGEntitlementTimestamp.parse(value)
    }
}

// MARK: - Apple

/// `POST /v1/apple/prepare`. Mandatory for a LINKED account's new purchase (every failure refuses);
/// an unlinked install skips it and buys with no `appAccountToken` (`SGIAPPurchaseAdmission`).
public struct SGEntitlementApplePrepare: Equatable, Decodable {
    /// Lowercase UUID for StoreKit's `.appAccountToken(_:)`. Opaque, no PII — Apple's own rule, and
    /// the reason the Telegram id never goes near it.
    public let appAccountToken: String
    public let productId: String
    public let expiresAt: String?

    public var appAccountTokenUUID: UUID? {
        return UUID(uuidString: self.appAccountToken)
    }
}

public struct SGEntitlementAppleAccount: Equatable, Decodable {
    public let id: String
    /// The denormalised column: `none | trial | active | grace | expired | revoked`.
    public let status: String?
    /// The ladder: `vip | paid | trial | locked`.
    public let reason: String?
    public let until: String?
    public let source: String?
    public let linkedTelegram: Bool?
}

public struct SGEntitlementAppleTransaction: Equatable, Decodable {
    public let transactionId: String?
    public let originalTransactionId: String?
    public let productId: String?
    public let environment: String?
    public let expiresAt: String?
}

/// `POST /v1/apple/attach`
public struct SGEntitlementAppleAttach: Equatable, Decodable {
    /// False means this exact transaction had already been applied — a replay. That is SUCCESS:
    /// `finish()` the transaction.
    public let granted: Bool
    /// NULL on the unauthenticated path: there is no binding to mint a token for. Fall back to the
    /// StoreKit snapshot and prompt — but never force — the user to link Telegram.
    public let entitlement: String?
    public let account: SGEntitlementAppleAccount?
    public let transaction: SGEntitlementAppleTransaction?
}

/// `GET /v1/health`. Always 200, even when degraded. Never gate anything on it and never call it on
/// launch.
public struct SGEntitlementHealth: Equatable, Decodable {
    public let ok: Bool
    public let version: String?
}
