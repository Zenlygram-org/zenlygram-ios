import Foundation
import UIKit
import TelegramPresentationData

/// Zenlygram — opaque cover shown while the app is inactive / in the app switcher and a locked chat is
/// unlocked, so the snapshot never shows its content. A separate window above everything (including the
/// keyboard windows) that never becomes key; AppLock's `Window1.coveringView` is deliberately not reused.
final class ChatLockPrivacyShield {
    private var window: UIWindow?

    func show(presentationData: PresentationData, referenceWindow: UIWindow?) {
        let window: UIWindow
        if let current = self.window {
            window = current
            if let windowScene = referenceWindow?.windowScene, current.windowScene !== windowScene {
                // The main window can reconnect to a new scene while this shield is cached.
                current.isHidden = true
                current.windowScene = windowScene
            }
        } else {
            if let windowScene = referenceWindow?.windowScene {
                window = UIWindow(windowScene: windowScene)
            } else {
                window = UIWindow(frame: UIScreen.main.bounds)
            }
            window.windowLevel = UIWindow.Level(rawValue: 10_000_100.0)
            window.backgroundColor = .clear
            window.accessibilityViewIsModal = true
            window.rootViewController = ChatLockPrivacyShieldController()
            self.window = window
        }
        if let referenceWindow {
            window.frame = referenceWindow.frame
        } else {
            window.frame = UIScreen.main.bounds
        }
        (window.rootViewController as? ChatLockPrivacyShieldController)?.update(presentationData: presentationData)
        window.isHidden = false
    }

    func hide() {
        self.window?.isHidden = true
    }
}

private final class ChatLockPrivacyShieldController: UIViewController {
    private let iconView = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        self.iconView.contentMode = .center
        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.iconView.isAccessibilityElement = false
        self.view.addSubview(self.iconView)
        NSLayoutConstraint.activate([
            self.iconView.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            self.iconView.centerYAnchor.constraint(equalTo: self.view.centerYAnchor)
        ])
    }

    func update(presentationData: PresentationData) {
        self.loadViewIfNeeded()
        let theme = presentationData.theme
        self.view.backgroundColor = theme.list.plainBackgroundColor.withAlphaComponent(1.0)
        let configuration = UIImage.SymbolConfiguration(pointSize: 64.0, weight: .regular)
        self.iconView.image = UIImage(systemName: "lock.fill", withConfiguration: configuration)?.withTintColor(theme.list.itemAccentColor, renderingMode: .alwaysOriginal)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }
}
