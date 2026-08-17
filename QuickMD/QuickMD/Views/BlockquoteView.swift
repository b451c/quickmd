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
    var fontScale: CGFloat = 1.0
    var contentVersion: Int = 0
    var searchText: String = ""
    var focusedOccurrence: Int? = nil
    let onLink: (URL) -> Void

    /// Cached renderer - created once per view
    private let renderer: MarkdownRenderer

    init(blockId: String, content: String, level: Int, theme: MarkdownTheme,
         fontScale: CGFloat = 1.0, contentVersion: Int = 0,
         searchText: String = "", focusedOccurrence: Int? = nil,
         onLink: @escaping (URL) -> Void) {
        self.blockId = blockId
        self.content = content
        self.level = level
        self.theme = theme
        self.fontScale = fontScale
        self.contentVersion = contentVersion
        self.searchText = searchText
        self.focusedOccurrence = focusedOccurrence
        self.onLink = onLink
        self.renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
    }

    /// Bar width + gap per nesting level, quote indent, vertical padding — see
    /// `BlockLayout.Quote` (shared with `BlockHeightMeasurer`).
    typealias Layout = BlockLayout.Quote

    var body: some View {
        // The quote body is the layout root; the level bars are an overlay,
        // not HStack siblings. An HStack re-negotiates its NSViewRepresentable
        // child's width with ideal/min/max proposals on every pass, which is
        // exactly the kind of width churn the self-sizing text view should not
        // see (during the 1.8.0 scroll-freeze investigation, demo.md never
        // looped once its blockquotes were removed). Text and bars keep the
        // old geometry: 16 pt indent, then (3 pt bar + 8 pt gap) per level.
        TextBlockView(
            blockId: blockId,
            attributed: renderedContent(),
            theme: theme,
            fontScale: fontScale,
            contentVersion: contentVersion,
            searchTerm: searchText,
            focusedOccurrence: focusedOccurrence,
            onLink: onLink
        )
        .padding(.leading, CGFloat(level) * (Layout.barWidth + Layout.barGap))
        .overlay(alignment: .leading) {
            HStack(spacing: Layout.barGap) {
                ForEach(0..<level, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.blockquoteColor.opacity(0.5))
                        .frame(width: Layout.barWidth)
                }
            }
        }
        .padding(.leading, Layout.leadingInset)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One attributed string for the whole quote body — see
    /// `MarkdownRenderer.renderQuotedBody` (shared with the alert view and the
    /// height measurer).
    private func renderedContent() -> AttributedString {
        renderer.renderQuotedBody(content)
    }
}
