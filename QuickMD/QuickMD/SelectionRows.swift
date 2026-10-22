import Foundation
import AppKit

// MARK: - What the document selection covers, row by row
//
// `SelectionController` (VirtualBlockList.swift) owns the selection, the views
// and the gestures; what a selection MEANS for each row — the pieces a copy is
// built from (S-D8, v1.13 TS-D8) and Source Edit's hint (S-D14b, TS-D10) — is
// decided here, from the blocks and their selectable strings alone, so it works
// for rows that were never materialized and is unit-tested directly. Compiled
// into the app AND the test target (no view code).

enum SelectionRows {

    /// Rows selected whole, with no text of their own to select (S-D3). A
    /// table is NOT one since v1.13 (TS-D5): it is one text view over its
    /// cells, its selectable string is `TableTextBuilder`'s.
    static func isAtomic(_ block: MarkdownBlock) -> Bool {
        switch block.content {
        case .image, .svgImage, .mathBlock, .mermaidDiagram: return true
        case .text, .codeBlock, .blockquote, .alert, .heading, .table: return false
        }
    }

    // MARK: Copy (S-D8 / TS-D8)

    /// The copy pieces of `selection`, in document order.
    ///
    /// `text` answers the selectable string of a text row (S-D2) and `table`
    /// a table row's string plus its cell layout — the SAME string the row's
    /// view shows, so the selection's offsets index the right characters.
    static func pieces(of selection: DocumentSelection, blocks: [MarkdownBlock],
                       text: (MarkdownBlock) -> NSAttributedString?,
                       table: (MarkdownBlock) -> TableText?) -> [SelectionPiece] {
        guard let span = selection.rowSpan else { return [] }
        var pieces: [SelectionPiece] = []
        pieces.reserveCapacity(span.count)

        for row in span where row < blocks.count {
            let block = blocks[row]
            switch block.content {
            case .table:
                guard let built = table(block),
                      let covered = selection.range(inRow: row, rowLength: built.string.length),
                      let piece = tablePiece(built, covered: covered) else { continue }
                pieces.append(piece)
            case .image(_, let alt, _):
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.image(alt: alt))
            case .svgImage:
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.image(alt: ""))
            case .mathBlock(let latex):
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.displayMath(latex: latex))
            case .mermaidDiagram(let source):
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.mermaid(source: source))
            case .codeBlock, .text, .blockquote, .alert, .heading:
                guard let string = text(block),
                      let covered = selection.range(inRow: row, rowLength: string.length) else { continue }
                let part = string.attributedSubstring(from: covered)
                if case .codeBlock = block.content {
                    pieces.append(.code(part))
                } else {
                    pieces.append(.text(part))
                }
            }
        }
        return pieces
    }

    /// The piece for the `covered` part of a table's string (TS-D8):
    /// - every cell's text covered (a drag through the table, ⌘A) → `.table`,
    ///   1.12's TSV, read from the string's own cells (`wholeTable`);
    /// - inside ONE cell → that text, as a text row copies (fonts, links), but
    ///   without the cell's `NSTextTableBlock` and the column's alignment —
    ///   pasted RTF must not turn a word into a one-cell table, nor into a
    ///   right-aligned or centred paragraph;
    /// - across cells → `.tableCells`: the covered cells in reading order, a
    ///   partial first / last cell with only its covered part.
    ///
    /// A cell counts as covered when the selection covers any of it, except a
    /// selection that only STARTS on a cell's terminating "\n" (it began after
    /// that cell's text: a press right of the text, or in an empty cell).
    /// That keeps start and end symmetric — the empty cell a drag starts or
    /// ends in is not copied, empty cells it crosses are (as empty fields).
    /// Cells come from `TableTextLayout`, never from re-reading the string.
    static func tablePiece(_ table: TableText, covered: NSRange) -> SelectionPiece? {
        let layout = table.layout
        let end = NSMaxRange(covered)
        guard covered.length > 0, covered.location >= 0, layout.length == table.string.length,
              end <= layout.length, let lastCell = layout.cellRanges.last?.last else { return nil }
        if covered.location == 0 && end >= NSMaxRange(lastCell) { return wholeTable(table) }

        var start = covered.location
        if let cell = layout.cell(containing: start),
           start == NSMaxRange(layout.cellRanges[cell.band][cell.column]) {
            start += 1
        }
        guard start < end, let first = layout.cell(containing: start),
              let last = layout.cell(containing: end - 1) else { return nil }
        func coveredText(_ band: Int, _ column: Int) -> NSRange {
            let cell = layout.cellRanges[band][column]
            let lower = max(cell.location, start)
            let upper = min(NSMaxRange(cell), end)
            return NSRange(location: lower, length: max(0, upper - lower))
        }

        if first.band == last.band && first.column == last.column {
            let range = coveredText(first.band, first.column)
            guard range.length > 0 else { return nil }
            return .text(withoutCellLayout(table.string.attributedSubstring(from: range)))
        }
        let string = table.string.string as NSString
        var bands: [[String]] = []
        for band in first.band...last.band {
            let lower = band == first.band ? first.column : 0
            let upper = band == last.band ? last.column : layout.columnCount - 1
            bands.append((lower...upper).map { string.substring(with: coveredText(band, $0)) })
        }
        return .tableCells(bands: bands)
    }

    /// The whole table as 1.12 copied it: header (only when the table shows
    /// one) and rows, each cell's RENDERED text. Read from the table's own
    /// string and layout — the cells `TableTextBuilder` rendered once for the
    /// view, the measurer and search — rather than rendering every cell
    /// again (1.12 did, on the main thread: a second `renderInline` per cell
    /// for ⌘A ⌘C). Bands are already padded to `columnCount`, which is what
    /// 1.12's `tsv` padded to (the parser normalizes every row to it).
    private static func wholeTable(_ table: TableText) -> SelectionPiece {
        let layout = table.layout
        let string = table.string.string as NSString
        let bands = layout.cellRanges.map { $0.map(string.substring(with:)) }
        guard layout.showsHeader, let header = bands.first else { return .table(headers: nil, rows: bands) }
        return .table(headers: header, rows: Array(bands.dropFirst()))
    }

    /// `text` with what belongs to the TABLE removed from its paragraph
    /// styles: the text blocks (the cell) and the alignment (the column's,
    /// from the separator row — back to natural). The rest is kept.
    private static func withoutCellLayout(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  !style.textBlocks.isEmpty || style.alignment != .natural,
                  let plain = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            plain.textBlocks = []
            plain.alignment = .natural
            result.addAttribute(.paragraphStyle, value: plain, range: range)
        }
        return result
    }

    // MARK: Source Edit hint (S-D14b / TS-D10)

    /// Source Edit's carry-over: the selection's plain text (`output`, as ⌘C
    /// copies it) plus up to `contextLength` rendered characters before it in
    /// its first row and after it in its last. Nil — and NOTHING built — when
    /// the selection spans more than `maxRows` rows, touches an atomic row (an
    /// image or a diagram cannot match the source literally) or covers more
    /// than `maxLength` UTF-16 units: the checks only measure the rows'
    /// selectable strings, `output` is asked after them.
    ///
    /// A table row takes part like a text row (TS-D10), so the hint's lines
    /// start at the table's `sourceLine`: a word selected in a cell is found
    /// in the table's source line, and a cross-cell selection (TSV, which
    /// never matches literally) still opens the editor at the table. Its
    /// context stops at the CELL's edges — the "\n" between two rendered
    /// cells is a `|` in the source and would end the agreement anyway.
    ///
    /// `lines`: nil = the rows' own lines (`DocumentReadingPosition
    /// .selectionHint` derives them from `rows`). A selection inside ONE band
    /// of a table names that band's source line instead: a whole-cell
    /// selection has no context, and the first literal match in the table's
    /// lines can be another row's cell — `| 10 | a |` above `| 1 | b |`, the
    /// "1" of "10" (`sourceLine(ofBand:in:tableLine:)`).
    static func sourceEditHint(for selection: DocumentSelection?, blocks: [MarkdownBlock],
                               maxRows: Int, maxLength: Int, contextLength: Int,
                               text: (MarkdownBlock) -> NSAttributedString?,
                               table: (MarkdownBlock) -> TableText?,
                               output: () -> String?)
        -> (text: String, before: String, after: String, rows: ClosedRange<Int>, lines: Range<Int>?)? {
        guard let selection, let span = selection.rowSpan, span.count <= maxRows,
              span.upperBound < blocks.count else { return nil }
        var covered = 0
        var before = ""
        var after = ""
        var lines: Range<Int>?
        for row in span {
            let block = blocks[row]
            let string: NSAttributedString
            var layout: TableTextLayout?
            switch block.content {
            case .codeBlock, .text, .blockquote, .alert, .heading:
                guard let rowText = text(block) else { return nil }
                string = rowText
            case .table:
                guard let built = table(block) else { return nil }
                string = built.string
                layout = built.layout
            case .image, .svgImage, .mathBlock, .mermaidDiagram:
                return nil
            }
            guard let range = selection.range(inRow: row, rowLength: string.length) else { continue }
            covered += range.length
            guard covered <= maxLength else { return nil }
            let ns = string.string as NSString
            if row == span.lowerBound {
                let floor = layout.flatMap { cellText(at: range.location, in: $0) }?.location ?? 0
                let start = max(floor, range.location - contextLength)
                before = ns.substring(with: NSRange(location: start, length: max(0, range.location - start)))
            }
            if row == span.upperBound {
                let end = NSMaxRange(range)
                let ceiling = layout.flatMap { cellText(at: end - 1, in: $0) }.map(NSMaxRange) ?? ns.length
                let stop = min(ceiling, end + contextLength)
                after = ns.substring(with: NSRange(location: end, length: max(0, stop - end)))
            }
            if span.count == 1, let layout,
               let first = layout.cell(containing: range.location)?.band,
               let last = layout.cell(containing: NSMaxRange(range) - 1)?.band, first == last {
                let line = sourceLine(ofBand: first, in: layout, tableLine: block.sourceLine)
                lines = line..<(line + 1)
            }
        }
        guard covered > 0, let plain = output() else { return nil }
        return (plain, before, after, span, lines)
    }

    /// The 0-based source line of `band`, from the table's `sourceLine` (its
    /// header line). `MarkdownBlockParser` reads a table as the header line,
    /// the separator line, then one line per row — and keeps the header line
    /// even when it is blank (`| | |`, a headerless table: no header band, so
    /// band 0 is the first row, two lines down).
    static func sourceLine(ofBand band: Int, in layout: TableTextLayout, tableLine: Int) -> Int {
        guard layout.showsHeader else { return tableLine + 2 + band }
        return band == 0 ? tableLine : tableLine + 1 + band
    }

    /// The text range (without its "\n") of the cell holding `index`.
    private static func cellText(at index: Int, in layout: TableTextLayout) -> NSRange? {
        layout.cell(containing: index).map { layout.cellRanges[$0.band][$0.column] }
    }
}

