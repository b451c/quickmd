import AppKit
import SwiftUI

// MARK: - Tables as text (v1.13 TS-D1…TS-D4)
//
// A `.table` row is ONE NSTextView whose string is a TextKit 1 `NSTextTable`
// (one `NSTextTableBlock` per cell), so the table is a single selectable string
// like every other text row (v1.11 S-D2) instead of a SwiftUI grid that could
// only be selected whole.
//
// This file is compiled into the app AND the test target: the measurer
// (`BlockHeightMeasurer`), the on-screen view (`Views/TableTextView.swift`) and
// `MarkdownView.selectableText` all build the string HERE, and the parity tests
// lay out the very same string. A second construction anywhere would be a
// height that disagrees with the drawn table (an `.exact` row that clips) or
// selection offsets that point at the wrong characters.

// MARK: - String layout

/// Where every cell sits inside the string `TableTextBuilder` produces.
///
/// The string is the cells in reading order — the header band first (only when
/// the table shows one), then each data row, left to right — and every cell is
/// exactly ONE paragraph:
///
///     <cell 0,0 text>\n<cell 0,1 text>\n … <cell 0,n-1 text>\n<cell 1,0 text>\n …
///
/// - `cellRanges[band][column]` is the cell's rendered text, WITHOUT its
///   terminating "\n" (an empty cell is a zero-length range sitting right
///   before its "\n"). The "\n" at `NSMaxRange(range)` belongs to the cell: it
///   carries the cell's paragraph style (its `NSTextTableBlock`), and the last
///   cell's "\n" is the last character of the string.
/// - A band ("row" on screen) is the contiguous range from its first cell's
///   location to its last cell's "\n" inclusive.
/// - Every band has `columnCount` cells: ragged rows are padded with empty
///   cells, so the column of a character is always well defined.
/// - Offsets are UTF-16 (NSString), the unit `DocumentSelection` uses.
struct TableTextLayout: Equatable {
    let columnCount: Int
    /// Band 0 is the header band when true.
    let showsHeader: Bool
    /// `[band][column]` — see the type comment.
    let cellRanges: [[NSRange]]

    var bandCount: Int { cellRanges.count }

    /// UTF-16 length of the whole string (0 for a table with no bands).
    var length: Int {
        guard let last = cellRanges.last?.last else { return 0 }
        return NSMaxRange(last) + 1
    }

    /// The cell a character index falls in; a cell's own "\n" counts as that
    /// cell. nil before the start or past the end.
    ///
    /// Bands are contiguous and ascending, so the band is a binary search —
    /// the selection asks this per drag event, and a table can have hundreds
    /// of rows.
    func cell(containing index: Int) -> (band: Int, column: Int)? {
        guard index >= 0, index < length else { return nil }
        var low = 0, high = bandCount - 1
        while low < high {
            let mid = (low + high) / 2
            if index <= NSMaxRange(cellRanges[mid][columnCount - 1]) { high = mid } else { low = mid + 1 }
        }
        for column in 0..<columnCount where index <= NSMaxRange(cellRanges[low][column]) {
            return (low, column)
        }
        return nil
    }
}

/// A table block's string plus its layout, built once by `TableTextBuilder`.
///
/// `source` is everything it was built from. `BlockHeightMeasurer` hands these
/// to the view through `MeasuredBlocks.tables` (keyed by the POSITIONAL block
/// id), so the view compares `source` before trusting one — a cell that still
/// shows the previous parse's `table-2` must not draw the new parse's `table-2`.
struct TableText {
    /// The block's cells plus what `MarkdownView.DocumentIdentity` re-parses
    /// for: theme (name + light/dark variant — "Auto" is one name for two
    /// palettes), document fonts, zoom. An instance built for another theme or
    /// font therefore never matches, whatever the parse ordering.
    struct Source: Equatable {
        let headers: [String]
        let rows: [[String]]
        let alignments: [TextAlignment]
        let fontScale: CGFloat
        let themeName: String
        let isDark: Bool
        let fonts: DocumentFonts

        init(headers: [String], rows: [[String]], alignments: [TextAlignment],
             theme: MarkdownTheme, fontScale: CGFloat) {
            self.headers = headers
            self.rows = rows
            self.alignments = alignments
            self.fontScale = fontScale
            themeName = theme.name
            isDark = theme.isDark
            fonts = theme.fonts
        }
    }

    let string: NSAttributedString
    let layout: TableTextLayout
    let source: Source

    func matches(headers: [String], rows: [[String]], alignments: [TextAlignment],
                 theme: MarkdownTheme, fontScale: CGFloat) -> Bool {
        source == Source(headers: headers, rows: rows, alignments: alignments, theme: theme, fontScale: fontScale)
    }
}

