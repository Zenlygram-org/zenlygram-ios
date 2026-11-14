import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — backoff and budgets (design 40 §7.4–7.5, contract §6.5): full jitter from 30 s to
/// 6 h, `Retry-After` wins, a success resets; device-wide budgets of 16 / 9 / 48 automatic calls per
/// hour.
final class SGCustomerBackoffTests: XCTestCase {
    /// 2026-11-01T10:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_793_527_200)

    func testTheCeilingDoublesFromThirtySecondsToSixHours() {
        XCTAssertEqual(SGCustomerBackoff.ceiling(failures: 0), 0)
        XCTAssertEqual((1 ... 11).map { SGCustomerBackoff.ceiling(failures: $0) }, [30, 60, 120, 240, 480, 960, 1920, 3840, 7680, 15_360, 21_600])
        XCTAssertEqual(SGCustomerBackoff.ceiling(failures: 12), 21_600)
        XCTAssertEqual(SGCustomerBackoff.ceiling(failures: 10_000), 21_600, "no overflow")
    }

    func testTheDelayIsAFullJitterBelowTheCeiling() {
        var backoff = SGCustomerBackoff()
        XCTAssertTrue(backoff.allows(now: self.now))
        backoff.recordFailure(now: self.now, random: { 0 })
        XCTAssertEqual(backoff.nextAt, self.now, "uniform(0, …): zero is a valid draw")
        backoff.recordFailure(now: self.now, random: { 0.5 })
        XCTAssertEqual(backoff.nextAt, self.now.addingTimeInterval(30), "half of the second ceiling (60 s)")
        XCTAssertFalse(backoff.allows(now: self.now))
        XCTAssertTrue(backoff.allows(now: self.now.addingTimeInterval(30)))
        for _ in 0 ..< 20 {
            backoff.recordFailure(now: self.now, random: { 0.999_999 })
        }
        XCTAssertEqual(backoff.failures, 22)
        XCTAssertLessThan(backoff.nextAt?.timeIntervalSince(self.now) ?? .infinity, 21_600)
        XCTAssertGreaterThan(backoff.nextAt?.timeIntervalSince(self.now) ?? 0, 21_599)
        var draws = SGCustomerBackoff()
        for _ in 0 ..< 200 {
            draws.recordFailure(now: self.now)
            let delay = draws.nextAt?.timeIntervalSince(self.now) ?? -1
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, SGCustomerBackoff.ceiling(failures: draws.failures))
        }
    }

    func testRetryAfterWins() {
        var backoff = SGCustomerBackoff()
        backoff.recordFailure(now: self.now, retryAfter: 120, random: { 0.5 })
        XCTAssertEqual(backoff.nextAt, self.now.addingTimeInterval(122.5), "Retry-After plus at most 5 s of jitter")
        for _ in 0 ..< 8 {
            backoff.recordFailure(now: self.now, random: { 0 })
        }
        backoff.recordFailure(now: self.now, retryAfter: 2, random: { 0 })
        XCTAssertEqual(backoff.nextAt, self.now.addingTimeInterval(2), "also when the exponential ceiling is far higher")
        backoff.recordFailure(now: self.now, retryAfter: 40_000, random: { 0.999 })
        XCTAssertGreaterThan(backoff.nextAt?.timeIntervalSince(self.now) ?? 0, 40_000, "and when it is longer than 6 h")
    }

    func testASuccessResets() {
        var backoff = SGCustomerBackoff()
        backoff.recordFailure(now: self.now, random: { 0.9 })
        backoff.recordFailure(now: self.now, random: { 0.9 })
        backoff.recordSuccess()
        XCTAssertEqual(backoff, SGCustomerBackoff())
        XCTAssertTrue(backoff.allows(now: self.now))
    }

    func testWhatEachOutcomeDoes() {
        let failing: [SGCustomerCallOutcome] = [.timedOut, .unavailable(retryAfter: nil), .rateLimited(retryAfter: nil)]
        for outcome in failing {
            var backoff = SGCustomerBackoff()
            backoff.apply(outcome, now: self.now, random: { 0.5 })
            XCTAssertEqual(backoff.failures, 1, "\(outcome)")
            XCTAssertEqual(backoff.nextAt, self.now.addingTimeInterval(15), "\(outcome)")
        }
        var limited = SGCustomerBackoff()
        limited.apply(.rateLimited(retryAfter: 600), now: self.now, random: { 0 })
        XCTAssertEqual(limited.nextAt, self.now.addingTimeInterval(600))
        var unavailable = SGCustomerBackoff()
        unavailable.apply(.unavailable(retryAfter: 90), now: self.now, random: { 0 })
        XCTAssertEqual(unavailable.nextAt, self.now.addingTimeInterval(90), "503 profile_unavailable's Retry-After")

        let resetting: [SGCustomerCallOutcome] = [.ok(Data()), .terminal(status: 422, code: "invalid_request"), .accountMismatch]
        for outcome in resetting {
            var backoff = SGCustomerBackoff()
            backoff.recordFailure(now: self.now, random: { 0.5 })
            backoff.apply(outcome, now: self.now)
            XCTAssertEqual(backoff, SGCustomerBackoff(), "\(outcome)")
        }
        let neutral: [SGCustomerCallOutcome] = [
            .payloadTooLarge, .consentRequired(SGConsentRequiredExtras(reason: .noConsent, consent: nil)), .accountNotLinked,
            .session(code: "invalid_token", reason: "account_erased"), .notLinkedLocally, .credentialChanged, .notConfigured,
        ]
        for outcome in neutral {
            var backoff = SGCustomerBackoff()
            backoff.recordFailure(now: self.now, random: { 0.5 })
            let before = backoff
            backoff.apply(outcome, now: self.now)
            XCTAssertEqual(backoff, before, "\(outcome): no attempt spent")
        }
    }

    func testTheDeviceWideBudgets() {
        var sync = SGCustomerBudget(route: .sync)
        XCTAssertNil(sync.nextAllowedAt(now: self.now))
        for minute in 0 ..< 9 {
            sync.record(now: self.now.addingTimeInterval(TimeInterval(minute * 60)))
        }
        let later = self.now.addingTimeInterval(600)
        XCTAssertEqual(sync.nextAllowedAt(now: later), self.now.addingTimeInterval(3600), "the 10th waits until the 1st leaves the hour")
        XCTAssertNil(sync.nextAllowedAt(now: self.now.addingTimeInterval(3600)))
        var consents = SGCustomerBudget(route: .consents)
        for _ in 0 ..< 15 {
            consents.record(now: self.now)
        }
        XCTAssertNil(consents.nextAllowedAt(now: self.now), "16 per hour")
        consents.record(now: self.now)
        XCTAssertNotNil(consents.nextAllowedAt(now: self.now))
        var events = SGCustomerBudget(route: .events)
        for _ in 0 ..< 47 {
            events.record(now: self.now)
        }
        XCTAssertNil(events.nextAllowedAt(now: self.now), "48 per hour")
        events.record(now: self.now)
        XCTAssertEqual(events.nextAllowedAt(now: self.now), self.now.addingTimeInterval(3600))
    }

    func testABudgetSurvivesARelaunchAndAClockSetBack() {
        var sync = SGCustomerBudget(route: .sync)
        for _ in 0 ..< 9 {
            sync.record(now: self.now)
        }
        let stored = sync.jsonObject
        XCTAssertTrue(JSONSerialization.isValidJSONObject(stored))
        let restored = SGCustomerBudget(route: .sync, jsonObject: stored)
        XCTAssertEqual(restored.nextAllowedAt(now: self.now.addingTimeInterval(60)), self.now.addingTimeInterval(3600))
        XCTAssertNotNil(restored.nextAllowedAt(now: self.now.addingTimeInterval(-1800)), "a clock set back does not free the budget")
        XCTAssertNil(SGCustomerBudget(route: .sync, jsonObject: ["sent": "garbage"]).nextAllowedAt(now: self.now))
        XCTAssertNil(SGCustomerBudget(route: .sync, jsonObject: nil).nextAllowedAt(now: self.now))
        var old = SGCustomerBudget(route: .sync, jsonObject: stored)
        old.record(now: self.now.addingTimeInterval(7200))
        XCTAssertEqual(old.sent.count, 1, "sends outside the hour are forgotten")
    }
}
