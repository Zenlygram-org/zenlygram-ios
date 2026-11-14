import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the wall decision table (design 40 §4.6) in both modes, the wall's text locale
/// (§4.2), and the per-account gate the decision feeds (§6.4).
final class SGConsentWallPolicyTests: XCTestCase {
    private let recordHash = String(repeating: "a", count: 64)
    private let changedHash = String(repeating: "b", count: 64)

    // MARK: - Rows 1–2

    func testAnUnreadableStoreDefersInBothModes() {
        for mode in SGConsentMode.allCases {
            for state in SGConsentState.allCases {
                XCTAssertEqual(self.decide(mode, state, readable: false, deletedNotice: true, linkEnded: true), SGConsentWallDecision(presentation: .deferred), "\(mode) \(state)")
            }
        }
    }

    func testTheDeletedNotice() {
        for state in SGConsentState.allCases {
            XCTAssertEqual(self.decide(.required, state, deletedNotice: true), SGConsentWallDecision(presentation: .wall(.deleted)), state.rawValue)
            XCTAssertEqual(self.decide(.optional, state, deletedNotice: true), SGConsentWallDecision(presentation: .none), state.rawValue)
        }
    }

    // MARK: - Rows 3–7 (granted)

    func testALinkTheServerEndedAsksAgain() {
        XCTAssertEqual(self.decide(.required, .granted, linkEnded: true), SGConsentWallDecision(presentation: .wall(.linkEnded), normalise: .linkEnded))
        XCTAssertEqual(self.decide(.optional, .granted, linkEnded: true), SGConsentWallDecision(presentation: .prompt(.linkEnded), normalise: .linkEnded))
        // Row 3 wins over a retired version and an operator change.
        XCTAssertEqual(self.decide(.required, .granted, version: 1, minimum: 2, rendered: self.changedHash, rejection: "consent_version_retired", linkEnded: true).normalise, .linkEnded)
    }

    func testARetiredBundleShowsNoText() {
        XCTAssertEqual(self.decide(.required, .granted, version: 2, current: 2, rejection: "consent_version_retired"), SGConsentWallDecision(presentation: .textUnavailable))
        XCTAssertEqual(self.decide(.required, .granted, version: 3, current: 2, rejection: "consent_version_retired"), SGConsentWallDecision(presentation: .textUnavailable))
        XCTAssertEqual(self.decide(.optional, .granted, version: 2, current: 2, rejection: "consent_version_retired"), SGConsentWallDecision(presentation: .none))
    }

    func testARetiredGrantAsksAgainWithTheBundledText() {
        // The server retired the granted version and this build bundles a newer one.
        XCTAssertEqual(self.decide(.required, .granted, version: 1, current: 2, rejection: "consent_version_retired"), SGConsentWallDecision(presentation: .wall(.reconsent), normalise: .reconsent))
        XCTAssertEqual(self.decide(.optional, .granted, version: 1, current: 2, rejection: "consent_version_retired"), SGConsentWallDecision(presentation: .prompt(.reconsent), normalise: .reconsent))
        // The bundle's own minimum is above the granted version.
        XCTAssertEqual(self.decide(.required, .granted, version: 1, current: 2, minimum: 2), SGConsentWallDecision(presentation: .wall(.reconsent), normalise: .reconsent))
        XCTAssertEqual(self.decide(.optional, .granted, version: 1, current: 2, minimum: 2), SGConsentWallDecision(presentation: .prompt(.reconsent), normalise: .reconsent))
    }

    func testChangedOperatorValuesAskAgain() {
        XCTAssertEqual(self.decide(.required, .granted, rendered: self.changedHash), SGConsentWallDecision(presentation: .wall(.operatorChanged), normalise: .operatorChanged))
        XCTAssertEqual(self.decide(.optional, .granted, rendered: self.changedHash), SGConsentWallDecision(presentation: .prompt(.operatorChanged), normalise: .operatorChanged))
        XCTAssertEqual(self.decide(.required, .granted, rendered: self.recordHash), SGConsentWallDecision(presentation: .none))
        XCTAssertEqual(self.decide(.required, .granted, rendered: nil), SGConsentWallDecision(presentation: .none), "a version this build does not bundle is not compared")
    }

    func testAGrantWithAnotherRejectionStaysUsable() {
        for rejection in [nil, "consent_text_mismatch", "consent_scopes_mismatch", "consent_age_required", "consent_version_unknown", "consent_id_mismatch"] {
            for mode in SGConsentMode.allCases {
                XCTAssertEqual(self.decide(mode, .granted, rendered: self.recordHash, rejection: rejection), SGConsentWallDecision(presentation: .none), "\(mode) \(rejection ?? "none")")
            }
        }
    }

    // MARK: - Rows 8–10

    func testNoDecisionYet() {
        XCTAssertEqual(self.decide(.required, .none), SGConsentWallDecision(presentation: .wall(.none)))
        XCTAssertEqual(self.decide(.optional, .none), SGConsentWallDecision(presentation: .prompt(.none)))
        XCTAssertEqual(SGConsentWallPolicy.decide(self.inputs(.required, record: nil)), SGConsentWallDecision(presentation: .wall(.none)), "no record = none")
        XCTAssertEqual(self.decide(.required, .declined), SGConsentWallDecision(presentation: .wall(.none)), "a legacy declined in a required build")
        XCTAssertEqual(self.decide(.optional, .declined), SGConsentWallDecision(presentation: .none), "a declined account is not asked again")
    }

