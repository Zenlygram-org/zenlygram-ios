import XCTest
import SGEntitlement
@testable import SGAppUpdateUI

// The override is compiled into non-store builds only (`SG_APP_UPDATE_DEBUG_OVERRIDE`, debug_override.bzl); a test
// bundle built with a store configuration has nothing to test here.
#if SG_APP_UPDATE_DEBUG_OVERRIDE

/// Zenlygram — the QA override of the app-update decision (update_policy_spec §4h): the three values, read by
/// non-store builds only, replacing the decision and nothing else.
final class SGAppUpdateDebugOverrideTests: XCTestCase {
    private let real: SGAppUpdateDecision = .block(SGAppUpdateVersions(min: SGAppUpdateVersion("12.9.2")!, latest: SGAppUpdateVersion("12.10.0")!)!)

    func test_theThreeValuesAreReadByANonStoreBuild_trimmedAndCaseInsensitive() {
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "none", isAppStoreBuild: false), .none)
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "remind", isAppStoreBuild: false), .remind)
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "block", isAppStoreBuild: false), .block)
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: " Block\n", isAppStoreBuild: false), .block, "`defaults write` output is forgiven its case and whitespace")
    }

    func test_anythingElseIsNoOverride() {
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: nil, isAppStoreBuild: false), .none)
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "", isAppStoreBuild: false), .none)
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "blocked", isAppStoreBuild: false), .none)
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "1", isAppStoreBuild: false), .none)
    }

    func test_aStoreBuildNeverReadsIt() {
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "block", isAppStoreBuild: true), .none)
        XCTAssertEqual(SGAppUpdateDebugOverride.resolve(raw: "remind", isAppStoreBuild: true), .none)
    }

    func test_noneLeavesTheSignedDecisionAlone_theOthersReplaceIt() {
        XCTAssertEqual(SGAppUpdateDebugOverride.none.apply(to: self.real), self.real)
        XCTAssertEqual(SGAppUpdateDebugOverride.none.apply(to: .none), .none)
        XCTAssertEqual(SGAppUpdateDebugOverride.remind.apply(to: .none), .remind(latest: SGAppUpdateVersion("99.0")!))
        XCTAssertEqual(SGAppUpdateDebugOverride.remind.apply(to: self.real), .remind(latest: SGAppUpdateVersion("99.0")!), "a signed block is overridden too — QA asked for the reminder")
        XCTAssertEqual(SGAppUpdateDebugOverride.block.apply(to: .none), .block(SGAppUpdateVersions(min: SGAppUpdateVersion("99.0")!, latest: SGAppUpdateVersion("99.0")!)!))
    }

    func test_thePretendVersionIsAboveAnyShippedOne() {
        XCTAssertGreaterThan(SGAppUpdateDebugOverride.version, SGAppUpdateVersion("12.9.2")!, "versions.json's app version")
        XCTAssertGreaterThan(SGAppUpdateDebugOverride.version, SGAppUpdateVersion("13.1.3")!)
    }
}

#endif
