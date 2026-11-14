import CryptoKit
import Foundation

/// Zenlygram — the canonical form of a consent text and its hash (contract §5.3; the only algorithm,
/// the same as the server's `ConsentCanonicalizer`, Android and `tools/consent/check_texts.py`):
///
/// 1. strip one leading U+FEFF;
/// 2. replace every `{{NAME}}` (NAME = `[A-Z_]+`) whose NAME is a manifest placeholder with its
///    value, NFC-normalised and trimmed of Unicode White_Space; a missing or empty value leaves
///    `{{NAME}}` literally (local builds only), any other `{{…}}` is never touched; a value still
///    holding CR, LF, TAB, `{{` or `}}` is refused;
/// 3. CRLF and a lone CR → LF;
/// 4. NFC-normalise the whole text;
/// 5. remove trailing U+0020 / U+0009 from every line;
/// 6. remove leading and trailing U+0020, U+0009, U+000A from the whole text;
/// 7. `text_sha256` = lowercase hex SHA-256 of the UTF-8 bytes (`template_sha256`: no values).
///
/// Everything runs on Unicode scalars: Swift `String` equality, `hasPrefix` and `Character` treat
/// canonically equivalent text and CR LF as one, which this algorithm must not.
public enum SGConsentCanonicalText {
    public static let algorithm = "zenlygram-consent-canonical/1"

    public enum Failure: Error, Equatable {
        /// The value of this placeholder holds CR, LF, TAB, `{{` or `}}` once trimmed.
        case invalidValue(placeholder: String)
    }

