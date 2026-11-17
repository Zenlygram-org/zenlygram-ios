import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the vendored consent tree (contract §5.1–5.2, §10): every `template_sha256`
/// recomputes, the manifest rules are the server's, and any corruption makes the repository invalid
/// (the app's activation then is `.failed(.text)`).
final class SGConsentManifestParityTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in self.temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        self.temporaryRoots = []
        super.tearDown()
    }

    func testEveryVendoredTemplateRecomputesItsTemplateSha256() throws {
        let root = SGCustomerSyncTestFixtures.consentRoot
        let manifest = try XCTUnwrap(SGConsentManifest.decode(try Data(contentsOf: root.appendingPathComponent("manifest.json"))), "manifest at \(root.path)")
        XCTAssertFalse(manifest.versions.isEmpty)
        for (version, entry) in manifest.versions {
            XCTAssertEqual(Set(entry.templates.keys), Set(SGConsentLocale.allCases))
            for (locale, template) in entry.templates {
                let text = try XCTUnwrap(SGConsentCanonicalText.decodeUTF8(try Data(contentsOf: root.appendingPathComponent(template.file))), "v\(version) \(locale)")
                XCTAssertEqual(try SGConsentCanonicalText.canonicalSha256(template: text, values: [:], placeholders: manifest.placeholders), template.templateSha256, "v\(version) \(locale)")
            }
        }
    }

    func testTheVendoredTreeLoadsWithTheContractShape() throws {
        let repository = try SGCustomerSyncTestFixtures.repository()
        // Version 2 (2026-11-16) is version 1 with the partner line reworded: the current text of a new
        // consent. Version 1 stays bundled and valid, so a stored consent is kept and never asked again.
        XCTAssertEqual(repository.currentVersion, 2)
        XCTAssertEqual(repository.minValidVersion, 1)
        XCTAssertTrue(repository.isBundled(version: 1))
        XCTAssertTrue(repository.isBundled(version: 2))
        XCTAssertFalse(repository.isBundled(version: 3))
        XCTAssertEqual(repository.manifest.placeholders, ["OPERATOR_NAME", "OPERATOR_STIR", "RESPONSIBLE_PERSON", "CONTACT_EMAIL"])
        XCTAssertEqual(repository.scopes(version: 1), ["link", "profile", "statistics", "tasks_sync"])
        XCTAssertEqual(repository.scopes(version: 2), ["link", "profile", "statistics", "tasks_sync"])
        XCTAssertNil(repository.scopes(version: 3))
    }

    func testEachLocaleRendersTheSharedFixtureHash() throws {
        let repository = try SGCustomerSyncTestFixtures.repository()
        for vector in try SGCustomerSyncTestFixtures.consentVectors() where vector["kind"] as? String == "locale_text" {
            let id = try XCTUnwrap(vector["id"] as? String)
            let locale = try XCTUnwrap(SGConsentLocale(rawValue: try XCTUnwrap(vector["locale"] as? String)))
            let values = SGCustomerSyncTestFixtures.operatorValues(try XCTUnwrap(vector["values"] as? [String: String]))
            let version = try XCTUnwrap(vector["text_version"] as? Int, id)
            let rendered = try XCTUnwrap(repository.render(version: version, locale: locale, operatorValues: values), id)
            XCTAssertEqual(rendered.sha256, vector["text_sha256"] as? String, id)
            XCTAssertEqual(rendered.version, version)
            XCTAssertEqual(rendered.locale, locale)
            XCTAssertEqual(rendered.scopes, ["link", "profile", "statistics", "tasks_sync"])
            XCTAssertFalse(rendered.canonical.contains("{{"), "\(id): every placeholder is filled")
            XCTAssertNotNil(rendered.document.ageStatement, id)
            XCTAssertEqual(repository.renderedSha256(version: version, locale: locale, operatorValues: values), rendered.sha256, id)

            let template = try XCTUnwrap(repository.render(version: version, locale: locale, operatorValues: .none))
            XCTAssertEqual(template.sha256, vector["template_sha256"] as? String, "\(id): without values the placeholders stay")
        }
        XCTAssertNil(repository.render(version: 3, locale: .uz, operatorValues: .none))
        XCTAssertNil(repository.renderedSha256(version: 3, locale: .uz, operatorValues: .none))
    }

    func testTheRenderedHashIsCachedPerValues() throws {
        let repository = try SGCustomerSyncTestFixtures.repository()
        let values = try SGCustomerSyncTestFixtures.uzVectorOperatorValues()
        let first = repository.renderedSha256(version: 1, locale: .uz, operatorValues: values)
        XCTAssertEqual(first, "229fd61b5ac4c2711e1b9635b6e5b24ab44ab5564baac8a2c1067a5b127f64d9")
        XCTAssertEqual(repository.renderedSha256(version: 1, locale: .uz, operatorValues: values), first)
        let other = SGConsentOperatorValues(decoded: [.name: "Other MChJ", .stir: "123456789", .responsiblePerson: "Ali Valiyev", .contactEmail: "privacy@zenlygram.org"])
        XCTAssertNotEqual(repository.renderedSha256(version: 1, locale: .uz, operatorValues: other), first, "other operator values, another text")
    }

    func testTheServersManifestRules() throws {
        XCTAssertNotNil(SGConsentManifest.decode(try self.manifestData { _ in }), "the baseline is valid")
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schema"] = "zenlygram-consent-manifest/2" }),
            ("extra top-level key", { $0["extra"] = 1 }),
            ("missing key", { $0.removeValue(forKey: "placeholders") }),
            ("current not a version", { $0["current_version"] = 3 }),
            ("min 0", { $0["min_valid_version"] = 0 }),
            ("min above current", { $0["min_valid_version"] = 3 }),
            ("current as text", { $0["current_version"] = "1" }),
            ("current as boolean", { $0["current_version"] = true }),
            ("current as fraction", { $0["current_version"] = 1.5 }),
            ("lower-case placeholder", { $0["placeholders"] = ["operator_name"] }),
            ("repeated placeholder", { $0["placeholders"] = ["OPERATOR_NAME", "OPERATOR_NAME"] }),
            ("placeholders not a list", { $0["placeholders"] = "OPERATOR_NAME" }),
            ("no versions", { $0["versions"] = [String: Any]() }),
            ("version key 01", { self.renameVersion(&$0, to: "01") }),
            ("version key 0", { self.renameVersion(&$0, to: "0") }),
            ("version key 32768", { self.renameVersion(&$0, to: "32768") }),
            ("published_at", { self.editVersion(&$0) { $0["published_at"] = "2026-11-1" } }),
            ("no scopes", { self.editVersion(&$0) { $0["scopes"] = [String]() } }),
            ("unknown scope", { self.editVersion(&$0) { $0["scopes"] = ["link", "ads"] } }),
            ("repeated scope", { self.editVersion(&$0) { $0["scopes"] = ["link", "link"] } }),
            ("extra version key", { self.editVersion(&$0) { $0["extra"] = true } }),
            ("missing locale", { self.editVersion(&$0) { self.editLocales(&$0) { $0.removeValue(forKey: "en") } } }),
            ("extra locale", { self.editVersion(&$0) { self.editLocales(&$0) { $0["de"] = $0["en"] } } }),
            ("parent path", { self.editTemplate(&$0) { $0["file"] = "../uz.md" } }),
            ("absolute path", { self.editTemplate(&$0) { $0["file"] = "/v1/uz.md" } }),
            ("not markdown", { self.editTemplate(&$0) { $0["file"] = "v1/uz.txt" } }),
            ("empty component", { self.editTemplate(&$0) { $0["file"] = "v1//uz.md" } }),
            ("upper-case hash", { self.editTemplate(&$0) { $0["template_sha256"] = String(repeating: "A", count: 64) } }),
            ("short hash", { self.editTemplate(&$0) { $0["template_sha256"] = "abc" } }),
            ("extra template key", { self.editTemplate(&$0) { $0["extra"] = 1 } }),
        ]
        for (name, mutate) in mutations {
            XCTAssertNil(SGConsentManifest.decode(try self.manifestData(mutate)), name)
        }
    }

    func testACorruptedTreeMakesTheRepositoryInvalid() throws {
        // A trailing newline does not change the canonical text: still valid.
        let newline = try self.copyOfTheTree()
        try self.append(Data("\n\n".utf8), to: newline.appendingPathComponent("v1/uz.md"))
        XCTAssertNoThrow(try self.load(newline).get())

        let edited = try self.copyOfTheTree()
        try self.append(Data("x".utf8), to: edited.appendingPathComponent("v1/uz.md"))
        XCTAssertEqual(self.problem(edited), .templateMismatch)

        let missing = try self.copyOfTheTree()
        try FileManager.default.removeItem(at: missing.appendingPathComponent("v1/ru.md"))
        XCTAssertEqual(self.problem(missing), .templateUnreadable)

        let malformedUTF8 = try self.copyOfTheTree()
        try self.append(Data([0xC3, 0x28]), to: malformedUTF8.appendingPathComponent("v1/en.md"))
        XCTAssertEqual(self.problem(malformedUTF8), .templateUnreadable)

        let noManifest = try self.copyOfTheTree()
        try FileManager.default.removeItem(at: noManifest.appendingPathComponent("manifest.json"))
        XCTAssertEqual(self.problem(noManifest), .manifestUnreadable)

        let badManifest = try self.copyOfTheTree()
        try Data("{\"schema\":\"zenlygram-consent-manifest/1\"}".utf8).write(to: badManifest.appendingPathComponent("manifest.json"))
        XCTAssertEqual(self.problem(badManifest), .manifestMalformed)
    }

    // MARK: - Helpers

    private func manifestData(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        let data = try Data(contentsOf: SGCustomerSyncTestFixtures.consentRoot.appendingPathComponent("manifest.json"))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func renameVersion(_ object: inout [String: Any], to key: String) {
        guard var versions = object["versions"] as? [String: Any], let entry = versions.removeValue(forKey: "1") else {
            return
        }
        versions[key] = entry
        object["versions"] = versions
    }

    private func editVersion(_ object: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        guard var versions = object["versions"] as? [String: Any], var entry = versions["1"] as? [String: Any] else {
            return
        }
        edit(&entry)
        versions["1"] = entry
        object["versions"] = versions
    }

    private func editLocales(_ entry: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        guard var locales = entry["locales"] as? [String: Any] else {
            return
        }
        edit(&locales)
        entry["locales"] = locales
    }

    private func editTemplate(_ object: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        self.editVersion(&object) { entry in
            self.editLocales(&entry) { locales in
                guard var template = locales["uz"] as? [String: Any] else {
                    return
                }
                edit(&template)
                locales["uz"] = template
            }
        }
    }

    private func copyOfTheTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zenlygram-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: SGCustomerSyncTestFixtures.consentRoot, to: root)
        self.temporaryRoots.append(root)
        return root
    }

    private func append(_ data: Data, to url: URL) throws {
        var contents = try Data(contentsOf: url)
        contents.append(data)
        try contents.write(to: url)
    }

    private func load(_ root: URL) -> Result<SGConsentTextRepository, SGConsentTextRepository.Problem> {
        return SGConsentTextRepository.load(rootURL: root)
    }

    private func problem(_ root: URL) -> SGConsentTextRepository.Problem? {
        if case let .failure(problem) = self.load(root) {
            return problem
        }
        return nil
    }
}
