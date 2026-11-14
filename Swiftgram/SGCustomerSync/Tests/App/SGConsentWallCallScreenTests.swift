// App-side only (see SGCustomerSyncConfigTests.swift): compiles to nothing in `run-core-tests.sh`.
#if canImport(SGCustomerSync)
import Foundation
import XCTest
@testable import SGCustomerSync

/// Zenlygram — Telegram's call screens stay above the consent wall (design 40 §5.1; the final review's finding on
/// `SGConsentWallPresenter.swift`, where the wall goes up). The wall is a global overlay of the account root, so a call
/// screen Telegram pushes (flat modal) or shows as a `.calls` overlay lands under it: no mute, video or hang-up until
/// the user decides. `SGCallScreenPlacement` sends a call screen above the wall instead, and the presenter brings a call
/// under way back above a wall it has just put up. Plain objects stand in for the root's controllers: the placement
/// reads only who is where, bottom to top.
final class SGConsentWallCallScreenTests: XCTestCase {
    private let tabs = NSObject()
    private let chat = NSObject()
    private let wall = NSObject()
    private let call = NSObject()
    private let toast = NSObject()
    private let menu = NSObject()

    private func placement(wall: AnyObject?, stack: [AnyObject], overlays: [AnyObject] = [], globalOverlays: [AnyObject] = []) -> SGCallScreenPlacement {
        return SGCallScreenPlacement(of: self.call, wall: wall, stack: stack, overlays: overlays, globalOverlays: globalOverlays)
    }

    func test_withoutAWallTelegramShowsTheCallScreenItsOwnWay() {
        XCTAssertEqual(self.placement(wall: nil, stack: [self.tabs]), .telegram)
        XCTAssertEqual(self.placement(wall: nil, stack: [self.tabs, self.call]), .telegram)
        XCTAssertEqual(self.placement(wall: nil, stack: [self.tabs], overlays: [self.call]), .telegram)
        XCTAssertEqual(self.placement(wall: nil, stack: [self.tabs], globalOverlays: [self.toast]), .telegram)
        // A wall the presenter holds but the root no longer shows (taken down by something else and about to be
        // presented again, when the presenter brings the call back above it) covers nothing yet.
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs, self.call], globalOverlays: [self.toast]), .telegram)
    }

    /// An answered incoming call, a call started from Recents, a restore from picture in picture, a tap on the call
    /// bar: the screen is not on the root yet. Before the fix it was pushed (or became a `.calls` overlay) under the wall.
    func test_aCallScreenShownWhileTheWallIsUpGoesAboveIt() {
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs, self.chat], globalOverlays: [self.wall]), .moveAboveWall(from: .nowhere))
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs], globalOverlays: [self.toast, self.wall]), .moveAboveWall(from: .nowhere))
    }

    /// The finding's case: a call answered before the first unlock is on screen when the wall goes up over it at
    /// unlock (or a withdrawal or an ended link puts it up during the call). The screen is taken out of the stack or
    /// its overlay and presented above the wall.
    func test_aCallScreenTheWallCoversIsMovedAboveIt() {
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs, self.chat, self.call], globalOverlays: [self.wall]), .moveAboveWall(from: .stack))
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs], overlays: [self.call], globalOverlays: [self.wall]), .moveAboveWall(from: .overlay))
        // Above an earlier wall, then a new wall presented over it (a wall taken down by something else comes back).
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs], globalOverlays: [self.call, self.wall]), .moveAboveWall(from: .overlay))
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs], globalOverlays: [self.call, self.toast, self.wall]), .moveAboveWall(from: .overlay))
    }

    func test_aCallScreenAlreadyAboveTheWallStaysWhereItIs() {
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs], globalOverlays: [self.wall, self.call]), .aboveWall)
        XCTAssertEqual(self.placement(wall: self.wall, stack: [self.tabs], globalOverlays: [self.toast, self.wall, self.call, self.menu]), .aboveWall)
    }

    /// The app-update block is a second barrier (update_policy_spec §4f): a call screen goes above the TOPMOST of the
    /// wall and the block, whichever order they were presented in; a barrier that is not among the global overlays is
    /// not up yet and decides nothing; with no barrier up Telegram shows the screen its own way.
    func test_aCallScreenGoesAboveTheTopmostOfTheWallAndTheUpdateBlock() {
        let block = NSObject()
        func placement(barriers: [AnyObject], stack: [AnyObject], overlays: [AnyObject] = [], globalOverlays: [AnyObject]) -> SGCallScreenPlacement {
            return SGCallScreenPlacement(of: self.call, barriers: barriers, stack: stack, overlays: overlays, globalOverlays: globalOverlays)
        }
        XCTAssertEqual(placement(barriers: [self.wall, block], stack: [self.tabs], globalOverlays: [self.wall, block]), .moveAboveWall(from: .nowhere))
        XCTAssertEqual(placement(barriers: [block, self.wall], stack: [self.tabs], globalOverlays: [block, self.wall]), .moveAboveWall(from: .nowhere), "the order of the barriers does not matter")
        XCTAssertEqual(placement(barriers: [self.wall, block], stack: [self.tabs], globalOverlays: [self.wall, self.call, block]), .moveAboveWall(from: .overlay), "between the wall and the block: still under the block")
        XCTAssertEqual(placement(barriers: [self.wall, block], stack: [self.tabs, self.call], globalOverlays: [self.wall, block]), .moveAboveWall(from: .stack))
        XCTAssertEqual(placement(barriers: [self.wall, block], stack: [self.tabs], globalOverlays: [self.wall, block, self.call]), .aboveWall)
        XCTAssertEqual(placement(barriers: [block], stack: [self.tabs, self.call], globalOverlays: [block]), .moveAboveWall(from: .stack), "the block alone (the login root has no wall)")
        XCTAssertEqual(placement(barriers: [self.wall, block], stack: [self.tabs], globalOverlays: [self.wall]), .moveAboveWall(from: .nowhere), "a block not up yet is no barrier; the wall still is")
        XCTAssertEqual(placement(barriers: [self.wall, block], stack: [self.tabs, self.call], globalOverlays: [self.toast]), .telegram, "neither up: Telegram's own way")
        XCTAssertEqual(placement(barriers: [], stack: [self.tabs], globalOverlays: [self.wall]), .telegram)
    }

    /// A wall that goes up on the window's root during a call brings the call screen back above it, so the call keeps
    /// its controls; not under the prompt the user opened from Settings, and not on a root the window does not show yet.
    func test_aWallThatGoesUpDuringACallBringsTheCallScreenBack() {
        XCTAssertTrue(SGConsentWallPresenter.raisesCallScreen(isForcedPrompt: false, hasActiveCall: true, isWindowRoot: true))
        XCTAssertFalse(SGConsentWallPresenter.raisesCallScreen(isForcedPrompt: false, hasActiveCall: false, isWindowRoot: true))
        XCTAssertFalse(SGConsentWallPresenter.raisesCallScreen(isForcedPrompt: false, hasActiveCall: true, isWindowRoot: false))
        XCTAssertFalse(SGConsentWallPresenter.raisesCallScreen(isForcedPrompt: true, hasActiveCall: true, isWindowRoot: true))
    }
}
#endif
