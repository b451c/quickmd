import SwiftUI

// MARK: - GFM Alert View

/// Renders a GitHub-flavored alert (`> [!NOTE]` etc.): icon + title in the
/// kind's accent color, accent left border, subtly tinted background.
/// The body renders through TextBlockView (NSTextView) — native selection and
/// LazyVStack-safe, mirroring BlockquoteView (constraint: no SwiftUI
/// `.textSelection` inside the lazy container).
struct AlertBlockView: View {
    let blockId: String
    let kind: AlertKind
    let content: String
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0
    var contentVersion: Int = 0
    var searchText: String = ""
    var focusedOccurrence: Int? = nil
    let heightCache: BlockHeightCache
    let onLink: (URL) -> Void

    /// Cached renderer - created once per view (same pattern as BlockquoteView)
    private let renderer: MarkdownRenderer

    init(blockId: String, kind: AlertKind, content: String, theme: MarkdownTheme,
         fontScale: CGFloat = 1.0, contentVersion: Int = 0,
         searchText: String = "", focusedOccurrence: Int? = nil,
         heightCache: BlockHeightCache, onLink: @escaping (URL) -> Void) {
        self.blockId = blockId
        self.kind = kind
        self.content = content
        self.theme = theme
        self.fontScale = fontScale
        self.contentVersion = contentVersion
        self.searchText = searchText
        self.focusedOccurrence = focusedOccurrence
        self.heightCache = heightCache
        self.onLink = onLink
        self.renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
    }

    private var accent: Color { kind.accentColor(isDark: theme.isDark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 13 * fontScale, weight: .semibold))
                Text(kind.title)
                    .font(.system(size: 14 * fontScale, weight: .semibold))
            }
            .foregroundColor(accent)

            if !content.isEmpty {
                TextBlockView(
                    blockId: blockId,
                    attributed: renderedContent(),
                    theme: theme,
                    fontScale: fontScale,
                    contentVersion: contentVersion,
                    searchTerm: searchText,
                    focusedOccurrence: focusedOccurrence,
                    heightCache: heightCache,
                    onLink: onLink
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.06))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Inline-render each body line and join with newlines — one attributed
    /// string for the whole alert body (same approach as BlockquoteView).
    /// Soft breaks are joined first so a single newline inside a paragraph
    /// reads as a space (CommonMark).
    private func renderedContent() -> AttributedString {
        var result = AttributedString()
        let lines = MarkdownRenderer.joinSoftBreaks(content.components(separatedBy: "\n"))
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(AttributedString(" "))
            } else {
                result.append(renderer.renderInline(line))
            }
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }
}
