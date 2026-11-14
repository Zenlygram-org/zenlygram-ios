// App-side only (see SGCustomerSyncConfigTests.swift): compiles to nothing in `run-core-tests.sh`.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
@testable import SGCustomerSync

/// Zenlygram — the wall's account line (design 40 §5.3): first + last name, else `@username`, else
/// the phone masked to its country code and last two digits. All values are made up.
final class SGProfileReaderTests: XCTestCase {
    private let dot = "\u{2022}"

    private func dots(_ groups: Int...) -> String {
        return groups.map { String(repeating: self.dot, count: $0) }.joined(separator: " ")
    }

    // MARK: - accountLine

    func test_theNameWinsAndIsTrimmed() {
        XCTAssertEqual(SGProfileReader.accountLine(firstName: "Test", lastName: "User", username: "testuser", phone: "+998901234567"), "Test User")
        XCTAssertEqual(SGProfileReader.accountLine(firstName: "  Test\n", lastName: nil, username: "testuser", phone: nil), "Test")
        XCTAssertEqual(SGProfileReader.accountLine(firstName: nil, lastName: " User ", username: nil, phone: nil), "User")
        XCTAssertEqual(SGProfileReader.accountLine(firstName: "Тест", lastName: "Фойдаланувчи", username: nil, phone: nil), "Тест Фойдаланувчи")
    }

    func test_withoutANameTheUsernameThenTheMaskedPhone() {
        XCTAssertEqual(SGProfileReader.accountLine(firstName: " ", lastName: "\t", username: "testuser", phone: "+998901234567"), "@testuser", "a blank name is no name")
        XCTAssertEqual(SGProfileReader.accountLine(firstName: nil, lastName: nil, username: "", phone: "+998901234567"), "+998 \(self.dots(2, 3, 2)) 67")
        XCTAssertEqual(SGProfileReader.accountLine(firstName: "", lastName: nil, username: nil, phone: "998901234567"), "+998 \(self.dots(2, 3, 2)) 67")
        XCTAssertNil(SGProfileReader.accountLine(firstName: nil, lastName: nil, username: nil, phone: nil), "nothing to show")
        XCTAssertNil(SGProfileReader.accountLine(firstName: nil, lastName: nil, username: nil, phone: "12345"))
    }

    // MARK: - maskedPhone

    func test_onlyTheCountryCodeAndTheLastTwoDigitsStay() {
        XCTAssertEqual(SGProfileReader.maskedPhone("+998 90 123 45 67"), "+998 \(self.dots(2, 3, 2)) 67", "the design's example")
        XCTAssertEqual(SGProfileReader.maskedPhone("+7 912 345 67 89"), "+7 \(self.dots(2, 3, 2, 1)) 89")
        XCTAssertEqual(SGProfileReader.maskedPhone("+44 20 7946 0958"), "+44 \(self.dots(2, 3, 2, 1)) 58")
        XCTAssertEqual(SGProfileReader.maskedPhone("15550100"), "+1 \(self.dots(2, 3)) 00")
        XCTAssertEqual(SGProfileReader.maskedPhone("1234567"), "+1 \(self.dots(2, 2)) 67", "seven digits is the least")
    }

    func test_fewerThanSevenDigitsOrNoPhoneIsNil() {
        XCTAssertNil(SGProfileReader.maskedPhone(nil))
        XCTAssertNil(SGProfileReader.maskedPhone(""))
        XCTAssertNil(SGProfileReader.maskedPhone("+998 12"))
        XCTAssertNil(SGProfileReader.maskedPhone("123456"))
        XCTAssertNil(SGProfileReader.maskedPhone("\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}"), "only ASCII digits count")
    }

    func test_noHiddenDigitLeaks() {
        let masked = SGProfileReader.maskedPhone("+998 90 123 45 67") ?? ""
        for digit in ["0", "1", "2", "3", "4", "5"] {
            XCTAssertFalse(masked.contains(digit), "\(digit) is one of the hidden digits")
        }
    }

    // MARK: - countryCodeLength

    func test_theCountryCodeLengthFollowsE164Prefixes() {
        let cases: [(String, Int)] = [("", 0), ("9", 1), ("1555", 1), ("7912", 1), ("2012", 2), ("4420", 2), ("8613", 2), ("9989", 3), ("3809", 3), ("9715", 3)]
        for (digits, expected) in cases {
            XCTAssertEqual(SGProfileReader.countryCodeLength(Array(digits)), expected, digits)
        }
    }
}
#endif
