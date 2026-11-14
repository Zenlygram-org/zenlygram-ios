import Foundation

/// Zenlygram — `loc3` (contract §0.3): the three languages every consent text version carries.
public enum SGConsentLocale: String, CaseIterable, Equatable, Hashable {
    case uz
    case ru
    case en

    /// The text locale the wall opens in for an app language (U§1 rule 8, design 40 §4.2): a trailing
    /// `-raw` dropped (as SGStrings' `sanitizeLocale` does), lower-cased, the primary subtag before
    /// `-` / `_`; `uz`, `ru` and `en` map to themselves and anything else to **uz**.
    public static func forWall(languageCode: String?) -> SGConsentLocale {
        guard var code = languageCode?.lowercased() else {
            return .uz
        }
        if code.hasSuffix("-raw") {
            code = String(code.dropLast(4))
        }
        let primary = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return SGConsentLocale(rawValue: primary) ?? .uz
    }
}

/// Zenlygram — the consent scopes (contract §2.4.1). One v1 grant covers all four.
public enum SGConsentScope: String, CaseIterable, Equatable, Hashable {
    case link
    case profile
    case statistics
    case tasksSync = "tasks_sync"
}

/// Zenlygram — the consent text manifest (contract §5.2, `zenlygram-consent-manifest/1`), vendored
/// byte for byte from `B/resources/consent/manifest.json`. Validated exactly as the server's
/// `ConsentManifest::parse` does: the exact key sets, `current_version` and `min_valid_version`
/// (1 ≤ min ≤ current ≤ 32767, both present), distinct `[A-Z_]{1,64}` placeholders, per version a
/// `YYYY-MM-DD` `published_at`, distinct known scopes and exactly the uz/ru/en templates, each a
/// relative `….md` path (never absolute, never `..`) with a lowercase hex64 `template_sha256`.
public struct SGConsentManifest: Equatable {
    public static let schema = "zenlygram-consent-manifest/1"
    public static let maxVersion = 32767
    /// The largest manifest or template file read (the server's limit).
    public static let maxFileBytes = 1_048_576

    public struct Template: Equatable {
        /// Relative to the consent root, e.g. `v1/uz.md`.
        public let file: String
        public let templateSha256: String
    }

    public struct Version: Equatable {
        public let number: Int
        public let publishedAt: String
        /// In manifest order; a grant of this version names exactly these.
        public let scopes: [String]
        public let templates: [SGConsentLocale: Template]
    }

    public let currentVersion: Int
    public let minValidVersion: Int
    /// The placeholder names the canonical form replaces (C§5.3 step 2).
    public let placeholders: [String]
    public let versions: [Int: Version]

    /// The manifest of `data`, or nil when it breaks any rule above.
    public static func decode(_ data: Data) -> SGConsentManifest? {
        guard data.count <= SGConsentManifest.maxFileBytes,
              let object = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              Set(object.keys) == ["schema", "current_version", "min_valid_version", "placeholders", "versions"],
              object["schema"] as? String == SGConsentManifest.schema,
              let current = SGConsentManifest.integer(object["current_version"]),
              let minimum = SGConsentManifest.integer(object["min_valid_version"]),
              minimum >= 1, minimum <= current, current <= SGConsentManifest.maxVersion,
              let placeholders = SGConsentManifest.distinctStrings(object["placeholders"], where: SGConsentManifest.isPlaceholderName),
              let entries = object["versions"] as? [String: Any], !entries.isEmpty else {
            return nil
        }
        var versions: [Int: Version] = [:]
        for (key, value) in entries {
            guard let number = SGConsentManifest.versionNumber(key),
                  let entry = value as? [String: Any],
                  Set(entry.keys) == ["published_at", "scopes", "locales"],
                  let publishedAt = entry["published_at"] as? String, SGConsentManifest.isDay(publishedAt),
                  let scopes = SGConsentManifest.distinctStrings(entry["scopes"], where: { SGConsentScope(rawValue: $0) != nil }),
                  !scopes.isEmpty,
                  let locales = entry["locales"] as? [String: Any],
                  Set(locales.keys) == Set(SGConsentLocale.allCases.map(\.rawValue)) else {
                return nil
            }
            var templates: [SGConsentLocale: Template] = [:]
            for locale in SGConsentLocale.allCases {
                guard let template = locales[locale.rawValue] as? [String: Any],
                      Set(template.keys) == ["file", "template_sha256"],
                      let file = template["file"] as? String, SGConsentManifest.isTemplatePath(file),
                      let sha256 = template["template_sha256"] as? String, SGCustomerTime.isHex64(sha256) else {
                    return nil
                }
                templates[locale] = Template(file: file, templateSha256: sha256)
            }
            versions[number] = Version(number: number, publishedAt: publishedAt, scopes: scopes, templates: templates)
        }
        guard versions[current] != nil, versions[minimum] != nil else {
            return nil
        }
        return SGConsentManifest(currentVersion: current, minValidVersion: minimum, placeholders: placeholders, versions: versions)
    }

    /// A JSON integer (never a boolean or a fraction).
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
            return number.intValue
        default:
            return nil
        }
    }

    /// A JSON list of distinct strings, each passing `isValid`.
    private static func distinctStrings(_ value: Any?, where isValid: (String) -> Bool) -> [String]? {
        guard let items = value as? [Any] else {
            return nil
        }
        var strings: [String] = []
        for item in items {
            guard let string = item as? String, isValid(string), !strings.contains(string) else {
                return nil
            }
            strings.append(string)
        }
        return strings
    }

    /// `^[A-Z_]{1,64}$`
    static func isPlaceholderName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return !bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy { ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")) || $0 == UInt8(ascii: "_") }
    }

    /// A `versions` key: the decimal text of 1…32767 (`^[1-9][0-9]{0,4}$`).
    private static func versionNumber(_ key: String) -> Int? {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty, bytes.count <= 5, bytes[0] != UInt8(ascii: "0"),
              bytes.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let number = Int(key), number <= SGConsentManifest.maxVersion else {
            return nil
        }
        return number
    }

    /// `^\d{4}-\d{2}-\d{2}$` (ASCII digits).
    private static func isDay(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10 else {
            return false
        }
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 7 {
                guard byte == UInt8(ascii: "-") else {
                    return false
                }
            } else if !(byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) {
                return false
            }
        }
        return true
    }

    /// `^(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.md$`: inside the consent root, never absolute, never `..`.
    private static func isTemplatePath(_ path: String) -> Bool {
        guard path.hasSuffix(".md") else {
            return false
        }
        let components = String(path.dropLast(3)).split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
            }
        }
    }
}
