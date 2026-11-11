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

    /// Column 0 of every band — a `.properties` table's key cells.
    var firstColumnRanges: [NSRange] { cellRanges.compactMap(\.first) }

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
    /// palettes), document fonts, zoom — and the style: a `.properties` and a
    /// `.grid` table of the same cells are different strings (key colour, key
    /// column width). An instance built for another theme or font therefore
    /// never matches, whatever the parse ordering.
    struct Source: Equatable {
        let headers: [String]
        let rows: [[String]]
        let alignments: [TextAlignment]
        let style: TableStyle
        let fontScale: CGFloat
        let themeName: String
        let isDark: Bool
        let fonts: DocumentFonts

        init(headers: [String], rows: [[String]], alignments: [TextAlignment], style: TableStyle,
             theme: MarkdownTheme, fontScale: CGFloat) {
            self.headers = headers
            self.rows = rows
            self.alignments = alignments
            self.style = style
            self.fontScale = fontScale
            themeName = theme.name
            isDark = theme.isDark
            fonts = theme.fonts
        }
    }

    let string: NSAttributedString
    let layout: TableTextLayout
    let source: Source
    /// The colour of the rules between cells (`theme.borderColor`), drawn by
    /// `paintTableRules` — the string's own cell borders are clear (#56, see
    /// `TableTextBuilder`). Built with the string, so the rules and the
    /// header band always come from the same theme.
    let ruleColor: NSColor

    func matches(headers: [String], rows: [[String]], alignments: [TextAlignment], style: TableStyle,
                 theme: MarkdownTheme, fontScale: CGFloat) -> Bool {
        source == Source(headers: headers, rows: rows, alignments: alignments, style: style,
                         theme: theme, fontScale: fontScale)
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
///
/// `fixedFirstColumnWidth` (a `.properties` table's key column): column 0 gets
/// that many whole points, capped at `Metrics.keyColumnMaxFraction` of the
/// width, and the other columns tile the rest exactly as above. The value is a
/// property of the table object INSIDE the string, so the view and the
/// measurer — which lay out the same string at the same width — agree; the cap
/// makes the split width-dependent, which `.exact` heights already are (every
/// table re-measures per `contentWidth`, as wrapping does).
final class FullWidthTextTable: NSTextTable {
    /// Column 0's natural width (whole points), or nil for equal columns.
    var fixedFirstColumnWidth: CGFloat?

    override func rect(for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
                       textContainer: NSTextContainer, characterRange charRange: NSRange) -> NSRect {
        var layoutRect = super.rect(for: block, layoutAt: startingPoint, in: rect,
                                    textContainer: textContainer, characterRange: charRange)
        let columns = max(1, numberOfColumns)
        let column = min(max(0, block.startingColumn), columns - 1)
        let whole = floor(rect.width)
        // A fixed first column is taken off the front; the remaining columns
        // share what is left (equal whole points, remainder to the first).
        let fixed = columns > 1 ? fixedFirstColumnWidth.map {
            min(ceil($0), floor(whole * BlockLayout.Table.keyColumnMaxFraction))
        } : nil
        var x: CGFloat
        var width: CGFloat
        if let fixed, column == 0 {
            x = rect.minX
            width = fixed
        } else {
            let leadingFixed = fixed ?? 0
            let shared = fixed == nil ? columns : columns - 1
            let index = fixed == nil ? column : column - 1
            let available = whole - leadingFixed
            let base = floor(available / CGFloat(shared))
            let remainder = Int(available - base * CGFloat(shared))
            x = rect.minX + leadingFixed + base * CGFloat(index) + CGFloat(min(index, remainder))
            width = base + (index < remainder ? 1 : 0)
        }
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
///   neighbouring cells never draw a rule twice. The border WIDTHS stay in the
///   blocks (they are layout: cell rects and row heights depend on them), but
///   the border COLOUR is clear and the rules are painted by
///   `paintTableRules` from the laid-out cells (#56: on macOS 27.2 AppKit
///   painted the dividers but none of the bottom borders — every horizontal
///   rule was gone; not reproducible on 27.0, so we no longer depend on it);
/// - cells are centred vertically in their band (`.middleAlignment` — the
///   HStack's default alignment in 1.12), not top-aligned as text tables are
///   by default;
/// - header cells get `headerBackgroundColor`; the table's own background, the
///   rounded clip and the outline are the hosting view's job.
///
/// Font: every run carries the renderer's explicit `cellFontSize`·scale font;
/// header cells are raised to semibold (v1.13, the user's call). 1.12's
/// SwiftUI view asked for a semibold header too, but its `.font` modifier lost
/// to the runs' own font, so headers drew regular until v1.13.
///
/// Pure: value types plus objects it creates, no actor isolation — safe off-main
/// (the measurer calls it from the parse task).
enum TableTextBuilder {

    typealias Metrics = BlockLayout.Table

    static func build(headers: [String], rows: [[String]], alignments: [TextAlignment], style: TableStyle,
                      theme: MarkdownTheme, fontScale: CGFloat) -> TableText {
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
        let (columnCount, showsHeader, bands) = grid(headers: headers, rows: rows, alignments: alignments)
        // Rendered once: the key column's width is measured on these very cells.
        let renderedBands = bands.map { band in
            (0..<columnCount).map { column in
                renderedCell(column < band.count ? band[column] : "", column: column, style: style,
                             renderer: renderer)
            }
        }

        let table = FullWidthTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = false
        table.hidesEmptyCells = false
        if style == .properties, columnCount > 1 {
            table.fixedFirstColumnWidth = keyColumnWidth(textWidth: naturalWidth(of: renderedBands.map { $0[0] }))
        }

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
        for (bandIndex, band) in renderedBands.enumerated() {
            let isHeader = showsHeader && bandIndex == 0
            var ranges: [NSRange] = []
            ranges.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                let cell = band[column]
                if isHeader { raiseToHeaderWeight(cell) }
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
                // Clear: AppKit must not paint the rules (#56) — the view
                // paints them, once, in `paintTableRules`. A translucent theme
                // colour painted by both would show darker.
                block.setBorderColor(.clear)
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
            source: TableText.Source(headers: headers, rows: rows, alignments: alignments, style: style,
                                     theme: theme, fontScale: fontScale),
            ruleColor: border)
    }

    /// The key column's fixed width for a widest key of `textWidth`: the text
    /// plus the cell's horizontal paddings and its trailing divider (a border
    /// inside the column), so the widest key fits on one line. The 40 % cap is
    /// applied at layout time (`FullWidthTextTable`), where the width is known.
    static func keyColumnWidth(textWidth: CGFloat) -> CGFloat {
        ceil(textWidth) + 2 * Metrics.cellHorizontalPadding + Metrics.dividerWidth
    }

    /// The widest line of `cells`, each laid out unwrapped by TextKit 1 — the
    /// engine that lays the cells out in the table, so a key measured here fits
    /// its column. Off-main safe (standalone stack, like `height(of:width:)`).
    /// Paragraph styles are dropped: a cell that already sits in a table
    /// would otherwise be laid out in its table block, not unwrapped.
    static func naturalWidth(of cells: [NSAttributedString]) -> CGFloat {
        let joined = NSMutableAttributedString()
        for (index, cell) in cells.enumerated() {
            if index > 0 { joined.append(NSAttributedString(string: "\n")) }
            joined.append(cell)
        }
        guard joined.length > 0 else { return 0 }
        joined.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: joined.length))
        let storage = NSTextStorage(attributedString: joined)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                    height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).width)
    }

    /// The characters of `build(...).string` — the cells' rendered text, each
    /// followed by its "\n", in the same order — without building the table:
    /// no `NSTextTable`, blocks or paragraph styles. `DocumentSearch` counts a
    /// table's matches in this string when the measurer has no `TableText` for
    /// the block, so the count is taken on exactly what the view shows (TS-D9).
    /// Same `grid` and `renderedCell` as `build`, so the two cannot disagree;
    /// pinned by `SearchTests`.
    static func plainString(headers: [String], rows: [[String]], alignments: [TextAlignment], style: TableStyle,
                            theme: MarkdownTheme, fontScale: CGFloat) -> String {
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
        let (columnCount, _, bands) = grid(headers: headers, rows: rows, alignments: alignments)
        var result = ""
        for band in bands {
            for column in 0..<columnCount {
                result += renderedCell(column < band.count ? band[column] : "", column: column, style: style,
                                       renderer: renderer).string
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

    /// One cell's rendered text (AppKit scope), without its "\n". A
    /// `.properties` key (column 0) is literal (`keyCell`), its value
    /// `valueCell`, every grid cell inline Markdown.
    private static func renderedCell(_ markdown: String, column: Int, style: TableStyle,
                                     renderer: MarkdownRenderer) -> NSMutableAttributedString {
        let attributed = style == .properties
            ? (column == 0 ? keyCell(markdown, renderer: renderer) : valueCell(markdown, renderer: renderer))
            : renderer.renderInline(markdown)
        let cell = NSMutableAttributedString(
            attributedString: (try? NSAttributedString(attributed, including: \.appKit))
                ?? NSAttributedString(string: markdown))
        // One paragraph per cell is the layout's invariant (TS-D4). A table row
        // is one source line, so this never fires today; it keeps the
        // invariant if the renderer ever emits a break.
        cell.mutableString.replaceOccurrences(of: "\n", with: " ", options: [],
                                              range: NSRange(location: 0, length: cell.length))
        return cell
    }

    /// A `.properties` key: the key's characters exactly as written — never
    /// through `renderInline`, so `*`, `_`, `~~`, `[x]` or a URL in a key are
    /// not markup — in the font `renderInline` gives plain text (cell size ×
    /// zoom, regular) and the theme's secondary colour, both scopes (screen
    /// table: AppKit; print: SwiftUI `Text`).
    static func keyCell(_ key: String, renderer: MarkdownRenderer) -> AttributedString {
        var cell = AttributedString(key)
        cell.setDualFont(size: renderer.scaled(Metrics.cellFontSize), fonts: renderer.theme.fonts)
        cell.setDualForeground(renderer.theme.secondaryTextColor)
        return cell
    }

    /// A `.properties` value: inline Markdown (a URL is a link, `**x**` is
    /// bold) except that a backslash is literal, as in the YAML it came from
    /// (`C:\_tmp` shows `C:\_tmp`, not `C:_tmp`), and so is a character
    /// reference (`&amp;` stays `&amp;`: GitHub renders front matter as plain
    /// text). Screen and print.
    static func valueCell(_ value: String, renderer: MarkdownRenderer) -> AttributedString {
        renderer.renderInline(value, literalBackslashes: true, literalEntities: true)
    }

    /// Header cells are semibold. Only raises the weight: a `**bold**` run
    /// stays bold, italic and monospaced runs keep their face. A family
    /// without a semibold face (a Settings font) falls back to its bold.
    /// Attributes only — the characters (search, copy) are unchanged.
    static func raiseToHeaderWeight(_ cell: NSMutableAttributedString) {
        cell.enumerateAttribute(.font, in: NSRange(location: 0, length: cell.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let raised = headerWeightFont(font)
            if raised !== font { cell.addAttribute(.font, value: raised, range: range) }
        }
    }

    /// `font` at header weight (see `raiseToHeaderWeight`), or `font` itself
    /// when it is already semibold or heavier.
    static func headerWeightFont(_ font: NSFont) -> NSFont {
        let semibold = NSFont.Weight.semibold.rawValue
        func weight(of font: NSFont) -> CGFloat {
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? CGFloat) ?? NSFont.Weight.regular.rawValue
        }
        guard weight(of: font) < semibold else { return font }
        var traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = semibold
        let descriptor = font.fontDescriptor.addingAttributes([.traits: traits])
        var raised = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        if weight(of: raised) < semibold {
            // Descriptor, not NSFontManager: build runs off-main (measurer).
            let bold = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.bold))
            raised = NSFont(descriptor: bold, size: font.pointSize) ?? font
        }
        return raised
    }

    /// One cell of the PRINT/PDF table (`PrintableTableView`, SwiftUI `Text`):
    /// the same `renderInline` runs as the screen cell, and in the header band
    /// every run raised exactly as `raiseToHeaderWeight` raises the screen's.
    ///
    /// The weight has to go onto the runs, in BOTH scopes: `renderInline`
    /// stamps an explicit font on every run, so a view-level `.font` modifier
    /// never shows (until 1.14.1 the printable header asked for 12 pt semibold
    /// that way and printed regular 14 pt), and SwiftUI `Text` reads only the
    /// SwiftUI-scope font. That one wraps the raised NSFont, so the PDF draws
    /// the very face the screen draws.
    static func printableCell(_ markdown: String, isHeader: Bool,
                              renderer: MarkdownRenderer) -> AttributedString {
        let cell = renderer.renderInline(markdown)
        guard isHeader else { return cell }
        // Rebuilt run by run from the UNCHANGED `cell`, so every range is used
        // only on the string it came from (AttributedString indices are not
        // documented to survive a mutation); each run is set on its own copy.
        var raisedCell = AttributedString()
        for run in cell.runs {
            var piece = AttributedString(cell[run.range])
            if let font = piece[AttributeScopes.AppKitAttributes.FontAttribute.self] {
                let raised = headerWeightFont(font)
                if raised !== font {
                    piece[AttributeScopes.AppKitAttributes.FontAttribute.self] = raised
                    piece.font = Font(raised as CTFont)
                }
            }
            raisedCell.append(piece)
        }
        return raisedCell
    }

    /// A printed `.properties` table's key column (`PrintableTableView`): the
    /// widest key in the export font, plus the printed cell's paddings and
    /// 1 pt, because SwiftUI `Text` may round its width up past TextKit's
    /// `ceil` by a fraction — which would wrap the widest key. The 40 % cap is
    /// `PropertiesRowLayout`'s, where the width is known.
    static func printableKeyColumnWidth(keys: [String], renderer: MarkdownRenderer,
                                        horizontalPadding: CGFloat) -> CGFloat {
        let cells = keys.map { key -> NSAttributedString in
            (try? NSAttributedString(keyCell(key, renderer: renderer), including: \.appKit))
                ?? NSAttributedString(string: key)
        }
        return naturalWidth(of: cells) + 2 * horizontalPadding + 1
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

// MARK: - Printed properties row

/// One printed `.properties` row: key cell, 1 pt divider, value cell. The key
/// column is `keyColumnWidth` capped at `keyColumnMaxFraction` of the width
/// the row is offered (every row of a table is offered the same width, so the
/// column lines up); the value takes the rest. Cells are centred vertically and
/// the divider spans the row, as in the grid's HStack.
struct PropertiesRowLayout: Layout {
    let keyColumnWidth: CGFloat

    private func columns(for width: CGFloat) -> (key: CGFloat, value: CGFloat) {
        let key = min(keyColumnWidth, floor(width * BlockLayout.Table.keyColumnMaxFraction))
        return (key, max(0, width - key - 1))
    }

    private func rowHeight(width: CGFloat, subviews: Subviews) -> CGFloat {
        guard subviews.count == 3 else { return 0 }
        let (key, value) = columns(for: width)
        return max(subviews[0].sizeThatFits(ProposedViewSize(width: key, height: nil)).height,
                   subviews[2].sizeThatFits(ProposedViewSize(width: value, height: nil)).height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            let value = subviews.count == 3 ? subviews[2].sizeThatFits(.unspecified).width : 0
            width = keyColumnWidth + 1 + value
        }
        return CGSize(width: width, height: rowHeight(width: width, subviews: subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (key, value) = columns(for: bounds.width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: key, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + key, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: 1, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.minX + key + 1, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: value, height: nil))
    }
}

// MARK: - Cell geometry and hit-testing

extension NSTextView {
    /// The bounds of a cell (padding + its borders) in view coordinates, or nil
    /// when the text view does not hold the table `layout` describes.
    func tableCellBounds(band: Int, column: Int, layout: TableTextLayout) -> NSRect? {
        tableCell(band: band, column: column, layout: layout)?.bounds
    }

    /// `tableCellBounds` plus the cell's text block (its border widths).
    private func tableCell(band: Int, column: Int, layout: TableTextLayout)
        -> (bounds: NSRect, block: NSTextBlock)? {
        guard let layoutManager, let storage = textStorage,
              band >= 0, band < layout.bandCount, column >= 0, column < layout.columnCount else { return nil }
        let range = layout.cellRanges[band][column]
        guard NSMaxRange(range) < storage.length,
              let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle, let block = style.textBlocks.first else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location,
                                                                         length: range.length + 1),
                                              actualCharacterRange: nil)
        let bounds = layoutManager.boundsRect(for: block, glyphRange: glyphs)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (bounds, block)
    }

    // MARK: Rules (#56)

    /// The table's rules in view coordinates, for the bands that intersect
    /// `rect` (all of them when nil): each cell's trailing divider and bottom
    /// rule, from its laid-out bounds and its block's border widths.
    ///
    /// The rects are the ones AppKit filled while it painted the borders
    /// itself (logged on macOS 27.0 through `fillBackgroundRectArray`): the
    /// divider spans the cell's whole height, the bottom rule the cell's width
    /// up to the divider — so where they meet, one rect covers the corner and
    /// a translucent colour is never painted twice.
    func tableRuleRects(layout: TableTextLayout, in rect: NSRect? = nil) -> [NSRect] {
        guard layout.bandCount > 0, layout.columnCount > 0 else { return [] }
        // Bands stack top to bottom (as in `characterIndex(confinedToCellAt:)`):
        // a binary search finds the first band that reaches into `rect`, so a
        // 200-row table costs only the visible bands per draw.
        var first = 0
        if let rect {
            var high = layout.bandCount - 1
            while first < high {
                let mid = (first + high) / 2
                let bounds = tableCellBounds(band: mid, column: 0, layout: layout) ?? .zero
                if bounds.maxY > rect.minY { high = mid } else { first = mid + 1 }
            }
        }
        var rules: [NSRect] = []
        for band in first..<layout.bandCount {
            for column in 0..<layout.columnCount {
                guard let (bounds, block) = tableCell(band: band, column: column, layout: layout) else { continue }
                if column == 0, let rect, bounds.minY >= rect.maxY { return rules }
                let trailing = block.width(for: .border, edge: .maxX)
                let bottom = block.width(for: .border, edge: .maxY)
                if trailing > 0 {
                    rules.append(NSRect(x: bounds.maxX - trailing, y: bounds.minY,
                                        width: trailing, height: bounds.height))
                }
                if bottom > 0 {
                    rules.append(NSRect(x: bounds.minX, y: bounds.maxY - bottom,
                                        width: bounds.width - trailing, height: bottom))
                }
            }
        }
        return rules
    }

    /// Paints the table's rules (`tableRuleRects`) in `color`. Call from
    /// `draw(_:)` AFTER `super.draw`, so nothing AppKit paints for the text
    /// (cell backgrounds, the selection, search highlights) can cover them.
    ///
    /// Why our own pass (#56): the cell borders were AppKit's job until 1.14.4,
    /// and on macOS 27.2 the bottom ones were not painted (the horizontal
    /// rules vanished, the dividers — the same mechanism on another edge —
    /// stayed; not reproducible on 27.0, so the cause inside AppKit is
    /// unknown). Here a rule depends only on the laid-out cell rects, which
    /// hit-testing and the measurer already rely on, and is painted last, in
    /// our own clip, by a plain fill. Each rect is snapped to whole device
    /// pixels (at least one), so a rule at a fractional position can never be
    /// rounded away or smeared to a faint pair of pixel rows; rules already on
    /// the pixel grid (every case measured) draw exactly as before.
    func paintTableRules(layout: TableTextLayout, color: NSColor, in dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rules = tableRuleRects(layout: layout, in: dirtyRect).filter { $0.intersects(dirtyRect) }
        guard !rules.isEmpty else { return }
        color.setFill()
        for rule in rules {
            TableTextBuilder.pixelAligned(rule, in: context).fill(using: .sourceOver)
        }
    }

    /// The whole of `TableTextView.draw`, here so the unit tests draw a table
    /// through the very same steps: everything clipped to the rounded rect
    /// (1.12 `.clipShape`), the table's background, then `drawText` (the
    /// view's `super.draw`: header band, selection, search highlights, text),
    /// then the rules on top (`paintTableRules`). The rules need `layout` to
    /// describe the installed string; while it does not (no table yet), only
    /// the text is drawn.
    func drawTable(in dirtyRect: NSRect, background: NSColor, layout: TableTextLayout?, ruleColor: NSColor,
                   drawText: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: BlockLayout.Table.cornerRadius,
                     yRadius: BlockLayout.Table.cornerRadius).addClip()
        background.setFill()
        dirtyRect.fill()
        drawText()
        if let layout, layout.length == (textStorage?.length ?? 0) {
            paintTableRules(layout: layout, color: ruleColor, in: dirtyRect)
        }
        NSGraphicsContext.restoreGraphicsState()
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

extension TableTextBuilder {
    /// `rect` with every edge moved to the nearest device pixel of `context`,
    /// and never thinner than one pixel — the grid of whatever the view draws
    /// into (window backing store, layer, bitmap), not the screen's guess.
    static func pixelAligned(_ rect: NSRect, in context: CGContext) -> NSRect {
        let device = context.convertToDeviceSpace(rect).standardized
        var minX = device.minX.rounded(), maxX = device.maxX.rounded()
        var minY = device.minY.rounded(), maxY = device.maxY.rounded()
        // Thinner than a pixel after rounding: the pixel holding its centre.
        if maxX - minX < 1 { minX = device.midX.rounded(.down); maxX = minX + 1 }
        if maxY - minY < 1 { minY = device.midY.rounded(.down); maxY = minY + 1 }
        return context.convertToUserSpace(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}
