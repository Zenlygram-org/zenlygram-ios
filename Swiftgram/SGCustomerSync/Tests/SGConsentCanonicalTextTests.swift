import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the canonical form and hash (contract §5.3) against the contract's vectors, every
/// entry of the shared `consent-vectors.json` and the vendored v1 texts; the operator values
/// (design 40 §3.2, §4.1).
final class SGConsentCanonicalTextTests: XCTestCase {
    private let placeholders = ["OPERATOR_NAME", "OPERATOR_STIR", "RESPONSIBLE_PERSON", "CONTACT_EMAIL"]

    // MARK: - Contract vectors (C§5.3 table, written out here independently of the fixture file)

    func testContractVectorsV1ToV3() throws {
        try self.assertVector(
            template: "Operator: {{OPERATOR_NAME}} ({{OPERATOR_STIR}})\r\nEmail: {{CONTACT_EMAIL}}  \r\n\r\n",
            values: ["OPERATOR_NAME": "Zenlygram MChJ", "OPERATOR_STIR": "123456789", "CONTACT_EMAIL": "privacy@zenlygram.org"],
            canonical: "Operator: Zenlygram MChJ (123456789)\nEmail: privacy@zenlygram.org",
            textSha256: "c7ecb28d27e873d1a917e3849202f728287e165c163bfb91964cba732a1df2a2",
            templateSha256: "92f61b9765f93e8c336c0c99153150389807ff727fc30e8adbea7b830c346a2d",
            id: "V1"
        )
        try self.assertVector(
            template: "\u{FEFF}# Rozilik\n\nCafe\u{301} o\u{2BB}zbek\t\n",
            values: [:],
            canonical: "# Rozilik\n\nCaf\u{E9} o\u{2BB}zbek",
            textSha256: "560fb9efb2279bd727779cba65fe67ae05b5a14aa25821f98903ae5e28b3f8a8",
            templateSha256: "560fb9efb2279bd727779cba65fe67ae05b5a14aa25821f98903ae5e28b3f8a8",
            id: "V2"
        )
        try self.assertVector(
            template: "Mas\u{2BC}ul shaxs: {{RESPONSIBLE_PERSON}}\n",
            values: [:],
            canonical: "Mas\u{2BC}ul shaxs: {{RESPONSIBLE_PERSON}}",
            textSha256: "89751cc5539c18b0e936bde8c955ae1af6e901065bdcc7643ed306409dfda67f",
            templateSha256: "89751cc5539c18b0e936bde8c955ae1af6e901065bdcc7643ed306409dfda67f",
            id: "V3"
        )
    }

    // MARK: - Shared fixture (`B/tests/Fixtures/customer-data/consent-vectors.json`)

