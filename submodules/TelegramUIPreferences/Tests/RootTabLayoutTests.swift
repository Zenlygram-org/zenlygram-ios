import XCTest
@testable import TelegramUIPreferences

final class RootTabLayoutTests: XCTestCase {
    /// Contacts, Calls and Tasks visible: the default without Lenta.
    private let tasksVisible = CallListSettings(showContactsTab: true, showTab: nil, showTasksTab: true)

    // MARK: - Visible tabs

    func test_defaultSettings_includeTasksBetweenChatsAndSettings() {
        #if SG_LENTA
        XCTAssertEqual(CallListSettings.defaultSettings(for: .lentaAsSixthTab).visibleRootTabs, [.contacts, .calls, .chats, .tasks, .settings])
        #else
        XCTAssertEqual(CallListSettings.defaultSettings.visibleRootTabs, [.contacts, .calls, .chats, .tasks, .settings])
        #endif
    }

    func test_tasksHidden_omitsOnlyTasks() {
        let settings = self.tasksVisible.withUpdatedShowTasksTab(false)
        XCTAssertEqual(settings.visibleRootTabs, [.contacts, .calls, .chats, .settings])
    }

    func test_allOptionalTabsHidden_keepsChatsAndSettings() {
        let settings = CallListSettings(showContactsTab: false, showTab: false, showTasksTab: false)
        XCTAssertEqual(settings.visibleRootTabs, [.chats, .settings])
    }

    func test_visibleTabs_neverDuplicateTasks() {
        for contacts in [false, true] {
            for calls in [false, true] {
                for tasks in [false, true] {
                    let tabs = CallListSettings(showContactsTab: contacts, showTab: calls, showTasksTab: tasks).visibleRootTabs
                    XCTAssertEqual(tabs.filter { $0 == .tasks }.count, tasks ? 1 : 0)
                    XCTAssertEqual(Set(tabs).count, tabs.count)
                }
            }
        }
    }

    // MARK: - Selection after a visibility change

