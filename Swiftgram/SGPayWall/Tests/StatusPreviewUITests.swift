import Foundation
import XCTest

// MARK: Zenlygram — UI tests over the status screen's REAL renderer, as an outside client sees it.
//
// Each case launches the test-only host (`org.zenlygram.SGPayWallStatusPreviewHost`) with
// `-scenario <name> -lang <en|ru|uz>`. The host renders the production `SGEntitlementStatusContent`
// for that synthetic scenario and touches no SGEntitlement, StoreKit, network or persistence.
// Everything asserted here comes from XCUITest's public accessibility snapshot of the running app:
//  - exactly the expected buttons are on screen: no "View Plans" or Manage without StoreKit
//    evidence in either mode; in free mode no Subscribe / View Plans at all, while Restore, linking
//    and — for an existing subscriber — Apple's management page stay; and no actions at all for
//    another account;
//  - every expected line is shown, every forbidden one is absent, and no raw localization key leaks;
//  - every button is at least 44 × 44 pt, and a running Restore is not enabled.
// Expected copy is read from the same SGLocalizable.strings tables the app ships (bundled into this
// test bundle via `data`), so a translation change cannot silently diverge. A screenshot of every
// case is attached to the result bundle.
final class StatusPreviewUITests: XCTestCase {
    private static let languages = ["en", "ru", "uz"]
    private static let hostBundleId = "org.zenlygram.SGPayWallStatusPreviewHost"

    private struct Expectation {
        /// The title keys of EXACTLY the buttons on screen, in any order.
        var buttons: [String]
        var present: [String] = []
        /// A key formatted with one date, `days` after the scenario clock.
        var presentWithDate: [(key: String, days: Double)] = []
        var absent: [String] = []
        /// A key formatted with one date that must NOT be on screen (a countdown, a misplaced horizon).
        var absentWithDate: [(key: String, days: Double)] = []
    }

    private static let restore = "PayWall.RestorePurchases"
    private static let subscribe = "Entitlement.Status.Subscribe"
    private static let viewPlans = "Entitlement.Status.ViewPlans"
    private static let manage = "PayWall.ManageSubscription"
    private static let link = "LinkAccount.Title"
    private static let linkOptional = "PayWall.LinkAccount.Notice"
    private static let linked = "Entitlement.Status.Linked"
    private static let restoreDetail = "Entitlement.Status.Restore.Detail"
    private static let restoring = "PayWall.Button.Restoring"
    private static let planNone = "Entitlement.Plan.None"
    private static let planActive = "Entitlement.Plan.Active"

    /// No StoreKit subscription: buying is "Subscribe", and Apple's management page is not offered.
    private static let unpaidButtons = [subscribe, restore, link]
    /// StoreKit shows a subscription: the paywall is a plan switch, and Apple's page is offered.
    private static let paidButtons = [viewPlans, restore, link, manage]
    /// Free, no StoreKit evidence: nothing new is sold (no Subscribe, no View Plans) and Apple's page is
    /// not offered either — a holder by server grant has no App Store subscription to manage.
    private static let freeButtons = [restore, link]
    /// Free, StoreKit shows a subscription: Apple's management page stays for the existing subscriber.
    private static let freeSubscriberButtons = [restore, link, manage]
    private static let freeAccess = "Entitlement.Status.FreeAccess"
    private static let freeNotice = "Entitlement.Status.FreeAccess.Notice"
    private static let renewsUntilCancelled = "Entitlement.Status.FreeAccess.ExistingSubscription"
    private static let managedByApple = "Entitlement.Status.FreeAccess.ManagedByApple"

