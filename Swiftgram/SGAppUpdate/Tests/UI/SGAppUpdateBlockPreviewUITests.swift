import Foundation
import UIKit
import XCTest

// MARK: Zenlygram — UI tests over the "Update required" screen's REAL controller (update_policy_spec §7, iOS
// simulator, presenter: "Help link hittable without scrolling (iPhone/iPad preview catalog)"), as an outside client
// sees it.
//
// Each case launches the test-only host (`org.zenlygram.SGAppUpdateBlockPreviewHost`) with a catalog scenario's
// arguments — a geometry (a 4.7-inch frame, the device's window; portrait and landscape, the device rotated for the
// latter), a store-button variant, a language and a Dynamic Type size (regular, AX5) — and reads XCUITest's public
// accessibility snapshot of the running app. The same bundle runs on iPhone 17 (`SGAppUpdateBlockPreviewTests`) and on
// iPad Pro 13-inch (M5) (`SGAppUpdateBlockPreviewPadTests`). Asserted, in every scenario:
//  - the store button (`zg.update.store`) and Help (`zg.update.help`) are hittable WITHOUT A SINGLE SWIPE, lie inside
//    the screen's frame, Help under the store button, each at least 44 pt tall and wide;
//  - the host honoured the geometry (a 375 × 667 / 667 × 375 frame, or the whole window) and the Dynamic Type size
//    (its container reports the content size category; AX5 draws the title taller than the regular size);
//  - the captions read the table's strings for the language (the store button's variant included) and no raw
//    localization key leaks.
// Expected copy comes from the same SGLocalizable.strings tables the app ships (bundled into this test bundle), so a
// translation change cannot silently diverge. A screenshot of every case is attached to the result bundle.
final class SGAppUpdateBlockPreviewUITests: XCTestCase {
    private static let hostBundleId = "org.zenlygram.SGAppUpdateBlockPreviewHost"

    private var tables: [String: [String: String]] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.continueAfterFailure = false
        for lang in SGAppUpdateBlockPreviewScenario.languages {
            self.tables[lang] = try Self.table(for: lang)
        }
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testTheStoreButtonAndHelpAreHittableWithoutScrollingInEveryScenario() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication(bundleIdentifier: Self.hostBundleId)
        var titleHeights: [String: [SGAppUpdateBlockPreviewScenario.TextSize: CGFloat]] = [:]
        for scenario in SGAppUpdateBlockPreviewScenario.catalog(forPad: isPad) {
            try XCTContext.runActivity(named: scenario.name) { _ in
                let height = try self.check(scenario, app: app)
                titleHeights[scenario.geometryKey, default: [:]][scenario.textSize] = height
            }
        }
        app.terminate()

