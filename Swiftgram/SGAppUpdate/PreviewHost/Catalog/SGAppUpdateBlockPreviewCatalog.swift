import Foundation

// MARK: Zenlygram — TEST-ONLY. The "Update required" screen's preview catalog (update_policy_spec §7, iOS
// simulator, presenter: "Help link hittable without scrolling (iPhone/iPad preview catalog)"), Foundation only.
//
// Compiled into BOTH the preview host (`SGAppUpdateBlockPreviewHostLib`, which lays the real
// `SGAppUpdateBlockController` out for one scenario) and the UI test bundle (`SGAppUpdateBlockPreviewUITestsLib`,
// which launches the host with a scenario's arguments and checks the store button and Help as XCUITest sees them).
// One list, so a scenario cannot exist in one and be missing from the other.

public struct SGAppUpdateBlockPreviewScenario: Hashable {
    /// The screen the block is laid out for.
    public enum Screen: String, CaseIterable {
        /// A 4.7-inch phone (iPhone SE 2nd/3rd generation, iPhone 8): 375 × 667 pt, a 20 pt status bar and no
        /// home indicator in portrait, nothing in landscape — the smallest screen the release supports (iOS 15.0
        /// floor), laid out in a frame of that size inside the test device's window.
        case fourPointSevenInch = "se"
        /// The whole window of the device the test runs on: iPhone 17 (402 × 874) or iPad Pro 13-inch (1032 × 1376),
        /// with its real safe area and status bar.
        case window
    }

    public enum Orientation: String, CaseIterable {
        case portrait
        case landscape
    }

    public enum StoreButton: String, CaseIterable {
        case appStore
        case testFlight
    }

    public enum TextSize: String, CaseIterable {
        case regular
        /// The largest accessibility size (AX5): the worst case for the fixed bottom bar.
        case accessibility5 = "ax5"

        /// UIKit's `-UIPreferredContentSizeCategoryName` launch argument the host is started with.
        public var contentSizeCategoryName: String {
            switch self {
            case .regular:
                return "UICTContentSizeCategoryL"
            case .accessibility5:
                return "UICTContentSizeCategoryAccessibilityXXXL"
            }
        }
    }

    public var screen: Screen
    public var orientation: Orientation
    public var storeButton: StoreButton
    public var lang: String
    public var textSize: TextSize

    public static let languages = ["en", "ru", "uz"]

    public init(screen: Screen, orientation: Orientation, storeButton: StoreButton, lang: String, textSize: TextSize) {
        self.screen = screen
        self.orientation = orientation
        self.storeButton = storeButton
        self.lang = lang
        self.textSize = textSize
    }

    /// The catalog for the device the test runs on: every geometry in both orientations, every language, at AX5
    /// with both store buttons and at the regular size with the App Store button. The 4.7-inch frame is laid out
    /// on the iPhone runner only (on the iPad runner the window is the case that matters).
    public static func catalog(forPad: Bool) -> [SGAppUpdateBlockPreviewScenario] {
        let screens: [Screen] = forPad ? [.window] : [.fourPointSevenInch, .window]
        var scenarios: [SGAppUpdateBlockPreviewScenario] = []
        for screen in screens {
            for orientation in Orientation.allCases {
                for lang in SGAppUpdateBlockPreviewScenario.languages {
                    for storeButton in StoreButton.allCases {
                        scenarios.append(SGAppUpdateBlockPreviewScenario(screen: screen, orientation: orientation, storeButton: storeButton, lang: lang, textSize: .accessibility5))
                    }
                    scenarios.append(SGAppUpdateBlockPreviewScenario(screen: screen, orientation: orientation, storeButton: .appStore, lang: lang, textSize: .regular))
                }
            }
        }
        return scenarios
    }

    public var name: String {
        return "\(self.screen.rawValue)-\(self.orientation.rawValue)-\(self.storeButton.rawValue)-\(self.lang)-\(self.textSize.rawValue)"
    }

    /// The same case at the other text size: the AX5 run must draw the title taller than the regular one.
    public var geometryKey: String {
        return "\(self.screen.rawValue)-\(self.orientation.rawValue)-\(self.storeButton.rawValue)-\(self.lang)"
    }

    /// `-screen se|window -orientation portrait|landscape -store appStore|testFlight -lang en|ru|uz -textSize
    /// regular|ax5`, plus UIKit's own `-UIPreferredContentSizeCategoryName`, which sets the host's Dynamic Type size.
    public var launchArguments: [String] {
        return [
            "-screen", self.screen.rawValue,
            "-orientation", self.orientation.rawValue,
            "-store", self.storeButton.rawValue,
            "-lang", self.lang,
            "-textSize", self.textSize.rawValue,
            "-UIPreferredContentSizeCategoryName", self.textSize.contentSizeCategoryName,
        ]
    }

    /// The scenario the host was launched with (NSArgumentDomain, read through `UserDefaults.standard`);
    /// nil without a `-screen` argument (the host then shows the default case).
    public init?(defaults: UserDefaults) {
        guard let screenName = defaults.string(forKey: "screen"), let screen = Screen(rawValue: screenName) else {
            return nil
        }
        self.screen = screen
        self.orientation = defaults.string(forKey: "orientation").flatMap { Orientation(rawValue: $0) } ?? .portrait
        self.storeButton = defaults.string(forKey: "store").flatMap { StoreButton(rawValue: $0) } ?? .appStore
        self.lang = defaults.string(forKey: "lang") ?? "en"
        self.textSize = defaults.string(forKey: "textSize").flatMap { TextSize(rawValue: $0) } ?? .regular
    }
}
