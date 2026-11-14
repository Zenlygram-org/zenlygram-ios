import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the automatic link's preconditions and schedule (design 40 §8, contract §6.6): the
/// ladder ±20 %, ≤ 6 starts in 24 h, `bind_conflict` 24 h, attest-null 6 h + the install ladder
/// 24 h / 72 h / 7 d and its resets, superseded / in progress not counted, the Unlink suppression.
final class SGAutoLinkPolicyTests: XCTestCase {
    private typealias Policy = SGAutoLinkPolicy

    private let tg: Int64 = 555_000_111
    private let authority = "zenlygram.org"
    /// 2026-11-01T10:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_793_527_200)

    // MARK: - Preconditions

    func testAConsentedUnlinkedAccountLinksOnceFirstIdleAndItsJitterPassed() {
        XCTAssertEqual(Policy.decide(self.ready(), now: self.now), .run)
        var inputs = self.ready()
        inputs.firstIdleAt = self.now.addingTimeInterval(-5)
        inputs.firstIdleJitter = 12
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .wait(until: self.now.addingTimeInterval(7)), "first idle + the process's jitter")
        inputs.firstIdleAt = nil
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .blocked(.firstIdle), "nothing automatic before first idle")
        XCTAssertEqual(Policy.firstIdleJitter { 0 }, 0)
        XCTAssertEqual(Policy.firstIdleJitter { 0.5 }, 15)
        XCTAssertLessThan(Policy.firstIdleJitter { 0.999_999 }, 30)
    }

    func testEachPreconditionBlocks() {
        func blocked(_ change: (inout Policy.Inputs) -> Void) -> Policy.Decision {
            var inputs = self.ready()
            change(&inputs)
            return Policy.decide(inputs, now: self.now)
        }
        XCTAssertEqual(blocked { $0.readable = false }, .blocked(.unreadable))
        for state in SGConsentState.allCases where state != .granted {
            XCTAssertEqual(blocked { $0.state = state }, .blocked(.notGranted), state.rawValue)
        }
        XCTAssertEqual(blocked { $0.latestGrantRejected = true }, .blocked(.grantRejected))
        XCTAssertEqual(blocked { $0.linkEnded = true }, .blocked(.linkEnded), "a server-ended link waits for a new grant")
        XCTAssertEqual(blocked { $0.erasing = true }, .blocked(.erasing))
        XCTAssertEqual(blocked { $0.isLinked = true }, .blocked(.linked))
        XCTAssertEqual(blocked { $0.bindPermissionAllowed = false }, .blocked(.notPermitted))
        XCTAssertEqual(blocked { $0.record = SGAutoLinkRecord().suppressingForUnlink() }, .blocked(.suppressed))
        XCTAssertEqual(blocked { $0.stopped = true }, .blocked(.stopped))
        XCTAssertEqual(blocked { $0.inFlight = true }, .blocked(.inFlight), "one automatic link on the install")
        XCTAssertEqual(blocked { $0.bindInProgress = true }, .blocked(.bindInProgress), "never beside a live manual bind")
    }

    func testTheScheduleHoldsUntilTheLatestOfItsTimes() {
        var inputs = self.ready()
        inputs.record.nextAt = self.now.addingTimeInterval(60)
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .wait(until: self.now.addingTimeInterval(60)))
        inputs.record.pausedUntil = self.now.addingTimeInterval(3_600)
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .wait(until: self.now.addingTimeInterval(3_600)))
        inputs.install.nextAt = self.now.addingTimeInterval(86_400)
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .wait(until: self.now.addingTimeInterval(86_400)), "the install-wide ladder holds every account")
        XCTAssertEqual(Policy.decide(inputs, now: self.now.addingTimeInterval(86_400)), .run)
    }

    func testAtMostSixStartsInTheTrailing24Hours() {
        var inputs = self.ready()
        let hours: [TimeInterval] = [-23, -20, -10, -5, -2, -1]
        inputs.record.starts = hours.map { self.now.addingTimeInterval($0 * 3_600) }
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .wait(until: self.now.addingTimeInterval(3_600)), "the oldest of the six leaves the window in an hour")
        inputs.record.starts[0] = self.now.addingTimeInterval(-25 * 3_600)
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .run, "a start older than 24 h no longer counts")
        inputs.record.starts = (1 ... 6).map { self.now.addingTimeInterval(TimeInterval($0) * 60) }
        XCTAssertEqual(Policy.decide(inputs, now: self.now), .wait(until: self.now.addingTimeInterval(60 + 86_400)), "a clock set back does not free the limit")
        let record = SGAutoLinkRecord(starts: [self.now.addingTimeInterval(-90_000), self.now.addingTimeInterval(-60)]).recordingStart(at: self.now.addingTimeInterval(0.6))
        XCTAssertEqual(record.starts, [self.now.addingTimeInterval(-60), self.now], "pruned, whole seconds")
    }

    // MARK: - The schedule after an attempt

    func testTheLadderIsSixtySecondsToTwentyFourHoursEachPlusMinusTwentyPercent() {
        let expected: [TimeInterval] = [60, 300, 1_800, 7_200, 21_600, 86_400, 86_400, 86_400]
        for (index, base) in expected.enumerated() {
            let failures = index + 1
            XCTAssertEqual(Policy.ladderDelay(failures: failures, random: { 0.5 }), base, accuracy: 0.001, "failure \(failures)")
            XCTAssertEqual(Policy.ladderDelay(failures: failures, random: { 0 }), base * 0.8, accuracy: 0.001)
            XCTAssertEqual(Policy.ladderDelay(failures: failures, random: { 1 }), base * 1.2, accuracy: 0.001)
        }
        var record = SGAutoLinkRecord()
        for base in expected {
            record = Policy.next(after: .offline, attestOffered: false, record: record, install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 }).record
            XCTAssertEqual(record.nextAt, self.now.addingTimeInterval(base))
        }
        XCTAssertEqual(record.failures, expected.count)
        for outcome in [Policy.Outcome.telegramUnavailable(reason: "attest_no_main_app"), .expired, .notStored, .refused(code: "attest_invalid"), .refused(code: "bind_not_found")] {
            let next = Policy.next(after: outcome, attestOffered: true, record: SGAutoLinkRecord(failures: 1), install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
            XCTAssertEqual(next.record.failures, 2, "\(outcome)")
            XCTAssertEqual(next.record.nextAt, self.now.addingTimeInterval(300), "\(outcome)")
        }
    }

    func testALinkResetsTheFailuresAndTheInstallLadder() {
        let record = SGAutoLinkRecord(starts: [self.now], failures: 4, nextAt: self.now.addingTimeInterval(60), pausedUntil: self.now.addingTimeInterval(60))
        let install = SGAutoLinkInstallRecord(attestNull: 4, appVersion: "12.0.1", nextAt: self.now.addingTimeInterval(86_400))
        for outcome in [Policy.Outcome.linked, .alreadyLinked] {
            let next = Policy.next(after: outcome, attestOffered: false, record: record, install: install, now: self.now, random: { 0.5 })
            XCTAssertEqual(next.record.failures, 0)
            XCTAssertNil(next.record.nextAt)
            XCTAssertNil(next.record.pausedUntil)
            XCTAssertEqual(next.install, SGAutoLinkInstallRecord(attestNull: 0, appVersion: "12.0.1", nextAt: nil))
        }
    }

    func testBindConflictPausesTheAccountFor24Hours() {
        let next = Policy.next(after: .refused(code: "bind_conflict"), attestOffered: true, record: SGAutoLinkRecord(failures: 2), install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
        XCTAssertEqual(next.record.pausedUntil, self.now.addingTimeInterval(86_400))
        XCTAssertEqual(next.record.failures, 2)
        var inputs = self.ready()
        inputs.record = next.record
        XCTAssertEqual(Policy.decide(inputs, now: self.now.addingTimeInterval(86_399)), .wait(until: self.now.addingTimeInterval(86_400)))
    }

    func testRetryAfterWinsWhenLongerThanTheLadder() {
        let limited = Policy.next(after: .rateLimited(retryAfter: 900), attestOffered: false, record: SGAutoLinkRecord(), install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
        XCTAssertEqual(limited.record.nextAt, self.now.addingTimeInterval(900))
        XCTAssertEqual(limited.record.failures, 1)
        let short = Policy.next(after: .rateLimited(retryAfter: 5), attestOffered: false, record: SGAutoLinkRecord(failures: 2), install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
        XCTAssertEqual(short.record.nextAt, self.now.addingTimeInterval(1_800), "the ladder when it is longer")
        let paused = Policy.next(after: .paused(retryAfter: 7_200), attestOffered: false, record: SGAutoLinkRecord(), install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
        XCTAssertEqual(paused.record.nextAt, self.now.addingTimeInterval(7_200))
        let pausedBare = Policy.next(after: .paused(retryAfter: nil), attestOffered: false, record: SGAutoLinkRecord(), install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
        XCTAssertEqual(pausedBare.record.nextAt, self.now.addingTimeInterval(60))
    }

    func testAttestNullWaitsSixHoursAndThenTheInstallLadder() {
        var record = SGAutoLinkRecord()
        var install = SGAutoLinkInstallRecord(appVersion: "12.0.1")
        let expected: [TimeInterval?] = [nil, nil, 86_400, 3 * 86_400, 7 * 86_400, 7 * 86_400]
        for (index, ladder) in expected.enumerated() {
            let next = Policy.next(after: .attestUnavailable, attestOffered: false, record: record, install: install, now: self.now, random: { 0.5 })
            record = next.record
            install = next.install
            XCTAssertEqual(record.nextAt, self.now.addingTimeInterval(6 * 3_600), "the account waits 6 h")
            XCTAssertEqual(record.failures, 0, "not a ladder failure")
            XCTAssertEqual(install.attestNull, index + 1)
            XCTAssertEqual(install.nextAt, ladder.map { self.now.addingTimeInterval($0) }, "attest-null start \(index + 1)")
        }
        // Any start that offers an attest block resets the install ladder (even if /bind/attest then
        // answers attest_unavailable).
        let offered = Policy.next(after: .attestUnavailable, attestOffered: true, record: record, install: install, now: self.now, random: { 0.5 })
        XCTAssertEqual(offered.install, SGAutoLinkInstallRecord(attestNull: 0, appVersion: "12.0.1", nextAt: nil))
        let telegram = Policy.next(after: .telegramUnavailable(reason: "attest_bot_not_found"), attestOffered: true, record: record, install: install, now: self.now, random: { 0.5 })
        XCTAssertEqual(telegram.install.attestNull, 0)
        XCTAssertNil(telegram.install.nextAt)
        // So does a new app version.
        XCTAssertEqual(install.forAppVersion("12.0.1"), install)
        XCTAssertEqual(install.forAppVersion("12.1"), SGAutoLinkInstallRecord(attestNull: 0, appVersion: "12.1", nextAt: nil))
    }

    func testSupersededAndBindInProgressWaitFiveMinutesWithoutAFailure() {
        for outcome in [Policy.Outcome.superseded, .bindInProgress] {
            let next = Policy.next(after: outcome, attestOffered: false, record: SGAutoLinkRecord(failures: 3), install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
            XCTAssertEqual(next.record.nextAt, self.now.addingTimeInterval(300), "\(outcome)")
            XCTAssertEqual(next.record.failures, 3, "\(outcome)")
        }
    }

    func testStoppingOutcomesLeaveTheScheduleAlone() {
        let record = SGAutoLinkRecord(starts: [self.now.addingTimeInterval(-60)], failures: 2, nextAt: self.now.addingTimeInterval(-1))
        for outcome in [Policy.Outcome.consentStale, .notPermitted, .notConfigured] {
            let next = Policy.next(after: outcome, attestOffered: false, record: record, install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 })
            XCTAssertEqual(next.record.failures, 2, "\(outcome)")
            XCTAssertEqual(next.record.nextAt, record.nextAt, "\(outcome)")
        }
    }

    func testAnAttemptThatSentNothingGivesBackItsStart() {
        let begun = SGAutoLinkRecord(starts: [self.now.addingTimeInterval(-3_600)]).recordingStart(at: self.now)
        XCTAssertEqual(begun.starts.count, 2, "counted before the attempt")
        for outcome in [Policy.Outcome.alreadyLinked, .bindInProgress, .notPermitted, .notConfigured] {
            XCTAssertTrue(outcome.sentNothing)
            XCTAssertEqual(Policy.next(after: outcome, attestOffered: false, record: begun, install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 }).record.starts, [self.now.addingTimeInterval(-3_600)], "\(outcome)")
        }
        for outcome in [Policy.Outcome.linked, .offline, .consentStale, .superseded, .attestUnavailable, .refused(code: "bind_conflict")] {
            XCTAssertFalse(outcome.sentNothing)
            XCTAssertEqual(Policy.next(after: outcome, attestOffered: false, record: begun, install: SGAutoLinkInstallRecord(), now: self.now, random: { 0.5 }).record.starts.count, 2, "\(outcome)")
        }
    }

    // MARK: - Unlink suppression

    func testTheUnlinkSuppressionIsSetAndClearedByAManualLinkOrANewGrant() throws {
        let record = SGAutoLinkRecord(failures: 1).suppressingForUnlink()
        XCTAssertTrue(record.isSuppressed)
        XCTAssertEqual(record.suppressed, "user_unlink")
        XCTAssertEqual(record.jsonObject["suppressed"] as? String, "user_unlink")
        XCTAssertFalse(record.liftingSuppression().isSuppressed, "a manual link")
        XCTAssertEqual(record.liftingSuppression().failures, 1)

        // A new grant lifts it in the store (SGConsentStore.grant), keeping the rest of the record.
        let made = SGCustomerSyncTestFixtures.makeDefaults()
        defer {
            made.remove()
        }
        let store = SGConsentStore(defaults: made.defaults, isReadable: { true }, notify: { _ in })
        try store.setJSONObject(record.jsonObject, for: .autoLink(tg: self.tg, authority: self.authority)).get()
        XCTAssertTrue(SGAutoLinkRecord(jsonObject: store.jsonObject(.autoLink(tg: self.tg, authority: self.authority))).isSuppressed)
        let text = try XCTUnwrap(try SGCustomerSyncTestFixtures.repository().render(version: 1, locale: .uz, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
        _ = try store.grant(tg: self.tg, text: text, mode: .required, appVersion: "12.0.1", now: self.now).get()
        let afterGrant = SGAutoLinkRecord(jsonObject: store.jsonObject(.autoLink(tg: self.tg, authority: self.authority)))
        XCTAssertFalse(afterGrant.isSuppressed)
        XCTAssertEqual(afterGrant.failures, 1)
    }

    // MARK: - Stored records

    func testTheRecordsRoundTrip() {
        let record = SGAutoLinkRecord(starts: [self.now.addingTimeInterval(-60.5), self.now], failures: 3, nextAt: self.now.addingTimeInterval(300.9), pausedUntil: nil, suppressed: nil)
        XCTAssertEqual(Set(record.jsonObject.keys), ["v", "starts", "failures", "next_at"], "absent values are left out")
        XCTAssertEqual(record.jsonObject["v"] as? Int, 1)
        XCTAssertEqual(record.jsonObject["starts"] as? [String], ["2026-11-01T09:58:59Z", "2026-11-01T10:00:00Z"])
        XCTAssertEqual(record.jsonObject["next_at"] as? String, "2026-11-01T10:05:00Z")
        XCTAssertEqual(SGAutoLinkRecord(jsonObject: record.jsonObject), record)
        XCTAssertEqual(SGAutoLinkRecord(jsonObject: nil), SGAutoLinkRecord())
        // The shape the store tests write, and damaged fields.
        XCTAssertEqual(SGAutoLinkRecord(jsonObject: ["v": 1, "failures": 2, "suppressed": "user_unlink"]), SGAutoLinkRecord(failures: 2, suppressed: "user_unlink"))
        XCTAssertEqual(SGAutoLinkRecord(jsonObject: ["failures": "2", "starts": ["x"], "next_at": 5, "suppressed": "user_unlink"]), SGAutoLinkRecord(suppressed: "user_unlink"), "a damaged schedule keeps the suppression")

        let install = SGAutoLinkInstallRecord(attestNull: 3, appVersion: "12.0.1", nextAt: self.now)
        XCTAssertEqual(Set(install.jsonObject.keys), ["attest_null", "app_version", "next_at"])
        XCTAssertEqual(SGAutoLinkInstallRecord(jsonObject: install.jsonObject), install)
        XCTAssertEqual(SGAutoLinkInstallRecord(jsonObject: ["attest_null": 1]), SGAutoLinkInstallRecord(attestNull: 1))
        XCTAssertEqual(SGAutoLinkInstallRecord(jsonObject: nil), SGAutoLinkInstallRecord())
    }

    // MARK: - link.attempt

    func testEachAttemptReportsItsOutcomeAndErrorCode() throws {
        let cases: [(Policy.Outcome, String?)] = [
            (.attestUnavailable, "attest_unavailable"),
            (.refused(code: "bind_conflict"), "bind_conflict"),
            (.refused(code: "attest_invalid"), "attest_invalid"),
            (.refused(code: "attest_stale"), "attest_stale"),
            (.refused(code: "attest_mismatch"), "attest_mismatch"),
            (.refused(code: "bind_not_found"), "bind_not_found"),
            (.refused(code: "bind_expired"), "bind_expired"),
            (.refused(code: "bind_denied"), "unknown"),
            (.rateLimited(retryAfter: 60), "rate_limited"),
            (.paused(retryAfter: nil), "bind_paused"),
            (.consentStale, "consent_stale"),
            (.telegramUnavailable(reason: "attest_bot_not_found"), "attest_bot_not_found"),
            (.telegramUnavailable(reason: "attest_bot_mismatch"), "attest_bot_mismatch"),
            (.telegramUnavailable(reason: "attest_no_main_app"), "attest_no_main_app"),
            (.telegramUnavailable(reason: "attest_webview_failed"), "attest_webview_failed"),
            (.telegramUnavailable(reason: "attest_no_init_data"), "attest_no_init_data"),
            (.telegramUnavailable(reason: "timeout"), "timeout"),
            (.telegramUnavailable(reason: "+998901234567"), "unknown"),
            (.offline, "offline"),
            (.expired, "bind_expired"),
            (.notStored, "unknown"),
            (.superseded, "unknown"),
        ]
        for (outcome, code) in cases {
            let event = try XCTUnwrap(Policy.linkAttempt(outcome, durationS: 12), "\(outcome)")
            XCTAssertEqual(event, .linkAttempt(trigger: .auto, method: .attest, outcome: .failed, errorCode: code.flatMap(SGAnalyticsErrorCode.init), durationS: 12), "\(outcome)")
        }
        XCTAssertEqual(Policy.linkAttempt(.linked, durationS: 9), .linkAttempt(trigger: .auto, method: .attest, outcome: .success, errorCode: nil, durationS: 9))
        for outcome in [Policy.Outcome.alreadyLinked, .bindInProgress, .notPermitted, .notConfigured] {
            XCTAssertNil(Policy.linkAttempt(outcome, durationS: 0), "\(outcome): nothing was attempted")
        }
    }

    // MARK: - Helpers

    /// Every precondition holds: granted, unlinked, permitted, first idle passed two minutes ago.
    private func ready() -> Policy.Inputs {
        return Policy.Inputs(readable: true, state: .granted, bindPermissionAllowed: true, firstIdleAt: self.now.addingTimeInterval(-120), firstIdleJitter: 12)
    }
}
