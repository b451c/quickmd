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
    /// The body's converted string, already built off-main by
    /// `BlockHeightMeasurer` — forwarded straight to `TextBlockView` (D12).
    /// `nil` for rows the current measured table does not cover (see
    /// `TextBlockView.preconverted`), which then convert on demand.
    var preconverted: NSAttributedString? = nil
    let onLink: (URL) -> Void

    /// Cached renderer - created once per view (same pattern as BlockquoteView)
    private let renderer: MarkdownRenderer

    init(blockId: String, kind: AlertKind, content: String, theme: MarkdownTheme,
         fontScale: CGFloat = 1.0, contentVersion: Int = 0,
         searchText: String = "", focusedOccurrence: Int? = nil,
         preconverted: NSAttributedString? = nil,
         onLink: @escaping (URL) -> Void) {
        self.blockId = blockId
        self.kind = kind
        self.content = content
        self.theme = theme
        self.fontScale = fontScale
        self.contentVersion = contentVersion
        self.searchText = searchText
        self.focusedOccurrence = focusedOccurrence
        self.preconverted = preconverted
        self.onLink = onLink
        self.renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
    }

    private var accent: Color { kind.accentColor(isDark: theme.isDark) }

    /// Paddings, spacing and label font sizes — see `BlockLayout.Alert`
    /// (shared with `BlockHeightMeasurer`).
    typealias Metrics = BlockLayout.Alert

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
            // Pinned to the height BlockHeightMeasurer predicts for this row, so
            // the alert's height is exact rather than estimated: both children
            // are SwiftUI leaves whose single-line height is not a documented
            // function of NSFont metrics (see BlockLayout.singleLineHeight).
            HStack(spacing: Metrics.titleRowSpacing) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: Metrics.iconFontSize * fontScale, weight: .semibold))
                Text(kind.title)
                    .font(theme.fonts.swiftUI(size: Metrics.titleFontSize * fontScale, weight: .semibold))
            }
            .foregroundColor(accent)
            .frame(height: Metrics.titleRowHeight(theme: theme, fontScale: fontScale))

            if !content.isEmpty {
                TextBlockView(
                    blockId: blockId,
                    attributed: renderedContent(),
                    theme: theme,
                    fontScale: fontScale,
                    contentVersion: contentVersion,
                    searchTerm: searchText,
                    focusedOccurrence: focusedOccurrence,
                    preconverted: preconverted,
                    onLink: onLink
                )
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.06))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: Metrics.accentBarWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
    }

    /// One attributed string for the whole alert body — see
    /// `MarkdownRenderer.renderQuotedBody` (shared with the blockquote view and
    /// the height measurer).
    private func renderedContent() -> AttributedString {
        renderer.renderQuotedBody(content)
    }
}