    func test_hidingSelectedTasks_selectsChats() {
        let tabs: [RootTab] = [.contacts, .calls, .chats, .settings]
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: .tasks, in: tabs), 2)
    }

    func test_survivingSelection_followsItsNewIndex() {
        // Settings was index 4 with Tasks visible; it stays selected at its new index.
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: .settings, in: [.contacts, .calls, .chats, .settings]), 3)
        // Re-showing Tasks keeps the Settings selection.
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: .settings, in: [.chats, .tasks, .settings]), 2)
    }

    func test_contactsOrCallsToggle_keepsSelectedTabByIdentity() {
        // Chats sits at index 2 with Contacts and Calls visible; hiding Contacts moves it to 1.
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: .chats, in: self.tasksVisible.withUpdatedShowContactsTab(false).visibleRootTabs), 1)
        // Tasks stays selected (not index-matched to Chats) when Calls is hidden.
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: .tasks, in: self.tasksVisible.withUpdatedShowTab(false).visibleRootTabs), 2)
    }

    func test_unknownSelection_selectsChats() {
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: nil, in: [.chats, .tasks, .settings]), 0)
    }

    #if SG_LENTA
    // MARK: - Lenta tab (flag-on builds)

    /// The tab bar for stored settings and the Lenta inputs, as TelegramRootController builds it.
    private func tabs(_ settings: CallListSettings, explicitLenta: Bool?, automaticallyAllowed: Bool) -> [RootTab] {
        return visibleRootTabs(
            showContactsTab: settings.showContactsTab,
            showCallsTab: settings.showTab,
            showTasksTab: settings.showTasksTab,
            showLentaTab: isLentaTabVisible(explicitChoice: explicitLenta, automaticallyAllowed: automaticallyAllowed)
        )
    }

    func test_lentaVisible_sitsRightAfterChats() {
        XCTAssertEqual(visibleRootTabs(showContactsTab: true, showCallsTab: true, showTasksTab: true, showLentaTab: true), [.contacts, .calls, .chats, .lenta, .tasks, .settings])
        XCTAssertEqual(visibleRootTabs(showContactsTab: false, showCallsTab: false, showTasksTab: false, showLentaTab: true), [.chats, .lenta, .settings])
    }

    func test_lentaHidden_matchesTabsWithoutLenta() {
        for contacts in [false, true] {
            for calls in [false, true] {
                for tasks in [false, true] {
                    XCTAssertEqual(
                        visibleRootTabs(showContactsTab: contacts, showCallsTab: calls, showTasksTab: tasks, showLentaTab: false),
                        visibleRootTabs(showContactsTab: contacts, showCallsTab: calls, showTasksTab: tasks)
                    )
                }
            }
        }
    }

    func test_hidingSelectedLenta_selectsChats() {
        let tabs = visibleRootTabs(showContactsTab: true, showCallsTab: true, showTasksTab: true, showLentaTab: false)
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: .lenta, in: tabs), 2)
    }

    func test_showingLenta_keepsTasksSelectedByIdentity() {
        let tabs = visibleRootTabs(showContactsTab: true, showCallsTab: true, showTasksTab: true, showLentaTab: true)
        XCTAssertEqual(rootTabSelectionIndex(previouslySelected: .tasks, in: tabs), 4)
    }

    // MARK: - Default tab set variants (SGF-07, owner choice BIR-07)

    func test_defaultSettings_followCurrentDefaultSet() {
        XCTAssertEqual(CallListSettings.defaultSettings, CallListSettings.defaultSettings(for: RootTabDefaultSet.current))
    }

    func test_sixthTabVariant_defaultSetHasLentaAndTasks() {
        let defaults = CallListSettings.defaultSettings(for: .lentaAsSixthTab)
        XCTAssertEqual(self.tabs(defaults, explicitLenta: nil, automaticallyAllowed: true), [.contacts, .calls, .chats, .lenta, .tasks, .settings])
    }

    func test_replacesTasksVariant_defaultSetHasLentaWithoutTasks() {
        let defaults = CallListSettings.defaultSettings(for: .lentaReplacesTasks)
        XCTAssertEqual(self.tabs(defaults, explicitLenta: nil, automaticallyAllowed: true), [.contacts, .calls, .chats, .lenta, .settings])
        // Turning Tasks on in Settings ▸ Tabs brings it back after Lenta.
        XCTAssertEqual(self.tabs(defaults.withUpdatedShowTasksTab(true), explicitLenta: nil, automaticallyAllowed: true), [.contacts, .calls, .chats, .lenta, .tasks, .settings])
    }

    func test_bothVariants_differOnlyInTasks() {
        for defaultSet in RootTabDefaultSet.allCases {
            let defaults = CallListSettings.defaultSettings(for: defaultSet)
            XCTAssertEqual(defaults.showTasksTab, defaultSet.includesTasks)
            XCTAssertTrue(defaults.showContactsTab)
            XCTAssertNil(defaults._showTab)
            XCTAssertNil(defaults._showLentaTab, "the default set never records a Lenta choice")
        }
    }

    func test_bothVariants_neverAlterExplicitChoices() {
        // Stored settings (any explicit tab choice) are used as they are, whatever the default set.
        let storedTasksOn = CallListSettings(showContactsTab: false, showTab: true, showTasksTab: true)
        let storedTasksOff = CallListSettings(showContactsTab: true, showTab: false, showTasksTab: false)
        for _ in RootTabDefaultSet.allCases {
            XCTAssertEqual(self.tabs(storedTasksOn, explicitLenta: nil, automaticallyAllowed: true), [.calls, .chats, .lenta, .tasks, .settings])
            XCTAssertEqual(self.tabs(storedTasksOff, explicitLenta: nil, automaticallyAllowed: true), [.contacts, .chats, .lenta, .settings])
            // An explicit Lenta choice wins over the automatic rule both ways.
            XCTAssertEqual(self.tabs(storedTasksOn, explicitLenta: false, automaticallyAllowed: true), [.calls, .chats, .tasks, .settings])
            XCTAssertEqual(self.tabs(storedTasksOn, explicitLenta: true, automaticallyAllowed: false), [.calls, .chats, .lenta, .tasks, .settings])
        }
    }

    // MARK: - Server default_tabs.exclude_lenta (KIR-15)

    func test_excludeLenta_dropsAutomaticTabInBothVariants() {
        // exclude_lenta makes the automatic rule false (SGFeedStorefront.allowsAutomaticTab).
        XCTAssertEqual(self.tabs(CallListSettings.defaultSettings(for: .lentaAsSixthTab), explicitLenta: nil, automaticallyAllowed: false), [.contacts, .calls, .chats, .tasks, .settings])
        XCTAssertEqual(self.tabs(CallListSettings.defaultSettings(for: .lentaReplacesTasks), explicitLenta: nil, automaticallyAllowed: false), [.contacts, .calls, .chats, .settings])
    }

    func test_excludeLenta_keepsExplicitChoice() {
        for defaultSet in RootTabDefaultSet.allCases {
            let defaults = CallListSettings.defaultSettings(for: defaultSet)
            let shown = self.tabs(defaults, explicitLenta: true, automaticallyAllowed: false)
            XCTAssertTrue(shown.contains(.lenta), "a Settings ▸ Tabs choice stays when the server excludes Lenta")
            XCTAssertEqual(shown.firstIndex(of: .lenta), shown.firstIndex(of: .chats).map { $0 + 1 })
            XCTAssertFalse(self.tabs(defaults, explicitLenta: false, automaticallyAllowed: true).contains(.lenta))
        }
    }

    func test_lentaVisibility_explicitChoiceWins() {
        XCTAssertTrue(isLentaTabVisible(explicitChoice: nil, automaticallyAllowed: true))
        XCTAssertFalse(isLentaTabVisible(explicitChoice: nil, automaticallyAllowed: false))
        XCTAssertTrue(isLentaTabVisible(explicitChoice: true, automaticallyAllowed: false))
        XCTAssertFalse(isLentaTabVisible(explicitChoice: false, automaticallyAllowed: true))
    }
    #endif
}
