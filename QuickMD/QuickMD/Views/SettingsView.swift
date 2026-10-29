import SwiftUI

/// Settings window (⌘,): general behaviour + theme picker + document fonts +
/// external editor selection.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
            FontPickerView()
                .tabItem { Label("Fonts", systemImage: "textformat") }
            ExternalEditorPickerView()
                .tabItem { Label("Editor", systemImage: "pencil") }
        }
    }
}

// MARK: - General

/// Settings → General: behaviour that is not about how the document looks —
/// the opt-in auto-copy of selections (v1.11 S-D10) and the Contents sidebar's
/// depth (#42, also in the sidebar's context menu); same grouped Form and
/// window size as the other tabs, so switching tabs does not resize the window.
struct GeneralSettingsView: View {
    @AppStorage(SelectionAutoCopy.defaultsKey) private var autoCopySelection: Bool = false
    @AppStorage(ToCDepth.defaultsKey) private var tocMaxLevel: Int = ToCDepth.all

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Copy selected text automatically", isOn: $autoCopySelection)
                } header: {
                    Text("Selection")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Selected text is copied to the clipboard as soon as you finish selecting. Off by default because it replaces whatever you copied in another app.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section {
                    Picker("Show", selection: $tocMaxLevel) {
                        ForEach(ToCDepth.choices, id: \.maxLevel) { choice in
                            Text(choice.title).tag(choice.maxLevel)
                        }
                    }
                } header: {
                    Text("Contents Sidebar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Also in the sidebar's context menu.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 360, height: 420)
    }
}
