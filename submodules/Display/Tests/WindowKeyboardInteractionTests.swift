import XCTest
import UIKit
import SwiftSignalKit
@testable import Display

/// Zenlygram — regression coverage for the chat composer sliding behind a keyboard that stays put while the
/// history is scrolled (physical iOS 27.2), and for the composer then staying collapsed after the keyboard
/// closes and reopens.
///
/// `Window1` drives the interactive keyboard gesture: the finger position becomes an upper bound for the
/// input area, the reduced input height goes to the child layout (which positions the composer), and the
/// `KeyboardManager` moves the system keyboard view by the same offset. A dismissing release animates the bound
/// to the window height and finishes in the keyboard manager's completion. These tests drive the real window
/// through its keyboard notification observer, its pan recognizer callbacks and its layout pass, and read the
/// input height the root controller receives.
final class WindowKeyboardInteractionTests: XCTestCase {
    private static let keyboardHeight: CGFloat = 336.0

    private final class TestStatusBarHost: StatusBarHost {
        let statusBarFrame: CGRect = .zero
        let keyboardWindow: UIWindow? = nil
        let keyboardView: UIView?
        let isApplicationInForeground: Bool = true

        init(keyboardView: UIView?) {
            self.keyboardView = keyboardView
        }
    }

    /// Stands in for the native host's event view (the app's `UIWindow`): `Window1` ends editing on it when it
    /// dismisses the keyboard, and converts keyboard frames from the screen into it. A real `UIWindow` is not used:
    /// in a hostless test its implicit screen scene traps in BackBoard when it is invalidated at teardown.
    private final class EventView: UIView {
        private(set) var endEditingCount = 0

        override func endEditing(_ force: Bool) -> Bool {
            self.endEditingCount += 1
            return super.endEditing(force)
        }
    }

    private struct HarnessError: Error {}

    /// Stands in for the focused composer text view.
    private final class FocusedTextStandIn: UIView {
        override var isFirstResponder: Bool {
            return true
        }
    }

    private final class LayoutRecordingController: ViewController {
        private(set) var lastLayout: ContainerViewLayout?

        init() {
            super.init(navigationBarPresentationData: nil)
        }

        required init(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
            super.containerLayoutUpdated(layout, transition: transition)
            self.lastLayout = layout
        }
    }

    private struct Harness {
        let window: Window1
        let eventView: EventView
        let controller: LayoutRecordingController
        let recognizer: WindowPanRecognizer

        var size: CGSize {
            return self.eventView.bounds.size
        }

        /// The input height the composer is laid out against.
        var composerInputHeight: CGFloat? {
            return self.controller.lastLayout?.inputHeight
        }

        func layout() {
            self.window.hostView.layoutSubviews?()
        }

