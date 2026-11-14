import UIKit
import SGCustomerSyncViewsPreview

// MARK: Zenlygram — TEST-ONLY host for the consent screens' real views (never shipped).
//
// Its own bundle id and data container (`org.zenlygram.SGCustomerSyncPreviewHost`), iPhone and iPad. It renders
// `sgCustomerSyncPreviewController` — the production `Sources/UI/Views/**` over a fixture state — and does nothing
// else: no SGEntitlement, no consent store, no network, no persistence. It is the `test_host` of
// `SGCustomerSyncPreviewTests` (iPhone 17) and `SGCustomerSyncPreviewPadTests` (iPad Pro 13-inch (M5)).
//
// Launch arguments (NSArgumentDomain): `-scenario <SGCustomerSyncPreviewScenario rawValue>` opens that scenario;
// `-lang uz|ru|en` picks the language (default en). Without `-scenario` it lists every scenario. Taps are only logged.
@main
final class SGCustomerSyncPreviewHostAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "SGCustomerSyncPreviewHost", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SGCustomerSyncPreviewHostSceneDelegate.self
        return configuration
    }
}

// The ObjC name is pinned so Info.plist can name the class without the Bazel-generated module name.
@objc(SGCustomerSyncPreviewHostSceneDelegate)
final class SGCustomerSyncPreviewHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        let defaults = UserDefaults.standard
        let lang = defaults.string(forKey: "lang") ?? "en"
        let root: UIViewController
        if let name = defaults.string(forKey: "scenario"), let scenario = SGCustomerSyncPreviewScenario(rawValue: name) {
            root = SGCustomerSyncPreviewHostSceneDelegate.screen(scenario, lang: lang)
        } else {
            root = UINavigationController(rootViewController: SGCustomerSyncPreviewScenarioList(lang: lang))
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        self.window = nil
    }

    /// The wall is full screen as in the app; the Settings screens sit in a navigation controller.
    static func screen(_ scenario: SGCustomerSyncPreviewScenario, lang: String) -> UIViewController {
        let controller = sgCustomerSyncPreviewController(scenario: scenario, lang: lang)
        switch scenario.screen {
        case .wall, .prompt:
            return controller
        case .dataConsent, .withdrawAlert, .delete, .myData:
            return UINavigationController(rootViewController: controller)
        }
    }
}

/// Every scenario; tap to open it in the selected language.
final class SGCustomerSyncPreviewScenarioList: UITableViewController {
    private let lang: String
    private let scenarios = SGCustomerSyncPreviewScenario.allCases

    init(lang: String) {
        self.lang = lang
        super.init(style: .insetGrouped)
        self.title = "Consent preview · \(lang)"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "scenario")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.scenarios.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "scenario", for: indexPath)
        cell.textLabel?.text = self.scenarios[indexPath.row].rawValue
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let screen = SGCustomerSyncPreviewHostSceneDelegate.screen(self.scenarios[indexPath.row], lang: self.lang)
        screen.modalPresentationStyle = .fullScreen
        self.present(screen, animated: true, completion: nil)
    }
}
