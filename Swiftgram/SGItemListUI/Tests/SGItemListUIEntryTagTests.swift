import XCTest
import UIKit
import ItemListUI
import MergeLists
import SGItemListUI

// Zenlygram — the Settings → Zenlygram hub-and-pages IA relies on three small `SGItemListUIEntry`
// facts: a row's tag key is the setting / link case name (the SGSimpleSettings key and the NEW-badge
// key, so a deep link `tg://sg/settings?row=<key>` names the same thing), pages built on their own
// `SGItemListCounter(base:)` concatenate behind the hub without one page's row count shifting
// another's stable ids (the hub's search lays every page's rows after its own), and `isNew` reads the
// badge off the built entries (the page row's roll-up).

private enum TestSection: Int32, SGItemListSection {
    case first
    case second
}

// Mirrors the production enums: `String`-raw-value enums whose `String(describing:)` is the case name,
// exactly what the entry sites hand to `SGNewBadgeTracker`.
private enum TestBool: String {
    case secretVaultEnabled
    case showDeletedMessages
    case nyStyleSnow
    case forceBuiltInMic
}

private enum TestSlider: String {
    case stickerSize
}

private enum TestSelector: String {
    case translationBackend
    case transcriptionBackend
}

private enum TestLink: String {
    case chatLock
    case languageSettings
}

private typealias Entry = SGItemListUIEntry<TestSection, TestBool, TestSlider, TestSelector, TestLink, AnyHashable>

/// Another screen's tag type: never equal to a row tag, whatever its key.
private struct ForeignTag: ItemListItemTag {
    let key: String

    func isEqual(to other: ItemListItemTag) -> Bool {
        return (other as? ForeignTag)?.key == self.key
    }
}

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

/// The exact diff `ItemListControllerNode` runs between two states.
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

private func vaultToggle(id: Int, isNew: Bool = false) -> Entry {
    return .iconToggle(id: id, section: .first, settingName: .secretVaultEnabled, value: true, title: "Secret Vault", description: nil, iconName: "eye.slash.fill", iconColor: .purple, isNew: isNew, enabled: true)
}

private func chatLockRow(id: Int, isNew: Bool = false) -> Entry {
    return .iconDisclosure(id: id, section: .first, link: .chatLock, title: "Chat Lock", value: "Off", iconName: "lock.shield.fill", iconColor: .blue, isNew: isNew)
}

/// A page as the hub's search builds it: its rows on its own id base. The gated block (a toggle and its
/// notice) reserves its two slots while hidden, as the production builder does.
private func firstPage(base: Int, gatedBlockShown: Bool) -> [Entry] {
    let id = SGItemListCounter(base: base)
    var entries: [Entry] = [
        .header(id: id.count, section: .first, text: "HIDDEN CHATS", badge: nil),
        vaultToggle(id: id.count),
    ]
    if gatedBlockShown {
        entries.append(.iconToggle(id: id.count, section: .first, settingName: .showDeletedMessages, value: true, title: "Show Deleted Messages", description: nil, iconName: "trash.slash.fill", iconColor: .orange, isNew: false, enabled: true))
        entries.append(.notice(id: id.count, section: .first, text: "Deleted messages notice"))
    } else {
        id.increment(2)
    }
    entries.append(chatLockRow(id: id.count))
    return entries
}

private func secondPage(base: Int) -> [Entry] {
    let id = SGItemListCounter(base: base)
    return [
        .header(id: id.count, section: .second, text: "TRANSLATION", badge: nil),
        .oneFromManySelector(id: id.count, section: .second, settingName: .translationBackend, text: "Service", value: "Google", enabled: true),
        .disclosure(id: id.count, section: .second, link: .languageSettings, text: "Translate entire chats"),
        .percentageSlider(id: id.count, section: .second, settingName: .stickerSize, value: 100),
        .toggle(id: id.count, section: .second, settingName: .nyStyleSnow, value: false, text: "Snow", enabled: true),
    ]
}

