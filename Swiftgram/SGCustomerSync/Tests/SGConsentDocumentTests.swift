import Foundation
import XCTest
@testable import SGCustomerSyncCore

/// Zenlygram — the consent text as the wall shows it (contract §5.5, design 40 §4.3): the Markdown
/// subset, the age statement, and `plainText()` parity with the hashed canonical text.
final class SGConsentDocumentTests: XCTestCase {
    func testHeadingsParagraphsBulletsAndBold() {
        let document = SGConsentDocument.parse("# Title\n\nIntro **bold** tail\n\n## 1. Section\n\n- **A:** one\n- two\n\n## 2. Age\n\nI am 18.")
        XCTAssertEqual(document.blocks, [
            .heading(level: 1, runs: [SGConsentRun(text: "Title")]),
            .paragraph(runs: [SGConsentRun(text: "Intro "), SGConsentRun(text: "bold", isBold: true), SGConsentRun(text: " tail")]),
            .heading(level: 2, runs: [SGConsentRun(text: "1. Section")]),
            .list(items: [[SGConsentRun(text: "A:", isBold: true), SGConsentRun(text: " one")], [SGConsentRun(text: "two")]]),
            .heading(level: 2, runs: [SGConsentRun(text: "2. Age")]),
            .paragraph(runs: [SGConsentRun(text: "I am 18.")]),
        ])
        XCTAssertEqual(document.ageStatementIndex, 5)
        XCTAssertEqual(document.ageStatement, [SGConsentRun(text: "I am 18.")])
        XCTAssertEqual(document.body.count, 5)
        XCTAssertFalse(document.body.contains(.paragraph(runs: [SGConsentRun(text: "I am 18.")])))
        XCTAssertEqual(document.plainText(), "Title\n\nIntro bold tail\n\n1. Section\n\nA: one\ntwo\n\n2. Age\n\nI am 18.")
    }

