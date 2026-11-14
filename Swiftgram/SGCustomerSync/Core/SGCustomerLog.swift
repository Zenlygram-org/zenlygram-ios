import Foundation

/// Zenlygram — a stable log code (`^[a-z0-9][a-z0-9_.-]{0,63}$`, contract §3.4 `error_code`). It is
/// built only from text written in source (`StaticString`) or from a server code on the allowlist
/// below, so no runtime value — a phone number, a name, a username, a token, `initData`, a body —
/// can ever become one.
public struct SGCustomerLogCode: Hashable, CustomStringConvertible {
    public let rawValue: String

    /// A code written in source, e.g. `SGCustomerLogCode("wall_build_failed")`. Text that is not a
    /// stable code becomes `invalid_code`.
    public init(_ code: StaticString) {
        let text = code.description
        self.rawValue = SGCustomerLogCode.isStableCode(text) ? text : "invalid_code"
    }

    public var description: String {
        return self.rawValue
    }

    /// A code the server (or the transport) answered with: its own code when it is one this
    /// contract defines, `http_<nnn>` as such, anything else `server_other`.
    public static func server(_ code: String?) -> SGCustomerLogCode {
        guard let code else {
            return .serverOther
        }
        if let known = SGCustomerLogCode.knownServerCodes[code] {
            return known
        }
        let bytes = Array(code.utf8)
        if bytes.count == 8, code.hasPrefix("http_"), bytes[5...].allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            return SGCustomerLogCode(validated: code)
        }
        return .serverOther
    }

    /// `^[a-z0-9][a-z0-9_.-]{0,63}$`
    public static func isStableCode(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first, bytes.count <= 64 else {
            return false
        }
        func isLowerAlnum(_ byte: UInt8) -> Bool {
            return (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        }
        return isLowerAlnum(first) && bytes.dropFirst().allSatisfy { isLowerAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    private init(validated: String) {
        self.rawValue = validated
    }

    // MARK: - Codes of the consent half

    public static let serverOther = SGCustomerLogCode("server_other")
    public static let consentManifestUnreadable = SGCustomerLogCode("consent_manifest_unreadable")
    public static let consentManifestMalformed = SGCustomerLogCode("consent_manifest_malformed")
    public static let consentTemplateUnreadable = SGCustomerLogCode("consent_template_unreadable")
    public static let consentTemplateMismatch = SGCustomerLogCode("consent_template_mismatch")
    public static let consentOperatorMissing = SGCustomerLogCode("consent_operator_missing")
    public static let consentOperatorInvalid = SGCustomerLogCode("consent_operator_invalid")
    public static let consentStoreUnreadable = SGCustomerLogCode("consent_store_unreadable")
    public static let consentSaveFailed = SGCustomerLogCode("consent_save_failed")
    public static let consentRejected = SGCustomerLogCode("consent_rejected")
    public static let consentWithdrawKept = SGCustomerLogCode("consent_withdraw_kept")
    public static let consentReupload = SGCustomerLogCode("consent_reupload")
    public static let consentWithdrawnRemote = SGCustomerLogCode("consent_withdrawn_remote")
    public static let consentNeedsReconsent = SGCustomerLogCode("consent_needs_reconsent")
    public static let consentForeignDuplicate = SGCustomerLogCode("consent_foreign_duplicate")
    public static let consentStale = SGCustomerLogCode("consent_stale")
    public static let wallBuildFailed = SGCustomerLogCode("wall_build_failed")

    /// Every stable code the contract's routes answer with (C§0.1, C§2.1, amendment A3, the bind and
    /// attest codes of design 40 §8) and the transport's own.
    private static let knownServerCodes: [String: SGCustomerLogCode] = {
        let codes: [StaticString] = [
            // 401 family and its reason
            "unauthenticated", "clock_skew", "nonce_replayed", "invalid_token", "expired_token", "session_revoked",
            "refresh_reuse", "device_revoked", "device_key_mismatch", "account_erased",
            // customer-data routes
            "invalid_consent", "profile_account_not_linked", "profile_account_mismatch", "consent_required",
            "no_consent", "withdrawn", "reconsent_required", "consent_version_unknown", "consent_version_retired",
            "consent_text_mismatch", "consent_scopes_mismatch", "consent_age_required", "consent_id_mismatch",
            "unsupported_schema_version", "invalid_request", "payload_too_large", "profile_unavailable",
            "idempotency_in_flight", "rate_limited", "server_error",
            // bind and attest
            "consent_stale", "consent_required_local", "bind_superseded_local", "bind_conflict", "bind_paused", "bind_not_found", "bind_expired",
            "attest_unavailable", "attest_invalid", "attest_stale", "attest_mismatch", "attest_bot_not_found",
            "attest_bot_mismatch", "attest_no_main_app", "attest_webview_failed", "attest_no_init_data",
            // transport
            "timeout", "offline", "unknown",
        ]
        var table: [String: SGCustomerLogCode] = [:]
        for code in codes {
            let value = SGCustomerLogCode(code)
            table[value.rawValue] = value
        }
        return table
    }()
}

/// Zenlygram — the ONLY logging path of the customer-data layer (design 40 §1). It takes typed
/// values only — a code, a route, an HTTP status — and no `String`, so it can never carry a phone,
/// a name, a username, a token, `initData` or a body. SGCustomerSync wires `sink` to the app's
/// logger once (its single logging call site); until then every entry is dropped. Core itself
/// never logs anywhere else.
public enum SGCustomerLog {
    public struct Entry: Equatable {
        public let code: SGCustomerLogCode
        public let route: SGCustomerRoute?
        /// An HTTP status (100…599); anything else is dropped.
        public let status: Int?

        /// `<code>[ route=<route>][ status=<nnn>]`
        public var line: String {
            var line = self.code.rawValue
            if let route = self.route {
                line += " route=\(route.rawValue)"
            }
            if let status = self.status {
                line += " status=\(status)"
            }
            return line
        }
    }

    private static let lock = NSLock()
    private static var installedSink: ((Entry) -> Void)?

    /// Set once by SGCustomerSync, forwarding `entry.line` to the app's logger under the tag
    /// `SGCustomerSync`.
    public static var sink: ((Entry) -> Void)? {
        get {
            SGCustomerLog.lock.lock()
            defer {
                SGCustomerLog.lock.unlock()
            }
            return SGCustomerLog.installedSink
        }
        set {
            SGCustomerLog.lock.lock()
            SGCustomerLog.installedSink = newValue
            SGCustomerLog.lock.unlock()
        }
    }

    public static func log(_ code: SGCustomerLogCode, route: SGCustomerRoute? = nil, status: Int? = nil) {
        guard let sink = SGCustomerLog.sink else {
            return
        }
        sink(Entry(code: code, route: route, status: status.flatMap { (100 ... 599).contains($0) ? $0 : nil }))
    }
}
