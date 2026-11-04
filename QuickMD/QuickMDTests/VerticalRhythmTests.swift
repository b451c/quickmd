import XCTest
import SwiftUI
import AppKit

/// The vertical rhythm (`BlockLayout.Spacing`, VerticalRhythm.swift): rows are
/// CommonMark blocks, blank lines never add space, every gap is a multiple of
/// the body size, and print/PDF uses the same rules.
///
/// Gaps are checked as the READER sees them — the space above a row PLUS the
/// air the two blocks already have inside their rows (`realizedGap`) — against
/// the rules restated here independently (`expectedTarget`), not against
/// `BlockLayout.Spacing.above` itself.
final class VerticalRhythmTests: XCTestCase {

    // MARK: - Fixtures

    private typealias Spacing = BlockLayout.Spacing
    private var theme: MarkdownTheme { MarkdownTheme.cached(for: .light) }
    /// Rounding to whole points can move a gap by up to half a point.
    private let tolerance: CGFloat = 0.51

    /// Same deterministic stand-in for SwiftMath as `BlockHeightMeasurerTests`.
    private let math = MathRendering(
        inlineImage: { _, _, _ in NSImage(size: NSSize(width: 24, height: 12)) },
        displayHeight: { _, _, _ in 40 }
    )

    private func parse(_ markdown: String, fontScale: CGFloat = 1.0) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: theme, fontScale: fontScale).parse(markdown)
    }

    private func measure(_ blocks: [MarkdownBlock], fontScale: CGFloat = 1.0,
                         width: CGFloat = 640) -> MeasuredBlocks {
        BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: fontScale,
                                    contentWidth: width, math: math)
    }

    /// What the reader sees between row `index - 1` and row `index`: optical
    /// (baseline / cap top) around a heading unless the heading follows front
    /// matter, edge to edge otherwise.
    private func realizedGap(_ rows: [Spacing.Row], _ spacing: [CGFloat], _ index: Int) -> CGFloat {
        let previous = rows[index - 1], next = rows[index]
        if isOptical(previous.role, next.role) {
            return previous.edges.inkBelow + spacing[index] + next.edges.inkAbove
        }
        return previous.edges.boxBelow + spacing[index] + next.edges.boxAbove
    }

    private func isOptical(_ previous: Spacing.Role, _ next: Spacing.Role) -> Bool {
        if case .frontMatter = previous { return false }
        if case .heading = previous { return true }
        if case .heading = next { return true }
        return false
    }

    /// The approved values, in body-size units.
    private func expectedTarget(_ previous: Spacing.Role, _ next: Spacing.Role) -> CGFloat {
        switch (previous, next) {
        case (.heading(let upper), .heading(let lower)) where lower > upper: return 2.0
        case (.frontMatter, .heading): return 1.75
        case (_, .heading(let level)): return [4.75, 4.25, 3.75, 3.5, 3.5, 3.5][level - 1]
        case (.heading, _): return 2.25
        default: return 1.75
        }
    }

    /// Every gap of `markdown` at `fontScale` equals its target.
    private func assertEveryGapOnTarget(_ markdown: String, fontScale: CGFloat = 1.0,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let measured = measure(parse(markdown, fontScale: fontScale), fontScale: fontScale)
        let rows = measured.rhythm
        let spacing = measured.table.spacingAbove
        XCTAssertEqual(spacing.first, 0, "first row", file: file, line: line)
        let u = 14 * fontScale
        for index in rows.indices.dropFirst() where !rows[index].joinsPrevious {
            let expected = expectedTarget(rows[index - 1].role, rows[index].role) * u
            XCTAssertEqual(realizedGap(rows, spacing, index), expected, accuracy: tolerance,
                           "row \(index - 1) \(rows[index - 1].role) → row \(index) \(rows[index].role) at \(fontScale)",
                           file: file, line: line)
        }
    }

    private func plain(_ block: MarkdownBlock) -> String {
        guard case .text(let attributed) = block.content else { return "" }
        return String(attributed.characters)
    }

    // MARK: - Blank lines

    func testBlankLinesBetweenBlocksAreNeutral() {
        let pairs: [(String, String)] = [
            ("## Heading\n\nParagraph text.", "## Heading\nParagraph text."),
            ("# Title\n\n\n\nParagraph text.", "# Title\nParagraph text."),
            ("Paragraph text.\n\n- one\n- two", "Paragraph text.\n- one\n- two"),
            ("Paragraph text.\n\n1. one\n2. two", "Paragraph text.\n1. one\n2. two"),
            ("```\ncode\n```\n\nParagraph text.", "```\ncode\n```\nParagraph text."),
            ("Paragraph text.\n\n---\n\nMore text.", "Paragraph text.\n\n---\nMore text."),
        ]
        for (loose, tight) in pairs {
            let a = parse(loose), b = parse(tight)
            XCTAssertEqual(a.count, b.count, loose)
            XCTAssertEqual(a.map(plain), b.map(plain), loose)
            let ma = measure(a), mb = measure(b)
            XCTAssertEqual(ma.table.heights, mb.table.heights, loose)
            XCTAssertEqual(ma.table.spacingAbove, mb.table.spacingAbove, loose)
        }
    }

    func testTextRowsCarryNoBlankLinesOrTrailingBreak() {
        let blocks = parse("First paragraph.\n\n\n\nSecond paragraph.\n\n")
        XCTAssertEqual(blocks.map(plain), ["First paragraph.", "Second paragraph."])
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 4])
    }

    func testRowsAreCommonMarkBlocks() {
        let blocks = parse("Intro line one\nintro line two.\n- item a\n- item b\n\nOutro.\n***\nAfter the rule.")
        XCTAssertEqual(blocks.map(plain).count, 5, "\(blocks.map(plain))")
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 5, 6, 7])
        XCTAssertTrue(blocks.allSatisfy { !$0.joinsPrevious })
    }

    // MARK: - Headings

    func testEveryBlockUnderAHeadingGetsTheSameOpticalGap() {
        let followers = [
            "Paragraph text.",
            "- bullet one\n- bullet two",
            "1. first\n2. second",
            "```swift\nlet x = 1\n```",
            "> A quote.",
            "> [!NOTE]\n> An alert.",
            "| a | b |\n|---|---|\n| 1 | 2 |",
            "$$\nx^2\n$$",
            "```mermaid\ngraph TD; A-->B\n```",
            "![alt](missing.png)",
            "***",
        ]
        for follower in followers {
            let measured = measure(parse("## Heading\n\n" + follower))
            XCTAssertEqual(measured.rhythm.count, 2, follower)
            XCTAssertEqual(realizedGap(measured.rhythm, measured.table.spacingAbove, 1), 2.25 * 14,
                           accuracy: tolerance, follower)
            // …and the same air above a heading, whatever precedes it.
            let above = measure(parse(follower + "\n\n## Heading"))
            XCTAssertEqual(realizedGap(above.rhythm, above.table.spacingAbove, above.rhythm.count - 1), 4.25 * 14,
                           accuracy: tolerance, follower)
        }
    }

    func testHeadingTargetsPerLevelAndUnderAParent() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            assertEveryGapOnTarget("Paragraph text.\n\n\(hashes) Heading \(level)\n\nParagraph text.")
        }
        assertEveryGapOnTarget("# Title\n## Section\n### Subsection\nText.\n## Next section\n### Deeper\n#### Deepest")
        let under = measure(parse("# Title\n## Section"))
        XCTAssertEqual(realizedGap(under.rhythm, under.table.spacingAbove, 1), 2.0 * 14, accuracy: tolerance)
    }

    func testFrontMatterToTitleIsOneMarginEdgeToEdge() {
        let measured = measure(parse("---\ntitle: Notes\ntags: [a, b]\n---\n# Notes\n\nText."))
        XCTAssertEqual(measured.rhythm.first?.role, .frontMatter)
        XCTAssertEqual(measured.rhythm.count, 3)
        XCTAssertEqual(realizedGap(measured.rhythm, measured.table.spacingAbove, 1), 1.75 * 14, accuracy: tolerance)
    }

    // MARK: - Between other blocks

    func testNonHeadingPairsAreOneMarginApart() {
        assertEveryGapOnTarget("""
        First paragraph.

        Second paragraph.
        - a list
        - of items

        ```
        code
        ```
        > A quote.

        | a | b |
        |---|---|
        | 1 | 2 |

        > [!TIP]
        > An alert.

        $$
        y = x
        $$

        ***
        Last paragraph.
        """)
    }

    func testGapsScaleWithFontScale() {
        let document = """
        # Title
        Intro paragraph.

        - list one
        - list two

        ```
        code
        ```

        ## Section
        | a | b |
        |---|---|
        | 1 | 2 |

        ### Subsection
        > A quote.
        """
        for fontScale: CGFloat in [1.0, 1.25, 1.5] {
            assertEveryGapOnTarget(document, fontScale: fontScale)
        }
        let at100 = measure(parse(document)).table.spacingAbove
        let at150 = measure(parse(document, fontScale: 1.5), fontScale: 1.5).table.spacingAbove
        XCTAssertGreaterThan(at150.reduce(0, +), at100.reduce(0, +) * 1.4)
    }

    func testFirstRowHasNoSpaceAbove() {
        for markdown in ["# Title", "Text.", "```\ncode\n```", "> quote", "---\ntitle: x\n---\nText."] {
            XCTAssertEqual(measure(parse(markdown)).table.spacingAbove.first, 0, markdown)
        }
    }

    // MARK: - Cuts

    func testLongListIsCutSeamlessly() {
        let list = (1...70).map { "- item \($0)" }.joined(separator: "\n")
        let blocks = parse("Intro.\n\n" + list)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.map(\.joinsPrevious), [false, false, true, true])
        let limit = MarkdownBlockParser.textChunkLineLimit
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 2 + limit, 2 + 2 * limit])
        let measured = measure(blocks)
        XCTAssertEqual(measured.table.spacingAbove[2], 0)
        XCTAssertEqual(measured.table.spacingAbove[3], 0)
        XCTAssertGreaterThan(measured.table.spacingAbove[1], 0)

        // A copy across the cuts reads as one list: a line break at each cut.
        let selection = DocumentSelection(anchor: SelectionPoint(row: 1, offset: 0),
                                          focus: SelectionPoint(row: 3, offset: measured.converted[blocks[3].id]!.length))
        let output = DocumentCopyBuilder.build(parts: SelectionRows.parts(
            of: selection, blocks: blocks, text: { measured.converted[$0.id] }, table: { _ in nil }))
        XCTAssertFalse(output.plain.contains("\n\n"))
        XCTAssertEqual(output.plain.components(separatedBy: "\n").count, 70)
    }

    func testNestedQuoteGroupsJoinTheirQuote() {
        let blocks = parse("Text.\n\n> outer\n>> inner\n> outer again\n\n> separate quote")
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks.map(\.joinsPrevious), [false, false, true, true, false])
        let measured = measure(blocks)
        XCTAssertEqual(Array(measured.table.spacingAbove[2...3]), [0, 0])
        XCTAssertGreaterThan(measured.table.spacingAbove[4], 0)
    }

    func testCopyJoinsSeparateBlocksWithABlankLine() {
        let blocks = parse("One.\n\nTwo.")
        let measured = measure(blocks)
        let selection = DocumentSelection(anchor: SelectionPoint(row: 0, offset: 0),
                                          focus: SelectionPoint(row: 1, offset: 4))
        let output = DocumentCopyBuilder.build(parts: SelectionRows.parts(
            of: selection, blocks: blocks, text: { measured.converted[$0.id] }, table: { _ in nil }))
        XCTAssertEqual(output.plain, "One.\n\nTwo.")
    }

    // MARK: - Ordered lists split into rows

    func testLooseOrderedListKeepsOneTextEdge() {
        let loose = parse((1...10).map { "\($0). item \($0)" }.joined(separator: "\n\n"))
        let tight = parse((1...10).map { "\($0). item \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(loose.count, 10)
        XCTAssertEqual(tight.count, 1)
        let measured = measure(loose)
        let headIndents = loose.map { block -> CGFloat in
            let style = measured.converted[block.id]?.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            return (style as? NSParagraphStyle)?.headIndent ?? -1
        }
        let tightString = measure(tight).converted[tight[0].id]!
        let tightIndent = (tightString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent
        XCTAssertEqual(Set(headIndents).count, 1, "\(headIndents)")
        XCTAssertEqual(headIndents.first, tightIndent)
    }

    // MARK: - Partial re-measures carry the column

    @MainActor
    func testMeasureMathRowsDerivesTheSameColumnAsAFullMeasure() {
        let blocks = parse("## Heading\n\nInline $x^2$ math on the first line.\n\n$$\ny = x\n$$\n\nAfter.\n\n### Next\nText.")
        let deferred = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1.25,
                                                   contentWidth: 640, math: nil)
        XCTAssertFalse(deferred.mathPendingRows.isEmpty)
        let finished = BlockHeightMeasurer.measureMathRows(deferred.mathPendingRows, in: deferred, blocks: blocks,
                                                           theme: theme, fontScale: 1.25, contentWidth: 640,
                                                           math: math)
        let direct = measure(blocks, fontScale: 1.25)
        XCTAssertEqual(finished.table, direct.table)
        XCTAssertEqual(finished.rhythm, direct.rhythm)
    }

    func testHeightReportChangesTheBlockNotItsSpacing() {
        let measured = measure(parse("Text.\n\n## Heading\n\nMore text."))
        let patched = measured.replacingHeight(123, at: 1)
        XCTAssertEqual(patched.table.heights[1], 123)
        XCTAssertEqual(patched.table.spacingAbove, measured.table.spacingAbove)
        XCTAssertEqual(patched.rhythm, measured.rhythm)
        XCTAssertEqual(patched.table.rowHeight(1), measured.table.spacing(1) + 123)
        XCTAssertEqual(measured.replacingHeight(5, at: 99).table, measured.table)
    }

    // MARK: - Row geometry (VirtualBlockList)

    func testRowGeometryPutsJumpsAndHitsOnTheBlock() {
        let row = NSRect(x: 0, y: 100, width: 500, height: 60)
        XCTAssertEqual(RowGeometry.contentRect(rowRect: row, spacingAbove: 20),
                       NSRect(x: 0, y: 120, width: 500, height: 40))
        XCTAssertEqual(RowGeometry.contentRect(rowRect: row, spacingAbove: 0), row)
        XCTAssertEqual(RowGeometry.contentRect(rowRect: row, spacingAbove: 90).height, 0)
        // `.top`: the block's top, not the row's.
        XCTAssertEqual(RowGeometry.topTarget(rowRect: row, spacingAbove: 20), 120)
        // `.center`: the block's middle (140) at the middle of a 400 pt area.
        XCTAssertEqual(RowGeometry.centerTarget(rowRect: row, spacingAbove: 20, visibleHeight: 400), -60)
        // The gap above the block: upper half → the previous row.
        XCTAssertTrue(RowGeometry.belongsToPreviousRow(y: 109.9, rowRect: row, spacingAbove: 20))
        XCTAssertFalse(RowGeometry.belongsToPreviousRow(y: 110, rowRect: row, spacingAbove: 20))
        XCTAssertFalse(RowGeometry.belongsToPreviousRow(y: 100, rowRect: row, spacingAbove: 0))
        // An atomic block splits at ITS middle.
        XCTAssertTrue(RowGeometry.isInUpperHalf(y: 139.9, rowRect: row, spacingAbove: 20))
        XCTAssertFalse(RowGeometry.isInUpperHalf(y: 140, rowRect: row, spacingAbove: 20))
    }

    // MARK: - Scroll anchor across layouts (Reading Mode, width, zoom)

    /// A column of rows as `NSTableView` lays it out with no intercell
    /// spacing: each row is its space above plus its block.
    private struct Column {
        let rows: [(spacing: CGFloat, height: CGFloat)]
        var rects: [NSRect] {
            var y: CGFloat = 0
            return rows.map { row in
                defer { y += row.spacing + row.height }
                return NSRect(x: 0, y: y, width: 500, height: row.spacing + row.height)
            }
        }
        func blockTop(_ row: Int) -> CGFloat {
            RowGeometry.topTarget(rowRect: rects[row], spacingAbove: rows[row].spacing)
        }
    }

    /// `VirtualBlockList.Coordinator`'s anchor bookkeeping over a `Column`:
    /// `captureAnchor` (the last anchor while the content top is still on it,
    /// else the row under the content top), `restore`, the reading-mode toggle
    /// and the install of a table measured at another width.
    private struct Scroller {
        var column: Column
        var contentTop: CGFloat
        /// Off = re-anchor on the row under the content top every time (the
        /// first version of the branch).
        let sticky: Bool
        var last: (row: Int, offset: CGFloat)?

        mutating func capture() -> (row: Int, offset: CGFloat) {
            let rects = column.rects
            if sticky, let last, RowGeometry.isAt(anchorOffset: last.offset, contentTop: contentTop,
                                                  rowRect: rects[last.row],
                                                  spacingAbove: column.rows[last.row].spacing) {
                return last
            }
            let row = rects.firstIndex { contentTop >= $0.minY && contentTop < $0.maxY } ?? rects.count - 1
            return (row, RowGeometry.anchorOffset(contentTop: contentTop, rowRect: rects[row],
                                                  spacingAbove: column.rows[row].spacing))
        }
        mutating func restore(_ anchor: (row: Int, offset: CGFloat)) {
            contentTop = RowGeometry.contentTop(anchorOffset: anchor.offset, rowRect: column.rects[anchor.row],
                                                spacingAbove: column.rows[anchor.row].spacing)
            last = anchor
        }
        /// `applyLayoutStyle`: the anchor minus the inset delta.
        mutating func toggleStyle(insetDelta: CGFloat) {
            let anchor = capture()
            restore((anchor.row, anchor.offset - insetDelta))
        }
        /// `install` of the table measured at the new width.
        mutating func install(_ new: Column) {
            let anchor = capture()
            column = new
            restore(anchor)
        }
    }

    /// Reading Mode on and off, step by step as the coordinator runs it: the
    /// style toggle restores the anchor minus the inset delta (a 24 pt move of
    /// the content top, across a row boundary here), then the table measured
    /// at the new width is installed and the anchor restored again. The
    /// narrow layout has taller rows above the reader AND less space between
    /// the two blocks the content top moves between (a block's edges can
    /// change with the wrap); the content top starts inside the gap.
    func testReadingModeRoundTripReturnsToTheSameBlockOffset() {
        let wide = Column(rows: [(0, 39), (19, 17), (25, 17), (25, 17), (21, 66), (21, 17), (50, 33), (12, 186), (5, 79)])
        let narrow = Column(rows: [(0, 39), (19, 34), (25, 34), (25, 34), (21, 66), (13, 17), (50, 33), (12, 186), (5, 79)])
        let standardInset: CGFloat = 24, readingInset: CGFloat = 48
        var drifted = false

        for start in stride(from: CGFloat(150), through: 330, by: 7.5) {
            for sticky in [true, false] {
                var list = Scroller(column: wide, contentTop: start, sticky: sticky)
                list.toggleStyle(insetDelta: readingInset - standardInset)
                // The block the reader was anchored on, and where they saw it.
                let block = list.last?.row ?? 0
                let before = wide.blockTop(block) - start + standardInset

                list.install(narrow)
                if sticky {
                    XCTAssertEqual(narrow.blockTop(block) - list.contentTop + readingInset, before + 48,
                                   accuracy: 0.001, "entering at \(start)")
                }

                list.toggleStyle(insetDelta: standardInset - readingInset)
                list.install(wide)
                if sticky {
                    XCTAssertEqual(list.contentTop, start, accuracy: 0.001, "round trip from \(start)")
                } else if abs(list.contentTop - start) > 0.5 {
                    drifted = true
                }
            }
        }
        // Why the anchor is sticky: re-anchoring on the row under the content
        // top lands on block 4 after the toggle and comes back by block 5 — so
        // the round trip moves by the change in the space between them.
        XCTAssertTrue(drifted)
    }

    /// A zoom (or any re-measure) while the reader is inside an image: the
    /// image comes back at its placeholder height and the restore puts the
    /// content top past it; a second re-measure before the image reported
    /// must not anchor on whatever row is now under the content top.
    func testAnchorInsideAPlaceholderSurvivesAnotherReinstall() {
        let loaded = Column(rows: [(0, 39), (16, 640), (17, 17), (50, 33), (19, 17), (25, 17), (25, 17)])
        let placeholder = Column(rows: [(0, 39), (16, 116), (17, 17), (50, 33), (19, 17), (25, 17), (25, 17)])
        let start = loaded.blockTop(1) + 550
        var list = Scroller(column: loaded, contentTop: start, sticky: true)
        list.install(placeholder)   // re-parse: the image is a placeholder again
        list.install(placeholder)   // width change before it reported
        list.install(loaded)        // the image reported (no compensation: see the report tests)
        XCTAssertEqual(list.contentTop, start, accuracy: 0.001)
    }

    func testAnchorIsRelativeToTheBlockNotTheRowEdge() {
        let rect = NSRect(x: 0, y: 1000, width: 500, height: 80)
        // In the gap above the block: negative, and it stays the same distance
        // above the block when the gap itself changes (zoom, new neighbours).
        let offset = RowGeometry.anchorOffset(contentTop: 1010, rowRect: rect, spacingAbove: 30)
        XCTAssertEqual(offset, -20)
        let regapped = NSRect(x: 0, y: 2000, width: 500, height: 95)
        XCTAssertEqual(RowGeometry.contentTop(anchorOffset: offset, rowRect: regapped, spacingAbove: 45), 2025)
    }

    // MARK: - Height reports

    func testReportAboveTheViewportIsCompensated() {
        // A block wholly above, and one straddling the content top.
        XCTAssertEqual(RowGeometry.contentTopAfterReport(contentTop: 500, blockTop: 100, delta: 24, anchoredOffset: nil), 524)
        XCTAssertEqual(RowGeometry.contentTopAfterReport(contentTop: 500, blockTop: 480, delta: -37.5, anchoredOffset: nil), 462.5)
        // A block in view grows below the reader: nothing to do.
        XCTAssertNil(RowGeometry.contentTopAfterReport(contentTop: 500, blockTop: 500, delta: 24, anchoredOffset: nil))
        XCTAssertNil(RowGeometry.contentTopAfterReport(contentTop: 500, blockTop: 620, delta: 24, anchoredOffset: nil))
    }

    func testReportOfTheAnchoredBlockKeepsTheReaderInIt() {
        // After a zoom the reader was 550 pt into an image that came back at a
        // 116 pt placeholder: the restore put the content top 550 below its
        // block top. The image then reports its real height — the reader must
        // stay 550 pt into it, not move on by the placeholder's error.
        XCTAssertNil(RowGeometry.contentTopAfterReport(contentTop: 1550, blockTop: 1000, delta: 524, anchoredOffset: 550))
        // A diagram that came back TALLER than it is (the 200 pt default).
        XCTAssertNil(RowGeometry.contentTopAfterReport(contentTop: 1150, blockTop: 1000, delta: -37.5, anchoredOffset: 150))
        // The reader scrolled since the restore: an ordinary straddling block.
        XCTAssertEqual(RowGeometry.contentTopAfterReport(contentTop: 1300, blockTop: 1000, delta: 524, anchoredOffset: 550), 1824)
    }

    func testTableRowHeightIsSpacingPlusBlock() {
        let measured = measure(parse("# Title\n\nText.\n\n```\ncode\n```"))
        let table = measured.table
        for row in 0..<table.count {
            XCTAssertEqual(table.rowHeight(row), table.heights[row] + table.spacingAbove[row])
        }
        XCTAssertEqual(table.spacing(-1), 0)
        XCTAssertEqual(table.spacing(table.count), 0)
        XCTAssertEqual(table.rowHeight(table.count), 0)
    }

    // MARK: - Print / PDF

    func testPrintGapsMatchTheScreen() {
        let markdown = """
        ---
        title: Report
        ---
        # Report
        Intro paragraph.

        ## Data
        | a | b |
        |---|---|
        | 1 | 2 |

        Text after the table.
        ```
        code
        ```
        ### Notes
        > A quote.

        $$
        y = x
        $$
        - one
        - two
        """
        let printTheme = MarkdownTheme.exportTheme(for: .light)
        let blocks = MarkdownBlockParser(theme: printTheme, fontScale: 1).parse(markdown)
        let renderer = MarkdownRenderer(colorScheme: .light)
        let printRows = blocks.enumerated().map {
            PrintRhythm.row(for: $0.element, isFirst: $0.offset == 0, renderer: renderer, width: 532)
        }
        let printSpacing = Spacing.column(printRows, fontScale: 1)
        let screen = BlockHeightMeasurer.measure(blocks: blocks, theme: printTheme, fontScale: 1,
                                                 contentWidth: 532, math: math)
        XCTAssertEqual(printRows.map(\.role), screen.rhythm.map(\.role))
        XCTAssertEqual(printSpacing.first, 0)
        for index in blocks.indices.dropFirst() {
            let expected = expectedTarget(printRows[index - 1].role, printRows[index].role) * 14
            XCTAssertEqual(realizedGap(printRows, printSpacing, index), expected, accuracy: tolerance, "print \(index)")
            XCTAssertEqual(realizedGap(screen.rhythm, screen.table.spacingAbove, index), expected,
                           accuracy: tolerance, "screen \(index)")
        }
    }

    func testPaginationDropsTheSpaceAtAPageTop() {
        let placements = PrintRhythm.paginate([(100, 0), (50, 30), (600, 30), (40, 30), (700, 30), (10, 0)],
                                              pageHeight: 700)
        XCTAssertEqual(placements, [
            .init(page: 0, y: 0),
            .init(page: 0, y: 130),
            .init(page: 1, y: 0),      // 180 + 30 + 600 > 700: new page, no space above
            .init(page: 1, y: 630),    // 600 + 30 + 40 = 670 fits
            .init(page: 2, y: 0),      // a full page (a slice of a taller block)
            .init(page: 3, y: 0),      // the next slice: nothing fits below a full page
        ])
    }
}