    func testEveryAlgorithmVectorOfTheSharedFixture() throws {
        let fixture = try SGCustomerSyncTestFixtures.jsonObject("consent-vectors.json")
        XCTAssertEqual(fixture["algorithm"] as? String, SGConsentCanonicalText.algorithm)
        let vectors = try SGCustomerSyncTestFixtures.consentVectors().filter { $0["kind"] as? String == "algorithm" }
        XCTAssertEqual(Set(vectors.compactMap { $0["id"] as? String }), ["V1", "V2", "V3"])
        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            try self.assertVector(
                template: try XCTUnwrap(vector["template"] as? String),
                values: try XCTUnwrap(vector["values"] as? [String: String]),
                canonical: try XCTUnwrap(vector["canonical"] as? String),
                textSha256: try XCTUnwrap(vector["text_sha256"] as? String),
                templateSha256: try XCTUnwrap(vector["template_sha256"] as? String),
                id: id
            )
            let canonical = try SGConsentCanonicalText.canonical(template: try XCTUnwrap(vector["template"] as? String), values: try XCTUnwrap(vector["values"] as? [String: String]), placeholders: self.placeholders)
            XCTAssertEqual(canonical.unicodeScalars.count, vector["canonical_length_scalars"] as? Int, id)
            XCTAssertEqual(canonical.utf8.count, vector["canonical_utf8_bytes"] as? Int, id)
        }
    }

    func testEveryLocaleTextVectorAgainstTheVendoredFiles() throws {
        let manifest = try XCTUnwrap(SGConsentManifest.decode(try Data(contentsOf: SGCustomerSyncTestFixtures.consentRoot.appendingPathComponent("manifest.json"))))
        let vectors = try SGCustomerSyncTestFixtures.consentVectors().filter { $0["kind"] as? String == "locale_text" }
        XCTAssertEqual(Set(vectors.compactMap { $0["id"] as? String }), ["v1-uz", "v1-ru", "v1-en", "v2-uz", "v2-ru", "v2-en"])
        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let file = try XCTUnwrap(vector["file"] as? String)
            let template = try XCTUnwrap(SGConsentCanonicalText.decodeUTF8(try Data(contentsOf: SGCustomerSyncTestFixtures.consentRoot.appendingPathComponent(file))), id)
            let values = try XCTUnwrap(vector["values"] as? [String: String])
            let templateSha256 = try XCTUnwrap(vector["template_sha256"] as? String)
            XCTAssertEqual(try SGConsentCanonicalText.canonicalSha256(template: template, values: [:], placeholders: manifest.placeholders), templateSha256, id)
            let canonical = try SGConsentCanonicalText.canonical(template: template, values: values, placeholders: manifest.placeholders)
            XCTAssertEqual(SGConsentCanonicalText.sha256(canonical), vector["text_sha256"] as? String, id)
            XCTAssertEqual(canonical.unicodeScalars.count, vector["canonical_length_scalars"] as? Int, id)
            XCTAssertEqual(canonical.utf8.count, vector["canonical_utf8_bytes"] as? Int, id)

            let version = try XCTUnwrap(vector["text_version"] as? Int)
            let locale = try XCTUnwrap(SGConsentLocale(rawValue: try XCTUnwrap(vector["locale"] as? String)))
            let entry = try XCTUnwrap(manifest.versions[version]?.templates[locale], id)
            XCTAssertEqual(entry.file, file, id)
            XCTAssertEqual(entry.templateSha256, templateSha256, id)
        }
    }

    // MARK: - Step 2: placeholder values

    func testValuesAreNFCAndTrimmedOfUnicodeWhiteSpace() throws {
        XCTAssertEqual(try self.fill("\u{3000}\u{A0}Zeno\u{301}\u{2003}\u{85}\u{2028}\u{202F}"), ["[", "Z", "e", "n", "\u{F3}", "]"])
        // Not Unicode White_Space, so not trimmed: U+200B (zero width space) and U+001C (Python's
        // str.strip() would remove the latter).
        XCTAssertEqual(try self.fill("\u{200B}X"), ["[", "\u{200B}", "X", "]"])
        XCTAssertEqual(try self.fill("\u{1C}X\u{1F}"), ["[", "\u{1C}", "X", "\u{1F}", "]"])
        // U+180E was White_Space before Unicode 6.3; the explicit set keeps it.
        XCTAssertEqual(try self.fill("\u{180E}X\u{FEFF}"), ["[", "\u{180E}", "X", "\u{FEFF}", "]"])
        // Leading and trailing CR, LF and TAB are White_Space: trimmed, then the value is fine.
        XCTAssertEqual(try self.fill("\r\n\tX\t\n"), ["[", "X", "]"])
    }

    func testAValueHoldingCRLFTABOrBracesIsRefused() {
        for value in ["a\rb", "a\nb", "a\tb", "a{{b", "a}}b", "{{OPERATOR_NAME}}"] {
            XCTAssertThrowsError(try self.fill(value), value.debugDescription) { error in
                XCTAssertEqual(error as? SGConsentCanonicalText.Failure, .invalidValue(placeholder: "OPERATOR_NAME"))
            }
        }
    }

    func testOnlyManifestPlaceholdersAreReplacedWithTheServersRegexSemantics() throws {
        let template = "{{OTHER}} {{operator_name}} {{OPERATOR_NAME}} {{{OPERATOR_NAME}}} {{OPERATOR_NAME}"
        let canonical = try SGConsentCanonicalText.canonical(template: template, values: ["OTHER": "no", "OPERATOR_NAME": "Z"], placeholders: self.placeholders)
        self.assertScalars(canonical, "{{OTHER}} {{operator_name}} Z {Z} {{OPERATOR_NAME}")
    }

    func testAMissingOrEmptyValueKeepsThePlaceholderAndABlankOneFillsNothing() throws {
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "[{{OPERATOR_NAME}}]", values: [:], placeholders: self.placeholders), "[{{OPERATOR_NAME}}]")
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "[{{OPERATOR_NAME}}]", values: ["OPERATOR_NAME": ""], placeholders: self.placeholders), "[{{OPERATOR_NAME}}]")
        // As the server: the empty check comes before the trim, so a blank value fills nothing.
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "[{{OPERATOR_NAME}}]", values: ["OPERATOR_NAME": " \u{A0} "], placeholders: self.placeholders), "[]")
    }

    // MARK: - Steps 1, 3–7

    func testLineEndsTrailingBlanksAndTheOuterTrim() throws {
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "\n\n \t a \t\r\nb\rc  \n\n", values: [:], placeholders: []), "a\nb\nc")
        // Inner blank lines and leading blanks of an inner line stay.
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "a\n\n\n  b", values: [:], placeholders: []), "a\n\n\n  b")
        // Only U+0020 / U+0009 are trailing blanks; U+00A0 stays (step 5 is not White_Space).
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "a\u{A0}\nb", values: [:], placeholders: []), "a\u{A0}\nb")
    }

    func testExactlyOneLeadingBOMIsStripped() throws {
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "\u{FEFF}\u{FEFF}x", values: [:], placeholders: []), "\u{FEFF}x")
        self.assertScalars(try SGConsentCanonicalText.canonical(template: "x\u{FEFF}", values: [:], placeholders: []), "x\u{FEFF}")
    }

    func testUTF8DecodingKeepsEveryBOMAndRefusesMalformedBytes() throws {
        let decoded = try XCTUnwrap(SGConsentCanonicalText.decodeUTF8(Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x41])))
        XCTAssertEqual(decoded.unicodeScalars.map(\.value), [0xFEFF, 0xFEFF, 0x41])
        XCTAssertNil(SGConsentCanonicalText.decodeUTF8(Data([0xC3, 0x28])))
        XCTAssertNil(SGConsentCanonicalText.decodeUTF8(Data([0xED, 0xA0, 0x80])), "a surrogate is not UTF-8")
        XCTAssertNil(SGConsentCanonicalText.decodeUTF8(Data([0xC0, 0xAF])), "an overlong form is not UTF-8")
    }

    func testTheHashIsLowercaseHexOfTheUTF8Bytes() {
        XCTAssertEqual(SGConsentCanonicalText.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SGConsentCanonicalText.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Operator values (design 40 §3.2, §4.1)

    func testTheSharedVectorsOperatorValuesAreValidAndUntrimmed() throws {
        for vector in try SGCustomerSyncTestFixtures.consentVectors() where vector["kind"] as? String == "locale_text" {
            let values = try XCTUnwrap(vector["values"] as? [String: String])
            let operatorValues = SGCustomerSyncTestFixtures.operatorValues(values)
            XCTAssertTrue(operatorValues.isComplete, "\(vector["id"] ?? "")")
            XCTAssertFalse(operatorValues.hasInvalid)
            XCTAssertEqual(operatorValues.placeholderValues, values)
        }
        let uz = try SGCustomerSyncTestFixtures.uzVectorOperatorValues()
        XCTAssertEqual(uz.displayValue(.responsiblePerson), "Ali Valiyev")
    }

    func testPercentDecodingSpaceIsPercent20AndPlusIsLiteral() {
        let values = SGConsentOperatorValues.fromConfig(name: "Zenlygram%20MChJ+1", stir: "123456789", responsiblePerson: "Ali%C2%A0Valiyev", contactEmail: "privacy%40zenlygram.org")
        XCTAssertEqual(values.value(.name), .valid("Zenlygram MChJ+1"))
        XCTAssertEqual(values.value(.responsiblePerson), .valid("Ali\u{A0}Valiyev"))
        XCTAssertEqual(values.value(.contactEmail), .valid("privacy@zenlygram.org"))
        XCTAssertTrue(values.isComplete)
        XCTAssertEqual(values.placeholderValues["OPERATOR_NAME"], "Zenlygram MChJ+1")

        let broken = SGConsentOperatorValues.fromConfig(name: "50%", stir: "%ZZ", responsiblePerson: "%C3", contactEmail: "a%40b.uz")
        XCTAssertEqual(broken.value(.name), .invalid)
        XCTAssertEqual(broken.value(.stir), .invalid)
        XCTAssertEqual(broken.value(.responsiblePerson), .invalid)
        XCTAssertEqual(broken.value(.contactEmail), .valid("a@b.uz"))
        XCTAssertTrue(broken.hasInvalid)
        XCTAssertEqual(broken.placeholderValues, ["CONTACT_EMAIL": "a@b.uz"])
    }

    func testFillMeAndEmptyValuesAreMissing() {
        let values = SGConsentOperatorValues.fromConfig(name: "FILL_ME", stir: "", responsiblePerson: "prefixFILL_MEsuffix", contactEmail: nil)
        XCTAssertEqual(values.missingFields, SGConsentOperatorValues.Field.allCases)
        XCTAssertFalse(values.isComplete)
        XCTAssertFalse(values.hasInvalid)
        XCTAssertEqual(values.placeholderValues, [:])
        XCTAssertEqual(SGConsentOperatorValues.none.missingFields, SGConsentOperatorValues.Field.allCases)
    }

    func testControlsLineSeparatorsAndBracesAreInvalid() {
        for name in ["A\u{07}B", "A\u{7F}B", "A\u{85}B", "A\u{9F}B", "A\u{2028}B", "A\u{2029}B", "A{{B", "A}}B", "A\nB", "A\tB", "Ali\n"] {
            XCTAssertEqual(SGConsentOperatorValues(decoded: [.name: name]).value(.name), .invalid, name.debugDescription)
        }
    }

    func testNameAndResponsiblePersonRules() {
        func check(_ value: String) -> SGConsentOperatorValues.Value {
            return SGConsentOperatorValues(decoded: [.name: value, .responsiblePerson: value]).value(.responsiblePerson)
        }
        XCTAssertEqual(check(String(repeating: "a", count: 200)), .valid(String(repeating: "a", count: 200)))
        XCTAssertEqual(check(String(repeating: "a", count: 201)), .invalid)
        XCTAssertEqual(check(" " + String(repeating: "a", count: 200) + "\u{A0}"), .valid(" " + String(repeating: "a", count: 200) + "\u{A0}"), "the length counts after the trim")
        XCTAssertEqual(check(" \u{A0} "), .invalid)
        XCTAssertEqual(check("«Zenlygram» MChJ"), .valid("«Zenlygram» MChJ"))
        for value in ["*Ali*", "[Ali]", "Ali]", "a\\b", "a`b"] {
            XCTAssertEqual(check(value), .invalid, value)
        }
    }

    func testStirRules() {
        func check(_ value: String) -> SGConsentOperatorValues.Value {
            return SGConsentOperatorValues(decoded: [.stir: value]).value(.stir)
        }
        XCTAssertEqual(check("123456789"), .valid("123456789"))
        XCTAssertEqual(check("12345678901234"), .valid("12345678901234"))
        XCTAssertEqual(check(" 123456789\u{A0}"), .valid(" 123456789\u{A0}"))
        for value in ["12345678", "1234567890", "1234567890123", "12345678a", "١٢٣٤٥٦٧٨٩", "123 456 789"] {
            XCTAssertEqual(check(value), .invalid, value)
        }
    }

    func testEmailRules() {
        func check(_ value: String) -> SGConsentOperatorValues.Value {
            return SGConsentOperatorValues(decoded: [.contactEmail: value]).value(.contactEmail)
        }
        for value in ["privacy@zenlygram.org", "a.b+c_d%e-f@sub-1.example.uz", "x@a.b.co"] {
            XCTAssertEqual(check(value), .valid(value), value)
        }
        for value in ["a@b", "a@b.c", "a@@b.uz", "a b@x.uz", "@x.uz", "a@.uz", "a@x..uz", "\"a\"@x.uz", "a@x.u2", "a<b>@x.uz", "a@x.uz#", "a@x_y.uz"] {
            XCTAssertEqual(check(value), .invalid, value)
        }
    }

    func testMissingValuesAreUsableOnlyForALocalHost() {
        for host in ["127.0.0.1", "127.1.2.3", "localhost", "LOCALHOST", "::1", "[::1]", "10.0.0.2", "172.16.0.1", "172.31.255.255", "192.168.1.2", "zenly.local", "Mac-Studio.local."] {
            XCTAssertTrue(SGConsentOperatorValues.acceptsMissingValues(apiHost: host), host)
        }
        for host in ["zenlygram.org", "www.zenlygram.org", "zenlygram.com", "172.15.0.1", "172.32.0.1", "192.169.0.1", "11.0.0.1", "127.0.0", "127.0.0.256", "1270.0.0.1", ".local", "local", "example.localhost.org", "::2", "", "8.8.8.8"] {
            XCTAssertFalse(SGConsentOperatorValues.acceptsMissingValues(apiHost: host), host)
        }
        XCTAssertFalse(SGConsentOperatorValues.acceptsMissingValues(apiHost: nil))

        let missing = SGConsentOperatorValues.fromConfig(name: "FILL_ME", stir: "FILL_ME", responsiblePerson: "FILL_ME", contactEmail: "FILL_ME")
        XCTAssertTrue(missing.isUsable(apiHost: "127.0.0.1"), "the local stack renders literal placeholders")
        XCTAssertFalse(missing.isUsable(apiHost: "zenlygram.org"), "a public host needs all four values")
        let complete = SGConsentOperatorValues(decoded: [.name: "Zenlygram MChJ", .stir: "123456789", .responsiblePerson: "Ali Valiyev", .contactEmail: "privacy@zenlygram.org"])
        XCTAssertTrue(complete.isUsable(apiHost: "zenlygram.org"))
        let invalid = SGConsentOperatorValues(decoded: [.name: "Zenlygram MChJ", .stir: "12345", .responsiblePerson: "Ali Valiyev", .contactEmail: "privacy@zenlygram.org"])
        XCTAssertFalse(invalid.isUsable(apiHost: "127.0.0.1"), "an invalid value is never usable")
    }

    // MARK: - Helpers

    private func fill(_ value: String) throws -> [Unicode.Scalar] {
        return Array(try SGConsentCanonicalText.canonical(template: "[{{OPERATOR_NAME}}]", values: ["OPERATOR_NAME": value], placeholders: self.placeholders).unicodeScalars)
    }

    private func assertVector(template: String, values: [String: String], canonical: String, textSha256: String, templateSha256: String, id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try SGConsentCanonicalText.canonical(template: template, values: values, placeholders: self.placeholders)
        self.assertScalars(actual, canonical, id, file: file, line: line)
        XCTAssertEqual(SGConsentCanonicalText.sha256(actual), textSha256, id, file: file, line: line)
        XCTAssertEqual(try SGConsentCanonicalText.canonicalSha256(template: template, values: values, placeholders: self.placeholders), textSha256, id, file: file, line: line)
        XCTAssertEqual(try SGConsentCanonicalText.canonicalSha256(template: template, values: [:], placeholders: self.placeholders), templateSha256, "\(id) template", file: file, line: line)
    }

    /// Scalar equality: Swift `String ==` treats canonically equivalent text as equal.
    private func assertScalars(_ actual: String, _ expected: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.unicodeScalars.map(\.value), expected.unicodeScalars.map(\.value), message, file: file, line: line)
    }
}
