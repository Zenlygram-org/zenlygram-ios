// App-side only (see SGCustomerSyncConfigTests.swift): compiles to nothing in `run-core-tests.sh`.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
import SGEntitlement
@testable import SGCustomerSync
@testable import SGCustomerSyncCore

/// Zenlygram — the rules `SGCustomerSync` installs and applies (design 40 §0, §7.1.4, §11.4, §5.6):
/// the `bindPermissionProvider` decision over a real consent store, the My data mapping of a
/// `/profile/me` outcome, and the session end as the core reads it.
final class SGCustomerSyncRulesTests: XCTestCase {
    /// A user id whose packed peer id is the id itself (namespace 0).
    private let tg: Int64 = 555_000_111
    private let authority = "zenlygram.org"
    private let otherAuthority = "127.0.0.1:8443"
    /// 2026-11-01T09:00:00Z.
    private let decided = Date(timeIntervalSince1970: 1_793_523_600)

    private var suite = ""
    private var readable = true
    private var store: SGConsentStore!

    override func setUp() {
        super.setUp()
        self.suite = "org.zenlygram.SGCustomerSyncRulesTests.\(UUID().uuidString)"
        self.readable = true
        self.store = SGConsentStore(defaults: UserDefaults(suiteName: self.suite)!, isReadable: { [unowned self] in self.readable }, now: { [unowned self] in self.decided })
    }

    override func tearDown() {
        UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
        self.store = nil
        super.tearDown()
    }

    private var accountPeerId: Int64 {
        return self.tg
    }

    /// The bundled v1 uz text with clearly fake operator values.
    private func text() throws -> SGConsentRenderedText {
        let root = try XCTUnwrap(SGCustomerSyncConfig.bundledConsentRootURL())
        let repository = try SGConsentTextRepository.load(rootURL: root).get()
        let values = SGConsentOperatorValues.fromConfig(name: "Test Operator LLC", stir: "123456789", responsiblePerson: "Test Person", contactEmail: "privacy@example.test")
        return try XCTUnwrap(repository.render(version: 1, locale: .uz, operatorValues: values))
    }

    @discardableResult
    private func grant() throws -> SGConsentEvent {
        return try self.store.grant(tg: self.tg, text: try self.text(), mode: .required, appVersion: "12.0.1", now: self.decided).get()
    }

    private func permission(_ mode: SGConsentMode, sessionEnd: SGEntitlementSessionEnd? = nil, accountPeerId: Int64? = nil) -> SGEntitlementBindPermission {
        return SGCustomerSync.bindPermission(accountPeerId: accountPeerId ?? self.accountPeerId, mode: mode, store: self.store, authority: self.authority, sessionEnd: sessionEnd)
    }

    // MARK: - bindPermission

    func test_withoutAGrantRequiredRefusesAndOptionalIsCodeOnly() throws {
        XCTAssertEqual(self.permission(.required), .refused, "no record")
        XCTAssertEqual(self.permission(.optional), .codeOnly)

        try self.store.decline(tg: self.tg, mode: .optional).get()
        XCTAssertEqual(self.store.record(tg: self.tg)?.state, .declined)
        XCTAssertEqual(self.permission(.required), .refused, "a declined account")
        XCTAssertEqual(self.permission(.optional), .codeOnly)
    }

    func test_aUsableGrantAllowsTheLinkInBothModes() throws {
        try self.grant()
        XCTAssertEqual(self.permission(.required), .allowed)
        XCTAssertEqual(self.permission(.optional), .allowed)
    }

    func test_anUnreadableStoreOrAnAccountThatIsNoUserHasNoGrant() throws {
        try self.grant()
        self.readable = false
        XCTAssertEqual(self.permission(.required), .refused, "defence in depth behind the wall")
        XCTAssertEqual(self.permission(.optional), .codeOnly)
        self.readable = true
        for packed in [Int64(0), -1, Int64(1) << 32] {
            XCTAssertEqual(self.permission(.required, accountPeerId: packed), .refused, "\(packed)")
            XCTAssertEqual(self.permission(.optional, accountPeerId: packed), .codeOnly, "\(packed)")
        }
    }

    func test_anErasingAccountIsRefusedInBothModes() throws {
        try self.grant()
        try self.store.setJSONObject(["key": "k-1", "sent_unknown": false, "since": SGCustomerTime.instant(self.decided)], for: .deletion(tg: self.tg, authority: self.authority)).get()
        XCTAssertEqual(self.permission(.required), .refused)
        XCTAssertEqual(self.permission(.optional), .refused, "an erasing account never links, not even by code")

        try self.store.setJSONObject(nil, for: .deletion(tg: self.tg, authority: self.authority)).get()
        try self.store.setJSONObject(["key": "k-1", "sent_unknown": false, "since": SGCustomerTime.instant(self.decided)], for: .deletion(tg: self.tg, authority: self.otherAuthority)).get()
        XCTAssertEqual(self.permission(.required), .allowed, "an erasure at another authority fences only that one")
    }

    func test_aGrantRejectedAtThisAuthorityIsNotUsable() throws {
        let event = try self.grant()
        try self.store.markRejected(tg: self.tg, authority: self.otherAuthority, id: event.consentId, code: "invalid_consent").get()
        XCTAssertEqual(self.permission(.required), .allowed, "rejected elsewhere only")
        try self.store.markRejected(tg: self.tg, authority: self.authority, id: event.consentId, code: "invalid_consent").get()
        XCTAssertEqual(self.permission(.required), .refused)
        XCTAssertEqual(self.permission(.optional), .codeOnly)
    }