        /// Posts the frame-change notification as UIKit does since iOS 16.1, with the screen as its object. `Window1`
        /// then converts the keyboard top from the screen into the event view, independent of `UIScreen.main.bounds`,
        /// which is empty in a hostless test. The event view is a root view at the origin, so the conversion is
        /// expected to be the identity; the harness precondition below fails if it is not.
        func keyboardFrameChanged(visible: Bool) {
            let height = WindowKeyboardInteractionTests.keyboardHeight
            let frame = CGRect(x: 0.0, y: visible ? self.size.height - height : self.size.height, width: self.size.width, height: height)
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: UIScreen.main, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.0)
            ])
            self.layout()
        }

        /// Starts above the keyboard, as a history scroll does, and moves into the keyboard area.
        func drag(toY y: CGFloat) {
            let x = self.size.width / 2.0
            let startY = self.size.height - WindowKeyboardInteractionTests.keyboardHeight - 150.0
            self.recognizer.began?(CGPoint(x: x, y: startY))
            self.recognizer.moved?(CGPoint(x: x, y: startY + 20.0))
            self.recognizer.moved?(CGPoint(x: x, y: y))
            self.layout()
        }

        func release(atY y: CGFloat, velocityY: CGFloat) {
            self.recognizer.ended?(CGPoint(x: self.size.width / 2.0, y: y), CGPoint(x: 0.0, y: velocityY))
            self.layout()
        }
    }

    /// A compact-width phone window at the screen origin.
    private static let windowSize = CGSize(width: 402.0, height: 874.0)

    private func makeHarness(keyboardView: UIView?) throws -> Harness {
        let eventView = EventView(frame: CGRect(origin: CGPoint(), size: WindowKeyboardInteractionTests.windowSize))
        let containerView = UIView(frame: eventView.bounds)
        eventView.addSubview(containerView)
        containerView.addSubview(FocusedTextStandIn(frame: CGRect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)))
        let hostView = WindowHostView(
            containerView: containerView,
            eventView: eventView,
            isRotating: { false },
            systemUserInterfaceStyle: .single(.light),
            currentInterfaceOrientation: { .portrait },
            updateSupportedInterfaceOrientations: { _ in },
            updateDeferScreenEdgeGestures: { _ in },
            updatePrefersOnScreenNavigationHidden: { _ in },
            updateStatusBar: { _, _, _ in }
        )
        let window = Window1(hostView: hostView, statusBarHost: TestStatusBarHost(keyboardView: keyboardView))
        let controller = LayoutRecordingController()
        window.viewController = controller
        let recognizer = try XCTUnwrap(containerView.gestureRecognizers?.compactMap({ $0 as? WindowPanRecognizer }).first)
        let harness = Harness(window: window, eventView: eventView, controller: controller, recognizer: recognizer)
        harness.layout()
        harness.keyboardFrameChanged(visible: true)

        // Harness preconditions, reported apart from the behavior under test.
        let layout = try XCTUnwrap(controller.lastLayout, "harness: the root controller received no layout")
        XCTAssertEqual(layout.size, WindowKeyboardInteractionTests.windowSize, "harness: unexpected window size")
        guard layout.inputHeight == WindowKeyboardInteractionTests.keyboardHeight else {
            XCTFail("harness: the open keyboard gave input height \(String(describing: layout.inputHeight)), expected \(WindowKeyboardInteractionTests.keyboardHeight); check the screen-to-event-view keyboard frame conversion")
            throw HarnessError()
        }
        return harness
    }

    private func makeKeyboardView() -> UIView {
        let windowSize = WindowKeyboardInteractionTests.windowSize
        let height = WindowKeyboardInteractionTests.keyboardHeight
        return UIView(frame: CGRect(x: 0.0, y: windowSize.height - height, width: windowSize.width, height: height))
    }

    // MARK: - Keyboard view cannot be resolved (the iOS 27.2 recording)

    func test_scrollIntoKeyboard_withoutResolvableKeyboard_keepsComposerAboveTheStationaryKeyboard() throws {
        let harness = try self.makeHarness(keyboardView: nil)

        harness.drag(toY: harness.size.height - 50.0)

        XCTAssertEqual(harness.composerInputHeight, WindowKeyboardInteractionTests.keyboardHeight, "the keyboard did not move, so the composer must not slide behind it")
    }

    func test_dismissingRelease_withoutResolvableKeyboard_endsEditingOnce_andComposerFollowsTheKeyboard() throws {
        let harness = try self.makeHarness(keyboardView: nil)

        harness.drag(toY: harness.size.height - 50.0)
        harness.release(atY: harness.size.height - 50.0, velocityY: 500.0)

        XCTAssertEqual(harness.eventView.endEditingCount, 1, "a dismissing release hands the keyboard to the system dismissal exactly once")
        XCTAssertEqual(harness.composerInputHeight, WindowKeyboardInteractionTests.keyboardHeight, "the composer stays on the keyboard until the system moves it")

        harness.keyboardFrameChanged(visible: false)
        XCTAssertNil(harness.composerInputHeight)

        harness.keyboardFrameChanged(visible: true)
        XCTAssertEqual(harness.composerInputHeight, WindowKeyboardInteractionTests.keyboardHeight, "the composer must sit on a reopened keyboard")
    }

    func test_nonDismissingRelease_withoutResolvableKeyboard_keepsKeyboardOpen() throws {
        let harness = try self.makeHarness(keyboardView: nil)
        let aboveKeyboardY = harness.size.height - WindowKeyboardInteractionTests.keyboardHeight - 40.0

        harness.drag(toY: aboveKeyboardY)
        harness.release(atY: aboveKeyboardY, velocityY: 0.0)

        XCTAssertEqual(harness.eventView.endEditingCount, 0, "the draft stays in an open composer")
        XCTAssertEqual(harness.composerInputHeight, WindowKeyboardInteractionTests.keyboardHeight)
    }

    // MARK: - Keyboard view resolvable (interactive dismissal unchanged)

    func test_scrollIntoKeyboard_withResolvableKeyboard_movesKeyboardTogetherWithComposer() throws {
        let keyboardView = self.makeKeyboardView()
        let harness = try self.makeHarness(keyboardView: keyboardView)

        harness.drag(toY: harness.size.height - 50.0)

        let composerInputHeight = try XCTUnwrap(harness.composerInputHeight)
        XCTAssertEqual(composerInputHeight, 50.0, accuracy: 0.001, "the composer follows the finger")
        XCTAssertEqual(composerInputHeight - keyboardView.bounds.minY, WindowKeyboardInteractionTests.keyboardHeight, accuracy: 0.001, "the keyboard moves by the same offset")
        XCTAssertEqual(harness.eventView.endEditingCount, 0)
    }

    func test_keyboardClosedBeforeInteractiveDismissalFinished_reopensWithComposerOnTheKeyboard() throws {
        let keyboardView = self.makeKeyboardView()
        let harness = try self.makeHarness(keyboardView: keyboardView)

        harness.drag(toY: harness.size.height - 50.0)
        // The dismissal animation's completion has not run (the run loop is not spun), as when it is lost.
        harness.release(atY: harness.size.height - 50.0, velocityY: 500.0)
        XCTAssertEqual(harness.composerInputHeight, 0.0, "the composer goes down with the keyboard")

        keyboardView.frame.origin.y = harness.size.height
        harness.keyboardFrameChanged(visible: false)
        keyboardView.frame.origin.y = harness.size.height - WindowKeyboardInteractionTests.keyboardHeight
        harness.keyboardFrameChanged(visible: true)

        XCTAssertEqual(harness.composerInputHeight, WindowKeyboardInteractionTests.keyboardHeight, "a reopened keyboard must not leave the composer collapsed")
        XCTAssertEqual(keyboardView.bounds.minY, 0.0, "the keyboard view is back at its resting offset")
    }

    // MARK: - KeyboardManager

    func test_interactiveInputOffset_withoutKeyboardView_completesExactlyOnce() {
        let manager = KeyboardManager(host: TestStatusBarHost(keyboardView: nil))
        var completionCount = 0

        manager.updateInteractiveInputOffset(120.0, transition: .animated(duration: 0.3, curve: .spring), completion: {
            completionCount += 1
        })

        XCTAssertEqual(completionCount, 1)
    }

    func test_interactiveInputOffset_withKeyboardView_movesKeyboardAndCompletesExactlyOnce() {
        let keyboardView = UIView(frame: CGRect(x: 0.0, y: 500.0, width: 390.0, height: WindowKeyboardInteractionTests.keyboardHeight))
        let manager = KeyboardManager(host: TestStatusBarHost(keyboardView: keyboardView))
        var completionCount = 0

        manager.updateInteractiveInputOffset(120.0, transition: .immediate, completion: {
            completionCount += 1
        })

        XCTAssertEqual(keyboardView.bounds.minY, -120.0)
        XCTAssertEqual(completionCount, 1)
    }
}
