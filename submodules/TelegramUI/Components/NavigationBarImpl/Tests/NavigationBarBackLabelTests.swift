import XCTest
import UIKit
import AsyncDisplayKit
import Display
import NavigationBarImpl

/// Zenlygram — regression coverage for the navigation bar's Back carrying the bar's own Back label (R-I14).
///
/// UIKit reads accessibility from views, top-down, and VoiceOver and XCUITest see what it collects: an element
/// hides its subtree, and a hidden, transparent or `accessibilityElementsHidden` view is skipped with its subtree.
/// The Back's item node keeps its label in a node-level getter that its view never asks, and on a glass bar that
/// node is zero-width, so no element carried the Back string: a glass Back read as one unlabelled 44 pt control
/// (Settings -> Zenlygram) and a legacy Back as a bare "button" (Data & Consent and its pages).
///
/// The bars are built from Display-only presentation data with a sentinel Back string. A logic test has no app
/// bundle, so nothing here builds `PresentationStrings` or `PresentationData`.
final class NavigationBarBackLabelTests: XCTestCase {
    private static let backSentinel = "ZG-Back-Sentinel"

    /// An iPhone 17 bar: a 54 pt status bar over the 60 pt default content height.
    private static let barSize = CGSize(width: 402.0, height: 114.0)

    private struct Fixture {
        let bar: NavigationBarImpl
        let item: UINavigationItem
        let theme: NavigationBarTheme
    }

    private var savedDefaultNavigationBarImpl: ((NavigationBarPresentationData) -> NavigationBar)?

    override func setUp() {
        super.setUp()
        self.savedDefaultNavigationBarImpl = defaultNavigationBarImpl
    }

    override func tearDown() {
        // A process-wide global that `ViewController.init` reads.
        defaultNavigationBarImpl = self.savedDefaultNavigationBarImpl
        self.savedDefaultNavigationBarImpl = nil
        super.tearDown()
    }

    // MARK: - Bars

    private static func theme(style: NavigationBarStyle) -> NavigationBarTheme {
        return NavigationBarTheme(
            overallDarkAppearance: false,
            buttonColor: .blue,
            disabledButtonColor: .gray,
            primaryTextColor: .black,
            backgroundColor: .white,
            enableBackgroundBlur: false,
            separatorColor: .lightGray,
            badgeBackgroundColor: .red,
            badgeStrokeColor: .red,
            badgeTextColor: .white,
            accentButtonColor: .blue,
            accentDisabledButtonColor: .gray,
            accentForegroundColor: .white,
            style: style
        )
    }

    private static func strings(back: String = NavigationBarBackLabelTests.backSentinel, close: String = "ZG-Close") -> NavigationBarStrings {
        return NavigationBarStrings(back: back, close: close)
    }

    /// A screen titled "Zenlygram" pushed from "Settings", its bar laid out the way `ViewController` lays it out.
    private func makeBarShowingBack(style: NavigationBarStyle) -> Fixture {
        let theme = NavigationBarBackLabelTests.theme(style: style)
        let bar = NavigationBarImpl(presentationData: NavigationBarPresentationData(theme: theme, strings: NavigationBarBackLabelTests.strings()))
        let item = UINavigationItem(title: "Zenlygram")
        bar.item = item
        bar.previousItem = .item(UINavigationItem(title: "Settings"))
        self.layOut(bar)
        return Fixture(bar: bar, item: item, theme: theme)
    }

    /// The bar lays out its content for the size; its frame belongs to the parent, which sets it afterwards.
    private func layOut(_ bar: NavigationBarImpl) {
        bar.updateLayout(size: NavigationBarBackLabelTests.barSize, defaultHeight: 60.0, additionalTopHeight: 54.0, additionalContentHeight: 0.0, additionalBackgroundHeight: 0.0, additionalCutout: nil, leftInset: 0.0, rightInset: 0.0, appearsHidden: false, isLandscape: false, transition: .immediate)
        bar.frame = CGRect(origin: CGPoint(), size: NavigationBarBackLabelTests.barSize)
    }

