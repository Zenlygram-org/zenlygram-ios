import XCTest
import SGConfig
@testable import SGEntitlement

/// Zenlygram — `sg_config.apple_backend_enabled` as the build reads it: a JSON `true` and nothing
/// else enables it. Absent, `false`, `null`, a string, a number or any other type all read as held,
/// and a bad value never resets the other fields (the lenient per-field decoder).
final class SGEntitlementAppleBackendFlagConfigTests: XCTestCase {
    /// The same decoder `parseSGConfig` uses.
    private func decode(_ json: String) -> SGConfig? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SGConfig.self, from: Data(json.utf8))
    }

    func test_theDefaultIsHeld() throws {
        XCTAssertFalse(try XCTUnwrap(self.decode("{}")).appleBackendEnabled)
    }

    func test_onlyAJSONTrueEnables() {
        XCTAssertEqual(self.decode("{\"apple_backend_enabled\":true}")?.appleBackendEnabled, true)
        XCTAssertEqual(self.decode("{\"apple_backend_enabled\":false}")?.appleBackendEnabled, false)
    }

    func test_nullOrAWrongTypeIsHeldAndLeavesTheOtherFieldsDecoded() {
        let cases: [(String, String)] = [
            ("null", "null"),
            ("string true", "\"true\""),
            ("string yes", "\"yes\""),
            ("number one", "1"),
            ("number zero", "0"),
            ("list", "[true]"),
            ("object", "{\"enabled\":true}")
        ]
        for (name, value) in cases {
            let config = self.decode("{\"apple_backend_enabled\":\(value),\"api_url\":\"https://api.zenlygram.org\",\"iaps\":[\"org.zenlygram.pro.month\"]}")
            XCTAssertNotNil(config, name)
            XCTAssertEqual(config?.appleBackendEnabled, false, name)
            XCTAssertEqual(config?.apiUrl, "https://api.zenlygram.org", "\(name): a bad flag reset api_url")
            XCTAssertEqual(config?.iaps, ["org.zenlygram.pro.month"], "\(name): a bad flag reset iaps")
        }
    }

    func test_aProductListAloneDoesNotEnable() {
        let config = self.decode("{\"api_url\":\"https://api.zenlygram.org\",\"iaps\":[\"org.zenlygram.pro.month\"]}")
        XCTAssertEqual(config?.appleBackendEnabled, false)
    }

    func test_theFlagRoundTripsThroughTheConfigEncoding() throws {
        var config = try XCTUnwrap(self.decode("{}"))
        config.appleBackendEnabled = true
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["apple_backend_enabled"] as? Bool, true)
        XCTAssertEqual(self.decode(String(decoding: data, as: UTF8.self))?.appleBackendEnabled, true)
    }
}
