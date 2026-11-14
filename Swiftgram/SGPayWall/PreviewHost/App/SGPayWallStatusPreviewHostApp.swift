import UIKit
import SGPayWallStatusPreview

// MARK: Zenlygram — TEST-ONLY host for the status screen's real renderer (never shipped).
//
// Its own bundle id and data container (`org.zenlygram.SGPayWallStatusPreviewHost`). It renders
// `sgPayWallStatusPreviewController` — the production `SGEntitlementStatusContent` over a synthetic
// scenario — and does nothing else: no `SGEntitlement`, no `SGIAPManager`, no StoreKit, no network,
// no persistence. It is also the `test_host` of `SGPayWallStatusPreviewTests`.
//
// Launch arguments (NSArgumentDomain): `-scenario <SGPayWallStatusPreviewScenario rawValue>` opens
// that scenario directly; `-lang en|ru|uz` picks the language (default en). Without `-scenario` it
// lists every scenario. Taps are only logged.
@main
final class SGPayWallStatusPreviewHostAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "SGPayWallStatusPreviewHost", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SGPayWallStatusPreviewHostSceneDelegate.self
        return configuration
    }
}

// The ObjC name is pinned so Info.plist can name the class without the Bazel-generated module name.
@objc(SGPayWallStatusPreviewHostSceneDelegate)
final class SGPayWallStatusPreviewHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        let defaults = UserDefaults.standard
        let lang = defaults.string(forKey: "lang") ?? "en"
        let root: UIViewController
        if let name = defaults.string(forKey: "scenario"), let scenario = SGPayWallStatusPreviewScenario(rawValue: name) {
            root = UINavigationController(rootViewController: sgPayWallStatusPreviewController(scenario: scenario, lang: lang, onAction: SGPayWallStatusPreviewScenarioList.log))
        } else {
            root = UINavigationController(rootViewController: SGPayWallStatusPreviewScenarioList(lang: lang))
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        self.window = nil
    }
}

/// Every scenario, tap to open it in the selected language.
final class SGPayWallStatusPreviewScenarioList: UITableViewController {
    private let lang: String
    private let scenarios = SGPayWallStatusPreviewScenario.allCases

    static func log(_ action: String) {
        NSLog("SGPayWallStatusPreview action: %@", action)
    }

    init(lang: String) {
        self.lang = lang
        super.init(style: .insetGrouped)
        self.title = "Status preview · \(lang)"
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
        let controller = sgPayWallStatusPreviewController(scenario: self.scenarios[indexPath.row], lang: self.lang, onAction: SGPayWallStatusPreviewScenarioList.log)
        self.navigationController?.pushViewController(controller, animated: true)
    }
}
