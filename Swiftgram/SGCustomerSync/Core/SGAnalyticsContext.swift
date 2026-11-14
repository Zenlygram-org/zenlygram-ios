import CryptoKit
import Foundation

/// Zenlygram — `device_class` (contract §2.4.3: iOS `userInterfaceIdiom == .pad` → tablet).
public enum SGCustomerDeviceClass: String, CaseIterable, Equatable {
    case phone
    case tablet
}

/// Zenlygram — `distribution`, the values an iOS build can be (contract §2.4.3; `play` and `direct`
/// are Android's): `GlobalExperimentalSettings.isAppStoreBuild` false → `debug`; true with a
/// `sandboxReceipt` → `testflight`; else `appstore` (design 40 §9.2).
public enum SGCustomerDistribution: String, CaseIterable, Equatable {
    case appstore
    case testflight
    case debug
}

/// Zenlygram — the device facts the app reads (`SGDeviceInfo`, design 40 §9.2), as read: the
/// analytics context and the profile snapshot normalise them (`SGCustomerNormalise`). Never the
/// user-assigned device name, an advertising id or anything about chats (contract §6.9).
public struct SGCustomerDeviceFacts: Equatable {
    public var deviceClass: SGCustomerDeviceClass
    /// `utsname.machine` (`iPhone17,1`); simulator: `SIMULATOR_MODEL_IDENTIFIER`.
    public var deviceModel: String?
    /// `UIDevice.current.systemVersion`.
    public var osVersion: String
    /// `CFBundleShortVersionString`.
    public var appVersion: String
    /// `CFBundleVersion`.
    public var appBuild: String?
    /// `presentationData.strings.baseLanguageCode` (`uz`, `pt-br`, `zh-hans-raw`, …).
    public var uiLanguage: String?
    /// `Locale.current` as `language[-Script][-REGION]` or its identifier (`uz_UZ`, `en_US@…`).
    public var locale: String?
    /// `TimeZone.current.identifier`.
    public var timezone: String?
    public var distribution: SGCustomerDistribution

    public init(deviceClass: SGCustomerDeviceClass, deviceModel: String?, osVersion: String, appVersion: String, appBuild: String?, uiLanguage: String?, locale: String?, timezone: String?, distribution: SGCustomerDistribution) {
        self.deviceClass = deviceClass
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.uiLanguage = uiLanguage
        self.locale = locale
        self.timezone = timezone
        self.distribution = distribution
    }
}

/// Zenlygram — the normalisations of the device values every body carries (contract §0.3, §0.2):
/// strict ones (`ver`) always produce a valid value, descriptive ones produce nil instead of a value
/// the server would store as null.
public enum SGCustomerNormalise {
    /// `ver` (`^[0-9A-Za-z._+() -]{1,32}$`): other characters dropped, at most 32 kept, `0` when
    /// nothing is left. ProfileBoundary refuses a top-level `app_version` / `os_version` outside it
    /// on every profile route, and the events context's are strict too.
    public static func version(_ raw: String) -> String {
        return SGConsentEvent.clippedVersion(raw)
    }

    /// A descriptive `ver` (`app_build`): like `version`, nil when nothing but spaces is left.
    public static func optionalVersion(_ raw: String?) -> String? {
        guard let raw, raw.unicodeScalars.contains(where: { $0 != " " && SGCustomerNormalise.isVersionScalar($0) }) else {
            return nil
        }
        return SGConsentEvent.clippedVersion(raw)
    }