    /// Unicode White_Space (PropList.txt), spelled out as compliance C-3 requires: U+0009–000D, 0020,
    /// 0085, 00A0, 1680, 2000–200A, 2028, 2029, 202F, 205F, 3000. Never `.whitespacesAndNewlines`.
    public static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009 ... 0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// `text` without leading and trailing Unicode White_Space.
    public static func trimmingWhiteSpace(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !SGConsentCanonicalText.isWhiteSpace($0) }),
              let last = scalars.lastIndex(where: { !SGConsentCanonicalText.isWhiteSpace($0) }) else {
            return ""
        }
        return SGConsentCanonicalText.string(scalars[first ... last])
    }

    /// NFC (Unicode canonical composition).
    public static func nfc(_ text: String) -> String {
        return text.precomposedStringWithCanonicalMapping
    }

    /// The canonical form of `template` filled with `values` (placeholder name → raw value) for the
    /// manifest's `placeholders`.
    public static func canonical(template: String, values: [String: String], placeholders: [String]) throws -> String {
        var scalars = Array(template.unicodeScalars)
        if scalars.first?.value == 0xFEFF {
            scalars.removeFirst()
        }
        let filled = try SGConsentCanonicalText.fill(scalars, values: values, placeholders: Set(placeholders))
        let unixLines = SGConsentCanonicalText.unixLineEnds(filled)
        let composed = Array(SGConsentCanonicalText.nfc(SGConsentCanonicalText.string(unixLines[...])).unicodeScalars)
        let trimmedLines = SGConsentCanonicalText.removingTrailingBlanks(composed)
        return SGConsentCanonicalText.string(SGConsentCanonicalText.trimmingOuter(trimmedLines))
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes of a canonical text.
    public static func sha256(_ canonical: String) -> String {
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `text_sha256` of `template` filled with `values` (`template_sha256` with no values).
    public static func canonicalSha256(template: String, values: [String: String], placeholders: [String]) throws -> String {
        return SGConsentCanonicalText.sha256(try SGConsentCanonicalText.canonical(template: template, values: values, placeholders: placeholders))
    }

    /// The text of UTF-8 `data` with every byte order mark kept (step 1 strips exactly one), or nil
    /// when `data` is not well-formed UTF-8. `String(data:encoding:)` would drop a leading BOM itself.
    public static func decodeUTF8(_ data: Data) -> String? {
        var iterator = data.makeIterator()
        var decoder = UTF8()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue:
                continue
            case .emptyInput:
                break loop
            case .error:
                return nil
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Steps

    /// Step 2, with the server's regex semantics (`/\{\{([A-Z_]+)\}\}/`, leftmost, non-overlapping):
    /// a `{{` that does not start a match is copied one scalar at a time.
    private static func fill(_ scalars: [Unicode.Scalar], values: [String: String], placeholders: Set<String>) throws -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "{", index + 1 < scalars.count, scalars[index + 1] == "{" {
                var end = index + 2
                while end < scalars.count, SGConsentCanonicalText.isPlaceholderScalar(scalars[end]) {
                    end += 1
                }
                if end > index + 2, end + 1 < scalars.count, scalars[end] == "}", scalars[end + 1] == "}" {
                    let name = SGConsentCanonicalText.string(scalars[(index + 2) ..< end])
                    if placeholders.contains(name), let raw = values[name], !raw.isEmpty {
                        result.append(contentsOf: try SGConsentCanonicalText.filledValue(raw, placeholder: name).unicodeScalars)
                    } else {
                        result.append(contentsOf: scalars[index ... (end + 1)])
                    }
                    index = end + 2
                    continue
                }
            }
            result.append(scalars[index])
            index += 1
        }
        return result
    }

    private static func filledValue(_ raw: String, placeholder: String) throws -> String {
        let value = SGConsentCanonicalText.trimmingWhiteSpace(SGConsentCanonicalText.nfc(raw))
        let scalars = Array(value.unicodeScalars)
        let holdsBreak = scalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\t" }
        if holdsBreak || SGConsentCanonicalText.contains(scalars, "{{") || SGConsentCanonicalText.contains(scalars, "}}") {
            throw Failure.invalidValue(placeholder: placeholder)
        }
        return value
    }

    /// Step 3.
    private static func unixLineEnds(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\r" {
                result.append("\n")
                index += (index + 1 < scalars.count && scalars[index + 1] == "\n") ? 2 : 1
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return result
    }

    /// Step 5: a run of U+0020 / U+0009 directly before a LF or the end goes.
    private static func removingTrailingBlanks(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalars.count)
        var pending: [Unicode.Scalar] = []
        for scalar in scalars {
            if scalar == " " || scalar == "\t" {
                pending.append(scalar)
            } else if scalar == "\n" {
                pending.removeAll()
                result.append(scalar)
            } else {
                result.append(contentsOf: pending)
                pending.removeAll()
                result.append(scalar)
            }
        }
        return result
    }

    /// Step 6.
    private static func trimmingOuter(_ scalars: [Unicode.Scalar]) -> ArraySlice<Unicode.Scalar> {
        let isOuter: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" }
        guard let first = scalars.firstIndex(where: { !isOuter($0) }), let last = scalars.lastIndex(where: { !isOuter($0) }) else {
            return []
        }
        return scalars[first ... last]
    }

    private static func isPlaceholderScalar(_ scalar: Unicode.Scalar) -> Bool {
        return (scalar.value >= 0x41 && scalar.value <= 0x5A) || scalar == "_"
    }

    /// Whether `scalars` holds the scalars of `needle` in a row (never canonical equivalence).
    static func contains(_ scalars: [Unicode.Scalar], _ needle: String) -> Bool {
        let pattern = Array(needle.unicodeScalars)
        guard !pattern.isEmpty, scalars.count >= pattern.count else {
            return false
        }
        for start in 0 ... (scalars.count - pattern.count) where scalars[start ..< (start + pattern.count)].elementsEqual(pattern) {
            return true
        }
        return false
    }

    static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

