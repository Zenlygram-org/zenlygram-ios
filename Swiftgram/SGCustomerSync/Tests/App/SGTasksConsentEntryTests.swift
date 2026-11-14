// App-side only (see SGCustomerSyncConfigTests.swift): compiles to nothing in `run-core-tests.sh`.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
import SGTasks
@testable import SGCustomerSync
@testable import SGCustomerSyncCore

/// Zenlygram — the Tasks consent hooks (wf15 §6, D1): `SGCustomerSync.start` installs
/// `SGTasksConsentEntry.installed` (Tasks never imports this module, F3); a required build — and an
/// inactive pipeline, which is what this test process has — never prompts from Tasks; an optional
/// build's first prompt waits for the first open of Vazifalar and goes up at most once per attach
/// (`SGConsentWallPresenter.optionalPromptTiming` over the pure `SGOptionalPromptTiming`).
final class SGTasksConsentEntryTests: XCTestCase {
    private typealias Kind = SGConsentWallViewModel.Kind

    override func tearDown() {
        SGTasksConsentEntry.installed = nil
        super.tearDown()
    }

    // MARK: - The hooks

    func test_startInstallsTheThreeHooks() {
        SGTasksConsentEntry.installed = nil
        SGCustomerSync.shared.installTasksConsentEntry()
        XCTAssertNotNil(SGTasksConsentEntry.installed, "the `.active` branch of `start` installs the entry")
        XCTAssertEqual(SGTasksConsentEntry.dataConsentFallbackURL, "tg://sg/settings?row=dataConsent", "the route the line opens with no hook (§6.1)")
    }

    func test_aBuildThatDoesNotPromptOptionallyNeverPromptsFromTasks() {
        // This process has no active pipeline (`consentMode` nil), the same answer as a required build:
        // false, and no entry is armed.
        XCTAssertNotEqual(SGCustomerSync.shared.consentMode, .optional)
        XCTAssertFalse(SGCustomerSync.shared.tasksPromptIfUndecided(accountPeerId: 1))
        XCTAssertFalse(SGCustomerSync.shared.isWallPresented(accountPeerId: 1))
    }

    func test_anAccountWhoseRootIsNotAttachedHasNothingToArm() {
        let presenter = SGConsentWallPresenter()
        XCTAssertFalse(presenter.armFirstPrompt(accountPeerId: 42))
        XCTAssertFalse(presenter.isWallPresented(accountPeerId: 42))
    }

    // MARK: - The armed prompt (optional mode)

    func test_theFirstPromptWaitsForVazifalarAndIsShownOnce() {
        // Attach: `.prompt(.none)` for state `none`, not armed → nothing, still pending.
        let attach = SGConsentWallPresenter.optionalPromptTiming(kind: .prompt(.none), isWallUp: false, armed: false, decided: false)
        XCTAssertNil(attach.kind)
        XCTAssertFalse(attach.decided)
        // Vazifalar opens → armed → the prompt, decided for this attach.
        let opened = SGConsentWallPresenter.optionalPromptTiming(kind: .prompt(.none), isWallUp: false, armed: true, decided: attach.decided)
        XCTAssertEqual(opened.kind, Kind.prompt(.none))
        XCTAssertTrue(opened.decided)
        // While it is up the model is updated, never re-decided.
        let up = SGConsentWallPresenter.optionalPromptTiming(kind: .prompt(.none), isWallUp: true, armed: true, decided: opened.decided)
        XCTAssertEqual(up.kind, Kind.prompt(.none))
        XCTAssertTrue(up.decided)
        // Gone undecided (taken down by something else), a second open: never two per attach.
        let again = SGConsentWallPresenter.optionalPromptTiming(kind: .prompt(.none), isWallUp: false, armed: true, decided: opened.decided)
        XCTAssertNil(again.kind)
        XCTAssertTrue(again.decided)
    }

    func test_theOtherPromptsKeepTheAttachTiming() {
        for notice in [SGConsentWallNotice.reconsent, .operatorChanged, .linkEnded] {
            let attach = SGConsentWallPresenter.optionalPromptTiming(kind: .prompt(notice), isWallUp: false, armed: false, decided: false)
            XCTAssertEqual(attach.kind, Kind.prompt(notice), "\(notice) at attach")
            XCTAssertTrue(attach.decided)
            let later = SGConsentWallPresenter.optionalPromptTiming(kind: .prompt(notice), isWallUp: false, armed: true, decided: attach.decided)
            XCTAssertNil(later.kind, "\(notice): not twice per attach")
        }
    }

    func test_nothingToAskDecidesTheAttachAndADeclineShowsNothingOnTheNextOpen() {
        // Granted / declined / withdrawn: `.none` presentation → nothing, decided.
        let granted = SGConsentWallPresenter.optionalPromptTiming(kind: nil, isWallUp: false, armed: false, decided: false)
        XCTAssertNil(granted.kind)
        XCTAssertTrue(granted.decided)
        // A decline from the one prompt: the policy answers `.none` from then on — the device-only board
        // with its one footer line, no prompt at the next open (§6.2).
        let shown = SGConsentWallPresenter.optionalPromptTiming(kind: .prompt(.none), isWallUp: false, armed: true, decided: false)
        XCTAssertEqual(shown.kind, Kind.prompt(.none))
        let declined = SGConsentWallPresenter.optionalPromptTiming(kind: nil, isWallUp: false, armed: true, decided: shown.decided)
        XCTAssertNil(declined.kind)
        XCTAssertTrue(declined.decided)
    }

    func test_aWallKindIsNeverTimedAway() {
        // Not asked of an optional build by the policy; if it ever were, the timing would not hide it.
        let wall = SGConsentWallPresenter.optionalPromptTiming(kind: .wall(.deleted), isWallUp: false, armed: false, decided: true)
        XCTAssertEqual(wall.kind, Kind.wall(.deleted))
        XCTAssertTrue(wall.decided)
    }
}
#endif
