// The app-side tests need the `SGCustomerSync` module, which `run-core-tests.sh` (macOS host, the
// core only) cannot build: there this file compiles to nothing. Bazel runs it in
// //Swiftgram/SGCustomerSync:SGCustomerSyncAppTests.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
@testable import SGCustomerSync
@testable import SGCustomerSyncCore

/// Zenlygram — what a build says about customer data (design 40 §1, §4.1): `consent_mode` /
/// `consent_operator` read from the raw `sg_config` JSON, and the activation order. The operator values
/// here are clearly fake test values; the real ones (O-1) are never in a tracked file.
final class SGCustomerSyncConfigTests: XCTestCase {
    private static let fakeOperator: [String: String] = [
        "name": "Test%20Operator%20LLC",
        "stir": "123456789",
        "responsible_person": "Test%20Person",
        "contact_email": "privacy@example.test",
    ]

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func texts() throws -> Result<SGConsentTextRepository, SGConsentTextRepository.Problem> {
        let root = try XCTUnwrap(SGCustomerSyncConfig.bundledConsentRootURL(), "SGCustomerSyncResources.bundle is next to the module's code")
        return SGConsentTextRepository.load(rootURL: root)
    }

    // MARK: - consent_mode

    func test_anAbsentModeIsRequired() {
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["api_url": "https://127.0.0.1"])).mode, .required)
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: "").mode, .required, "an unreadable config reads as absent")
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: "[1]").mode, .required, "not an object")
    }

    func test_theTwoModesAreReadAsWritten() {
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_mode": "required"])).mode, .required)
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_mode": "optional"])).mode, .optional)
    }

    func test_anyOtherModeStringIsInvalidAndAMistypedOneAbsent() {
        for value in ["Optional", "REQUIRED", "maybe", "", " required"] {
            XCTAssertNil(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_mode": value])).mode, "\"\(value)\"")
        }
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_mode": 1])).mode, .required, "a mistyped value is absent")
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_mode": NSNull()])).mode, .required)
    }

    // MARK: - consent_operator

    func test_operatorValuesArePercentDecodedAndChecked() {
        let values = SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": SGCustomerSyncConfigTests.fakeOperator])).operatorValues
        XCTAssertTrue(values.isComplete)
        XCTAssertFalse(values.hasInvalid)
        XCTAssertEqual(values.value(.name), .valid("Test Operator LLC"))
        XCTAssertEqual(values.value(.responsiblePerson), .valid("Test Person"))
        XCTAssertEqual(values.value(.stir), .valid("123456789"))
        XCTAssertEqual(values.value(.contactEmail), .valid("privacy@example.test"))
    }

    func test_absentFillMeOrMistypedOperatorValuesAreMissing() {
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json([:])).operatorValues.missingFields, SGConsentOperatorValues.Field.allCases)
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": "x"])).operatorValues.missingFields, SGConsentOperatorValues.Field.allCases, "not an object")

        var placeholders = SGCustomerSyncConfigTests.fakeOperator
        placeholders["name"] = "FILL_ME"
        placeholders["stir"] = ""
        var object: [String: Any] = placeholders
        object["contact_email"] = 42
        let values = SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": object])).operatorValues
        XCTAssertEqual(Set(values.missingFields), [.name, .stir, .contactEmail], "a FILL_ME marker, an empty and a mistyped value are missing")
        XCTAssertFalse(values.hasInvalid)
        XCTAssertFalse(values.isComplete)
    }

    func test_malformedOperatorValuesAreInvalid() {
        var malformed = SGCustomerSyncConfigTests.fakeOperator
        malformed["stir"] = "12345"
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": malformed])).operatorValues.value(.stir), .invalid)

        var undecodable = SGCustomerSyncConfigTests.fakeOperator
        undecodable["name"] = "Test%ZZOperator"
        XCTAssertEqual(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": undecodable])).operatorValues.value(.name), .invalid, "a value that does not percent-decode")

        var placeholder = SGCustomerSyncConfigTests.fakeOperator
        placeholder["contact_email"] = "not-an-email"
        XCTAssertTrue(SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": placeholder])).operatorValues.hasInvalid)
    }

    // MARK: - Activation

    private func activation(backendShipped: Bool = true, hasAuthority: Bool = true, mode: SGConsentMode? = .required, texts: Result<SGConsentTextRepository, SGConsentTextRepository.Problem>, operatorValues: SGConsentOperatorValues, apiHost: String?, hasQueueStore: Bool = true) -> SGCustomerSyncConfig.Activation {
        return SGCustomerSyncConfig.activation(backendShipped: backendShipped, hasAuthority: hasAuthority, mode: mode, texts: texts, operatorValues: operatorValues, apiHost: apiHost, hasQueueStore: hasQueueStore)
    }

    private var completeValues: SGConsentOperatorValues {
        return SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": SGCustomerSyncConfigTests.fakeOperator])).operatorValues
    }

    func test_theBundledConsentTreeLoadsAndVerifies() throws {
        guard case .success = try self.texts() else {
            return XCTFail("every template_sha256 of the bundled tree verifies")
        }
    }

    func test_bothModesActivateWithCompleteValuesOnAnyHost() throws {
        let texts = try self.texts()
        for mode in SGConsentMode.allCases {
            for host in ["zenlygram.org", "127.0.0.1", nil] as [String?] {
                XCTAssertEqual(self.activation(mode: mode, texts: texts, operatorValues: self.completeValues, apiHost: host), .active, "\(mode) \(host ?? "nil")")
            }
        }
    }

    func test_withoutTheBackendOrAuthorityNothingIsShipped() throws {
        let texts = try self.texts()
        XCTAssertEqual(self.activation(backendShipped: false, mode: nil, texts: .failure(.manifestUnreadable), operatorValues: .none, apiHost: "zenlygram.org", hasQueueStore: false), .notShipped, "checked before anything else")
        XCTAssertEqual(self.activation(hasAuthority: false, texts: texts, operatorValues: self.completeValues, apiHost: "zenlygram.org"), .notShipped, "an extension")
    }

    func test_theFailuresAreCheckedInOrder() throws {
        let texts = try self.texts()
        XCTAssertEqual(self.activation(mode: nil, texts: .failure(.templateMismatch), operatorValues: .none, apiHost: "zenlygram.org", hasQueueStore: false), .failed(.mode), "the mode first")
        XCTAssertEqual(self.activation(texts: .failure(.templateMismatch), operatorValues: .none, apiHost: "zenlygram.org", hasQueueStore: false), .failed(.text(.templateMismatch)), "then the texts")
        XCTAssertEqual(self.activation(texts: texts, operatorValues: .none, apiHost: "zenlygram.org", hasQueueStore: false), .failed(.operatorMissing), "then the operator values")
        XCTAssertEqual(self.activation(texts: texts, operatorValues: self.completeValues, apiHost: "zenlygram.org", hasQueueStore: false), .failed(.storage), "then the queue")
    }

    func test_missingOperatorValuesActivateOnlyOnALocalHost() throws {
        let texts = try self.texts()
        let local = ["127.0.0.1", "127.8.9.10", "localhost", "LOCALHOST", "::1", "[::1]", "10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.20", "stack.local", "stack.local."]
        for host in local {
            XCTAssertEqual(self.activation(texts: texts, operatorValues: .none, apiHost: host), .active, host)
            XCTAssertEqual(self.activation(mode: .optional, texts: texts, operatorValues: .none, apiHost: host), .active, "optional \(host)")
        }
        let production = ["zenlygram.org", "api.zenlygram.org", "8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1", "11.0.0.1", "local", ".local", "127.0.0", "127.0.0.1.example.test", "", nil] as [String?]
        for host in production {
            XCTAssertEqual(self.activation(texts: texts, operatorValues: .none, apiHost: host), .failed(.operatorMissing), host ?? "nil")
        }
        var partial = SGCustomerSyncConfigTests.fakeOperator
        partial["responsible_person"] = "FILL_ME"
        let partialValues = SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": partial])).operatorValues
        XCTAssertEqual(self.activation(texts: texts, operatorValues: partialValues, apiHost: "zenlygram.org"), .failed(.operatorMissing), "a production profile that kept a FILL_ME marker")
        XCTAssertEqual(self.activation(texts: texts, operatorValues: partialValues, apiHost: "127.0.0.1"), .active)
    }

    func test_anInvalidOperatorValueFailsEvenOnALocalHost() throws {
        let texts = try self.texts()
        var malformed = SGCustomerSyncConfigTests.fakeOperator
        malformed["stir"] = "12345"
        let values = SGCustomerSyncConfig.consentKeys(sgConfigJSON: self.json(["consent_operator": malformed])).operatorValues
        XCTAssertEqual(self.activation(texts: texts, operatorValues: values, apiHost: "127.0.0.1"), .failed(.operatorInvalid))
        XCTAssertEqual(self.activation(texts: texts, operatorValues: values, apiHost: "zenlygram.org"), .failed(.operatorInvalid))
    }

    func test_eachFailureLogsItsOwnStableCode() {
        XCTAssertEqual(SGCustomerSyncConfig.Failure.mode.logCode.rawValue, "consent_mode_invalid")
        XCTAssertEqual(SGCustomerSyncConfig.Failure.storage.logCode.rawValue, "customer_storage_unavailable")
        XCTAssertEqual(SGCustomerSyncConfig.Failure.operatorMissing.logCode, .consentOperatorMissing)
        XCTAssertEqual(SGCustomerSyncConfig.Failure.operatorInvalid.logCode, .consentOperatorInvalid)
        XCTAssertEqual(SGCustomerSyncConfig.Failure.text(.templateMismatch).logCode, SGConsentTextRepository.Problem.templateMismatch.logCode)
    }

    // MARK: - privacy_policy_url

    func test_onlyAnHttpsURLWithAHostIsAPrivacyPolicy() {
        XCTAssertEqual(SGCustomerSyncConfig.httpsURL("https://zenlygram.org/privacy-policy.html")?.absoluteString, "https://zenlygram.org/privacy-policy.html")
        XCTAssertNotNil(SGCustomerSyncConfig.httpsURL("HTTPS://zenlygram.org/p"))
        for text in [nil, "", "http://zenlygram.org/p", "https://", "https:///p", "zenlygram.org/p", "ftp://zenlygram.org/p"] as [String?] {
            XCTAssertNil(SGCustomerSyncConfig.httpsURL(text), text ?? "nil")
        }
    }
}
#endif
