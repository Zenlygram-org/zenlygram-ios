import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the local consent store (contract §6.2, design 40 §4.4–4.5): exact key names, the
/// synchronous decisions, the readability guard, outbox retention, purge.
final class SGConsentStoreTests: XCTestCase {
    private let tg: Int64 = 555_000_111
    private let authority = "zenlygram.org"
    private let otherAuthority = "127.0.0.1:8443"
    /// 2026-11-01T09:00:00Z, the shared fixture's `recorded_at`.
    private let start = Date(timeIntervalSince1970: 1_793_523_600)

    private var defaults: UserDefaults!
    private var removeDefaults: (() -> Void)?
    private var readable = true
    private var notified: [Int64] = []
    private var pendingIds: [String] = []
    private var mintedIds: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_793_523_600)
    private var store: SGConsentStore!
    private var uzText: SGConsentRenderedText!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        self.defaults = made.defaults
        self.removeDefaults = made.remove
        self.readable = true
        self.notified = []
        self.pendingIds = []
        self.mintedIds = []
        self.clock = self.start
        self.store = self.makeStore(self.defaults)
        let repository = try SGCustomerSyncTestFixtures.repository()
        self.uzText = try XCTUnwrap(repository.render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
    }

    override func tearDown() {
        self.removeDefaults?()
        self.removeDefaults = nil
        self.store = nil
        self.defaults = nil
        super.tearDown()
    }

    // MARK: - Keys

    func testExactKeyNames() {
        let a = "zenlygram.org"
        XCTAssertEqual(SGCustomerStoreKey.record(tg: 555000111).name, "zg.consent.v1.555000111")
        XCTAssertEqual(SGCustomerStoreKey.outbox(tg: 555000111).name, "zg.consent.outbox.v1.555000111")
        XCTAssertEqual(SGCustomerStoreKey.acked(tg: 555000111, authority: a).name, "zg.consent.acked.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.rejected(tg: 555000111, authority: a).name, "zg.consent.rejected.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.notice(tg: 555000111).name, "zg.cs.notice.v1.555000111")
        XCTAssertEqual(SGCustomerStoreKey.consentsSent(tg: 555000111, authority: a).name, "zg.cs.consents_sent.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.bindRefused(tg: 555000111, authority: a).name, "zg.cs.bind_refused.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.linkEnded(tg: 555000111, authority: a).name, "zg.cs.link_ended.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.deletion(tg: 555000111, authority: a).name, "zg.cs.delete.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.deletedNotice(tg: 555000111).name, "zg.cs.deleted_notice.v1.555000111")
        XCTAssertEqual(SGCustomerStoreKey.autoLink(tg: 555000111, authority: a).name, "zg.autolink.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.autoLinkInstall(authority: a).name, "zg.autolink.install.v1@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.budget(route: .sync, authority: a).name, "zg.cs.budget.v1.sync@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.hints(authority: a).name, "zg.cs.hints.v1@zenlygram.org")
        XCTAssertEqual(SGCustomerStoreKey.notLinked(tg: 555000111, authority: a).name, "zg.cs.not_linked.v1.555000111@zenlygram.org")
        XCTAssertEqual(SGCustomerRoute.allCases.map(\.rawValue), ["consents", "sync", "me", "events", "delete"])
    }

    // MARK: - Grant

    func testAGrantMatchesTheSharedConsentsFixture() throws {
        self.pendingIds = ["3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a"]
        XCTAssertEqual(self.uzText.sha256, "229fd61b5ac4c2711e1b9635b6e5b24ab44ab5564baac8a2c1067a5b127f64d9", "the v1-uz vector's operator values")
        let event = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "12.0.1", now: self.start).get()
        let body = try XCTUnwrap(SGConsentsRequest.body(events: [event.encoded()]))

        let fixture = try SGCustomerSyncTestFixtures.jsonObject("consents-valid.json")
        XCTAssertEqual(fixture["tg_user_id"] as? Int, 555000111)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let grant = try XCTUnwrap(cases.first { $0["id"] as? String == "grant" })
        XCTAssertEqual(try self.sortedJSON(try JSONSerialization.jsonObject(with: body, options: [])), try self.sortedJSON(try XCTUnwrap(grant["body"])))

        XCTAssertEqual(self.store.pendingUploads(tg: self.tg, authority: self.authority), [event.encoded()])
        XCTAssertEqual(self.store.latestDecision(tg: self.tg), event.encoded())
        XCTAssertEqual(self.store.latestGrant(tg: self.tg), event)
        XCTAssertEqual(self.notified, [self.tg])
    }

    func testAGrantWritesRecordAndOutboxBeforeReturningAndClearsNoticesAndSuppression() throws {
        XCTAssertNoThrow(try self.store.setString("reconsent", for: .notice(tg: self.tg)).get())
        XCTAssertNoThrow(try self.store.setDeletedNotice(tg: self.tg, at: self.start).get())
        for authority in [self.authority, self.otherAuthority] {
            XCTAssertNoThrow(try self.store.setJSONObject(["v": 1, "failures": 2, "suppressed": "user_unlink"], for: .autoLink(tg: self.tg, authority: authority)).get())
        }
        self.notified = []

        let event = try self.store.grant(tg: self.tg, text: self.uzText, mode: .optional, appVersion: "12.0.1", now: self.start).get()

        // Synchronously on disk-backed defaults, before anything else ran.
        let recordText = try XCTUnwrap(self.defaults.string(forKey: "zg.consent.v1.555000111"))
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(recordText.utf8), options: []) as? [String: Any])
        XCTAssertEqual(Set(record.keys), ["v", "tg_user_id", "state", "consent_id", "text_version", "text_sha256", "locale", "consent_mode", "decided_at"])
        XCTAssertEqual(record["v"] as? Int, 1)
        XCTAssertEqual(record["tg_user_id"] as? Int64, self.tg)
        XCTAssertEqual(record["state"] as? String, "granted")
        XCTAssertEqual(record["consent_id"] as? String, event.consentId)
        XCTAssertEqual(record["text_version"] as? Int, 1)
        XCTAssertEqual(record["text_sha256"] as? String, self.uzText.sha256)
        XCTAssertEqual(record["locale"] as? String, "uz")
        XCTAssertEqual(record["consent_mode"] as? String, "optional")
        XCTAssertEqual(record["decided_at"] as? String, "2026-11-01T09:00:00Z")
        XCTAssertEqual(self.defaults.stringArray(forKey: "zg.consent.outbox.v1.555000111"), [String(decoding: event.encoded(), as: UTF8.self)])

        XCTAssertNil(self.defaults.object(forKey: "zg.cs.notice.v1.555000111"))
        XCTAssertNil(self.defaults.object(forKey: "zg.cs.deleted_notice.v1.555000111"))
        for authority in [self.authority, self.otherAuthority] {
            let autoLink = try XCTUnwrap(self.store.jsonObject(.autoLink(tg: self.tg, authority: authority)))
            XCTAssertNil(autoLink["suppressed"], "a new grant lifts the Unlink suppression")
            XCTAssertEqual(autoLink["failures"] as? Int, 2)
        }
        XCTAssertEqual(self.store.record(tg: self.tg), SGConsentRecord(tgUserId: self.tg, state: .granted, consentId: event.consentId, textVersion: 1, textSha256: self.uzText.sha256, locale: .uz, consentMode: .optional, decidedAt: "2026-11-01T09:00:00Z"))
        XCTAssertEqual(self.notified, [self.tg])
    }

    func testTheEventJSONOfEachAction() throws {
        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "12.0.1", now: self.start).get()
        let grantObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: grant.encoded(), options: []) as? [String: Any])
        XCTAssertEqual(Set(grantObject.keys), ["consent_id", "tg_user_id", "action", "scopes", "text_version", "text_sha256", "locale", "consent_mode", "age_confirmed", "recorded_at", "platform", "app_version"])
        XCTAssertEqual(grantObject["action"] as? String, "grant")
        XCTAssertEqual(grantObject["scopes"] as? [String], ["link", "profile", "statistics", "tasks_sync"])
        XCTAssertEqual(grantObject["platform"] as? String, "ios")
        let ageConfirmed = try XCTUnwrap(grantObject["age_confirmed"] as? NSNumber)
        XCTAssertTrue(CFGetTypeID(ageConfirmed) == CFBooleanGetTypeID() && ageConfirmed.boolValue, "age_confirmed is JSON true")
        XCTAssertTrue(SGCustomerTime.isUUID4(grant.consentId))

        let withdraw = try self.store.withdraw(tg: self.tg, authority: self.authority, mode: .required, locale: .ru, appVersion: "12.0.1", now: self.start.addingTimeInterval(60)).get()
        let withdrawObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: withdraw.encoded(), options: []) as? [String: Any])
        XCTAssertEqual(Set(withdrawObject.keys), ["consent_id", "tg_user_id", "action", "scopes", "text_version", "locale", "consent_mode", "recorded_at", "platform", "app_version"])
        XCTAssertEqual(withdrawObject["action"] as? String, "withdraw")
        XCTAssertEqual(withdrawObject["scopes"] as? [String], ["link", "profile", "statistics", "tasks_sync"])
        XCTAssertEqual(withdrawObject["text_version"] as? Int, 1)
        XCTAssertEqual(withdrawObject["locale"] as? String, "ru")
        XCTAssertEqual(withdrawObject["recorded_at"] as? String, "2026-11-01T09:01:00Z")
        XCTAssertNotEqual(withdraw.consentId, grant.consentId)
    }

    func testTheSharedFixtureEventsEncodeExactly() throws {
        let fixture = try SGCustomerSyncTestFixtures.jsonObject("consents-valid.json")
        for testCase in try XCTUnwrap(fixture["cases"] as? [[String: Any]]) {
            let body = try XCTUnwrap(testCase["body"] as? [String: Any])
            var events: [Data] = []
            for object in try XCTUnwrap(body["consents"] as? [[String: Any]]) {
                let data = try JSONSerialization.data(withJSONObject: object, options: [])
                let event = try XCTUnwrap(SGConsentEvent.decode(data), "\(testCase["id"] ?? "")")
                XCTAssertEqual(try self.sortedJSON(event.jsonObject()), try self.sortedJSON(object))
                events.append(event.encoded())
            }
            let rebuilt = try XCTUnwrap(SGConsentsRequest.body(events: events))
            XCTAssertEqual(try self.sortedJSON(try JSONSerialization.jsonObject(with: rebuilt, options: [])), try self.sortedJSON(body))
        }
    }

    func testAppVersionIsClippedToVer() {
        XCTAssertEqual(SGConsentEvent.clippedVersion("12.0.1 (beta)/é"), "12.0.1 (beta)")
        XCTAssertEqual(SGConsentEvent.clippedVersion(String(repeating: "1", count: 40)), String(repeating: "1", count: 32))
        XCTAssertEqual(SGConsentEvent.clippedVersion("éé"), "0")
    }

    func testAGrantOfAnInvalidAccountOrTextWritesNothing() {
        XCTAssertEqual(self.failure(self.store.grant(tg: 0, text: self.uzText, mode: .required, appVersion: "1", now: self.start)), .invalidInput)
        XCTAssertEqual(self.failure(self.store.grant(tg: 9_007_199_254_740_992, text: self.uzText, mode: .required, appVersion: "1", now: self.start)), .invalidInput)
        self.pendingIds = ["not-a-uuid"]
        XCTAssertEqual(self.failure(self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start)), .invalidInput)
        XCTAssertEqual(self.consentKeys(), [], "nothing written")
        XCTAssertEqual(self.notified, [])
    }

    // MARK: - Decline

    func testAnOptionalDeclineIsRecordedAndARequiredDeclinePersistsNothing() throws {
        XCTAssertEqual(self.failure(self.store.decline(tg: self.tg, mode: .required)), .notAllowed)
        XCTAssertEqual(self.consentKeys(), [])
        XCTAssertEqual(self.notified, [])

        XCTAssertNoThrow(try self.store.decline(tg: self.tg, mode: .optional).get())
        let record = try XCTUnwrap(self.store.record(tg: self.tg))
        XCTAssertEqual(record.state, .declined)
        XCTAssertEqual(record.consentMode, .optional)
        XCTAssertEqual(record.decidedAt, "2026-11-01T09:00:00Z")
        XCTAssertNil(record.consentId)
        XCTAssertNil(self.defaults.stringArray(forKey: SGCustomerStoreKey.outbox(tg: self.tg).name), "a decline is never uploaded")
        XCTAssertEqual(self.notified, [self.tg])

        // Not from granted: that needs a withdraw, which the server learns about.
        _ = try self.store.grant(tg: self.tg, text: self.uzText, mode: .optional, appVersion: "1", now: self.start).get()
        XCTAssertEqual(self.failure(self.store.decline(tg: self.tg, mode: .optional)), .notAllowed)
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .granted)
    }

    // MARK: - Withdraw

    func testAWithdrawFromGranted() throws {
        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "12.0.1", now: self.start).get()
        self.notified = []
        let withdraw = try self.store.withdraw(tg: self.tg, authority: nil, mode: .required, locale: .en, appVersion: "12.0.1", now: self.start.addingTimeInterval(3600)).get()
        let record = try XCTUnwrap(self.store.record(tg: self.tg))
        XCTAssertEqual(record.state, .withdrawn)
        XCTAssertEqual(record.consentId, withdraw.consentId)
        XCTAssertEqual(record.decidedAt, "2026-11-01T10:00:00Z")
        XCTAssertEqual(record.textVersion, 1)
        XCTAssertNil(record.textSha256)
        XCTAssertEqual(self.store.pendingUploads(tg: self.tg, authority: self.authority), [grant.encoded(), withdraw.encoded()])
        XCTAssertEqual(self.store.pendingWithdraws(tg: self.tg, authority: self.authority), [withdraw.encoded()])
        XCTAssertEqual(self.store.latestDecision(tg: self.tg), withdraw.encoded())
        XCTAssertEqual(self.notified, [self.tg])
        XCTAssertEqual(self.failure(self.store.withdraw(tg: self.tg, authority: self.authority, mode: .required, locale: .en, appVersion: "1", now: self.start)), .notAllowed, "already withdrawn")
    }

    func testAWithdrawFromNeedsReconsentOnlyWhileTheServerHoldsTheGrant() throws {
        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start).get()
        XCTAssertNoThrow(try self.store.markNeedsReconsent(tg: self.tg, notice: .reconsent).get())
        XCTAssertEqual(self.failure(self.store.withdraw(tg: self.tg, authority: self.authority, mode: .required, locale: .uz, appVersion: "1", now: self.start)), .notAllowed, "not acked")
        XCTAssertNoThrow(try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [grant.consentId]).get())
        XCTAssertEqual(self.failure(self.store.withdraw(tg: self.tg, authority: self.otherAuthority, mode: .required, locale: .uz, appVersion: "1", now: self.start)), .notAllowed, "acked elsewhere only")
        XCTAssertEqual(self.failure(self.store.withdraw(tg: self.tg, authority: nil, mode: .required, locale: .uz, appVersion: "1", now: self.start)), .notAllowed)
        XCTAssertNoThrow(try self.store.withdraw(tg: self.tg, authority: self.authority, mode: .required, locale: .uz, appVersion: "1", now: self.start.addingTimeInterval(1)).get())
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .withdrawn)
        XCTAssertNil(self.store.storedNotice(tg: self.tg))
    }

    func testAWithdrawNeedsAGrant() throws {
        XCTAssertEqual(self.failure(self.store.withdraw(tg: self.tg, authority: self.authority, mode: .optional, locale: .uz, appVersion: "1", now: self.start)), .notAllowed)
        XCTAssertNoThrow(try self.store.decline(tg: self.tg, mode: .optional).get())
        XCTAssertEqual(self.failure(self.store.withdraw(tg: self.tg, authority: self.authority, mode: .optional, locale: .uz, appVersion: "1", now: self.start)), .notAllowed)
    }

    // MARK: - Normalisations

    func testNeedsReconsentAndWithdrawnRemote() throws {
        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start).get()
        XCTAssertNoThrow(try self.store.markNeedsReconsent(tg: self.tg, notice: .operatorChanged).get())
        var record = try XCTUnwrap(self.store.record(tg: self.tg))
        XCTAssertEqual(record.state, .needsReconsent)
        XCTAssertEqual(record.consentId, grant.consentId, "the grant stays named")
        XCTAssertEqual(record.decidedAt, "2026-11-01T09:00:00Z")
        XCTAssertEqual(self.store.storedNotice(tg: self.tg), .operatorChanged)

        XCTAssertEqual(self.failure(self.store.markWithdrawnRemote(tg: self.tg, effectiveAt: "2026-11-01 10:00:00")), .invalidInput)
        let remoteId = "9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d7"
        XCTAssertNoThrow(try self.store.markWithdrawnRemote(tg: self.tg, effectiveAt: "2026-11-01T10:00:00Z", consentId: remoteId).get())
        record = try XCTUnwrap(self.store.record(tg: self.tg))
        XCTAssertEqual(record.state, .withdrawnRemote)
        XCTAssertEqual(record.consentId, remoteId)
        XCTAssertEqual(record.decidedAt, "2026-11-01T10:00:00Z")
        XCTAssertNil(self.store.storedNotice(tg: self.tg))
        XCTAssertEqual(self.failure(self.store.markNeedsReconsent(tg: self.tg, notice: .reconsent)), .notAllowed, "only a grant is asked again")
    }

    func testConsentStaleNormalisesOnlyTheGrantItNames() throws {
        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start).get()
        self.notified = []
        XCTAssertEqual(self.failure(self.store.normaliseAfterConsentStale(tg: self.tg, consentId: "e1f3a5c7-b9d1-4e3f-a5b7-c9d1e3f5a7b9")), .notAllowed)
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .granted)
        XCTAssertEqual(self.notified, [])

        XCTAssertNoThrow(try self.store.normaliseAfterConsentStale(tg: self.tg, consentId: grant.consentId).get())
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .needsReconsent)
        XCTAssertEqual(self.store.storedNotice(tg: self.tg), .linkEnded)
        XCTAssertEqual(self.notified, [self.tg])
        XCTAssertEqual(self.failure(self.store.normaliseAfterConsentStale(tg: self.tg, consentId: nil)), .notAllowed, "already asked again")

        // The manual path may not know the id: nil normalises the current grant.
        let second = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start.addingTimeInterval(10)).get()
        XCTAssertNoThrow(try self.store.normaliseAfterConsentStale(tg: self.tg, consentId: nil).get())
        XCTAssertEqual(self.store.record(tg: self.tg)?.consentId, second.consentId)
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .needsReconsent)
    }

    // MARK: - Readability

    func testNoWriteHappensWhileUnreadable() throws {
        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start).get()
        let before = self.allKeys()
        self.readable = false
        self.notified = []
        XCTAssertFalse(self.store.isReadable)
        XCTAssertEqual(self.failure(self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start)), .unreadable)
        XCTAssertEqual(self.failure(self.store.decline(tg: self.tg, mode: .optional)), .unreadable)
        XCTAssertEqual(self.failure(self.store.withdraw(tg: self.tg, authority: self.authority, mode: .required, locale: .uz, appVersion: "1", now: self.start)), .unreadable)
        XCTAssertEqual(self.failure(self.store.markWithdrawnRemote(tg: self.tg, effectiveAt: "2026-11-02T00:00:00Z")), .unreadable)
        XCTAssertEqual(self.failure(self.store.markNeedsReconsent(tg: self.tg, notice: .reconsent)), .unreadable)
        XCTAssertEqual(self.failure(self.store.normaliseAfterConsentStale(tg: self.tg, consentId: grant.consentId)), .unreadable)
        XCTAssertEqual(self.failure(self.store.markAcked(tg: self.tg, authority: self.authority, ids: [grant.consentId])), .unreadable)
        XCTAssertEqual(self.failure(self.store.markRejected(tg: self.tg, authority: self.authority, id: grant.consentId, code: "consent_text_mismatch")), .unreadable)
        XCTAssertEqual(self.failure(self.store.setString("x", for: .consentsSent(tg: self.tg, authority: self.authority))), .unreadable)
        XCTAssertEqual(self.failure(self.store.setJSONObject(["v": 1], for: .hints(authority: self.authority))), .unreadable)
        XCTAssertEqual(self.failure(self.store.setBindRefused(tg: self.tg, authority: self.authority, consentId: grant.consentId)), .unreadable)
        XCTAssertEqual(self.failure(self.store.setDeletedNotice(tg: self.tg, at: self.start)), .unreadable)
        XCTAssertEqual(self.failure(self.store.purge(tg: self.tg)), .unreadable)
        XCTAssertEqual(self.failure(self.store.resetForDebug(tg: self.tg)), .unreadable)
        XCTAssertEqual(self.allKeys(), before, "nothing changed")
        XCTAssertEqual(self.notified, [])
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .granted)
    }

    func testAnUnreadableFirstLaunchWritesNotEvenTheCanary() {
        self.readable = false
        XCTAssertEqual(self.failure(self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start)), .unreadable)
        XCTAssertEqual(self.allKeys(), [])
        self.readable = true
        XCTAssertTrue(self.store.isReadable)
        XCTAssertEqual(self.allKeys(), [SGConsentStore.canaryKey])
    }

    func testAWriteThatDoesNotReadBackIsASaveFailure() throws {
        let suite = "org.zenlygram.SGCustomerSyncTests.\(UUID().uuidString)"
        let dropping = try XCTUnwrap(SGDroppingDefaults(suiteName: suite))
        defer {
            dropping.removePersistentDomain(forName: suite)
        }
        let store = self.makeStore(dropping)
        XCTAssertTrue(store.isReadable, "the canary was written before writes start failing")
        dropping.dropsWrites = true
        XCTAssertEqual(self.failure(store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start)), .saveFailed)
        XCTAssertNil(store.record(tg: self.tg))
        XCTAssertNil(store.latestDecision(tg: self.tg))
        XCTAssertEqual(self.notified, [])
    }

    // MARK: - Outbox

    func testTheOutboxKeepsEveryUnackedWithdrawAndTheLatestDecision() throws {
        var names: [String: String] = [:]
        func grant(_ name: String) throws {
            self.clock = self.clock.addingTimeInterval(60)
            names[try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.clock).get().consentId] = name
        }
        func withdraw(_ name: String) throws {
            self.clock = self.clock.addingTimeInterval(60)
            names[try self.store.withdraw(tg: self.tg, authority: nil, mode: .required, locale: .uz, appVersion: "1", now: self.clock).get().consentId] = name
        }
        func ack(_ name: String) throws {
            let id = try XCTUnwrap(names.first { $0.value == name }?.key)
            XCTAssertNoThrow(try self.store.markAcked(tg: self.tg, authority: self.otherAuthority, ids: [id]).get())
        }
        func reject(_ name: String) throws {
            let id = try XCTUnwrap(names.first { $0.value == name }?.key)
            XCTAssertNoThrow(try self.store.markRejected(tg: self.tg, authority: self.otherAuthority, id: id, code: "consent_text_mismatch").get())
        }
        func outbox() -> [String] {
            // An authority with no marks sees every entry, in recorded order.
            return self.store.pendingUploads(tg: self.tg, authority: self.authority).compactMap { SGConsentEvent.decode($0).flatMap { names[$0.consentId] } }
        }

        try grant("g0"); try withdraw("w0"); try ack("g0"); try ack("w0")
        try grant("g1"); try withdraw("w1"); try ack("g1")
        try grant("g2"); try reject("g2"); try withdraw("w2")
        try grant("g3"); try withdraw("w3")
        try grant("g4"); try withdraw("w4")
        XCTAssertEqual(outbox(), ["g0", "w0", "g1", "w1", "g2", "w2", "g3", "w3", "g4", "w4"])

        try grant("g5")
        XCTAssertEqual(outbox(), ["w0", "g1", "w1", "g2", "w2", "g3", "w3", "g4", "w4", "g5"], "the oldest acked entry goes first")
        try withdraw("w5")
        XCTAssertEqual(outbox(), ["g1", "w1", "g2", "w2", "g3", "w3", "g4", "w4", "g5", "w5"], "an acked withdraw may go")
        try grant("g6")
        XCTAssertEqual(outbox(), ["w1", "g2", "w2", "g3", "w3", "g4", "w4", "g5", "w5", "g6"])
        try withdraw("w6")
        XCTAssertEqual(outbox(), ["w1", "w2", "g3", "w3", "g4", "w4", "g5", "w5", "g6", "w6"], "then a rejected grant")
        try grant("g7")
        XCTAssertEqual(outbox(), ["w1", "w2", "w3", "g4", "w4", "g5", "w5", "g6", "w6", "g7"], "then the oldest un-acked grant")

        // Only un-acked withdraws and the latest decision remain eventually; they are never dropped,
        // so the outbox outgrows the cap.
        for round in 7 ..< 14 {
            try withdraw("w\(round)")
            try grant("g\(round + 1)")
        }
        let final = outbox()
        XCTAssertEqual(final.last, "g14", "the latest decision")
        XCTAssertEqual(final.filter { $0.hasPrefix("g") }, ["g14"])
        XCTAssertEqual(final.filter { $0.hasPrefix("w") }, ["w1", "w2", "w3", "w4", "w5", "w6"] + (7 ..< 14).map { "w\($0)" }, "every un-acked withdraw stays")
        XCTAssertGreaterThan(final.count, SGConsentStore.outboxLimit)
    }

    func testPendingUploadsAreNeitherAckedNorRejectedAtTheAuthority() throws {
        let first = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start).get()
        let withdraw = try self.store.withdraw(tg: self.tg, authority: nil, mode: .required, locale: .uz, appVersion: "1", now: self.start.addingTimeInterval(1)).get()
        let second = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start.addingTimeInterval(2)).get()
        XCTAssertNoThrow(try self.store.markAcked(tg: self.tg, authority: self.authority, ids: [first.consentId, "unknown-id"]).get())
        XCTAssertNoThrow(try self.store.markRejected(tg: self.tg, authority: self.authority, id: second.consentId, code: "consent_text_mismatch").get())
        XCTAssertEqual(self.store.pendingUploads(tg: self.tg, authority: self.authority), [withdraw.encoded()])
        XCTAssertEqual(self.store.pendingUploads(tg: self.tg, authority: self.otherAuthority), [first.encoded(), withdraw.encoded(), second.encoded()])
        XCTAssertTrue(self.store.isAcked(tg: self.tg, authority: self.authority, consentId: first.consentId))
        XCTAssertFalse(self.store.isAcked(tg: self.tg, authority: self.authority, consentId: "unknown-id"), "only outbox entries are marked")
        XCTAssertEqual(self.store.latestGrantRejection(tg: self.tg, authority: self.authority), "consent_text_mismatch")
        XCTAssertNil(self.store.latestGrantRejection(tg: self.tg, authority: self.otherAuthority))
    }

    func testAWithdrawIsNeverMarkedRejected() throws {
        _ = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start).get()
        let withdraw = try self.store.withdraw(tg: self.tg, authority: nil, mode: .required, locale: .uz, appVersion: "1", now: self.start.addingTimeInterval(1)).get()
        XCTAssertEqual(self.failure(self.store.markRejected(tg: self.tg, authority: self.authority, id: withdraw.consentId, code: "invalid_request")), .notAllowed)
        XCTAssertEqual(self.store.pendingWithdraws(tg: self.tg, authority: self.authority), [withdraw.encoded()])

        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start.addingTimeInterval(2)).get()
        XCTAssertNoThrow(try self.store.markRejected(tg: self.tg, authority: self.authority, id: grant.consentId, code: "Not A Code!").get())
        XCTAssertEqual(self.store.latestGrantRejection(tg: self.tg, authority: self.authority), "unknown")
    }

    // MARK: - bind/start consent

    func testTheBindConsentObject() throws {
        XCTAssertNil(self.store.bindConsentObject(tg: self.tg, authority: self.authority), "no grant")
        let grant = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "12.0.1", now: self.start).get()
        let object = try XCTUnwrap(self.store.bindConsentObject(tg: self.tg, authority: self.authority))
        XCTAssertEqual(try self.sortedJSON(object), try self.sortedJSON(grant.jsonObject()))

        XCTAssertNoThrow(try self.store.setJSONObject(["key": SGCustomerTime.uuid4(), "sent_unknown": false, "since": "2026-11-01T09:00:00Z"], for: .deletion(tg: self.tg, authority: self.authority)).get())
        XCTAssertNil(self.store.bindConsentObject(tg: self.tg, authority: self.authority), "erasing")
        XCTAssertNotNil(self.store.bindConsentObject(tg: self.tg, authority: self.otherAuthority))
        XCTAssertNoThrow(try self.store.setJSONObject(nil, for: .deletion(tg: self.tg, authority: self.authority)).get())

        XCTAssertNoThrow(try self.store.setBindRefused(tg: self.tg, authority: self.authority, consentId: grant.consentId).get())
        XCTAssertNil(self.store.bindConsentObject(tg: self.tg, authority: self.authority), "bind/start refused it")

        let second = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start.addingTimeInterval(5)).get()
        XCTAssertEqual(self.store.bindConsentObject(tg: self.tg, authority: self.authority)?["consent_id"] as? String, second.consentId)
        XCTAssertNoThrow(try self.store.markRejected(tg: self.tg, authority: self.authority, id: second.consentId, code: "consent_text_mismatch").get())
        XCTAssertNil(self.store.bindConsentObject(tg: self.tg, authority: self.authority), "rejected")

        let third = try self.store.grant(tg: self.tg, text: self.uzText, mode: .required, appVersion: "1", now: self.start.addingTimeInterval(6)).get()
        XCTAssertNotNil(self.store.bindConsentObject(tg: self.tg, authority: self.authority))
        XCTAssertNoThrow(try self.store.normaliseAfterConsentStale(tg: self.tg, consentId: third.consentId).get())
        XCTAssertNil(self.store.bindConsentObject(tg: self.tg, authority: self.authority), "not granted")
    }

    // MARK: - Purge

    func testPurgeRemovesEveryKeyOfTheAccountAcrossAuthorities() throws {
        let other: Int64 = 5_550_001_110
        for account in [self.tg, other] {
            let grant = try self.store.grant(tg: account, text: self.uzText, mode: .required, appVersion: "1", now: self.start).get()
            for authority in [self.authority, self.otherAuthority] {
                XCTAssertNoThrow(try self.store.markAcked(tg: account, authority: authority, ids: [grant.consentId]).get())
                XCTAssertNoThrow(try self.store.setString("01JBDEVICE", for: .consentsSent(tg: account, authority: authority)).get())
                XCTAssertNoThrow(try self.store.setString("01JBDEVICE", for: .notLinked(tg: account, authority: authority)).get())
                XCTAssertNoThrow(try self.store.setBindRefused(tg: account, authority: authority, consentId: grant.consentId).get())
                XCTAssertNoThrow(try self.store.setJSONObject(["code": "invalid_token", "at": "2026-11-01T09:00:00Z"], for: .linkEnded(tg: account, authority: authority)).get())
                XCTAssertNoThrow(try self.store.setJSONObject(["key": SGCustomerTime.uuid4(), "sent_unknown": true, "since": "2026-11-01T09:00:00Z"], for: .deletion(tg: account, authority: authority)).get())
                XCTAssertNoThrow(try self.store.setJSONObject(["v": 1, "failures": 0], for: .autoLink(tg: account, authority: authority)).get())
            }
            XCTAssertNoThrow(try self.store.markNeedsReconsent(tg: account, notice: .linkEnded).get())
            XCTAssertNoThrow(try self.store.setDeletedNotice(tg: account, at: self.start).get())
        }
        let markedGrant = try XCTUnwrap(self.store.latestGrant(tg: self.tg))
        XCTAssertNoThrow(try self.store.markRejected(tg: self.tg, authority: self.authority, id: markedGrant.consentId, code: "consent_scopes_mismatch").get())
        XCTAssertNoThrow(try self.store.setJSONObject(["attest_null": 1], for: .autoLinkInstall(authority: self.authority)).get())
        XCTAssertNoThrow(try self.store.setJSONObject(["count": 1], for: .budget(route: .events, authority: self.authority)).get())
        XCTAssertNoThrow(try self.store.setJSONObject(["flush_interval_s": 300], for: .hints(authority: self.authority)).get())
        XCTAssertEqual(self.store.knownTelegramUserIds(), [self.tg, other])
        // Per account: record, outbox, notice, deleted notice + 7 keys at each of the 2 authorities;
        // the rejected marks of the purged account.
        XCTAssertEqual(self.keys(of: self.tg).count, 19)
        let otherKeysBefore = self.keys(of: other)
        XCTAssertEqual(otherKeysBefore.count, 18)
        self.notified = []

        XCTAssertNoThrow(try self.store.purge(tg: self.tg).get())
        XCTAssertEqual(self.keys(of: self.tg), [], "every key of the account, every authority")
        XCTAssertEqual(self.keys(of: other), otherKeysBefore, "another account whose id starts with the same digits is untouched")
        XCTAssertEqual(Set(self.allKeys()).subtracting(otherKeysBefore), [
            SGConsentStore.canaryKey,
            "zg.autolink.install.v1@zenlygram.org",
            "zg.cs.budget.v1.events@zenlygram.org",
            "zg.cs.hints.v1@zenlygram.org",
        ], "device-wide keys stay")
        XCTAssertEqual(self.store.knownTelegramUserIds(), [other])
        XCTAssertNil(self.store.record(tg: self.tg))
        XCTAssertEqual(self.notified, [self.tg])

        // Purging an account with nothing left changes nothing and posts nothing.
        XCTAssertNoThrow(try self.store.purge(tg: self.tg).get())
        XCTAssertEqual(self.notified, [self.tg])

        // The deletion flow writes the deleted notice AFTER its purge, so it survives.
        XCTAssertNoThrow(try self.store.setDeletedNotice(tg: self.tg, at: self.start.addingTimeInterval(5)).get())
        XCTAssertEqual(self.store.deletedNotice(tg: self.tg), "2026-11-01T09:00:05Z")
        XCTAssertNoThrow(try self.store.clearDeletedNotice(tg: self.tg).get())
        XCTAssertNil(self.store.deletedNotice(tg: self.tg))
    }

    func testTheManagedKeysAreWrittenOnlyByTheirOperations() {
        XCTAssertEqual(self.failure(self.store.setString("{}", for: .record(tg: self.tg))), .notAllowed)
        XCTAssertEqual(self.failure(self.store.setString("x", for: .outbox(tg: self.tg))), .notAllowed)
        XCTAssertEqual(self.failure(self.store.setJSONObject([:], for: .acked(tg: self.tg, authority: self.authority))), .notAllowed)
        XCTAssertEqual(self.failure(self.store.setJSONObject([:], for: .rejected(tg: self.tg, authority: self.authority))), .notAllowed)
        XCTAssertEqual(self.consentKeys(), [])
    }

    // MARK: - Time (SGCustomerTime)

    func testInstantsAndUUIDs() {
        XCTAssertEqual(SGCustomerTime.instant(Date(timeIntervalSince1970: 0.9)), "1970-01-01T00:00:00Z")
        XCTAssertEqual(SGCustomerTime.instant(self.start.addingTimeInterval(0.999)), "2026-11-01T09:00:00Z")
        XCTAssertEqual(SGCustomerTime.date(fromInstant: "2026-11-01T09:00:00Z"), self.start)
        XCTAssertEqual(SGCustomerTime.date(fromInstant: "2028-02-29T23:59:59Z").map(SGCustomerTime.instant), "2028-02-29T23:59:59Z")
        for invalid in ["2026-02-30T00:00:00Z", "2026-11-01T09:00:00.5Z", "2026-11-01 09:00:00Z", "2026-11-01T24:00:00Z", "2026-11-01T09:00:00+00:00", "2026-11-01T09:00:60Z", ""] {
            XCTAssertNil(SGCustomerTime.date(fromInstant: invalid), invalid)
        }
        let id = SGCustomerTime.uuid4()
        XCTAssertTrue(SGCustomerTime.isUUID4(id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertFalse(SGCustomerTime.isUUID4(id.uppercased()))
        XCTAssertFalse(SGCustomerTime.isUUID4("3a1c6f0e-5b7d-1e2a-9c8b-1f2e3d4c5b6a"), "version 1")
        XCTAssertFalse(SGCustomerTime.isUUID4("3a1c6f0e-5b7d-4e2a-7c8b-1f2e3d4c5b6a"), "variant")
    }

    // MARK: - Helpers

    private func makeStore(_ defaults: UserDefaults) -> SGConsentStore {
        return SGConsentStore(
            defaults: defaults,
            isReadable: { [unowned self] in self.readable },
            now: { [unowned self] in self.clock },
            makeConsentId: { [unowned self] in
                let id = self.pendingIds.isEmpty ? SGCustomerTime.uuid4() : self.pendingIds.removeFirst()
                self.mintedIds.append(id)
                return id
            },
            notify: { [unowned self] tg in self.notified.append(tg) }
        )
    }

    private func failure<T>(_ result: Result<T, SGConsentStoreError>) -> SGConsentStoreError? {
        if case let .failure(error) = result {
            return error
        }
        return nil
    }

    /// Every `zg.` key of the test domain.
    private func allKeys() -> [String] {
        return self.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("zg.") }.sorted()
    }

    /// The `zg.` keys except the canary.
    private func consentKeys() -> [String] {
        return self.allKeys().filter { $0 != SGConsentStore.canaryKey }
    }

    /// The keys naming `account` exactly (`….<tg>` or `….<tg>@<authority>`), written out here
    /// independently of `SGCustomerStoreKey.belongs`.
    private func keys(of account: Int64) -> [String] {
        return self.allKeys().filter { $0.hasSuffix(".\(account)") || $0.contains(".\(account)@") }
    }

    private func sortedJSON(_ object: Any) throws -> String {
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Defaults whose writes can be switched off, so a write never reads back.
private final class SGDroppingDefaults: UserDefaults {
    var dropsWrites = false

    override func set(_ value: Any?, forKey defaultName: String) {
        if !self.dropsWrites {
            super.set(value, forKey: defaultName)
        }
    }

    override func removeObject(forKey defaultName: String) {
        if !self.dropsWrites {
            super.removeObject(forKey: defaultName)
        }
    }
}