// MARK: - Points in a text view (S-D6 / TS-D6 / TS-D7)

extension SelectionRows {
    /// The selection offset for `local` (the row's text-view coordinates,
    /// flipped) — `SelectionController.hit` for a row with a registered view.
    /// `characterIndex` is the view's hit-test hook
    /// (`SelfSizingTextView.selectionCharacterIndex`).
    ///
    /// A text row: above its view = the row's start, below = its end (the
    /// gap and the chrome around the text belong to the row's edges), beside
    /// it = the line's start or end. A TABLE (`isTable`) clamps the point into
    /// the view and asks the hook in every direction, which snaps it to the
    /// nearest band and cell (TS-D6): a drag along the header that slips a
    /// few points above the table must stay in the header cells, not jump to
    /// the start of the table; below the last band likewise.
    static func hitOffset(at local: NSPoint, viewSize: NSSize, length: Int, isTable: Bool,
                          characterIndex: (NSPoint) -> Int) -> Int {
        if !isTable {
            if local.y < 0 { return 0 }
            if local.y > viewSize.height { return length }
        }
        let clamped = NSPoint(x: min(max(local.x, 0), viewSize.width),
                              y: min(max(local.y, 0), viewSize.height))
        return min(max(0, characterIndex(clamped)), length)
    }
}

