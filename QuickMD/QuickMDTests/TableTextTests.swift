import XCTest
import SwiftUI
import AppKit

/// v1.13 TS-T1: a table is one NSTextView over a TextKit 1 `NSTextTable`.
///
/// Two things are pinned here:
/// 1. The string layout (TS-D4) — the row's selectable string, so its offsets
///    are what the document selection, copy and search index into: header band
///    first (only when shown), then rows, left to right; one paragraph per
///    cell; ragged rows padded; `cellRanges` / `bandRange` / `cell(containing:)`.
/// 2. Parity (TS-D3) — the row is `.exact`, so the measurer's height must be
///    the height the table really takes in a text view configured as
///    `TableTextView` is (`configureForSelfSizing` +
///    `installDocumentSelectionLayoutManager`), laid out through its DISPLAY
///    container at the same width. `TableTextView` itself lives with the views
///    (not compiled into this target); its only height-relevant code is
///    `TableTextBuilder.tableHeight`, used on both sides here.
final class TableTextTests: XCTestCase {

    private var theme: MarkdownTheme { MarkdownTheme.cached(for: .light) }

    /// The prototype's fixtures (scratchpad/table-proto, 2026-10-22) plus a
    /// header-only table.
    private static let fixtures: [(name: String, markdown: String)] = [
        ("simple", """
        | Name | Role | Since |
        |------|------|-------|
        | Ada | Engineer | 2019 |
        | Grace | Admiral | 1943 |
        | Linus | Maintainer | 1991 |
        """),
        ("rich", """
        | Feature | Description | Status |
        |:--------|:-----------:|-------:|
        | **Search** | Finds every occurrence across the document, including text inside tables, and highlights the focused one while you step with Cmd-G | `done` |
        | Links | See [the docs](https://example.com/docs) for the full list of supported inline syntax, which wraps onto several lines at narrow widths | **beta** |
        | Code | `let x = renderer.renderInline(cell)` sits inline with regular text and must wrap with it | ok |
        """),
        ("headerless-ragged", """
        | | | |
        |---|---|---|
        | a | b |
        | one | two | three | four |
        | only |
        """),
        ("six-columns", """
        | Column 0 | Column 1 | Column 2 | Column 3 | Column 4 | Column 5 |
        |---|---|---|---|---|---|
        | Cell 0,0 | Cell 0,1 | **Row 0** has `code` and a longer description that wraps at narrower widths | Cell 0,3 | Cell 0,4 | Cell 0,5 |
        | Cell 1,0 | Cell 1,1 | **Row 1** has `code` and a longer description that wraps at narrower widths | Cell 1,3 | Cell 1,4 | Cell 1,5 |
        """),
        ("header-only", """
        | Lonely | Header |
        |---|---|
        """),
    ]

    private struct Table {
        let block: MarkdownBlock
        let headers: [String]
        let rows: [[String]]
        let alignments: [TextAlignment]
    }

    private func table(_ markdown: String, fontScale: CGFloat = 1) -> Table {
        let blocks = MarkdownBlockParser(theme: theme, fontScale: fontScale).parse(markdown)
        for block in blocks {
            if case .table(let headers, let rows, let alignments) = block.content {
                return Table(block: block, headers: headers, rows: rows, alignments: alignments)
            }
        }
        XCTFail("no table in fixture")
        return Table(block: blocks[0], headers: [], rows: [], alignments: [])
    }

    private func build(_ t: Table, fontScale: CGFloat = 1) -> TableText {
        TableTextBuilder.build(headers: t.headers, rows: t.rows, alignments: t.alignments,
                               theme: theme, fontScale: fontScale)
    }

    /// A text view set up as `TableTextView.makeNSView` sets it up, holding
    /// `table`, laid out at `width` through its display container.
    private func liveTextView(_ table: TableText, width: CGFloat) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.textStorage?.setAttributedString(table.string)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    // MARK: - String layout (TS-D4)

