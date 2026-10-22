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
        // A whole table copies as 1.12 did: the cells' rendered characters
        // (no `**`). The characters do not depend on the theme, so any will do.
        var cellRenderer: MarkdownRenderer?
        func renderedCell(_ markdown: String) -> String {
            let renderer = cellRenderer ?? MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
            cellRenderer = renderer
            return String(renderer.renderInline(markdown).characters)
        }

        for row in span where row < blocks.count {
            let block = blocks[row]
            switch block.content {
            case .table(let headers, let rows, _):
                guard let built = table(block),
                      let covered = selection.range(inRow: row, rowLength: built.string.length),
                      let piece = tablePiece(built, covered: covered, whole: {
                          // Same rule as `TableTextLayout.showsHeader`: an all-blank
                          // header row is not shown, so it is not copied either.
                          let showsHeader = headers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                          return .table(headers: showsHeader ? headers.map(renderedCell) : nil,
                                        rows: rows.map { $0.map(renderedCell) })
                      }) else { continue }
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
    /// - every cell's text covered (a drag through the table, ⌘A) → `whole()`,
    ///   which is 1.12's TSV;
    /// - inside ONE cell → that text, as a text row copies (fonts, links), but
    ///   without the cell's `NSTextTableBlock` — pasted RTF must not turn a
    ///   word into a one-cell table;
    /// - across cells → `.tableCells`: the covered cells in reading order, a
    ///   partial first / last cell with only its covered part.
    ///
    /// A cell counts as covered when the selection covers any of it, except a
    /// selection that only STARTS on a cell's terminating "\n" (it began after
    /// that cell's text: a press right of the text, or in an empty cell).
    /// That keeps start and end symmetric — the empty cell a drag starts or
    /// ends in is not copied, empty cells it crosses are (as empty fields).
    /// Cells come from `TableTextLayout`, never from re-reading the string.
    static func tablePiece(_ table: TableText, covered: NSRange,
                           whole: () -> SelectionPiece) -> SelectionPiece? {
        let layout = table.layout
        let end = NSMaxRange(covered)
        guard covered.length > 0, covered.location >= 0, layout.length == table.string.length,
              end <= layout.length, let lastCell = layout.cellRanges.last?.last else { return nil }
        if covered.location == 0 && end >= NSMaxRange(lastCell) { return whole() }

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
            return .text(withoutTextBlocks(table.string.attributedSubstring(from: range)))
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

    /// `text` with every paragraph style's text blocks removed (alignment,
    /// spacing and the rest kept).
    private static func withoutTextBlocks(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty,
                  let plain = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            plain.textBlocks = []
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
    static func sourceEditHint(for selection: DocumentSelection?, blocks: [MarkdownBlock],
                               maxRows: Int, maxLength: Int, contextLength: Int,
                               text: (MarkdownBlock) -> NSAttributedString?,
                               table: (MarkdownBlock) -> TableText?,
                               output: () -> String?)
        -> (text: String, before: String, after: String, rows: ClosedRange<Int>)? {
        guard let selection, let span = selection.rowSpan, span.count <= maxRows,
              span.upperBound < blocks.count else { return nil }
        var covered = 0
        var before = ""
        var after = ""
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
        }
        guard covered > 0, let plain = output() else { return nil }
        return (plain, before, after, span)
    }

    /// The text range (without its "\n") of the cell holding `index`.
    private static func cellText(at index: Int, in layout: TableTextLayout) -> NSRange? {
        layout.cell(containing: index).map { layout.cellRanges[$0.band][$0.column] }
    }
}

// MARK: - Points in a text view (S-D6 / TS-D6 / TS-D7)

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
    /// `insertion` is the row's own hit-test answer for the same press (the
    /// TS-D6 hook, `SelfSizingTextView.selectionCharacterIndex`). The glyph
    /// under the point is used when it agrees with it (it is one side of that
    /// insertion point) — always the case on a text line. When they disagree,
    /// TextKit's "nearest glyph" went somewhere the hook would not: in a
    /// table cell's padding, or below a short cell in a tall band, that is a
    /// NEIGHBOURING cell, so the hook wins.
    ///
    /// `inTableCell`: a press in the empty part of a cell (right of a short
    /// text — most of a wide cell) lands on the cell's terminating "\n",
    /// which a word selection would select alone. It is moved back onto the
    /// cell's last character, so the double-click is about the cell's last
    /// word. (Text rows keep TextKit's answer, as before v1.13.) An empty
    /// cell has nothing else: its "\n" stays (the triple-click still selects
    /// the cell).
    func multiClickCharacterIndex(at local: NSPoint, insertion: Int, inTableCell: Bool) -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let string = storage.string as NSString
        var index: Int
        if let glyph = selectionGlyphCharacterIndex(at: local, requireInside: false),
           glyph == insertion || glyph == insertion - 1 {
            index = glyph
        } else {
            index = min(max(insertion, 0), string.length - 1)
        }
        guard inTableCell else { return index }
        func isLineBreak(_ index: Int) -> Bool {
            let unit = string.character(at: index)
            return unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
        }
        if index > 0, isLineBreak(index), !isLineBreak(index - 1) { index -= 1 }
        return index
    }
}
