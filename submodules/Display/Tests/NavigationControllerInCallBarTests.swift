import XCTest
import UIKit
import AsyncDisplayKit
@testable import Display

/// Zenlygram — regression coverage for Telegram's in-call bar above the consent wall (design 40 §5.1).
///
/// The consent wall is an opaque global overlay of an account root. Telegram places the in-call bar of a minimised
/// call under the root's overlays, so the wall would cover it. While `sgInCallStatusBarAboveGlobalOverlays` is set
/// (the wall's presenter sets it while a wall or prompt is up), the bar must be the root's last subnode, so a tap
/// reaches it before the global-overlay parents, and its zPosition must be above theirs, so it is drawn above them,
/// also after a parent came back from the keyboard window with zPosition 1000. A modal pushed meanwhile must stay
/// below the wall. Unset, Telegram's order holds. These tests drive a real `NavigationController` without a host, with
/// a plain controller standing in for the wall and a `CallStatusBarNode` for the call, and read the order of the root's
/// subnodes, their zPosition and the status-bar style the root resolves.
final class NavigationControllerInCallBarTests: XCTestCase {
    private struct HarnessError: Error {}

    /// A Dynamic Island phone in portrait with the keyboard closed.
    private static let layout = ContainerViewLayout(
        size: CGSize(width: 402.0, height: 874.0),
        metrics: LayoutMetrics(widthClass: .compact, heightClass: .regular, orientation: .portrait),
        deviceMetrics: .iPhone16Pro,
        intrinsicInsets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 34.0, right: 0.0),
        safeInsets: UIEdgeInsets(top: 62.0, left: 0.0, bottom: 34.0, right: 0.0),
        additionalInsets: UIEdgeInsets(),
        statusBarHeight: 54.0,
        inputHeight: nil,
        inputHeightIsInteractivellyChanging: false,
        inVoiceOver: false
    )

    private static func makeTheme() -> NavigationControllerTheme {
        let navigationBar = NavigationBarTheme(
            overallDarkAppearance: false,
            buttonColor: .systemBlue,
            disabledButtonColor: .gray,
            primaryTextColor: .black,
            backgroundColor: .white,
            enableBackgroundBlur: false,
            separatorColor: .lightGray,
            badgeBackgroundColor: .red,
            badgeStrokeColor: .red,
            badgeTextColor: .white,
            accentButtonColor: .systemBlue,
            accentDisabledButtonColor: .gray,
            accentForegroundColor: .white
        )
        return NavigationControllerTheme(statusBar: .black, navigationBar: navigationBar, emptyAreaColor: .white)
    }

    /// Runs the main-queue work a step scheduled (readiness, deferred layout requests).
    private static func spin() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    private struct Harness {
        let navigationController: NavigationController
        let wall: ViewController

        var subnodes: [ASDisplayNode] {
            return self.navigationController.displayNode.subnodes ?? []
        }

        /// The in-call bar: the root's only direct `StatusBar` subnode.
        var inCallBar: StatusBar? {
            return self.subnodes.first(where: { $0 is StatusBar }) as? StatusBar
        }

        var inCallBarIndex: Int? {
            return self.subnodes.firstIndex(where: { $0 is StatusBar })
        }

        /// The root's direct subnode that holds `node`: for the wall its global-overlay parent, for a modal its container.
        func topLevelNode(holding node: ASDisplayNode) -> ASDisplayNode? {
            let root = self.navigationController.displayNode
            var current: ASDisplayNode? = node
            while let candidate = current {
                if candidate.supernode === root {
                    return candidate
                }
                current = candidate.supernode
            }
            return nil
        }

        func index(of node: ASDisplayNode) -> Int? {
            return self.subnodes.firstIndex(where: { $0 === node })
        }

        var wallParent: ASDisplayNode? {
            return self.topLevelNode(holding: self.wall.displayNode)
        }

        var wallParentIndex: Int? {
            return self.wallParent.flatMap { self.index(of: $0) }
        }

        var isInCallBarLast: Bool {
            guard let inCallBar = self.inCallBar else {
                return false
            }
            return self.subnodes.last === inCallBar
        }

        func setFlag(_ value: Bool) {
            self.navigationController.sgInCallStatusBarAboveGlobalOverlays = value
            NavigationControllerInCallBarTests.spin()
        }

        func layout() {
            self.navigationController.containerLayoutUpdated(NavigationControllerInCallBarTests.layout, transition: .immediate)
            NavigationControllerInCallBarTests.spin()
        }
    }

    /// An account root with one controller and the stand-in wall presented as a global overlay.
    private func makeHarness() throws -> Harness {
        let navigationController = NavigationController(mode: .single, theme: NavigationControllerInCallBarTests.makeTheme())
        _ = navigationController.view
        navigationController.setViewControllers([ViewController(navigationBarPresentationData: nil)], animated: false)
        navigationController.containerLayoutUpdated(NavigationControllerInCallBarTests.layout, transition: .immediate)
        NavigationControllerInCallBarTests.spin()

        let wall = ViewController(navigationBarPresentationData: nil)
        wall.isOpaqueWhenInOverlay = true
        wall.blocksBackgroundWhenInOverlay = true
        navigationController.presentOverlay(controller: wall, inGlobal: true)
        NavigationControllerInCallBarTests.spin()

        let harness = Harness(navigationController: navigationController, wall: wall)
        // Harness preconditions, reported apart from the behavior under test.
        guard wall.isNodeLoaded, harness.wallParentIndex != nil else {
            XCTFail("harness: the stand-in wall's overlay container never joined the root's display node")
            throw HarnessError()
        }
        return harness
    }

    /// A call minimised: `SharedAccountContextImpl.updateInCallStatusBarData` hands the root a call status bar node.
    private func showInCallBar(_ harness: Harness) throws -> StatusBar {
        harness.navigationController.setForceInCallStatusBar(CallStatusBarNode(), transition: .immediate)
        NavigationControllerInCallBarTests.spin()
        guard let inCallBar = harness.inCallBar else {
            XCTFail("harness: the in-call bar never joined the root's display node")
            throw HarnessError()
        }
        return inCallBar
    }

    /// Pushes a modal controller and returns its container, a direct subnode of the root.
    private func pushModal(_ harness: Harness) throws -> ASDisplayNode {
        let modal = ViewController(navigationBarPresentationData: nil)
        modal.navigationPresentation = .modal
        harness.navigationController.pushViewController(modal, animated: false, completion: {})
        NavigationControllerInCallBarTests.spin()
        guard modal.isNodeLoaded, let container = harness.topLevelNode(holding: modal.displayNode) else {
            XCTFail("harness: the modal's container never joined the root's display node")
            throw HarnessError()
        }
        return container
    }

    // MARK: - Unset: Telegram's layout

    /// (1)
    func test_flagUnset_inCallBarStaysUnderTheGlobalOverlays() throws {
        let harness = try self.makeHarness()
        XCTAssertFalse(harness.navigationController.sgInCallStatusBarAboveGlobalOverlays, "a root that never shows a wall keeps Telegram's layout")
        _ = try self.showInCallBar(harness)

        let barIndex = try XCTUnwrap(harness.inCallBarIndex)
        let wallParentIndex = try XCTUnwrap(harness.wallParentIndex)
        XCTAssertLessThan(barIndex, wallParentIndex, "Telegram's order: the bar is under the global overlays")
    }

    // MARK: - Set: the bar above the wall

    /// (2)
    func test_flagSetWithABar_liftsTheBarAboveTheWall() throws {
        let harness = try self.makeHarness()
        let inCallBar = try self.showInCallBar(harness)

        harness.setFlag(true)

        let wallParent = try XCTUnwrap(harness.wallParent)
        XCTAssertTrue(harness.isInCallBarLast, "a tap on the bar must reach it before the wall")
        XCTAssertGreaterThan(inCallBar.layer.zPosition, wallParent.layer.zPosition, "the bar must be drawn above the wall")
        for node in harness.subnodes where node !== inCallBar {
            XCTAssertGreaterThan(inCallBar.layer.zPosition, node.layer.zPosition, "the bar must be drawn above both global-overlay parents")
        }
    }

    /// (3)
    func test_flagSetBeforeTheCallIsMinimised_newBarIsLifted() throws {
        let harness = try self.makeHarness()
        harness.setFlag(true)

        let inCallBar = try self.showInCallBar(harness)

        let wallParent = try XCTUnwrap(harness.wallParent)
        XCTAssertTrue(harness.isInCallBarLast, "a bar created while the wall is up goes above it")
        XCTAssertGreaterThan(inCallBar.layer.zPosition, wallParent.layer.zPosition)
    }

    /// (4)
    func test_flagSet_modalPushedMeanwhileStaysUnderTheWall() throws {
        let harness = try self.makeHarness()
        _ = try self.showInCallBar(harness)
        harness.setFlag(true)

        let modalContainer = try self.pushModal(harness)

        let modalIndex = try XCTUnwrap(harness.index(of: modalContainer))
        let wallParentIndex = try XCTUnwrap(harness.wallParentIndex)
        XCTAssertLessThan(modalIndex, wallParentIndex, "nothing of the app goes above the wall: a modal is not inserted under the lifted bar")
        XCTAssertTrue(harness.isInCallBarLast)
    }

    // MARK: - Cleared: back to Telegram's place

    /// (5)
    func test_flagCleared_putsTheBarBackAtTelegramsPlace() throws {
        let harness = try self.makeHarness()
        let inCallBar = try self.showInCallBar(harness)
        harness.setFlag(true)

        harness.setFlag(false)

        let barIndex = try XCTUnwrap(harness.inCallBarIndex)
        let wallParentIndex = try XCTUnwrap(harness.wallParentIndex)
        XCTAssertEqual(inCallBar.layer.zPosition, 0.0)
        XCTAssertLessThan(barIndex, wallParentIndex, "Telegram's order once the wall is gone")

        let modalContainer = try self.pushModal(harness)
        let modalIndex = try XCTUnwrap(harness.index(of: modalContainer))
        let updatedBarIndex = try XCTUnwrap(harness.inCallBarIndex)
        XCTAssertLessThan(modalIndex, updatedBarIndex, "Telegram's order: a later modal goes under the bar")
    }

    // MARK: - The keyboard window round trip

    /// (6)
    func test_flagSet_wallParentReAddedByALayoutPass_barIsLastAgain() throws {
        let harness = try self.makeHarness()
        _ = try self.showInCallBar(harness)
        harness.setFlag(true)
        let wallParent = try XCTUnwrap(harness.wallParent)

        // What moving the parent into the keyboard window does to the root; with the keyboard closed, the next layout
        // pass adds it back as the root's last subnode.
        wallParent.removeFromSupernode()
        harness.layout()

        guard wallParent.supernode === harness.navigationController.displayNode else {
            XCTFail("harness: the layout pass did not add the wall's parent back to the root")
            throw HarnessError()
        }
        XCTAssertTrue(harness.isInCallBarLast, "the bar must be lifted again above the re-added parent")
    }

    /// (7)
    func test_wallParentBackFromTheKeyboardWindow_barIsDrawnAboveItsZPosition() throws {
        let harness = try self.makeHarness()
        let inCallBar = try self.showInCallBar(harness)
        let wallParent = try XCTUnwrap(harness.wallParent)
        // The zPosition a parent keeps after a visit to the keyboard window.
        wallParent.layer.zPosition = 1000.0

        harness.setFlag(true)

        XCTAssertTrue(harness.isInCallBarLast)
        XCTAssertGreaterThan(inCallBar.layer.zPosition, 1000.0, "the bar must be drawn above a parent back from the keyboard window")

        harness.setFlag(false)

        let barIndex = try XCTUnwrap(harness.inCallBarIndex)
        let wallParentIndex = try XCTUnwrap(harness.wallParentIndex)
        XCTAssertEqual(inCallBar.layer.zPosition, 0.0)
        XCTAssertLessThan(barIndex, wallParentIndex)
    }

    // MARK: - Status bar

    /// (8)
    func test_flagSetWithABar_statusBarIsWhiteOverTheBar() throws {
        let harness = try self.makeHarness()
        // A light theme's wall asks for dark status-bar content.
        harness.wall.statusBar.statusBarStyle = .Black

        harness.setFlag(true)
        harness.layout()
        XCTAssertEqual(harness.navigationController.statusBar.style, .darkContent, "no bar: the wall's own style")

        _ = try self.showInCallBar(harness)
        harness.layout()
        XCTAssertEqual(harness.navigationController.statusBar.style, .lightContent, "white time and battery over the lifted bar")

        harness.setFlag(false)
        harness.layout()
        XCTAssertEqual(harness.navigationController.statusBar.style, .darkContent, "unset: the wall's own style, as in Telegram")
    }

    // MARK: - Raisers

    /// (9) The consent wall and the app-update block (update_policy_spec §4f) each hold the bar lifted while they are
    /// up; the bar drops only when the last of them releases it, so a wall taken down under a block never drops the
    /// bar below the block.
    func test_twoRaisersKeepTheBarLiftedUntilBothRelease() throws {
        let harness = try self.makeHarness()
        let inCallBar = try self.showInCallBar(harness)

        harness.navigationController.sgSetInCallStatusBarAboveGlobalOverlays(true, for: "wall")
        harness.navigationController.sgSetInCallStatusBarAboveGlobalOverlays(true, for: "block")
        NavigationControllerInCallBarTests.spin()
        XCTAssertTrue(harness.navigationController.sgInCallStatusBarAboveGlobalOverlays)
        XCTAssertTrue(harness.isInCallBarLast)

        harness.navigationController.sgSetInCallStatusBarAboveGlobalOverlays(false, for: "wall")
        NavigationControllerInCallBarTests.spin()
        XCTAssertTrue(harness.navigationController.sgInCallStatusBarAboveGlobalOverlays, "the block still holds it")
        XCTAssertTrue(harness.isInCallBarLast)

        harness.navigationController.sgSetInCallStatusBarAboveGlobalOverlays(false, for: "wall")
        harness.navigationController.sgSetInCallStatusBarAboveGlobalOverlays(false, for: "block")
        NavigationControllerInCallBarTests.spin()
        XCTAssertFalse(harness.navigationController.sgInCallStatusBarAboveGlobalOverlays, "released by both: Telegram's layout")
        XCTAssertEqual(inCallBar.layer.zPosition, 0.0)
        let barIndex = try XCTUnwrap(harness.inCallBarIndex)
        let wallParentIndex = try XCTUnwrap(harness.wallParentIndex)
        XCTAssertLessThan(barIndex, wallParentIndex)
    }
}
