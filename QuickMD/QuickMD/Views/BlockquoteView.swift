import SwiftUI

// MARK: - Blockquote View

/// Renders a blockquote block with left border indicator and nested level support.
/// The quote body renders through TextBlockView (NSTextView) — native selection
/// across the whole quote and LazyVStack-safe (no SwiftUI SelectionOverlay).
struct BlockquoteView: View {
    let blockId: String
    let content: String
    let level: Int
    let theme: MarkdownTheme
    var searchText: String = ""
    var focusedOccurrence: Int? = nil
    let heightCache: BlockHeightCache
    let onLink: (URL) -> Void

    /// Cached renderer - created once per view
    private let renderer: MarkdownRenderer

    init(blockId: String, content: String, level: Int, theme: MarkdownTheme,
         searchText: String = "", focusedOccurrence: Int? = nil,
         heightCache: BlockHeightCache, onLink: @escaping (URL) -> Void) {
        self.blockId = blockId
        self.content = content
        self.level = level
        self.theme = theme
        self.searchText = searchText
        self.focusedOccurrence = focusedOccurrence
        self.heightCache = heightCache
        self.onLink = onLink
        self.renderer = MarkdownRenderer(theme: theme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left border bars - one per nesting level
            ForEach(0..<level, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.blockquoteColor.opacity(0.5))
                    .frame(width: 3)
                    .padding(.trailing, 8)
            }

            TextBlockView(
                blockId: blockId,
                attributed: renderedContent(),
                theme: theme,
                searchTerm: searchText,
                focusedOccurrence: focusedOccurrence,
                heightCache: heightCache,
                onLink: onLink
            )
        }
        .padding(.leading, 16)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline-render each quote line and join with newlines — one attributed
    /// string for the whole quote body.
    private func renderedContent() -> AttributedString {
        var result = AttributedString()
        let lines = content.components(separatedBy: "\n")
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
