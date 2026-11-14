import Foundation
import BuildConfig
import AccountContext
import SGConfig
import SGCustomerSyncCore

/// Zenlygram — what this build says about customer data (design 40 §1, §3, §4.1), read once: the
/// consent mode, the operator values the consent text names, the `api_url` host, the privacy-policy
/// URL, the distribution and the bundled consent tree. `activation(...)` decides from them whether
/// the pipeline runs at all.
///
/// `consent_mode` / `consent_operator` are read from the raw `sg_config` JSON (contract §5.4: the
/// contract's snake_case keys, with the per-field leniency `SGConfig` uses — a missing or mistyped
/// value is absent), so this module depends on no typed `SGConfig` field for them.
public struct SGCustomerSyncConfig {
    /// Why a build that ships the authenticated backend runs no customer-data pipeline.
    public enum Failure: Equatable {
        /// The bundled manifest or a template is unreadable or does not verify (`template_sha256`).
        case text(SGConsentTextRepository.Problem)
        /// Operator values are missing and the `api_url` host is not a local one.
        case operatorMissing
        /// An operator value is malformed.
        case operatorInvalid
        /// `consent_mode` is neither `required` nor `optional`.
        case mode
        /// The event queue has no usable location (Application Support, the origin's storage token).
        case storage

        /// The one log line `.failed` writes (a stable code, never a value).
        public var logCode: SGCustomerLogCode {
            switch self {
            case let .text(problem):
                return problem.logCode
            case .operatorMissing:
                return .consentOperatorMissing
            case .operatorInvalid:
                return .consentOperatorInvalid
            case .mode:
                return .consentModeInvalid
            case .storage:
                return .customerStorageUnavailable
            }
        }
    }

    /// Design 40 §1.
    public enum Activation: Equatable {
        /// The build does not ship the authenticated backend (or this is not the main app): nothing
        /// is shown or sent and `SGCustomerDataGate.isPipelineActive` stays false (Tasks `.legacy`).
        case notShipped
        /// The wall, the uploads, the automatic link and the analytics run.
        case active
        /// The backend is shipped but the pipeline cannot run safely: no wall and nothing customer-data
        /// related is sent, the bind providers answer code-only, and the pipeline reads as active
        /// with every clearance `[]` — Tasks `.forbidden`, so no to-do content leaves the device.
        case failed(Failure)
    }

    /// `sg_config.consent_mode`; nil when present but neither value (`required` when absent).
    public let mode: SGConsentMode?
    /// `sg_config.consent_operator`, percent-decoded and checked (`SGConsentOperatorValues`).
    public let operatorValues: SGConsentOperatorValues
    /// `SG_CONFIG.apiUrl`'s host (lower-cased by `URL`), for the local-host rule.
    public let apiHost: String?
    /// `SG_CONFIG.privacyPolicyUrl` when it is an https URL with a host.
    public let privacyPolicyURL: URL?
    /// `GlobalExperimentalSettings.isAppStoreBuild` (set from `BuildConfig` by AppDelegate).
    public let isAppStoreBuild: Bool
    /// `SGCustomerSyncResources.bundle/consent`, the vendored consent tree.
    public let consentRootURL: URL?

    public init(mode: SGConsentMode?, operatorValues: SGConsentOperatorValues, apiHost: String?, privacyPolicyURL: URL?, isAppStoreBuild: Bool, consentRootURL: URL?) {
        self.mode = mode
        self.operatorValues = operatorValues
        self.apiHost = apiHost
        self.privacyPolicyURL = privacyPolicyURL
        self.isAppStoreBuild = isAppStoreBuild
        self.consentRootURL = consentRootURL
    }

    /// This build's values.
    public static func current() -> SGCustomerSyncConfig {
        let sgConfig = BuildConfig(baseAppBundleId: Bundle.main.bundleIdentifier ?? "").sgConfig
        let consent = SGCustomerSyncConfig.consentKeys(sgConfigJSON: sgConfig)
        return SGCustomerSyncConfig(
            mode: consent.mode,
            operatorValues: consent.operatorValues,
            apiHost: URL(string: SG_CONFIG.apiUrl)?.host,
            privacyPolicyURL: SGCustomerSyncConfig.httpsURL(SG_CONFIG.privacyPolicyUrl),
            isAppStoreBuild: GlobalExperimentalSettings.isAppStoreBuild,
            consentRootURL: SGCustomerSyncConfig.bundledConsentRootURL()
        )
    }

    /// The pipeline's activation (design 40 §1), in this order: no authenticated backend (or no
    /// customer-data authority: an extension) → `.notShipped`; then the mode, the bundled texts
    /// (every `template_sha256` must verify) and the operator values (missing values are accepted
    /// only for a local `api_url` host); then the queue location.
    public static func activation(backendShipped: Bool, hasAuthority: Bool, mode: SGConsentMode?, texts: Result<SGConsentTextRepository, SGConsentTextRepository.Problem>, operatorValues: SGConsentOperatorValues, apiHost: String?, hasQueueStore: Bool) -> Activation {
        guard backendShipped, hasAuthority else {
            return .notShipped
        }
        guard mode != nil else {
            return .failed(.mode)
        }
        if case let .failure(problem) = texts {
            return .failed(.text(problem))
        }
        guard operatorValues.isUsable(apiHost: apiHost) else {
            return .failed(operatorValues.hasInvalid ? .operatorInvalid : .operatorMissing)
        }
        guard hasQueueStore else {
            return .failed(.storage)
        }
        return .active
    }

    /// `consent_mode` and `consent_operator` of the `sg_config` JSON text. A mistyped value reads as
    /// absent (mode `required`, operator values missing); a mode string other than the two is nil.
    static func consentKeys(sgConfigJSON: String) -> (mode: SGConsentMode?, operatorValues: SGConsentOperatorValues) {
        let object = (try? JSONSerialization.jsonObject(with: Data(sgConfigJSON.utf8), options: [])) as? [String: Any] ?? [:]
        let mode: SGConsentMode?
        if let value = object["consent_mode"] as? String {
            mode = SGConsentMode(rawValue: value)
        } else {
            mode = .required
        }
        let values = object["consent_operator"] as? [String: Any] ?? [:]
        let operatorValues = SGConsentOperatorValues.fromConfig(
            name: values["name"] as? String,
            stir: values["stir"] as? String,
            responsiblePerson: values["responsible_person"] as? String,
            contactEmail: values["contact_email"] as? String
        )
        return (mode, operatorValues)
    }

    static func httpsURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// `SGCustomerSyncResources.bundle/consent` next to this module's code (the SGAutoProxy
    /// precedent), else in the main bundle.
    static func bundledConsentRootURL() -> URL? {
        for bundle in [Bundle(for: SGCustomerSyncResourcesAnchor.self), Bundle.main] {
            if let url = bundle.url(forResource: "SGCustomerSyncResources", withExtension: "bundle") {
                return url.appendingPathComponent("consent", isDirectory: true)
            }
        }
        return nil
    }
}

/// Locates this module's code bundle.
private final class SGCustomerSyncResourcesAnchor {}

extension SGCustomerLogCode {
    static let consentModeInvalid = SGCustomerLogCode("consent_mode_invalid")
    static let customerStorageUnavailable = SGCustomerLogCode("customer_storage_unavailable")
}
