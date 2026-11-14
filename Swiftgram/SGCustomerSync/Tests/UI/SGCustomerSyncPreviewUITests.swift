import Foundation
import XCTest

// MARK: Zenlygram — UI tests over the consent screens' REAL views (design 40 §15.6), as an outside client sees them.
//
// Each case launches the test-only host (`org.zenlygram.SGCustomerSyncPreviewHost`) with `-scenario <name> -lang
// <uz|ru|en>`; the host renders the production `Sources/UI/Views/**` over that fixture state and touches no
// SGEntitlement, consent store, network or persistence. The same bundle runs on iPhone 17
// (`SGCustomerSyncPreviewTests`) and on iPad Pro 13-inch (M5) (`SGCustomerSyncPreviewPadTests`). Asserted:
//  - every scenario shows exactly its `zg.*` identifiers (and none of the absent ones), its captions, and no raw
//    localization key; the notice line, Data & consent's status and the withdraw confirmation read exactly the
//    strings the tables hold (with the dates in Asia/Tashkent, as the screens show them);
//  - on the wall: "I agree" is disabled until the age box is ticked; "I don't agree" is there, under it, smaller and
//    quiet (a text button, not a second filled one); the summary paragraph reads `Consent.Wall.Summary`; the account
//    line and the mode note are visible; with no notice the whole page fits without scrolling ("I agree" and "I don't
//    agree" are hittable as soon as the wall or the prompt appears); the content column is at most 640 pt wide on
//    iPad; the wall page carries neither
//    the language control nor the document — "Consent text" opens the text page, where the language segment changes
//    the captions and the document, and Back brings the chosen language back to the wall;
//  - the prompt's close glyph reads as "I don't agree".
// Expected copy comes from the same SGLocalizable.strings tables the app ships (bundled into this test bundle), so a
// translation change cannot silently diverge. A screenshot of every case is attached to the result bundle.
final class SGCustomerSyncPreviewUITests: XCTestCase {
    private static let hostBundleId = "org.zenlygram.SGCustomerSyncPreviewHost"
    private static let languages = ["uz", "ru", "en"]
    private static let segments = ["uz": "Oʻzbekcha", "ru": "Русский", "en": "English"]
    /// A caption that is shown as its key means the key is missing from the table.
    private static let rawKeyPrefixes = ["Consent.Wall.", "Consent.Declined.", "DataConsent.", "Settings.Data.", "AccountDelete.", "MyData.", "Common."]

