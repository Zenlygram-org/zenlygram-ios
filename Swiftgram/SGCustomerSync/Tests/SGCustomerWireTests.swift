import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the wire (design 40 §6.5, contract §2.1, §2.4): the shared `consents-valid.json`
/// bodies equal what the store and the request builder make (parsed JSON); every classification row,
/// including the `consent_required` extras, the 401 `account_erased` reason, 409 `consent_stale`,
/// timeouts and `Retry-After`; unknown keys accepted; another `schema_version` → unavailable; the
/// response DTOs and the transport protocol.
final class SGCustomerWireTests: XCTestCase {
    private let tg: Int64 = 555_000_111

    // MARK: - consents-valid.json

    func testTheSharedConsentsBodiesEqualTheBuilderOutput() throws {
        let fixture = try SGCustomerSyncTestFixtures.jsonObject("consents-valid.json")
        XCTAssertEqual(SGCustomerJSON.integer(fixture["tg_user_id"]), Int(self.tg))
        let cases = try SGCustomerSyncTestFixtures.cases("consents-valid.json")
        XCTAssertEqual(cases.map { $0["id"] as? String }, ["grant", "withdraw", "grant-then-withdraw"])
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let body = try XCTUnwrap(item["body"] as? [String: Any], id)
            let events = try XCTUnwrap(body["consents"] as? [[String: Any]], id).map { raw -> Data in
                let event = SGConsentEvent(
                    consentId: raw["consent_id"] as? String ?? "", tgUserId: Int64(SGCustomerJSON.integer(raw["tg_user_id"]) ?? 0),
                    action: SGConsentAction(rawValue: raw["action"] as? String ?? "") ?? .grant, scopes: raw["scopes"] as? [String] ?? [],
                    textVersion: SGCustomerJSON.integer(raw["text_version"]), textSha256: raw["text_sha256"] as? String,
                    locale: SGConsentLocale(rawValue: raw["locale"] as? String ?? "") ?? .uz, consentMode: SGConsentMode(rawValue: raw["consent_mode"] as? String ?? "") ?? .required,
                    ageConfirmed: SGCustomerJSON.bool(raw["age_confirmed"]), recordedAt: raw["recorded_at"] as? String ?? "",
                    platform: raw["platform"] as? String ?? "", appVersion: raw["app_version"] as? String ?? ""
                )
                XCTAssertTrue(event.isValid, id)
                return event.encoded()
            }
            SGCustomerSyncTestFixtures.assertJSON(try XCTUnwrap(SGConsentsRequest.body(events: events), id), equals: body, id)
            XCTAssertEqual(SGCustomerRequest.consents(try XCTUnwrap(SGConsentsRequest.body(events: events))).route, .consents)
        }
    }

    func testTheStoresGrantGoesOutAsTheSharedGrantBody() throws {
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        let store = SGConsentStore(defaults: made.defaults, isReadable: { true }, makeConsentId: { "3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a" }, notify: { _ in })
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
        _ = try store.grant(tg: self.tg, text: text, mode: .required, appVersion: "12.0.1", now: Date(timeIntervalSince1970: 1_793_523_600)).get()
        let pending = store.pendingUploads(tg: self.tg, authority: "zenlygram.org")
        XCTAssertEqual(pending.count, 1)
        let grant = try XCTUnwrap(try SGCustomerSyncTestFixtures.cases("consents-valid.json").first { $0["id"] as? String == "grant" })
        SGCustomerSyncTestFixtures.assertJSON(try XCTUnwrap(SGConsentsRequest.body(events: pending)), equals: grant["body"])
    }

    // MARK: - Classification

    func testEveryRowOfTheClassification() {
        let consentBlock = "\"consent\":{\"state\":\"withdrawn\",\"consent_id\":\"9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d7\",\"text_version\":1,\"effective_at\":\"2026-11-01T09:30:00Z\"}"
        let rows: [(String, SGCustomerRawAnswer, SGCustomerCallOutcome)] = [
            ("200", self.answer(200, body: "{\"schema_version\":1,\"ingest\":\"stored\",\"min_interval_s\":21600,\"server_time\":\"2026-11-01T10:00:00Z\"}"), .ok(Data("{\"schema_version\":1,\"ingest\":\"stored\",\"min_interval_s\":21600,\"server_time\":\"2026-11-01T10:00:00Z\"}".utf8))),
            ("200 another schema", self.answer(200, body: "{\"schema_version\":2}"), .unavailable(retryAfter: nil)),
            ("200 no schema", self.answer(200, body: "{\"ingest\":\"stored\"}"), .unavailable(retryAfter: nil)),
            ("200 not JSON", self.answer(200, body: "<html>"), .unavailable(retryAfter: nil)),
            ("204 empty", self.answer(204, body: ""), .unavailable(retryAfter: nil)),
            ("403 consent_required", self.answer(403, code: "consent_required", reason: "withdrawn", body: "{\"error\":\"consent_required\",\"message\":\"…\",\"reason\":\"withdrawn\",\(consentBlock)}"),
             .consentRequired(SGConsentRequiredExtras(reason: .withdrawn, consent: SGEffectiveConsent(state: .withdrawn, consentId: "9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d7", textVersion: 1, effectiveAt: "2026-11-01T09:30:00Z")))),
            ("403 consent_required, extras only in the answer", self.answer(403, code: "consent_required", reason: "reconsent_required", body: ""), .consentRequired(SGConsentRequiredExtras(reason: .reconsentRequired, consent: nil))),
            ("403 consent_required, unknown reason", self.answer(403, code: "consent_required", reason: "later", body: "{\"error\":\"consent_required\",\"reason\":\"later\"}"), .consentRequired(SGConsentRequiredExtras(reason: .unknown, consent: nil))),
            ("403 not linked", self.answer(403, code: "profile_account_not_linked"), .accountNotLinked),
            ("403 other", self.answer(403, code: "forbidden"), .terminal(status: 403, code: "forbidden")),
            ("409 mismatch", self.answer(409, code: "profile_account_mismatch", body: "{\"error\":\"profile_account_mismatch\",\"field\":\"telegram.user_id\"}"), .accountMismatch),
            ("409 idempotency_in_flight", self.answer(409, code: "idempotency_in_flight"), .terminal(status: 409, code: "idempotency_in_flight")),
            ("409 consent_stale", self.answer(409, code: "consent_stale"), .terminal(status: 409, code: "consent_stale")),
            ("413", self.answer(413, code: "payload_too_large"), .payloadTooLarge),
            ("422 consent_text_mismatch", self.answer(422, code: "consent_text_mismatch", body: "{\"error\":\"consent_text_mismatch\",\"field\":\"consents[0].text_sha256\"}"), .terminal(status: 422, code: "consent_text_mismatch")),
            ("422 unsupported_schema_version", self.answer(422, code: "unsupported_schema_version", body: "{\"error\":\"unsupported_schema_version\",\"supported\":[1]}"), .terminal(status: 422, code: "unsupported_schema_version")),
            ("400", self.answer(400), .terminal(status: 400, code: nil)),
            ("429 Retry-After", self.answer(429, code: "rate_limited", retryAfter: 30, body: "{\"error\":\"rate_limited\",\"retry_after\":45}"), .rateLimited(retryAfter: 30)),
            ("429 retry_after", self.answer(429, code: "rate_limited", body: "{\"error\":\"rate_limited\",\"retry_after\":45}"), .rateLimited(retryAfter: 45)),
            ("429 capped", self.answer(429, retryAfter: 9_999_999), .rateLimited(retryAfter: 86_400)),
            ("401 invalid_token", self.answer(401, code: "invalid_token"), .session(code: "invalid_token", reason: nil)),
            ("401 account_erased", self.answer(401, code: "invalid_token", reason: "account_erased"), .session(code: "invalid_token", reason: "account_erased")),
            ("401 reason in the body only", self.answer(401, body: "{\"error\":\"session_revoked\",\"reason\":\"account_erased\"}"), .session(code: "session_revoked", reason: "account_erased")),
            ("404 older server", self.answer(404), .unavailable(retryAfter: nil)),
            ("503 profile_unavailable", self.answer(503, code: "profile_unavailable", retryAfter: 120), .unavailable(retryAfter: 120)),
            ("500", self.answer(500, code: "server_error"), .unavailable(retryAfter: nil)),
            ("302", self.answer(302), .unavailable(retryAfter: nil)),
            ("no status", SGCustomerRawAnswer(transport: .ok), .unavailable(retryAfter: nil)),
            ("timeout", SGCustomerRawAnswer(transport: .timeout), .timedOut),
            ("offline", SGCustomerRawAnswer(transport: .offline), .unavailable(retryAfter: nil)),
            ("no session", SGCustomerRawAnswer(transport: .notLinked), .notLinkedLocally),
            ("token changed", SGCustomerRawAnswer(transport: .credentialChanged), .credentialChanged),
            ("extension / no backend", SGCustomerRawAnswer(transport: .notConfigured), .notConfigured),
        ]
        for (name, answer, expected) in rows {
            XCTAssertEqual(SGCustomerWire.classify(answer), expected, name)
        }
        XCTAssertTrue(SGCustomerWire.classify(self.answer(401, code: "invalid_token", reason: "account_erased")).isAccountErased)
        XCTAssertFalse(SGCustomerWire.classify(self.answer(401, code: "invalid_token")).isAccountErased)
        XCTAssertTrue(SGCustomerWire.classify(self.answer(409, code: "consent_stale")).isConsentStale)
        XCTAssertFalse(SGCustomerWire.classify(self.answer(409, code: "idempotency_in_flight")).isConsentStale)
        XCTAssertFalse(SGCustomerWire.classify(self.answer(422, code: "consent_stale")).isConsentStale)
    }

    func testTheErrorFieldOfATerminalAnswerReachesTheReconciler() throws {
        let grant = SGConsentEvent(consentId: SGCustomerTime.uuid4(), tgUserId: self.tg, action: .grant, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: String(repeating: "0", count: 64), locale: .uz, consentMode: .required, ageConfirmed: true, recordedAt: "2026-11-01T09:00:00Z", appVersion: "12.0.1")
        let withdraw = SGConsentEvent(consentId: SGCustomerTime.uuid4(), tgUserId: self.tg, action: .withdraw, scopes: SGConsentScope.allCases.map(\.rawValue), textVersion: 1, textSha256: nil, locale: .uz, consentMode: .required, ageConfirmed: nil, recordedAt: "2026-11-01T09:05:00Z", appVersion: "12.0.1")
        let answer = self.answer(422, code: "consent_text_mismatch", body: "{\"error\":\"consent_text_mismatch\",\"message\":\"x\",\"field\":\"consents[0].text_sha256\"}")
        guard case let .terminal(status, code) = SGCustomerWire.classify(answer) else {
            return XCTFail("terminal")
        }
        let field = SGCustomerWire.errorField(answer)
        XCTAssertEqual(field, "consents[0].text_sha256")
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: status, code: code, field: field, sent: [grant, withdraw]), .markRejected(consentId: grant.consentId, code: "consent_text_mismatch"))
        XCTAssertNil(SGCustomerWire.errorField(self.answer(422, body: "not json")))
    }

    func testUnknownKeysAreAcceptedEverywhere() throws {
        let events = try XCTUnwrap(SGEventsResponse.decode(Data("{\"schema_version\":1,\"accepted\":197,\"duplicates\":1,\"dropped_props\":2,\"rejected\":[{\"id\":\"d3104862-d80e-408e-9670-3381ed55b6a6\",\"reason\":\"invalid_envelope\",\"note\":1},{\"id\":null,\"reason\":\"invalid_envelope\"},7],\"ingest\":\"stored\",\"flush_interval_s\":300,\"server_time\":\"2026-11-01T10:00:00Z\",\"next\":{}}".utf8)))
        XCTAssertEqual(events, SGEventsResponse(accepted: 197, duplicates: 1, droppedProps: 2, rejected: [SGEventsResponse.Rejection(id: "d3104862-d80e-408e-9670-3381ed55b6a6", reason: "invalid_envelope"), SGEventsResponse.Rejection(id: nil, reason: "invalid_envelope")], ingest: .stored, flushIntervalS: 300))
        XCTAssertNil(SGEventsResponse.decode(Data("{\"schema_version\":2,\"accepted\":1}".utf8)))
        XCTAssertEqual(SGProfileSyncResponse.decode(Data("{\"schema_version\":1,\"ingest\":\"paused\",\"min_interval_s\":21600,\"x\":true}".utf8)), SGProfileSyncResponse(ingest: .paused, minIntervalS: 21_600))
        XCTAssertEqual(SGProfileSyncResponse.decode(Data("{\"schema_version\":1,\"ingest\":\"later\"}".utf8)), SGProfileSyncResponse(ingest: nil, minIntervalS: nil))
        XCTAssertNil(SGProfileSyncResponse.decode(Data("{\"ingest\":\"stored\"}".utf8)))
        XCTAssertEqual(SGAccountDeleteResponse.decode(Data("{\"schema_version\":1,\"state\":\"erased\",\"account_id\":\"01JBACCOUNTAAAAAAAAAAAAAAA\",\"erased_at\":\"2026-10-29T10:05:00Z\",\"retained\":[\"payment_records\"],\"server_time\":\"2026-10-29T10:05:00Z\"}".utf8)), SGAccountDeleteResponse(state: "erased", accountId: "01JBACCOUNTAAAAAAAAAAAAAAA", erasedAt: "2026-10-29T10:05:00Z", retained: ["payment_records"]))
        XCTAssertEqual(SGCustomerWire.classify(self.answer(200, body: "{\"schema_version\":1,\"brand_new\":{\"nested\":[1,2]}}")), .ok(Data("{\"schema_version\":1,\"brand_new\":{\"nested\":[1,2]}}".utf8)))
    }

    func testTheRightToKnowAnswer() throws {
        let body = """
        {"schema_version":1,"server_time":"2026-11-01T10:00:00Z","future_section":{"a":1},
         "account":{"id":"01JBACCOUNTAAAAAAAAAAAAAAA","tg_user_id":555000111,"created_at":"2026-10-01T08:00:00Z"},
         "consent":{"state":"granted","consent_id":"3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a","text_version":1,"locale":"uz","consent_mode":"required","effective_at":"2026-11-01T09:00:00Z"},
         "consent_history":[{"consent_id":"3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a","action":"grant","scopes":["link","profile","statistics","tasks_sync"],"text_version":1,"locale":"uz","consent_mode":"required","source":"bind","platform":"ios","app_version":"12.0.1","recorded_at":"2026-11-01T09:00:00Z","received_at":"2026-11-01T09:00:02Z","outcome":"recorded"}],
         "profile":{"phone":{"value":"+998901234567","source":"telegram_session","observed_at":"2026-11-01T10:00:00Z"},"country":"UZ",
                    "usernames":{"value":["primary_name"],"source":"telegram_attest","observed_at":"2026-11-01T09:00:00Z"},
                    "first_name":{"value":"Ali","source":"client","observed_at":"2026-11-01T10:00:00Z"},"last_name":null,
                    "language_code":{"value":"uz","source":"telegram_attest","observed_at":"2026-11-01T09:00:00Z"},
                    "is_premium":{"value":false,"source":"client","observed_at":"2026-11-01T10:00:00Z"}},
         "devices":[{"device_id":"01JBDEVICEAAAAAAAAAAAAAAAA","platform":"ios","device_class":"phone","device_model":"iPhone17,1","os_version":"18.1","app_version":"12.0.1","app_build":"1234","ui_language":"uz","locale":"uz-UZ","timezone":"Asia/Tashkent","distribution":"appstore","first_seen_at":"2026-11-01T09:00:00Z","last_seen_at":"2026-11-01T10:00:00Z","revoked_at":null}],
         "activity":{"first_active_at":"2026-11-01T09:00:00Z","last_active_at":"2026-11-01T10:00:00Z","active_days":12,"sessions_30d":40,"session_seconds_30d":9000},
         "events":{"retention_days":180,"total":1234,"by_name":[{"name":"app.session_start","count":40}],"recent":[{"name":"screen.view","ts":"2026-11-01T09:58:00Z"}]},
         "subscription":null,
         "retention":{"profile":"until_withdrawal_or_deletion","events_days":180,"activity_months":25,"consent_log_years_after_erasure":3}}
        """
        let me = try XCTUnwrap(SGProfileMe.decode(Data(body.utf8)))
        XCTAssertEqual(me.account?.tgUserId, 555_000_111)
        XCTAssertEqual(me.consent?.state, "granted")
        XCTAssertEqual(me.consentHistory.first?.scopes, ["link", "profile", "statistics", "tasks_sync"])
        XCTAssertEqual(me.consentHistory.first?.outcome, "recorded")
        XCTAssertEqual(me.profile?.phone?.value, "+998901234567")
        XCTAssertEqual(me.profile?.phone?.source, "telegram_session")
        XCTAssertEqual(me.profile?.usernames?.value, ["primary_name"])
        XCTAssertNil(me.profile?.lastName)
        XCTAssertEqual(me.profile?.isPremium?.value, false)
        XCTAssertEqual(me.profile?.country, "UZ")
        XCTAssertEqual(me.devices.first?.deviceModel, "iPhone17,1")
        XCTAssertNil(me.devices.first?.revokedAt)
        XCTAssertEqual(me.activity?.activeDays, 12)
        XCTAssertEqual(me.events?.byName, [SGProfileMe.EventCount(name: "app.session_start", count: 40)])
        XCTAssertEqual(me.events?.recent, [SGProfileMe.RecentEvent(name: "screen.view", ts: "2026-11-01T09:58:00Z")])
        XCTAssertNil(me.subscription, "core failed: the section is null, the rest is there")
        XCTAssertEqual(me.retention?.eventsDays, 180)
        let unconsented = try XCTUnwrap(SGProfileMe.decode(Data("{\"schema_version\":1,\"consent\":{\"state\":\"none\",\"consent_id\":null},\"consent_history\":[],\"devices\":[]}".utf8)))
        XCTAssertEqual(unconsented.consent?.state, "none")
        XCTAssertNil(unconsented.profile)
        XCTAssertEqual(unconsented.devices, [])
        XCTAssertNil(SGProfileMe.decode(Data("{\"schema_version\":3}".utf8)))
    }

    func testTheDeleteRequestAndTheHints() throws {
        SGCustomerSyncTestFixtures.assertJSON(SGAccountDeleteRequest.body, equals: ["schema_version": 1, "confirm": "delete_account"])
        let delete = SGCustomerRequest.delete(idempotencyKey: "7c1e8a2b-3d4f-4a6b-8c9d-0e1f2a3b4c5d")
        XCTAssertEqual(delete.route, .delete)
        XCTAssertEqual(delete.body, SGAccountDeleteRequest.body)
        XCTAssertEqual(delete.idempotencyKey, "7c1e8a2b-3d4f-4a6b-8c9d-0e1f2a3b4c5d")
        XCTAssertNil(SGCustomerRequest.me.body)
        XCTAssertNil(SGCustomerRequest.sync(Data("{}".utf8)).idempotencyKey, "only delete carries an Idempotency-Key")

        let hints = SGCustomerHints(flushIntervalS: 120, eventsPausedUntil: Date(timeIntervalSince1970: 1_793_613_600), minIntervalS: 21_600)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(hints.jsonObject))
        XCTAssertEqual(SGCustomerHints(jsonObject: hints.jsonObject), hints)
        XCTAssertEqual(SGCustomerHints(jsonObject: ["flush_interval_s": "300", "events_paused_until": true, "min_interval_s": -1]), SGCustomerHints())
        XCTAssertEqual(SGCustomerHints(jsonObject: nil), SGCustomerHints())
    }

    // MARK: - Transport

    func testTheTransportProtocolRoutesEveryRequestAndClassifiesOnce() async {
        let transport = SGCustomerWireTestTransport()
        let requests: [SGCustomerRequest] = [.consents(Data("c".utf8)), .sync(Data("s".utf8)), .me, .events(Data("e".utf8)), .delete(idempotencyKey: "key-1")]
        var outcomes: [SGCustomerCallOutcome] = []
        for request in requests {
            outcomes.append(await transport.call(request, accountPeerId: 7).outcome)
        }
        XCTAssertEqual(transport.calls, ["consents c 7", "sync s 7", "me 7", "events e 7", "delete key-1 {\"confirm\":\"delete_account\",\"schema_version\":1} 7"])
        XCTAssertEqual(outcomes, [.ok(Data("{\"schema_version\":1}".utf8)), .timedOut, .accountNotLinked, .rateLimited(retryAfter: 60), .session(code: "device_revoked", reason: nil)])
    }

    // MARK: - Helpers

    private func answer(_ status: Int, code: String? = nil, reason: String? = nil, retryAfter: TimeInterval? = nil, body: String = "") -> SGCustomerRawAnswer {
        return SGCustomerRawAnswer(transport: .ok, status: status, code: code, reason: reason, body: Data(body.utf8), retryAfter: retryAfter)
    }
}

