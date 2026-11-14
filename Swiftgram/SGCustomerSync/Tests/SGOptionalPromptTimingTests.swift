import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the optional build's prompt timing (wf15 §6.2, D1): the account's first prompt
/// waits for the first open of Vazifalar and is shown at most once per attach; the other prompts
/// keep the attach timing; required mode never reaches this rule (its wall is decided by the policy).
final class SGOptionalPromptTimingTests: XCTestCase {
    private typealias Timing = SGOptionalPromptTiming

    // MARK: - The first prompt (state `none`)

    func testTheFirstPromptIsNotShownAtAttach() {
        // Attach: not armed, nothing decided yet → nothing on screen, and the prompt stays pending.
        XCTAssertEqual(Timing.decide(ask: .firstPrompt, armed: false, decided: false), Timing.Outcome(shows: false, decided: false))
        XCTAssertFalse(Timing.shouldShow(armed: false, decided: false, kindIsFirstPrompt: true))
    }

    func testTheFirstPromptIsShownOnceVazifalarIsOpened() {
        // armFirstPrompt → evaluate: shown, and from then on decided for this attach.
        XCTAssertEqual(Timing.decide(ask: .firstPrompt, armed: true, decided: false), Timing.Outcome(shows: true, decided: true))
        XCTAssertTrue(Timing.shouldShow(armed: true, decided: false, kindIsFirstPrompt: true))
    }

    func testTheFirstPromptIsNeverShownTwiceInOneAttach() {
        // A second evaluation while armed (a store change, foreground, a second open of Vazifalar
        // after the prompt went away undecided): not again.
        XCTAssertEqual(Timing.decide(ask: .firstPrompt, armed: true, decided: true), Timing.Outcome(shows: false, decided: true))
        XCTAssertFalse(Timing.shouldShow(armed: true, decided: true, kindIsFirstPrompt: true))
        // Not armed but decided (another prompt of this attach was already decided): not now either.
        XCTAssertEqual(Timing.decide(ask: .firstPrompt, armed: false, decided: true), Timing.Outcome(shows: false, decided: true))
    }

    func testRepeatedEvaluationsBeforeArmingKeepThePromptPending() {
        var decided = false
        for _ in 0..<5 {
            let outcome = Timing.decide(ask: .firstPrompt, armed: false, decided: decided)
            XCTAssertFalse(outcome.shows)
            decided = outcome.decided
        }
        XCTAssertFalse(decided, "the attach evaluations never decide the first prompt")
        let opened = Timing.decide(ask: .firstPrompt, armed: true, decided: decided)
        XCTAssertEqual(opened, Timing.Outcome(shows: true, decided: true))
        XCTAssertEqual(Timing.decide(ask: .firstPrompt, armed: true, decided: opened.decided).shows, false)
    }

    // MARK: - The other prompts keep the attach timing

    func testAnotherPromptIsShownAtAttachWhetherArmedOrNot() {
        for armed in [false, true] {
            XCTAssertEqual(Timing.decide(ask: .otherPrompt, armed: armed, decided: false), Timing.Outcome(shows: true, decided: true), "armed \(armed)")
            XCTAssertTrue(Timing.shouldShow(armed: armed, decided: false, kindIsFirstPrompt: false), "armed \(armed)")
        }
    }

    func testAnotherPromptIsNotShownTwiceInOneAttach() {
        for armed in [false, true] {
            XCTAssertEqual(Timing.decide(ask: .otherPrompt, armed: armed, decided: true), Timing.Outcome(shows: false, decided: true), "armed \(armed)")
            XCTAssertFalse(Timing.shouldShow(armed: armed, decided: true, kindIsFirstPrompt: false), "armed \(armed)")
        }
    }

    // MARK: - Nothing to ask

    func testNothingToAskDecidesTheAttach() {
        // Granted and usable, declined, withdrawn, the deleted notice: the attach's one prompt is
        // decided (a later change never prompts at once, as before), armed or not.
        for armed in [false, true] {
            for decided in [false, true] {
                XCTAssertEqual(Timing.decide(ask: .nothing, armed: armed, decided: decided), Timing.Outcome(shows: false, decided: true), "armed \(armed) decided \(decided)")
            }
        }
    }

    /// Optional mode, a decline from the one prompt: the next evaluations ask nothing, and a later
    /// open of Vazifalar shows nothing — the device-only board with its one footer line (§6.2).
    func testADeclineLeavesNothingToShowOnTheNextOpen() {
        let shown = Timing.decide(ask: .firstPrompt, armed: true, decided: false)
        XCTAssertTrue(shown.shows)
        // Declined → the policy answers `.none`.
        let afterDecline = Timing.decide(ask: .nothing, armed: true, decided: shown.decided)
        XCTAssertEqual(afterDecline, Timing.Outcome(shows: false, decided: true))
        XCTAssertFalse(Timing.decide(ask: .nothing, armed: true, decided: afterDecline.decided).shows)
    }
}
