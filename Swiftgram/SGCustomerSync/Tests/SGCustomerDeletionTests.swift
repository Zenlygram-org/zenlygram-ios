import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the deletion state machine (design 40 §11.4, contract §2.2.5, Contract issue 18): every
/// row of the table, the four 401 codes only after an unknown outcome, the fence and its key, resume.
final class SGCustomerDeletionTests: XCTestCase {
    private typealias Deletion = SGCustomerDeletion

    private let key = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    private let binding = "01JBBINDINGAAAAAAAAAAAAAAA"
    /// 2026-11-01T09:00:00Z, when the fence was written.
    private let since = Date(timeIntervalSince1970: 1_793_523_600)

    /// The fence before the first send.
    private var first: Deletion.Record {
        return Deletion.Record.begin(key: self.key, now: self.since)!
    }

    /// The fence after a send whose outcome is not known.
    private var unknown: Deletion.Record {
        return self.first.outcomeUnknown
    }

    func testA200IsDeleted() {
        let ok = self.answer(200, body: "{\"schema_version\":1,\"state\":\"erased\",\"account_id\":\"01JBACCOUNTAAAAAAAAAAAAAAA\",\"erased_at\":\"2026-11-01T09:00:05Z\",\"retained\":[\"payment_records\"]}")
        XCTAssertEqual(ok.outcome, .ok(Data("{\"schema_version\":1,\"state\":\"erased\",\"account_id\":\"01JBACCOUNTAAAAAAAAAAAAAAA\",\"erased_at\":\"2026-11-01T09:00:05Z\",\"retained\":[\"payment_records\"]}".utf8)))
        XCTAssertEqual(Deletion.decide(self.first, outcome: ok, sessionEnd: nil), .deleted)
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: ok, sessionEnd: nil), .deleted)
    }

    func testAClockSkew401OnAFirstDeleteIsNotDeleted() {
        XCTAssertEqual(Deletion.decide(self.first, outcome: self.answer(401, "clock_skew"), sessionEnd: nil), .notDeleted(.failed), "nothing erased; the fence is lifted; the web link")
    }

    func testAnInvalidToken401AfterAnUnknownOutcomeIsDeleted() {
        // The first send timed out: the server may have erased the account (and its session).
        guard case let .retry(record, retry, notice) = Deletion.decide(self.first, outcome: SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .timeout)), sessionEnd: nil) else {
            return XCTFail("a timeout keeps the fence")
        }
        XCTAssertEqual(record, self.unknown)
        XCTAssertEqual(record.key, self.key, "the same key")
        XCTAssertEqual(retry, .backoff)
        XCTAssertEqual(notice, .offline)
        XCTAssertEqual(Deletion.decide(record, outcome: self.answer(401, "invalid_token"), sessionEnd: nil), .deleted)
    }

    func testOnlyTheFourDropCodesConfirmAnUnknownOutcome() {
        for code in ["invalid_token", "session_revoked", "device_revoked", "refresh_reuse"] {
            XCTAssertEqual(Deletion.decide(self.unknown, outcome: self.answer(401, code), sessionEnd: nil), .deleted, code)
            XCTAssertEqual(Deletion.decide(self.first, outcome: self.answer(401, code), sessionEnd: nil), .notDeleted(.failed), "\(code) on a first send")
        }
        for code in ["clock_skew", "unauthenticated", "nonce_replayed", "device_key_mismatch", "expired_token"] {
            XCTAssertEqual(Deletion.decide(self.unknown, outcome: self.answer(401, code), sessionEnd: nil), .notDeleted(.failed), code)
        }
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: self.answer(401), sessionEnd: nil), .notDeleted(.failed), "a bare 401")
        XCTAssertEqual(Deletion.dropCodes, ["invalid_token", "session_revoked", "device_revoked", "refresh_reuse"])
    }

    func testAnErasedAccountIsDeletedEvenOnAFirstSend() {
        XCTAssertEqual(Deletion.decide(self.first, outcome: self.answer(401, "invalid_token", reason: "account_erased"), sessionEnd: nil), .deleted, "amendment A3: the account is gone")
    }

    func testTimeoutsAndServerErrorsKeepTheFenceAndRetryWithTheSameKey() {
        let cases: [(SGCustomerDeleteOutcome, Deletion.Notice)] = [
            (SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .timeout)), .offline),
            (SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .offline)), .offline),
            (self.answer(500), .unavailable),
            (self.answer(503, "server_error", retryAfter: 30), .unavailable),
            (self.answer(502), .unavailable),
        ]
        for (outcome, notice) in cases {
            for record in [self.first, self.unknown] {
                XCTAssertEqual(Deletion.decide(record, outcome: outcome, sessionEnd: nil), .retry(self.unknown, .backoff, notice), "\(outcome.outcome)")
            }
        }
    }

    func testIdempotencyInFlightRetriesAfterOneSecond() {
        XCTAssertEqual(Deletion.decide(self.first, outcome: self.answer(409, "idempotency_in_flight"), sessionEnd: nil), .retry(self.unknown, .after(1), .inProgress))
        XCTAssertEqual(Deletion.decide(self.first, outcome: self.answer(409, "bind_conflict"), sessionEnd: nil), .notDeleted(.failed), "another 409 is final")
    }

    func testRateLimitedLiftsTheFenceOnlyWhenNothingWasSent() {
        let limited = self.answer(429, "rate_limited", retryAfter: 60)
        XCTAssertEqual(Deletion.decide(self.first, outcome: limited, sessionEnd: nil), .notDeleted(.rateLimited), "nothing happened")
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: limited, sessionEnd: nil), .retry(self.unknown, .backoff, .rateLimited))
    }

    func testAChangedCredentialRetriesAtOnceWithTheSameKey() {
        let changed = SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .credentialChanged))
        XCTAssertEqual(Deletion.decide(self.first, outcome: changed, sessionEnd: nil), .retry(self.first, .immediately, .inProgress))
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: changed, sessionEnd: nil), .retry(self.unknown, .immediately, .inProgress))
    }

    func testNoSessionIsDeletedOnlyWhenADropConfirmsAnUnknownOutcome() {
        let noSession = SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .notLinked))
        let after = self.drop("device_revoked", at: self.since.addingTimeInterval(40))
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: noSession, sessionEnd: after), .deleted)
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: noSession, sessionEnd: self.drop("device_revoked", at: self.since.addingTimeInterval(0.4))), .deleted, "the fence's own second counts")
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: noSession, sessionEnd: self.drop("device_revoked", at: self.since.addingTimeInterval(-1))), .notDeleted(.notLinked), "a drop older than the fence")
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: noSession, sessionEnd: self.drop("expired_token", at: self.since.addingTimeInterval(40))), .notDeleted(.notLinked), "not a drop code")
        XCTAssertEqual(Deletion.decide(self.unknown, outcome: noSession, sessionEnd: nil), .notDeleted(.notLinked), "an Unlink, not a drop")
        XCTAssertEqual(Deletion.decide(self.first, outcome: noSession, sessionEnd: after), .notDeleted(.notLinked), "never sent")
        XCTAssertEqual(Deletion.decide(self.first, outcome: noSession, sessionEnd: self.drop("invalid_token", at: self.since, reason: "account_erased")), .deleted, "an erasure always confirms")
    }

    func testAnyOtherAnswerLiftsTheFence() {
        for outcome in [self.answer(422, "invalid_request"), self.answer(413), self.answer(403, "consent_required"), self.answer(400), SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .notConfigured))] {
            XCTAssertEqual(Deletion.decide(self.unknown, outcome: outcome, sessionEnd: nil), .notDeleted(.failed), "\(outcome.outcome)")
        }
    }

    func testResumeSendsTheSameKeyAsAnUnknownOutcome() {
        // A fence found unresolved and not being sent: its earlier send may have reached the server.
        XCTAssertEqual(Deletion.resume(self.first, isLinked: true, sessionEnd: nil), .send(self.unknown))
        XCTAssertEqual(Deletion.resume(self.unknown, isLinked: true, sessionEnd: nil), .send(self.unknown))
        XCTAssertEqual(Deletion.resume(self.unknown, isLinked: false, sessionEnd: self.drop("session_revoked", at: self.since.addingTimeInterval(5))), .deleted)
        XCTAssertEqual(Deletion.resume(self.first, isLinked: false, sessionEnd: self.drop("session_revoked", at: self.since.addingTimeInterval(5))), .deleted, "resumed as unknown")
        XCTAssertEqual(Deletion.resume(self.unknown, isLinked: false, sessionEnd: nil), .notDeleted(.notLinked))
    }

    func testTheFenceRoundTripsAndKeepsItsKey() throws {
        XCTAssertEqual(self.first.sentUnknown, false)
        XCTAssertEqual(self.first.since, "2026-11-01T09:00:00Z")
        XCTAssertNil(Deletion.Record.begin(key: "not-a-uuid", now: self.since))
        XCTAssertNil(Deletion.Record.begin(key: self.key.uppercased(), now: self.since))
        XCTAssertEqual(Set(self.first.jsonObject.keys), ["key", "sent_unknown", "since"])
        XCTAssertEqual(Deletion.Record(jsonObject: self.first.jsonObject), self.first)
        XCTAssertEqual(Deletion.Record(jsonObject: self.unknown.jsonObject), self.unknown)
        XCTAssertEqual(Deletion.Record(jsonObject: ["key": self.key, "since": "2026-11-01T09:00:00Z"])?.sentUnknown, true, "nothing says it was not sent")
        XCTAssertNil(Deletion.Record(jsonObject: ["key": "x", "sent_unknown": false, "since": "2026-11-01T09:00:00Z"]))
        XCTAssertNil(Deletion.Record(jsonObject: ["key": self.key, "sent_unknown": false]))
        XCTAssertNil(Deletion.Record(jsonObject: nil))

        // The store keeps the fence (the account is erasing) until it is removed.
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        let store = SGConsentStore(defaults: made.defaults, isReadable: { true }, notify: { _ in })
        try store.setJSONObject(self.unknown.jsonObject, for: .deletion(tg: 555_000_111, authority: "zenlygram.org")).get()
        XCTAssertTrue(store.isErasing(tg: 555_000_111, authority: "zenlygram.org"))
        XCTAssertEqual(Deletion.Record(jsonObject: store.jsonObject(.deletion(tg: 555_000_111, authority: "zenlygram.org"))), self.unknown)
        try store.setJSONObject(nil, for: .deletion(tg: 555_000_111, authority: "zenlygram.org")).get()
        XCTAssertFalse(store.isErasing(tg: 555_000_111, authority: "zenlygram.org"))
    }

    func testTheRequestCarriesTheKey() throws {
        let request = SGCustomerRequest.delete(idempotencyKey: self.first.key)
        XCTAssertEqual(request.route, .delete)
        XCTAssertEqual(request.idempotencyKey, self.key)
        SGCustomerSyncTestFixtures.assertJSON(try XCTUnwrap(request.body), equals: ["schema_version": 1, "confirm": "delete_account"])
    }

    // MARK: - Helpers

    private func answer(_ status: Int, _ code: String? = nil, reason: String? = nil, retryAfter: TimeInterval? = nil, body: String? = nil) -> SGCustomerDeleteOutcome {
        var text = body
        if text == nil, let code {
            text = "{\"error\":\"\(code)\",\"message\":\"…\"}"
        }
        return SGCustomerDeleteOutcome(SGCustomerRawAnswer(transport: .ok, status: status, code: code, reason: reason, body: Data((text ?? "").utf8), retryAfter: retryAfter))
    }

    private func drop(_ code: String, at date: Date, reason: String? = nil) -> SGCustomerLinkState.SessionEnd {
        return SGCustomerLinkState.SessionEnd(code: code, reason: reason, at: date, deviceId: self.binding)
    }
}