/// Zenlygram — the four operator values the consent text names (contract §5.4), read from
/// `sg_config.consent_operator` (each value percent-encoded UTF-8: a space is `%20`, `+` is literal)
/// and checked as design 40 §3.2 / compliance C-2 require, so a value this build accepts is never
/// refused by the policy renderer or the server's canonical form:
/// - missing: absent, empty or holding `FILL_ME` (accepted only by a build for a local host);
/// - invalid: not percent-decodable, holding a C0/C1 control, U+2028/U+2029, `{{` or `}}`; a name or
///   responsible person that is not 1…200 scalars after NFC + White_Space trim or holds one of
///   `* [ ] \` and the backtick (it is rendered inside Markdown); a STIR / JShShIR that is not exactly
///   9 or 14 digits; an e-mail not matching
///   `^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$`.
public struct SGConsentOperatorValues: Equatable {
    public enum Field: String, CaseIterable, Equatable, Hashable {
        case name
        case stir
        case responsiblePerson = "responsible_person"
        case contactEmail = "contact_email"

        /// The manifest placeholder this value fills.
        public var placeholder: String {
            switch self {
            case .name:
                return "OPERATOR_NAME"
            case .stir:
                return "OPERATOR_STIR"
            case .responsiblePerson:
                return "RESPONSIBLE_PERSON"
            case .contactEmail:
                return "CONTACT_EMAIL"
            }
        }
    }

    public enum Value: Equatable {
        /// The decoded value as configured (not trimmed: the canonical form trims it).
        case valid(String)
        case missing
        case invalid
    }

    public let values: [Field: Value]

    /// No values at all (a local build's literal placeholders).
    public static let none = SGConsentOperatorValues(decoded: [:])

    /// Values that are already decoded (fixtures, tests). A nil or absent field is missing.
    public init(decoded: [Field: String?]) {
        var values: [Field: Value] = [:]
        for field in Field.allCases {
            values[field] = SGConsentOperatorValues.check(decoded[field] ?? nil, field: field)
        }
        self.values = values
    }

    /// The `sg_config.consent_operator` values, each percent-encoded UTF-8.
    public static func fromConfig(name: String?, stir: String?, responsiblePerson: String?, contactEmail: String?) -> SGConsentOperatorValues {
        var decoded: [Field: String?] = [:]
        var undecodable: Set<Field> = []
        let raw: [Field: String?] = [.name: name, .stir: stir, .responsiblePerson: responsiblePerson, .contactEmail: contactEmail]
        for (field, value) in raw {
            guard let value, !value.isEmpty else {
                decoded[field] = nil
                continue
            }
            if let text = value.removingPercentEncoding {
                decoded[field] = text
            } else {
                undecodable.insert(field)
            }
        }
        let checked = SGConsentOperatorValues(decoded: decoded)
        guard !undecodable.isEmpty else {
            return checked
        }
        var values = checked.values
        for field in undecodable {
            values[field] = .invalid
        }
        return SGConsentOperatorValues(values: values)
    }

    private init(values: [Field: Value]) {
        self.values = values
    }

    public func value(_ field: Field) -> Value {
        return self.values[field] ?? .missing
    }

    /// All four values present and valid.
    public var isComplete: Bool {
        return Field.allCases.allSatisfy { field in
            if case .valid = self.value(field) {
                return true
            }
            return false
        }
    }

    public var hasInvalid: Bool {
        return Field.allCases.contains { self.value($0) == .invalid }
    }

    public var missingFields: [Field] {
        return Field.allCases.filter { self.value($0) == .missing }
    }

    /// The valid values keyed by manifest placeholder, for the canonical form; a missing or invalid
    /// value is left out, so its `{{NAME}}` stays literally.
    public var placeholderValues: [String: String] {
        var result: [String: String] = [:]
        for field in Field.allCases {
            if case let .valid(value) = self.value(field) {
                result[field.placeholder] = value
            }
        }
        return result
    }

