import XCTest
import Postbox
import TelegramCore
@testable import TelegramUIPreferences

/// The exact on-disk shape written by builds before `showTasksTab` existed (keys and
/// Int32 encoding copied from the pre-change `CallListSettings.encode(to:)`).
private struct LegacyCallListSettings: Encodable {
    let showContactsTab: Bool
    let showTab: Bool?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode((self.showContactsTab ? 1 : 0) as Int32, forKey: "showContactsTab")
        if let showTab = self.showTab {
            try container.encode((showTab ? 1 : 0) as Int32, forKey: "showTab")
        } else {
            try container.encodeNil(forKey: "showTab")
        }
    }
}

final class CallListSettingsTests: XCTestCase {
    // CallListSettings is stored as a SharedPreferencesEntry, i.e. through
    // AdaptedPostboxEncoder/Decoder — the same path these tests exercise.
    private func roundTrip(_ settings: CallListSettings) throws -> CallListSettings {
        let data = try AdaptedPostboxEncoder().encode(settings)
        return try AdaptedPostboxDecoder().decode(CallListSettings.self, from: data)
    }

    // MARK: - Legacy data (existing installs keep the Tasks tab)

    func test_legacyEntryWithoutShowTasksTab_decodesTasksTabVisible() throws {
        let data = try AdaptedPostboxEncoder().encode(LegacyCallListSettings(showContactsTab: false, showTab: false))
        let decoded = try AdaptedPostboxDecoder().decode(CallListSettings.self, from: data)

        XCTAssertTrue(decoded.showTasksTab)
        XCTAssertFalse(decoded.showContactsTab)
        XCTAssertEqual(decoded._showTab, false)
    }

    func test_legacyEntryWithNilCallsTab_keepsCallsTabUnset() throws {
        let data = try AdaptedPostboxEncoder().encode(LegacyCallListSettings(showContactsTab: true, showTab: nil))
        let decoded = try AdaptedPostboxDecoder().decode(CallListSettings.self, from: data)

        XCTAssertNil(decoded._showTab)
        XCTAssertTrue(decoded.showTab)
        XCTAssertTrue(decoded.showTasksTab)
    }

    func test_defaultSettings_showTasksTab() {
        #if SG_LENTA
        // The default Tasks visibility follows the owner's default tab set (RootTabLayoutTests covers both).
        XCTAssertEqual(CallListSettings.defaultSettings.showTasksTab, RootTabDefaultSet.current.includesTasks)
        #else
        XCTAssertTrue(CallListSettings.defaultSettings.showTasksTab)
        #endif
        XCTAssertTrue(CallListSettings.defaultSettings.showContactsTab)
        XCTAssertNil(CallListSettings.defaultSettings._showTab)
    }

    // MARK: - Persistence round-trip

    func test_tasksTabOff_roundTripsHidden() throws {
        let hidden = CallListSettings.defaultSettings.withUpdatedShowTasksTab(false)
        let decoded = try self.roundTrip(hidden)

        XCTAssertFalse(decoded.showTasksTab)
        XCTAssertEqual(decoded, hidden)
    }

    func test_tasksTabBackOn_roundTripsVisible() throws {
        let shown = CallListSettings.defaultSettings.withUpdatedShowTasksTab(false).withUpdatedShowTasksTab(true)
        let decoded = try self.roundTrip(shown)

        XCTAssertTrue(decoded.showTasksTab)
        XCTAssertEqual(decoded, shown)
    }

    func test_equality_distinguishesTasksTabVisibility() {
        // Equatable gates distinctUntilChanged-style consumers; a toggle must register as a change.
        XCTAssertNotEqual(CallListSettings.defaultSettings.withUpdatedShowTasksTab(true), CallListSettings.defaultSettings.withUpdatedShowTasksTab(false))
    }

    // MARK: - Copy helpers preserve unrelated fields

    func test_withUpdatedShowTasksTab_preservesContactsAndNilCallsTab() {
        let updated = CallListSettings(showContactsTab: false, showTab: nil, showTasksTab: true).withUpdatedShowTasksTab(false)

        XCTAssertFalse(updated.showTasksTab)
        XCTAssertFalse(updated.showContactsTab)
        XCTAssertNil(updated._showTab)
    }

    func test_withUpdatedShowTab_preservesTasksTab() {
        let updated = CallListSettings.defaultSettings.withUpdatedShowTasksTab(false).withUpdatedShowTab(false)

        XCTAssertFalse(updated.showTasksTab)
        XCTAssertEqual(updated._showTab, false)
    }

    func test_withUpdatedShowContactsTab_preservesTasksTab() {
        let updated = CallListSettings.defaultSettings.withUpdatedShowTasksTab(false).withUpdatedShowContactsTab(false)

        XCTAssertFalse(updated.showTasksTab)
        XCTAssertFalse(updated.showContactsTab)
    }

    #if SG_LENTA
    // MARK: - Lenta tab choice (flag-on builds)

    func test_legacyEntry_lentaTabUnchanged() throws {
        let data = try AdaptedPostboxEncoder().encode(LegacyCallListSettings(showContactsTab: true, showTab: nil))
        let decoded = try AdaptedPostboxDecoder().decode(CallListSettings.self, from: data)

        XCTAssertNil(decoded._showLentaTab)
        XCTAssertTrue(decoded.showLentaTab)
    }

    func test_defaultSettings_lentaTabUnchanged() {
        XCTAssertNil(CallListSettings.defaultSettings._showLentaTab)
        XCTAssertTrue(CallListSettings.defaultSettings.showLentaTab)
    }

    func test_unchangedLentaTab_roundTripsUnchanged() throws {
        let decoded = try self.roundTrip(CallListSettings.defaultSettings)

        XCTAssertNil(decoded._showLentaTab)
        XCTAssertEqual(decoded, CallListSettings.defaultSettings)
    }

    func test_explicitLentaChoice_roundTrips() throws {
        let hidden = CallListSettings.defaultSettings.withUpdatedShowLentaTab(false)
        let decodedHidden = try self.roundTrip(hidden)
        XCTAssertEqual(decodedHidden._showLentaTab, false)
        XCTAssertEqual(decodedHidden, hidden)

        let shown = hidden.withUpdatedShowLentaTab(true)
        let decodedShown = try self.roundTrip(shown)
        XCTAssertEqual(decodedShown._showLentaTab, true)
        XCTAssertEqual(decodedShown, shown)
    }

    func test_equality_distinguishesExplicitLentaChoice() {
        XCTAssertNotEqual(CallListSettings.defaultSettings, CallListSettings.defaultSettings.withUpdatedShowLentaTab(true))
        XCTAssertNotEqual(CallListSettings.defaultSettings.withUpdatedShowLentaTab(true), CallListSettings.defaultSettings.withUpdatedShowLentaTab(false))
    }

    func test_otherCopyHelpers_preserveLentaChoice() {
        let hidden = CallListSettings.defaultSettings.withUpdatedShowLentaTab(false)

        XCTAssertEqual(hidden.withUpdatedShowTasksTab(false)._showLentaTab, false)
        XCTAssertEqual(hidden.withUpdatedShowTab(false)._showLentaTab, false)
        XCTAssertEqual(hidden.withUpdatedShowContactsTab(false)._showLentaTab, false)
    }

    func test_lentaChoice_preservesOtherTabs() {
        let updated = CallListSettings(showContactsTab: false, showTab: nil, showTasksTab: false).withUpdatedShowLentaTab(false)

        XCTAssertFalse(updated.showContactsTab)
        XCTAssertNil(updated._showTab)
        XCTAssertFalse(updated.showTasksTab)
    }
    #endif
}