    private static let expectations: [SGPayWallStatusPreviewScenario: Expectation] = [
        .notSubscribed: Expectation(
            buttons: unpaidButtons,
            present: ["Entitlement.Status.Inactive", restoreDetail, linkOptional, planNone],
            absent: ["Entitlement.Message.NotLinked"]
        ),
        .localGrace: Expectation(
            buttons: unpaidButtons,
            present: [planNone],
            presentWithDate: [("Entitlement.Status.FreeUntil", 5)]
        ),
        .tokenAccess: Expectation(
            buttons: unpaidButtons,
            present: [linked, planNone],
            presentWithDate: [("Entitlement.Status.AvailableUntil", 30)],
            absent: ["Entitlement.Status.ViaAppStore"]
        ),
        .appStoreRenews: Expectation(
            buttons: paidButtons,
            present: [linked],
            presentWithDate: [("Entitlement.Status.AvailableUntil", 30), ("Entitlement.Plan.RenewsOn", 30)],
            absent: [planNone]
        ),
        .appStoreEnds: Expectation(
            buttons: paidButtons,
            presentWithDate: [("Entitlement.Plan.EndsOn", 12)]
        ),
        .appStoreBillingRetry: Expectation(
            buttons: paidButtons,
            present: ["Entitlement.Status.Lapsed", "Entitlement.Plan.BillingRetry", "Entitlement.Message.SubscriptionEnded"]
        ),
        .viaAppStoreSnapshot: Expectation(
            buttons: paidButtons,
            present: ["Entitlement.Status.ViaAppStore", planActive, linkOptional]
        ),
        .unconfiguredBuild: Expectation(
            buttons: unpaidButtons,
            present: ["Entitlement.Status.UnlockedBuild"],
            absent: [planNone, planActive]
        ),
        .lapsed: Expectation(
            buttons: unpaidButtons,
            present: ["Entitlement.Status.Lapsed", "Entitlement.Message.SubscriptionEnded", planNone]
        ),
        .reconnect: Expectation(
            buttons: unpaidButtons,
            present: ["Entitlement.Status.Reconnect", "Entitlement.Message.ReconnectToRestore"],
            absent: ["Entitlement.Status.Lapsed"]
        ),
        .otherAccount: Expectation(
            buttons: [],
            present: ["Entitlement.Status.OtherAccount", "Entitlement.Status.OtherAccount.Notice"],
            absent: [planActive]
        ),
        .restoreRunning: Expectation(
            buttons: unpaidButtons,
            present: [restoring],
            absent: [restoreDetail, "IAP.Message.RestoreCompleted", "IAP.Message.NothingToRestore"]
        ),
        .restoreRestored: Expectation(buttons: paidButtons, present: ["IAP.Message.RestoreCompleted", restoreDetail]),
        .restoreNothing: Expectation(buttons: unpaidButtons, present: ["IAP.Message.NothingToRestore"]),
        .restoreInProgressElsewhere: Expectation(buttons: unpaidButtons, present: ["IAP.Message.StoreOperationInProgress"]),
        .restoreFailed: Expectation(buttons: unpaidButtons, present: ["Entitlement.Message.NoConnection"], absent: ["IAP.Message.RestoreCompleted"]),
        .freeAccess: Expectation(
            buttons: freeButtons,
            present: [freeAccess, freeNotice, restoreDetail, linkOptional],
            absent: [renewsUntilCancelled, managedByApple, "Entitlement.Status.Inactive"],
            absentWithDate: [("Entitlement.Status.FreeUntil", 5)]
        ),
        .freeAppStoreRenews: Expectation(
            buttons: freeSubscriberButtons,
            present: [freeAccess, freeNotice, renewsUntilCancelled, linked],
            presentWithDate: [("Entitlement.Status.FreeAccess.AccountUntil", 30), ("Entitlement.Plan.RenewsOn", 30)],
            absent: [managedByApple],
            absentWithDate: [("Entitlement.Status.AvailableUntil", 30)]
        ),
        .freeAppStoreEnds: Expectation(
            buttons: freeSubscriberButtons,
            present: [freeAccess, managedByApple],
            presentWithDate: [("Entitlement.Plan.EndsOn", 12)],
            absent: [renewsUntilCancelled]
        ),
        .freeRestoreNothing: Expectation(
            buttons: freeButtons,
            present: [freeAccess, "IAP.Message.NothingToRestore"],
            absentWithDate: [("Entitlement.Status.FreeUntil", 5)]
        )
    ]

