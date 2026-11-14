import XCTest
@testable import SGEntitlement

final class SGEntitlementClockTests: XCTestCase {
    private let serverTime = Date(timeIntervalSince1970: 1790000000)

    func test_withNoMark_effectiveNowIsTheWallClock() {
        let wall = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(SGEntitlementClock.effectiveNow(mark: nil, wallClock: wall, uptime: 10), wall)
    }

    func test_settingTheClockBackwardsBuysNothing() {
        let mark = SGEntitlementClockMark(serverTime: self.serverTime, uptime: 1000, bootTime: self.serverTime.addingTimeInterval(-1000))
        // The user winds the wall clock back a year. Winding it back also moves the DERIVED boot time,
        // so the same-boot check fails and the mark itself becomes the floor — which is the whole
        // point: the result is never earlier than the highest server time we have ever seen.
        let wall = self.serverTime.addingTimeInterval(-365 * 86400)
        let effective = SGEntitlementClock.effectiveNow(mark: mark, wallClock: wall, uptime: 1000 + 3600)
        XCTAssertGreaterThanOrEqual(effective, self.serverTime)
        XCTAssertEqual(effective, self.serverTime)
    }

    func test_withinOneBootTheUptimeDeltaAdvancesTheMark() {
        let mark = SGEntitlementClockMark(serverTime: self.serverTime, uptime: 1000, bootTime: self.serverTime.addingTimeInterval(-1000))
        // Same boot session, wall clock untouched, one hour of uptime later.
        let wall = self.serverTime.addingTimeInterval(3600)
        let effective = SGEntitlementClock.effectiveNow(mark: mark, wallClock: wall, uptime: 1000 + 3600)
        XCTAssertEqual(effective.timeIntervalSince1970, self.serverTime.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 1.0)
    }

    func test_settingTheClockForwardsOnlyExpiresSooner() {
        let mark = SGEntitlementClockMark(serverTime: self.serverTime, uptime: 1000, bootTime: self.serverTime.addingTimeInterval(-1000))
        let wall = self.serverTime.addingTimeInterval(365 * 86400)
        XCTAssertEqual(SGEntitlementClock.effectiveNow(mark: mark, wallClock: wall, uptime: 1000), wall)
    }

    func test_afterARebootTheMarkItselfIsTheFloor() {
        // A different boot session: the uptime delta is meaningless, so only the mark survives.
        let mark = SGEntitlementClockMark(serverTime: self.serverTime, uptime: 90000, bootTime: self.serverTime.addingTimeInterval(-90000))
        let wall = self.serverTime.addingTimeInterval(-86400)
        let effective = SGEntitlementClock.effectiveNow(mark: mark, wallClock: wall, uptime: 30)
        XCTAssertEqual(effective, self.serverTime)
    }

    func test_sleepOnlyUnderCountsElapsedTime_whichErrsTowardThePayingUser() {
        // systemUptime stalls while the device sleeps: the monotonic branch can only lag reality.
        let mark = SGEntitlementClockMark(serverTime: self.serverTime, uptime: 1000, bootTime: self.serverTime.addingTimeInterval(-1000))
        let effective = SGEntitlementClock.effectiveNow(mark: mark, wallClock: self.serverTime.addingTimeInterval(-10), uptime: 1010)
        XCTAssertLessThanOrEqual(effective.timeIntervalSince1970, self.serverTime.addingTimeInterval(10).timeIntervalSince1970)
    }

    func test_timestampsParseExactlyTheServersFormat() {
        XCTAssertEqual(SGEntitlementTimestamp.parse("2026-10-01T12:00:00Z")?.timeIntervalSince1970, 1790856000)
        XCTAssertNil(SGEntitlementTimestamp.parse("2026-10-01 12:00:00"))
        XCTAssertNil(SGEntitlementTimestamp.parse(""))
        // Forward compatible, in case a future server starts emitting fractional seconds.
        XCTAssertNotNil(SGEntitlementTimestamp.parse("2026-10-01T12:00:00.250Z"))
    }
}