    func testHeaderThenRowsLeftToRightOneParagraphPerCell() {
        let t = table(Self.fixtures[0].markdown)
        let built = build(t)
        XCTAssertEqual(built.string.string,
                       "Name\nRole\nSince\nAda\nEngineer\n2019\nGrace\nAdmiral\n1943\nLinus\nMaintainer\n1991\n")
        XCTAssertTrue(built.layout.showsHeader)
        XCTAssertEqual(built.layout.columnCount, 3)
        XCTAssertEqual(built.layout.bandCount, 4)
        XCTAssertEqual(built.layout.length, built.string.length)

        // Every cell is exactly one paragraph, and that paragraph is the cell's
        // own NSTextTableBlock at (band, column).
        let ns = built.string.string as NSString
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            paragraphs.append(range)
        }
        XCTAssertEqual(paragraphs, built.layout.cellRanges.flatMap { $0 })
        for band in 0..<built.layout.bandCount {
            for column in 0..<built.layout.columnCount {
                let range = built.layout.cellRanges[band][column]
                let style = built.string.attribute(.paragraphStyle, at: NSMaxRange(range),
                                                   effectiveRange: nil) as? NSParagraphStyle
                let block = style?.textBlocks.first as? NSTextTableBlock
                XCTAssertEqual(block?.startingRow, band)
                XCTAssertEqual(block?.startingColumn, column)
                XCTAssertEqual(block?.verticalAlignment, .middleAlignment)
                XCTAssertEqual(ns.character(at: NSMaxRange(range)), 0x0A, "cell (\(band),\(column)) ends in \\n")
            }
        }
        XCTAssertEqual(NSMaxRange(built.layout.cellRanges[3][2]), built.string.length - 1,
                       "the last cell's \\n is the last character")
    }

    func testRaggedRowsArePaddedWithEmptyCells() {
        let built = TableTextBuilder.build(headers: ["A", "B"], rows: [["1"], ["2", "3", "4"]],
                                           alignments: [.leading, .trailing], theme: theme, fontScale: 1)
        XCTAssertEqual(built.layout.columnCount, 3)
        XCTAssertEqual(built.string.string, "A\nB\n\n1\n\n\n2\n3\n4\n")
        XCTAssertEqual(built.layout.cellRanges, [
            [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), NSRange(location: 4, length: 0)],
            [NSRange(location: 5, length: 1), NSRange(location: 7, length: 0), NSRange(location: 8, length: 0)],
            [NSRange(location: 9, length: 1), NSRange(location: 11, length: 1), NSRange(location: 13, length: 1)],
        ])
        // Column alignment from the separator row; missing columns are leading.
        func alignment(_ band: Int, _ column: Int) -> NSTextAlignment? {
            (built.string.attribute(.paragraphStyle, at: NSMaxRange(built.layout.cellRanges[band][column]),
                                    effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        XCTAssertEqual(alignment(1, 0), .left)
        XCTAssertEqual(alignment(1, 1), .right)
        XCTAssertEqual(alignment(1, 2), .left)
    }

    func testHeaderlessTableHasNoHeaderBand() {
        let t = table(Self.fixtures[2].markdown)
        let built = build(t)
        XCTAssertFalse(built.layout.showsHeader)
        XCTAssertEqual(built.layout.bandCount, t.rows.count)
        XCTAssertTrue(built.string.string.hasPrefix("a\nb\n\n"), built.string.string)
        // No header background anywhere.
        built.string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: built.string.length)) { value, _, _ in
            let block = (value as? NSParagraphStyle)?.textBlocks.first
            XCTAssertNil(block?.backgroundColor)
        }
    }

    func testBandRangeAndCellContaining() {
        let built = TableTextBuilder.build(headers: ["H1", "H2"], rows: [["a", ""], ["bb", "c"]],
                                           alignments: [], theme: theme, fontScale: 1)
        // "H1\nH2\na\n\nbb\nc\n"
        let layout = built.layout
        XCTAssertEqual(layout.bandRange(0), NSRange(location: 0, length: 6))
        XCTAssertEqual(layout.bandRange(1), NSRange(location: 6, length: 3))
        XCTAssertEqual(layout.bandRange(2), NSRange(location: 9, length: 5))
        XCTAssertEqual(NSMaxRange(layout.bandRange(2)), built.string.length)

        let expected: [(Int, Int)] = [(0, 0), (0, 0), (0, 0), (0, 1), (0, 1), (0, 1),
                                      (1, 0), (1, 0), (1, 1),
                                      (2, 0), (2, 0), (2, 0), (2, 1), (2, 1)]
        XCTAssertEqual(expected.count, built.string.length)
        for (index, cell) in expected.enumerated() {
            let hit = layout.cell(containing: index)
            XCTAssertEqual(hit?.band, cell.0, "index \(index)")
            XCTAssertEqual(hit?.column, cell.1, "index \(index)")
        }
        XCTAssertNil(layout.cell(containing: -1))
        XCTAssertNil(layout.cell(containing: built.string.length))
    }

    func testEmptyTableIsEmptyAndZeroHigh() {
        let built = TableTextBuilder.build(headers: ["", ""], rows: [], alignments: [.leading, .leading],
                                           theme: theme, fontScale: 1)
        XCTAssertEqual(built.string.length, 0)
        XCTAssertEqual(built.layout.bandCount, 0)
        XCTAssertEqual(built.layout.length, 0)
        XCTAssertNil(built.layout.cell(containing: 0))
        XCTAssertEqual(TableTextBuilder.height(of: built.string, width: 500), 0)
    }

    /// What 1.12 drew: the renderer's 14·scale regular in EVERY cell, header
    /// included; header band background; rules on trailing/bottom edges only,
    /// the header always keeping its bottom rule.
    func testCellFontsBackgroundsAndRules() {
        for scale in [CGFloat(0.75), 1.0, 1.5] {
            let built = build(table(Self.fixtures[0].markdown, fontScale: scale), fontScale: scale)
            built.string.enumerateAttribute(.font, in: NSRange(location: 0, length: built.string.length)) { value, range, _ in
                guard let font = value as? NSFont else { return XCTFail("no font at \(range)") }
                XCTAssertEqual(font.pointSize, BlockLayout.Table.cellFontSize * scale, accuracy: 0.001)
                XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold), "bold at \(range)")
            }
        }
        let built = build(table(Self.fixtures[0].markdown))
        func block(_ band: Int, _ column: Int) -> NSTextTableBlock {
            let style = built.string.attribute(.paragraphStyle, at: built.layout.cellRanges[band][column].location,
                                               effectiveRange: nil) as! NSParagraphStyle
            return style.textBlocks[0] as! NSTextTableBlock
        }
        XCTAssertNotNil(block(0, 0).backgroundColor)
        XCTAssertNil(block(1, 0).backgroundColor)
        XCTAssertEqual(block(0, 0).width(for: .border, edge: .maxX), BlockLayout.Table.dividerWidth)
        XCTAssertEqual(block(0, 2).width(for: .border, edge: .maxX), 0)
        XCTAssertEqual(block(2, 1).width(for: .border, edge: .maxY), BlockLayout.Table.separatorHeight)
        XCTAssertEqual(block(3, 1).width(for: .border, edge: .maxY), 0)
        XCTAssertEqual(block(0, 1).width(for: .padding, edge: .minY), BlockLayout.Table.headerCellVerticalPadding)
        XCTAssertEqual(block(1, 1).width(for: .padding, edge: .minY), BlockLayout.Table.cellVerticalPadding)

        let headerOnly = build(table(Self.fixtures[4].markdown))
        let headerStyle = headerOnly.string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(headerStyle.textBlocks[0].width(for: .border, edge: .maxY), BlockLayout.Table.separatorHeight,
                       "the header separator is drawn even with no rows below it (as 1.12)")
    }

    // MARK: - Measurer (TS-D3)

    func testTableRowIsExactAndCarriesTheBuiltString() {
        let t = table(Self.fixtures[1].markdown)
        let measured = BlockHeightMeasurer.measure(blocks: [t.block], theme: theme, fontScale: 1,
                                                   contentWidth: 700, math: nil)
        XCTAssertEqual(measured.table.kinds, [.exact])
        XCTAssertTrue(measured.mathPendingRows.isEmpty)
        let carried = measured.tables[t.block.id]
        XCTAssertNotNil(carried)
        // Characters + layout: NSAttributedString equality compares the
        // NSTextTable objects by identity, and each build makes its own.
        XCTAssertEqual(carried?.string.string, build(t).string.string)
        XCTAssertEqual(carried?.layout, build(t).layout)
        XCTAssertTrue(carried?.matches(headers: t.headers, rows: t.rows, alignments: t.alignments,
                                       fontScale: 1) ?? false)
        XCTAssertFalse(carried?.matches(headers: t.headers, rows: t.rows, alignments: t.alignments,
                                        fontScale: 1.5) ?? true, "another zoom is another string")
    }

    /// measurer row == laid-out view + outer padding, to the point, for every
    /// fixture × width × zoom. Also checked against the table's real drawn
    /// bottom (the last cell's block bounds), which does not go through
    /// `tableHeight` at all.
    func testMeasuredHeightEqualsLaidOutTableView() {
        var compared = 0
        for fixture in Self.fixtures {
            for scale in [CGFloat(0.75), 1.0, 1.5] {
                let t = table(fixture.markdown, fontScale: scale)
                let built = build(t, fontScale: scale)
                for width in [CGFloat(400), 700, 1000] {
                    let row = BlockHeightMeasurer.measure(blocks: [t.block], theme: theme, fontScale: scale,
                                                          contentWidth: width, math: nil).table.heights[0]
                    let measured = row - 2 * BlockLayout.Document.tableOuterVerticalPadding

                    let textView = liveTextView(built, width: width)
                    let live = TableTextBuilder.tableHeight(layoutManager: textView.layoutManager!,
                                                            container: textView.textContainer!)
                    let tag = "\(fixture.name) @\(Int(width)) ×\(scale)"
                    XCTAssertEqual(measured, live, tag)

                    let layout = built.layout
                    let lastCell = textView.tableCellBounds(band: layout.bandCount - 1, column: 0, layout: layout)
                    XCTAssertNotNil(lastCell, tag)
                    XCTAssertEqual(live, ceil(lastCell?.maxY ?? 0), tag)
                    XCTAssertGreaterThan(live, 0, tag)
                    compared += 1
                }
            }
        }
        XCTAssertEqual(compared, Self.fixtures.count * 9)
    }

    func testHeightGrowsWhenCellsWrap() {
        let t = table(Self.fixtures[1].markdown)
        let built = build(t)
        XCTAssertGreaterThan(TableTextBuilder.height(of: built.string, width: 400),
                             TableTextBuilder.height(of: built.string, width: 1000))
    }

    // MARK: - Hit-testing helper (TS-D6 groundwork)

    /// Centre and padding corners of every cell resolve to THAT cell — the
    /// probes plain `characterIndexForInsertion` got wrong 19/36 times.
    func testConfinedHitTestStaysInTheCellUnderThePoint() {
        for fixture in Self.fixtures {
            let built = build(table(fixture.markdown))
            let textView = liveTextView(built, width: 700)
            let layout = built.layout
            for band in 0..<layout.bandCount {
                for column in 0..<layout.columnCount {
                    guard let rect = textView.tableCellBounds(band: band, column: column, layout: layout) else {
                        XCTFail("\(fixture.name) no bounds for (\(band),\(column))")
                        continue
                    }
                    let probes: [(String, NSPoint)] = [
                        ("centre", NSPoint(x: rect.midX, y: rect.midY)),
                        ("topLeftPadding", NSPoint(x: rect.minX + 2, y: rect.minY + 2)),
                        ("bottomRightPadding", NSPoint(x: rect.maxX - 3, y: rect.maxY - 3)),
                    ]
                    for (label, point) in probes {
                        let index = textView.characterIndex(confinedToCellAt: point, layout: layout)
                        let hit = layout.cell(containing: index)
                        XCTAssertEqual(hit?.band, band, "\(fixture.name) (\(band),\(column)) \(label) idx \(index)")
                        XCTAssertEqual(hit?.column, column, "\(fixture.name) (\(band),\(column)) \(label) idx \(index)")
                    }
                }
            }
            // Outside the table: the nearest cell.
            let below = textView.characterIndex(confinedToCellAt: NSPoint(x: 1, y: 10_000), layout: layout)
            XCTAssertEqual(layout.cell(containing: below)?.band, layout.bandCount - 1, fixture.name)
            XCTAssertEqual(layout.cell(containing: below)?.column, 0, fixture.name)
            let above = textView.characterIndex(confinedToCellAt: NSPoint(x: 699, y: -50), layout: layout)
            XCTAssertEqual(layout.cell(containing: above)?.band, 0, fixture.name)
            XCTAssertEqual(layout.cell(containing: above)?.column, layout.columnCount - 1, fixture.name)
        }
    }
}
