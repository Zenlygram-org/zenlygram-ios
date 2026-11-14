// MARK: Swiftgram
import SGLogging
import SGSimpleSettings
import SGStrings
import SGAPIToken

import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import MtProtoKit
import MessageUI
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import OverlayStatusController
import AccountContext
import AppBundle
import WebKit
import PeerNameColorScreen
import ComponentFlow

/// Hands out the row ids an `SGItemListUIEntry` list is built with. `count` pre-increments, so the first
/// row of a counter started at `base` gets `base + 1`; `increment` reserves the slots of rows a state
/// does not render, so the rows below keep their ids in every state.
///
/// `base` is for screens whose entries are concatenated with another screen's (the Zenlygram Settings
/// hub's search lays every page's rows after the hub's): each page's counter starts at its own base,
/// so the ids stay strictly increasing across the whole list (`ItemListControllerNode` asserts that)
/// and a page whose row count varies can never shift another page's stable ids.
public class SGItemListCounter {
    private var _count: Int

    public init(base: Int = 0) {
        self._count = base
    }

    public var count: Int {
        _count += 1
        return _count
    }
    
    public func increment(_ amount: Int) {
        _count += amount
    }
    
    public func countWith(_ amount: Int) -> Int {
        _count += amount
        return count
    }
}


/// The `ListViewItemNode` class an `SGItemListUIEntry` renders into. Entries of the same kind can be
/// updated in place; entries of different kinds must never share a list identity (see `stableId`).
/// Append new kinds at the end — the raw value is part of `stableId`.
public enum SGItemListNodeKind: Int, CaseIterable {
    case sectionHeader       // ItemListSectionHeaderItem
    case switchRow           // ItemListSwitchItem
    case disclosure          // ItemListDisclosureItem
    case text                // ItemListTextItem
    case percentageSlider    // SliderPercentageItem
    case action              // ItemListActionItem
    case singleLineInput     // ItemListSingleLineInputItem

    // Reserve kind slots without constructing allCases during every list comparison.
    fileprivate static let identityStride = 16
}

/// The `ItemListItemTag` of a settings row, keyed by the row's `tagKey` (the setting / link case name,
/// which is also its SGSimpleSettings key and its NEW-badge key). A deep link focuses a row through it:
/// `ItemListNodeState.ensureVisibleItemTag` scrolls the row in, and the node whose `tag` `isEqual(to:)`
/// the focused tag is flashed. Two tags are equal when their keys are, whatever screen built them.
public struct SGItemListRowTag: ItemListItemTag, Equatable {
    public let key: String

    public init(key: String) {
        self.key = key
    }

    public func isEqual(to other: ItemListItemTag) -> Bool {
        return (other as? SGItemListRowTag)?.key == self.key
    }
}

public protocol SGItemListSection: Equatable {
    var rawValue: Int32 { get }
}

public final class SGItemListArguments<BoolSetting: Hashable, SliderSetting: Hashable, OneFromManySetting: Hashable, DisclosureLink: Hashable, ActionType: Hashable> {
    let context: AccountContext
    //
    let setBoolValue: (BoolSetting, Bool) -> Void
    let updateSliderValue: (SliderSetting, Int32) -> Void
    let setOneFromManyValue: (OneFromManySetting) -> Void
    let openDisclosureLink: (DisclosureLink) -> Void
    let action: (ActionType) -> Void
    let searchInput: (String) -> Void

    
    public init(
        context: AccountContext,
        //
        setBoolValue: @escaping (BoolSetting, Bool) -> Void = { _,_ in },
        updateSliderValue: @escaping (SliderSetting, Int32) -> Void = { _,_ in },
        setOneFromManyValue: @escaping (OneFromManySetting) -> Void = { _ in },
        openDisclosureLink: @escaping (DisclosureLink) -> Void = { _ in},
        action: @escaping (ActionType) -> Void = { _ in },
        searchInput: @escaping (String) -> Void = { _ in }
    ) {
        self.context = context
        //
        self.setBoolValue = setBoolValue
        self.updateSliderValue = updateSliderValue
        self.setOneFromManyValue = setOneFromManyValue
        self.openDisclosureLink = openDisclosureLink
        self.action = action
        self.searchInput = searchInput
    }
}

