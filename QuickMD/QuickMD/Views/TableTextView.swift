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
        let table = preconverted.flatMap {
            $0.matches(headers: headers, rows: rows, alignments: alignments, fontScale: fontScale) ? $0 : nil
        } ?? TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments,
                                    theme: theme, fontScale: fontScale)

        TableTextRepresentable(
            table: table,
            headers: headers,
            rows: rows,
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
    let table: TableText
    /// The cells' markdown, for the 1.12 search mapping (`applyTableSearchHighlight`).
    let headers: [String]
    let rows: [[String]]
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

        let fill = NSColor(background)
        if textView.tableBackground != fill {
            textView.tableBackground = fill
            textView.needsDisplay = true
        }

        let textChanged = (textView.cachedAttributed !== table.string)
        if textChanged {
            textView.textStorage?.setAttributedString(table.string)
            textView.cachedAttributed = table.string
            textView.tableLayout = table.layout
            textView.invalidateMeasurement()
        }

        let searchChanged = (textView.lastSearchTerm != searchTerm) ||
                            (textView.lastFocusedOccurrence != focusedOccurrence)
        if textChanged || searchChanged {
            applyTableSearchHighlight(in: textView, layout: table.layout, headers: headers, rows: rows,
                                      term: searchTerm, focusedOccurrence: focusedOccurrence)
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
    /// The table's own background (1.12 `.background(theme.backgroundColor)`),
    /// painted inside the rounded clip.
    var tableBackground: NSColor = .clear

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

// MARK: - Search highlight (1.12 semantics)

/// Search highlighting for a table, with exactly 1.12's mapping (TS-T3 replaces
/// it with `applyNSSearchHighlight` on the rendered string, TS-D9).
///
/// `DocumentSearch` counts a table's matches in the cells' MARKDOWN (headers
/// first, then rows, left to right), so the block's focused occurrence is an
/// index into those raw counts. Each cell therefore maps it to a cell-local
/// index (`focused − occurrences in earlier cells`, if below this cell's raw
/// count) and highlights the matches in its RENDERED text, the focused one
/// orange — what 1.12's per-cell `searchHighlight` did. Main-thread by
/// convention, like `applyNSSearchHighlight`.
func applyTableSearchHighlight(in textView: NSTextView, layout: TableTextLayout,
                               headers: [String], rows: [[String]],
                               term: String, focusedOccurrence: Int?) {
    guard let layoutManager = textView.layoutManager,
          let storage = textView.textStorage else { return }
    layoutManager.removeTemporaryAttribute(.backgroundColor,
                                           forCharacterRange: NSRange(location: 0, length: storage.length))
    guard !term.isEmpty, storage.length == layout.length else { return }

    let needle = term.lowercased()
    let string = storage.string as NSString
    let yellow = NSColor.systemYellow.withAlphaComponent(0.55)
    let orange = NSColor.systemOrange
    var earlier = 0

    func highlight(band: Int?, column: Int, markdown: String) {
        let rawCount = countOccurrences(in: markdown, of: term)
        defer { earlier += rawCount }
        guard let band, band < layout.bandCount else { return }
        let local = focusedOccurrence.map { $0 - earlier }.flatMap { (0..<rawCount).contains($0) ? $0 : nil }
        let cell = layout.cellRanges[band][column]
        guard cell.length > 0 else { return }
        let haystack = string.substring(with: cell).lowercased() as NSString
        var location = 0
        var index = 0
        while location < haystack.length {
            let found = haystack.range(of: needle, options: [],
                                       range: NSRange(location: location, length: haystack.length - location))
            if found.location == NSNotFound { break }
            let target = NSIntersectionRange(NSRange(location: cell.location + found.location, length: found.length),
                                             cell)
            if target.length > 0 {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: index == local ? orange : yellow,
                                                    forCharacterRange: target)
            }
            location = found.location + max(found.length, 1)
            index += 1
        }
    }

    // 1.12 counted the header cells even when the band is hidden (all blank).
    for column in 0..<layout.columnCount {
        highlight(band: layout.showsHeader ? 0 : nil, column: column,
                  markdown: column < headers.count ? headers[column] : "")
    }
    let firstRowBand = layout.showsHeader ? 1 : 0
    for (index, row) in rows.enumerated() {
        for column in 0..<layout.columnCount {
            highlight(band: firstRowBand + index, column: column,
                      markdown: column < row.count ? row[column] : "")
        }
    }
}
