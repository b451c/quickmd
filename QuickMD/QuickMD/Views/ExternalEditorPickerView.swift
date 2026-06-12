import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings tab for choosing which editor ⌘E ("Open in External Editor")
/// hands the current document to. Auto-detects known editors; any other app
/// can be picked via "Other…". Empty selection = system default handler.
struct ExternalEditorPickerView: View {
    @AppStorage(ExternalEditorManager.defaultsKey) private var selectedBundleID: String = ""
    @State private var installedEditors: [ExternalEditorManager.Editor] = []

    /// True when the stored selection is an app outside the known list.
    private var customSelection: (bundleID: String, name: String)? {
        guard !selectedBundleID.isEmpty,
              !installedEditors.contains(where: { $0.bundleID == selectedBundleID }) else { return nil }
        let name = ExternalEditorManager.displayName(for: selectedBundleID)
            ?? selectedBundleID
        return (selectedBundleID, name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("External editor", selection: $selectedBundleID) {
                        Text("System Default").tag("")
                        ForEach(installedEditors) { editor in
                            Text(editor.name).tag(editor.bundleID)
                        }
                        if let custom = customSelection {
                            Text(custom.name).tag(custom.bundleID)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("Open in External Editor (⌘E)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Tip: enable auto-save in your editor and QuickMD becomes a live preview — it reloads automatically whenever the file changes on disk.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Other…") { chooseCustomEditor() }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360, height: 420)
        .onAppear {
            installedEditors = ExternalEditorManager.installedKnownEditors()
        }
    }

    private func chooseCustomEditor() {
        guard let bundleID = ExternalEditorManager.chooseApplicationBundleID() else { return }
        selectedBundleID = bundleID
    }
}