/// One section with three sub-headers, as the Translation & Voice page builds it: the filter keeps all three
/// headers for a match anywhere in the section.
private func translationPage(base: Int) -> [Entry] {
    let id = SGItemListCounter(base: base)
    return [
        .header(id: id.count, section: .second, text: "TRANSLATE MESSAGES", badge: nil),
        .oneFromManySelector(id: id.count, section: .second, settingName: .translationBackend, text: "Service", value: "Telegram", enabled: true),
        .notice(id: id.count, section: .second, text: "Quick, pinned-message and whole-chat translation use Telegram."),
        .header(id: id.count, section: .second, text: "VOICE-TO-TEXT", badge: nil),
        .oneFromManySelector(id: id.count, section: .second, settingName: .transcriptionBackend, text: "Service", value: "Apple", enabled: true),
        .header(id: id.count, section: .second, text: "VOICE MESSAGES", badge: nil),
        .iconToggle(id: id.count, section: .second, settingName: .forceBuiltInMic, value: false, title: "Force Device Microphone", description: "Always record voice messages with the built-in microphone.", iconName: "mic.fill", iconColor: .red, isNew: false, enabled: true),
    ]
}

final class SGItemListUIEntryTagTests: XCTestCase {
    func testTagKeyIsTheCaseNameOfTheSettingOrLink() {
        XCTAssertEqual(vaultToggle(id: 1).tagKey, "secretVaultEnabled")
        XCTAssertEqual(Entry.toggle(id: 2, section: .first, settingName: .nyStyleSnow, value: false, text: "Snow", enabled: true).tagKey, "nyStyleSnow")
        XCTAssertEqual(chatLockRow(id: 3).tagKey, "chatLock")
        XCTAssertEqual(Entry.disclosure(id: 4, section: .first, link: .languageSettings, text: "Translate").tagKey, "languageSettings")
        XCTAssertEqual(Entry.oneFromManySelector(id: 5, section: .first, settingName: .translationBackend, text: "Service", value: "Google", enabled: true).tagKey, "translationBackend")
        XCTAssertEqual(Entry.percentageSlider(id: 6, section: .first, settingName: .stickerSize, value: 100).tagKey, "stickerSize")
    }

    func testRowsThatAreNotSettingsHaveNoTag() {
        let rows: [Entry] = [
            .header(id: 1, section: .first, text: "HEADER", badge: nil),
            .notice(id: 2, section: .first, text: "notice"),
            .searchInput(id: 3, section: .first, title: NSAttributedString(string: "🔍"), text: "", placeholder: "Search"),
            .peerColorDisclosurePreview(id: 4, section: .first, name: "Name", color: .red),
            .action(id: 5, section: .first, actionType: AnyHashable("reset"), text: "Reset", kind: .generic),
        ]
        for row in rows {
            XCTAssertNil(row.tagKey, "\(nodeClass(row)) has no tag key")
            XCTAssertNil(row.tag, "\(nodeClass(row)) has no tag")
        }
    }

    func testTagIsARowTagKeyedByTagKey() {
        let rows: [Entry] = [
            vaultToggle(id: 1),
            chatLockRow(id: 2),
            .toggle(id: 3, section: .first, settingName: .nyStyleSnow, value: false, text: "Snow", enabled: true),
            .disclosure(id: 4, section: .first, link: .languageSettings, text: "Translate"),
            .oneFromManySelector(id: 5, section: .first, settingName: .translationBackend, text: "Service", value: "Google", enabled: true),
            .percentageSlider(id: 6, section: .first, settingName: .stickerSize, value: 100),
        ]
        for row in rows {
            let tag = row.tag as? SGItemListRowTag
            XCTAssertEqual(tag?.key, row.tagKey)
            XCTAssertTrue(tag?.isEqual(to: SGItemListRowTag(key: row.tagKey ?? "")) ?? false, "a deep link finds the row by its key alone")
        }
    }

