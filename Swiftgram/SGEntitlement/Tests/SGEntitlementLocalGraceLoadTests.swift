import XCTest
@testable import SGEntitlement

/// Zenlygram — `SGEntitlement.resolveLocalGrace`: the local grace record is minted ONCE. A record
/// that merely could not be read (a launch before the first unlock after a reboot) is never
/// re-minted, never cached and never mirrored; the window is granted in memory for that one
/// evaluation (invariant I2) and the real record is read next time.
final class SGEntitlementLocalGraceLoadTests: XCTestCase {
    private let firstLaunch = Date(timeIntervalSince1970: 1790000000)
    private let day: TimeInterval = 86400

    private func encoded(_ grace: SGEntitlementLocalGrace) -> Data {
        return SGEntitlement.encodeLocalGrace(grace)
    }

    func test_aPresentRecordIsLoaded_neverReMinted() {
        let expired = SGEntitlementLocalGrace(firstLaunchAt: self.firstLaunch)
        let now = self.firstLaunch.addingTimeInterval(21 * self.day)
        var persisted = 0
        let load = SGEntitlement.resolveLocalGrace(read: .present(self.encoded(expired)), now: now, canMint: true, persist: { _ in
            persisted += 1
            return true
        })
        XCTAssertEqual(load.grace, expired)
        XCTAssertTrue(load.isVerified)
        XCTAssertEqual(load.persistedSeenAt, expired.lastSeenAt)
        XCTAssertEqual(persisted, 0, "an existing record is never rewritten by the load")
        XCTAssertFalse(load.grace!.isActive(at: now), "the trial that ended three weeks ago stays ended")
    }

    func test_anAbsentRecordIsMinted_onlyInTheMainApp_andOnlyOnceProvenPersisted() {
        let now = self.firstLaunch
        var written: SGEntitlementLocalGrace?
        let minted = SGEntitlement.resolveLocalGrace(read: .absent, now: now, canMint: true, persist: { grace in
            written = grace
            return true
        })
        XCTAssertEqual(written?.firstLaunchAt, now)
        XCTAssertEqual(minted.grace, written)
        XCTAssertTrue(minted.isVerified)
        XCTAssertEqual(minted.persistedSeenAt, now)

        // Extensions never mint; they read what the main app wrote.
        var extensionWrote = false
        let inExtension = SGEntitlement.resolveLocalGrace(read: .absent, now: now, canMint: false, persist: { _ in
            extensionWrote = true
            return true
        })
        XCTAssertNil(inExtension.grace)
        XCTAssertTrue(inExtension.isVerified)
        XCTAssertFalse(extensionWrote)

        // A write that does not verify proves nothing: the window is granted for this evaluation
        // and NOT counted as loaded, so the next evaluation mints again after the first unlock.
        let unproven = SGEntitlement.resolveLocalGrace(read: .absent, now: now, canMint: true, persist: { _ in false })
        XCTAssertEqual(unproven.grace?.firstLaunchAt, now)
        XCTAssertFalse(unproven.isVerified)
        XCTAssertNil(unproven.persistedSeenAt)
    }

    func test_anUnreadableRecordGrantsThisEvaluationOnly_andIsNeverMinted() {
        // Trial expired three weeks ago; the device rebooted; a VoIP push launched the app before the
        // first unlock, so the Keychain answers errSecInteractionNotAllowed. Nothing may be written
        // and nothing may be cached: the process must re-read after the unlock and find the expired
        // record, and the mirror must not carry seven fresh days to the extensions meanwhile.
        let now = self.firstLaunch.addingTimeInterval(21 * self.day)
        var persisted = 0
        let load = SGEntitlement.resolveLocalGrace(read: .unreadable(errSecInteractionNotAllowed), now: now, canMint: true, persist: { _ in
            persisted += 1
            return true
        })
        XCTAssertEqual(persisted, 0, "a locked Keychain is not an empty one")
        XCTAssertFalse(load.isVerified, "not loaded: the next evaluation retries the read")
        XCTAssertNil(load.persistedSeenAt)
        XCTAssertNotNil(load.grace, "fail toward the user for this one evaluation (invariant I2)")

        let inExtension = SGEntitlement.resolveLocalGrace(read: .unreadable(errSecInteractionNotAllowed), now: now, canMint: false, persist: { _ in true })
        XCTAssertNil(inExtension.grace)
        XCTAssertFalse(inExtension.isVerified)
    }

