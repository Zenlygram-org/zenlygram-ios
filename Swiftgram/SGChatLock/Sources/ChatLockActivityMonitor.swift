import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// SG: Secret Vault — observes user activity in the main window while a vault is open (audit #119: a real
/// inactivity timer instead of a fixed 5-minute timer on the vault list).
///
/// A pure observer: it reports every touch-down and hardware-keyboard press and fails at once, never cancels or
/// delays touches, never prevents, requires or is required to fail by another recognizer, and recognizes
/// simultaneously with all of them, so it cannot change how any screen handles its touches or presses.
final class ChatLockActivityMonitor: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onActivity: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        self.delegate = self
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        self.onActivity?()
        self.state = .failed
    }

    /// Hardware keyboard (arrow keys, shortcuts, typing outside a text view).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesBegan(presses, with: event)
        self.onActivity?()
        self.state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

/// SG: Secret Vault — pointer activity while a vault is open (#119): a hover recognizer (pointer movement) and a
/// scroll-only pan recognizer (trackpad and mouse-wheel scrolls: `allowedTouchTypes` is empty, so it never sees
/// a touch). Neither is a touch, so ChatLockActivityMonitor cannot see them. This object is their target and
/// delegate (ChatLockSession keeps it next to the recognizers). Pure observers like ChatLockActivityMonitor: they
/// neither cancel nor delay touches, recognize simultaneously with every other recognizer and never require or
/// are required to fail by one, so they never prevent another recognizer.
final class ChatLockPointerActivityObserver: NSObject, UIGestureRecognizerDelegate {
    private let onActivity: () -> Void

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        super.init()
    }

    /// New recognizers targeting this observer, for the caller to install (the scroll one from iOS 13.4).
    func makeRecognizers() -> [UIGestureRecognizer] {
        var recognizers: [UIGestureRecognizer] = [UIHoverGestureRecognizer(target: self, action: #selector(self.handleActivity(_:)))]
        if #available(iOS 13.4, *) {
            let scrollRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.handleActivity(_:)))
            scrollRecognizer.allowedScrollTypesMask = .all
            scrollRecognizer.allowedTouchTypes = []
            recognizers.append(scrollRecognizer)
        }
        for recognizer in recognizers {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
        }
        return recognizers
    }

    @objc private func handleActivity(_ recognizer: UIGestureRecognizer) {
        self.onActivity()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }
}
