import SwiftUI

/// Settings window (⌘,): theme picker + external editor selection.
struct SettingsView: View {
    var body: some View {
        TabView {
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
            ExternalEditorPickerView()
                .tabItem { Label("Editor", systemImage: "pencil") }
        }
    }
}
