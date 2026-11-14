import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the plural key a count reads with (U§4): ru CLDR, en one/other, uz one form.
final class SGCustomerPluralTests: XCTestCase {
    func testRussian() {
        let expected: [(Int, SGCustomerPlural.Category)] = [
            (0, .many), (1, .one), (2, .few), (4, .few), (5, .many), (11, .many), (12, .many), (14, .many),
            (21, .one), (22, .few), (25, .many), (101, .one), (111, .many), (112, .many), (122, .few), (1_000_001, .one),
        ]
        for (count, category) in expected {
            XCTAssertEqual(SGCustomerPlural.category(count, languageCode: "ru"), category, "ru \(count)")
        }
        XCTAssertEqual(SGCustomerPlural.category(-21, languageCode: "ru"), .one, "the magnitude counts")
    }

    func testEnglish() {
        XCTAssertEqual(SGCustomerPlural.category(1, languageCode: "en"), .one)
        XCTAssertEqual(SGCustomerPlural.category(2, languageCode: "en"), .many)
        XCTAssertEqual(SGCustomerPlural.category(0, languageCode: "en"), .many)
        XCTAssertEqual(SGCustomerPlural.category(21, languageCode: "en"), .many)
    }

    func testUzbekHasOneForm() {
        for count in [0, 1, 2, 5, 11, 21, 22, 111] {
            XCTAssertEqual(SGCustomerPlural.category(count, languageCode: "uz"), .many, "uz \(count)")
        }
    }

    func testTheCategoryFollowsTheTableTheAppLanguageReads() {
        XCTAssertEqual(SGCustomerPlural.category(22, languageCode: "ru-raw"), .few)
        XCTAssertEqual(SGCustomerPlural.category(22, languageCode: "ru_RU"), .few)
        XCTAssertEqual(SGCustomerPlural.category(22, languageCode: "RU"), .few)
        XCTAssertEqual(SGCustomerPlural.category(22, languageCode: "be"), .few, "SGStrings reads be from the ru table")
        XCTAssertEqual(SGCustomerPlural.category(1, languageCode: "uz-raw"), .many)
        XCTAssertEqual(SGCustomerPlural.category(1, languageCode: "de"), .one, "other languages read the en table")
        XCTAssertEqual(SGCustomerPlural.category(22, languageCode: "pt-br"), .many)
    }
}