    func test_anUndecodableRecordIsReplaced() {
        var written: SGEntitlementLocalGrace?
        let load = SGEntitlement.resolveLocalGrace(read: .present(Data("garbage".utf8)), now: self.firstLaunch, canMint: true, persist: { grace in
            written = grace
            return true
        })
        XCTAssertEqual(load.grace, written)
        XCTAssertTrue(load.isVerified)
    }

    // MARK: - D9: the paid-policy mark, the second minted-once record, follows the same rules

    private func encodedMark(_ mark: SGEntitlementPaidModeMark) -> Data {
        return SGEntitlement.encodePaidModeMark(mark)
    }

    func test_aPresentMarkIsLoaded_neverReMinted() {
        // The owner flipped paid a year after this install's first launch; a month later (after a
        // free -> paid -> free -> paid round trip, say) the record is read, never rewritten.
        let flip = self.firstLaunch.addingTimeInterval(365 * self.day)
        var persisted = 0
        let load = SGEntitlement.resolvePaidModeMark(read: .present(self.encodedMark(SGEntitlementPaidModeMark(firstPaidPolicyAt: flip))), now: flip.addingTimeInterval(30 * self.day), canMint: true, persist: { _ in
            persisted += 1
            return true
        })
        XCTAssertEqual(load.firstPaidPolicyAt, flip)
        XCTAssertTrue(load.isVerified)
        XCTAssertEqual(persisted, 0, "a later free -> paid flip re-bases nothing: the record is never rewritten")
    }

    func test_anAbsentMarkIsMinted_onlyInTheMainApp_andOnlyOnceProvenPersisted() {
        let now = self.firstLaunch.addingTimeInterval(365 * self.day)
        var written: SGEntitlementPaidModeMark?
        let minted = SGEntitlement.resolvePaidModeMark(read: .absent, now: now, canMint: true, persist: { mark in
            written = mark
            return true
        })
        XCTAssertEqual(written?.firstPaidPolicyAt, now)
        XCTAssertEqual(minted.firstPaidPolicyAt, now)
        XCTAssertTrue(minted.isVerified)

        // Extensions never mint; they read what the main app wrote.
        var extensionWrote = false
        let inExtension = SGEntitlement.resolvePaidModeMark(read: .absent, now: now, canMint: false, persist: { _ in
            extensionWrote = true
            return true
        })
        XCTAssertNil(inExtension.firstPaidPolicyAt)
        XCTAssertTrue(inExtension.isVerified)
        XCTAssertFalse(extensionWrote)

        // A write that does not verify proves nothing: the re-based window is granted for this
        // evaluation and NOT counted as loaded, so the next evaluation mints again after the unlock.
        let unproven = SGEntitlement.resolvePaidModeMark(read: .absent, now: now, canMint: true, persist: { _ in false })
        XCTAssertEqual(unproven.firstPaidPolicyAt, now)
        XCTAssertFalse(unproven.isVerified)
    }

    func test_anUnreadableMarkGrantsThisEvaluationOnly_andIsNeverMinted() {
        let now = self.firstLaunch.addingTimeInterval(365 * self.day)
        var persisted = 0
        let load = SGEntitlement.resolvePaidModeMark(read: .unreadable(errSecInteractionNotAllowed), now: now, canMint: true, persist: { _ in
            persisted += 1
            return true
        })
        XCTAssertEqual(persisted, 0, "a locked Keychain is not an empty one")
        XCTAssertFalse(load.isVerified, "not loaded: the next evaluation retries the read")
        XCTAssertEqual(load.firstPaidPolicyAt, now, "fail toward the user for this one evaluation (invariant I2)")

        let inExtension = SGEntitlement.resolvePaidModeMark(read: .unreadable(errSecInteractionNotAllowed), now: now, canMint: false, persist: { _ in true })
        XCTAssertNil(inExtension.firstPaidPolicyAt)
        XCTAssertFalse(inExtension.isVerified)
    }

    func test_anUndecodableMarkIsReplaced_andAMarkRoundTrips() throws {
        var written: SGEntitlementPaidModeMark?
        let load = SGEntitlement.resolvePaidModeMark(read: .present(Data("garbage".utf8)), now: self.firstLaunch, canMint: true, persist: { mark in
            written = mark
            return true
        })
        XCTAssertEqual(load.firstPaidPolicyAt, written?.firstPaidPolicyAt)
        XCTAssertTrue(load.isVerified)

        let mark = SGEntitlementPaidModeMark(firstPaidPolicyAt: self.firstLaunch)
        XCTAssertEqual(try JSONDecoder().decode(SGEntitlementPaidModeMark.self, from: self.encodedMark(mark)), mark)
    }
}
