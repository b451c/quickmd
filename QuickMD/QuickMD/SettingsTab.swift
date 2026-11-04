import Foundation

// MARK: - Settings: the remembered tab

/// The Settings window's tabs, remembered by IDENTIFIER.
///
/// Until 1.14.4 the `TabView` had no selection, and SwiftUI remembered the
/// selected tab by INDEX (`legacyIndexKey`): inserting "General" at 0 shifted
/// every user's remembered tab by one. The tags here survive reordering and
/// new tabs.
enum SettingsTab: String, CaseIterable {
    // Declaration order = the order the tabs show = the legacy index.
    case general, themes, fonts, editor

    static let defaultsKey = "settingsSelectedTab"

    /// Where SwiftUI's `Settings` scene kept the selected tab's index, read from
    /// the app's own defaults domain (2026-11-04: present in the App Store
    /// build's container and the E2E build, an Int).
    static let legacyIndexKey = "com_apple_SwiftUI_Settings_selectedTabIndex"

    /// The tab a stored legacy index meant — in the order the tabs had when it
    /// was written, which is this enum's order (the index was last remapped
    /// by the "General" insertion itself). Missing or out of range → General.
    static func fromLegacyIndex(_ index: Int?) -> SettingsTab {
        guard let index, allCases.indices.contains(index) else { return .general }
        return allCases[index]
    }

    /// The tab to open with: the stored identifier, else (first launch after
    /// the update) the tab SwiftUI remembered by index, so nobody's tab moves.
    static func initial(in defaults: UserDefaults) -> SettingsTab {
        if let raw = defaults.string(forKey: defaultsKey), let tab = SettingsTab(rawValue: raw) {
            return tab
        }
        return fromLegacyIndex(defaults.object(forKey: legacyIndexKey) as? Int)
    }
}
