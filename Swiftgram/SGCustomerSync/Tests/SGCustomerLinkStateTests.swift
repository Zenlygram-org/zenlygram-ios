import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — a binding the server ended (design 40 §8.1, contract amendment A3): a drop after the
/// grant ends the link once, a grant after the drop is never ended, the handled marker, `account_erased`
/// → the local erase, `consent_stale` → the grant it carried normalised.
final class SGCustomerLinkStateTests: XCTestCase {
    private typealias LinkState = SGCustomerLinkState

    private let tg: Int64 = 555_000_111
    private let grantId = "3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a"
    private let binding = "01JBBINDINGAAAAAAAAAAAAAAA"
    /// 2026-11-01T09:00:00Z, the grant's `decided_at`.
    private let grantedAt = Date(timeIntervalSince1970: 1_793_523_600)

    func testADropAfterTheGrantEndsTheLinkExactlyOnce() {
        let granted = self.record(.granted, decidedAt: self.grantedAt)
        let drop = self.drop(at: self.grantedAt.addingTimeInterval(3_600.4))
        XCTAssertTrue(LinkState.linkEnded(record: granted, sessionEnd: drop, handled: nil))
        XCTAssertEqual(LinkState.decide(record: granted, sessionEnd: drop, handled: nil), .normalise(consentId: self.grantId))

        // Normalised: the record no longer reads as granted, so the drop is marked handled — only now.
        var normalised = granted
        normalised.state = .needsReconsent
        XCTAssertFalse(LinkState.linkEnded(record: normalised, sessionEnd: drop, handled: nil))
        XCTAssertEqual(LinkState.decide(record: normalised, sessionEnd: drop, handled: nil), .markHandled(LinkState.Handled(drop)))

        // Handled: never again, whatever the record says.
        let handled = LinkState.Handled(drop)
        for record in [granted, normalised] {
            XCTAssertFalse(LinkState.linkEnded(record: record, sessionEnd: drop, handled: handled))
            XCTAssertEqual(LinkState.decide(record: record, sessionEnd: drop, handled: handled), .none)
        }
        // A LATER drop (a new binding, ended again) is a new one.
        let laterDrop = self.drop(at: self.grantedAt.addingTimeInterval(7_200))
        XCTAssertTrue(LinkState.linkEnded(record: granted, sessionEnd: laterDrop, handled: handled))
    }

    func testAGrantAfterTheDropIsNeverEnded() {
        let drop = self.drop(at: self.grantedAt)
        let newGrant = self.record(.granted, decidedAt: self.grantedAt.addingTimeInterval(60))
        XCTAssertFalse(LinkState.linkEnded(record: newGrant, sessionEnd: drop, handled: nil), "the new grant is later than the drop: auto-link resumes with it")
        XCTAssertEqual(LinkState.decide(record: newGrant, sessionEnd: drop, handled: nil), .markHandled(LinkState.Handled(drop)))
    }

    func testTheSameSecondFailsClosedUntilTheDropIsHandled() {
        let drop = self.drop(at: self.grantedAt.addingTimeInterval(0.7))
        let grant = self.record(.granted, decidedAt: self.grantedAt)
        XCTAssertTrue(LinkState.linkEnded(record: grant, sessionEnd: drop, handled: nil), "≥ on whole seconds: a drop in the grant's second ends it")
        XCTAssertFalse(LinkState.linkEnded(record: grant, sessionEnd: drop, handled: LinkState.Handled(drop)), "once handled, a grant given in that second is not taken for the ended one")
        XCTAssertTrue(LinkState.linkEnded(record: self.record(.granted, decidedAt: nil), sessionEnd: drop, handled: nil), "a grant without a readable decision time is not shown to be newer")
    }

    func testNothingEndsWithoutADropOrAGrant() {
        let drop = self.drop(at: self.grantedAt.addingTimeInterval(60))
        XCTAssertFalse(LinkState.linkEnded(record: self.record(.granted, decidedAt: self.grantedAt), sessionEnd: nil, handled: nil))
        XCTAssertEqual(LinkState.decide(record: self.record(.granted, decidedAt: self.grantedAt), sessionEnd: nil, handled: nil), .none)
        for state in SGConsentState.allCases where state != .granted {
            XCTAssertFalse(LinkState.linkEnded(record: self.record(state, decidedAt: self.grantedAt), sessionEnd: drop, handled: nil), state.rawValue)
        }
        XCTAssertFalse(LinkState.linkEnded(record: nil, sessionEnd: drop, handled: nil))
        XCTAssertEqual(LinkState.decide(record: nil, sessionEnd: drop, handled: nil), .markHandled(LinkState.Handled(drop)), "no grant to end: marked, so a later grant in the same second stays usable")
    }

    func testAccountErasedIsTheLocalEraseWhateverTheRecord() {
        let erased = self.drop(at: self.grantedAt.addingTimeInterval(60), reason: "account_erased")
        XCTAssertTrue(erased.isAccountErased)
        XCTAssertFalse(self.drop(at: self.grantedAt).isAccountErased)
        for record in [self.record(.granted, decidedAt: self.grantedAt), self.record(.needsReconsent, decidedAt: self.grantedAt), self.record(.withdrawn, decidedAt: self.grantedAt), nil] {
            XCTAssertEqual(LinkState.decide(record: record, sessionEnd: erased, handled: nil), .accountErased)
            XCTAssertEqual(LinkState.decide(record: record, sessionEnd: erased, handled: LinkState.Handled(erased)), .accountErased, "an erasure is never just marked")
        }
    }

