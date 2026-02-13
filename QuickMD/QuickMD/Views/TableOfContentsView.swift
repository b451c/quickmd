import SwiftUI

// MARK: - Table of Contents Entry

struct ToCEntry: Identifiable {
    let id: String
    let level: Int
    let title: String
}

// MARK: - Table of Contents View

/// Sidebar showing document headings with click-to-navigate
struct TableOfContentsView: View {
    let headings: [ToCEntry]
    let onSelect: (String) -> Void
    var onCopy: ((ToCEntry) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("selectedTheme") private var selectedThemeName: String = "Auto"

    private var theme: MarkdownTheme {
        let name = ThemeName(rawValue: selectedThemeName) ?? .auto
        return MarkdownTheme.theme(named: name, colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Contents")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Headings list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(headings) { entry in
                        ToCEntryRow(entry: entry, theme: theme, onSelect: {
                            onSelect(entry.id)
                        }, onCopy: onCopy != nil ? {
                            onCopy?(entry)
                        } : nil)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(theme.backgroundColor.opacity(0.5))
    }
}

// MARK: - ToC Entry Row

/// Individual ToC row with hover-to-reveal copy button
private struct ToCEntryRow: View {
    let entry: ToCEntry
    let theme: MarkdownTheme
    let onSelect: () -> Void
    let onCopy: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onSelect()
            } label: {
                Text(entry.title)
                    .font(.system(size: fontSize(for: entry.level), weight: fontWeight(for: entry.level)))
                    .foregroundColor(theme.textColor)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, indentation(for: entry.level))
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered, let onCopy = onCopy {
                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy section")
                .transition(.opacity)
            }
        }
        .padding(.trailing, 8)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func fontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 14
        case 2: return 13
        case 3: return 12.5
        default: return 12
        }
    }

    private func fontWeight(for level: Int) -> Font.Weight {
        switch level {
        case 1: return .bold
        case 2: return .semibold
        case 3: return .medium
        default: return .regular
        }
    }

    private func indentation(for level: Int) -> CGFloat {
        CGFloat(12 + (level - 1) * 14)
    }
}
