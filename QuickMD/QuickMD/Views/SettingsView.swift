import SwiftUI

/// Settings window (⌘,): theme picker + document fonts + external editor selection.
struct SettingsView: View {
    var body: some View {
        TabView {
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
            FontPickerView()
                .tabItem { Label("Fonts", systemImage: "textformat") }
            ExternalEditorPickerView()
                .tabItem { Label("Editor", systemImage: "pencil") }
        }
    }
}
