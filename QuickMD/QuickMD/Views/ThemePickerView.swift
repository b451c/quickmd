import SwiftUI

// MARK: - Theme Picker View (Settings)

/// Settings view for selecting the color theme
/// Displayed via QuickMD > Settings (Cmd+,)
struct ThemePickerView: View {
    @AppStorage("selectedTheme") private var selectedThemeName: String = "Auto"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Picker("Theme", selection: $selectedThemeName) {
                ForEach(ThemeName.allCases, id: \.rawValue) { themeName in
                    HStack(spacing: 8) {
                        ThemePreviewBar(theme: previewTheme(for: themeName))
                        Text(themeName.rawValue)
                    }
                    .tag(themeName.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .frame(width: 300)
        .padding()
    }

    private func previewTheme(for name: ThemeName) -> MarkdownTheme {
        MarkdownTheme.theme(named: name, colorScheme: colorScheme)
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