public enum SGItemListUIEntry<Section: SGItemListSection, BoolSetting: Hashable, SliderSetting: Hashable, OneFromManySetting: Hashable, DisclosureLink: Hashable, ActionType: Hashable>: ItemListNodeEntry {
    // `multiline` is display-only (not part of `stableId`): `ItemListSectionHeaderItem` is single-line by
    // default, and the Settings hub's search results prefix a page's headers with the page name
    // ("TAB BAR — TABS"), which no longer fits one line in ru/uz. Defaulted so every existing call site
    // (`header(id:section:text:badge:)`) compiles unchanged.
    case header(id: Int, section: Section, text: String, badge: String?, multiline: Bool = false)
    case toggle(id: Int, section: Section, settingName: BoolSetting, value: Bool, text: String, enabled: Bool)
    // MARK: Swiftgram — Novagram-style rich rows (colored icon + description subtitle + optional NEW badge)
    // `enableInteractiveChanges: false` makes the row a CONTROLLED switch (ItemListSwitchItem's own mode): a
    // tap only reports the requested value, and the switch moves when `value` does. Use it for a switch whose
    // change can be refused or cancelled after the tap (a PIN / device-owner prompt). With the default, the
    // UISwitch flips on touch and re-syncs only when the entry changes — a cancelled prompt leaves the entry
    // unchanged, so the diff applies nothing and the switch stays flipped against the real setting.
    case iconToggle(id: Int, section: Section, settingName: BoolSetting, value: Bool, title: String, description: String?, iconName: String, iconColor: SGSettingsIconColor, isNew: Bool, enabled: Bool, enableInteractiveChanges: Bool = true)
    case iconDisclosure(id: Int, section: Section, link: DisclosureLink, title: String, value: String, iconName: String, iconColor: SGSettingsIconColor, isNew: Bool)
    case notice(id: Int, section: Section, text: String)
    case percentageSlider(id: Int, section: Section, settingName: SliderSetting, value: Int32)
    case oneFromManySelector(id: Int, section: Section, settingName: OneFromManySetting, text: String, value: String, enabled: Bool)
    case disclosure(id: Int, section: Section, link: DisclosureLink, text: String)
    case peerColorDisclosurePreview(id: Int, section: Section, name: String, color: UIColor)
    case action(id: Int, section: Section, actionType: ActionType, text: String, kind: ItemListActionKind)
    case searchInput(id: Int, section: Section, title: NSAttributedString, text: String, placeholder: String)
    
    public var section: ItemListSectionId {
        switch self {
        case let .header(_, sectionId, _, _, _):
            return sectionId.rawValue
        case let .toggle(_, sectionId, _, _, _, _):
            return sectionId.rawValue
        case let .iconToggle(_, sectionId, _, _, _, _, _, _, _, _, _):
            return sectionId.rawValue
        case let .iconDisclosure(_, sectionId, _, _, _, _, _, _):
            return sectionId.rawValue
        case let .notice(_, sectionId, _):
            return sectionId.rawValue
            
        case let .disclosure(_, sectionId, _, _):
            return sectionId.rawValue

        case let .percentageSlider(_, sectionId, _, _):
            return sectionId.rawValue
            
        case let .peerColorDisclosurePreview(_, sectionId, _, _):
            return sectionId.rawValue
        case let .oneFromManySelector(_, sectionId, _, _, _, _):
            return sectionId.rawValue
            
        case let .action(_, sectionId, _, _, _):
            return sectionId.rawValue
            
        case let .searchInput(_, sectionId, _, _, _):
            return sectionId.rawValue
        }
    }
    