    func testRowTagEqualityIsByKeyOnly() {
        XCTAssertTrue(SGItemListRowTag(key: "chatLock").isEqual(to: SGItemListRowTag(key: "chatLock")))
        XCTAssertEqual(SGItemListRowTag(key: "chatLock"), SGItemListRowTag(key: "chatLock"))
        XCTAssertFalse(SGItemListRowTag(key: "chatLock").isEqual(to: SGItemListRowTag(key: "tasks")))
        XCTAssertFalse(SGItemListRowTag(key: "chatLock").isEqual(to: ForeignTag(key: "chatLock")), "another screen's tag type never matches, even with the same key")
        // The same row built by two screens (the hub's search and the page) carries equal tags.
        XCTAssertTrue(chatLockRow(id: 7).tag!.isEqual(to: chatLockRow(id: 2007).tag!))
    }

    func testIsNewReadsTheBadgeOfTheRichRowsOnly() {
        XCTAssertTrue(vaultToggle(id: 1, isNew: true).isNew)
        XCTAssertFalse(vaultToggle(id: 1, isNew: false).isNew)
        XCTAssertTrue(chatLockRow(id: 2, isNew: true).isNew)
        XCTAssertFalse(chatLockRow(id: 2, isNew: false).isNew)
        let plainRows: [Entry] = [
            .header(id: 1, section: .first, text: "HEADER", badge: "3"),
            .toggle(id: 2, section: .first, settingName: .nyStyleSnow, value: true, text: "Snow", enabled: true),
            .notice(id: 3, section: .first, text: "notice"),
            .oneFromManySelector(id: 4, section: .first, settingName: .translationBackend, text: "Service", value: "Google", enabled: true),
            .percentageSlider(id: 5, section: .first, settingName: .stickerSize, value: 100),
            .disclosure(id: 6, section: .first, link: .languageSettings, text: "Translate"),
        ]
        for row in plainRows {
            XCTAssertFalse(row.isNew, "\(nodeClass(row)) never carries a NEW badge")
        }
        // The hub's roll-up: a page row is new while any of the page's built rows is.
        XCTAssertFalse(firstPage(base: 1000, gatedBlockShown: true).contains { $0.isNew })
        XCTAssertTrue(([vaultToggle(id: 1, isNew: true)] + secondPage(base: 2000)).contains { $0.isNew })
    }

    func testCounterStartsAtItsBase() {
        let id = SGItemListCounter(base: 1000)
        XCTAssertEqual(id.count, 1001)
        XCTAssertEqual(id.count, 1002)
        id.increment(2)
        XCTAssertEqual(id.count, 1005)
        XCTAssertEqual(id.countWith(10), 1016)
        XCTAssertEqual(SGItemListCounter().count, 1, "the default base keeps today's ids")
    }

    func testPagesOnTheirOwnBasesConcatenateWithStrictlyIncreasingIds() {
        for gatedBlockShown in [false, true] {
            let list = firstPage(base: 1000, gatedBlockShown: gatedBlockShown) + secondPage(base: 2000)
            let ids = list.map { $0.stableId }
            XCTAssertEqual(ids, ids.sorted(), "ItemListControllerNode requires strictly increasing entries")
            XCTAssertEqual(Set(ids).count, ids.count)
            for (previous, next) in zip(ids, ids.dropFirst()) {
                XCTAssertLessThan(previous, next)
            }
            XCTAssertEqual(list.sorted(by: <), list)
        }
    }

