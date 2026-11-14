import Foundation

/// Zenlygram — which of the three plural keys (`….One`, `….Few`, `….Many`) a count reads with, for
/// the U§4 plural strings (SGStrings has no plural API). The category follows the TABLE the app
/// language actually reads (SGStrings falls back `be` → ru and anything without the key → en):
/// - ru (and be): the CLDR rule — one: n % 10 = 1 and n % 100 ≠ 11; few: n % 10 ∈ 2…4 and
///   n % 100 ∉ 12…14; many: everything else;
/// - uz: one form — all three uz strings are the same text, every count reads `.many`;
/// - en and every other language: one for 1, `.many` (CLDR "other") otherwise; en Few = Many.
public enum SGCustomerPlural {
    public enum Category: Equatable {
        case one
        case few
        case many
    }

    /// `languageCode` as SGStrings takes it (`ru`, `uz-raw`, `pt-br`, `ru_RU`).
    public static func category(_ n: Int, languageCode: String) -> Category {
        let count = n.magnitude
        switch SGCustomerPlural.table(languageCode) {
        case "ru":
            let lastDigit = count % 10
            let lastTwo = count % 100
            if lastDigit == 1 && lastTwo != 11 {
                return .one
            }
            if (2 ... 4).contains(lastDigit) && !(12 ... 14).contains(lastTwo) {
                return .few
            }
            return .many
        case "uz":
            return .many
        default:
            return count == 1 ? .one : .many
        }
    }

    /// The primary subtag of the app language, lower-cased, without SGStrings' `-raw` suffix.
    private static func table(_ languageCode: String) -> String {
        var code = languageCode.lowercased()
        if code.hasSuffix("-raw") {
            code = String(code.dropLast(4))
        }
        let primary = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return primary == "be" ? "ru" : primary
    }
}