/// An `NSTextTable` whose columns fill the available width exactly.
///
/// With `fixedLayoutAlgorithm` TextKit floors every column to whole points, so
/// the cells stop up to `columnCount - 1` pt short of the container (measured:
/// 6–7 pt for 8 columns) and the header band, the rules and the outline no
/// longer meet — 1.12's grid filled the width. This override hands out the
/// columns itself: whole points, `floor(width / n)` each, the remainder 1 pt at
/// a time to the first columns (and a fractional width's last fraction to the
/// last one), so they tile `rect` with no gap. Only x and width of the content
/// rect change; TextKit still decides the row heights and the vertical layout,
/// and the measurer lays out the same subclass, so parity is unaffected.
final class FullWidthTextTable: NSTextTable {
    override func rect(for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
                       textContainer: NSTextContainer, characterRange charRange: NSRange) -> NSRect {
        var layoutRect = super.rect(for: block, layoutAt: startingPoint, in: rect,
                                    textContainer: textContainer, characterRange: charRange)
        let columns = max(1, numberOfColumns)
        let column = min(max(0, block.startingColumn), columns - 1)
        let whole = floor(rect.width)
        let base = floor(whole / CGFloat(columns))
        let remainder = Int(whole - base * CGFloat(columns))
        let x = rect.minX + base * CGFloat(column) + CGFloat(min(column, remainder))
        var width = base + (column < remainder ? 1 : 0)
        if column == columns - 1 { width += rect.width - whole }
        let leading = block.width(for: .margin, edge: .minX) + block.width(for: .border, edge: .minX)
            + block.width(for: .padding, edge: .minX)
        let trailing = block.width(for: .margin, edge: .maxX) + block.width(for: .border, edge: .maxX)
            + block.width(for: .padding, edge: .maxX)
        layoutRect.origin.x = x + leading
        layoutRect.size.width = BlockLayout.clampedWidth(width - leading - trailing)
        return layoutRect
    }
}

// MARK: - Builder

/// Builds the attributed string of a `.table` block: one `NSTextTable`, one
/// `NSTextTableBlock` per cell, each cell's inline styling from
/// `MarkdownRenderer.renderInline` (AppKit scope).
///
/// The look is the one 1.12's SwiftUI table DREW, measured, not what its
/// modifiers asked for (TS-D2). Metrics come from `BlockLayout.Table`:
/// - columns are equal, whole points, and fill the width exactly
///   (`FullWidthTextTable`); a cell can wrap a word earlier than 1.12's
///   fractional columns did. The measurer lays out the same string, so it is
///   self-consistent, and the dividers land on whole points;
/// - a cell's padding is 1.12's `.padding`; its 1 pt rule is a BORDER on its
///   trailing edge (not the last column) and its bottom edge (not the last
///   data row — the header always has one, as 1.12's header separator), so
///   neighbouring cells never draw a rule twice;
/// - cells are centred vertically in their band (`.middleAlignment` — the
///   HStack's default alignment in 1.12), not top-aligned as text tables are
///   by default;
/// - header cells get `headerBackgroundColor`; the table's own background, the
///   rounded clip and the outline are the hosting view's job.
///
/// Font: every run carries the renderer's explicit `cellFontSize`·scale font,
/// header included — that is what 1.12 drew (its `.font(13 [semibold])`
/// modifiers lost to the runs' own font).
///
/// Pure: value types plus objects it creates, no actor isolation — safe off-main
/// (the measurer calls it from the parse task).
enum TableTextBuilder {

    typealias Metrics = BlockLayout.Table