    func test_aServerEndedLinkMakesTheGrantUnusableUntilHandled() throws {
        try self.grant()
        let after = SGEntitlementSessionEnd(code: "invalid_token", reason: nil, at: self.decided.addingTimeInterval(60), deviceId: "01JB8R")
        XCTAssertEqual(self.permission(.required, sessionEnd: after), .refused, "the drop ended the binding this grant linked")
        XCTAssertEqual(self.permission(.optional, sessionEnd: after), .codeOnly)

        let sameSecond = SGEntitlementSessionEnd(code: "invalid_token", reason: nil, at: self.decided.addingTimeInterval(0.4), deviceId: nil)
        XCTAssertEqual(self.permission(.required, sessionEnd: sameSecond), .refused, "a drop in the grant's own second still ends it (whole seconds)")

        let before = SGEntitlementSessionEnd(code: "invalid_token", reason: nil, at: self.decided.addingTimeInterval(-60), deviceId: "01JB8R")
        XCTAssertEqual(self.permission(.required, sessionEnd: before), .allowed, "a drop older than the grant ends nothing")

        let handled = SGCustomerLinkState.Handled(SGCustomerSync.sessionEnd(after))
        try self.store.setJSONObject(handled.jsonObject, for: .linkEnded(tg: self.tg, authority: self.authority)).get()
        XCTAssertEqual(self.permission(.required, sessionEnd: after), .allowed, "a drop already handled no longer blocks")
    }

    func test_theSessionEndIsCopiedFieldForField() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let end = SGCustomerSync.sessionEnd(SGEntitlementSessionEnd(code: "invalid_token", reason: "account_erased", at: at, deviceId: "01JB8R"))
        XCTAssertEqual(end.code, "invalid_token")
        XCTAssertEqual(end.reason, "account_erased")
        XCTAssertEqual(end.at, at)
        XCTAssertEqual(end.deviceId, "01JB8R")
        XCTAssertTrue(end.isAccountErased)
        XCTAssertNil(SGCustomerSync.sessionEnd(SGEntitlementSessionEnd(code: "c", reason: nil, at: at, deviceId: nil)).deviceId)
    }

    // MARK: - My data

    private let me = Data(#"{"schema_version":1,"account":{"id":"01JB8Q","tg_user_id":555000111,"created_at":"2026-10-29T10:00:00Z"},"consent":{"state":"granted","consent_id":"c-1","text_version":1}}"#.utf8)
    private let offline = SGCustomerRawAnswer(transport: .offline)
    private let answered = SGCustomerRawAnswer(transport: .ok, status: 503, code: "profile_unavailable")

    func test_aReadableProfileMeIsLoaded() throws {
        let decoded = try XCTUnwrap(SGProfileMe.decode(self.me))
        XCTAssertEqual(SGCustomerSync.myData(.ok(self.me), answer: SGCustomerRawAnswer(transport: .ok, status: 200, body: self.me), isLinked: true), .loaded(decoded))
        XCTAssertEqual(decoded.account?.tgUserId, 555_000_111)
        XCTAssertEqual(decoded.consent?.state, "granted")
    }

    func test_anUnreadableBodyFails() {
        for body in [Data(), Data("{".utf8), Data(#"{"schema_version":2}"#.utf8), Data("[]".utf8)] {
            XCTAssertEqual(SGCustomerSync.myData(.ok(body), answer: SGCustomerRawAnswer(transport: .ok, status: 200, body: body), isLinked: true), .failed, String(decoding: body, as: UTF8.self))
        }
    }

    func test_everyOtherOutcomeMapsToItsScreen() {
        let rows: [(SGCustomerCallOutcome, SGCustomerRawAnswer, Bool, SGCustomerSync.MyData)] = [
            (.notLinkedLocally, SGCustomerRawAnswer(transport: .notLinked), true, .notLinked),
            (.timedOut, SGCustomerRawAnswer(transport: .timeout), true, .offline),
            (.unavailable(retryAfter: nil), self.offline, true, .offline),
            (.unavailable(retryAfter: 120), self.answered, true, .unavailable),
            (.unavailable(retryAfter: nil), SGCustomerRawAnswer(transport: .ok, status: 404), true, .unavailable),
            (.rateLimited(retryAfter: 7), SGCustomerRawAnswer(transport: .ok, status: 429), true, .rateLimited),
            (.credentialChanged, SGCustomerRawAnswer(transport: .credentialChanged), true, .unavailable),
            (.session(code: "invalid_token", reason: nil), SGCustomerRawAnswer(transport: .ok, status: 401), false, .notLinked),
            (.session(code: "invalid_token", reason: nil), SGCustomerRawAnswer(transport: .ok, status: 401), true, .failed),
            (.consentRequired(SGConsentRequiredExtras(reason: .withdrawn, consent: nil)), SGCustomerRawAnswer(transport: .ok, status: 403), true, .failed),
            (.accountNotLinked, SGCustomerRawAnswer(transport: .ok, status: 403), true, .failed),
            (.accountMismatch, SGCustomerRawAnswer(transport: .ok, status: 409), true, .failed),
            (.payloadTooLarge, SGCustomerRawAnswer(transport: .ok, status: 413), true, .failed),
            (.terminal(status: 422, code: "invalid_request"), SGCustomerRawAnswer(transport: .ok, status: 422), true, .failed),
            (.notConfigured, SGCustomerRawAnswer(transport: .notConfigured), true, .failed),
        ]
        for (outcome, answer, isLinked, expected) in rows {
            XCTAssertEqual(SGCustomerSync.myData(outcome, answer: answer, isLinked: isLinked), expected, "\(outcome) linked=\(isLinked)")
        }
    }
}
#endif
