import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the app's string tables against the hashed consent text (design 40 §14, compliance
/// ui-strings §0.1). The v1 text tells the user where to act ("Settings → Zenlygram → Data & consent
/// → My data", "… → Delete my Zenlygram account and data"), so the three coupled labels of each
/// locale must read exactly as in §5 of that locale's text; only English may change letter case
/// (iOS rows are in Title Case). Changing one of them needs a new consent text version.
///
/// Also: en, ru and uz carry the same key set, every deletion entry point uses the `DataConsent.Delete`
/// words, and there is no "Not now" (ui-strings rule 1.3). The tables come from
/// `SG_CUSTOMER_STRINGS_ROOT` (the host script) or this test bundle (`SGCustomerSyncCoreTests`).
final class SGConsentLabelParityTests: XCTestCase {
    private static let locales: [SGConsentLocale] = [.uz, .ru, .en]
    /// The labels the hashed text quotes (ui-strings §0.1).
    private static let coupledKeys = ["Settings.Data.Consent", "DataConsent.Title", "DataConsent.MyData", "DataConsent.Delete"]

    func testCoupledLabelsReadAsInSectionFiveOfTheSameLocale() throws {
        let repository = try SGCustomerSyncTestFixtures.repository()
        for locale in SGConsentLocale.allCases {
            let table = try self.table(locale.rawValue)
            let rendered = try XCTUnwrap(repository.render(version: repository.currentVersion, locale: locale, operatorValues: .none), "\(locale): the current text does not render")
            let section = try XCTUnwrap(self.sectionFive(of: rendered.canonical), "\(locale): no section 5 in the current text")
            for key in Self.coupledKeys {
                let label = try XCTUnwrap(table[key], "\(locale): \(key) is missing")
                XCTAssertFalse(label.isEmpty, "\(locale): \(key) is empty")
                if locale == .en {
                    XCTAssertTrue(section.lowercased().contains(label.lowercased()), "en: \(key) '\(label)' is not in §5 of the hashed text")
                } else {
                    XCTAssertTrue(section.contains(label), "\(locale): \(key) '\(label)' is not in §5 of the hashed text")
                }
            }
            XCTAssertEqual(table["Settings.Data.Consent"], table["DataConsent.Title"], "\(locale): the Settings row and the screen title are the same coupled label")
        }
    }

    func testEveryDeletionEntryPointUsesTheCoupledWords() throws {
        for locale in Self.locales {
            let table = try self.table(locale.rawValue)
            let delete = try XCTUnwrap(table["DataConsent.Delete"], "\(locale)")
            for key in ["Consent.Declined.Delete", "DataConsent.Withdraw.DeleteInstead"] {
                let label = try XCTUnwrap(table[key], "\(locale): \(key) is missing")
                if locale == .en {
                    XCTAssertEqual(label.lowercased(), delete.lowercased(), "en: \(key)")
                } else {
                    XCTAssertEqual(label, delete, "\(locale): \(key)")
                }
            }
        }
    }

    func testThreeLocalesCarryTheSameKeys() throws {
        let tables = try Self.locales.map { try self.table($0.rawValue) }
        let keys = tables.map { Set($0.keys) }
        XCTAssertFalse(keys[0].isEmpty)
        for (index, locale) in Self.locales.enumerated() {
            XCTAssertEqual(keys[index].subtracting(keys[2]).sorted(), [], "\(locale) has keys en lacks")
            XCTAssertEqual(keys[2].subtracting(keys[index]).sorted(), [], "\(locale) lacks keys en has")
            XCTAssertNil(tables[index]["Consent.Wall.NotNow"], "\(locale): there is no 'Not now' (ui-strings rule 1.3)")
        }
    }

    func testConsentKeysKeepTheirPlaceholdersInEveryLocale() throws {
        let tables = try Self.locales.map { try self.table($0.rawValue) }
        let prefixes = ["Consent.", "DataConsent.", "Settings.Data.", "AccountDelete.", "MyData.", "LinkAccount.AttestDisclosure", "PayWall.LinkAccount.Notice.Required"]
        let english = tables[2]
        let keys = english.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
        XCTAssertGreaterThan(keys.count, 100)
        for key in keys {
            let expected = Self.placeholders(english[key] ?? "")
            for (index, locale) in Self.locales.enumerated() {
                let value = try XCTUnwrap(tables[index][key], "\(locale): \(key) is missing")
                XCTAssertFalse(value.isEmpty, "\(locale): \(key) is empty")
                XCTAssertEqual(Self.placeholders(value), expected, "\(locale): \(key) changes its placeholders")
            }
        }
    }

    // MARK: - Helpers

    /// The text of the `## 5.` section (up to the next `## ` heading).
    private func sectionFive(of canonical: String) -> String? {
        let lines = canonical.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## 5.") }) else {
            return nil
        }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        return lines[start ..< end].joined(separator: "\n")
    }

    /// `%@` / `%d` in order.
    private static func placeholders(_ value: String) -> [String] {
        var result: [String] = []
        var previous: Character?
        for character in value {
            if previous == "%", character == "@" || character == "d" {
                result.append("%\(character)")
            }
            previous = character
        }
        return result
    }

    /// The app's `SGLocalizable.strings` for `lang`.
    private func table(_ lang: String) throws -> [String: String] {
        let direct = SGCustomerSyncTestFixtures.stringsRoot.appendingPathComponent("\(lang).lproj/SGLocalizable.strings")
        var url: URL? = FileManager.default.fileExists(atPath: direct.path) ? direct : nil
        if url == nil, let path = Bundle(for: SGConsentLabelParityTests.self).path(forResource: "SGLocalizable", ofType: "strings", inDirectory: nil, forLocalization: lang) {
            url = URL(fileURLWithPath: path)
        }
        let found = try XCTUnwrap(url, "SGLocalizable.strings for \(lang) not found (root \(SGCustomerSyncTestFixtures.stringsRoot.path))")
        return try XCTUnwrap(NSDictionary(contentsOf: found) as? [String: String], "\(lang): SGLocalizable.strings does not parse")
    }
}
