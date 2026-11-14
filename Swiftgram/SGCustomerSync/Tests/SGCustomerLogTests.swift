import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the customer-data layer's only logging path (design 40 §1): typed entries, stable
/// codes only, so no phone, name, username, token, `initData` or body can reach the sink. The route
/// sweep through the response classifier is added with it (I-2b).
final class SGCustomerLogTests: XCTestCase {
    private final class Sink {
        var entries: [SGCustomerLog.Entry] = []
    }

    /// Values that must never be logged.
    private let secrets = [
        "+998901234567", "998901234567", "john_doe", "Ali Valiyev", "«Zenlygram» MChJ",
        "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln", "rt_live_0123456789abcdef",
        "query_id=AAHdF6IQAAAAAN0XohDhrOrc&user=%7B%22id%22%3A555000111%7D&auth_date=1793523600&hash=c501b71e775f74ce10e377dea85a7ea24ecd640b223ea86dfe453e0eaed2e2b2",
        "{\"phone\":\"+998901234567\",\"first_name\":\"Ali\"}", "privacy@zenlygram.org",
    ]

    private var sink: Sink!

    override func setUp() {
        super.setUp()
        let sink = Sink()
        self.sink = sink
        SGCustomerLog.sink = { sink.entries.append($0) }
    }

    override func tearDown() {
        SGCustomerLog.sink = nil
        self.sink = nil
        super.tearDown()
    }

    func testAnEntryHoldsTypedValuesOnly() throws {
        SGCustomerLog.log(.consentRejected, route: .consents, status: 422)
        let entry = try XCTUnwrap(self.sink.entries.first)
        let children = Array(Mirror(reflecting: entry).children)
        XCTAssertEqual(children.compactMap(\.label).sorted(), ["code", "route", "status"])
        for child in children {
            XCTAssertFalse(child.value is String, "\(child.label ?? "") is a String")
            XCTAssertFalse(child.value is String?, "\(child.label ?? "") is a String?")
        }
        XCTAssertTrue(children.first { $0.label == "code" }?.value is SGCustomerLogCode)
        XCTAssertTrue(children.first { $0.label == "route" }?.value is SGCustomerRoute?)
        XCTAssertTrue(children.first { $0.label == "status" }?.value is Int?)
        XCTAssertEqual(entry, SGCustomerLog.Entry(code: .consentRejected, route: .consents, status: 422))
        XCTAssertEqual(entry.line, "consent_rejected route=consents status=422")
    }

    func testNothingIsLoggedWithoutASink() {
        SGCustomerLog.sink = nil
        SGCustomerLog.log(.consentSaveFailed)
        XCTAssertEqual(self.sink.entries, [])
    }

    func testEveryCodeIsStable() {
        let codes: [SGCustomerLogCode] = [
            .serverOther, .consentManifestUnreadable, .consentManifestMalformed, .consentTemplateUnreadable, .consentTemplateMismatch,
            .consentOperatorMissing, .consentOperatorInvalid, .consentStoreUnreadable, .consentSaveFailed, .consentRejected,
            .consentWithdrawKept, .consentReupload, .consentWithdrawnRemote, .consentNeedsReconsent, .consentForeignDuplicate,
            .consentStale, .wallBuildFailed,
        ]
        for code in codes {
            XCTAssertTrue(SGCustomerLogCode.isStableCode(code.rawValue), code.rawValue)
        }
        XCTAssertEqual(Set(codes.map(\.rawValue)).count, codes.count)
        XCTAssertEqual(SGCustomerLogCode("Not A Code").rawValue, "invalid_code")
        XCTAssertEqual(SGCustomerLogCode("wall_build_failed"), .wallBuildFailed)
        for problem in [SGConsentTextRepository.Problem.manifestUnreadable, .manifestMalformed, .templateUnreadable, .templateMismatch] {
            XCTAssertTrue(SGCustomerLogCode.isStableCode(problem.logCode.rawValue))
        }
    }

    func testServerCodesOutsideTheContractNeverReachTheSink() {
        for secret in self.secrets + ["consent_text_mismatch_+998", "john_doe_998901234567", "http_4044", "http_", "HTTP_404"] {
            XCTAssertEqual(SGCustomerLogCode.server(secret), .serverOther, secret)
            SGCustomerLog.log(SGCustomerLogCode.server(secret), route: .sync, status: 403)
        }
        XCTAssertEqual(SGCustomerLogCode.server(nil), .serverOther)
        for code in ["consent_text_mismatch", "invalid_token", "account_erased", "consent_stale", "rate_limited", "attest_no_init_data", "timeout"] {
            XCTAssertEqual(SGCustomerLogCode.server(code).rawValue, code)
        }
        XCTAssertEqual(SGCustomerLogCode.server("http_404").rawValue, "http_404")
        self.assertNoSecretWasLogged()
    }

    func testAStatusOutsideHTTPIsDropped() {
        SGCustomerLog.log(.consentRejected, route: .consents, status: 998_901_234_567)
        SGCustomerLog.log(.consentRejected, status: 99)
        SGCustomerLog.log(.consentRejected, status: 600)
        XCTAssertEqual(self.sink.entries.map(\.status), [nil, nil, nil])
        XCTAssertEqual(self.sink.entries.first?.line, "consent_rejected route=consents")
        self.assertNoSecretWasLogged()
    }