        // The AX5 launches really ran at AX5: the title is taller than at the regular size in every geometry.
        for (geometry, heights) in titleHeights {
            guard let regular = heights[.regular], let large = heights[.accessibility5] else {
                continue
            }
            XCTAssertGreaterThan(large, regular, "\(geometry): AX5 did not enlarge the title (\(large) vs \(regular) pt)")
        }
    }

    // MARK: - One case

    /// Returns the title's height, for the text-size comparison.
    private func check(_ scenario: SGAppUpdateBlockPreviewScenario, app: XCUIApplication) throws -> CGFloat {
        let context = scenario.name
        let table = try XCTUnwrap(self.tables[scenario.lang])
        func text(_ key: String) throws -> String {
            return try XCTUnwrap(table[key], "\(context): \(key) missing in \(scenario.lang)")
        }

        XCUIDevice.shared.orientation = scenario.orientation == .landscape ? .landscapeLeft : .portrait
        app.terminate()
        app.launchArguments = scenario.launchArguments
        app.launch()

        let block = app.descendants(matching: .any)["zg.update.block"]
        XCTAssertTrue(block.waitForExistence(timeout: 20), "\(context): the block never appeared")
        let container = app.otherElements["zg.preview.container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), "\(context): the host's container is missing")
        let state = container.label
        XCTAssertTrue(state.contains("textSize=\(scenario.textSize.contentSizeCategoryName)"), "\(context): the host does not run at the requested text size: \(state)")
        let bounds = container.frame
        switch scenario.screen {
        case .fourPointSevenInch:
            let expected = scenario.orientation == .landscape ? CGSize(width: 667.0, height: 375.0) : CGSize(width: 375.0, height: 667.0)
            XCTAssertEqual(bounds.size, expected, "\(context): the 4.7-inch frame")
        case .window:
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(bounds.size, window.size, "\(context): the whole window")
        }
        XCTAssertEqual(bounds.width > bounds.height, scenario.orientation == .landscape, "\(context): the orientation did not take effect: \(bounds)")

        let store = app.buttons["zg.update.store"]
        let help = app.buttons["zg.update.help"]
        let title = app.staticTexts["zg.update.title"]
        XCTAssertTrue(store.exists, "\(context): no store button")
        XCTAssertTrue(help.exists, "\(context): no Help link")
        XCTAssertTrue(title.exists, "\(context): no title")

        // Without a single swipe: the buttons are a fixed bar under the scroll view, not part of its content.
        XCTAssertTrue(store.isHittable, "\(context): the store button is not hittable without scrolling")
        XCTAssertTrue(help.isHittable, "\(context): Help is not hittable without scrolling")
        let visible = bounds.insetBy(dx: -1.0, dy: -1.0)
        XCTAssertTrue(visible.contains(store.frame), "\(context): the store button \(store.frame) is not inside the screen \(bounds)")
        XCTAssertTrue(visible.contains(help.frame), "\(context): Help \(help.frame) is not inside the screen \(bounds)")
        XCTAssertGreaterThanOrEqual(help.frame.minY + 1.0, store.frame.maxY, "\(context): Help \(help.frame) is not under the store button \(store.frame)")
        XCTAssertGreaterThanOrEqual(store.frame.height, 44.0, "\(context): the store button is \(store.frame.height) pt tall")
        XCTAssertGreaterThanOrEqual(help.frame.height, 44.0, "\(context): Help is \(help.frame.height) pt tall")
        XCTAssertGreaterThanOrEqual(help.frame.width, 44.0, "\(context): Help is \(help.frame.width) pt wide")

        XCTAssertEqual(store.label, try text(scenario.storeButton == .testFlight ? "AppUpdate.Required.TestFlightButton" : "AppUpdate.Required.Button"), "\(context): the store button's caption")
        XCTAssertEqual(help.label, try text("AppUpdate.Required.Help"), "\(context): Help's caption")
        XCTAssertEqual(title.label, try text("AppUpdate.Required.Title"), "\(context): the title")
        let labels = Self.flatten(try block.snapshot()).map { $0.label }.filter { !$0.isEmpty }
        XCTAssertFalse(labels.isEmpty, "\(context): the block exposed no labelled elements")
        for label in labels {
            XCTAssertFalse(label.contains("AppUpdate."), "\(context): raw key on screen: \(label)")
        }
        let expectedTexts = try ["AppUpdate.Required.Text", "AppUpdate.Required.DeviceNote"].map { try text($0) }
        for expected in expectedTexts {
            XCTAssertTrue(labels.contains { $0.contains(expected) }, "\(context): missing copy '\(expected)'")
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = context
        attachment.lifetime = .keepAlways
        self.add(attachment)
        return title.frame.height
    }

    // MARK: - Helpers

    /// The app's own SGLocalizable table for `lang`, bundled into this test bundle.
    private static func table(for lang: String) throws -> [String: String] {
        let bundle = Bundle(for: SGAppUpdateBlockPreviewUITests.self)
        let path = try XCTUnwrap(bundle.path(forResource: "SGLocalizable", ofType: "strings", inDirectory: nil, forLocalization: lang), "SGLocalizable.strings missing for \(lang) in the test bundle")
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    private static func flatten(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        return [node] + node.children.flatMap { Self.flatten($0) }
    }
}
