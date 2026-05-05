import SwiftUI
import AppKit

// MARK: - Theme Picker View (Settings)

/// Settings view for selecting the color theme.
/// Displayed via QuickMD > Settings (Cmd+,).
/// Lists built-in themes plus any custom JSON themes loaded from
/// ~/Library/Application Support/QuickMD/Themes/.
struct ThemePickerView: View {
    @AppStorage("selectedTheme") private var selectedThemeName: String = ThemeName.auto
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var customStore = CustomThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Theme", selection: $selectedThemeName) {
                        ForEach(MarkdownTheme.allBuiltInThemes) { theme in
                            row(for: theme)
                                .tag(theme.name)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("Built-in").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                }

                if !customStore.themes.isEmpty {
                    Section {
                        Picker("Custom theme", selection: $selectedThemeName) {
                            ForEach(customStore.themes) { theme in
                                row(for: theme)
                                    .tag(theme.name)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    } header: {
                        Text("Custom").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    }
                }

                if let error = customStore.lastError {
                    Section {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(4)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 8) {
                Button("Import Theme…") { importTheme() }
                Button("Open Themes Folder") { openThemesFolder() }
                Spacer()
                Button("Reload") { customStore.reload() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360, height: 420)
    }

    @ViewBuilder
    private func row(for theme: MarkdownTheme) -> some View {
        HStack(spacing: 8) {
            ThemePreviewBar(theme: theme)
            Text(theme.name)
        }
    }

    // MARK: - Actions

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "Choose one or more QuickMD theme JSON files to import."
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            customStore.importTheme(from: url)
        }
    }

    private func openThemesFolder() {
        NSWorkspace.shared.open(customStore.themesFolderURL)
    }
}

// MARK: - Theme Preview Bar

/// Compact color bar showing representative theme colors
struct ThemePreviewBar: View {
    let theme: MarkdownTheme

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.backgroundColor)
            Rectangle().fill(theme.textColor)
            Rectangle().fill(theme.linkColor)
            Rectangle().fill(theme.keywordColor)
            Rectangle().fill(theme.stringColor)
        }
        .frame(width: 50, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
    }
}
