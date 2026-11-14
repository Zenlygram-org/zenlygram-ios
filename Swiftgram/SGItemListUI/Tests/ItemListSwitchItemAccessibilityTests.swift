import XCTest
import UIKit
import Display
import ItemListUI
import TelegramPresentationData
import TelegramUIPreferences

// Zenlygram — QA 10004: the Secret Vault switch was drawn Off after a cancelled PIN prompt while the setting
// stayed On. The Settings rows are controlled switches (`enableInteractiveChanges: false`). These tests build
// the production `ItemListSwitchItemNode` through the public `ListViewItem` API and drive it the way people do:
// VoiceOver activates the row's accessibility element (its `AccessibilityAreaNode` view) and reads its spoken
// value; a touch or an accessibility action on the native control arrives as `.valueChanged`. They read the real
// `UISwitch` the node draws. Both switch types (`.regular` / `.icon`) and both control modes are covered.

private let title = "Secret Vault"

private let strings = PresentationStrings(primaryComponent: PresentationStrings.Component(languageCode: "en", localizedName: "English", pluralizationRulesCode: nil, dict: [:]), secondaryComponent: nil, groupingSeparator: "")

private func makePresentationData() -> ItemListPresentationData {
    return ItemListPresentationData(theme: defaultPresentationTheme, fontSize: .regular, strings: strings, nameDisplayOrder: .firstLast, dateTimeFormat: PresentationDateTimeFormat())
}

private func findSwitch(in view: UIView) -> UISwitch? {
    if let view = view as? UISwitch {
        return view
    }
    for subview in view.subviews {
        if let found = findSwitch(in: subview) {
            return found
        }
    }
    return nil
}

/// The views under `view` that DECLARE themselves accessibility elements (`isAccessibilityElement`), outside
/// subtrees that declare themselves hidden (`isHidden` / `accessibilityElementsHidden`). This applies the
/// project's own exposure flags by a simple rule; it is NOT the system's VoiceOver element tree.
private func collectDeclaredAccessibilityViews(in view: UIView) -> [UIView] {
    if view.isHidden || view.accessibilityElementsHidden {
        return []
    }
    if view.isAccessibilityElement {
        return [view]
    }
    return view.subviews.flatMap { collectDeclaredAccessibilityViews(in: $0) }
}

private struct Fixture {
    let node: ItemListSwitchItemNode
    let switchView: UISwitch
    /// The row's VoiceOver element (`AccessibilityAreaNode`'s view).
    let rowElement: UIView
}

private let layoutParams = ListViewItemLayoutParams(width: 390.0, leftInset: 0.0, rightInset: 0.0, availableHeight: 800.0)

private func makeItem(type: ItemListSwitchItemNodeType, value: Bool, enableInteractiveChanges: Bool, updated: @escaping (Bool) -> Void) -> ItemListSwitchItem {
    return ItemListSwitchItem(presentationData: makePresentationData(), title: title, value: value, type: type, enableInteractiveChanges: enableInteractiveChanges, sectionId: 0, style: .blocks, updated: updated)
}

