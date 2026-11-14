import XCTest
import SGConfig

/// Zenlygram — `sg_config.consent_mode` / `consent_operator` as the build reads them (design 40 §3): the
/// snake_case keys of contract §5.4, the per-field leniency of every other `SGConfig` field (a missing
/// or mistyped value falls back on its own and never drops the rest of the config), and the operator
/// values kept exactly as written, still percent-encoded. The fixture values are fake.
final class SGConfigConsentDecodingTests: XCTestCase {
    /// The same decoder `parseSGConfig` uses.
    private func decode(_ json: String) -> SGConfig? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SGConfig.self, from: Data(json.utf8))
    }

    private func object(_ fields: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private let fixtureOperator: [String: Any] = [
        "name": "Fixture%20Operator%20MChJ",
        "stir": "000000000",
        "responsible_person": "Fixture%20Person",
        "contact_email": "privacy%40fixture.example.invalid"
    ]

    func test_absentKeysDecodeAsRequiredWithNoOperator() {
        let config = self.decode(self.object(["api_url": "https://fixture.example.invalid"]))
        XCTAssertEqual(config?.consentMode, "required")
        XCTAssertEqual(config?.consentMode, SGConfig.defaultConsentMode)
        XCTAssertNil(config?.consentOperator)
        XCTAssertEqual(config?.apiUrl, "https://fixture.example.invalid")
    }

    func test_bothModesDecode() {
        XCTAssertEqual(self.decode(self.object(["consent_mode": "required"]))?.consentMode, "required")
        XCTAssertEqual(self.decode(self.object(["consent_mode": "optional"]))?.consentMode, "optional")
    }

    func test_anUnknownModeStringIsKeptForTheConsumerToRefuse() {
        XCTAssertEqual(self.decode(self.object(["consent_mode": "REQUIRED"]))?.consentMode, "REQUIRED")
        XCTAssertEqual(self.decode(self.object(["consent_mode": ""]))?.consentMode, "")
    }

    func test_aMistypedOrNullModeFallsBackToRequiredWithoutDroppingTheConfig() {
        for value in [1 as Any, true as Any, NSNull() as Any, ["optional"] as Any, ["mode": "optional"] as Any] {
            let config = self.decode(self.object(["consent_mode": value, "api_url": "https://fixture.example.invalid", "apple_backend_enabled": true]))
            XCTAssertEqual(config?.consentMode, "required", "\(value)")
            XCTAssertEqual(config?.apiUrl, "https://fixture.example.invalid", "\(value)")
            XCTAssertEqual(config?.appleBackendEnabled, true, "\(value)")
        }
    }

    func test_theOperatorDecodesItsSnakeCaseKeysAndKeepsTheEncodedValues() {
        let config = self.decode(self.object(["consent_operator": self.fixtureOperator]))
        XCTAssertEqual(config?.consentOperator, SGConsentOperatorConfig(
            name: "Fixture%20Operator%20MChJ",
            stir: "000000000",
            responsiblePerson: "Fixture%20Person",
            contactEmail: "privacy%40fixture.example.invalid"
        ))
    }

    func test_aPlusAndNonAsciiEscapesStayAsWritten() {
        let config = self.decode(self.object(["consent_operator": ["name": "Fixture+%D0%9E%D0%9E%D0%9E", "stir": "00000000000000", "responsible_person": "O%CA%BBg%CA%BBli", "contact_email": "a+b@fixture.example.invalid"]]))
        XCTAssertEqual(config?.consentOperator?.name, "Fixture+%D0%9E%D0%9E%D0%9E")
        XCTAssertEqual(config?.consentOperator?.stir, "00000000000000")
        XCTAssertEqual(config?.consentOperator?.responsiblePerson, "O%CA%BBg%CA%BBli")
        XCTAssertEqual(config?.consentOperator?.contactEmail, "a+b@fixture.example.invalid")
    }

    func test_eachOperatorValueFallsBackOnItsOwn() {
        var fields = self.fixtureOperator
        fields["stir"] = 123456789
        fields.removeValue(forKey: "contact_email")
        fields["responsible_person"] = NSNull()
        let config = self.decode(self.object(["consent_operator": fields, "consent_mode": "optional"]))
        XCTAssertEqual(config?.consentMode, "optional")
        XCTAssertEqual(config?.consentOperator?.name, "Fixture%20Operator%20MChJ")
        XCTAssertNil(config?.consentOperator?.stir, "a mistyped value is missing")
        XCTAssertNil(config?.consentOperator?.responsiblePerson)
        XCTAssertNil(config?.consentOperator?.contactEmail)
    }

    func test_aNonObjectOperatorIsAbsentAndTheRestStillDecodes() {
        for value in ["FILL_ME" as Any, 1 as Any, [] as [Any] as Any, NSNull() as Any] {
            let config = self.decode(self.object(["consent_operator": value, "consent_mode": "optional", "privacy_policy_url": "https://fixture.example.invalid/privacy-policy.html"]))
            XCTAssertNil(config?.consentOperator, "\(value)")
            XCTAssertEqual(config?.consentMode, "optional", "\(value)")
            XCTAssertEqual(config?.privacyPolicyUrl, "https://fixture.example.invalid/privacy-policy.html", "\(value)")
        }
    }

    func test_theTemplatesFillMeMarkersDecodeAsWritten() {
        let markers: [String: Any] = ["name": "FILL_ME", "stir": "FILL_ME", "responsible_person": "FILL_ME", "contact_email": "FILL_ME"]
        let config = self.decode(self.object(["consent_operator": markers, "consent_mode": "required", "apple_backend_enabled": true]))
        XCTAssertEqual(config?.consentOperator, SGConsentOperatorConfig(name: "FILL_ME", stir: "FILL_ME", responsiblePerson: "FILL_ME", contactEmail: "FILL_ME"))
        XCTAssertEqual(config?.appleBackendEnabled, true)
    }

    /// The shape `tools/local-stack/stack ios-config` prints for the sim-local profile (the compact
    /// JSON BuildConfiguration.py emits), with fake operator values in place of the stack's.
    func test_aLocalStackShapedConfigDecodesEveryField() {
        let json = "{\"api_url\":\"https://127.0.0.1\",\"webapp_url\":\"https://127.0.0.1/account\",\"privacy_policy_url\":\"https://127.0.0.1/privacy-policy.html\",\"bot_username\":\"FixtureLocalBot\",\"entitlement_keys\":{\"k2026l\":\"AAAA\"},\"apple_backend_enabled\":false,\"iaps\":[],\"consent_mode\":\"required\",\"consent_operator\":{\"name\":\"Fixture%20Operator%20MChJ\",\"stir\":\"000000000\",\"responsible_person\":\"Fixture%20Person\",\"contact_email\":\"privacy%40fixture.example.invalid\"}}"
        let config = self.decode(json)
        XCTAssertEqual(config?.apiUrl, "https://127.0.0.1")
        XCTAssertEqual(config?.webappUrl, "https://127.0.0.1/account")
        XCTAssertEqual(config?.privacyPolicyUrl, "https://127.0.0.1/privacy-policy.html")
        XCTAssertEqual(config?.botUsername, "FixtureLocalBot")
        XCTAssertEqual(config?.entitlementKeys, ["k2026l": "AAAA"])
        XCTAssertEqual(config?.appleBackendEnabled, false)
        XCTAssertEqual(config?.iaps, [])
        XCTAssertEqual(config?.consentMode, "required")
        XCTAssertEqual(config?.consentOperator?.name, "Fixture%20Operator%20MChJ")
        XCTAssertEqual(config?.consentOperator?.stir, "000000000")
        XCTAssertEqual(config?.consentOperator?.responsiblePerson, "Fixture%20Person")
        XCTAssertEqual(config?.consentOperator?.contactEmail, "privacy%40fixture.example.invalid")
        XCTAssertFalse(config?.publicPolicyRequested ?? true)
    }

    func test_theOperatorRoundTripsThroughItsEncoder() throws {
        let value = SGConsentOperatorConfig(name: "Fixture%20Operator", stir: "000000000", responsiblePerson: nil, contactEmail: "x@fixture.example.invalid")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["contact_email"] as? String, "x@fixture.example.invalid")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try decoder.decode(SGConsentOperatorConfig.self, from: data), value)
    }
}
