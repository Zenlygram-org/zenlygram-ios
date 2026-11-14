import XCTest
import MergeLists
import SGItemListUI

// Zenlygram — QA 2026-10-12: turning the Secret Vault off after the correct PIN crashed (SIGTRAP in
// `ItemListTextItem.updateNode`) and turning it on left the Zenlygram settings list stale. The rows of
// the vault block reuse the same counter ids across states for DIFFERENT row kinds, and the list paired
// them as in-place updates of a node of the wrong class.
//
// These tests drive the exact diff `ItemListControllerNode` runs (`mergeListsStableWithUpdates` with the
// entry's `<`, `==` and `stableId`) over the real `SGItemListUIEntry`, mirroring the vault rows'
// before/after states. They classify kinds with a local switch, not the production `nodeKind`, so they
// compile against the original implementation too and fail there.

private enum TestSection: Int32, SGItemListSection {
    case privacy
    case other
}

private typealias Entry = SGItemListUIEntry<TestSection, String, String, String, String, AnyHashable>

/// The `ListViewItemNode` class each case renders into (see `SGItemListUIEntry.item`).
private func nodeClass(_ entry: Entry) -> String {
    switch entry {
    case .header:
        return "ItemListSectionHeaderItemNode"
    case .toggle, .iconToggle:
        return "ItemListSwitchItemNode"
    case .iconDisclosure, .disclosure, .peerColorDisclosurePreview, .oneFromManySelector:
        return "ItemListDisclosureItemNode"
    case .notice:
        return "ItemListTextItemNode"
    case .percentageSlider:
        return "SliderPercentageItemNode"
    case .action:
        return "ItemListActionItemNode"
    case .searchInput:
        return "ItemListSingleLineInputItemNode"
    }
}

private struct Transition {
    let deletes: [Int]
    let inserts: [(Int, Entry, Int?)]
    let updates: [(Int, Entry, Int)]
}

private func diff(_ from: [Entry], _ to: [Entry]) -> Transition {
    let (deletes, inserts, updates) = mergeListsStableWithUpdates(leftList: from, rightList: to, isLess: { $0 < $1 }, isEqual: { $0 == $1 }, getId: { AnyHashable($0.stableId) })
    return Transition(deletes: deletes, inserts: inserts, updates: updates)
}

/// Applies a transition the way ListView does: deletes (descending), then inserts (ascending), then updates.
private func apply(_ transition: Transition, to from: [Entry]) -> [Entry] {
    var result = from
    for index in transition.deletes.sorted(by: >) {
        result.remove(at: index)
    }
    for (index, entry, _) in transition.inserts.sorted(by: { $0.0 < $1.0 }) {
        result.insert(entry, at: index)
    }
    for (index, entry, _) in transition.updates {
        result[index] = entry
    }
    return result
}

// The vault block as `SGControllerEntries` lays it out: the master toggle at 2, then either the usable
// branch (toggle 3, disclosure 4, notice 5), the recovery branch (disclosure 3, notice 4) or the plain
// notice at 3. The Chat Lock row follows at 6.
private func vaultBlock(usable: Bool, needsRecovery: Bool) -> [Entry] {
    var entries: [Entry] = [
        .header(id: 1, section: .privacy, text: "HIDDEN CHATS", badge: nil),
        .iconToggle(id: 2, section: .privacy, settingName: "secretVaultEnabled", value: usable, title: "Secret Vault", description: nil, iconName: "eye.slash.fill", iconColor: .purple, isNew: false, enabled: true),
    ]
    if usable {
        entries.append(.iconToggle(id: 3, section: .privacy, settingName: "secretVaultUseSecretCode", value: false, title: "Use secret code", description: nil, iconName: "character.cursor.ibeam", iconColor: .teal, isNew: false, enabled: true))
        entries.append(.iconDisclosure(id: 4, section: .privacy, link: "secretVaultChangePin", title: "Change PIN", value: "", iconName: "key.fill", iconColor: .gray, isNew: false))
        entries.append(.notice(id: 5, section: .privacy, text: "Secret code notice"))
    } else if needsRecovery {
        entries.append(.iconDisclosure(id: 3, section: .privacy, link: "protectionRecovery", title: "Use secret code", value: "Paused", iconName: "character.cursor.ibeam", iconColor: .gray, isNew: false))
        entries.append(.notice(id: 4, section: .privacy, text: "Paused notice"))
    } else {
        entries.append(.notice(id: 3, section: .privacy, text: "Vault notice"))
    }
    entries.append(.iconDisclosure(id: 6, section: .privacy, link: "chatLock", title: "Chat Lock", value: "Off", iconName: "lock.shield.fill", iconColor: .blue, isNew: false))
    return entries
}