    /// The list identity ItemList diffs on. It is the caller's row `id` combined with the row's
    /// `nodeKind`, so one `id` can never be handed from one node class to another.
    ///
    /// `ItemListControllerNode` pairs old and new entries by this value and turns a pair into an
    /// in-place `updateNode` on the EXISTING node. Item `updateNode`s require their own node class
    /// (`ItemListTextItem.updateNode` asserts on `node() as? ItemListTextItemNode`), so a raw `id`
    /// that moved between kinds — a conditional block whose `id`s line up with a different row kind
    /// in another state — trapped in DEBUG and, in release, returned without completing the update,
    /// which left the list stale. With the kind folded in, such a change becomes delete + insert.
    /// Order is unchanged: entries still sort by `id` first.
    public var stableId: Int {
        return self.rowId * SGItemListNodeKind.identityStride + self.nodeKind.rawValue
    }

    /// Which `ListViewItemNode` class `item(presentationData:arguments:)` builds for this entry.
    public var nodeKind: SGItemListNodeKind {
        switch self {
        case .header:
            return .sectionHeader
        case .toggle, .iconToggle:
            return .switchRow
        case .iconDisclosure, .disclosure, .peerColorDisclosurePreview, .oneFromManySelector:
            return .disclosure
        case .notice:
            return .text
        case .percentageSlider:
            return .percentageSlider
        case .action:
            return .action
        case .searchInput:
            return .singleLineInput
        }
    }

    /// The key a deep link or the NEW-badge tracker names this row by: the setting / link case name
    /// (`String(describing:)` of the same value the entry sites hand to `SGNewBadgeTracker`), nil for
    /// rows that are not settings (headers, notices, previews, actions, the search field).
    public var tagKey: String? {
        switch self {
        case let .toggle(_, _, settingName, _, _, _):
            return String(describing: settingName)
        case let .iconToggle(_, _, settingName, _, _, _, _, _, _, _, _):
            return String(describing: settingName)
        case let .oneFromManySelector(_, _, settingName, _, _, _):
            return String(describing: settingName)
        case let .percentageSlider(_, _, settingName, _):
            return String(describing: settingName)
        case let .iconDisclosure(_, _, link, _, _, _, _, _):
            return String(describing: link)
        case let .disclosure(_, _, link, _):
            return String(describing: link)
        case .header, .notice, .peerColorDisclosurePreview, .action, .searchInput:
            return nil
        }
    }

    /// The row's `ItemListItemTag` (overrides the `ItemListNodeEntry` default of nil): an
    /// `SGItemListRowTag` keyed by `tagKey`, handed to the switch and disclosure items so
    /// `ensureVisibleItemTag` / the focus highlight can find the row.
    public var tag: ItemListItemTag? {
        return self.tagKey.map { SGItemListRowTag(key: $0) }
    }

    /// Whether the row shows the NEW badge. Only the rich rows carry one; the Settings hub rolls a page
    /// row's badge up from the page's built entries through this.
    public var isNew: Bool {
        switch self {
        case let .iconToggle(_, _, _, _, _, _, _, _, isNew, _, _):
            return isNew
        case let .iconDisclosure(_, _, _, _, _, _, _, isNew):
            return isNew
        case .header, .toggle, .notice, .percentageSlider, .oneFromManySelector, .disclosure, .peerColorDisclosurePreview, .action, .searchInput:
            return false
        }
    }

    /// The `id` the caller gave this row (see `SGItemListCounter`).
    public var rowId: Int {
        switch self {
        case let .header(stableIdValue, _, _, _, _):
            return stableIdValue
        case let .toggle(stableIdValue, _, _, _, _, _):
            return stableIdValue
        case let .iconToggle(stableIdValue, _, _, _, _, _, _, _, _, _, _):
            return stableIdValue
        case let .iconDisclosure(stableIdValue, _, _, _, _, _, _, _):
            return stableIdValue
        case let .notice(stableIdValue, _, _):
            return stableIdValue
        case let .disclosure(stableIdValue, _, _, _):
            return stableIdValue
        case let .percentageSlider(stableIdValue, _, _, _):
            return stableIdValue
        case let .peerColorDisclosurePreview(stableIdValue, _, _, _):
            return stableIdValue
        case let .oneFromManySelector(stableIdValue, _, _, _, _, _):
            return stableIdValue
        case let .action(stableIdValue, _, _, _, _):
            return stableIdValue
        case let .searchInput(stableIdValue, _, _, _, _):
            return stableIdValue
        }
    }
    
