import SwiftUI

/// Settings window (⌘,): general behaviour + theme picker + document fonts +
/// external editor selection.
struct SettingsView: View {
    /// Remembered by identifier (`SettingsTab`); absent → the index SwiftUI
    /// remembered before, so an update does not move anyone's tab.
    @AppStorage(SettingsTab.defaultsKey) private var selectedTab: SettingsTab = SettingsTab.initial(in: .standard)

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ThemePickerView()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
                .tag(SettingsTab.themes)
            FontPickerView()
                .tabItem { Label("Fonts", systemImage: "textformat") }
                .tag(SettingsTab.fonts)
            ExternalEditorPickerView()
                .tabItem { Label("Editor", systemImage: "pencil") }
                .tag(SettingsTab.editor)
        }
    }
}

// MARK: - General

/// Settings → General: behaviour that is not about how the document looks —
/// the opt-in auto-copy of selections (v1.11 S-D10), the Contents sidebar's
/// depth (#42, also in the sidebar's context menu) and how documents are
/// windowed (tabs in one window, or one window each); same grouped Form and
/// window size as the other tabs, so switching tabs does not resize the window.
struct GeneralSettingsView: View {
    @AppStorage(SelectionAutoCopy.defaultsKey) private var autoCopySelection: Bool = false
    @AppStorage(ToCDepth.defaultsKey) private var tocMaxLevel: Int = ToCDepth.all
    @AppStorage(WindowTabbing.separateWindowsKey) private var separateWindows: Bool = false

    /// Writes the setting and re-applies it right away, so the next document
    /// opens in its own window without restarting the app.
    private var separateWindowsBinding: Binding<Bool> {
        Binding(
            get: { separateWindows },
            set: { newValue in
                separateWindows = newValue
                WindowTabbing.applyWindowPreference()
            }
        )
    }

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
                    Toggle("Open each document in its own window", isOn: separateWindowsBinding)
                } header: {
                    Text("Windows")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Off: every document opens as a tab of the same window. On: each document gets its own window, so you can read several at once side by side.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section {
                    Picker("Show", selection: Binding(get: { ToCDepth.normalized(tocMaxLevel) },
                                                      set: { tocMaxLevel = $0 })) {
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