    static func build(headers: [String], rows: [[String]], alignments: [TextAlignment],
                      theme: MarkdownTheme, fontScale: CGFloat) -> TableText {
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
        let (columnCount, showsHeader, bands) = grid(headers: headers, rows: rows, alignments: alignments)

        let table = FullWidthTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = false
        table.hidesEmptyCells = false

        let border = NSColor(theme.borderColor)
        let headerBackground = NSColor(theme.headerBackgroundColor)
        // The "\n" of a cell (and so an empty cell's only line) needs the cell
        // font too, or its line takes the 12 pt default height.
        let terminatorAttributes: [NSAttributedString.Key: Any] = [
            .font: theme.fonts.appKit(size: Metrics.cellFontSize * fontScale),
            .foregroundColor: NSColor(theme.textColor),
        ]
        let alignmentsByColumn = (0..<columnCount).map {
            nsAlignment($0 < alignments.count ? alignments[$0] : .leading)
        }

        let result = NSMutableAttributedString()
        var cellRanges: [[NSRange]] = []
        cellRanges.reserveCapacity(bands.count)
        let lastDataBand = bands.count - 1
        for (bandIndex, band) in bands.enumerated() {
            let isHeader = showsHeader && bandIndex == 0
            var ranges: [NSRange] = []
            ranges.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                let cell = renderedCell(column < band.count ? band[column] : "", renderer: renderer)
                ranges.append(NSRange(location: result.length, length: cell.length))
                cell.append(NSAttributedString(string: "\n", attributes: terminatorAttributes))

                let block = NSTextTableBlock(table: table, startingRow: bandIndex, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                let vertical = isHeader ? Metrics.headerCellVerticalPadding : Metrics.cellVerticalPadding
                block.setWidth(Metrics.cellHorizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(Metrics.cellHorizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(vertical, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(vertical, type: .absoluteValueType, for: .padding, edge: .maxY)
                if column < columnCount - 1 {
                    block.setWidth(Metrics.dividerWidth, type: .absoluteValueType, for: .border, edge: .maxX)
                }
                if isHeader || bandIndex < lastDataBand {
                    block.setWidth(Metrics.separatorHeight, type: .absoluteValueType, for: .border, edge: .maxY)
                }
                block.setBorderColor(border)
                block.verticalAlignment = .middleAlignment
                if isHeader { block.backgroundColor = headerBackground }

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.alignment = alignmentsByColumn[column]
                cell.addAttribute(.paragraphStyle, value: paragraph,
                                  range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
            cellRanges.append(ranges)
        }
        return TableText(
            string: result,
            layout: TableTextLayout(columnCount: columnCount, showsHeader: showsHeader, cellRanges: cellRanges),
            source: TableText.Source(headers: headers, rows: rows, alignments: alignments,
                                     theme: theme, fontScale: fontScale))
    }

    /// The characters of `build(...).string` — the cells' rendered text, each
    /// followed by its "\n", in the same order — without building the table:
    /// no `NSTextTable`, blocks or paragraph styles. `DocumentSearch` counts a
    /// table's matches in this string when the measurer has no `TableText` for
    /// the block, so the count is taken on exactly what the view shows (TS-D9).
    /// Same `grid` and `renderedCell` as `build`, so the two cannot disagree;
    /// pinned by `SearchTests`.
    static func plainString(headers: [String], rows: [[String]], alignments: [TextAlignment],
                            theme: MarkdownTheme, fontScale: CGFloat) -> String {
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
        let (columnCount, _, bands) = grid(headers: headers, rows: rows, alignments: alignments)
        var result = ""
        for band in bands {
            for column in 0..<columnCount {
                result += renderedCell(column < band.count ? band[column] : "", renderer: renderer).string
                result += "\n"
            }
        }
        return result
    }

    /// The bands the string is made of: the header band only when it shows
    /// (all-blank headers ⇒ no header band), then the rows. The separator row
    /// is authoritative (constraints.md "Tables"); ragged rows widen the table
    /// rather than lose cells.
    private static func grid(headers: [String], rows: [[String]], alignments: [TextAlignment])
        -> (columnCount: Int, showsHeader: Bool, bands: [[String]]) {
        let columnCount = max(1, max(headers.count, alignments.count, rows.map(\.count).max() ?? 0))
        let showsHeader = headers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var bands: [[String]] = []
        if showsHeader { bands.append(headers) }
        bands.append(contentsOf: rows)
        return (columnCount, showsHeader, bands)
    }

    /// One cell's rendered text (AppKit scope), without its "\n".
    private static func renderedCell(_ markdown: String, renderer: MarkdownRenderer) -> NSMutableAttributedString {
        let cell = NSMutableAttributedString(
            attributedString: (try? NSAttributedString(renderer.renderInline(markdown), including: \.appKit))
                ?? NSAttributedString(string: markdown))
        // One paragraph per cell is the layout's invariant (TS-D4). A table row
        // is one source line, so this never fires today; it keeps the
        // invariant if the renderer ever emits a break.
        cell.mutableString.replaceOccurrences(of: "\n", with: " ", options: [],
                                              range: NSRange(location: 0, length: cell.length))
        return cell
    }

    /// The table's height in a laid-out container — the view's
    /// (`TableTextView.layoutHeight`) and the measurer's (`height(of:width:)`).
    ///
    /// NOT `usedRect`: the string ends with the last cell's "\n", so TextKit
    /// adds its extra (empty) line fragment BELOW the table — one body line
    /// that is not part of it. The last cell cannot drop its "\n" instead: an
    /// empty last cell would then be a zero-length paragraph with no text
    /// block, i.e. a missing cell. An empty string (no bands) is 0 pt, as the
    /// empty 1.12 grid was.
    static func tableHeight(layoutManager: NSLayoutManager, container: NSTextContainer) -> CGFloat {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return 0 }
        layoutManager.ensureLayout(for: container)
        let extra = layoutManager.extraLineFragmentRect
        return ceil(extra.isEmpty ? layoutManager.usedRect(for: container).height : extra.minY)
    }

    /// Height of `string` laid out at `width` by a standalone TextKit 1 stack,
    /// configured as `BlockHeightMeasurer.exactHeight` is (and as
    /// `SelfSizingTextView`'s measuring stack is), measured with `tableHeight`.
    static func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: string)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(0, width),
                                                    height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        return tableHeight(layoutManager: layoutManager, container: container)
    }

    /// A column's `TextAlignment` (from the separator row) as a paragraph
    /// alignment.
    static func nsAlignment(_ alignment: TextAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        @unknown default: return .left
        }
    }
}

// MARK: - Cell geometry and hit-testing

extension NSTextView {
    /// The bounds of a cell (padding + its borders) in view coordinates, or nil
    /// when the text view does not hold the table `layout` describes.
    func tableCellBounds(band: Int, column: Int, layout: TableTextLayout) -> NSRect? {
        guard let layoutManager, let storage = textStorage,
              band >= 0, band < layout.bandCount, column >= 0, column < layout.columnCount else { return nil }
        let range = layout.cellRanges[band][column]
        guard NSMaxRange(range) < storage.length,
              let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle, let block = style.textBlocks.first else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location,
                                                                         length: range.length + 1),
                                              actualCharacterRange: nil)
        return layoutManager.boundsRect(for: block, glyphRange: glyphs)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The insertion index for `point` (view coordinates), confined to the cell
    /// under the point — the table view's answer to the selection's hit-test
    /// (TS-D6).
    ///
    /// `characterIndexForInsertion(at:)` alone is wrong for any point that is
    /// not on one of the cell's line fragments: in the padding, or in the empty
    /// space of a short cell in a tall band, TextKit picks whichever fragment of
    /// ANY cell is nearest — usually the neighbour's text (19 of 36 probes in
    /// the prototype). So: find the cell by its block bounds (the nearest cell
    /// when the point is outside the table), clamp the point into the used rect
    /// of that cell's nearest line, and only then ask TextKit.
    func characterIndex(confinedToCellAt point: NSPoint, layout: TableTextLayout) -> Int {
        guard let layoutManager, layout.bandCount > 0 else { return 0 }
        // Bands stack top to bottom and every cell of a band spans the band's
        // height, so column 0 locates the band (binary search), then the
        // columns of that band locate the cell.
        var low = 0, high = layout.bandCount - 1
        while low < high {
            let mid = (low + high) / 2
            let rect = tableCellBounds(band: mid, column: 0, layout: layout) ?? .zero
            if point.y < rect.maxY { high = mid } else { low = mid + 1 }
        }
        let band = low
        var column = 0
        var nearest = CGFloat.greatestFiniteMagnitude
        for candidate in 0..<layout.columnCount {
            guard let rect = tableCellBounds(band: band, column: candidate, layout: layout) else { continue }
            let distance = max(rect.minX - point.x, 0, point.x - rect.maxX)
            if distance < nearest { nearest = distance; column = candidate }
        }

        let range = layout.cellRanges[band][column]
        guard range.length > 0 else { return range.location }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var line: NSRect?
        var lineDistance = CGFloat.greatestFiniteMagnitude
        // The USED rect: past the end of a cell's last line, TextKit answers
        // with an index outside the cell (measured: the next cell's text).
        let origin = textContainerOrigin
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            let rect = used.offsetBy(dx: origin.x, dy: origin.y)
            let distance = max(rect.minY - point.y, 0, point.y - rect.maxY)
            if distance < lineDistance { lineDistance = distance; line = rect }
        }
        guard let line else { return range.location }
        let clamped = NSPoint(x: min(max(point.x, line.minX), line.maxX - 0.5),
                              y: min(max(point.y, line.minY + 0.5), line.maxY - 0.5))
        // The cell is already decided by geometry; TextKit can still answer
        // with the end of the string for the right end of a last-band cell's
        // last line (once in 36 probes), so keep the answer in the cell.
        return min(max(characterIndexForInsertion(at: clamped), range.location), NSMaxRange(range))
    }
}