    /// `model` (printable ASCII, 1…64): white space as one space, other characters outside printable
    /// ASCII dropped, trimmed, clipped to 64; nil when nothing is left.
    public static func model(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        var scalars: [Unicode.Scalar] = []
        for scalar in raw.unicodeScalars {
            if SGConsentCanonicalText.isWhiteSpace(scalar) {
                if let last = scalars.last, last != " " {
                    scalars.append(" ")
                }
            } else if (0x21 ... 0x7E).contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        var clipped = Array(scalars.prefix(64))
        while clipped.last == " " {
            clipped.removeLast()
        }
        return clipped.isEmpty ? nil : SGConsentCanonicalText.string(clipped[...])
    }

    /// `iana_tz` (`^[A-Za-z][A-Za-z0-9_+/-]{0,63}$`) as it is, else nil.
    public static func timezone(_ raw: String?) -> String? {
        guard let raw, SGCustomerNormalise.isTimezone(raw) else {
            return nil
        }
        return raw
    }

    /// The app language as the lower-cased primary subtag (design 40 §9.2, B10 R9): a trailing
    /// `-raw` dropped, the part before `-` / `_`, 2–3 ASCII letters (`pt-br` → `pt`, `uz-raw` → `uz`,
    /// `zh-hans` → `zh`); else nil.
    public static func uiLanguage(_ raw: String?) -> String? {
        guard var code = raw?.lowercased() else {
            return nil
        }
        if code.hasSuffix("-raw") {
            code = String(code.dropLast(4))
        }
        let primary = code.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return SGCustomerNormalise.isUILanguage(primary) ? primary : nil
    }

    /// `bcp47` (`language[-Script][-REGION]`, contract §0.3) of a locale identifier: `_` read as `-`,
    /// ICU keywords (`@…`) and anything after the region (variants, extensions) dropped, the cases
    /// fixed (`uz_latn_uz` → `uz-Latn-UZ`); nil when the language is not 2–3 letters.
    public static func bcp47(identifier: String?) -> String? {
        guard let identifier else {
            return nil
        }
        let base = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var parts = base.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)[...]
        guard let language = parts.popFirst() else {
            return nil
        }
        var script: String?
        var region: String?
        if let next = parts.first, next.count == 4, SGCustomerNormalise.isASCIILetters(next) {
            script = next
            parts = parts.dropFirst()
        }
        if let next = parts.first, (next.count == 2 && SGCustomerNormalise.isASCIILetters(next)) || (next.count == 3 && next.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })) {
            region = next
        }
        return SGCustomerNormalise.bcp47(language: language, script: script, region: region)
    }

    /// `bcp47` of separate subtags (iOS 16+ `Locale.Language` components, else `languageCode` /
    /// `scriptCode` / `regionCode`): an invalid script or region is left out; nil when the language
    /// is not 2–3 letters.
    public static func bcp47(language: String?, script: String?, region: String?) -> String? {
        guard let language, (2 ... 3).contains(language.count), SGCustomerNormalise.isASCIILetters(language) else {
            return nil
        }
        var tag = language.lowercased()
        if let script, script.count == 4, SGCustomerNormalise.isASCIILetters(script) {
            tag += "-" + script.prefix(1).uppercased() + script.dropFirst().lowercased()
        }
        if let region {
            if region.count == 2, SGCustomerNormalise.isASCIILetters(region) {
                tag += "-" + region.uppercased()
            } else if region.count == 3, region.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
                tag += "-" + region
            }
        }
        return tag
    }

    // MARK: - Checks (the producible forms)

    static func isVersionScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A:
            return true
        default:
            return scalar == "." || scalar == "_" || scalar == "+" || scalar == "(" || scalar == ")" || scalar == " " || scalar == "-"
        }
    }

    /// `ver`.
    static func isVersion(_ text: String) -> Bool {
        return SGConsentEvent.isVersionText(text)
    }

    /// `model` as `model(_:)` produces it: printable ASCII, 1…64, no leading, trailing or double
    /// space.
    static func isModel(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 64).contains(bytes.count), bytes.first != 0x20, bytes.last != 0x20 else {
            return false
        }
        for (index, byte) in bytes.enumerated() {
            guard (0x20 ... 0x7E).contains(byte) else {
                return false
            }
            if byte == 0x20, index > 0, bytes[index - 1] == 0x20 {
                return false
            }
        }
        return true
    }

    /// `iana_tz`.
    static func isTimezone(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first, bytes.count <= 64, SGCustomerNormalise.isASCIILetter(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            SGCustomerNormalise.isASCIILetter(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "-")
        }
    }

    /// `^[a-z]{2,3}$`.
    static func isUILanguage(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (2 ... 3).contains(bytes.count) && bytes.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
    }

    /// `bcp47`: `^[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?$`.
    static func isBCP47(_ text: String) -> Bool {
        return SGCustomerNormalise.bcp47(identifier: text) == text
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        return (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func isASCIILetters(_ text: String) -> Bool {
        return !text.isEmpty && text.utf8.allSatisfy(SGCustomerNormalise.isASCIILetter)
    }
}

/// Zenlygram — the context events are RECORDED under (contract §3.1): nested in the batch envelope,
/// one per batch (batches split on change), interned in the queue by `id`. Captured at record time,
/// so a queued event keeps the app version it happened in (only `/v1/profile/sync` refreshes
/// `core.devices`).
public struct SGAnalyticsContext: Equatable {
    public static let platform = "ios"
    static let keys: Set<String> = ["platform", "device_class", "os_version", "app_version", "app_build", "device_model", "ui_language", "timezone", "distribution"]

    public let deviceClass: SGCustomerDeviceClass
    /// `ver` (strict).
    public let osVersion: String
    /// `ver` (strict).
    public let appVersion: String
    public let appBuild: String?
    public let deviceModel: String?
    /// The lower-cased primary subtag.
    public let uiLanguage: String?
    public let timezone: String?
    public let distribution: SGCustomerDistribution

    /// The context of `facts`, normalised.
    public init(facts: SGCustomerDeviceFacts) {
        self.deviceClass = facts.deviceClass
        self.osVersion = SGCustomerNormalise.version(facts.osVersion)
        self.appVersion = SGCustomerNormalise.version(facts.appVersion)
        self.appBuild = SGCustomerNormalise.optionalVersion(facts.appBuild)
        self.deviceModel = SGCustomerNormalise.model(facts.deviceModel)
        self.uiLanguage = SGCustomerNormalise.uiLanguage(facts.uiLanguage)
        self.timezone = SGCustomerNormalise.timezone(facts.timezone)
        self.distribution = facts.distribution
    }

    private init(deviceClass: SGCustomerDeviceClass, osVersion: String, appVersion: String, appBuild: String?, deviceModel: String?, uiLanguage: String?, timezone: String?, distribution: SGCustomerDistribution) {
        self.deviceClass = deviceClass
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.deviceModel = deviceModel
        self.uiLanguage = uiLanguage
        self.timezone = timezone
        self.distribution = distribution
    }

    /// Compact JSON, sorted keys, `null` for an unknown descriptive value: every key is always
    /// present (contract §3.5).
    public func encoded() -> Data {
        func optional(_ value: String?) -> String {
            return value.map(SGCustomerJSON.quoted) ?? "null"
        }
        return Data(SGCustomerJSON.object([
            ("platform", SGCustomerJSON.quoted(SGAnalyticsContext.platform)),
            ("device_class", SGCustomerJSON.quoted(self.deviceClass.rawValue)),
            ("os_version", SGCustomerJSON.quoted(self.osVersion)),
            ("app_version", SGCustomerJSON.quoted(self.appVersion)),
            ("app_build", optional(self.appBuild)),
            ("device_model", optional(self.deviceModel)),
            ("ui_language", optional(self.uiLanguage)),
            ("timezone", optional(self.timezone)),
            ("distribution", SGCustomerJSON.quoted(self.distribution.rawValue)),
        ]).utf8)
    }

    /// The canonical id the queue interns it under: the first 16 hex digits of the SHA-256 of
    /// `encoded()`.
    public var id: String {
        return SHA256.hash(data: self.encoded()).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The context of decoded JSON when this client could have built it: exactly the nine keys,
    /// `platform` `ios`, every value in the form `init(facts:)` produces. Else nil.
    static func validated(_ value: Any?) -> SGAnalyticsContext? {
        guard let object = value as? [String: Any], Set(object.keys) == SGAnalyticsContext.keys,
              object["platform"] as? String == SGAnalyticsContext.platform,
              let deviceClass = (object["device_class"] as? String).flatMap(SGCustomerDeviceClass.init(rawValue:)),
              let osVersion = object["os_version"] as? String, SGCustomerNormalise.isVersion(osVersion),
              let appVersion = object["app_version"] as? String, SGCustomerNormalise.isVersion(appVersion),
              let distribution = (object["distribution"] as? String).flatMap(SGCustomerDistribution.init(rawValue:)) else {
            return nil
        }
        /// A descriptive value: JSON null, or a string passing `isValid`; `.some(nil)` = null, nil = invalid.
        func descriptive(_ key: String, _ isValid: (String) -> Bool) -> String?? {
            let raw = object[key]
            if raw is NSNull {
                return .some(nil)
            }
            guard let text = raw as? String, isValid(text) else {
                return nil
            }
            return .some(text)
        }
        guard let appBuild = descriptive("app_build", SGCustomerNormalise.isVersion),
              let deviceModel = descriptive("device_model", SGCustomerNormalise.isModel),
              let uiLanguage = descriptive("ui_language", SGCustomerNormalise.isUILanguage),
              let timezone = descriptive("timezone", SGCustomerNormalise.isTimezone) else {
            return nil
        }
        return SGAnalyticsContext(deviceClass: deviceClass, osVersion: osVersion, appVersion: appVersion, appBuild: appBuild, deviceModel: deviceModel, uiLanguage: uiLanguage, timezone: timezone, distribution: distribution)
    }
}
