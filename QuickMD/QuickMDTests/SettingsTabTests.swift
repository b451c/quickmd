import XCTest

/// Settings remembers its tab by identifier (`SettingsTab`), migrating the
/// index SwiftUI used to remember.
final class SettingsTabTests: XCTestCase {

    /// The Settings tab was remembered by INDEX; the update reads that index
    /// once (when the identifier key is absent) and maps it to the same tab.
    func testSettingsTabMigratesTheLegacyIndex() throws {
        XCTAssertEqual(SettingsTab.allCases, [.general, .themes, .fonts, .editor], "legacy index order")
        XCTAssertEqual([0, 1, 2, 3].map(SettingsTab.fromLegacyIndex), [.general, .themes, .fonts, .editor])
        XCTAssertEqual([-1, 4, 99].map(SettingsTab.fromLegacyIndex), [.general, .general, .general])
        XCTAssertEqual(SettingsTab.fromLegacyIndex(nil), .general)

        let suite = try TemporaryDefaults("SettingsTab")
        defer { suite.remove() }
        let defaults = suite.defaults
        XCTAssertEqual(SettingsTab.initial(in: defaults), .general, "fresh install")
        defaults.set(2, forKey: SettingsTab.legacyIndexKey)
        XCTAssertEqual(SettingsTab.initial(in: defaults), .fonts, "the tab SwiftUI remembered")
        defaults.set(SettingsTab.editor.rawValue, forKey: SettingsTab.defaultsKey)
        XCTAssertEqual(SettingsTab.initial(in: defaults), .editor, "the identifier wins once written")
        defaults.set("removed-tab", forKey: SettingsTab.defaultsKey)
        XCTAssertEqual(SettingsTab.initial(in: defaults), .fonts, "an unknown identifier falls back")
        XCTAssertEqual(SettingsTab.legacyIndexKey, "com_apple_SwiftUI_Settings_selectedTabIndex")
    }
}