    /// The value as it reads in the text (NFC, trimmed), for display (`DataConsent.Operator`).
    public func displayValue(_ field: Field) -> String? {
        guard case let .valid(value) = self.value(field) else {
            return nil
        }
        return SGConsentCanonicalText.trimmingWhiteSpace(SGConsentCanonicalText.nfc(value))
    }

    /// Whether a build for this `api_url` host may render this consent text (design 40 §1): no value
    /// invalid, and all four present — or the host is local, where missing values stay literal
    /// placeholders. Otherwise the pipeline's activation is `.failed`.
    public func isUsable(apiHost: String?) -> Bool {
        return !self.hasInvalid && (self.isComplete || SGConsentOperatorValues.acceptsMissingValues(apiHost: apiHost))
    }

    /// A local host (design 40 §1): loopback (`127.0.0.0/8`, `::1`, `localhost`), RFC 1918 private
    /// IPv4 (`10/8`, `172.16/12`, `192.168/16`) or a name under `.local` — the local stack, never
    /// a public server.
    public static func acceptsMissingValues(apiHost: String?) -> Bool {
        guard var host = apiHost?.lowercased(), !host.isEmpty else {
            return false
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") {
            host = String(host.dropLast())
        }
        if host == "localhost" || host == "::1" || (host.hasSuffix(".local") && host.count > ".local".count) {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        var values: [Int] = []
        for octet in octets {
            guard (1 ... 3).contains(octet.count), octet.allSatisfy({ $0 >= "0" && $0 <= "9" }), let value = Int(octet), value <= 255 else {
                return false
            }
            values.append(value)
        }
        switch (values[0], values[1]) {
        case (127, _), (10, _), (192, 168):
            return true
        case let (172, second):
            return (16 ... 31).contains(second)
        default:
            return false
        }
    }

    // MARK: - Checks

    private static func check(_ decoded: String?, field: Field) -> Value {
        guard let decoded, !decoded.isEmpty else {
            return .missing
        }
        let raw = Array(decoded.unicodeScalars)
        if SGConsentCanonicalText.contains(raw, "FILL_ME") {
            return .missing
        }
        let forbidden = raw.contains { scalar in
            scalar.value <= 0x1F || (scalar.value >= 0x7F && scalar.value <= 0x9F) || scalar.value == 0x2028 || scalar.value == 0x2029
        }
        if forbidden || SGConsentCanonicalText.contains(raw, "{{") || SGConsentCanonicalText.contains(raw, "}}") {
            return .invalid
        }
        let text = SGConsentCanonicalText.trimmingWhiteSpace(SGConsentCanonicalText.nfc(decoded))
        let scalars = Array(text.unicodeScalars)
        let isValid: Bool
        switch field {
        case .name, .responsiblePerson:
            let markdown: Set<Unicode.Scalar> = ["*", "[", "]", "\\", "`"]
            isValid = (1 ... 200).contains(scalars.count) && !scalars.contains(where: { markdown.contains($0) })
        case .stir:
            isValid = (scalars.count == 9 || scalars.count == 14) && scalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
        case .contactEmail:
            isValid = SGConsentOperatorValues.isEmail(scalars)
        }
        return isValid ? .valid(decoded) : .invalid
    }

    /// `^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$`
    private static func isEmail(_ scalars: [Unicode.Scalar]) -> Bool {
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            return (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
        }
        func isAlnum(_ scalar: Unicode.Scalar) -> Bool {
            return isLetter(scalar) || (scalar.value >= 0x30 && scalar.value <= 0x39)
        }
        let parts = scalars.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return false
        }
        let local = parts[0]
        guard !local.isEmpty, local.allSatisfy({ isAlnum($0) || $0 == "." || $0 == "_" || $0 == "%" || $0 == "+" || $0 == "-" }) else {
            return false
        }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(isLetter) else {
            return false
        }
        return labels.dropLast().allSatisfy { label in
            !label.isEmpty && label.allSatisfy { isAlnum($0) || $0 == "-" }
        }
    }
}
