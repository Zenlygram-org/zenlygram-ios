import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — clearance from persisted state (design 40 §6.4, Contract issue 19): at t = 0, with no
/// network, a consented, linked, synced account keeps `.tasksSync` (also after a relaunch); the
/// post-link consents marker does not gate; erasing, a server-ended link, the `not_linked` binding,
/// a rejected grant and a grant this build treats as stale (§4.6 rows 5–6, on every signed-in
/// account, not only the primary one) never yield upload clearance.
final class SGCustomerClearanceTests: XCTestCase {
    private let tg: Int64 = 555_000_111
    private let authority = "zenlygram.org"
    private let binding = "01JBBINDINGAAAAAAAAAAAAAAA"
    /// 2026-11-01T09:00:00Z.
    private let start = Date(timeIntervalSince1970: 1_793_523_600)
    /// Fake operator values (never real operator data), unlike the `v1-uz` vector's.
    private var changedOperatorValues: SGConsentOperatorValues {
        return SGConsentOperatorValues(decoded: [.name: "Test Operator MChJ", .stir: "987654321", .responsiblePerson: "Test Responsible Person", .contactEmail: "privacy@example.org"])
    }

    private var defaults: UserDefaults!
    private var removeDefaults: (() -> Void)?
    private var removeDirectories: [() -> Void] = []
    private var readable = true
    private var store: SGConsentStore!
    private var grantId = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        self.defaults = made.defaults
        self.removeDefaults = made.remove
        self.removeDirectories = []
        self.readable = true
        self.store = self.makeStore()
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
        self.grantId = try self.store.grant(tg: self.tg, text: text, mode: .required, appVersion: "12.0.1", now: self.start).get().consentId
    }

    override func tearDown() {
        self.removeDefaults?()
        self.removeDirectories.forEach { $0() }
        self.removeDirectories = []
        self.store = nil
        self.defaults = nil
        super.tearDown()
    }

    func testAConsentedLinkedSyncedAccountIsClearedAtTZeroFromPersistedState() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        XCTAssertEqual(self.clearance(), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync])
    }

    func testAnOfflineRelaunchKeepsTasksSync() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        // The next launch: a new store over the same defaults, no transport anywhere.
        let relaunched = self.makeStore()
        let inputs = SGCustomerClearance.inputs(store: relaunched, tg: self.tg, authority: self.authority, bindingDeviceId: self.binding, linkEnded: false, hasProfileReceipt: true)
        XCTAssertTrue(SGCustomerClearance.derive(inputs).contains(.tasksSync))
        XCTAssertEqual(inputs.state, .granted)
        XCTAssertTrue(inputs.latestGrantAcked)
    }

    func testThePostLinkConsentsMarkerDoesNotGate() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        XCTAssertNil(self.store.string(.consentsSent(tg: self.tg, authority: self.authority)))
        let without = self.clearance()
        try self.store.setString("01JBOLDBINDINGAAAAAAAAAAAA", for: .consentsSent(tg: self.tg, authority: self.authority)).get()
        XCTAssertEqual(self.clearance(), without)
        try self.store.setString(self.binding, for: .consentsSent(tg: self.tg, authority: self.authority)).get()
        XCTAssertEqual(self.clearance(), without)
        XCTAssertTrue(without.contains(.tasksSync))
    }

    func testEachStepOfTheLadder() throws {
        XCTAssertEqual(self.clearance(bindingDeviceId: nil, receipt: false), [.recordEvents], "granted, not linked: events are recorded and queued")
        XCTAssertEqual(self.clearance(receipt: false), [.recordEvents], "linked, grant not acked yet")
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        XCTAssertEqual(self.clearance(receipt: false), [.recordEvents, .uploadProfile], "acked: the first sync may go")
        XCTAssertEqual(self.clearance(receipt: true), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync], "synced for this binding")
        XCTAssertEqual(self.clearance(authority: "127.0.0.1:8443", receipt: true), [.recordEvents], "acks are per authority")
        XCTAssertEqual(self.clearance(authority: nil, receipt: true), [.recordEvents], "no authenticated backend")
        XCTAssertEqual(self.clearance(bindingDeviceId: "", receipt: true), [.recordEvents], "an empty binding id is no binding")
    }

    func testErasingNeverYieldsAnything() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        try self.store.setJSONObject(["key": SGCustomerTime.uuid4(), "sent_unknown": false, "since": "2026-11-01T09:30:00Z"], for: .deletion(tg: self.tg, authority: self.authority)).get()
        XCTAssertEqual(self.clearance(), [])
    }

    func testAServerEndedLinkNeverYieldsAnything() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        XCTAssertEqual(self.clearance(linkEnded: true), [])
    }

    func testTheNotLinkedBindingNeverUploads() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        try self.store.setString(self.binding, for: .notLinked(tg: self.tg, authority: self.authority)).get()
        XCTAssertEqual(self.clearance(), [.recordEvents], "this binding answered profile_account_not_linked")
        try self.store.setString("01JBOLDBINDINGAAAAAAAAAAAA", for: .notLinked(tg: self.tg, authority: self.authority)).get()
        XCTAssertEqual(self.clearance(), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync], "an earlier binding's marker does not stop a new one")
    }

    func testARejectedGrantNeverYieldsAnything() throws {
        try self.store.markRejected(tg: self.tg, authority: self.authority, id: self.grantId, code: "consent_text_mismatch").get()
        XCTAssertEqual(self.clearance(), [])
        XCTAssertEqual(self.clearance(authority: "127.0.0.1:8443"), [.recordEvents], "rejections are per authority")
    }

    func testEveryOtherStateGetsNothing() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        for state in SGConsentState.allCases where state != .granted {
            let inputs = SGCustomerClearance.Inputs(readable: true, state: state, latestGrantRejected: false, erasing: false, linkEnded: false, bindingDeviceId: self.binding, latestGrantAcked: true, notLinkedDeviceId: nil, hasProfileReceipt: true)
            XCTAssertEqual(SGCustomerClearance.derive(inputs), [], state.rawValue)
        }
        try self.store.markNeedsReconsent(tg: self.tg, notice: .linkEnded).get()
        XCTAssertEqual(self.clearance(), [], "needs_reconsent from the store")
        _ = try self.store.withdraw(tg: self.tg, authority: self.authority, mode: .required, locale: .uz, appVersion: "12.0.1", now: self.start.addingTimeInterval(60)).get()
        XCTAssertEqual(self.clearance(), [], "withdrawn")
    }

    func testAnUnreadableStoreGetsNothing() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        self.readable = false
        let inputs = SGCustomerClearance.inputs(store: self.store, tg: self.tg, authority: self.authority, bindingDeviceId: self.binding, linkEnded: false, hasProfileReceipt: true)
        XCTAssertFalse(inputs.readable)
        XCTAssertEqual(SGCustomerClearance.derive(inputs), [])
        XCTAssertEqual(SGCustomerClearance.derive(SGCustomerClearance.Inputs(readable: false, state: .granted, latestGrantRejected: false, erasing: false, linkEnded: false, bindingDeviceId: self.binding, latestGrantAcked: true, notLinkedDeviceId: nil, hasProfileReceipt: true)), [])
    }

    func testTheGateMappingTasksReads() throws {
        // T§5.1: `.tasksSync` → allowed, `.recordEvents` only → waiting, else forbidden.
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        let gate = SGCustomerDataGate(post: { _ in })
        gate.setPipelineActive(true)
        gate.publish(self.clearance(), accountPeerId: 1)
        gate.publish(self.clearance(receipt: false), accountPeerId: 2)
        XCTAssertTrue(gate.clearance(accountPeerId: 1).contains(.tasksSync))
        XCTAssertFalse(gate.clearance(accountPeerId: 2).contains(.tasksSync))
        XCTAssertTrue(gate.clearance(accountPeerId: 2).contains(.recordEvents))
        XCTAssertEqual(gate.clearance(accountPeerId: 3), [])
    }

    // MARK: - A grant this build treats as stale (§4.6 rows 5–6)

    func testAGrantBelowTheBundledMinimumGetsNothing() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        let values = try SGCustomerSyncTestFixtures.uzVectorOperatorValues()
        XCTAssertEqual(self.clearance(texts: try SGCustomerSyncTestFixtures.repository(), operatorValues: values), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync], "the build it was granted in")
        // An update bundles v2 and raises min_valid_version above the granted v1.
        let update = try self.textsBundlingV2(minValidVersion: 2)
        let inputs = SGCustomerClearance.inputs(store: self.store, tg: self.tg, authority: self.authority, bindingDeviceId: self.binding, linkEnded: false, hasProfileReceipt: true, texts: update, operatorValues: values)
        XCTAssertEqual(inputs.staleGrantNotice, .reconsent)
        XCTAssertEqual(SGCustomerClearance.derive(inputs), [])
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .granted, "nothing normalised the record: the clearance reads the stale grant itself")
        XCTAssertEqual(self.clearance(texts: try self.textsBundlingV2(minValidVersion: 1), operatorValues: values), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync], "a newer current version alone retires nothing")
    }

    func testChangedOperatorValuesGetNothing() throws {
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        let texts = try SGCustomerSyncTestFixtures.repository()
        let changed = self.changedOperatorValues
        XCTAssertTrue(changed.isComplete)
        let record = self.store.record(tg: self.tg)
        XCTAssertNotNil(SGCustomerClearance.renderedSha256(record: record, texts: texts, operatorValues: changed))
        XCTAssertNotEqual(SGCustomerClearance.renderedSha256(record: record, texts: texts, operatorValues: changed), record?.textSha256)
        let inputs = SGCustomerClearance.inputs(store: self.store, tg: self.tg, authority: self.authority, bindingDeviceId: self.binding, linkEnded: false, hasProfileReceipt: true, texts: texts, operatorValues: changed)
        XCTAssertEqual(inputs.staleGrantNotice, .operatorChanged)
        XCTAssertEqual(SGCustomerClearance.derive(inputs), [])
        XCTAssertEqual(self.clearance(texts: texts, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync], "the values it was granted with")
    }

    /// The review's scenario: two signed-in accounts, both granted, linked and synced, and an update
    /// raises the bundled minimum. Only the primary account's root attaches, so the wall normalises
    /// only its record; the other account must stop all the same — no profile sync, no events, no
    /// Cloud Tasks — although its record still reads `granted`.
    func testEverySignedInAccountStopsNotOnlyThePrimary() throws {
        let other: Int64 = 555_000_222
        let otherBinding = "01JBOTHERBINDINGAAAAAAAAAA"
        let values = try SGCustomerSyncTestFixtures.uzVectorOperatorValues()
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: values))
        let otherGrantId = try self.store.grant(tg: other, text: text, mode: .required, appVersion: "12.0.1", now: self.start).get().consentId
        try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [self.grantId]).get()
        try self.store.markAcked(tg: other, authority: self.authority, ids: [otherGrantId]).get()
        try self.store.setString(otherBinding, for: .consentsSent(tg: other, authority: self.authority)).get()
        let update = try self.textsBundlingV2(minValidVersion: 2)

        // The primary account's root attaches: the presenter decides and persists the normalisation.
        let primaryRecord = self.store.record(tg: self.tg)
        let decision = SGConsentWallPolicy.decide(SGConsentWallInputs(mode: .required, readable: true, record: primaryRecord, storedNotice: nil, bundledCurrentVersion: update.currentVersion, bundledMinValidVersion: update.minValidVersion, renderedSha256ForRecord: SGCustomerClearance.renderedSha256(record: primaryRecord, texts: update, operatorValues: values), latestGrantRejection: nil, linkEnded: false, deletedNotice: false))
        XCTAssertEqual(decision, SGConsentWallDecision(presentation: .wall(.reconsent), normalise: .reconsent))
        try self.store.markNeedsReconsent(tg: self.tg, notice: .reconsent).get()
        // The other account has no root: nothing evaluated its wall.
        XCTAssertEqual(self.store.record(tg: other)?.state, .granted)

        let primary = SGCustomerClearance.derive(SGCustomerClearance.inputs(store: self.store, tg: self.tg, authority: self.authority, bindingDeviceId: self.binding, linkEnded: false, hasProfileReceipt: true, texts: update, operatorValues: values))
        let otherInputs = SGCustomerClearance.inputs(store: self.store, tg: other, authority: self.authority, bindingDeviceId: otherBinding, linkEnded: false, hasProfileReceipt: true, texts: update, operatorValues: values)
        XCTAssertEqual(primary, [])
        XCTAssertEqual(SGCustomerClearance.derive(otherInputs), [], "the account that is not primary")

        // Tasks reads the gate (T§5.1: [] → forbidden), the uploads the planner.
        let gate = SGCustomerDataGate(post: { _ in })
        gate.setPipelineActive(true)
        gate.publish(primary, accountPeerId: 1)
        gate.publish(SGCustomerClearance.derive(otherInputs), accountPeerId: 2)
        XCTAssertFalse(gate.clearance(accountPeerId: 2).contains(.tasksSync))
        XCTAssertFalse(gate.clearance(accountPeerId: 2).contains(.recordEvents))
        func step(_ clearance: SGCustomerClearance.Inputs) -> SGCustomerUploadPlanner.Step {
            let account = SGCustomerUploadPlanner.Account(clearance: clearance, recordConsentId: otherGrantId, firstIdlePassed: true, pendingUploads: self.store.pendingUploads(tg: other, authority: self.authority), latestDecision: self.store.latestDecision(tg: other), consentsSentDeviceId: otherBinding, syncDueAt: self.start, eventsDueAt: self.start)
            return SGCustomerUploadPlanner.next(account, now: self.start)
        }
        XCTAssertEqual(step(SGCustomerClearance.inputs(store: self.store, tg: other, authority: self.authority, bindingDeviceId: otherBinding, linkEnded: false, hasProfileReceipt: true, texts: try SGCustomerSyncTestFixtures.repository(), operatorValues: values)), .sync, "the build it was granted in syncs")
        XCTAssertEqual(step(otherInputs), .none, "no profile sync and no events")
    }

    /// The clearance stops exactly the grants the wall would normalise (rows 5–6), in both modes.
    func testTheClearanceAndTheWallAgreeOnAStaleGrant() {
        let recordHash = String(repeating: "a", count: 64)
        let changedHash = String(repeating: "b", count: 64)
        for version in [nil, 1, 2, 3] as [Int?] {
            for minimum in 1 ... 3 {
                for textSha256 in [recordHash, nil] as [String?] {
                    for rendered in [nil, recordHash, changedHash] as [String?] {
                        let label = "version \(version.map(String.init) ?? "nil"), minimum \(minimum), record hash \(textSha256 == nil ? "nil" : "a"), rendered \(rendered.map { String($0.prefix(1)) } ?? "nil")"
                        let record = SGConsentRecord(tgUserId: self.tg, state: .granted, consentId: self.grantId, textVersion: version, textSha256: textSha256, locale: .uz, consentMode: .required, decidedAt: "2026-11-01T09:00:00Z")
                        func wall(_ mode: SGConsentMode) -> SGConsentStoredNotice? {
                            return SGConsentWallPolicy.decide(SGConsentWallInputs(mode: mode, readable: true, record: record, storedNotice: nil, bundledCurrentVersion: 3, bundledMinValidVersion: minimum, renderedSha256ForRecord: rendered, latestGrantRejection: nil, linkEnded: false, deletedNotice: false)).normalise
                        }
                        let normalise = wall(.required)
                        XCTAssertEqual(wall(.optional), normalise, label)
                        let inputs = SGCustomerClearance.Inputs(readable: true, state: .granted, latestGrantRejected: false, erasing: false, linkEnded: false, bindingDeviceId: self.binding, latestGrantAcked: true, notLinkedDeviceId: nil, hasProfileReceipt: true, textVersion: version, textSha256: textSha256, bundledMinValidVersion: minimum, renderedSha256ForRecord: rendered)
                        XCTAssertEqual(inputs.staleGrantNotice, normalise, label)
                        let expected: SGCustomerDataGate.Clearance = normalise == nil ? [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync] : []
                        XCTAssertEqual(SGCustomerClearance.derive(inputs), expected, label)
                    }
                }
            }
        }
    }

    func testAVersionThisBuildDoesNotBundleIsNotCompared() throws {
        // A grant of v5 (a newer build's, kept after a downgrade): not below the minimum, and this
        // build cannot render it — as on the wall (row 6), it is not compared.
        let newer: Int64 = 555_000_333
        let text = SGConsentRenderedText(version: 5, locale: .ru, canonical: "v5", sha256: String(repeating: "c", count: 64), document: SGConsentDocument.parse("v5"), scopes: SGConsentScope.allCases.map(\.rawValue))
        let consentId = try self.store.grant(tg: newer, text: text, mode: .required, appVersion: "12.0.1", now: self.start).get().consentId
        try self.store.markAcked(tg: newer, authority: self.authority, ids: [consentId]).get()
        let texts = try SGCustomerSyncTestFixtures.repository()
        let values = try SGCustomerSyncTestFixtures.uzVectorOperatorValues()
        XCTAssertNil(SGCustomerClearance.renderedSha256(record: self.store.record(tg: newer), texts: texts, operatorValues: values))
        let inputs = SGCustomerClearance.inputs(store: self.store, tg: newer, authority: self.authority, bindingDeviceId: self.binding, linkEnded: false, hasProfileReceipt: true, texts: texts, operatorValues: values)
        XCTAssertNil(inputs.staleGrantNotice)
        XCTAssertEqual(SGCustomerClearance.derive(inputs), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync])
    }

    // MARK: - Helpers

    private func makeStore() -> SGConsentStore {
        return SGConsentStore(defaults: self.defaults, isReadable: { [unowned self] in self.readable }, now: { [unowned self] in self.start }, notify: { _ in })
    }

    private func clearance(authority: String? = "zenlygram.org", bindingDeviceId: String? = "01JBBINDINGAAAAAAAAAAAAAAA", linkEnded: Bool = false, receipt: Bool = true, texts: SGConsentTextRepository? = nil, operatorValues: SGConsentOperatorValues? = nil) -> SGCustomerDataGate.Clearance {
        return SGCustomerClearance.derive(SGCustomerClearance.inputs(store: self.store, tg: self.tg, authority: authority, bindingDeviceId: bindingDeviceId, linkEnded: linkEnded, hasProfileReceipt: receipt, texts: texts, operatorValues: operatorValues))
    }

    /// A later build's consent tree: the vendored v1 templates bundled as both v1 and v2,
    /// `current_version` 2 and `min_valid_version` = `minValidVersion` (1 or 2).
    private func textsBundlingV2(minValidVersion: Int) throws -> SGConsentTextRepository {
        let made = SGCustomerSyncTestFixtures.makeDirectory()
        self.removeDirectories.append(made.remove)
        let source = SGCustomerSyncTestFixtures.consentRoot
        var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json")), options: []) as? [String: Any])
        var versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
        versions["2"] = versions["1"]
        manifest["versions"] = versions
        manifest["current_version"] = 2
        manifest["min_valid_version"] = minValidVersion
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: made.url.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: source.appendingPathComponent("v1"), to: made.url.appendingPathComponent("v1"))
        switch SGConsentTextRepository.load(rootURL: made.url) {
        case let .success(texts):
            XCTAssertEqual(texts.currentVersion, 2)
            XCTAssertEqual(texts.minValidVersion, minValidVersion)
            return texts
        case let .failure(problem):
            XCTFail("the later tree does not load: \(problem.rawValue)")
            throw problem
        }
    }
}