    func testAnHttpsLinkIsALinkAndAnyOtherTargetIsText() throws {
        let document = SGConsentDocument.parse("See [site](https://zenlygram.org/account/delete), [plain](http://example.org) and [js](javascript:void) or [](https://x.org) [a](b c)")
        guard case let .paragraph(runs) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("a paragraph")
        }
        XCTAssertEqual(runs, [
            SGConsentRun(text: "See "),
            SGConsentRun(text: "site", link: URL(string: "https://zenlygram.org/account/delete")),
            SGConsentRun(text: ", "),
            SGConsentRun(text: "plain"),
            SGConsentRun(text: " and "),
            SGConsentRun(text: "js"),
            SGConsentRun(text: " or [](https://x.org) [a](b c)"),
        ])
    }

    func testAnUnpairedMarkerIsLiteralAndALinkMayBeBold() throws {
        XCTAssertEqual(SGConsentDocument.parse("a ** b").blocks, [.paragraph(runs: [SGConsentRun(text: "a ** b")])])
        XCTAssertEqual(SGConsentDocument.parse("**[x](https://a.uz)** y").blocks, [
            .paragraph(runs: [SGConsentRun(text: "x", isBold: true, link: URL(string: "https://a.uz")), SGConsentRun(text: " y")]),
        ])
        // `#Title` (no space) and `### x` are not headings of the subset: plain text.
        XCTAssertEqual(SGConsentDocument.parse("#Title\n### x").blocks, [.paragraph(runs: [SGConsentRun(text: "#Title\n### x")])])
    }

    func testTheAgeStatementIsTheFirstParagraphOfTheFinalSection() {
        let document = SGConsentDocument.parse("## 1. A\n\nx\n\n## 2. B\n\n- item\n\nfirst\n\nsecond")
        XCTAssertEqual(document.ageStatement, [SGConsentRun(text: "first")])
        XCTAssertEqual(document.body.last, .paragraph(runs: [SGConsentRun(text: "second")]))
        XCTAssertNil(SGConsentDocument.parse("# Only\n\ntext").ageStatement, "no ## section")
        XCTAssertNil(SGConsentDocument.parse("## 1. A\n\n- only a list").ageStatement)
    }

    func testPlainTextEqualsTheCanonicalTextWithoutMarkupForEveryVendoredText() throws {
        let repository = try SGCustomerSyncTestFixtures.repository()
        let values = try SGCustomerSyncTestFixtures.uzVectorOperatorValues()
        for locale in SGConsentLocale.allCases {
            for operatorValues in [values, SGConsentOperatorValues.none] {
                let rendered = try XCTUnwrap(repository.render(version: 1, locale: locale, operatorValues: operatorValues))
                XCTAssertEqual(rendered.document, SGConsentDocument.parse(rendered.canonical))
                XCTAssertEqual(
                    rendered.document.plainText().unicodeScalars.map(\.value),
                    try self.withoutMarkup(rendered.canonical).unicodeScalars.map(\.value),
                    "\(locale): what is hashed is what is shown"
                )
            }
        }
    }

    func testEveryLinkOfTheVendoredTextsIsShownAsItsHttpsTarget() throws {
        let repository = try SGCustomerSyncTestFixtures.repository()
        let pattern = try NSRegularExpression(pattern: "\\]\\((https://[^()\\s]+)\\)")
        for locale in SGConsentLocale.allCases {
            let rendered = try XCTUnwrap(repository.render(version: 1, locale: locale, operatorValues: try SGCustomerSyncTestFixtures.uzVectorOperatorValues()))
            let canonical = rendered.canonical as NSString
            let expected = pattern.matches(in: rendered.canonical, range: NSRange(location: 0, length: canonical.length)).map { canonical.substring(with: $0.range(at: 1)) }
            XCTAssertEqual(Set(expected), ["https://zenlygram.org/account/delete", "https://zenlygram.org/privacy-policy.html"], "\(locale)")
            XCTAssertEqual(self.links(rendered.document).map(\.absoluteString), expected, "\(locale)")
        }
    }

    func testTheVendoredAgeStatementIsTheTextsLastParagraph() throws {
        let repository = try SGCustomerSyncTestFixtures.repository()
        for locale in SGConsentLocale.allCases {
            let rendered = try XCTUnwrap(repository.render(version: 1, locale: locale, operatorValues: .none))
            let lastParagraph = try XCTUnwrap(rendered.canonical.components(separatedBy: "\n\n").last)
            let ageStatement = try XCTUnwrap(rendered.document.ageStatement, "\(locale)")
            XCTAssertEqual(SGConsentDocument.plainText(of: ageStatement).unicodeScalars.map(\.value), lastParagraph.unicodeScalars.map(\.value), "\(locale)")
            XCTAssertEqual(rendered.document.body.count, rendered.document.blocks.count - 1)
        }
    }

    // MARK: - Helpers

    /// The canonical text with the subset's markup removed, written independently of the parser:
    /// line markers `## `, `# `, `- `, then links to their text, then `**`.
    private func withoutMarkup(_ canonical: String) throws -> String {
        let link = try NSRegularExpression(pattern: "\\[([^\\[\\]\\n]+)\\]\\(([^()\\s]+)\\)")
        let lines = canonical.components(separatedBy: "\n").map { line -> String in
            for marker in ["## ", "# ", "- "] where line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
            return line
        }
        let joined = lines.joined(separator: "\n")
        let unlinked = link.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length), withTemplate: "$1")
        return unlinked.replacingOccurrences(of: "**", with: "")
    }

    private func links(_ document: SGConsentDocument) -> [URL] {
        var links: [URL] = []
        for block in document.blocks {
            switch block {
            case let .heading(_, runs), let .paragraph(runs):
                links += runs.compactMap(\.link)
            case let .list(items):
                links += items.flatMap { $0.compactMap(\.link) }
            }
        }
        return links
    }
}