    override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
    }

    func testEveryScenarioRendersItsStateActionsAndTargets() throws {
        XCTAssertEqual(Set(Self.expectations.keys), Set(SGPayWallStatusPreviewScenario.allCases), "every scenario needs an expectation")
        let tables = try Dictionary(uniqueKeysWithValues: Self.languages.map { ($0, try Self.table(for: $0)) })
        let app = XCUIApplication(bundleIdentifier: Self.hostBundleId)
        for scenario in SGPayWallStatusPreviewScenario.allCases {
            for lang in Self.languages {
                try XCTContext.runActivity(named: "\(scenario.rawValue)/\(lang)") { _ in
                    try check(scenario: scenario, lang: lang, table: tables[lang] ?? [:], app: app)
                }
            }
        }
        app.terminate()
    }

    // MARK: - One case

    private func check(scenario: SGPayWallStatusPreviewScenario, lang: String, table: [String: String], app: XCUIApplication) throws {
        let context = "\(scenario.rawValue)/\(lang)"
        let expectation = try XCTUnwrap(Self.expectations[scenario])
        func text(_ key: String, _ args: CVarArg...) throws -> String {
            let format = try XCTUnwrap(table[key], "\(context): \(key) missing in \(lang)")
            return args.isEmpty ? format : String(format: format, arguments: args)
        }

        app.terminate()
        app.launchArguments = ["-scenario", scenario.rawValue, "-lang", lang]
        app.launch()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 15), "\(context): the status screen never appeared")

        let root = try app.snapshot()
        let screen = try XCTUnwrap(Self.first(in: root, where: { $0.elementType == .scrollView }), "\(context): no scroll view")
        let nodes = Self.flatten(screen)
        let labels = nodes.map { $0.label }.filter { !$0.isEmpty }
        XCTAssertFalse(labels.isEmpty, "\(context): the screen exposed no labelled elements")

        for label in labels {
            for prefix in ["Entitlement.", "PayWall.", "IAP.Message.", "LinkAccount."] {
                XCTAssertFalse(label.contains(prefix), "\(context): raw key on screen: \(label)")
            }
        }
        for key in expectation.present {
            let expected = try text(key)
            XCTAssertTrue(labels.contains { $0.contains(expected) }, "\(context): missing \(key) (\(expected))")
        }
        for (key, days) in expectation.presentWithDate {
            let date = SGPayWallStatusPreviewScenario.referenceNow.addingTimeInterval(days * 86_400)
            let expected = try text(key, Self.dateText(date, lang: lang))
            XCTAssertTrue(labels.contains { $0.contains(expected) }, "\(context): missing \(key) (\(expected))")
        }
        for key in expectation.absent {
            let forbidden = try text(key)
            XCTAssertFalse(labels.contains { $0.contains(forbidden) }, "\(context): must not show \(key) (\(forbidden))")
        }
        for (key, days) in expectation.absentWithDate {
            let date = SGPayWallStatusPreviewScenario.referenceNow.addingTimeInterval(days * 86_400)
            let forbidden = try text(key, Self.dateText(date, lang: lang))
            XCTAssertFalse(labels.contains { $0.contains(forbidden) }, "\(context): must not show \(key) (\(forbidden))")
        }

        let buttons = nodes.filter { $0.elementType == .button }
        let buttonLabels = buttons.map { $0.label }
        let expectedTitles = try expectation.buttons.map { try text($0) }
        XCTAssertEqual(buttons.count, expectedTitles.count, "\(context): buttons on screen: \(buttonLabels)")
        for title in expectedTitles {
            XCTAssertEqual(buttonLabels.filter { $0.hasPrefix(title) }.count, 1, "\(context): expected one '\(title)' button among \(buttonLabels)")
        }
        let restoreTitle = try text(Self.restore)
        for button in buttons {
            let element = app.scrollViews.firstMatch.buttons.matching(NSPredicate(format: "label == %@", button.label)).firstMatch
            let expectedEnabled = !(scenario == .restoreRunning && button.label.hasPrefix(restoreTitle))
            XCTAssertEqual(element.isEnabled, expectedEnabled, "\(context): button '\(button.label)' has the wrong enabled state")
            if expectedEnabled {
                for _ in 0 ..< 4 {
                    if element.isHittable {
                        break
                    }
                    app.swipeUp()
                }
                XCTAssertTrue(element.isHittable, "\(context): button '\(button.label)' cannot be reached")
            }
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(context): button '\(button.label)' is \(element.frame.height) pt tall")
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(context): button '\(button.label)' is \(element.frame.width) pt wide")
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = context.replacingOccurrences(of: "/", with: "-")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    /// The app's own SGLocalizable table for `lang`, bundled into this test bundle.
    private static func table(for lang: String) throws -> [String: String] {
        let bundle = Bundle(for: StatusPreviewUITests.self)
        let path = try XCTUnwrap(bundle.path(forResource: "SGLocalizable", ofType: "strings", inDirectory: nil, forLocalization: lang), "SGLocalizable.strings missing for \(lang) in the test bundle")
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    /// The renderer's date presentation: medium style in the app language. Host and runner share
    /// the simulator's time zone.
    private static func dateText(_ date: Date, lang: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: lang)
        return formatter.string(from: date)
    }

    private static func first(in node: XCUIElementSnapshot, where predicate: (XCUIElementSnapshot) -> Bool) -> XCUIElementSnapshot? {
        if predicate(node) {
            return node
        }
        for child in node.children {
            if let found = first(in: child, where: predicate) {
                return found
            }
        }
        return nil
    }

    private static func flatten(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        return [node] + node.children.flatMap { flatten($0) }
    }
}