    func testWithdrawals() {
        XCTAssertEqual(self.decide(.required, .withdrawn), SGConsentWallDecision(presentation: .wall(.withdrawn)))
        XCTAssertEqual(self.decide(.required, .withdrawnRemote), SGConsentWallDecision(presentation: .wall(.withdrawnRemote)))
        XCTAssertEqual(self.decide(.optional, .withdrawn), SGConsentWallDecision(presentation: .none))
        XCTAssertEqual(self.decide(.optional, .withdrawnRemote), SGConsentWallDecision(presentation: .none))
    }

    func testNeedsReconsentShowsItsStoredNotice() {
        let expected: [(SGConsentStoredNotice?, SGConsentWallNotice)] = [(.reconsent, .reconsent), (.operatorChanged, .operatorChanged), (.linkEnded, .linkEnded), (nil, .reconsent)]
        for (stored, notice) in expected {
            XCTAssertEqual(self.decide(.required, .needsReconsent, notice: stored), SGConsentWallDecision(presentation: .wall(notice)))
            XCTAssertEqual(self.decide(.optional, .needsReconsent, notice: stored), SGConsentWallDecision(presentation: .prompt(notice)))
        }
    }

    // MARK: - The wall's text locale (design 40 §4.2)

    func testTheWallLocale() {
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "uz"), .uz)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "ru"), .ru)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "en"), .en)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "uz-raw"), .uz)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "ru-RU"), .ru)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "en_GB"), .en)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "EN"), .en)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "de"), .uz)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: "pt-br"), .uz)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: ""), .uz)
        XCTAssertEqual(SGConsentLocale.forWall(languageCode: nil), .uz)
    }

    // MARK: - SGCustomerDataGate (design 40 §6.4)

    func testTheGateStartsInactiveAndEmptyAndPostsOnlyOnChange() {
        var posts: [Int64?] = []
        let gate = SGCustomerDataGate(post: { posts.append($0) })
        XCTAssertFalse(gate.isPipelineActive)
        XCTAssertEqual(gate.clearance(accountPeerId: 42), [])

        gate.setPipelineActive(true)
        gate.setPipelineActive(true)
        XCTAssertTrue(gate.isPipelineActive)
        XCTAssertEqual(posts, [nil], "a pipeline change concerns every account")

        gate.publish([.recordEvents, .uploadProfile, .uploadEvents, .tasksSync], accountPeerId: 42)
        gate.publish([.recordEvents, .uploadProfile, .uploadEvents, .tasksSync], accountPeerId: 42)
        gate.publish([.recordEvents], accountPeerId: 7)
        XCTAssertEqual(gate.clearance(accountPeerId: 42), [.recordEvents, .uploadProfile, .uploadEvents, .tasksSync])
        XCTAssertTrue(gate.clearance(accountPeerId: 42).contains(.tasksSync))
        XCTAssertEqual(gate.clearance(accountPeerId: 7), .recordEvents)
        XCTAssertEqual(posts, [nil, 42, 7])

        gate.publish([], accountPeerId: 42)
        gate.publish([], accountPeerId: 42)
        gate.publish([], accountPeerId: 99)
        XCTAssertEqual(gate.clearance(accountPeerId: 42), [])
        XCTAssertEqual(posts, [nil, 42, 7, 42], "clearing posts once; an account never published stays silent")

        gate.setPipelineActive(false)
        XCTAssertEqual(posts, [nil, 42, 7, 42, nil])
    }

    func testTheGateNotificationCarriesTheAccount() {
        final class Received {
            var userInfos: [[AnyHashable: Any]?] = []
        }
        let gate = SGCustomerDataGate()
        let received = Received()
        let observer = NotificationCenter.default.addObserver(forName: SGCustomerDataGate.didChangeNotification, object: nil, queue: nil) { notification in
            received.userInfos.append(notification.userInfo)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }
        gate.publish(.recordEvents, accountPeerId: 4_294_967_337)
        gate.setPipelineActive(true)
        XCTAssertEqual(received.userInfos.count, 2)
        XCTAssertEqual(received.userInfos.first??[SGCustomerDataGate.accountPeerIdKey] as? Int64, 4_294_967_337)
        XCTAssertNil(received.userInfos.last ?? nil)
    }

    // MARK: - Helpers

    private func decide(
        _ mode: SGConsentMode,
        _ state: SGConsentState,
        readable: Bool = true,
        version: Int = 1,
        current: Int = 1,
        minimum: Int = 1,
        rendered: String? = String(repeating: "a", count: 64),
        rejection: String? = nil,
        notice: SGConsentStoredNotice? = nil,
        deletedNotice: Bool = false,
        linkEnded: Bool = false
    ) -> SGConsentWallDecision {
        let record = SGConsentRecord(tgUserId: 555000111, state: state, consentId: SGCustomerTime.uuid4(), textVersion: version, textSha256: self.recordHash, locale: .uz, consentMode: mode, decidedAt: "2026-11-01T09:00:00Z")
        var inputs = self.inputs(mode, record: state == SGConsentState.none ? nil : record)
        inputs.readable = readable
        inputs.bundledCurrentVersion = current
        inputs.bundledMinValidVersion = minimum
        inputs.renderedSha256ForRecord = rendered
        inputs.latestGrantRejection = rejection
        inputs.storedNotice = notice
        inputs.deletedNotice = deletedNotice
        inputs.linkEnded = linkEnded
        return SGConsentWallPolicy.decide(inputs)
    }

    private func inputs(_ mode: SGConsentMode, record: SGConsentRecord?) -> SGConsentWallInputs {
        return SGConsentWallInputs(mode: mode, readable: true, record: record, storedNotice: nil, bundledCurrentVersion: 1, bundledMinValidVersion: 1, renderedSha256ForRecord: nil, latestGrantRejection: nil, linkEnded: false, deletedNotice: false)
    }
}