    private var tables: [String: [String: String]] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.continueAfterFailure = false
        for lang in Self.languages {
            self.tables[lang] = try Self.table(for: lang)
        }
    }

    // MARK: - Every scenario

    /// Every scenario once, the languages in turn (the wall and the language control get all three below).
    func testEveryScenarioShowsItsIdentifiersAndCaptions() throws {
        for (index, scenario) in SGCustomerSyncPreviewScenario.allCases.enumerated() {
            let lang = Self.languages[index % Self.languages.count]
            try XCTContext.runActivity(named: "\(scenario.rawValue)/\(lang)") { _ in
                try self.check(scenario, lang: lang)
            }
        }
    }

    private func check(_ scenario: SGCustomerSyncPreviewScenario, lang: String) throws {
        let context = "\(scenario.rawValue)/\(lang)"
        let table = try XCTUnwrap(self.tables[lang])
        let app = self.launch(scenario, lang: lang)

        if let withdrawal = scenario.withdrawal {
            try self.checkWithdrawAlert(app: app, withdrawal: withdrawal, lang: lang, context: context)
        } else {
            let root = app.descendants(matching: .any)[scenario.rootIdentifier]
            XCTAssertTrue(root.waitForExistence(timeout: 20), "\(context): \(scenario.rootIdentifier) never appeared")
        }
        for identifier in scenario.presentIdentifiers {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].exists, "\(context): \(identifier) is missing")
        }
        for identifier in scenario.absentIdentifiers {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].exists, "\(context): \(identifier) must not be shown")
        }

        let labels = Self.flatten(try app.snapshot()).map { $0.label }.filter { !$0.isEmpty }
        XCTAssertFalse(labels.isEmpty, "\(context): the screen exposed no labelled elements")
        for label in labels {
            for prefix in Self.rawKeyPrefixes {
                XCTAssertFalse(label.contains(prefix), "\(context): raw key on screen: \(label)")
            }
        }
        for key in scenario.presentKeys {
            let expected = try XCTUnwrap(table[key], "\(context): \(key) is missing in \(lang)").lowercased()
            XCTAssertTrue(labels.contains { $0.lowercased().contains(expected) }, "\(context): \(key) (\(expected)) is not on screen")
        }

        if let notice = scenario.noticeKey {
            let format = try XCTUnwrap(table[notice.key], "\(context): \(notice.key)")
            let expected = notice.dated ? Self.sentence(String(format: format, Self.decisionDateText(lang))) : format
            let label = app.descendants(matching: .any)["zg.consent.notice"].label
            XCTAssertTrue(label.contains(expected), "\(context): the notice reads '\(label)', expected '\(expected)'")
        }
        if let status = scenario.dataStatus {
            let format = try XCTUnwrap(table[status.key], "\(context): \(status.key)")
            var arguments: [CVarArg] = []
            if status.dated {
                arguments.append(Self.decisionDateText(lang))
            }
            if let version = status.version {
                arguments.append(version)
            }
            let expected = arguments.isEmpty ? format : Self.sentence(String(format: format, arguments: arguments))
            XCTAssertEqual(app.descendants(matching: .any)["zg.data.status"].label, expected, "\(context): the status line")
        }
        if scenario.screen == .prompt {
            XCTAssertEqual(app.buttons["zg.consent.close"].label, table["Consent.Wall.Decline"], "\(context): the close glyph reads as I don't agree")
        }
        if scenario == .deleteSending {
            XCTAssertFalse(app.buttons["zg.delete.action"].isEnabled, "\(context): no second request while one runs")
        }
        if scenario == .myDataLoaded || scenario == .wallMyData {
            XCTAssertEqual(app.descendants(matching: .any)["zg.mydata.tgid"].label, "\(SGCustomerSyncPreviewScenario.telegramUserId)", "\(context): the Telegram ID")
        }
        self.attachScreenshot(app, name: context)
    }

    private func checkWithdrawAlert(app: XCUIApplication, withdrawal: (unsent: Int?, optional: Bool, linked: Bool), lang: String, context: String) throws {
        let table = try XCTUnwrap(self.tables[lang])
        func text(_ key: String) throws -> String {
            return try XCTUnwrap(table[key], "\(context): \(key) is missing in \(lang)")
        }
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "\(context): the withdraw confirmation never appeared")
        let texts = alert.staticTexts.allElementsBoundByIndex.map { $0.label }
        XCTAssertTrue(texts.contains(try text("DataConsent.Withdraw.Confirm.Title")), "\(context): the title, among \(texts)")
        let message = try XCTUnwrap(texts.first { $0.contains(try text("DataConsent.Withdraw.Confirm.Text")) }, "\(context): no message with the withdraw text among \(texts)")

        var expected = [try text("DataConsent.Withdraw.Confirm.Text")]
        if let unsent = withdrawal.unsent {
            if unsent > 0 {
                expected.append(String(format: try text("DataConsent.Withdraw.Confirm.Unsent.\(Self.pluralForm(unsent, lang: lang))"), unsent))
            }
        } else {
            expected.append(try text("DataConsent.Withdraw.Confirm.UnsentUnknown"))
        }
        expected.append(try text(withdrawal.optional ? "DataConsent.Withdraw.Optional" : "DataConsent.Withdraw.Required"))
        if !withdrawal.linked {
            expected.append(try text("DataConsent.Withdraw.PendingUpload"))
        }
        XCTAssertEqual(message, expected.joined(separator: "\n\n"), "\(context): the confirmation text")
        for key in ["Common.Cancel", "DataConsent.Withdraw.DeleteInstead", "DataConsent.Withdraw.Confirm.Action"] {
            XCTAssertTrue(alert.buttons[try text(key)].exists, "\(context): the \(key) button")
        }
    }

    // MARK: - The wall

    func testTheWallAgreesOnlyAfterTheAgeBoxInEveryLanguage() throws {
        for lang in Self.languages {
            try XCTContext.runActivity(named: "wallNone/\(lang)") { _ in
                try self.checkDecision(.wallNone, lang: lang)
            }
        }
    }

    func testThePromptHasTheSameDecision() throws {
        try self.checkDecision(.promptNone, lang: "en")
    }

    private func checkDecision(_ scenario: SGCustomerSyncPreviewScenario, lang: String) throws {
        let context = "\(scenario.rawValue)/\(lang)"
        let table = try XCTUnwrap(self.tables[lang])
        let app = self.launch(scenario, lang: lang)
        let agree = app.buttons["zg.consent.agree"]
        let decline = app.buttons["zg.consent.decline"]
        XCTAssertTrue(agree.waitForExistence(timeout: 20), "\(context): no I agree")
        XCTAssertEqual(agree.label, table["Consent.Wall.Agree"], "\(context)")
        XCTAssertTrue(decline.exists, "\(context): no I don't agree")
        XCTAssertEqual(decline.label, table["Consent.Wall.Decline"], "\(context)")
        XCTAssertFalse(agree.isEnabled, "\(context): I agree must stay disabled until the age box is ticked")
        if scenario.noticeKey == nil {
            // The point of the minimal wall: with no notice the whole page fits at the default text size, so neither
            // button needs scrolling — on the wall and on the prompt (its close glyph and longer note still leave room).
            XCTAssertTrue(agree.isHittable, "\(context): I agree is below the fold right after the page appears")
            XCTAssertTrue(decline.isHittable, "\(context): I don't agree is below the fold right after the page appears")
        }

        let account = app.descendants(matching: .any)["zg.consent.account"]
        XCTAssertTrue(account.exists && account.isHittable, "\(context): the account line is not visible")
        let accountFormat = try XCTUnwrap(table["Consent.Wall.Account"])
        XCTAssertEqual(account.label, String(format: accountFormat, SGCustomerSyncPreviewScenario.accountLine), "\(context): the account line")

        // The summary paragraph and the "Consent text" row stand in for the document, which is not on this page.
        let summary = app.descendants(matching: .any)["zg.consent.summary"]
        XCTAssertTrue(summary.exists, "\(context): no summary paragraph")
        XCTAssertEqual(summary.label, table["Consent.Wall.Summary"], "\(context): the summary")
        XCTAssertEqual(app.buttons["zg.consent.text"].label, table["DataConsent.ReadText"], "\(context): the Consent text row")
        XCTAssertFalse(app.descendants(matching: .any)["zg.consent.lang"].exists, "\(context): the language control belongs to the text page")
        XCTAssertFalse(app.descendants(matching: .any)["zg.consent.text.body"].exists, "\(context): the document belongs to the text page")

        let age = app.buttons["zg.consent.age"]
        self.reveal(age, in: app, context: context)
        XCTAssertFalse(agree.isEnabled, "\(context): scrolling never enables I agree")
        age.tap()
        XCTAssertTrue(self.waitUntil { agree.isEnabled }, "\(context): ticking the age box did not enable I agree")

        let modeNote = app.descendants(matching: .any)["zg.consent.modenote"]
        self.reveal(decline, in: app, context: context)
        XCTAssertTrue(modeNote.isHittable, "\(context): the mode note is not visible above the buttons")
        let noteKey = scenario.screen == .prompt ? "Consent.Wall.ModeNote.Optional" : "Consent.Wall.ModeNote.Required"
        XCTAssertEqual(modeNote.label, table[noteKey], "\(context): the mode note")
        // Prominent "I agree", quiet "I don't agree": a narrower, no taller text button stacked under the filled one.
        XCTAssertLessThan(decline.frame.width, agree.frame.width, "\(context): I don't agree must be narrower than I agree")
        XCTAssertLessThanOrEqual(decline.frame.height, agree.frame.height, "\(context): I don't agree must be no taller than I agree")
        XCTAssertLessThan(agree.frame.maxY, decline.frame.minY + 1, "\(context): the buttons are stacked")
        XCTAssertEqual(decline.frame.midX, agree.frame.midX, accuracy: 1, "\(context): I don't agree is centred under I agree")

        let window = app.windows.firstMatch.frame
        if window.width > 700 {
            for element in [agree, decline, modeNote] {
                XCTAssertLessThanOrEqual(element.frame.width, 640, "\(context): the content column is wider than 640 pt on iPad")
                XCTAssertGreaterThan(element.frame.minX, window.minX + 16, "\(context): the column is not centred")
            }
        }
        self.attachScreenshot(app, name: "\(context)-decision")
    }

    /// "Consent text" opens the text page; its language segment changes the captions and the document; Back returns
    /// to the wall in the language chosen last (the locale "I agree" would record).
    func testTheLanguageControlOnTheTextPageChangesTheCaptionsAndCarriesBack() throws {
        let app = self.launch(.wallNone, lang: "en")
        XCTAssertTrue(app.buttons["zg.consent.agree"].waitForExistence(timeout: 20), "the wall never appeared")
        XCTAssertFalse(app.descendants(matching: .any)["zg.consent.lang"].exists, "the wall page must not carry the language control")
        XCTAssertFalse(app.descendants(matching: .any)["zg.consent.text.body"].exists, "the wall page must not carry the document")

        let row = app.buttons["zg.consent.text"]
        XCTAssertTrue(row.isHittable, "the Consent text row is not visible")
        row.tap()
        let page = app.descendants(matching: .any)["zg.consent.text.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "the text page never appeared")
        XCTAssertTrue(app.descendants(matching: .any)["zg.consent.lang"].exists, "no language control on the text page")
        XCTAssertFalse(app.buttons["zg.consent.agree"].exists, "no I agree on the text page")
        XCTAssertFalse(app.buttons["zg.consent.decline"].exists, "no I don't agree on the text page")
        XCTAssertFalse(app.descendants(matching: .any)["zg.consent.summary"].exists, "no summary on the text page")

        var bodies: [String: String] = [:]
        for lang in ["ru", "en", "uz"] {
            let table = try XCTUnwrap(self.tables[lang])
            let segmentTitle = try XCTUnwrap(Self.segments[lang])
            let segment = app.segmentedControls.buttons[segmentTitle]
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "no '\(segmentTitle)' segment")
            segment.tap()
            let back = try XCTUnwrap(table["Consent.Declined.Back"])
            XCTAssertTrue(self.waitUntil { app.buttons["zg.consent.text.back"].label == back }, "\(lang): Back reads '\(app.buttons["zg.consent.text.back"].label)'")
            let labels = Self.flatten(try app.snapshot()).map { $0.label }
            XCTAssertTrue(labels.contains(try XCTUnwrap(table["DataConsent.ReadText"])), "\(lang): the title")
            XCTAssertTrue(labels.contains(try XCTUnwrap(table["Consent.Wall.Language"])), "\(lang): the language caption")
            let body = try self.bodyText(app)
            XCTAssertFalse(body.isEmpty, "\(lang): the document is empty")
            XCTAssertEqual(Self.hasCyrillic(body), lang == "ru", "\(lang): the document is not in that language")
            bodies[lang] = body
            self.attachScreenshot(app, name: "text-\(lang)")
        }
        XCTAssertEqual(Set(bodies.values).count, 3, "the document must differ between the three languages")

        // Back: the wall in the language chosen last (uz), its language control still on the text page.
        app.buttons["zg.consent.text.back"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["zg.consent.page"].waitForExistence(timeout: 5), "Back did not return to the wall")
        let uz = try XCTUnwrap(self.tables["uz"])
        XCTAssertEqual(app.buttons["zg.consent.agree"].label, uz["Consent.Wall.Agree"], "I agree after Back")
        XCTAssertEqual(app.buttons["zg.consent.decline"].label, uz["Consent.Wall.Decline"], "I don't agree after Back")
        XCTAssertEqual(app.descendants(matching: .any)["zg.consent.title"].label, uz["Consent.Wall.Title"], "the title after Back")
        XCTAssertEqual(app.descendants(matching: .any)["zg.consent.summary"].label, uz["Consent.Wall.Summary"], "the summary after Back")
        XCTAssertEqual(app.descendants(matching: .any)["zg.consent.modenote"].label, uz["Consent.Wall.ModeNote.Required"], "the mode note after Back")
        XCTAssertFalse(app.descendants(matching: .any)["zg.consent.lang"].exists, "the language control came back to the wall")
        XCTAssertFalse(app.descendants(matching: .any)["zg.consent.text.body"].exists, "the document came back to the wall")
        self.attachScreenshot(app, name: "language-back-uz")
    }

    // MARK: - Helpers

    private func launch(_ scenario: SGCustomerSyncPreviewScenario, lang: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.hostBundleId)
        app.launchArguments = ["-scenario", scenario.rawValue, "-lang", lang]
        app.launch()
        return app
    }

    /// Scrolls the page until `element` can be tapped.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, context: String) {
        let scrollView = app.scrollViews.firstMatch
        var attempts = 0
        while !element.isHittable && attempts < 30 {
            scrollView.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.isHittable, "\(context): \(element.identifier) cannot be reached")
    }

    /// The document on the text page, as its accessibility labels read top to bottom.
    private func bodyText(_ app: XCUIApplication) throws -> String {
        let body = app.descendants(matching: .any)["zg.consent.text.body"]
        XCTAssertTrue(body.exists, "no document on the text page")
        return Self.flatten(try body.snapshot()).map { $0.label }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Whether `text` holds a Cyrillic letter (the ru document does; the en and the Latin-script uz ones do not).
    private static func hasCyrillic(_ text: String) -> Bool {
        return text.unicodeScalars.contains { (0x0400 ... 0x04FF).contains($0.value) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name.replacingOccurrences(of: "/", with: "-")
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    /// The decision date as the screens show it: medium style in the language, Asia/Tashkent.
    private static func decisionDateText(_ lang: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang)
        formatter.timeZone = TimeZone(identifier: SGCustomerSyncPreviewScenario.decisionTimeZone)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: SGCustomerSyncPreviewScenario.decisionDate)
    }

    /// A dated caption as the screens show it: a date ending in an abbreviation's period also ends the sentence
    /// (`SGCustomerSyncFormat.sentence`).
    private static func sentence(_ text: String) -> String {
        return text.replacingOccurrences(of: "..", with: ".")
    }

    /// The plural key a count reads with (as `SGCustomerPlural`): ru by the CLDR rule, uz one form, en one/other.
    private static func pluralForm(_ n: Int, lang: String) -> String {
        switch lang {
        case "ru":
            if n % 10 == 1 && n % 100 != 11 {
                return "One"
            }
            if (2 ... 4).contains(n % 10) && !(12 ... 14).contains(n % 100) {
                return "Few"
            }
            return "Many"
        case "uz":
            return "Many"
        default:
            return n == 1 ? "One" : "Many"
        }
    }

    /// The app's own SGLocalizable table for `lang`, bundled into this test bundle.
    private static func table(for lang: String) throws -> [String: String] {
        let bundle = Bundle(for: SGCustomerSyncPreviewUITests.self)
        let path = try XCTUnwrap(bundle.path(forResource: "SGLocalizable", ofType: "strings", inDirectory: nil, forLocalization: lang), "SGLocalizable.strings missing for \(lang) in the test bundle")
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    private static func flatten(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        return [node] + node.children.flatMap { Self.flatten($0) }
    }
}
