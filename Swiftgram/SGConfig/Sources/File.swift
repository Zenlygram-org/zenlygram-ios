import Foundation
import BuildConfig

public struct SGConfig: Codable {
    // MARK: Zenlygram — exposed so a consumer can tell "the config said this" from "the config said
    // nothing". `SGEntitlementClient.Configuration.shipped` refuses to bind against it: it is
    // upstream Swiftgram's host, so reaching it means `api_url` was left out of `sg_config`.
    public static let defaultApiUrl = "https://api.swiftgram.app"
    public static let defaultConsentMode = "required"
    public static let defaultTasksWire = 4

    public var apiUrl: String = SGConfig.defaultApiUrl
    public var webappUrl: String = "https://my.swiftgram.app"
    public var botUsername: String = "SwiftgramBot"
    public var publicKey: String?
    public var iaps: [String] = []
    // MARK: Zenlygram — entitlement signing keys, `kid` -> PEM (or base64 SPKI DER). Design 4.6 ships
    // TWO pinned keys (the active one and the next one) so a server-side key rotation lands without an
    // App Store release. `publicKey` stays as the single-key fallback (see SGEntitlementPinnedKeys).
    public var entitlementKeys: [String: String]?
    // MARK: Zenlygram — where `appstore/privacy-policy.html` is hosted. It is a DEPLOYMENT fact, not a
    // translatable string, so it lives here rather than in ten `.strings` files (where it drifted and
    // still pointed at Telegram's policy). Guideline 3.1.2 wants the paywall to link the app's OWN
    // policy, and 5.1.1(i) wants that policy to describe what the entitlement server receives —
    // neither is true of telegram.org/privacy. When it is absent the paywall shows the disclosure
    // with no hyperlinks at all rather than link somebody else's policy.
    public var privacyPolicyUrl: String?
    // MARK: Zenlygram — the anonymous signed monetization policy, configured on its own: the exact
    // `https://host/v1/monetization` endpoint and the `kid` -> key ring that verifies the policy and
    // nothing else. Both optional and independent of `apiUrl` / `entitlementKeys` / `publicKey`:
    // neither falls back to those, and neither activates the authenticated entitlement client.
    // See `SGEntitlementPublicPolicyConfiguration`.
    public var publicPolicyUrl: String?
    public var publicPolicyKeys: [String: String]?
    // MARK: Zenlygram — the explicit switch for every Apple operation (StoreKit listener, snapshot,
    // provenance re-read, attach outbox drain/delivery, Restore, products, purchase) and for the
    // StoreKit fallback grant. Build-only and false unless `sg_config` says JSON `true`: an
    // authenticated configuration and a product list are NOT activation authority on their own. See
    // `SGEntitlementAppleBackendConfiguration`.
    public var appleBackendEnabled: Bool = false
    // MARK: Zenlygram — customer data (design 40 §3, contract §5.4 / §6.1). `consent_mode` is a build-time
    // fact the server never toggles: `required` (the default, also when absent) or `optional`; any other
    // string is kept as written so the consumer can refuse it (BuildConfiguration.py refuses it first).
    // `consent_operator` holds the four values the consent text names, each still percent-encoded UTF-8
    // as sg_config carries them; `SGConsentOperatorValues.fromConfig` decodes and checks them.
    public var consentMode: String = SGConfig.defaultConsentMode
    public var consentOperator: SGConsentOperatorConfig?
    // MARK: Zenlygram — `sg_config.tasks_wire` (wf15 §8.2): the `X-Tasks-Wire` value every Tasks request of
    // this build sends, 4 (the default, also when the key is absent or mistyped) or 5. A server that does not
    // accept the value answers 422 before authentication on every request, so the wire is a build-time fact
    // the client never probes: `BuildConfiguration.py` accepts only the integers 4 and 5 and refuses 5 for an
    // App Store build or a build pointed at the production server until the backend that accepts 5 is
    // deployed there. Kept as written here; `SGTasksShippedWire.requestWire` (SGEntitlement) clamps it to
    // the wires the client speaks.
    public var tasksWire: Int = SGConfig.defaultTasksWire
    /// Whether `sg_config` NAMED either public-policy key at all — present with a valid value, `null`
    /// or a wrong type alike. A build that asked for the public policy and got it wrong must fail
    /// closed into the public-only mode, never fall back to the legacy (authenticated-build) policy
    /// path and its StoreKit cleanup. Read-only; not part of the JSON shape.
    public private(set) var publicPolicyRequested: Bool = false
    #if SG_LENTA
    // MARK: Zenlygram — `sg_config.lenta_iaps`: the Lenta product ids (Lenta Plus, premium-name tiers, auction
    // steps). SGIAP hands their transactions to the Lenta handler instead of the Pro engine; Pro restore and the
    // Pro snapshot never count them. Only in flag-on builds: `BuildConfiguration.py` strips the key from a
    // flag-off build's sg_config, and this property does not exist there.
    public var lentaIaps: [String] = []
    #endif

