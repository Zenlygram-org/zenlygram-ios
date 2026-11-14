import UIKit

@objc(ZenlygramSceneDelegate)
final class ZenlygramSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private func appDelegate(for scene: UIScene) -> AppDelegate? {
        guard self.window?.windowScene === scene else {
            return nil
        }
        return UIApplication.shared.delegate as? AppDelegate
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate,
              let window = appDelegate.connectWindow(to: windowScene) else {
            return
        }
        self.window = window

        self.scene(scene, openURLContexts: connectionOptions.urlContexts)
        for userActivity in connectionOptions.userActivities {
            self.scene(scene, continue: userActivity)
        }
        if let shortcutItem = connectionOptions.shortcutItem {
            self.windowScene(windowScene, performActionFor: shortcutItem, completionHandler: { _ in })
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        self.appDelegate(for: scene)?.disconnectWindow(from: scene)
        self.window = nil
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        self.appDelegate(for: scene)?.applicationWillEnterForeground(UIApplication.shared)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        self.appDelegate(for: scene)?.applicationDidBecomeActive(UIApplication.shared)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        self.appDelegate(for: scene)?.applicationWillResignActive(UIApplication.shared)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        self.appDelegate(for: scene)?.applicationDidEnterBackground(UIApplication.shared)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let appDelegate = self.appDelegate(for: scene) else {
            return
        }
        for context in URLContexts {
            _ = appDelegate.application(UIApplication.shared, open: context.url, options: [:])
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        _ = self.appDelegate(for: scene)?.application(UIApplication.shared, continue: userActivity, restorationHandler: { _ in })
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let appDelegate = self.appDelegate(for: windowScene) else {
            completionHandler(false)
            return
        }
        appDelegate.application(UIApplication.shared, performActionFor: shortcutItem, completionHandler: completionHandler)
    }

    @available(iOS 26.0, *)
    func preferredWindowingControlStyle(for windowScene: UIWindowScene) -> UIWindowScene.WindowingControlStyle {
        return .minimal
    }
}
