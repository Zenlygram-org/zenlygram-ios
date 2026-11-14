import Foundation

/// Zenlygram — one consent text exactly as the wall shows it and the grant names it.
public struct SGConsentRenderedText: Equatable {
    public let version: Int
    public let locale: SGConsentLocale
    /// The canonical form (contract §5.3) filled with this build's operator values.
    public let canonical: String
    /// `text_sha256` of `canonical`.
    public let sha256: String
    public let document: SGConsentDocument
    /// The version's scopes (manifest order): what a grant of this text names.
    public let scopes: [String]

    public init(version: Int, locale: SGConsentLocale, canonical: String, sha256: String, document: SGConsentDocument, scopes: [String]) {
        self.version = version
        self.locale = locale
        self.canonical = canonical
        self.sha256 = sha256
        self.document = document
        self.scopes = scopes
    }
}

/// Zenlygram — the bundled consent texts (design 40 §4.1): `manifest.json` plus every
/// `v{N}/{uz,ru,en}.md` under a root URL (the app: `SGCustomerSyncResources.bundle/consent`; host
/// tests: `Resources/consent`). Valid only when the manifest is and EVERY template recomputes to its
/// `template_sha256`; otherwise `load` fails and the app's activation is `.failed(.text)`.
public final class SGConsentTextRepository {
    public enum Problem: String, Error, Equatable {
        case manifestUnreadable = "manifest_unreadable"
        case manifestMalformed = "manifest_malformed"
        case templateUnreadable = "template_unreadable"
        case templateMismatch = "template_mismatch"

        public var logCode: SGCustomerLogCode {
            switch self {
            case .manifestUnreadable:
                return .consentManifestUnreadable
            case .manifestMalformed:
                return .consentManifestMalformed
            case .templateUnreadable:
                return .consentTemplateUnreadable
            case .templateMismatch:
                return .consentTemplateMismatch
            }
        }
    }

    public let manifest: SGConsentManifest
    private let templates: [Int: [SGConsentLocale: String]]
    private let lock = NSLock()
    private var renderedHashes: [RenderKey: String] = [:]

    private struct RenderKey: Hashable {
        let version: Int
        let locale: SGConsentLocale
        let values: [String: String]
    }

    private init(manifest: SGConsentManifest, templates: [Int: [SGConsentLocale: String]]) {
        self.manifest = manifest
        self.templates = templates
    }

    /// Reads and verifies the tree under `rootURL`.
    public static func load(rootURL: URL) -> Result<SGConsentTextRepository, Problem> {
        guard let data = SGConsentTextRepository.read(rootURL.appendingPathComponent("manifest.json")) else {
            return .failure(.manifestUnreadable)
        }
        guard let manifest = SGConsentManifest.decode(data) else {
            return .failure(.manifestMalformed)
        }
        var templates: [Int: [SGConsentLocale: String]] = [:]
        for version in manifest.versions.keys.sorted() {
            guard let entry = manifest.versions[version] else {
                continue
            }
            for locale in SGConsentLocale.allCases {
                guard let template = entry.templates[locale] else {
                    return .failure(.manifestMalformed)
                }
                guard let bytes = SGConsentTextRepository.read(rootURL.appendingPathComponent(template.file)),
                      let text = SGConsentCanonicalText.decodeUTF8(bytes),
                      let hash = try? SGConsentCanonicalText.canonicalSha256(template: text, values: [:], placeholders: manifest.placeholders) else {
                    return .failure(.templateUnreadable)
                }
                guard hash == template.templateSha256 else {
                    return .failure(.templateMismatch)
                }
                templates[version, default: [:]][locale] = text
            }
        }
        return .success(SGConsentTextRepository(manifest: manifest, templates: templates))
    }

    public var currentVersion: Int {
        return self.manifest.currentVersion
    }

    public var minValidVersion: Int {
        return self.manifest.minValidVersion
    }

    public func isBundled(version: Int) -> Bool {
        return self.templates[version] != nil
    }

    /// The scopes a grant of `version` names, or nil when it is not bundled.
    public func scopes(version: Int) -> [String]? {
        return self.manifest.versions[version]?.scopes
    }

    /// `version` in `locale` filled with `operatorValues` (a missing value keeps its placeholder),
    /// or nil when the version is not bundled or a value is refused by the canonical form.
    public func render(version: Int, locale: SGConsentLocale, operatorValues: SGConsentOperatorValues) -> SGConsentRenderedText? {
        guard let template = self.templates[version]?[locale], let scopes = self.scopes(version: version),
              let canonical = try? SGConsentCanonicalText.canonical(template: template, values: operatorValues.placeholderValues, placeholders: self.manifest.placeholders) else {
            return nil
        }
        let sha256 = SGConsentCanonicalText.sha256(canonical)
        self.lock.lock()
        self.renderedHashes[RenderKey(version: version, locale: locale, values: operatorValues.placeholderValues)] = sha256
        self.lock.unlock()
        return SGConsentRenderedText(version: version, locale: locale, canonical: canonical, sha256: sha256, document: SGConsentDocument.parse(canonical), scopes: scopes)
    }

    /// The `text_sha256` this build renders for (`version`, `locale`) — nil when the version is not
    /// bundled. Cached per (version, locale, values) for the life of the repository (the process).
    public func renderedSha256(version: Int, locale: SGConsentLocale, operatorValues: SGConsentOperatorValues) -> String? {
        let key = RenderKey(version: version, locale: locale, values: operatorValues.placeholderValues)
        self.lock.lock()
        let cached = self.renderedHashes[key]
        self.lock.unlock()
        if let cached {
            return cached
        }
        guard let template = self.templates[version]?[locale],
              let sha256 = try? SGConsentCanonicalText.canonicalSha256(template: template, values: key.values, placeholders: self.manifest.placeholders) else {
            return nil
        }
        self.lock.lock()
        self.renderedHashes[key] = sha256
        self.lock.unlock()
        return sha256
    }

    private static func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count <= SGConsentManifest.maxFileBytes else {
            return nil
        }
        return data
    }
}