extension NSTextView {
    /// The character whose glyph is under `local` (view coordinates), or nil
    /// past the end. With `requireInside`, only when the point is ON the
    /// glyph — a click in the empty space after a link must not open it.
    func selectionGlyphCharacterIndex(at local: NSPoint, requireInside: Bool) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let point = NSPoint(x: local.x - origin.x, y: local.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        if requireInside {
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                                 in: textContainer)
            guard box.contains(point) else { return nil }
        }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    /// The character a double- or triple-click at `local` is about (TS-D7) —
    /// what `selectionRange(forProposedRange:granularity:)` expands to a word
    /// or a paragraph (in a table: the cell).
    ///
    /// A text row (`inTableCell == false`) gets exactly what it got before
    /// v1.13: the glyph TextKit finds nearest to the point — on a multi-unit
    /// glyph (emoji, ZWJ sequence, ligature) on either half, and above/below
    /// the text the word under the pointer's x.
    ///
    /// In a table cell, TextKit's "nearest glyph" can be in a NEIGHBOURING
    /// cell (a press in a cell's padding, or under a short cell in a tall
    /// band). `insertion` is the row's own hit-test answer for the same press
    /// (the TS-D6 hook, `SelfSizingTextView.selectionCharacterIndex`, confined
    /// to the cell under the point): the glyph is used when the insertion
    /// point is on one of its edges — compared against the glyph's whole
    /// composed character sequence, so the right half of an emoji still
    /// agrees — and otherwise the hook wins. A press in the empty part of a
    /// cell (right of a short text — most of a wide cell) lands on the cell's
    /// terminating "\n", which a word selection would select alone, so it is
    /// moved back onto the cell's last character: the double-click is about
    /// the cell's last word. An empty cell has nothing else: its "\n" stays
    /// (the triple-click still selects the cell).
    func multiClickCharacterIndex(at local: NSPoint, insertion: Int, inTableCell: Bool) -> Int? {
        let glyph = selectionGlyphCharacterIndex(at: local, requireInside: false)
        guard inTableCell else { return glyph }
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let string = storage.string as NSString
        var index: Int
        if let glyph, glyph < string.length,
           case let composed = string.rangeOfComposedCharacterSequence(at: glyph),
           insertion >= composed.location, insertion <= NSMaxRange(composed) {
            index = glyph
        } else {
            index = min(max(insertion, 0), string.length - 1)
        }
        func isLineBreak(_ index: Int) -> Bool {
            let unit = string.character(at: index)
            return unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
        }
        if index > 0, isLineBreak(index), !isLineBreak(index - 1) { index -= 1 }
        return index
    }
}