    public static func <(lhs: SGItemListUIEntry, rhs: SGItemListUIEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    public static func ==(lhs: SGItemListUIEntry, rhs: SGItemListUIEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(id1, section1, text1, badge1, multiline1), .header(id2, section2, text2, badge2, multiline2)):
            return id1 == id2 && section1 == section2 && text1 == text2 && badge1 == badge2 && multiline1 == multiline2
        
        case let (.toggle(id1, section1, settingName1, value1, text1, enabled1), .toggle(id2, section2, settingName2, value2, text2, enabled2)):
            return id1 == id2 && section1 == section2 && settingName1 == settingName2 && value1 == value2 && text1 == text2 && enabled1 == enabled2

        case let (.iconToggle(id1, s1, n1, v1, t1, d1, i1, c1, new1, e1, ic1), .iconToggle(id2, s2, n2, v2, t2, d2, i2, c2, new2, e2, ic2)):
            return id1 == id2 && s1 == s2 && n1 == n2 && v1 == v2 && t1 == t2 && d1 == d2 && i1 == i2 && c1 == c2 && new1 == new2 && e1 == e2 && ic1 == ic2

        case let (.iconDisclosure(id1, s1, l1, t1, v1, i1, c1, new1), .iconDisclosure(id2, s2, l2, t2, v2, i2, c2, new2)):
            return id1 == id2 && s1 == s2 && l1 == l2 && t1 == t2 && v1 == v2 && i1 == i2 && c1 == c2 && new1 == new2

        case let (.notice(id1, section1, text1), .notice(id2, section2, text2)):
            return id1 == id2 && section1 == section2 && text1 == text2
        
        case let (.percentageSlider(id1, section1, settingName1, value1), .percentageSlider(id2, section2, settingName2, value2)):
            return id1 == id2 && section1 == section2 && value1 == value2 && settingName1 == settingName2
            
        case let (.disclosure(id1, section1, link1, text1), .disclosure(id2, section2, link2, text2)):
            return id1 == id2 && section1 == section2 && link1 == link2 && text1 == text2

        case let (.peerColorDisclosurePreview(id1, section1, name1, currentColor1), .peerColorDisclosurePreview(id2, section2, name2, currentColor2)):
            return id1 == id2 && section1 == section2 && name1 == name2 && currentColor1 == currentColor2
        
        case let (.oneFromManySelector(id1, section1, settingName1, text1, value1, enabled1), .oneFromManySelector(id2, section2, settingName2, text2, value2, enabled2)):
            return id1 == id2 && section1 == section2 && settingName1 == settingName2 && text1 == text2 && value1 == value2 && enabled1 == enabled2
        case let (.action(id1, section1, actionType1, text1, kind1), .action(id2, section2, actionType2, text2, kind2)):
            return id1 == id2 && section1 == section2 && actionType1 == actionType2 && text1 == text2 && kind1 == kind2
            
        case let (.searchInput(id1, lhsValue1, lhsValue2, lhsValue3, lhsValue4), .searchInput(id2, rhsValue1, rhsValue2, rhsValue3, rhsValue4)):
            return id1 == id2 && lhsValue1 == rhsValue1 && lhsValue2 == rhsValue2 && lhsValue3 == rhsValue3 && lhsValue4 == rhsValue4

        default:
            return false
        }
    }

    
    public func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGItemListArguments<BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>
        switch self {
        case let .header(_, _, string, badge, multiline):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: string, badge: badge, multiline: multiline, sectionId: self.section)

        case let .toggle(_, _, setting, value, text, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, enabled: enabled, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setBoolValue(setting, value)
            }, tag: self.tag)
        case let .iconToggle(_, _, setting, value, title, description, iconName, iconColor, isNew, enabled, enableInteractiveChanges):
            let badge: AnyComponent<Empty>? = isNew ? AnyComponent(SGNewBadgeComponent(langCode: presentationData.strings.baseLanguageCode)) : nil
            let badgeAccessibilityLabel: String? = isNew ? SGNewBadgeComponent.accessibilityLabel(langCode: presentationData.strings.baseLanguageCode) : nil
            return ItemListSwitchItem(presentationData: presentationData, icon: sgSettingsIcon(systemName: iconName, color: iconColor), title: title, text: description, titleBadgeComponent: badge, titleBadgeAccessibilityLabel: badgeAccessibilityLabel, value: value, enableInteractiveChanges: enableInteractiveChanges, enabled: enabled, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setBoolValue(setting, value)
            }, tag: self.tag)
        case let .iconDisclosure(_, _, link, title, value, iconName, iconColor, isNew):
            let badge: AnyComponent<Empty>? = isNew ? AnyComponent(SGNewBadgeComponent(langCode: presentationData.strings.baseLanguageCode)) : nil
            let badgeAccessibilityLabel: String? = isNew ? SGNewBadgeComponent.accessibilityLabel(langCode: presentationData.strings.baseLanguageCode) : nil
            return ItemListDisclosureItem(presentationData: presentationData, icon: sgSettingsIcon(systemName: iconName, color: iconColor), title: title, titleBadgeComponent: badge, titleBadgeAccessibilityLabel: badgeAccessibilityLabel, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openDisclosureLink(link)
            }, tag: self.tag)
        case let .notice(_, _, string):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(string), sectionId: self.section)
        case let .disclosure(_, _, link, text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openDisclosureLink(link)
            }, tag: self.tag)
        case let .percentageSlider(_, _, setting, value):
            return SliderPercentageItem(
                theme: presentationData.theme,
                strings: presentationData.strings,
                value: value,
                sectionId: self.section,
                systemStyle: .glass,
                updated: { value in
                    arguments.updateSliderValue(setting, value)
                }
            )
        
        case let .peerColorDisclosurePreview(_, _, name, color):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: " ", enabled: false, label: name, labelStyle: .semitransparentBadge(color), centerLabelAlignment: true, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
            })
        
        case let .oneFromManySelector(_, _, settingName, text, value, enabled):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, enabled: enabled, label: value, sgLabelMaximumNumberOfLines: 2, sectionId: self.section, style: .blocks, action: {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) // Closing search keyboard if active
                arguments.setOneFromManyValue(settingName)
            }, tag: self.tag)
        case let .action(_, _, actionType, text, kind):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: kind, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) // Closing search keyboard if active
                    arguments.action(actionType)
            })
        case let .searchInput(_, _, title, text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, placeholder: placeholder, returnKeyType: .done, spacing: 3.0, clearType: .always, selectAllOnFocus: true, secondaryStyle: true, sectionId: self.section, textUpdated: { input in arguments.searchInput(input) }, action: {}, dismissKeyboardOnEnter: true)
        }
    }
}


