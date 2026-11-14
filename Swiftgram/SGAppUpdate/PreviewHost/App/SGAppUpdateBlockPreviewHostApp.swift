import UIKit
import Display
import TelegramPresentationData
@testable import SGAppUpdateUI

// MARK: Zenlygram — TEST-ONLY host for the "Update required" screen's real controller (never shipped).
//
// Its own bundle id and data container (`org.zenlygram.SGAppUpdateBlockPreviewHost`), iPhone and iPad. It lays the
// production `SGAppUpdateBlockController` out the way the app does — a `NavigationController` whose view is installed
// in a container of the scenario's size and laid out through `containerLayoutUpdated` (as `WindowContent` lays the
// window's root out), the block presented on it as a global overlay (`presentOverlay(inGlobal: true)`, as the
// presenter does) — and does nothing else: no SGEntitlement, no policy, no network, no persistence. It is the
// `test_host` of `SGAppUpdateBlockPreviewTests` (iPhone 17) and `SGAppUpdateBlockPreviewPadTests` (iPad Pro 13-inch).
//
// Launch arguments: `SGAppUpdateBlockPreviewScenario.launchArguments` (`-screen se|window -orientation … -store …
// -lang … -textSize …` plus UIKit's `-UIPreferredContentSizeCategoryName`). Without `-screen` it shows the window
// case in English. The store button and Help only log.
@main
final class SGAppUpdateBlockPreviewHostAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "SGAppUpdateBlockPreviewHost", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SGAppUpdateBlockPreviewHostSceneDelegate.self
        return configuration
    }
}

// The ObjC name is pinned so Info.plist can name the class without the Bazel-generated module name.
@objc(SGAppUpdateBlockPreviewHostSceneDelegate)
final class SGAppUpdateBlockPreviewHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        let scenario = SGAppUpdateBlockPreviewScenario(defaults: UserDefaults.standard)
            ?? SGAppUpdateBlockPreviewScenario(screen: .window, orientation: .portrait, storeButton: .appStore, lang: "en", textSize: .regular)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = SGAppUpdateBlockPreviewController(scenario: scenario)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        self.window = nil
    }
}

/// One scenario: the real block over a real `NavigationController`, in a container of the scenario's size.
///
/// The container (`zg.preview.container`) is what the test measures the buttons against; its accessibility label
/// reports the geometry and the Dynamic Type size the host actually runs at, so the test can tell that the launch
/// arguments took effect. The 4.7-inch frame is centred in the window (letterboxed, clear of the notch and the home
/// indicator); the window case fills it and passes the real safe area and status bar through, as the app does.
final class SGAppUpdateBlockPreviewController: UIViewController {
    private let scenario: SGAppUpdateBlockPreviewScenario
    private let container = UIView()
    private let root: NavigationController
    private var block: SGAppUpdateBlockController?

    init(scenario: SGAppUpdateBlockPreviewScenario) {
        self.scenario = scenario
        self.root = NavigationController(mode: .single, theme: NavigationControllerTheme(presentationTheme: defaultPresentationTheme))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black
        self.container.accessibilityIdentifier = "zg.preview.container"
        self.container.clipsToBounds = true
        self.view.addSubview(self.container)
        _ = self.root.view
        self.root.setViewControllers([ViewController(navigationBarPresentationData: nil)], animated: false)
        self.container.addSubview(self.root.view)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = self.containerFrame()
        self.container.frame = frame
        // As `WindowContent.viewController`'s setter installs the window's root.
        self.root.view.frame = CGRect(origin: CGPoint(), size: frame.size)
        self.root.containerLayoutUpdated(self.layout(for: frame.size), transition: .immediate)
        self.container.accessibilityLabel = "screen=\(self.scenario.screen.rawValue) size=\(Int(frame.width))x\(Int(frame.height)) textSize=\(self.traitCollection.preferredContentSizeCategory.rawValue)"
        if self.block == nil {
            self.present()
        }
    }

    private func containerFrame() -> CGRect {
        let bounds = self.view.bounds
        switch self.scenario.screen {
        case .window:
            return bounds
        case .fourPointSevenInch:
            let wanted = bounds.width > bounds.height ? CGSize(width: 667.0, height: 375.0) : CGSize(width: 375.0, height: 667.0)
            let size = CGSize(width: min(wanted.width, bounds.width), height: min(wanted.height, bounds.height))
            return CGRect(x: floor((bounds.width - size.width) / 2.0), y: floor((bounds.height - size.height) / 2.0), width: size.width, height: size.height)
        }
    }

    /// The layout the window would hand this root for the scenario's screen.
    private func layout(for size: CGSize) -> ContainerViewLayout {
        let isLandscape = size.width > size.height
        let orientation: UIInterfaceOrientation = isLandscape ? .landscapeLeft : .portrait
        switch self.scenario.screen {
        case .fourPointSevenInch:
            return ContainerViewLayout(
                size: size,
                metrics: LayoutMetrics(widthClass: .compact, heightClass: isLandscape ? .compact : .regular, orientation: orientation),
                deviceMetrics: .iPhone6,
                intrinsicInsets: UIEdgeInsets(),
                safeInsets: UIEdgeInsets(),
                additionalInsets: UIEdgeInsets(),
                statusBarHeight: isLandscape ? nil : 20.0,
                inputHeight: nil,
                inputHeightIsInteractivellyChanging: false,
                inVoiceOver: false
            )
        case .window:
            let safeInsets = self.view.safeAreaInsets
            let statusBarHeight = self.view.window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 0.0
            let isPad = self.traitCollection.userInterfaceIdiom == .pad
            return ContainerViewLayout(
                size: size,
                metrics: LayoutMetrics(
                    widthClass: self.traitCollection.horizontalSizeClass == .regular ? .regular : .compact,
                    heightClass: self.traitCollection.verticalSizeClass == .regular ? .regular : .compact,
                    orientation: orientation
                ),
                deviceMetrics: isPad ? .iPadPro3rdGen : .iPhone16Pro,
                intrinsicInsets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: safeInsets.bottom, right: 0.0),
                safeInsets: safeInsets,
                additionalInsets: UIEdgeInsets(),
                statusBarHeight: statusBarHeight > 0.0 ? statusBarHeight : nil,
                inputHeight: nil,
                inputHeightIsInteractivellyChanging: false,
                inVoiceOver: false
            )
        }
    }

    private func present() {
        let storeButton: SGAppUpdateBlockViewModel.StoreButton = self.scenario.storeButton == .testFlight ? .testFlight : .appStore
        let model = SGAppUpdateBlockViewModel(lang: self.scenario.lang, storeButton: storeButton)
        model.actions.openStore = {
            NSLog("SGAppUpdateBlockPreview action: store")
        }
        model.actions.openHelp = {
            NSLog("SGAppUpdateBlockPreview action: help")
        }
        let block = SGAppUpdateBlockController(model: model, token: UUID(), theme: defaultPresentationTheme)
        self.block = block
        self.root.presentOverlay(controller: block, inGlobal: true, blockInteraction: false)
    }
}
