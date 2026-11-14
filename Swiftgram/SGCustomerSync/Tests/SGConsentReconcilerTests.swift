import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — reconciling the local consent with the server (contract §6.3, design 40 §4.7,
/// amendments A3/A4).
final class SGConsentReconcilerTests: XCTestCase {
    private let grantId = "3a1c6f0e-5b7d-4e2a-9c8b-1f2e3d4c5b6a"
    private let withdrawId = "9b2d4f6a-8c0e-4a1b-b3d5-e7f9a1c3e5d7"
    private let foreignId = "c4e6a8b0-d2f4-4a6c-8e0a-2b4d6f8a0c2e"

    private var granted: SGConsentRecord {
        return SGConsentRecord(tgUserId: 555000111, state: .granted, consentId: self.grantId, textVersion: 1, textSha256: String(repeating: "a", count: 64), locale: .uz, consentMode: .required, decidedAt: "2026-11-01T09:00:00Z")
    }

    // MARK: - 403 consent_required (C§6.3)

    func testNoConsentReuploadsOncePerProcess() {
        let extras = SGConsentRequiredExtras(reason: .noConsent, consent: SGEffectiveConsent(state: .none, consentId: nil, textVersion: nil, effectiveAt: nil))
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(extras, record: self.granted, didReuploadThisProcess: false), .reuploadThenRetryOnce)
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(extras, record: self.granted, didReuploadThisProcess: true), .stop)
    }

    func testARemoteWithdrawWinsOnlyWhenNewerThanTheLocalDecision() {
        func withdrawn(at effectiveAt: String?) -> SGConsentRequiredExtras {
            return SGConsentRequiredExtras(reason: .withdrawn, consent: SGEffectiveConsent(state: .withdrawn, consentId: self.withdrawId, textVersion: nil, effectiveAt: effectiveAt))
        }
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(withdrawn(at: "2026-11-01T09:00:01Z"), record: self.granted, didReuploadThisProcess: false), .markWithdrawnRemote(effectiveAt: "2026-11-01T09:00:01Z", consentId: self.withdrawId))
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(withdrawn(at: "2026-11-01T09:00:00Z"), record: self.granted, didReuploadThisProcess: false), .reuploadThenRetryOnce, "not newer: our grant is the latest")
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(withdrawn(at: "2026-10-31T09:00:00Z"), record: self.granted, didReuploadThisProcess: false), .reuploadThenRetryOnce)
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(withdrawn(at: "2026-10-31T09:00:00Z"), record: self.granted, didReuploadThisProcess: true), .stop)
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(withdrawn(at: nil), record: self.granted, didReuploadThisProcess: false), .reuploadThenRetryOnce)
        var undated = self.granted
        undated.decidedAt = nil
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(withdrawn(at: "2026-11-01T09:00:01Z"), record: undated, didReuploadThisProcess: false), .markWithdrawnRemote(effectiveAt: "2026-11-01T09:00:01Z", consentId: self.withdrawId))
    }

    func testReconsentRequiredAsksAgainAndAnUnknownReasonStops() {
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(SGConsentRequiredExtras(reason: .reconsentRequired, consent: nil), record: self.granted, didReuploadThisProcess: false), .markNeedsReconsent(.reconsent))
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(SGConsentRequiredExtras(reason: .unknown, consent: nil), record: self.granted, didReuploadThisProcess: false), .stop)
    }

    func testOnlyAGrantedAccountReconciles() {
        let extras = SGConsentRequiredExtras(reason: .reconsentRequired, consent: nil)
        XCTAssertEqual(SGConsentReconciler.onConsentRequired(extras, record: nil, didReuploadThisProcess: false), .none)
        for state in [SGConsentState.declined, .withdrawn, .withdrawnRemote, .needsReconsent] {
            var record = self.granted
            record.state = state
            XCTAssertEqual(SGConsentReconciler.onConsentRequired(extras, record: record, didReuploadThisProcess: false), .none, state.rawValue)
        }
    }

    func testTheConsentRequiredErrorBodyDecodes() throws {
        let body = Data("""
        {"error":"consent_required","message":"…","server_time":"2026-11-01T10:00:00Z","reason":"withdrawn","extra":1,
         "consent":{"state":"withdrawn","consent_id":"\(self.withdrawId)","text_version":null,"effective_at":"2026-11-01T09:30:00Z"}}
        """.utf8)
        let extras = try XCTUnwrap(SGConsentRequiredExtras.decode(errorBody: body))
        XCTAssertEqual(extras, SGConsentRequiredExtras(reason: .withdrawn, consent: SGEffectiveConsent(state: .withdrawn, consentId: self.withdrawId, textVersion: nil, effectiveAt: "2026-11-01T09:30:00Z")))
        XCTAssertEqual(SGConsentRequiredExtras.decode(errorBody: Data("{\"error\":\"consent_required\",\"reason\":\"later\"}".utf8))?.reason, .unknown)
        XCTAssertNil(SGConsentRequiredExtras.decode(errorBody: Data("{\"error\":\"rate_limited\"}".utf8)))
        XCTAssertNil(SGConsentRequiredExtras.decode(errorBody: Data("not json".utf8)))
    }

    // MARK: - POST /v1/profile/consents 200

    func testEveryKnownOutcomeIsAcked() throws {
        let grant = self.event(.grant, id: self.grantId)
        let response = try XCTUnwrap(SGConsentsResponse.decode(Data("""
        {"schema_version":1,"server_time":"2026-11-01T09:00:02Z","later_key":true,
         "results":[{"consent_id":"\(self.grantId)","outcome":"duplicate"},{"consent_id":"\(self.withdrawId)","outcome":"retried"},
                    {"consent_id":"\(self.foreignId)","outcome":"superseded"}],
         "consent":{"state":"granted","consent_id":"\(self.grantId)","text_version":1,"effective_at":"2026-11-01T09:00:00Z"},
         "erasure":null}
        """.utf8)))
        XCTAssertEqual(response.results.map(\.consentId), [self.grantId, self.foreignId], "an unknown outcome is never acked")
        let result = SGConsentReconciler.onConsentsResponse(response, sent: [grant], record: self.granted)
        XCTAssertEqual(result.acked, [self.grantId], "only what this request sent")
        XCTAssertEqual(result.action, .none)
    }

    func testAnswersOfAnotherSchemaVersionAreNotThisAnswer() {
        XCTAssertNil(SGConsentsResponse.decode(Data("{\"schema_version\":2,\"results\":[]}".utf8)))
        XCTAssertNil(SGConsentsResponse.decode(Data("{\"results\":[]}".utf8)))
        XCTAssertNotNil(SGConsentsResponse.decode(Data("{\"schema_version\":1,\"results\":[],\"erasure\":{\"state\":\"scheduled\",\"due_by\":\"2026-11-02T09:00:00Z\"}}".utf8)))
    }

    func testANewerRemoteWithdrawInTheAnswerMarksWithdrawnRemote() {
        let response = SGConsentsResponse(results: [SGConsentsResponse.Item(consentId: self.grantId, outcome: .superseded)], consent: SGEffectiveConsent(state: .withdrawn, consentId: self.withdrawId, textVersion: 1, effectiveAt: "2026-11-01T09:10:00Z"))
        let result = SGConsentReconciler.onConsentsResponse(response, sent: [self.event(.grant, id: self.grantId)], record: self.granted)
        XCTAssertEqual(result.acked, [self.grantId])
        XCTAssertEqual(result.action, .markWithdrawnRemote(effectiveAt: "2026-11-01T09:10:00Z", consentId: self.withdrawId))

        let older = SGConsentsResponse(results: [], consent: SGEffectiveConsent(state: .withdrawn, consentId: self.withdrawId, textVersion: 1, effectiveAt: "2026-11-01T08:00:00Z"))
        XCTAssertEqual(SGConsentReconciler.onConsentsResponse(older, sent: [], record: self.granted).action, .none)
    }

    func testOurOwnWithdrawIsNotARemoteOne() {
        var withdrawn = self.granted
        withdrawn.state = .withdrawn
        withdrawn.consentId = self.withdrawId
        let response = SGConsentsResponse(results: [SGConsentsResponse.Item(consentId: self.withdrawId, outcome: .recorded)], consent: SGEffectiveConsent(state: .withdrawn, consentId: self.withdrawId, textVersion: 1, effectiveAt: "2026-11-01T09:10:00Z"))
        let result = SGConsentReconciler.onConsentsResponse(response, sent: [self.event(.withdraw, id: self.withdrawId)], record: withdrawn)
        XCTAssertEqual(result.acked, [self.withdrawId])
        XCTAssertEqual(result.action, .none)
    }

    func testAForeignDuplicateAsksForANewGrant() {
        let sent = [self.event(.grant, id: self.grantId)]
        let none = SGEffectiveConsent(state: .none, consentId: nil, textVersion: nil, effectiveAt: nil)
        for outcome in [SGConsentsResponse.Outcome.duplicate, .recorded] {
            let response = SGConsentsResponse(results: [SGConsentsResponse.Item(consentId: self.grantId, outcome: outcome)], consent: none)
            let result = SGConsentReconciler.onConsentsResponse(response, sent: sent, record: self.granted)
            XCTAssertEqual(result.acked, [self.grantId])
            XCTAssertEqual(result.action, .markNeedsReconsent(.linkEnded), outcome.rawValue)
        }
        // Amendment A4: the server says so directly.
        let foreign = SGConsentsResponse(results: [SGConsentsResponse.Item(consentId: self.grantId, outcome: .duplicate, foreign: true)], consent: SGEffectiveConsent(state: .granted, consentId: self.foreignId, textVersion: 1, effectiveAt: "2026-11-01T09:00:00Z"))
        XCTAssertEqual(SGConsentReconciler.onConsentsResponse(foreign, sent: sent, record: self.granted).action, .markNeedsReconsent(.linkEnded))
        // Our grant effective here: nothing to do.
        let ours = SGConsentsResponse(results: [SGConsentsResponse.Item(consentId: self.grantId, outcome: .duplicate)], consent: SGEffectiveConsent(state: .granted, consentId: self.grantId, textVersion: 1, effectiveAt: "2026-11-01T09:00:00Z"))
        XCTAssertEqual(SGConsentReconciler.onConsentsResponse(ours, sent: sent, record: self.granted).action, .none)
        // A superseded grant with state none is not ours being foreign (another decision won).
        let superseded = SGConsentsResponse(results: [SGConsentsResponse.Item(consentId: self.grantId, outcome: .superseded)], consent: none)
        XCTAssertEqual(SGConsentReconciler.onConsentsResponse(superseded, sent: sent, record: self.granted).action, .none)
    }

    func testTheForeignFlagDecodes() throws {
        let response = try XCTUnwrap(SGConsentsResponse.decode(Data("""
        {"schema_version":1,"results":[{"consent_id":"\(self.grantId)","outcome":"duplicate","foreign":true}],
         "consent":{"state":"none","consent_id":null,"text_version":null,"effective_at":null},"erasure":null}
        """.utf8)))
        XCTAssertEqual(response.results, [SGConsentsResponse.Item(consentId: self.grantId, outcome: .duplicate, foreign: true)])
        XCTAssertEqual(response.consent, SGEffectiveConsent(state: .none, consentId: nil, textVersion: nil, effectiveAt: nil))
    }

    // MARK: - Terminal answers

    func testATerminalAnswerMarksExactlyTheOneGrantSent() {
        for code in ["consent_text_mismatch", "consent_version_unknown", "consent_version_retired", "consent_scopes_mismatch", "consent_age_required", "consent_id_mismatch", "invalid_request", "unsupported_schema_version"] {
            XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: code, field: "consents[0].text_sha256", sent: [self.event(.grant, id: self.grantId)]), .markRejected(consentId: self.grantId, code: code))
        }
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 409, code: "profile_account_mismatch", field: "consents[0].tg_user_id", sent: [self.event(.grant, id: self.grantId)]), .markRejected(consentId: self.grantId, code: "profile_account_mismatch"))
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 400, code: nil, field: nil, sent: [self.event(.grant, id: self.grantId)]), .markRejected(consentId: self.grantId, code: "http_400"))
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: "Not A Code", field: nil, sent: [self.event(.grant, id: self.grantId)]), .markRejected(consentId: self.grantId, code: "http_422"))
    }

    func testAWithdrawIsNeverRejectedForAnyCode() {
        for code in ["consent_text_mismatch", "invalid_request", "profile_account_mismatch"] {
            XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: code, field: nil, sent: [self.event(.withdraw, id: self.withdrawId)]), .keep(SGCustomerLogCode.server(code)))
        }
    }

    func testSeveralEntriesAreAttributedByTheErrorField() {
        let sent = [self.event(.grant, id: self.grantId), self.event(.withdraw, id: self.withdrawId), self.event(.grant, id: self.foreignId)]
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: "consent_text_mismatch", field: "consents[2].text_sha256", sent: sent), .markRejected(consentId: self.foreignId, code: "consent_text_mismatch"))
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: "invalid_request", field: "consents[1].scopes", sent: sent), .keep(SGCustomerLogCode.server("invalid_request")))
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: "invalid_request", field: "schema_version", sent: sent), .unattributed)
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: "invalid_request", field: "consents[7].scopes", sent: sent), .unattributed)
        XCTAssertEqual(SGConsentReconciler.onConsentsTerminal(status: 422, code: "invalid_request", field: nil, sent: sent), .unattributed)
    }

    // MARK: - 409 consent_stale on /bind/start (amendment A3)

    func testConsentStaleAsksForANewGrantOnBothPaths() {
        XCTAssertEqual(SGConsentReconciler.onBindConsentStale(record: self.granted, consentId: nil), .markNeedsReconsent(.linkEnded))
        XCTAssertEqual(SGConsentReconciler.onBindConsentStale(record: self.granted, consentId: self.grantId), .markNeedsReconsent(.linkEnded))
        XCTAssertEqual(SGConsentReconciler.onBindConsentStale(record: self.granted, consentId: self.foreignId), .none, "a newer grant is not stale")
        XCTAssertEqual(SGConsentReconciler.onBindConsentStale(record: nil, consentId: nil), .none)
        var withdrawn = self.granted
        withdrawn.state = .withdrawn
        XCTAssertEqual(SGConsentReconciler.onBindConsentStale(record: withdrawn, consentId: nil), .none)
    }

    // MARK: - Helpers

    private func event(_ action: SGConsentAction, id: String) -> SGConsentEvent {
        return SGConsentEvent(
            consentId: id,
            tgUserId: 555000111,
            action: action,
            scopes: SGConsentScope.allCases.map(\.rawValue),
            textVersion: 1,
            textSha256: action == .grant ? String(repeating: "a", count: 64) : nil,
            locale: .uz,
            consentMode: .required,
            ageConfirmed: action == .grant ? true : nil,
            recordedAt: "2026-11-01T09:00:00Z",
            appVersion: "12.0.1"
        )
    }
}