public func filterSGItemListUIEntrires<Section: SGItemListSection & Hashable, BoolSetting: Hashable, SliderSetting: Hashable, OneFromManySetting: Hashable, DisclosureLink: Hashable, ActionType: Hashable>(
    entries: [SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>],
    by searchQuery: String?
) -> [SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>] {
    
    guard let query = searchQuery?.lowercased(), !query.isEmpty else {
        return entries
    }
    
    var sectionIdsForEntireIncludion: Set<ItemListSectionId> = []
    var sectionIdsWithMatches: Set<ItemListSectionId> = []
    var filteredEntries: [SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>] = []
    
    func entryMatches(_ entry: SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>, query: String) -> Bool {
        switch entry {
        case .header(_, _, let text, _, _):
            return text.lowercased().contains(query)
        case .toggle(_, _, _, _, let text, _):
            return text.lowercased().contains(query)
        case .iconToggle(_, _, _, _, let title, let description, _, _, _, _, _):
            return title.lowercased().contains(query) || (description?.lowercased().contains(query) ?? false)
        case .iconDisclosure(_, _, _, let title, let value, _, _, _):
            return title.lowercased().contains(query) || value.lowercased().contains(query)
        case .notice(_, _, let text):
            return text.lowercased().contains(query)
        case .percentageSlider:
            return false // Assuming percentage sliders don't have searchable text
        case .oneFromManySelector(_, _, _, let text, let value, _):
            return text.lowercased().contains(query) || value.lowercased().contains(query)
        case .disclosure(_, _, _, let text):
            return text.lowercased().contains(query)
        case .peerColorDisclosurePreview:
            return false // Never indexed during search
        case .action(_, _, _, let text, _):
            return text.lowercased().contains(query)
        case .searchInput:
            return true // Never hiding search input
        }
    }
    
    // First pass: identify sections with matches
    for entry in entries {
        if entryMatches(entry, query: query) {
            switch entry {
            case .searchInput:
                continue
            default:
                sectionIdsWithMatches.insert(entry.section)
            }
        }
    }
    
    // Second pass: keep matching entries and headers of sections with matches
    for (index, entry) in entries.enumerated() {
        switch entry {
        case .header:
            if entryMatches(entry, query: query) {
                // Will show all entries for the same section
                sectionIdsForEntireIncludion.insert(entry.section)
                if !filteredEntries.contains(entry) {
                    filteredEntries.append(entry)
                }
            }
            // Or show header if something from the section already matched
            if sectionIdsWithMatches.contains(entry.section) {
                if !filteredEntries.contains(entry) {
                    filteredEntries.append(entry)
                }
            }
        default:
            if entryMatches(entry, query: query) {
                if case .notice = entry {
                    // add previous entry to if it's not another notice and if it's not already here
                    // possibly targeting related toggle / setting if we've matched it's description (notice) in search
                    if index > 0 {
                        let previousEntry = entries[index - 1]
                        if case .notice = previousEntry {} else {
                            if !filteredEntries.contains(previousEntry) {
                                filteredEntries.append(previousEntry)
                            }
                        }
                    }
                    if !filteredEntries.contains(entry) {
                        filteredEntries.append(entry)
                    }
                } else {
                    if !filteredEntries.contains(entry) {
                        filteredEntries.append(entry)
                    }
                    // add next entry if it's notice
                    // possibly targeting description (notice) for the currently search-matched toggle/setting
                    if index < entries.count - 1 {
                        let nextEntry = entries[index + 1]
                        if case .notice = nextEntry {
                            if !filteredEntries.contains(nextEntry) {
                                filteredEntries.append(nextEntry)
                            }
                        }
                    }
                }
            } else if sectionIdsForEntireIncludion.contains(entry.section) {
                if !filteredEntries.contains(entry) {
                    filteredEntries.append(entry)
                }
            }
        }
    }
    
    return filteredEntries
}

/// Drops every `.header` that no row follows — the next entry is another header, or the list ends.
///
/// `filterSGItemListUIEntrires` keeps every header of a section that has a match, and a section may carry
/// several sub-headers (the Settings hub's Translation & Voice page has three in one section, Media four):
/// a match under one of them leaves the others standing over nothing, which, prefixed with the page name
/// in the hub's search results, reads as a broken section. Display only: the filter's semantics are
/// untouched, no entry is renumbered or reordered, and on a list where every header has a row the pass is
/// the identity. A notice counts as content (an explainer under its header stays).
public func removeSGItemListUIHeadersWithoutRows<Section: SGItemListSection & Hashable, BoolSetting: Hashable, SliderSetting: Hashable, OneFromManySetting: Hashable, DisclosureLink: Hashable, ActionType: Hashable>(
    entries: [SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>]
) -> [SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>] {
    var result: [SGItemListUIEntry<Section, BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>] = []
    result.reserveCapacity(entries.count)
    for (index, entry) in entries.enumerated() {
        if case .header = entry {
            let nextIndex = index + 1
            guard nextIndex < entries.count else {
                continue
            }
            if case .header = entries[nextIndex] {
                continue
            }
        }
        result.append(entry)
    }
    return result
}
