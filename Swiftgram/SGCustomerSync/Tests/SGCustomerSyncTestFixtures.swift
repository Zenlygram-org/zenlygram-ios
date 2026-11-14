import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — where the customer-data tests find their inputs (design 40 §15.1), resolved the same
/// way by the host script and the Bazel bundle:
/// - the shared fixtures (`Tests/Fixtures`, vendored from `B/tests/Fixtures/customer-data`);
/// - the vendored consent tree (`Resources/consent`);
/// - the app's string tables (`<lang>.lproj/SGLocalizable.strings`).
/// `run-core-tests.sh` names the source directories in `SG_CUSTOMER_FIXTURES`,
/// `SG_CUSTOMER_CONSENT_ROOT` and `SG_CUSTOMER_STRINGS_ROOT`; without them the test bundle's own
/// resources are used (`SGCustomerSyncCoreTests`: the fixtures and the tables at the bundle root,
/// the tree inside `SGCustomerSyncResources.bundle/consent`).
enum SGCustomerSyncTestFixtures {
    static var fixturesRoot: URL {
        return SGCustomerSyncTestFixtures.root(environment: "SG_CUSTOMER_FIXTURES", inBundle: nil)
    }

    static var consentRoot: URL {
        return SGCustomerSyncTestFixtures.root(environment: "SG_CUSTOMER_CONSENT_ROOT", inBundle: "SGCustomerSyncResources.bundle/consent")
    }

    static var stringsRoot: URL {
        return SGCustomerSyncTestFixtures.root(environment: "SG_CUSTOMER_STRINGS_ROOT", inBundle: nil)
    }

    /// A fixture file's bytes, e.g. `consent-vectors.json`.
    static func data(_ name: String) throws -> Data {
        return try Data(contentsOf: SGCustomerSyncTestFixtures.fixturesRoot.appendingPathComponent(name))
    }

    /// A fixture file decoded as a JSON object.
    static func jsonObject(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try SGCustomerSyncTestFixtures.data(name), options: [])
        return try XCTUnwrap(object as? [String: Any], "\(name) is not a JSON object")
    }

    /// The entries of `consent-vectors.json`.
    static func consentVectors() throws -> [[String: Any]] {
        return try XCTUnwrap(try SGCustomerSyncTestFixtures.jsonObject("consent-vectors.json")["vectors"] as? [[String: Any]])
    }

    /// The vendored consent tree as the app loads it.
    static func repository() throws -> SGConsentTextRepository {
        switch SGConsentTextRepository.load(rootURL: SGCustomerSyncTestFixtures.consentRoot) {
        case let .success(repository):
            return repository
        case let .failure(problem):
            XCTFail("the vendored consent tree does not load: \(problem.rawValue) (root \(SGCustomerSyncTestFixtures.consentRoot.path))")
            throw problem
        }
    }

    /// The operator values of a `consent-vectors.json` entry (`values`), as decoded config values.
    static func operatorValues(_ values: [String: String]) -> SGConsentOperatorValues {
        var decoded: [SGConsentOperatorValues.Field: String?] = [:]
        for field in SGConsentOperatorValues.Field.allCases {
            decoded[field] = values[field.placeholder]
        }
        return SGConsentOperatorValues(decoded: decoded)
    }

    /// The `v1-uz` vector's operator values: the public test values the server and Android use too
    /// (never real operator data).
    static func uzVectorOperatorValues() throws -> SGConsentOperatorValues {
        let uz = try XCTUnwrap(try SGCustomerSyncTestFixtures.consentVectors().first { $0["id"] as? String == "v1-uz" })
        return SGCustomerSyncTestFixtures.operatorValues(try XCTUnwrap(uz["values"] as? [String: String]))
    }

    /// A fresh, empty defaults domain and the closure that deletes it.
    static func makeDefaults() -> (defaults: UserDefaults, remove: () -> Void) {
        let suite = "org.zenlygram.SGCustomerSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, {
            defaults.removePersistentDomain(forName: suite)
        })
    }

    /// The `cases` of a case-list fixture (`events-valid.json`, `profile-sync-valid.json`, …).
    static func cases(_ name: String) throws -> [[String: Any]] {
        return try XCTUnwrap(try SGCustomerSyncTestFixtures.jsonObject(name)["cases"] as? [[String: Any]], "\(name) has no cases")
    }

    /// A fresh, empty directory and the closure that deletes it.
    static func makeDirectory() -> (url: URL, remove: () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zg-customer-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return (url, {
            try? FileManager.default.removeItem(at: url)
        })
    }

    /// Two decoded JSON values are equal as parsed JSON, strictly: key order is ignored, but a
    /// boolean is never a number and an integer never a float.
    static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil || lhs is NSNull {
            return rhs == nil || rhs is NSNull
        }
        if rhs == nil || rhs is NSNull {
            return false
        }
        if let left = lhs as? [String: Any] {
            guard let right = rhs as? [String: Any], Set(left.keys) == Set(right.keys) else {
                return false
            }
            return left.allSatisfy { SGCustomerSyncTestFixtures.jsonEqual($0.value, right[$0.key]) }
        }
        if let left = lhs as? [Any] {
            guard let right = rhs as? [Any], left.count == right.count else {
                return false
            }
            return zip(left, right).allSatisfy { SGCustomerSyncTestFixtures.jsonEqual($0, $1) }
        }
        if let left = lhs as? String {
            return (rhs as? String) == left
        }
        guard let left = lhs as? NSNumber, let right = rhs as? NSNumber else {
            return false
        }
        let leftIsBool = CFGetTypeID(left) == CFBooleanGetTypeID()
        guard leftIsBool == (CFGetTypeID(right) == CFBooleanGetTypeID()) else {
            return false
        }
        if leftIsBool {
            return left.boolValue == right.boolValue
        }
        func isInteger(_ number: NSNumber) -> Bool {
            return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType))
        }
        guard isInteger(left) == isInteger(right) else {
            return false
        }
        return isInteger(left) ? left.int64Value == right.int64Value : left.doubleValue == right.doubleValue
    }

    /// `data` parsed as JSON equals `expected` (`jsonEqual`).
    static func assertJSON(_ data: Data, equals expected: Any?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            XCTFail("not JSON: \(String(decoding: data, as: UTF8.self)) \(message)", file: file, line: line)
            return
        }
        XCTAssertTrue(SGCustomerSyncTestFixtures.jsonEqual(parsed, expected), "\(String(decoding: data, as: UTF8.self)) differs from the expected JSON \(message)", file: file, line: line)
    }

    private static func root(environment name: String, inBundle path: String?) -> URL {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let bundle = Bundle(for: SGCustomerSyncTestBundleAnchor.self)
        let resources = bundle.resourceURL ?? bundle.bundleURL
        guard let path else {
            return resources
        }
        return resources.appendingPathComponent(path, isDirectory: true)
    }
}

private final class SGCustomerSyncTestBundleAnchor {}
