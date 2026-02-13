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
    @Environment(\.colorScheme) private var colorScheme

    private var theme: MarkdownTheme {
        MarkdownTheme.cached(for: colorScheme)
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
                        Button {
                            onSelect(entry.id)
                        } label: {
                            Text(entry.title)
                                .font(.system(size: fontSize(for: entry.level), weight: fontWeight(for: entry.level)))
                                .foregroundColor(theme.textColor)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, indentation(for: entry.level))
                                .padding(.trailing, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(theme.backgroundColor.opacity(0.5))
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