    func testEveryRouteLogsAsCodeRouteAndStatus() throws {
        let pattern = try NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_.-]* route=(consents|sync|me|events|delete) status=[1-5][0-9]{2}$")
        for route in SGCustomerRoute.allCases {
            for status in [200, 401, 403, 409, 413, 422, 429, 503] {
                SGCustomerLog.log(.serverOther, route: route, status: status)
            }
        }
        XCTAssertEqual(self.sink.entries.count, SGCustomerRoute.allCases.count * 8)
        for entry in self.sink.entries {
            XCTAssertNotNil(pattern.firstMatch(in: entry.line, range: NSRange(location: 0, length: (entry.line as NSString).length)), entry.line)
        }
    }

    func testAKeptWithdrawLogsOnlyAnAllowedCode() {
        let withdraw = SGConsentEvent(consentId: SGCustomerTime.uuid4(), tgUserId: 555000111, action: .withdraw, scopes: ["link"], textVersion: nil, textSha256: nil, locale: .uz, consentMode: .required, ageConfirmed: nil, recordedAt: "2026-11-01T09:00:00Z", appVersion: "1")
        for secret in self.secrets {
            if case let .keep(code) = SGConsentReconciler.onConsentsTerminal(status: 422, code: secret, field: nil, sent: [withdraw]) {
                SGCustomerLog.log(code, route: .consents, status: 422)
            } else {
                XCTFail("a withdraw is kept")
            }
        }
        self.assertNoSecretWasLogged()
        XCTAssertEqual(Set(self.sink.entries.map(\.code.rawValue)), ["server_other", "http_422"])
    }

    func testTheRouteSweepThroughTheClassifierLogsNoValue() throws {
        // Every route, every answer the transport can hand over — with secrets in the code, the
        // reason and the body — classified by the one classifier and logged as one typed line.
        let pattern = try NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_.-]* route=(consents|sync|me|events|delete)( status=[1-5][0-9]{2})?$")
        let body = Data("{\"error\":\"consent_required\",\"reason\":\"withdrawn\",\"message\":\"+998901234567 john_doe Ali Valiyev\",\"field\":\"telegram.phone\",\"phone\":\"+998901234567\",\"first_name\":\"Ali\",\"init_data\":\"query_id=AAHdF6IQAAAAAN0XohDhrOrc\",\"refresh_token\":\"rt_live_0123456789abcdef\",\"schema_version\":1}".utf8)
        let transports: [SGCustomerRawAnswer.Transport] = [.timeout, .offline, .notLinked, .credentialChanged, .notConfigured]
        var answers = transports.map { SGCustomerRawAnswer(transport: $0, body: body) }
        for status in [200, 302, 400, 401, 403, 404, 409, 413, 422, 429, 500, 503] {
            answers.append(SGCustomerRawAnswer(transport: .ok, status: status, body: body, retryAfter: 30))
            answers.append(SGCustomerRawAnswer(transport: .ok, status: status, code: "consent_required", reason: "account_erased", body: body))
            for secret in self.secrets {
                answers.append(SGCustomerRawAnswer(transport: .ok, status: status, code: secret, reason: secret, body: Data(secret.utf8)))
            }
        }
        for route in SGCustomerRoute.allCases {
            for answer in answers {
                SGCustomerWire.log(SGCustomerWire.classify(answer), answer: answer, route: route)
            }
        }
        XCTAssertEqual(self.sink.entries.count, SGCustomerRoute.allCases.count * answers.count, "one line per call")
        for entry in self.sink.entries {
            XCTAssertNotNil(pattern.firstMatch(in: entry.line, range: NSRange(location: 0, length: (entry.line as NSString).length)), entry.line)
        }
        XCTAssertTrue(self.sink.entries.contains { $0.code == .customerCallOk }, "a 2xx with schema_version 1 logs call_ok")
        XCTAssertTrue(self.sink.entries.contains { $0.code.rawValue == "account_erased" }, "a 401 account_erased logs its reason code")
        self.assertNoSecretWasLogged()
        let codes: [SGCustomerLogCode] = [.customerCallOk, .customerNotConfigured, .customerNotLinkedLocally, .customerCredentialChanged, .analyticsQueueWriteFailed, .analyticsQueueUnreadable, .profileSnapshotInvalid]
        for code in codes {
            XCTAssertTrue(SGCustomerLogCode.isStableCode(code.rawValue), code.rawValue)
        }
        XCTAssertEqual(Set(codes.map(\.rawValue)).count, codes.count)
    }

    private func assertNoSecretWasLogged(file: StaticString = #filePath, line: UInt = #line) {
        let lines = self.sink.entries.map(\.line).joined(separator: "\n")
        for secret in self.secrets {
            XCTAssertFalse(lines.contains(secret), "logged: \(secret)", file: file, line: line)
        }
        for fragment in ["998901234567", "john", "Ali", "eyJ", "query_id", "phone", "@"] {
            XCTAssertFalse(lines.contains(fragment), "logged: \(fragment)", file: file, line: line)
        }
    }
}
