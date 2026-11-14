import UIKit

// Zenlygram — test host for SGItemListUIHostedTests only (never shipped).
//
// Building real ItemList nodes needs `PresentationStrings`, whose generated initializer reads
// `PresentationStrings.data` from `getAppBundle()` (the main bundle) and asserts when it is missing. rules_apple
// has no default host app (hostless tests run inside the platform `xctest` agent), so this host bundles the
// app's own generated data file (see `SGItemListUITestHost` in BUILD).
//
// Like the app since the Xcode 27 work (`ZenlygramSceneDelegate`, docs/entitlement.md), it uses the scene
// lifecycle: one UIWindowScene with a window and an empty root view controller. It does nothing else.
@main
final class SGItemListUITestHostAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "SGItemListUITestHost", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SGItemListUITestHostSceneDelegate.self
        return configuration
    }
}

// The ObjC name is pinned so Info.plist can name the class without the Bazel-generated Swift module name.
@objc(SGItemListUITestHostSceneDelegate)
final class SGItemListUITestHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        self.window = nil
    }
}
