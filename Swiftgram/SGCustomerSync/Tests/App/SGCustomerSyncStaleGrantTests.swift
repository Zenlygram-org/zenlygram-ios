// App-side only (see SGCustomerSyncConfigTests.swift): compiles to nothing in `run-core-tests.sh`.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
import SGEntitlement
@testable import SGCustomerSync
@testable import SGCustomerSyncCore

/// Zenlygram — a grant this build treats as stale (design 40 §4.6 rows 5–6) is no usable grant for the link
/// either: `bindPermissionProvider` answers for it what it answers for `needs_reconsent` (§0, §7.1.4) —
/// refused in required mode, the code flow only in optional mode, so no attestation runs and the grant is
/// never attached to `bind/start` — until the wall asks again. The operator values here are clearly fake.
final class SGCustomerSyncStaleGrantTests: XCTestCase {
    /// A user id whose packed peer id is the id itself (namespace 0).
    private let tg: Int64 = 555_000_111
    private let authority = "zenlygram.org"
    /// 2026-11-01T09:00:00Z.
    private let decided = Date(timeIntervalSince1970: 1_793_523_600)
    private let values = SGConsentOperatorValues.fromConfig(name: "Test Operator LLC", stir: "123456789", responsiblePerson: "Test Person", contactEmail: "privacy@example.test")
    private let changedValues = SGConsentOperatorValues.fromConfig(name: "Test Operator MChJ", stir: "987654321", responsiblePerson: "Test Responsible Person", contactEmail: "privacy@example.org")

    private var suite = ""
    private var store: SGConsentStore!
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        self.suite = "org.zenlygram.SGCustomerSyncStaleGrantTests.\(UUID().uuidString)"
        self.store = SGConsentStore(defaults: UserDefaults(suiteName: self.suite)!, isReadable: { true }, now: { [unowned self] in self.decided })
        self.directories = []
    }

    override func tearDown() {
        UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
        for directory in self.directories {
            try? FileManager.default.removeItem(at: directory)
        }
        self.store = nil
        super.tearDown()
    }

    func test_aStaleGrantLinksAsNeedsReconsent() throws {
        let texts = try self.bundledTexts()
        let text = try XCTUnwrap(texts.render(version: 1, locale: .uz, operatorValues: self.values))
        _ = try self.store.grant(tg: self.tg, text: text, mode: .required, appVersion: "12.0.1", now: self.decided).get()
        XCTAssertEqual(self.permission(.required, texts: texts, operatorValues: self.values), .allowed, "the texts and values it was granted with")
        XCTAssertEqual(self.permission(.optional, texts: texts, operatorValues: self.values), .allowed)

        // Row 6: this build renders the granted text with other operator values.
        XCTAssertTrue(self.changedValues.isComplete)
        XCTAssertEqual(self.permission(.required, texts: texts, operatorValues: self.changedValues), .refused)
        XCTAssertEqual(self.permission(.optional, texts: texts, operatorValues: self.changedValues), .codeOnly, "the code flow only: no attestation, no consent attached")

        // Row 5: an update raised min_valid_version above the granted v1.
        let raised = try self.textsRaisingTheMinimum()
        XCTAssertEqual(self.permission(.required, texts: raised, operatorValues: self.values), .refused)
        XCTAssertEqual(self.permission(.optional, texts: raised, operatorValues: self.values), .codeOnly)

        // Exactly what the record answers once the wall normalised it.
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .granted, "nothing normalised the record: the provider reads the stale grant itself")
        try self.store.markNeedsReconsent(tg: self.tg, notice: .operatorChanged).get()
        XCTAssertEqual(self.permission(.required, texts: texts, operatorValues: self.values), .refused)
        XCTAssertEqual(self.permission(.optional, texts: texts, operatorValues: self.values), .codeOnly)
    }

    // MARK: - Helpers

    private func permission(_ mode: SGConsentMode, texts: SGConsentTextRepository, operatorValues: SGConsentOperatorValues) -> SGEntitlementBindPermission {
        return SGCustomerSync.bindPermission(accountPeerId: self.tg, mode: mode, store: self.store, authority: self.authority, sessionEnd: nil, texts: texts, operatorValues: operatorValues)
    }

    private func bundledTexts() throws -> SGConsentTextRepository {
        let root = try XCTUnwrap(SGCustomerSyncConfig.bundledConsentRootURL(), "SGCustomerSyncResources.bundle is next to the module's code")
        return try SGConsentTextRepository.load(rootURL: root).get()
    }

    /// A later build's tree: the bundled v1 templates kept as v1 and also bundled as v2, `current_version` 2 and
    /// `min_valid_version` 2.
    private func textsRaisingTheMinimum() throws -> SGConsentTextRepository {
        let source = try XCTUnwrap(SGCustomerSyncConfig.bundledConsentRootURL())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SGCustomerSyncStaleGrantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.directories.append(root)
        var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json")), options: []) as? [String: Any])
        var versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
        versions["2"] = versions["1"]
        manifest["versions"] = versions
        manifest["current_version"] = 2
        manifest["min_valid_version"] = 2
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: source.appendingPathComponent("v1", isDirectory: true), to: root.appendingPathComponent("v1", isDirectory: true))
        let texts = try SGConsentTextRepository.load(rootURL: root).get()
        XCTAssertEqual(texts.minValidVersion, 2)
        return texts
    }
}
#endif