final class ItemListSwitchItemAccessibilityTests: XCTestCase {
    /// Lays the item out as ListView would and returns the applied node, its UISwitch and its row element.
    private func makeFixture(type: ItemListSwitchItemNodeType, value: Bool, enableInteractiveChanges: Bool, updated: @escaping (Bool) -> Void, file: StaticString = #filePath, line: UInt = #line) throws -> Fixture {
        let item = makeItem(type: type, value: value, enableInteractiveChanges: enableInteractiveChanges, updated: updated)
        let params = layoutParams
        let configured = self.expectation(description: "node configured")
        var result: ItemListSwitchItemNode?
        item.nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: true, previousItem: nil, nextItem: nil, completion: { node, apply in
            let (_, applyLayout) = apply()
            applyLayout(ListViewItemApply(isOnScreen: true))
            result = node as? ItemListSwitchItemNode
            configured.fulfill()
        })
        self.wait(for: [configured], timeout: 5.0)
        let node = try XCTUnwrap(result, file: file, line: line)
        let switchView = try XCTUnwrap(findSwitch(in: node.view), file: file, line: line)
        let rowElement = try XCTUnwrap(collectDeclaredAccessibilityViews(in: node.view).first(where: { $0.accessibilityLabel == title }), "the row must declare an accessibility element labelled with its title", file: file, line: line)
        return Fixture(node: node, switchView: switchView, rowElement: rowElement)
    }

    /// Re-applies `item` to an EXISTING node, the way ListView updates a reused row (`updateNode`).
    private func reapply(_ item: ItemListSwitchItem, to node: ItemListSwitchItemNode) {
        let applied = self.expectation(description: "node updated")
        item.updateNode(async: { $0() }, node: { node }, params: layoutParams, previousItem: nil, nextItem: nil, animation: .None, completion: { _, apply in
            apply(ListViewItemApply(isOnScreen: true))
            applied.fulfill()
        })
        self.wait(for: [applied], timeout: 5.0)
    }

    private func spoken(_ value: Bool) -> String {
        return value ? strings.VoiceOver_Common_On : strings.VoiceOver_Common_Off
    }

    // MARK: Controlled switches (the Secret Vault rows)

    func testControlledRowActivationRequestsTheOppositeAndKeepsTheRealState() throws {
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            for value in [true, false] {
                var requested: [Bool] = []
                let fixture = try self.makeFixture(type: type, value: value, enableInteractiveChanges: false, updated: { requested.append($0) })
                XCTAssertEqual(fixture.switchView.isOn, value, "\(type) \(value)")
                XCTAssertEqual(fixture.rowElement.accessibilityValue, self.spoken(value), "\(type) \(value)")

                // The owner did not change `item.value` (a PIN prompt is open, or was cancelled).
                XCTAssertTrue(fixture.rowElement.accessibilityActivate(), "\(type) \(value)")
                XCTAssertTrue(fixture.rowElement.accessibilityActivate(), "\(type) \(value)")

                // Each activation asks for the opposite of the REAL state (before the fix, a row first shown On
                // asked for On), and the control and the spoken value still show the real state.
                XCTAssertEqual(requested, [!value, !value], "\(type) \(value)")
                XCTAssertEqual(fixture.switchView.isOn, value, "\(type) \(value)")
                XCTAssertEqual(fixture.rowElement.accessibilityValue, self.spoken(value), "\(type) \(value)")
            }
        }
    }

    func testControlledNodeAccessibilityActivationOnlyRequestsTheChange() throws {
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            var requested: [Bool] = []
            let fixture = try self.makeFixture(type: type, value: true, enableInteractiveChanges: false, updated: { requested.append($0) })

            XCTAssertTrue(fixture.node.accessibilityActivate(), "\(type)")

            XCTAssertEqual(requested, [false], "\(type)")
            XCTAssertTrue(fixture.switchView.isOn, "\(type)")
        }
    }

    func testControlledRowDeclaresOnlyTheRowAsAccessibilityElement() throws {
        // Declared project flags, not the system VoiceOver tree (see `collectDeclaredAccessibilityViews`).
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            let fixture = try self.makeFixture(type: type, value: true, enableInteractiveChanges: false, updated: { _ in })
            XCTAssertFalse(fixture.switchView.isAccessibilityElement, "\(type): the native control must not declare itself an element")
            XCTAssertTrue(fixture.switchView.accessibilityElementsHidden, "\(type)")
            XCTAssertEqual(collectDeclaredAccessibilityViews(in: fixture.node.view), [fixture.rowElement], "\(type): only the row declares itself")
        }
    }

    func testControlledNativeValueChangeIsReportedAndPutBack() throws {
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            for value in [true, false] {
                var requested: [Bool] = []
                let fixture = try self.makeFixture(type: type, value: value, enableInteractiveChanges: false, updated: { requested.append($0) })

                // A touch or accessibility action that reaches the native control anyway.
                fixture.switchView.setOn(!value, animated: false)
                fixture.switchView.sendActions(for: .valueChanged)

                XCTAssertEqual(requested, [!value], "\(type) \(value)")
                XCTAssertEqual(fixture.switchView.isOn, value, "\(type) \(value): the control must not stay flipped against the real setting")
                XCTAssertEqual(fixture.rowElement.accessibilityValue, self.spoken(value), "\(type) \(value)")
                // The node's own state agrees: the next row activation still asks for the opposite of the real state.
                XCTAssertTrue(fixture.rowElement.accessibilityActivate(), "\(type) \(value)")
                XCTAssertEqual(requested, [!value, !value], "\(type) \(value)")
                XCTAssertEqual(fixture.switchView.isOn, value, "\(type) \(value)")
            }
        }
    }

    // MARK: Ordinary switches (behaviour preserved)

    func testOrdinaryRowActivationStillFlipsAndReports() throws {
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            for value in [true, false] {
                var requested: [Bool] = []
                let fixture = try self.makeFixture(type: type, value: value, enableInteractiveChanges: true, updated: { requested.append($0) })

                XCTAssertTrue(fixture.rowElement.accessibilityActivate(), "\(type) \(value)")

                XCTAssertEqual(requested, [!value], "\(type) \(value)")
                XCTAssertEqual(fixture.switchView.isOn, !value, "\(type) \(value): an ordinary switch flips immediately")
            }
        }
    }

    func testOrdinaryNodeAccessibilityActivationStillFlipsAndReports() throws {
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            var requested: [Bool] = []
            let fixture = try self.makeFixture(type: type, value: false, enableInteractiveChanges: true, updated: { requested.append($0) })

            XCTAssertTrue(fixture.node.accessibilityActivate(), "\(type)")

            XCTAssertEqual(requested, [true], "\(type)")
            XCTAssertTrue(fixture.switchView.isOn, "\(type)")
        }
    }

    func testOrdinaryNativeValueChangeStaysAndKeepsNodeStateInStep() throws {
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            for value in [true, false] {
                var requested: [Bool] = []
                let fixture = try self.makeFixture(type: type, value: value, enableInteractiveChanges: true, updated: { requested.append($0) })

                fixture.switchView.setOn(!value, animated: false)
                fixture.switchView.sendActions(for: .valueChanged)

                XCTAssertEqual(requested, [!value], "\(type) \(value)")
                XCTAssertEqual(fixture.switchView.isOn, !value, "\(type) \(value)")
                // The next row activation reverses it: the node did not keep its pre-change state. (Starting Off
                // catches an `IconSwitchNode` whose cache never follows a native change.)
                XCTAssertTrue(fixture.rowElement.accessibilityActivate(), "\(type) \(value)")
                XCTAssertEqual(requested, [!value, value], "\(type) \(value)")
                XCTAssertEqual(fixture.switchView.isOn, value, "\(type) \(value)")
            }
        }
    }

    // MARK: Native accessibility flags (declared project flags, not the system VoiceOver tree)

    func testOrdinaryRegularSwitchKeepsItsOwnNonElementFlagThroughControl() throws {
        // `SwitchNode` declares its native control not an element in its own `didLoad`; nothing may change that.
        let fixture = try self.makeFixture(type: .regular, value: true, enableInteractiveChanges: true, updated: { _ in })
        XCTAssertFalse(fixture.switchView.isAccessibilityElement)
        XCTAssertEqual(collectDeclaredAccessibilityViews(in: fixture.node.view), [fixture.rowElement])
        let hiddenBefore = fixture.switchView.accessibilityElementsHidden

        self.reapply(makeItem(type: .regular, value: true, enableInteractiveChanges: false, updated: { _ in }), to: fixture.node)
        XCTAssertFalse(fixture.switchView.isAccessibilityElement)
        XCTAssertTrue(fixture.switchView.accessibilityElementsHidden)

        self.reapply(makeItem(type: .regular, value: true, enableInteractiveChanges: true, updated: { _ in }), to: fixture.node)
        XCTAssertFalse(fixture.switchView.isAccessibilityElement)
        XCTAssertEqual(fixture.switchView.accessibilityElementsHidden, hiddenBefore)
    }

    func testIconSwitchFlagsArePreservedAndRestoredAroundControl() throws {
        // Independent of the SDK default: the test supplies the ordinary flag itself, both ways.
        for suppliedIsElement in [false, true] {
            let label = "supplied \(suppliedIsElement)"
            let fixture = try self.makeFixture(type: .icon, value: true, enableInteractiveChanges: true, updated: { _ in })
            fixture.switchView.isAccessibilityElement = suppliedIsElement
            let hiddenBefore = fixture.switchView.accessibilityElementsHidden

            // An ordinary re-apply leaves the supplied flags alone.
            self.reapply(makeItem(type: .icon, value: true, enableInteractiveChanges: true, updated: { _ in }), to: fixture.node)
            XCTAssertEqual(fixture.switchView.isAccessibilityElement, suppliedIsElement, label)
            XCTAssertEqual(fixture.switchView.accessibilityElementsHidden, hiddenBefore, label)

            for round in 1...2 {
                // Controlled: hidden and not an element; only the row declares itself.
                self.reapply(makeItem(type: .icon, value: true, enableInteractiveChanges: false, updated: { _ in }), to: fixture.node)
                XCTAssertFalse(fixture.switchView.isAccessibilityElement, "\(label) round \(round)")
                XCTAssertTrue(fixture.switchView.accessibilityElementsHidden, "\(label) round \(round)")
                XCTAssertEqual(collectDeclaredAccessibilityViews(in: fixture.node.view), [fixture.rowElement], "\(label) round \(round)")

                // A second controlled apply must not record the hidden state as the "before" flags.
                self.reapply(makeItem(type: .icon, value: true, enableInteractiveChanges: false, updated: { _ in }), to: fixture.node)

                // Ordinary again: exactly the supplied flags come back.
                self.reapply(makeItem(type: .icon, value: true, enableInteractiveChanges: true, updated: { _ in }), to: fixture.node)
                XCTAssertEqual(fixture.switchView.isAccessibilityElement, suppliedIsElement, "\(label) round \(round)")
                XCTAssertEqual(fixture.switchView.accessibilityElementsHidden, hiddenBefore, "\(label) round \(round)")
            }
        }
    }

    // MARK: Node reuse

    func testReusedNodeRestoresFlagsAndStateAcrossControlledOrdinaryControlled() throws {
        for type in [ItemListSwitchItemNodeType.regular, .icon] {
            // What an ordinary row of this type declares when no controlled item ever touched it, read in this
            // runtime rather than assumed.
            let untouched = try self.makeFixture(type: type, value: false, enableInteractiveChanges: true, updated: { _ in })
            let untouchedIsElement = untouched.switchView.isAccessibilityElement
            let untouchedHidden = untouched.switchView.accessibilityElementsHidden

            var requested: [Bool] = []
            let record: (Bool) -> Void = { requested.append($0) }
            let fixture = try self.makeFixture(type: type, value: true, enableInteractiveChanges: false, updated: record)

            // 1. Controlled, On.
            XCTAssertFalse(fixture.switchView.isAccessibilityElement, "\(type) step 1")
            XCTAssertTrue(fixture.switchView.accessibilityElementsHidden, "\(type) step 1")

            // 2. The same node is reused for an ORDINARY row whose value is Off.
            self.reapply(makeItem(type: type, value: false, enableInteractiveChanges: true, updated: record), to: fixture.node)
            XCTAssertFalse(fixture.switchView.isOn, "\(type) step 2")
            XCTAssertEqual(fixture.switchView.isAccessibilityElement, untouchedIsElement, "\(type) step 2")
            XCTAssertEqual(fixture.switchView.accessibilityElementsHidden, untouchedHidden, "\(type) step 2")
            XCTAssertEqual(fixture.rowElement.accessibilityValue, self.spoken(false), "\(type) step 2")
            // The node's cached state followed the update: activation asks for On and flips it.
            XCTAssertTrue(fixture.rowElement.accessibilityActivate(), "\(type) step 2")
            XCTAssertEqual(requested, [true], "\(type) step 2")
            XCTAssertTrue(fixture.switchView.isOn, "\(type) step 2")

            // 3. Reused again for a CONTROLLED row whose value is On.
            self.reapply(makeItem(type: type, value: true, enableInteractiveChanges: false, updated: record), to: fixture.node)
            XCTAssertTrue(fixture.switchView.isOn, "\(type) step 3")
            XCTAssertFalse(fixture.switchView.isAccessibilityElement, "\(type) step 3")
            XCTAssertTrue(fixture.switchView.accessibilityElementsHidden, "\(type) step 3")
            XCTAssertEqual(fixture.rowElement.accessibilityValue, self.spoken(true), "\(type) step 3")
            XCTAssertTrue(fixture.rowElement.accessibilityActivate(), "\(type) step 3")
            XCTAssertEqual(requested, [true, false], "\(type) step 3")
            XCTAssertTrue(fixture.switchView.isOn, "\(type) step 3: a controlled switch does not move by itself")
        }
    }
}
