import XCTest
import SGConfig

/// Zenlygram — `sg_config.tasks_wire` as the build reads it (wf15 §8.2): the snake_case key, 4 when absent,
/// the integer as written otherwise (`SGTasksShippedWire.requestWire` clamps it to the wires the client
/// speaks), and the per-field leniency of every other `SGConfig` field: a mistyped or null value falls back
/// to 4 on its own and never drops the rest of the config. The fixture values are fake.
final class SGConfigTasksWireDecodingTests: XCTestCase {
    /// The same decoder `parseSGConfig` uses.
    private func decode(_ json: String) -> SGConfig? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SGConfig.self, from: Data(json.utf8))
    }

    func test_anAbsentKeyReadsAsWireFour() {
        let config = self.decode("{\"api_url\":\"https://fixture.example.invalid\"}")
        XCTAssertEqual(config?.tasksWire, 4)
        XCTAssertEqual(config?.tasksWire, SGConfig.defaultTasksWire)
        XCTAssertEqual(config?.apiUrl, "https://fixture.example.invalid")
    }

    func test_fourAndFiveDecodeAsWritten() {
        XCTAssertEqual(self.decode("{\"tasks_wire\":4}")?.tasksWire, 4)
        XCTAssertEqual(self.decode("{\"tasks_wire\":5}")?.tasksWire, 5)
    }

    func test_anOutOfRangeIntegerIsKeptForTheConsumerToClamp() {
        // BuildConfiguration.py refuses these before a build; the lenient decoder keeps them like any field.
        XCTAssertEqual(self.decode("{\"tasks_wire\":6}")?.tasksWire, 6)
        XCTAssertEqual(self.decode("{\"tasks_wire\":3}")?.tasksWire, 3)
        XCTAssertEqual(self.decode("{\"tasks_wire\":0}")?.tasksWire, 0)
    }

    func test_aMistypedOrNullValueFallsBackToFourWithoutDroppingTheConfig() {
        let cases: [(String, String)] = [
            ("null", "null"),
            ("string", "\"5\""),
            ("boolean", "true"),
            ("fraction", "4.5"),
            ("list", "[5]"),
            ("object", "{\"wire\":5}")
        ]
        for (name, value) in cases {
            let config = self.decode("{\"tasks_wire\":\(value),\"api_url\":\"https://fixture.example.invalid\",\"consent_mode\":\"optional\",\"apple_backend_enabled\":true}")
            XCTAssertNotNil(config, name)
            XCTAssertEqual(config?.tasksWire, 4, name)
            XCTAssertEqual(config?.apiUrl, "https://fixture.example.invalid", "\(name): a bad wire reset api_url")
            XCTAssertEqual(config?.consentMode, "optional", "\(name): a bad wire reset consent_mode")
            XCTAssertEqual(config?.appleBackendEnabled, true, "\(name): a bad wire reset apple_backend_enabled")
        }
    }

    /// The compact shape BuildConfiguration.py emits for a simulator build against the local stack with
    /// `"tasks_wire":5` (the WP-V3 variant), with fake operator values in place of the stack's.
    func test_aLocalStackShapedConfigWithWireFiveDecodesEveryField() {
        let json = "{\"api_url\":\"https://127.0.0.1\",\"bot_username\":\"FixtureLocalBot\",\"entitlement_keys\":{\"k2026l\":\"AAAA\"},\"apple_backend_enabled\":false,\"iaps\":[],\"consent_mode\":\"required\",\"consent_operator\":{\"name\":\"Fixture%20Operator%20MChJ\",\"stir\":\"000000000\",\"responsible_person\":\"Fixture%20Person\",\"contact_email\":\"privacy%40fixture.example.invalid\"},\"tasks_wire\":5}"
        let config = self.decode(json)
        XCTAssertEqual(config?.tasksWire, 5)
        XCTAssertEqual(config?.apiUrl, "https://127.0.0.1")
        XCTAssertEqual(config?.botUsername, "FixtureLocalBot")
        XCTAssertEqual(config?.entitlementKeys, ["k2026l": "AAAA"])
        XCTAssertEqual(config?.appleBackendEnabled, false)
        XCTAssertEqual(config?.iaps, [])
        XCTAssertEqual(config?.consentMode, "required")
        XCTAssertEqual(config?.consentOperator?.stir, "000000000")
    }

    func test_theWireRoundTripsThroughTheConfigEncoding() throws {
        var config = try XCTUnwrap(self.decode("{}"))
        config.tasksWire = 5
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["tasks_wire"] as? Int, 5)
        XCTAssertEqual(self.decode(String(decoding: data, as: UTF8.self))?.tasksWire, 5)
    }
}
