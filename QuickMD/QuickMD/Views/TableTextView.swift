import SwiftUI
import AppKit

// MARK: - Table Block View (v1.13)

/// A markdown table as ONE read-only NSTextView over an `NSTextTable` (TS-D1),
/// replacing 1.12's SwiftUI grid of `Text` cells, so a table's text joins the
/// document selection like any other text row.
///
/// The string and its cell layout come from `TableTextBuilder` — normally the
/// very instance `BlockHeightMeasurer` laid out to size the row (`preconverted`,
/// v1.9 D12), which is why the row is `.exact`. The view adds only what a text
/// table cannot draw itself, all from `BlockLayout.Table`: the table background
/// and the rounded clip (`TableTextView.draw`), and the 1 pt outline — a SwiftUI
/// stroke overlay as in 1.12, centred on the edge so half of it lies outside the
/// view's frame, where an AppKit subview would be clipped.
struct TableTextBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0
    var searchText: String = ""
    var focusedOccurrence: Int? = nil
    /// The measurer's `TableText` for this block id. Used only when it was
    /// built from this block (ids are positional — see `TableText`); otherwise,
    /// or before the document was measured, the view builds its own.
    var preconverted: TableText? = nil
    let onLink: (URL) -> Void

    typealias Metrics = BlockLayout.Table

    var body: some View {
        // Nothing is built here: `body` runs on every search keystroke, focus
        // move and cell reuse. The representable builds (or adopts
        // `preconverted`) only when the text view's installed source differs.
        TableTextRepresentable(
            headers: headers,
            rows: rows,
            alignments: alignments,
            theme: theme,
            fontScale: fontScale,
            preconverted: preconverted,
            background: theme.backgroundColor,
            searchTerm: searchText,
            focusedOccurrence: focusedOccurrence,
            onLink: onLink
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius)
            .stroke(theme.borderColor, lineWidth: Metrics.borderWidth))
    }
}

// MARK: - NSTextView Wrapper

private struct TableTextRepresentable: NSViewRepresentable {
    /// The cells' markdown — what the table is built from.
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]
    let theme: MarkdownTheme
    let fontScale: CGFloat
    let preconverted: TableText?
    let background: Color
    let searchTerm: String
    let focusedOccurrence: Int?
    let onLink: (URL) -> Void

    func makeCoordinator() -> TextViewLinkDelegate { TextViewLinkDelegate(onLink: onLink) }

    func makeNSView(context: Context) -> TableTextView {
        let textView = TableTextView()
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.delegate = context.coordinator
        // Keep the renderer's link color/underline — only add the pointer cursor.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TableTextView, context: Context) -> CGSize? {
        nsView.size(fitting: proposal)
    }

    func updateNSView(_ textView: TableTextView, context: Context) {
        context.coordinator.onLink = onLink

        // By value: `NSColor(Color)` is a fresh object per call.
        if textView.tableBackgroundSource != background {
            textView.tableBackgroundSource = background
            textView.tableBackground = NSColor(background)
            textView.needsDisplay = true
        }

        // At most one build per source per view: the measurer's instance when
        // it was built from exactly this source, otherwise our own.
        let source = TableText.Source(headers: headers, rows: rows, alignments: alignments,
                                      theme: theme, fontScale: fontScale)
        let textChanged = textView.tableSource != source
        if textChanged {
            let table = preconverted.flatMap { $0.source == source ? $0 : nil }
                ?? TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments,
                                          theme: theme, fontScale: fontScale)
            textView.textStorage?.setAttributedString(table.string)
            textView.cachedAttributed = table.string
            textView.tableLayout = table.layout
            textView.tableSource = table.source
            textView.invalidateMeasurement()
        }

        let searchChanged = (textView.lastSearchTerm != searchTerm) ||
                            (textView.lastFocusedOccurrence != focusedOccurrence)
        if textChanged || searchChanged {
            // The text rows' highlight on the whole table string: `DocumentSearch`
            // counted this block on the same characters with the same matcher
            // (TS-D9), so the focused occurrence is the n-th highlight in
            // reading order.
            applyNSSearchHighlight(in: textView, term: searchTerm, focusedOccurrence: focusedOccurrence)
            textView.lastSearchTerm = searchTerm
            textView.lastFocusedOccurrence = focusedOccurrence
        }

        // As `BlockTextView`: the row's block id comes from the hosting cell's
        // environment, and the covered range is re-read after every string change.
        textView.attachSelection(context.environment.blockSelection)
    }

    static func dismantleNSView(_ textView: TableTextView, coordinator: TextViewLinkDelegate) {
        textView.detachSelection()
    }
}

// MARK: - Table Text View

/// `SelfSizingTextView` (sizing, refusing first responder, selection drawing,
/// AX — the whole text-row plumbing) with the three things that differ for a
/// table: the rounded clip + background, the height (`TableTextBuilder`'s,
/// not `usedRect`), and the cell-confined hit-test hook.
final class TableTextView: SelfSizingTextView {
    /// The cell layout of the installed string; set with it.
    var tableLayout: TableTextLayout?
    /// What the installed string was built from — the representable's rebuild key.
    var tableSource: TableText.Source?
    /// The table's own background (1.12 `.background(theme.backgroundColor)`),
    /// painted inside the rounded clip, and the theme colour it came from.
    var tableBackground: NSColor = .clear
    var tableBackgroundSource: Color?

    /// Everything — background, header band, rules, selection, search
    /// highlights, text — is clipped to the rounded rect (1.12 `.clipShape`).
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: BlockLayout.Table.cornerRadius,
                     yRadius: BlockLayout.Table.cornerRadius).addClip()
        tableBackground.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func layoutHeight(layoutManager: NSLayoutManager, container: NSTextContainer) -> CGFloat {
        TableTextBuilder.tableHeight(layoutManager: layoutManager, container: container)
    }

    override func selectionCharacterIndex(at point: NSPoint) -> Int {
        guard let tableLayout, tableLayout.length == selectionTextLength else {
            return super.selectionCharacterIndex(at: point)
        }
        return characterIndex(confinedToCellAt: point, layout: tableLayout)
    }
}
