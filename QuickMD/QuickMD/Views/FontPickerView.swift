import SwiftUI
import AppKit

// MARK: - Font Picker View (Settings → Fonts)

/// Settings tab for the document font families (issue #18): one picker for
/// body text, one for code. "System" (stored as "") keeps San Francisco /
/// SF Mono — the pre-1.8 look. Applies to every open document, print and PDF
/// export; a custom theme's `bodyFontFamily` / `codeFontFamily` overrides it.
/// Sizes and ⌘+/⌘− zoom are unaffected — only the family changes.
struct FontPickerView: View {
    @AppStorage(DocumentFonts.bodyDefaultsKey) private var bodyFontFamily: String = ""
    @AppStorage(DocumentFonts.codeDefaultsKey) private var codeFontFamily: String = ""
    @State private var families: [String] = []

    private var fonts: DocumentFonts {
        DocumentFonts(body: bodyFontFamily, code: codeFontFamily)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    familyPicker("Body text", selection: $bodyFontFamily, systemLabel: "System (San Francisco)")
                    preview("The quick brown fox jumps over the lazy dog — 0123456789",
                            font: fonts.swiftUI(size: 14))
                } header: {
                    header("Body text")
                }

                Section {
                    familyPicker("Code", selection: $codeFontFamily, systemLabel: "System (SF Mono)")
                    preview("let answer = compute(42) // {} [] <> |",
                            font: fonts.swiftUI(size: 13, monospaced: true))
                } header: {
                    header("Code")
                } footer: {
                    Text("Applies to the document, print and PDF export — the app's own controls keep the system font. Font size and zoom are unaffected. A custom theme can override these with bodyFontFamily / codeFontFamily in its JSON.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 360, height: 420)
        .onAppear {
            families = DocumentFonts.installedFamilies()
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func familyPicker(_ label: String, selection: Binding<String>, systemLabel: String) -> some View {
        Picker(label, selection: selection) {
            Text(systemLabel).tag("")
            Divider()
            ForEach(families, id: \.self) { family in
                Text(family).tag(family)
            }
            // A stored family that is no longer installed (or was typed into
            // defaults) still needs a row, or the picker shows an empty
            // selection. It renders with the system font until changed.
            if !selection.wrappedValue.isEmpty, !families.contains(selection.wrappedValue) {
                Divider()
                Text("\(selection.wrappedValue) (not installed)").tag(selection.wrappedValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func preview(_ sample: String, font: Font) -> some View {
        Text(sample)
            .font(font)
            .lineLimit(2)
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
    }
}
