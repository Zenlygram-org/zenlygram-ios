import Foundation

/// Zenlygram — identity of a root tab-bar tab. Chats and Settings are always present;
/// Contacts, Calls and Tasks follow `CallListSettings`.
public enum RootTab: Hashable {
    case contacts
    case calls
    case chats
    #if SG_LENTA
    /// The Lenta feed tab. Never persisted: a build without SG_LENTA has no such case and simply
    /// rebuilds the tab bar from `CallListSettings`, whose unknown `showLentaTab` key it ignores.
    case lenta
    #endif
    case tasks
    case settings
}

/// Visible root tabs in display order (Tasks sits between Chats and Settings).
public func visibleRootTabs(showContactsTab: Bool, showCallsTab: Bool, showTasksTab: Bool) -> [RootTab] {
    var tabs: [RootTab] = []
    if showContactsTab {
        tabs.append(.contacts)
    }
    if showCallsTab {
        tabs.append(.calls)
    }
    tabs.append(.chats)
    if showTasksTab {
        tabs.append(.tasks)
    }
    tabs.append(.settings)
    return tabs
}

#if SG_LENTA
/// The default tab set with Lenta — the owner's open choice (BIR-07, spec «Lenta tabi o'rni»: a sixth tab,
/// or Tasks leaves the standard set). `current` is the ONE place it is decided (docs/lenta.md "Choices
/// waiting for the owner"). In both variants Lenta sits right after Chats; the variants differ only in
/// whether Tasks is part of the default set. Explicit user choices are never altered: the variant only
/// shapes `CallListSettings.defaultSettings`, i.e. a device whose tab settings were never stored; a stored
/// Tasks value (and a Settings ▸ Tabs Lenta choice) is used as it is.
public enum RootTabDefaultSet: CaseIterable {
    /// Lenta is a sixth tab; Tasks stays in the default set.
    case lentaAsSixthTab
    /// Lenta replaces Tasks in the default set: Tasks is off until the user turns it on in Settings ▸ Tabs.
    case lentaReplacesTasks

    public static let current: RootTabDefaultSet = .lentaAsSixthTab

    /// Whether Tasks is visible by default.
    public var includesTasks: Bool {
        switch self {
        case .lentaAsSixthTab:
            return true
        case .lentaReplacesTasks:
            return false
        }
    }
}

/// Visible root tabs with the Lenta tab, which sits right after Chats (before Tasks when Tasks is shown).
public func visibleRootTabs(showContactsTab: Bool, showCallsTab: Bool, showTasksTab: Bool, showLentaTab: Bool) -> [RootTab] {
    var tabs = visibleRootTabs(showContactsTab: showContactsTab, showCallsTab: showCallsTab, showTasksTab: showTasksTab)
    if showLentaTab, let chatsIndex = tabs.firstIndex(of: .chats) {
        tabs.insert(.lenta, at: chatsIndex + 1)
    }
    return tabs
}

/// Whether the Lenta tab is shown: the user's explicit Settings ▸ Tabs / Tools ▸ Lenta choice
/// (`CallListSettings._showLentaTab`) always wins; without one, the automatic availability rule decides
/// (UZ storefront, the cached server answer, bootstrap `default_tabs.exclude_lenta`).
public func isLentaTabVisible(explicitChoice: Bool?, automaticallyAllowed: Bool) -> Bool {
    return explicitChoice ?? automaticallyAllowed
}
#endif

public extension CallListSettings {
    /// The Contacts/Calls/Chats/Tasks/Settings tabs the stored settings ask for. Tabs whose visibility
    /// also depends on runtime availability are added by the root controller.
    var visibleRootTabs: [RootTab] {
        return TelegramUIPreferences.visibleRootTabs(showContactsTab: self.showContactsTab, showCallsTab: self.showTab, showTasksTab: self.showTasksTab)
    }
}

/// Index to select after the visible tabs change: the previously selected tab when it is still
/// visible, otherwise Chats (e.g. when the selected Tasks tab was just hidden).
public func rootTabSelectionIndex(previouslySelected: RootTab?, in tabs: [RootTab]) -> Int {
    if let previouslySelected, let index = tabs.firstIndex(of: previouslySelected) {
        return index
    }
    return tabs.firstIndex(of: .chats) ?? 0
}
