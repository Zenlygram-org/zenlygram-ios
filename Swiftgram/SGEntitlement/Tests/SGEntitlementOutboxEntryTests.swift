import XCTest
@testable import SGEntitlement

/// What one failed `/apple/attach` does to an outbox entry. The entry is a value, so these run on the
/// host without the Keychain-backed store; `SGEntitlementOutbox` only persists the result.
final class SGEntitlementOutboxEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(attempts: Int = 0) -> SGEntitlementOutboxEntry {
        return SGEntitlementOutboxEntry(id: "2000000123456789", signedTransaction: "signed.transaction", idempotencyKey: "idempotency-key", accountPeerId: 42, attempts: attempts)
    }

    func test_aFailureCountsOneAttemptAndNeverTouchesTheTransactionOrItsKey() {
        var entry = self.makeEntry()
        entry.recordFailure(.offline(.timeout), retryAfter: nil, now: self.now)
        XCTAssertEqual(entry.attempts, 1)
        XCTAssertEqual(entry.id, "2000000123456789")
        XCTAssertEqual(entry.signedTransaction, "signed.transaction")
        XCTAssertEqual(entry.idempotencyKey, "idempotency-key", "a retry must present the SAME key")
        XCTAssertEqual(entry.accountPeerId, 42, "a failure never re-attributes the entry")
    }

    func test_offlineIsSilentAboutTheCodeAndSchedulesARetry() {
        var entry = self.makeEntry()
        entry.recordFailure(.offline(.serverError), retryAfter: nil, now: self.now)
        XCTAssertNil(entry.lastErrorCode, "a 5xx is 'offline': there is no stable code to keep")
        XCTAssertFalse(entry.isStuck)
        guard let next = entry.nextAttemptAt else {
            return XCTFail("a transient failure schedules the next attempt")
        }
        XCTAssertGreaterThanOrEqual(next, self.now)
        XCTAssertLessThanOrEqual(next.timeIntervalSince(self.now), SGEntitlementBackoff.base, "the first retry is within one base interval")
    }

    func test_theStableCodeIsKeptForSupport() {
        var entry = self.makeEntry()
        entry.recordFailure(.rateLimited(retryAfter: 30), retryAfter: 30, now: self.now)
        XCTAssertEqual(entry.lastErrorCode, "rate_limited")
        entry.recordFailure(.session(.clockSkew), retryAfter: nil, now: self.now)
        XCTAssertEqual(entry.lastErrorCode, "clock_skew")
        entry.recordFailure(.refused(.appleTemporarilyUnavailable), retryAfter: nil, now: self.now)
        XCTAssertEqual(entry.lastErrorCode, "apple_temporarily_unavailable")
        entry.recordFailure(.unknownRefusal(code: "invented_tomorrow", status: 418), retryAfter: nil, now: self.now)
        XCTAssertEqual(entry.lastErrorCode, "request_failed")
        XCTAssertEqual(entry.attempts, 4)
    }

    func test_theServersRetryAfterWins() {
        var entry = self.makeEntry()
        entry.recordFailure(.rateLimited(retryAfter: 90), retryAfter: 90, now: self.now)
        guard let next = entry.nextAttemptAt else {
            return XCTFail("a rate limit schedules the next attempt")
        }
        XCTAssertGreaterThanOrEqual(next.timeIntervalSince(self.now), 90, "never earlier than the server asked")
        XCTAssertLessThanOrEqual(next.timeIntervalSince(self.now), 95, "plus at most the capped jitter")
    }

    func test_theBackoffIsCappedHoweverManyAttemptsThereWere() {
        var entry = self.makeEntry(attempts: 40)
        entry.recordFailure(.offline(.noRoute), retryAfter: nil, now: self.now)
        guard let next = entry.nextAttemptAt else {
            return XCTFail("a transient failure schedules the next attempt")
        }
        XCTAssertLessThanOrEqual(next.timeIntervalSince(self.now), SGEntitlementBackoff.cap)
    }

    func test_appleJwsInvalidKeepsRetryingUntilTheFifthAttempt() {
        XCTAssertEqual(SGEntitlementOutboxEntry.stuckAfterAttempts, 5)
        var entry = self.makeEntry()
        for attempt in 1 ..< SGEntitlementOutboxEntry.stuckAfterAttempts {
            entry.recordFailure(.refused(.appleJwsInvalid), retryAfter: nil, now: self.now)
            XCTAssertEqual(entry.attempts, attempt)
            XCTAssertFalse(entry.isStuck, "attempt \(attempt): Apple's chain check can fail transiently, keep trying")
            XCTAssertNotNil(entry.nextAttemptAt, "attempt \(attempt) schedules the next one")
        }
        entry.recordFailure(.refused(.appleJwsInvalid), retryAfter: nil, now: self.now)
        XCTAssertEqual(entry.attempts, SGEntitlementOutboxEntry.stuckAfterAttempts)
        XCTAssertTrue(entry.isStuck, "the fifth apple_jws_invalid hands the transaction to a human")
        XCTAssertNil(entry.nextAttemptAt, "a stuck entry has no automatic next attempt")
        XCTAssertEqual(entry.lastErrorCode, "apple_jws_invalid")
    }

    func test_theAppleRefusalsThatNeedAHumanAreStuckAtOnce() {
        for code in [SGEntitlementRefusalCode.appleEnvironmentMismatch, .appleSubscriptionConflict, .appleFamilyShared] {
            var entry = self.makeEntry()
            entry.recordFailure(.refused(code), retryAfter: nil, now: self.now)
            XCTAssertEqual(entry.attempts, 1)
            XCTAssertTrue(entry.isStuck, "\(code) is not helped by one more attempt")
            XCTAssertNil(entry.nextAttemptAt, "\(code): no automatic next attempt")
            XCTAssertEqual(entry.lastErrorCode, code.rawValue)
        }
    }

    /// The refusals `classify` can synthesise from a bare HTTP status, with no server code behind
    /// them; `apple_jws_invalid` has its own test.
    private let bareStatusRefusals: [SGEntitlementRefusalCode] = [.notFound, .methodNotAllowed]

    func test_everyCodedRefusalTheMappingStopsIsStuckAtOnce() {
        // The outbox derives "stuck" from the recovery table instead of keeping its own list of
        // codes, so a coded refusal the mapping stops — known today or added tomorrow — never loops
        // with backoff. `apple_jws_invalid` and the bare-status classes are the exceptions, each
        // covered by its own test.
        for code in SGEntitlementRefusalCode.allCases where code != .appleJwsInvalid && !self.bareStatusRefusals.contains(code) {
            let stops = SGEntitlementFailureMapping.recovery(for: .refused(code)).retry == .stop
            var entry = self.makeEntry()
            entry.recordFailure(.refused(code), retryAfter: nil, now: self.now)
            XCTAssertEqual(entry.isStuck, stops, "\(code): stuck exactly when the mapping says stop")
            XCTAssertEqual(entry.nextAttemptAt == nil, stops, "\(code): a stuck entry has no automatic next attempt, a retried one has")
            XCTAssertEqual(entry.lastErrorCode, code.rawValue)
        }
    }

    func test_anUnknownStableCodeIsStuckAtOnce() {
        // A code this build does not know is a refusal the server will repeat. Retrying it with
        // backoff forever is what kept a FAMILY_SHARED transaction looping before the code was known.
        var entry = self.makeEntry()
        entry.recordFailure(.unknownRefusal(code: "invented_tomorrow", status: 409), retryAfter: nil, now: self.now)
        XCTAssertTrue(entry.isStuck)
        XCTAssertNil(entry.nextAttemptAt)
        XCTAssertEqual(entry.lastErrorCode, "request_failed")
    }

    func test_aBareStatusAnswerKeepsBackingOffUntilTheFifthAttempt() {
        // No JSON `code`: a CDN / WAF / proxy error page (403, 400), or a 404 / 405 from an edge
        // misroute during a deploy. The mapping stops them like a coded refusal, but one such answer
        // is not a stable server refusal and must not strand a PAID transaction until the user finds
        // Restore. Five in a row are no longer transient.
        let answers: [SGEntitlementFailureClass] = [
            .unknownRefusal(code: "", status: 403),
            .unknownRefusal(code: "", status: 400),
            .refused(.notFound),
            .refused(.methodNotAllowed)
        ]
        for answer in answers {
            XCTAssertEqual(SGEntitlementFailureMapping.recovery(for: answer).retry, .stop, "\(answer): premise — the mapping stops it")
            var entry = self.makeEntry()
            for attempt in 1 ..< SGEntitlementOutboxEntry.stuckAfterAttempts {
                entry.recordFailure(answer, retryAfter: nil, now: self.now)
                XCTAssertEqual(entry.attempts, attempt)
                XCTAssertFalse(entry.isStuck, "\(answer), attempt \(attempt): a bare status is transient, keep trying")
                guard let next = entry.nextAttemptAt else {
                    XCTFail("\(answer), attempt \(attempt): schedules the next one")
                    continue
                }
                XCTAssertGreaterThanOrEqual(next, self.now)
            }
            entry.recordFailure(answer, retryAfter: nil, now: self.now)
            XCTAssertTrue(entry.isStuck, "\(answer): the fifth hands the transaction to a human")
            XCTAssertNil(entry.nextAttemptAt)
        }
        // The same statuses WITH a server code behind them are stable refusals: stuck at once.
        var coded = self.makeEntry()
        coded.recordFailure(.unknownRefusal(code: "invented_tomorrow", status: 403), retryAfter: nil, now: self.now)
        XCTAssertTrue(coded.isStuck, "a coded 403 is the server's answer, not an edge's")
        XCTAssertNil(coded.nextAttemptAt)
    }

    func test_aStuckEntryStaysStuckUntilRestoreClearsIt() {
        var entry = self.makeEntry()
        entry.recordFailure(.refused(.appleFamilyShared), retryAfter: nil, now: self.now)
        XCTAssertTrue(entry.isStuck)
        entry.recordFailure(.offline(.timeout), retryAfter: nil, now: self.now)
        XCTAssertTrue(entry.isStuck, "a later transient failure does not make the human unnecessary")
        XCTAssertNil(entry.nextAttemptAt)
        XCTAssertEqual(entry.attempts, 2)
        // What Restore does (`SGEntitlementOutbox.clearStuckFlags`), then the retry fails transiently.
        entry.isStuck = false
        entry.nextAttemptAt = nil
        entry.recordFailure(.offline(.timeout), retryAfter: nil, now: self.now)
        XCTAssertFalse(entry.isStuck, "once cleared, only a new stopping refusal makes it stuck again")
        XCTAssertNotNil(entry.nextAttemptAt)
    }

    func test_theTransientFamilyIsNeverStuck() {
        let failures: [SGEntitlementFailureClass] = [
            .refused(.appleTemporarilyUnavailable),
            .refused(.idempotencyInFlight),
            .offline(.serverError),
            .offline(.timeout),
            .rateLimited(retryAfter: 30),
            .session(.invalidToken),
            .session(.deviceKeyMismatch),
            .session(.clockSkew)
        ]
        for failure in failures {
            var entry = self.makeEntry(attempts: 10)
            entry.recordFailure(failure, retryAfter: nil, now: self.now)
            XCTAssertFalse(entry.isStuck, "\(failure) is repaired by time or a re-bind, not by a human")
            XCTAssertNotNil(entry.nextAttemptAt, "\(failure) keeps retrying")
        }
    }
}