    /// An iPhone 17 screen in portrait.
    private static var phoneLayout: ContainerViewLayout {
        return ContainerViewLayout(
            size: CGSize(width: 402.0, height: 874.0),
            metrics: LayoutMetrics(widthClass: .compact, heightClass: .regular, orientation: .portrait),
            deviceMetrics: .iPhone16Pro,
            intrinsicInsets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: 34.0, right: 0.0),
            safeInsets: UIEdgeInsets(),
            additionalInsets: UIEdgeInsets(),
            statusBarHeight: 54.0,
            inputHeight: nil,
            inputHeightIsInteractivellyChanging: false,
            inVoiceOver: false
        )
    }

    // MARK: - Accessibility, collected as UIKit collects it

    /// The elements UIKit finds under `object`, top-down: an element hides its subtree; a hidden, transparent or
    /// `accessibilityElementsHidden` view is skipped with its subtree; an explicit `accessibilityElements` list
    /// takes the place of the subviews.
    private func accessibilityElements(under object: NSObject) -> [NSObject] {
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 {
            return []
        }
        if object.accessibilityElementsHidden {
            return []
        }
        if object.isAccessibilityElement {
            return [object]
        }
        if let explicitElements = object.accessibilityElements {
            return explicitElements.compactMap({ $0 as? NSObject }).flatMap({ self.accessibilityElements(under: $0) })
        }
        if let view = object as? UIView {
            return view.subviews.flatMap({ self.accessibilityElements(under: $0) })
        }
        return []
    }

    private func elements(in bar: NavigationBar, labelled label: String) -> [NSObject] {
        return self.accessibilityElements(under: bar.view).filter({ $0.accessibilityLabel == label })
    }

    /// The bar's Back: exactly one element is named `label`, and it is a view with the button trait.
    private func backElement(in bar: NavigationBar, labelled label: String, _ context: String) throws -> UIView {
        let labelled = self.elements(in: bar, labelled: label)
        XCTAssertEqual(labelled.count, 1, "\(context): \(labelled.count) accessibility elements are named \"\(label)\"")
        let element = try XCTUnwrap(labelled.first as? UIView, "\(context): no view is named \"\(label)\"")
        XCTAssertTrue(element.accessibilityTraits.contains(.button), "\(context): the Back is not announced as a button")
        return element
    }

    /// A tap at the element's centre reaches the Back, so the named element is also the one that works.
    private func assertTapAtCentre(of element: UIView, in bar: NavigationBar, reaches target: UIView, _ context: String) {
        let centre = element.convert(CGPoint(x: element.bounds.midX, y: element.bounds.midY), to: bar.view)
        let hit = bar.view.hitTest(centre, with: nil)
        XCTAssertNotNil(hit, "\(context): nothing is hit at the Back's centre \(centre)")
        if let hit {
            XCTAssertTrue(hit.isDescendant(of: target), "\(context): a tap at the Back's centre \(centre) reaches \(hit), not the Back")
        }
    }

    private func viewAndAncestors(of view: UIView, upTo root: UIView) -> [UIView] {
        var result: [UIView] = []
        var current: UIView? = view
        while let candidate = current {
            result.append(candidate)
            if candidate === root {
                break
            }
            current = candidate.superview
        }
        return result
    }

    /// No element is named with the Back string; the view that carried it is no longer an element, named Back or a
    /// button (a DEBUG `_ASDisplayView` answers a nil label with its node's description, so the label is compared
    /// with the Back string, not with nil); and neither the back node nor the left button node is, or sits in, an
    /// element, which would hide a Cancel or Close button.
    private func assertNoBackElement(in bar: NavigationBar, formerBack: UIView, _ context: String) {
        XCTAssertEqual(self.elements(in: bar, labelled: NavigationBarBackLabelTests.backSentinel).count, 0, "\(context): an element is still named Back")
        XCTAssertFalse(formerBack.isAccessibilityElement, "\(context): the former Back is still an accessibility element")
        XCTAssertNotEqual(formerBack.accessibilityLabel, NavigationBarBackLabelTests.backSentinel, "\(context): the former Back keeps the Back label")
        XCTAssertTrue(formerBack.accessibilityTraits.isEmpty, "\(context): the former Back keeps its traits")
        let nodes: [(name: String, node: ASDisplayNode)] = [("back node", bar.backButtonNode), ("left button node", bar.leftButtonNode)]
        for (name, node) in nodes {
            let elementsAbove = self.viewAndAncestors(of: node.view, upTo: bar.view).filter({ $0.isAccessibilityElement })
            XCTAssertTrue(elementsAbove.isEmpty, "\(context): the \(name) sits in an accessibility element: \(elementsAbove)")
        }
    }

    // MARK: - Glass bar (Settings -> Zenlygram)

    func test_glassBar_backIsTheLabelledGlassAroundTheBackNode_andATapAtItsCentreReachesTheBack() throws {
        let bar = self.makeBarShowingBack(style: .glass).bar
        let back = try self.backElement(in: bar, labelled: NavigationBarBackLabelTests.backSentinel, "glass")
        let backNodeView = bar.backButtonNode.view

        XCTAssertTrue(back !== backNodeView && backNodeView.isDescendant(of: back), "glass: the Back element is not the glass around the back node")
        XCTAssertFalse(backNodeView.isAccessibilityElement, "glass: the back node itself must not be a second element")
        XCTAssertGreaterThanOrEqual(back.bounds.width, 44.0, "glass: the Back is narrower than the 44 pt glass")
        XCTAssertGreaterThanOrEqual(back.bounds.height, 44.0, "glass: the Back is lower than the 44 pt glass")
        self.assertTapAtCentre(of: back, in: bar, reaches: backNodeView, "glass")
    }

    func test_glassBar_leftButtonOrHiddenBack_leavesNoBackElement_andTheLabelReturnsWithTheBack() throws {
        try self.checkBackLabelLeavesWithTheBack(style: .glass, "glass")
    }

    func test_glassBar_languageChange_relabelsTheBack() throws {
        try self.checkLanguageChangeRelabelsTheBack(style: .glass, "glass")
    }

    // MARK: - Legacy bar (Data & Consent, Consent text, My Data, Account deletion)

    func test_legacyBar_backIsTheLabelledBackNode_andATapAtItsCentreReachesTheBack() throws {
        let bar = self.makeBarShowingBack(style: .legacy).bar
        let back = try self.backElement(in: bar, labelled: NavigationBarBackLabelTests.backSentinel, "legacy")

        XCTAssertTrue(back === bar.backButtonNode.view, "legacy: the Back element is not the back node")
        XCTAssertFalse(back.bounds.isEmpty, "legacy: the Back has empty bounds")
        self.assertTapAtCentre(of: back, in: bar, reaches: bar.backButtonNode.view, "legacy")
    }

    func test_legacyBar_leftButtonOrHiddenBack_leavesNoBackElement_andTheLabelReturnsWithTheBack() throws {
        try self.checkBackLabelLeavesWithTheBack(style: .legacy, "legacy")
    }

    func test_legacyBar_languageChange_relabelsTheBack() throws {
        try self.checkLanguageChangeRelabelsTheBack(style: .legacy, "legacy")
    }

    /// The bar a pushed `ViewController` gets from `defaultNavigationBarImpl` (as the Data & Consent screens get
    /// theirs), laid out by the controller itself.
    func test_viewControllerBar_exposesExactlyOneBack() throws {
        defaultNavigationBarImpl = { presentationData in
            return NavigationBarImpl(presentationData: presentationData)
        }
        let controller = ViewController(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarBackLabelTests.theme(style: .legacy), strings: NavigationBarBackLabelTests.strings()))
        controller.navigationItem.title = "Data & Consent"
        let bar = try XCTUnwrap(controller.navigationBar, "harness: the controller has no navigation bar")
        bar.previousItem = .item(UINavigationItem(title: "Zenlygram"))
        controller.updateNavigationBarLayout(NavigationBarBackLabelTests.phoneLayout, transition: .immediate)
        XCTAssertEqual(bar.frame.size, NavigationBarBackLabelTests.barSize, "harness: the controller laid out an unexpected bar")

        let back = try self.backElement(in: bar, labelled: NavigationBarBackLabelTests.backSentinel, "view controller")
        XCTAssertTrue(back === bar.backButtonNode.view, "view controller: the Back element is not the back node")
        self.assertTapAtCentre(of: back, in: bar, reaches: bar.backButtonNode.view, "view controller")
    }

    // MARK: - Shared checks

    /// From a shown, labelled Back: (a) a Cancel left button replaces it, (b) it shows again once Cancel is
    /// gone, (c) the previous item goes away and the Back is hidden.
    private func checkBackLabelLeavesWithTheBack(style: NavigationBarStyle, _ context: String) throws {
        let fixture = self.makeBarShowingBack(style: style)
        let bar = fixture.bar
        let shownBack = try self.backElement(in: bar, labelled: NavigationBarBackLabelTests.backSentinel, "\(context), shown")

        fixture.item.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: nil, action: nil)
        self.layOut(bar)
        XCTAssertNotNil(bar.leftButtonNode.view.superview, "\(context), Cancel: harness: the Cancel button is not shown")
        self.assertNoBackElement(in: bar, formerBack: shownBack, "\(context), Cancel")

        fixture.item.leftBarButtonItem = nil
        self.layOut(bar)
        let shownAgain = try self.backElement(in: bar, labelled: NavigationBarBackLabelTests.backSentinel, "\(context), shown again")
        XCTAssertTrue(shownAgain === shownBack, "\(context), shown again: the Back moved to another element")

        bar.previousItem = nil
        self.layOut(bar)
        XCTAssertNil(bar.backButtonNode.view.superview, "\(context), hidden: harness: the Back is still shown")
        self.assertNoBackElement(in: bar, formerBack: shownBack, "\(context), hidden")
    }

    /// A language change hands the bar new strings; the Back takes the new label (Uzbek "Orqaga").
    private func checkLanguageChangeRelabelsTheBack(style: NavigationBarStyle, _ context: String) throws {
        let fixture = self.makeBarShowingBack(style: style)
        let bar = fixture.bar
        let before = try self.backElement(in: bar, labelled: NavigationBarBackLabelTests.backSentinel, "\(context), before")

        bar.updatePresentationData(NavigationBarPresentationData(theme: fixture.theme, strings: NavigationBarBackLabelTests.strings(back: "Orqaga", close: "Yopish")), transition: .immediate)
        self.layOut(bar)

        let after = try self.backElement(in: bar, labelled: "Orqaga", "\(context), after")
        XCTAssertTrue(after === before, "\(context), after: the Back moved to another element")
        XCTAssertEqual(self.elements(in: bar, labelled: NavigationBarBackLabelTests.backSentinel).count, 0, "\(context), after: an element keeps the old Back label")
    }
}
