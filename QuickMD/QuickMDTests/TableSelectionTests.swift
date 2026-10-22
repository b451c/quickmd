import XCTest
import SwiftUI
import AppKit

/// v1.13 TS-T2: text inside tables joins the document selection.
///
/// A table row is a text row now (TS-D5): its selectable string is
/// `TableTextBuilder`'s (one paragraph per cell), so what is pinned here is
/// what a covered range of that string MEANS — the copy (TS-D8), the Source
/// Edit hint (TS-D10) — and how a press inside a cell becomes the word or the
/// cell a double/triple click selects (TS-D6/TS-D7), on a real text view laid
/// out as `TableTextView` is. `SelectionController` itself lives with the
/// views (not compiled into this target); everything it decides about rows
/// goes through `SelectionRows`, tested here.
final class TableSelectionTests: XCTestCase {

    private var theme: MarkdownTheme { MarkdownTheme.cached(for: .light) }

    /// "Name\nValue\nalpha one\n1\nbeta\ntwo words\n\ngamma\n"
    private static let tableMarkdown = """
    | Name | Value |
    |------|-------|
    | alpha one | 1 |
    | beta | two words |
    |  | gamma |
    """

    private static let documentMarkdown = """
    Intro paragraph.

    \(tableMarkdown)

    Outro.
    """

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: theme).parse(markdown)
    }

    /// The selectable string of a text row, as `MarkdownView.selectableText`
    /// builds it for `.text` (no inline math here).
    private func text(_ block: MarkdownBlock) -> NSAttributedString? {
        guard case .text(let attributed) = block.content else { return nil }
        return BlockTextConverter.makeNSAttributedString(from: attributed, hasInlineMath: false,
                                                         theme: theme, fontScale: 1, math: .none)
    }

    private func table(_ block: MarkdownBlock) -> TableText? {
        guard case .table(let headers, let rows, let alignments) = block.content else { return nil }
        return TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments,
                                      theme: theme, fontScale: 1)
    }

    private func tableBlock(_ markdown: String = tableMarkdown) -> (block: MarkdownBlock, text: TableText) {
        let block = parse(markdown).first { if case .table = $0.content { return true } else { return false } }!
        return (block, table(block)!)
    }

    /// 1.12's whole-table copy for `block` (what `SelectionRows.pieces` hands
    /// `tablePiece` as `whole`).
    private func wholeTablePiece(_ block: MarkdownBlock) -> SelectionPiece {
        guard case .table(let headers, let rows, _) = block.content else { fatalError("not a table") }
        let renderer = MarkdownRenderer(theme: theme)
        func rendered(_ cell: String) -> String { String(renderer.renderInline(cell).characters) }
        return .table(headers: headers.map(rendered), rows: rows.map { $0.map(rendered) })
    }

    /// The copy of `covered` in the fixture table.
    private func copy(_ covered: NSRange, of fixture: (block: MarkdownBlock, text: TableText)? = nil) -> DocumentCopyOutput? {
        let fixture = fixture ?? tableBlock()
        guard let piece = SelectionRows.tablePiece(fixture.text, covered: covered,
                                                   whole: { wholeTablePiece(fixture.block) }) else { return nil }
        return DocumentCopyBuilder.build([piece])
    }

    /// `length` characters of cell (band, column), from `offset` into it.
    private func cellRange(_ layout: TableTextLayout, _ band: Int, _ column: Int,
                           from offset: Int = 0, length: Int? = nil) -> NSRange {
        let cell = layout.cellRanges[band][column]
        return NSRange(location: cell.location + offset, length: length ?? (cell.length - offset))
    }

    /// From (band, column, offset) to (band, column, offset), as a range.
    private func span(_ layout: TableTextLayout, from a: (Int, Int, Int), to b: (Int, Int, Int)) -> NSRange {
        let start = layout.cellRanges[a.0][a.1].location + a.2
        let end = layout.cellRanges[b.0][b.1].location + b.2
        return NSRange(location: start, length: end - start)
    }

    // MARK: - TS-D5

    func testTablesAreTextRowsNow() {
        let blocks = parse(Self.documentMarkdown + "\n\n![alt](x.png)\n\n$$\nx\n$$\n")
        let kinds = blocks.map { block -> String in
            switch block.content {
            case .table: return "table"
            case .image: return "image"
            case .mathBlock: return "math"
            default: return "text"
            }
        }
        XCTAssertTrue(kinds.contains("table"))
        for block in blocks {
            switch block.content {
            case .table, .text: XCTAssertFalse(SelectionRows.isAtomic(block))
            case .image, .mathBlock: XCTAssertTrue(SelectionRows.isAtomic(block))
            default: break
            }
        }
    }

    // MARK: - TS-D8 copy

    func testInsideOneCellCopiesTheCoveredText() {
        let fixture = tableBlock()
        let layout = fixture.text.layout
        // "one" of "alpha one"
        let output = copy(cellRange(layout, 1, 0, from: 6), of: fixture)
        XCTAssertEqual(output?.plain, "one")
        // A whole cell, as a triple-click selects it (its "\n" included).
        let cell = layout.cellRanges[2][1]
        XCTAssertEqual(copy(NSRange(location: cell.location, length: cell.length + 1))?.plain, "two words")
    }

    func testOneCellRTFHasNoThemeColourAndNoTextTable() throws {
        let fixture = tableBlock("""
        | Name | Value |
        |------|-------|
        | see [docs](https://example.com) **now** | 1 |
        """)
        let layout = fixture.text.layout
        let output = try XCTUnwrap(copy(layout.cellRanges[1][0], of: fixture))
        XCTAssertEqual(output.plain, "see docs now")
        let rtf = output.rtf
        let full = NSRange(location: 0, length: rtf.length)
        var sawLink = false
        rtf.enumerateAttributes(in: full) { attributes, range, _ in
            XCTAssertNil(attributes[.foregroundColor], "colour at \(range)")
            XCTAssertNil(attributes[.backgroundColor], "background at \(range)")
            XCTAssertNotNil(attributes[.font], "font at \(range)")
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                XCTAssertTrue(style.textBlocks.isEmpty, "text table block at \(range)")
            }
            if attributes[.link] != nil { sawLink = true }
        }
        XCTAssertTrue(sawLink, "links are kept, as for text rows")
        // The pasteboard's RTF of one cell is not a table either.
        let data = try XCTUnwrap(rtf.rtf(from: full, documentAttributes: [:]))
        let rtfSource = try XCTUnwrap(String(data: data, encoding: .ascii))
        XCTAssertFalse(rtfSource.contains("\\trowd"), rtfSource)
    }

    func testAcrossCellsOfOneBandIsTabSeparated() {
        let layout = tableBlock().text.layout
        // "ta" of "beta" … "two" of "two words"
        XCTAssertEqual(copy(span(layout, from: (2, 0, 2), to: (2, 1, 3)))?.plain, "ta\ttwo")
    }

    func testHeaderToRowStartsWithTheCoveredHeaderCells() {
        let layout = tableBlock().text.layout
        // From the table's start into "alpha one".
        XCTAssertEqual(copy(span(layout, from: (0, 0, 0), to: (1, 0, 5)))?.plain, "Name\tValue\nalpha")
    }

    func testPartialFirstAndLastCellAcrossBands() {
        let layout = tableBlock().text.layout
        // "lue" of the header "Value" … "two" of "two words".
        XCTAssertEqual(copy(span(layout, from: (0, 1, 2), to: (2, 1, 3)))?.plain,
                       "lue\nalpha one\t1\nbeta\ttwo")
    }

    func testEmptyCellsCrossedAreFieldsButNotTheOneADragStartsIn() {
        let layout = tableBlock().text.layout
        // Crossing the empty first cell of the last band keeps its field.
        XCTAssertEqual(copy(span(layout, from: (2, 1, 0), to: (3, 1, 3)))?.plain, "two words\n\tgam")
        // A drag that starts IN that empty cell (the hook answers its "\n")
        // and stays in the band copies only what it covered.
        XCTAssertEqual(copy(span(layout, from: (3, 0, 0), to: (3, 1, 3)))?.plain, "gam")
        // A press right of a cell's text (its "\n") into the next cell.
        XCTAssertEqual(copy(span(layout, from: (1, 0, 9), to: (1, 1, 1)))?.plain, "1")
        // Only a "\n" covered: nothing.
        XCTAssertNil(copy(NSRange(location: NSMaxRange(layout.cellRanges[1][0]), length: 1)))
    }

    func testTabsInsideCellsBecomeSpaces() {
        let built = TableTextBuilder.build(headers: ["H1", "H2"], rows: [["a\tb", "c"]], alignments: [],
                                           theme: theme, fontScale: 1)
        let block = MarkdownBlock(id: "table-0", content: .table(headers: ["H1", "H2"], rows: [["a\tb", "c"]],
                                                                 alignments: []), sourceLine: 0)
        let layout = built.layout
        let output = copy(span(layout, from: (1, 0, 0), to: (1, 1, 1)), of: (block, built))
        XCTAssertEqual(output?.plain, "a b\tc")
    }

    func testWholeTableIsExactlyThe112TSV() {
        let fixture = tableBlock()
        let length = fixture.text.string.length
        let expected = "Name\tValue\nalpha one\t1\nbeta\ttwo words\n\tgamma"
        XCTAssertEqual(DocumentCopyBuilder.build([wholeTablePiece(fixture.block)]).plain, expected)
        XCTAssertEqual(copy(NSRange(location: 0, length: length))?.plain, expected)
        // Ending right after the last cell's text (before its "\n") is still every cell.
        XCTAssertEqual(copy(NSRange(location: 0, length: length - 1))?.plain, expected)
    }

    func testHeaderlessTableCopiesWithoutAHeaderLine() {
        let fixture = tableBlock("""
        | | |
        |---|---|
        | a | b |
        | c | d |
        """)
        XCTAssertFalse(fixture.text.layout.showsHeader)
        let whole = SelectionRows.pieces(
            of: DocumentSelection(anchor: SelectionPoint(row: 0, offset: 0),
                                  focus: SelectionPoint(row: 0, offset: fixture.text.string.length)),
            blocks: [fixture.block], text: text, table: table)
        XCTAssertEqual(DocumentCopyBuilder.build(whole).plain, "a\tb\nc\td")
    }

    // MARK: - Mixed selections through `SelectionRows.pieces`

    private func document() -> (blocks: [MarkdownBlock], tableRow: Int) {
        let blocks = parse(Self.documentMarkdown)
        let row = blocks.firstIndex { if case .table = $0.content { return true } else { return false } }!
        return (blocks, row)
    }

    private func output(_ selection: DocumentSelection, _ blocks: [MarkdownBlock]) -> String {
        DocumentCopyBuilder.build(SelectionRows.pieces(of: selection, blocks: blocks,
                                                       text: text, table: table)).plain
    }

    func testParagraphThroughTableToParagraph() {
        let (blocks, row) = document()
        XCTAssertEqual(row, 1)
        let last = blocks.count - 1
        let selection = DocumentSelection(anchor: SelectionPoint(row: 0, offset: 0),
                                          focus: SelectionPoint(row: last, offset: text(blocks[last])!.length))
        XCTAssertEqual(output(selection, blocks),
                       "Intro paragraph.\n\nName\tValue\nalpha one\t1\nbeta\ttwo words\n\tgamma\n\nOutro.")
    }

    func testFromAParagraphAboveIntoACell() {
        let (blocks, row) = document()
        let intro = text(blocks[0])!.string as NSString
        let layout = table(blocks[row])!.layout
        let selection = DocumentSelection(
            anchor: SelectionPoint(row: 0, offset: intro.range(of: "paragraph").location),
            focus: SelectionPoint(row: row, offset: layout.cellRanges[1][0].location + 5))
        XCTAssertEqual(output(selection, blocks), "paragraph.\n\nName\tValue\nalpha")
        // Upwards: same text.
        let upwards = DocumentSelection(anchor: selection.focus, focus: selection.anchor)
        XCTAssertEqual(output(upwards, blocks), "paragraph.\n\nName\tValue\nalpha")
    }

    func testFromACellIntoTheParagraphBelow() {
        let (blocks, row) = document()
        let layout = table(blocks[row])!.layout
        let selection = DocumentSelection(
            anchor: SelectionPoint(row: row, offset: layout.cellRanges[3][1].location + 3),
            focus: SelectionPoint(row: row + 1, offset: text(blocks[row + 1])!.length))
        XCTAssertEqual(output(selection, blocks), "ma\n\nOutro.")
    }

    func testSelectAllOverADocumentWithTables() {
        let blocks = parse(Self.documentMarkdown + "\n\n" + Self.tableMarkdown)
        func length(_ row: Int) -> Int {
            (table(blocks[row])?.string ?? text(blocks[row]))?.length ?? 0
        }
        XCTAssertNotNil(table(blocks[blocks.count - 1]), "the document ends with a table")
        let all = DocumentSelection.selectAll(rowCount: blocks.count, lengths: length)!
        let tsv = "Name\tValue\nalpha one\t1\nbeta\ttwo words\n\tgamma"
        XCTAssertEqual(output(all, blocks), "Intro paragraph.\n\n\(tsv)\n\nOutro.\n\n\(tsv)")
    }

    // MARK: - TS-D10 Source Edit hint

    private func hint(_ selection: DocumentSelection, _ blocks: [MarkdownBlock])
        -> (text: String, before: String, after: String, rows: ClosedRange<Int>, lines: Range<Int>?)? {
        SelectionRows.sourceEditHint(
            for: selection, blocks: blocks,
            maxRows: SourceEditSession.selectionHintMaxRows,
            maxLength: SourceEditSession.selectionHintMaxLength,
            contextLength: SourceEditSession.selectionHintContextLength,
            text: text, table: table,
            output: { DocumentCopyBuilder.build(SelectionRows.pieces(of: selection, blocks: blocks,
                                                                     text: self.text, table: self.table)).plain })
    }

    func testHintInsideACellIsFoundInTheTablesSourceLine() throws {
        let (blocks, row) = document()
        let layout = table(blocks[row])!.layout
        let words = layout.cellRanges[2][1]  // "two words"
        let selection = DocumentSelection(anchor: SelectionPoint(row: row, offset: words.location + 4),
                                          focus: SelectionPoint(row: row, offset: NSMaxRange(words)))
        let h = try XCTUnwrap(hint(selection, blocks))
        XCTAssertEqual(h.text, "words")
        XCTAssertEqual(h.before, "two ", "context stops at the cell's edge")
        XCTAssertEqual(h.after, "")
        XCTAssertEqual(h.rows, row...row)

        let lines = try XCTUnwrap(DocumentReadingPosition.selectionHint(
            text: h.text, before: h.before, after: h.after, rows: h.rows, lines: h.lines, blocks: blocks))
        // Band 2 = the second data row: header, separator, first row, then it.
        XCTAssertEqual(lines.lines, (blocks[row].sourceLine + 3)..<(blocks[row].sourceLine + 4),
                       "the band's own source line")
        let source = Self.documentMarkdown as NSString
        let found = try XCTUnwrap(SourceEditSupport.sourceRange(ofSelection: lines.text, before: lines.before,
                                                                after: lines.after, in: source, lines: lines.lines))
        XCTAssertEqual(source.substring(with: found), "words")
        XCTAssertEqual(source.substring(with: source.lineRange(for: found)), "| beta | two words |\n")
    }

    func testHintAcrossCellsStillPointsAtTheTable() throws {
        let (blocks, row) = document()
        let layout = table(blocks[row])!.layout
        let selection = DocumentSelection(anchor: SelectionPoint(row: row, offset: layout.cellRanges[1][0].location),
                                          focus: SelectionPoint(row: row, offset: layout.cellRanges[2][0].location + 2))
        let h = try XCTUnwrap(hint(selection, blocks))
        XCTAssertEqual(h.text, "alpha one\t1\nbe")
        XCTAssertNil(h.lines, "two bands: the table's lines")
        let lines = try XCTUnwrap(DocumentReadingPosition.selectionHint(text: h.text, rows: h.rows, lines: h.lines,
                                                                        blocks: blocks))
        XCTAssertEqual(lines.lines.lowerBound, blocks[row].sourceLine)
        // A TSV never matches the source literally: the editor falls back to the line.
        XCTAssertNil(SourceEditSupport.sourceRange(ofSelection: lines.text, in: Self.documentMarkdown,
                                                   lines: lines.lines))
    }

    func testHintFromAParagraphIntoATableCoversBothRows() throws {
        let (blocks, row) = document()
        let layout = table(blocks[row])!.layout
        let selection = DocumentSelection(anchor: SelectionPoint(row: 0, offset: 6),
                                          focus: SelectionPoint(row: row, offset: layout.cellRanges[0][0].location + 2))
        let h = try XCTUnwrap(hint(selection, blocks))
        XCTAssertEqual(h.rows, 0...row)
        XCTAssertEqual(h.after, "me", "after-context inside the last cell")
        XCTAssertNil(h.lines, "two rows: their lines")
    }

    /// Where Source Edit selects a WHOLE cell (no context to tell matches
    /// apart) of `markdown`: the source text of the match and its line.
    private func sourceSelection(ofCell band: Int, _ column: Int, in markdown: String)
        throws -> (text: String, line: String) {
        let blocks = parse(markdown)
        let row = try XCTUnwrap(blocks.firstIndex { if case .table = $0.content { return true } else { return false } })
        let cell = table(blocks[row])!.layout.cellRanges[band][column]
        // As a triple-click selects it: the cell and its "\n".
        let selection = DocumentSelection(anchor: SelectionPoint(row: row, offset: cell.location),
                                          focus: SelectionPoint(row: row, offset: NSMaxRange(cell) + 1))
        let h = try XCTUnwrap(hint(selection, blocks))
        let resolved = try XCTUnwrap(DocumentReadingPosition.selectionHint(
            text: h.text, before: h.before, after: h.after, rows: h.rows, lines: h.lines, blocks: blocks))
        let source = markdown as NSString
        let found = try XCTUnwrap(SourceEditSupport.sourceRange(ofSelection: resolved.text, before: resolved.before,
                                                                after: resolved.after, in: source,
                                                                lines: resolved.lines))
        return (source.substring(with: found), source.substring(with: source.lineRange(for: found)))
    }

    /// Repeated values in a column: the selected cell's OWN row, never the
    /// first literal match in the table (the "1" of "10").
    func testWholeCellHintFindsItsOwnRowAmongRepeatedValues() throws {
        let markdown = """
        Intro.

        | Count | Done |
        |------:|:----:|
        | 10 | yes |
        | 1 | yes |
        | 1 | no |
        | 100 | yes |

        After.
        """
        var found = try sourceSelection(ofCell: 2, 0, in: markdown)
        XCTAssertEqual(found.text, "1")
        XCTAssertEqual(found.line, "| 1 | yes |\n")
        found = try sourceSelection(ofCell: 3, 0, in: markdown)
        XCTAssertEqual(found.line, "| 1 | no |\n")
        found = try sourceSelection(ofCell: 4, 1, in: markdown)   // last band
        XCTAssertEqual(found.text, "yes")
        XCTAssertEqual(found.line, "| 100 | yes |\n")
        found = try sourceSelection(ofCell: 0, 1, in: markdown)   // header band
        XCTAssertEqual(found.line, "| Count | Done |\n")
    }

    func testWholeCellHintInAHeaderlessTable() throws {
        let markdown = """
        | | |
        |---|---|
        | 10 | yes |
        | 1 | yes |
        """
        var found = try sourceSelection(ofCell: 0, 1, in: markdown)  // first band = first row
        XCTAssertEqual(found.line, "| 10 | yes |\n")
        found = try sourceSelection(ofCell: 1, 0, in: markdown)      // last band
        XCTAssertEqual(found.text, "1")
        XCTAssertEqual(found.line, "| 1 | yes |")
    }

    func testBandSourceLines() {
        let header = TableTextBuilder.build(headers: ["A"], rows: [["1"], ["2"]], alignments: [],
                                            theme: theme, fontScale: 1).layout
        XCTAssertEqual((0..<3).map { SelectionRows.sourceLine(ofBand: $0, in: header, tableLine: 7) }, [7, 9, 10])
        let headerless = TableTextBuilder.build(headers: [""], rows: [["1"], ["2"]], alignments: [],
                                                theme: theme, fontScale: 1).layout
        XCTAssertEqual((0..<2).map { SelectionRows.sourceLine(ofBand: $0, in: headerless, tableLine: 7) }, [9, 10])
    }

    /// A word copied from a right-aligned or centred column pastes as an
    /// ordinary (natural) paragraph.
    func testOneCellCopyDropsTheColumnAlignment() throws {
        let fixture = tableBlock("""
        | Left | Centre | Right |
        |:-----|:------:|------:|
        | a | b | c |
        """)
        let layout = fixture.text.layout
        for column in 0..<3 {
            let source = fixture.text.string.attribute(.paragraphStyle, at: layout.cellRanges[1][column].location,
                                                       effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(source?.alignment, [NSTextAlignment.left, .center, .right][column], "fixture")
            let output = try XCTUnwrap(copy(layout.cellRanges[1][column], of: fixture))
            output.rtf.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: output.rtf.length)) { value, _, _ in
                guard let style = value as? NSParagraphStyle else { return }
                XCTAssertEqual(style.alignment, .natural, "column \(column)")
                XCTAssertTrue(style.textBlocks.isEmpty, "column \(column)")
            }
        }
    }

    // MARK: - TS-D6 / TS-D7 on a real text view

    /// A text view set up as `TableTextView` (`configureForSelfSizing` +
    /// `installDocumentSelectionLayoutManager`) holding `table`, laid out at
    /// `width` through its display container.
    private func liveTextView(_ string: NSAttributedString, width: CGFloat) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.textStorage?.setAttributedString(string)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    private static let multiClickFixtures = [tableMarkdown, """
    | Feature | Description | Status |
    |:--------|:-----------:|-------:|
    | **Search** | Finds every occurrence across the document, including text inside tables, and highlights the focused one | `done` |
    | Links | See [the docs](https://example.com/docs) for the full list | **beta** |
    """]

    /// A double- / triple-click anywhere in a cell — its text, its padding
    /// corners, the empty space under a short cell in a tall band — selects
    /// a word of THAT cell / that cell exactly, never a neighbour and never
    /// the whole table. The press goes through the same path as in the app:
    /// the hook's insertion index (`characterIndex(confinedToCellAt:)`, what
    /// `TableTextView.selectionCharacterIndex` returns), then
    /// `multiClickCharacterIndex`, then TextKit's granularity.
    func testMultiClickSelectsAWordOfTheCellAndTheCellUnderThePress() {
        var probed = 0
        for markdown in Self.multiClickFixtures {
            for width in [CGFloat(400), 700] {
                let built = tableBlock(markdown).text
                let layout = built.layout
                let textView = liveTextView(built.string, width: width)
                for band in 0..<layout.bandCount {
                    for column in 0..<layout.columnCount {
                        guard let rect = textView.tableCellBounds(band: band, column: column, layout: layout) else {
                            XCTFail("no bounds for (\(band),\(column))")
                            continue
                        }
                        let cell = layout.cellRanges[band][column]
                        let paragraph = NSRange(location: cell.location, length: cell.length + 1)
                        let probes: [(String, NSPoint)] = [
                            ("centre", NSPoint(x: rect.midX, y: rect.midY)),
                            ("topLeftPadding", NSPoint(x: rect.minX + 2, y: rect.minY + 2)),
                            ("bottomRightPadding", NSPoint(x: rect.maxX - 3, y: rect.maxY - 3)),
                            ("bottomLeftPadding", NSPoint(x: rect.minX + 2, y: rect.maxY - 3)),
                        ]
                        for (label, point) in probes {
                            let tag = "w\(Int(width)) (\(band),\(column)) \(label)"
                            let insertion = textView.characterIndex(confinedToCellAt: point, layout: layout)
                            guard let index = textView.multiClickCharacterIndex(at: point, insertion: insertion,
                                                                                  inTableCell: true) else {
                                XCTFail("no index \(tag)")
                                continue
                            }
                            XCTAssertTrue(NSLocationInRange(index, paragraph), "\(tag): \(index) not in \(paragraph)")
                            let triple = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                                                 granularity: .selectByParagraph)
                            XCTAssertEqual(triple, paragraph, tag)
                            let word = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                                               granularity: .selectByWord)
                            XCTAssertTrue(word.length > 0 && NSMaxRange(word) <= NSMaxRange(paragraph)
                                          && word.location >= paragraph.location, "\(tag): word \(word)")
                            if cell.length > 0 {
                                XCTAssertTrue(NSMaxRange(word) <= NSMaxRange(cell), "\(tag): word \(word) is the \\n")
                            }
                            probed += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(probed, 100)
    }

    /// On ordinary text the glyph under the pointer is what a double-click is
    /// about, exactly as before tables joined the selection.
    func testMultiClickOnTextIsTheGlyphUnderThePointer() {
        let string = NSAttributedString(string: "Hello wonderful world, again and again.",
                                        attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let textView = liveTextView(string, width: 600)
        let layoutManager = textView.layoutManager!
        for index in [0, 3, 6, 10, 15, 16, 22, 30] {
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                                 in: textView.textContainer!)
            for x in [box.minX + 1, box.maxX - 1] {
                let point = NSPoint(x: x + textView.textContainerOrigin.x, y: box.midY + textView.textContainerOrigin.y)
                let insertion = textView.characterIndexForInsertion(at: point)
                XCTAssertEqual(textView.multiClickCharacterIndex(at: point, insertion: insertion, inTableCell: false), index,
                               "index \(index) x \(x)")
            }
        }
    }

    /// The point at the left or right edge (`fraction` 0.1 / 0.9) of the glyph
    /// that shows character `index`, in view coordinates.
    private func point(onGlyphOf index: Int, fraction: CGFloat, in textView: NSTextView,
                       dy: CGFloat = 0) -> NSPoint {
        let layoutManager = textView.layoutManager!
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                             in: textView.textContainer!)
        let origin = textView.textContainerOrigin
        return NSPoint(x: origin.x + box.minX + box.width * fraction, y: origin.y + box.midY + dy)
    }

    private func word(at index: Int, in textView: NSTextView) -> String {
        let range = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                            granularity: .selectByWord)
        return (textView.string as NSString).substring(with: range)
    }

    /// A double-click on a glyph made of several UTF-16 units (emoji, a ZWJ
    /// sequence) or of several characters (a ligature) is about THAT glyph on
    /// either half — the insertion point after it is several units away from
    /// the glyph's first character. (7fc791f compared them unit by unit and
    /// selected the space after the emoji.)
    func testMultiClickOnAMultiUnitGlyphOfATextRowIsThatGlyph() {
        let font = NSFont.systemFont(ofSize: 18)
        let cases: [(text: String, target: String)] = [
            ("hi \u{1F600} there", "\u{1F600}"),
            ("a \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} family", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
            ("an office", "office"),
        ]
        for (text, target) in cases {
            let textView = liveTextView(NSAttributedString(string: text, attributes: [.font: font]), width: 600)
            let location = (text as NSString).range(of: target).location
            for fraction in [CGFloat(0.1), 0.9] {
                let point = point(onGlyphOf: location, fraction: fraction, in: textView)
                let insertion = textView.characterIndexForInsertion(at: point)
                let index = textView.multiClickCharacterIndex(at: point, insertion: insertion, inTableCell: false)
                XCTAssertEqual(index, textView.selectionGlyphCharacterIndex(at: point, requireInside: false),
                               "\(text) @\(fraction): the glyph under the pointer")
                XCTAssertEqual(index.map { word(at: $0, in: textView) }, target, "\(text) @\(fraction)")
            }
        }
    }

    /// Above or below a text row's text (in its view's inset) a double-click
    /// is about what it was about before v1.13: TextKit's nearest glyph —
    /// measured, the text's first / last character, so the first / last word,
    /// not the word under the pointer's x.
    func testMultiClickInATextRowsPaddingKeepsThePreTablesAnswer() {
        let text = "first second third\nfourth fifth sixth"
        let textView = liveTextView(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]),
                                    width: 600)
        textView.textContainerInset = NSSize(width: 0, height: 12)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager!.usedRect(for: textView.textContainer!)
        let ns = text as NSString
        let x = point(onGlyphOf: ns.range(of: "second").location + 2, fraction: 0.5, in: textView).x
        let probes: [(NSPoint, String)] = [
            (NSPoint(x: x, y: 4), "first"),                                           // in the top inset
            (NSPoint(x: x, y: textView.textContainerOrigin.y + used.maxY + 4), "sixth"),  // below the text
        ]
        for (point, expected) in probes {
            let insertion = textView.characterIndexForInsertion(at: point)
            let glyph = textView.selectionGlyphCharacterIndex(at: point, requireInside: false)
            let index = textView.multiClickCharacterIndex(at: point, insertion: insertion, inTableCell: false)
            XCTAssertEqual(index, glyph, "y \(point.y): the pre-v1.13 rule")
            XCTAssertEqual(index.map { word(at: $0, in: textView) }, expected, "y \(point.y)")
        }
    }

    /// The same multi-unit glyph inside a table CELL: the cell rule still
    /// accepts the glyph (its composed range contains the insertion point).
    func testMultiClickOnAnEmojiInATableCell() throws {
        let fixture = tableBlock("""
        | A | B |
        |---|---|
        | hi \u{1F600} there | x |
        """)
        let layout = fixture.text.layout
        let textView = liveTextView(fixture.text.string, width: 700)
        let location = (fixture.text.string.string as NSString).range(of: "\u{1F600}").location
        for fraction in [CGFloat(0.1), 0.9] {
            let point = point(onGlyphOf: location, fraction: fraction, in: textView)
            let insertion = textView.characterIndex(confinedToCellAt: point, layout: layout)
            let index = try XCTUnwrap(textView.multiClickCharacterIndex(at: point, insertion: insertion,
                                                                        inTableCell: true))
            XCTAssertEqual(word(at: index, in: textView), "\u{1F600}", "@\(fraction)")
        }
    }
}