    // Raw values are the camelCase names: `convertFromSnakeCase` rewrites the JSON keys before matching.
    enum CodingKeys: String, CodingKey {
        case apiUrl
        case webappUrl
        case botUsername
        case publicKey
        case iaps
        case entitlementKeys
        case privacyPolicyUrl
        case publicPolicyUrl
        case publicPolicyKeys
        case appleBackendEnabled
        #if SG_LENTA
        case lentaIaps
        #endif
        case consentMode
        case consentOperator
        case tasksWire
    }
}

/// Zenlygram — `sg_config.consent_operator`. A typed struct, not `[String: String]`: `convertFromSnakeCase`
/// rewrites dictionary keys too, so `responsible_person` would arrive as `responsiblePerson` in a
/// dictionary. Each value is optional and decoded on its own, like `SGConfig`'s fields: a missing or
/// mistyped value is nil (the consent pipeline reads it as missing), never the whole object.
public struct SGConsentOperatorConfig: Codable, Equatable {
    public var name: String?
    public var stir: String?
    public var responsiblePerson: String?
    public var contactEmail: String?

    public init(name: String? = nil, stir: String? = nil, responsiblePerson: String? = nil, contactEmail: String? = nil) {
        self.name = name
        self.stir = stir
        self.responsiblePerson = responsiblePerson
        self.contactEmail = contactEmail
    }

    // Raw values are the camelCase names: `convertFromSnakeCase` rewrites the nested JSON keys as well.
    enum CodingKeys: String, CodingKey {
        case name
        case stir
        case responsiblePerson
        case contactEmail
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.stir = try? container.decodeIfPresent(String.self, forKey: .stir)
        self.responsiblePerson = try? container.decodeIfPresent(String.self, forKey: .responsiblePerson)
        self.contactEmail = try? container.decodeIfPresent(String.self, forKey: .contactEmail)
    }
}

// MARK: Zenlygram — the synthesized decoder ignores property defaults, so ONE missing or mistyped key
// (`webapp_url` was missing from the App Store sg_config) threw, and `parseSGConfig` then replaced the
// whole config with `SGConfig()`: no pinned keys, no product ids, no privacy link, and no error anywhere.
// Each field now falls back to its own default on its own. An App Store build does not rely on this
// leniency: `BuildConfiguration.py` refuses one whose sg_config lacks a required key.
// In an extension so the implicit `SGConfig()` initializer survives.
extension SGConfig {
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Before any typed decode: presence alone is the build's intent.
        self.publicPolicyRequested = container.contains(.publicPolicyUrl) || container.contains(.publicPolicyKeys)
        if let value = try? container.decodeIfPresent(String.self, forKey: .apiUrl) {
            self.apiUrl = value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .webappUrl) {
            self.webappUrl = value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .botUsername) {
            self.botUsername = value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .publicKey) {
            self.publicKey = value
        }
        if let value = try? container.decodeIfPresent([String].self, forKey: .iaps) {
            self.iaps = value
        }
        if let value = try? container.decodeIfPresent([String: String].self, forKey: .entitlementKeys) {
            self.entitlementKeys = value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .privacyPolicyUrl) {
            self.privacyPolicyUrl = value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .publicPolicyUrl) {
            self.publicPolicyUrl = value
        }
        if let value = try? container.decodeIfPresent([String: String].self, forKey: .publicPolicyKeys) {
            self.publicPolicyKeys = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .appleBackendEnabled) {
            self.appleBackendEnabled = value
        }
        #if SG_LENTA
        if let value = try? container.decodeIfPresent([String].self, forKey: .lentaIaps) {
            self.lentaIaps = value
        }
        #endif
        if let value = try? container.decodeIfPresent(String.self, forKey: .consentMode) {
            self.consentMode = value
        }
        if let value = try? container.decodeIfPresent(SGConsentOperatorConfig.self, forKey: .consentOperator) {
            self.consentOperator = value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: .tasksWire) {
            self.tasksWire = value
        }
    }
}

private func parseSGConfig(_ jsonString: String) -> SGConfig {
    let jsonData = Data(jsonString.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode(SGConfig.self, from: jsonData)) ?? SGConfig()
}

private let baseAppBundleId = Bundle.main.bundleIdentifier!
private let buildConfig = BuildConfig(baseAppBundleId: baseAppBundleId)
public let SG_CONFIG: SGConfig = parseSGConfig(buildConfig.sgConfig)
public let SG_API_WEBAPP_URL_PARSED = URL(string: SG_CONFIG.webappUrl)!