    func testAPageGrowingNeverShiftsTheNextPage() {
        let short = firstPage(base: 1000, gatedBlockShown: false) + secondPage(base: 2000)
        let long = firstPage(base: 1000, gatedBlockShown: true) + secondPage(base: 2000)
        let secondPageRows = secondPage(base: 2000)
        XCTAssertEqual(Array(short.suffix(secondPageRows.count)), secondPageRows)
        XCTAssertEqual(Array(long.suffix(secondPageRows.count)), secondPageRows)

        let transition = diff(short, long)
        for (_, newEntry, previousIndex) in transition.updates {
            XCTAssertEqual(nodeClass(short[previousIndex]), nodeClass(newEntry), "an in-place update would hand a \(nodeClass(short[previousIndex])) to an item that builds \(nodeClass(newEntry))")
        }
        XCTAssertTrue(transition.deletes.isEmpty)
        XCTAssertTrue(transition.updates.isEmpty, "the second page's rows are untouched")
        XCTAssertEqual(transition.inserts.map { $0.1.rowId }.sorted(), [1003, 1004], "only the first page's gated rows come in")
        XCTAssertEqual(apply(transition, to: short), long)

        let back = diff(long, short)
        XCTAssertTrue(back.inserts.isEmpty)
        XCTAssertTrue(back.updates.isEmpty)
        XCTAssertEqual(back.deletes.sorted(), [2, 3])
        XCTAssertEqual(apply(back, to: long), short)
    }

    func testSearchDropsTheSubHeadersNoRowFollows() {
        let page = translationPage(base: 6000)
        // "pin" matches only the notice under the first sub-header: the filter keeps the notice, the row
        // before it and — a section with a match — all three sub-headers.
        let filtered = filterSGItemListUIEntrires(entries: page, by: "pin")
        XCTAssertEqual(filtered.map { $0.rowId }, [6001, 6002, 6003, 6004, 6006])
        let shown = removeSGItemListUIHeadersWithoutRows(entries: filtered)
        XCTAssertEqual(shown, Array(page[0..<3]), "the two sub-headers over nothing go; ids and order are untouched")
        XCTAssertEqual(shown.map { $0.stableId }, Array(page[0..<3]).map { $0.stableId })
        // A match under the last sub-header keeps that header alone.
        let mic = removeSGItemListUIHeadersWithoutRows(entries: filterSGItemListUIEntrires(entries: page, by: "microphone"))
        XCTAssertEqual(mic, [page[5], page[6]])
        // A header followed by a notice is kept: an explainer is content.
        let explainer: [Entry] = [
            .header(id: 1, section: .first, text: "CONTEXT MENU", badge: nil),
            .notice(id: 2, section: .first, text: "Disabled entries move to a sub-menu."),
        ]
        XCTAssertEqual(removeSGItemListUIHeadersWithoutRows(entries: explainer), explainer)
        // Where every header has a row the pass is the identity (the hub without a query never runs it anyway).
        XCTAssertEqual(removeSGItemListUIHeadersWithoutRows(entries: page), page)
        XCTAssertEqual(removeSGItemListUIHeadersWithoutRows(entries: firstPage(base: 1000, gatedBlockShown: false) + secondPage(base: 2000)), firstPage(base: 1000, gatedBlockShown: false) + secondPage(base: 2000))
        XCTAssertEqual(removeSGItemListUIHeadersWithoutRows(entries: [Entry]()), [])
        // A lone header at the very end goes too.
        XCTAssertEqual(removeSGItemListUIHeadersWithoutRows(entries: [page[6], page[0]]), [page[6]])
    }

    func testHeaderMultilineDefaultsToFalseAndIsDisplayOnly() {
        let plain = Entry.header(id: 1, section: .first, text: "TABS", badge: nil)
        let prefixed = Entry.header(id: 1, section: .first, text: "TAB BAR — TABS", badge: nil, multiline: true)
        XCTAssertEqual(plain, .header(id: 1, section: .first, text: "TABS", badge: nil, multiline: false))
        XCTAssertNotEqual(plain, .header(id: 1, section: .first, text: "TABS", badge: nil, multiline: true))
        XCTAssertEqual(plain.stableId, prefixed.stableId, "the flag is not part of the list identity")
        let transition = diff([plain], [prefixed])
        XCTAssertTrue(transition.deletes.isEmpty)
        XCTAssertTrue(transition.inserts.isEmpty)
        XCTAssertEqual(transition.updates.count, 1, "the search-mode prefix is an in-place update of the same header node")
        XCTAssertEqual(apply(transition, to: [plain]), [prefixed])
    }
}