    func testTheHandledMarkerRoundTrips() throws {
        let drop = LinkState.SessionEnd(code: "device_revoked", reason: nil, at: Date(timeIntervalSince1970: 1_793_527_200.9), deviceId: self.binding)
        let handled = LinkState.Handled(drop)
        XCTAssertEqual(handled.at, "2026-11-01T10:00:00Z")
        XCTAssertEqual(handled.code, "device_revoked")
        XCTAssertEqual(handled.deviceId, self.binding)
        XCTAssertEqual(Set(handled.jsonObject.keys), ["at", "code", "device_id"])
        XCTAssertEqual(LinkState.Handled(jsonObject: handled.jsonObject), handled)
        let anonymous = LinkState.Handled(LinkState.SessionEnd(code: "invalid_token", reason: nil, at: self.grantedAt, deviceId: nil))
        XCTAssertEqual(Set(anonymous.jsonObject.keys), ["at", "code"], "a missing device id is left out")
        XCTAssertNil(LinkState.Handled(jsonObject: ["code": "invalid_token"]))
        XCTAssertNil(LinkState.Handled(jsonObject: ["code": "invalid_token", "at": "2026-11-01 10:00:00"]))
        XCTAssertNil(LinkState.Handled(jsonObject: nil))

        // Through the store, in the shape the store tests write.
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        let store = SGConsentStore(defaults: made.defaults, isReadable: { true }, notify: { _ in })
        try store.setJSONObject(["code": "invalid_token", "at": "2026-11-01T09:00:00Z"], for: .linkEnded(tg: self.tg, authority: "zenlygram.org")).get()
        let stored = try XCTUnwrap(LinkState.Handled(jsonObject: store.jsonObject(.linkEnded(tg: self.tg, authority: "zenlygram.org"))))
        XCTAssertTrue(stored.copies(self.drop(at: self.grantedAt.addingTimeInterval(0.5))))
        try store.setJSONObject(handled.jsonObject, for: .linkEnded(tg: self.tg, authority: "zenlygram.org")).get()
        XCTAssertEqual(LinkState.Handled(jsonObject: store.jsonObject(.linkEnded(tg: self.tg, authority: "zenlygram.org"))), handled)
    }

    func testTheClassifierCarriesTheErasureSignals() {
        let erased = SGCustomerWire.classify(SGCustomerRawAnswer(transport: .ok, status: 401, code: "invalid_token", reason: "account_erased"))
        XCTAssertEqual(LinkState.signal(erased), .accountErased)
        let erasedInBody = SGCustomerWire.classify(SGCustomerRawAnswer(transport: .ok, status: 401, body: Data("{\"error\":\"invalid_token\",\"reason\":\"account_erased\"}".utf8)))
        XCTAssertEqual(LinkState.signal(erasedInBody), .accountErased)
        let stale = SGCustomerWire.classify(SGCustomerRawAnswer(transport: .ok, status: 409, code: "consent_stale"))
        XCTAssertEqual(LinkState.signal(stale), .consentStale)
        for answer in [
            SGCustomerRawAnswer(transport: .ok, status: 401, code: "invalid_token"),
            SGCustomerRawAnswer(transport: .ok, status: 409, code: "bind_conflict"),
            SGCustomerRawAnswer(transport: .ok, status: 422, code: "consent_stale"),
            SGCustomerRawAnswer(transport: .timeout),
        ] {
            XCTAssertNil(LinkState.signal(SGCustomerWire.classify(answer)), "\(answer.status ?? 0) \(answer.code ?? "-")")
        }
    }

    func testConsentStaleNormalisesOnlyTheGrantItCarried() throws {
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        var ids = [self.grantId, "5e1d2c3b-4a59-4687-9a1b-2c3d4e5f6a7b"]
        let store = SGConsentStore(defaults: made.defaults, isReadable: { true }, makeConsentId: { ids.removeFirst() }, notify: { _ in })
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
        let first = try store.grant(tg: self.tg, text: text, mode: .required, appVersion: "12.0.1", now: self.grantedAt).get()

        // The automatic and the manual path both apply the same store operation.
        try store.normaliseAfterConsentStale(tg: self.tg, consentId: first.consentId).get()
        XCTAssertEqual(store.record(tg: self.tg)?.state, .needsReconsent)
        XCTAssertEqual(store.storedNotice(tg: self.tg), .linkEnded)
        let wall = SGConsentWallPolicy.decide(SGConsentWallInputs(mode: .required, readable: true, record: store.record(tg: self.tg), storedNotice: store.storedNotice(tg: self.tg), bundledCurrentVersion: 1, bundledMinValidVersion: 1, renderedSha256ForRecord: text.sha256, latestGrantRejection: nil, linkEnded: false, deletedNotice: false))
        XCTAssertEqual(wall.presentation, .wall(.linkEnded))

        // A new grant: the late answer naming the old grant changes nothing.
        let second = try store.grant(tg: self.tg, text: text, mode: .required, appVersion: "12.0.1", now: self.grantedAt.addingTimeInterval(600)).get()
        if case .success = store.normaliseAfterConsentStale(tg: self.tg, consentId: first.consentId) {
            XCTFail("the old grant's consent_stale must not touch the new grant")
        }
        XCTAssertEqual(store.record(tg: self.tg)?.state, .granted)
        XCTAssertEqual(store.record(tg: self.tg)?.consentId, second.consentId)
    }

    // MARK: - Helpers

    private func record(_ state: SGConsentState, decidedAt: Date?) -> SGConsentRecord {
        return SGConsentRecord(tgUserId: self.tg, state: state, consentId: self.grantId, textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, decidedAt: decidedAt.map(SGCustomerTime.instant))
    }

    private func drop(at date: Date, code: String = "invalid_token", reason: String? = nil) -> LinkState.SessionEnd {
        return LinkState.SessionEnd(code: code, reason: reason, at: date, deviceId: self.binding)
    }
}