final class SGItemListUIEntryIdentityTests: XCTestCase {
    private func assertNoCrossKindUpdates(from: [Entry], to: [Entry], file: StaticString = #filePath, line: UInt = #line) {
        let transition = diff(from, to)
        for (_, newEntry, previousIndex) in transition.updates {
            XCTAssertEqual(nodeClass(from[previousIndex]), nodeClass(newEntry), "an in-place update would hand a \(nodeClass(from[previousIndex])) to an item that builds \(nodeClass(newEntry)) (the updateNode type assertion)", file: file, line: line)
        }
        XCTAssertEqual(apply(transition, to: from), to, "the transition must produce exactly the new list", file: file, line: line)
    }

    func testDisablingVaultNeverUpdatesASwitchNodeAsText() {
        assertNoCrossKindUpdates(from: vaultBlock(usable: true, needsRecovery: false), to: vaultBlock(usable: false, needsRecovery: false))
    }

    func testEnablingVaultNeverUpdatesATextNodeAsSwitch() {
        assertNoCrossKindUpdates(from: vaultBlock(usable: false, needsRecovery: false), to: vaultBlock(usable: true, needsRecovery: false))
    }

    func testEnteringAndLeavingVaultRecoveryNeverCrossesKinds() {
        let usable = vaultBlock(usable: true, needsRecovery: false)
        let recovery = vaultBlock(usable: false, needsRecovery: true)
        let off = vaultBlock(usable: false, needsRecovery: false)
        assertNoCrossKindUpdates(from: usable, to: recovery)
        assertNoCrossKindUpdates(from: recovery, to: usable)
        assertNoCrossKindUpdates(from: recovery, to: off)
        assertNoCrossKindUpdates(from: off, to: recovery)
    }

    func testDisablingVaultReplacesTheSecretCodeRowInsteadOfReusingIt() {
        let from = vaultBlock(usable: true, needsRecovery: false)
        let to = vaultBlock(usable: false, needsRecovery: false)
        let transition = diff(from, to)
        // The secret-code switch (old index 2) goes away and the vault notice comes in as a new row.
        XCTAssertTrue(transition.deletes.contains(2))
        XCTAssertTrue(transition.inserts.contains(where: { nodeClass($0.1) == "ItemListTextItemNode" && $0.0 == 2 }))
    }

    func testSameKindChangeStillUpdatesInPlace() {
        // The fix must not turn every change into delete + insert: the vault switch flipping and the
        // Chat Lock value changing ("Off" -> "On", the stale-label report) are ordinary updates.
        var from = vaultBlock(usable: false, needsRecovery: false)
        var to = from
        to[1] = .iconToggle(id: 2, section: .privacy, settingName: "secretVaultEnabled", value: true, title: "Secret Vault", description: nil, iconName: "eye.slash.fill", iconColor: .purple, isNew: false, enabled: true)
        to[3] = .iconDisclosure(id: 6, section: .privacy, link: "chatLock", title: "Chat Lock", value: "On", iconName: "lock.shield.fill", iconColor: .blue, isNew: false)
        let transition = diff(from, to)
        XCTAssertTrue(transition.deletes.isEmpty)
        XCTAssertTrue(transition.inserts.isEmpty)
        XCTAssertEqual(transition.updates.map { $0.2 }.sorted(), [1, 3])
        XCTAssertEqual(apply(transition, to: from), to)
        from = to
        XCTAssertTrue(diff(from, to).updates.isEmpty, "an unchanged list produces no work")
    }

    func testOrderFollowsRowIdAcrossKinds() {
        let entries = vaultBlock(usable: true, needsRecovery: false)
        XCTAssertEqual(entries.sorted(by: <), entries, "rows still sort by the caller's id whatever their kind")
        XCTAssertEqual(Set(entries.map { $0.stableId }).count, entries.count)
    }
}