/// A scripted transport: one answer per route, every call recorded.
final class SGCustomerWireTestTransport: SGCustomerTransport {
    private(set) var calls: [String] = []

    func consents(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        self.calls.append("consents \(String(decoding: body, as: UTF8.self)) \(accountPeerId)")
        return SGCustomerRawAnswer(transport: .ok, status: 200, body: Data("{\"schema_version\":1}".utf8))
    }

    func sync(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        self.calls.append("sync \(String(decoding: body, as: UTF8.self)) \(accountPeerId)")
        return SGCustomerRawAnswer(transport: .timeout)
    }

    func me(accountPeerId: Int64) async -> SGCustomerRawAnswer {
        self.calls.append("me \(accountPeerId)")
        return SGCustomerRawAnswer(transport: .ok, status: 403, code: "profile_account_not_linked")
    }

    func events(body: Data, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        self.calls.append("events \(String(decoding: body, as: UTF8.self)) \(accountPeerId)")
        return SGCustomerRawAnswer(transport: .ok, status: 429, code: "rate_limited", retryAfter: 60)
    }

    func delete(body: Data, idempotencyKey: String, accountPeerId: Int64) async -> SGCustomerRawAnswer {
        self.calls.append("delete \(idempotencyKey) \(String(decoding: body, as: UTF8.self)) \(accountPeerId)")
        return SGCustomerRawAnswer(transport: .ok, status: 401, code: "device_revoked")
    }
}
