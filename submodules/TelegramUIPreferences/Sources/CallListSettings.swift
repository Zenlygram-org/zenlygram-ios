import Foundation
import TelegramCore
import SwiftSignalKit

public struct CallListSettings: Codable, Equatable {
    public var showContactsTab: Bool
    public var _showTab: Bool?
    // Zenlygram — local Tasks tab visibility. Hiding the tab never touches task data;
    // entries written before this field existed decode as visible.
    public var showTasksTab: Bool
    #if SG_LENTA
    // Zenlygram — the user's own Lenta tab choice from Settings ▸ Tabs. nil = never changed on this
    // device: the tab then follows the Lenta availability rule (StoreKit storefront + cached server
    // answer) and a server-side hide_lenta_tab may still be adopted. Entries written before this
    // field existed (or by a build without Lenta) decode as nil.
    public var _showLentaTab: Bool?
    #endif
    
    public static var defaultSettings: CallListSettings {
        #if SG_LENTA
        return CallListSettings.defaultSettings(for: RootTabDefaultSet.current)
        #else
        return CallListSettings(showContactsTab: true, showTab: nil, showTasksTab: true)
        #endif
    }
    
    #if SG_LENTA
    /// The settings of a device that never stored a tab choice, for one variant of the default tab set.
    public static func defaultSettings(for defaultSet: RootTabDefaultSet) -> CallListSettings {
        return CallListSettings(showContactsTab: true, showTab: nil, showTasksTab: defaultSet.includesTasks)
    }
    #endif
    
    public var showTab: Bool {
        get {
            if let value = self._showTab {
                return value
            } else {
                return true
            }
        } set {
            self._showTab = newValue
        }
    }
    
    #if SG_LENTA
    /// The stored Lenta tab choice, `true` when the user never changed it.
    public var showLentaTab: Bool {
        return self._showLentaTab ?? true
    }
    #endif
    
    public init(showContactsTab: Bool, showTab: Bool?, showTasksTab: Bool) {
        self.showContactsTab = showContactsTab
        self._showTab = showTab
        self.showTasksTab = showTasksTab
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.showContactsTab = (try container.decode(Int32.self, forKey: "showContactsTab")) != 0
        if let value = try container.decodeIfPresent(Int32.self, forKey: "showTab") {
            self._showTab = value != 0
        }
        self.showTasksTab = (try container.decodeIfPresent(Int32.self, forKey: "showTasksTab") ?? 1) != 0
        #if SG_LENTA
        if let value = try container.decodeIfPresent(Int32.self, forKey: "showLentaTab") {
            self._showLentaTab = value != 0
        }
        #endif
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode((self.showContactsTab ? 1 : 0) as Int32, forKey: "showContactsTab")
        if let showTab = self._showTab {
            try container.encode((showTab ? 1 : 0) as Int32, forKey: "showTab")
        } else {
            try container.encodeNil(forKey: "showTab")
        }
        try container.encode((self.showTasksTab ? 1 : 0) as Int32, forKey: "showTasksTab")
        #if SG_LENTA
        // Absent (not nil-encoded) while unchanged, so "never changed" survives a round trip.
        if let showLentaTab = self._showLentaTab {
            try container.encode((showLentaTab ? 1 : 0) as Int32, forKey: "showLentaTab")
        }
        #endif
    }
    
    public static func ==(lhs: CallListSettings, rhs: CallListSettings) -> Bool {
        #if SG_LENTA
        if lhs._showLentaTab != rhs._showLentaTab {
            return false
        }
        #endif
        return lhs.showContactsTab == rhs.showContactsTab && lhs._showTab == rhs._showTab && lhs.showTasksTab == rhs.showTasksTab
    }
    
    // The copy helpers start from `self`, so fields they do not name (including build-specific
    // ones) are carried over unchanged.
    public func withUpdatedShowTab(_ showTab: Bool) -> CallListSettings {
        var settings = self
        settings._showTab = showTab
        return settings
    }
    
    public func withUpdatedShowContactsTab(_ showContactsTab: Bool) -> CallListSettings {
        var settings = self
        settings.showContactsTab = showContactsTab
        settings._showTab = self.showTab
        return settings
    }
    
    public func withUpdatedShowTasksTab(_ showTasksTab: Bool) -> CallListSettings {
        var settings = self
        settings.showTasksTab = showTasksTab
        return settings
    }
    
    #if SG_LENTA
    /// Records an explicit user choice (Settings ▸ Tabs); after this the availability rule no longer
    /// adds or removes the tab on its own.
    public func withUpdatedShowLentaTab(_ showLentaTab: Bool) -> CallListSettings {
        var settings = self
        settings._showLentaTab = showLentaTab
        return settings
    }
    #endif
}

public func updateCallListSettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (CallListSettings) -> CallListSettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.callListSettings, { entry in
            let currentSettings: CallListSettings
            if let entry = entry?.get(CallListSettings.self) {
                currentSettings = entry
            } else {
                currentSettings = CallListSettings.defaultSettings
            }
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
}
