// App-side only (see SGCustomerSyncConfigTests.swift): compiles to nothing in `run-core-tests.sh`.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
import SGEntitlement
@testable import SGCustomerSync
@testable import SGCustomerSyncCore

/// Zenlygram — `SGCustomerTransportLive.rawAnswer` (design 40 §6.5): the facade's result converted
/// into what the core classifies, nothing more.
final class SGCustomerTransportLiveTests: XCTestCase {
    private func answer(_ result: Result<Data, SGEntitlement.CustomerDataFailure>) -> SGCustomerRawAnswer {
        return SGCustomerTransportLive.rawAnswer(result)
    }

    func test_aSuccessIsA200WithItsBody() {
        let body = Data(#"{"schema_version":1}"#.utf8)
        XCTAssertEqual(self.answer(.success(body)), SGCustomerRawAnswer(transport: .ok, status: 200, body: body))
        XCTAssertEqual(self.answer(.success(Data())), SGCustomerRawAnswer(transport: .ok, status: 200, body: Data()))
    }

    func test_theFacadesOwnRefusalsSentNothing() {
        XCTAssertEqual(self.answer(.failure(.notConfigured)), SGCustomerRawAnswer(transport: .notConfigured))
        XCTAssertEqual(self.answer(.failure(.notLinked)), SGCustomerRawAnswer(transport: .notLinked))
        XCTAssertEqual(self.answer(.failure(.credentialChanged)), SGCustomerRawAnswer(transport: .credentialChanged))
        // `performIfCleared` reports a refused re-check as not sent before it would get here.
        XCTAssertEqual(self.answer(.failure(.notWanted)), SGCustomerRawAnswer(transport: .notConfigured), "nothing was sent")
    }

    func test_anAnsweredErrorKeepsStatusCodeReasonBodyAndRetryAfter() {
        let body = Data(#"{"error":"consent_required","reason":"withdrawn"}"#.utf8)
        let error = SGEntitlementRequestError(failure: .unknownRefusal(code: "consent_required", status: 403), retryAfter: 30, status: 403, code: "consent_required", reason: "withdrawn", responseBody: body)
        XCTAssertEqual(self.answer(.failure(.request(error))), SGCustomerRawAnswer(transport: .ok, status: 403, code: "consent_required", reason: "withdrawn", body: body, retryAfter: 30))

        let bare = SGEntitlementRequestError(failure: .offline(.serverError), status: 503)
        XCTAssertEqual(self.answer(.failure(.request(bare))), SGCustomerRawAnswer(transport: .ok, status: 503, code: nil, reason: nil, body: Data(), retryAfter: nil), "no body reads as empty, no Retry-After as nil")

        let session = SGEntitlementRequestError(failure: .session(.invalidToken), status: 401, code: "invalid_token", reason: "account_erased")
        XCTAssertEqual(self.answer(.failure(.request(session))), SGCustomerRawAnswer(transport: .ok, status: 401, code: "invalid_token", reason: "account_erased"), "an answered 401 is an answer, whatever its class")
    }

    func test_withoutAnAnswerOnlyTheTimeoutIsSetApart() {
        XCTAssertEqual(self.answer(.failure(.request(SGEntitlementRequestError(failure: .offline(.timeout))))), SGCustomerRawAnswer(transport: .timeout))
        for cause in [SGEntitlementOfflineCause.dns, .tls, .noRoute, .connectionLost, .cancelled, .serverError, .malformedResponse, .unknown] {
            XCTAssertEqual(self.answer(.failure(.request(SGEntitlementRequestError(failure: .offline(cause))))), SGCustomerRawAnswer(transport: .offline), "\(cause)")
        }
    }

    func test_aLocalRefusalWithoutAStatusReadsAsNotConfigured() {
        let refusals: [SGEntitlementFailureClass] = [
            .rateLimited(retryAfter: 5),
            .session(.unauthenticated),
            .refused(.invalidRequest),
            .unknownRefusal(code: "consent_required_local", status: 0),
        ]
        for failure in refusals {
            XCTAssertEqual(self.answer(.failure(.request(SGEntitlementRequestError(failure: failure)))), SGCustomerRawAnswer(transport: .notConfigured), "\(failure)")
        }
    }
}
#endif
