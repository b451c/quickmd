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

    // MARK: - Scroll anchor across layouts (Reading Mode, width, zoom, jumps)

    /// `VirtualBlockList.Coordinator`'s scrolling over a model column, step by
    /// step as the coordinator runs it: capture → new table → place the
    /// anchor (`install`), the reading-mode toggle, jumps, and the height
    /// reports of the `.reported` rows that are on screen. The decisions are
    /// the coordinator's own (`RowGeometry.isAt`, `anchorPlacement`,
    /// `reportAction`); `current == false` replays the rules of the branch
    /// before this fix, as a control: re-anchor on the row under the content
    /// top every time, place the offset as is, compensate any block whose top
    /// is above the content top.
    private struct ListModel {
        struct Row {
            var spacing: CGFloat
            /// What the list lays the block out at (the height table).
            var height: CGFloat
            /// What the block's view measures.
            var real: CGFloat
            /// `.reported`: its view reports `real` once it is on screen.
            var reported: Bool

            static func exact(_ spacing: CGFloat, _ height: CGFloat) -> Row {
                Row(spacing: spacing, height: height, real: height, reported: false)
            }
            static func reported(_ spacing: CGFloat, _ estimate: CGFloat, real: CGFloat) -> Row {
                Row(spacing: spacing, height: estimate, real: real, reported: true)
            }
        }

        var rows: [Row]
        var contentTop: CGFloat
        var current = true
        var inset: CGFloat = 24
        var clipHeight: CGFloat = 828
        var anchor: (row: Int, offset: CGFloat, placed: CGFloat)?
        /// A jump in flight: the content top is still on its way to here.
        var jumpTarget: CGFloat?
        /// Rows whose view reported since the last table (`reportedBlocks`).
        var confirmed: Set<Int> = []

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
        /// Where block `row`'s top is on screen, from the top of the clip view.
        func screenY(_ row: Int) -> CGFloat { blockTop(row) - (contentTop - inset) }
        func rowUnderContentTop() -> Int {
            rects.firstIndex { contentTop >= $0.minY && contentTop < $0.maxY } ?? rows.count - 1
        }
        /// The rows AppKit has views for: those in the clip view, whose top
        /// inset shows content too.
        var rowsOnScreen: [Int] {
            let top = contentTop - inset
            return rects.indices.filter { rects[$0].maxY > top && rects[$0].minY < top + clipHeight }
        }

        func anchoredRow() -> Int? {
            guard current, let anchor else { return nil }
            if jumpTarget != nil { return anchor.row }
            return RowGeometry.isAt(anchorOffset: anchor.placed, contentTop: contentTop,
                                    rowRect: rects[anchor.row], spacingAbove: rows[anchor.row].spacing)
                ? anchor.row : nil
        }
        func capture() -> (row: Int, offset: CGFloat) {
            if let row = anchoredRow(), let anchor { return (row, anchor.offset) }
            let row = rowUnderContentTop()
            return (row, RowGeometry.anchorOffset(contentTop: contentTop, rowRect: rects[row],
                                                  spacingAbove: rows[row].spacing))
        }
        mutating func place(_ row: Int, _ offset: CGFloat) {
            let placed = current
                ? RowGeometry.anchorPlacement(offset: offset, blockHeight: rows[row].height, topInset: inset,
                                              heightIsEstimate: rows[row].reported && !confirmed.contains(row))
                : offset
            if jumpTarget != nil {
                jumpTarget = blockTop(row) + placed
            } else {
                contentTop = blockTop(row) + placed
            }
            anchor = (row, offset, placed)
        }
        mutating func report(_ row: Int) {
            let top = contentTop
            let delta = rows[row].real - rows[row].height
            let blockTop = blockTop(row)
            let anchorRow = anchoredRow()
            rows[row].height = rows[row].real
            guard current else {
                if blockTop < top, jumpTarget == nil { contentTop = top + delta }
                return
            }
            switch RowGeometry.reportAction(row: row, anchorRow: anchorRow, blockTop: blockTop, contentTop: top) {
            case .keep:
                break
            case .shift where jumpTarget != nil, .placeAnchor:
                if let anchor { place(anchor.row, anchor.offset) }
            case .shift:
                contentTop = top + delta
            }
        }
        /// Every view on screen reports; a report can bring new rows on screen.
        mutating func settle() {
            for _ in 0..<50 {
                confirmed.formUnion(rowsOnScreen.filter { rows[$0].reported })
                guard let row = rowsOnScreen.first(where: {
                    rows[$0].reported && abs(rows[$0].real - rows[$0].height) >= 0.5
                }) else { return }
                report(row)
            }
            XCTFail("the reports never settled")
        }
        /// A new table (zoom, width): capture, install, place, reports.
        mutating func install(_ new: [Row], settling: Bool = true) {
            let captured = capture()
            rows = new
            anchor = nil
            jumpTarget = nil
            confirmed = []
            place(captured.row, captured.offset)
            if settling { settle() }
        }
        /// `applyLayoutStyle` mid-document: the anchor minus the inset delta.
        mutating func toggleStyle(inset newInset: CGFloat) {
            let captured = capture()
            let delta = newInset - inset
            inset = newInset
            place(captured.row, captured.offset - delta)
        }
        /// A `.center` jump that lands after the views on screen reported.
        mutating func centerJump(to row: Int) {
            let target = RowGeometry.centerTarget(rowRect: rects[row], spacingAbove: rows[row].spacing,
                                                  visibleHeight: clipHeight - 2 * inset)
            jumpTarget = target
            anchor = (row, target - blockTop(row), target - blockTop(row))
            settle()   // still at the start of the glide
            contentTop = jumpTarget ?? target
            jumpTarget = nil
            settle()   // landed
        }
        /// The block's middle on screen minus the content area's middle.
        func offCentre(_ row: Int) -> CGFloat {
            let middle = blockTop(row) + rows[row].height / 2
            return (middle - contentTop) - (clipHeight - 2 * inset) / 2
        }
    }

    /// fixture.md around the image, as at 100 % zoom (`scale` 1), wrapped at
    /// `wrap` lines per short paragraph (2 = Reading Mode's 720 pt): the
    /// image is a placeholder in every new table (`imageEstimate`) and
    /// `imageReal` once loaded; the diagram starts at the 200 pt default.
    private func fixtureRows(scale s: CGFloat = 1, wrap: CGFloat = 1, imageReal: CGFloat = 655,
                             imageEstimate: CGFloat = 116, diagram: CGFloat = 94) -> [ListModel.Row] {
        let paragraph = { (spacing: CGFloat) in ListModel.Row.exact(spacing * s, 17 * s * wrap) }
        var rows: [ListModel.Row] = [.reported(0, 39 * s, real: 39 * s)]           // # Rhythm fixture
        rows += (0..<10).map { _ in paragraph(25) }                                 // the long list
        rows += [
            .reported(50 * s, 33 * s, real: 33 * s),                                // ## Image and caption
            .reported(16 * s, imageEstimate, real: imageReal),                      // the image
            .exact(17 * s, 17 * s),                                                 // its caption
            .reported(50 * s, 33 * s, real: 33 * s),                                // ## Math
            paragraph(19),
            .reported(13 * s, 64 * s, real: 64 * s),                                // a formula
            paragraph(13),
            .exact(21 * s, 66 * s),                                                 // the latex fallback
            paragraph(21),
            .reported(50 * s, 33 * s, real: 33 * s),                                // ## Diagram
            .reported(12 * s, 224, real: diagram + 24),                             // the diagram
            .exact(5 * s, 79 * s),                                                  // a table
            .reported(50 * s, 39 * s, real: 39 * s),                                // # Second part
        ]
        rows += (0..<12).map { _ in paragraph(25) }
        return rows
    }
    private let image = 12, secondPart = 23

    /// A model list on fixture.md with every view reported, the content top
    /// `offset` below the image's top.
    private func listInsideTheImage(at offset: CGFloat, current: Bool) -> ListModel {
        var rows = fixtureRows()
        for index in rows.indices { rows[index].height = rows[index].real }
        var list = ListModel(rows: rows, contentTop: 0, current: current)
        list.contentTop = list.blockTop(image) + offset
        list.anchor = nil
        return list
    }

    /// ⌘+ ⌘+ ⌘− ⌘− with the viewport top inside the image, only its bottom
    /// edge visible. Every zoom re-parses: the image comes back as a 116 pt
    /// placeholder. The reader stays in the image at every step and comes
    /// back to the very same point.
    func testZoomRoundTripKeepsAReaderInsideAnImage() {
        for current in [true, false] {
            var list = listInsideTheImage(at: 600, current: current)
            let start = list.contentTop
            var lostTheImage = false
            for scale: CGFloat in [1.1, 1.25, 1.1, 1] {
                list.install(fixtureRows(scale: scale))
                if list.rowUnderContentTop() != image { lostTheImage = true }
            }
            if current {
                XCTAssertFalse(lostTheImage)
                XCTAssertEqual(list.contentTop, start, accuracy: 0.001)
            } else {
                // The regression: placed 600 pt into a 116 pt placeholder, the
                // image is off screen, never reports, and the reader is left
                // in the blocks after it.
                XCTAssertTrue(lostTheImage)
                XCTAssertGreaterThan(abs(list.contentTop - start), 10)
            }
        }
    }

    /// Reading Mode on and off with the viewport top inside the image (the
    /// debug log: `row 21 + 579.5` on the way in, `row 29 + 0.0` on the way
    /// out). At 720 pt the image is smaller and the short paragraphs wrap.
    func testReadingModeRoundTripKeepsAReaderInsideAnImage() {
        for current in [true, false] {
            var list = listInsideTheImage(at: 603.5, current: current)
            let start = list.contentTop
            list.toggleStyle(inset: 48)
            list.install(fixtureRows(wrap: 2, imageReal: 576))
            if current {
                // Still on the image: its bottom edge in the top inset.
                XCTAssertEqual(list.anchor?.row, image)
                XCTAssertEqual(list.contentTop - list.blockTop(image), 579.5, accuracy: 0.001)
            }
            list.toggleStyle(inset: 24)
            list.install(fixtureRows())
            if current {
                XCTAssertEqual(list.contentTop, start, accuracy: 0.001)
            } else {
                XCTAssertGreaterThan(abs(list.contentTop - start), 10)
            }
        }
    }

    /// A second re-measure before the image had a chance to report (a width
    /// change right after a zoom): the anchor is still the image and its
    /// offset, not the row the placeholder left under the content top.
    func testAnchorInsideAPlaceholderSurvivesAnotherReinstall() {
        var list = listInsideTheImage(at: 550, current: true)
        let start = list.contentTop
        list.install(fixtureRows(), settling: false)
        list.install(fixtureRows(), settling: false)
        list.settle()
        XCTAssertEqual(list.contentTop, start, accuracy: 0.001)
    }

    /// Reading Mode on and off with the content top in the space above a
    /// block: the toggle's 24 pt move crosses into the row above, and the
    /// narrow layout has less space between those two blocks. Sticky anchor
    /// = exact; re-anchoring on the row under the content top drifts.
    func testReadingModeRoundTripWithTheReaderInAGap() {
        let wide: [ListModel.Row] = [.exact(0, 39), .exact(19, 17), .exact(25, 17), .exact(25, 17), .exact(21, 66),
                                     .exact(21, 17), .exact(50, 33), .exact(12, 186), .exact(5, 79)]
        var narrow = wide
        for row in 1...3 { narrow[row].height = 34; narrow[row].real = 34 }
        narrow[5].spacing = 13
        var drifted = false
        for start in stride(from: CGFloat(150), through: 330, by: 7.5) {
            for current in [true, false] {
                var list = ListModel(rows: wide, contentTop: start, current: current)
                list.toggleStyle(inset: 48)
                let block = list.capture().row
                let seen = list.screenY(block)
                list.install(narrow)
                if current {
                    XCTAssertEqual(list.screenY(block), seen, accuracy: 0.001, "entering at \(start)")
                }
                list.toggleStyle(inset: 24)
                list.install(wide)
                if current {
                    XCTAssertEqual(list.contentTop, start, accuracy: 0.001, "round trip from \(start)")
                } else if abs(list.contentTop - start) > 0.5 {
                    drifted = true
                }
            }
        }
        XCTAssertTrue(drifted)
    }

    /// ⌘F "Second part" from the top of the document: the image above the
    /// heading loads while the scroll is in flight, the diagram above it
    /// reports after it landed. The heading ends in the middle (before: at
    /// the bottom of the window, in 1.14.4 as well).
    func testSearchJumpStaysCentredWhileTheBlocksAboveReport() {
        for current in [true, false] {
            var list = ListModel(rows: fixtureRows(), contentTop: 0, current: current)
            list.centerJump(to: secondPart)
            if current {
                XCTAssertEqual(list.offCentre(secondPart), 0, accuracy: 0.001)
            } else {
                XCTAssertGreaterThan(list.offCentre(secondPart), 300)
            }
        }
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

    func testAnAnchorPastAnEstimateIsPlacedInsideTheBlock() {
        // 600 pt into an image whose placeholder is 116 pt: on its last point.
        XCTAssertEqual(RowGeometry.anchorPlacement(offset: 600, blockHeight: 116, topInset: 24, heightIsEstimate: true), 115)
        // Still partly visible in the top inset: as is.
        XCTAssertEqual(RowGeometry.anchorPlacement(offset: 130, blockHeight: 116, topInset: 24, heightIsEstimate: true), 130)
        // A measured block keeps the offset (the toggle's 24 pt can pass its end).
        XCTAssertEqual(RowGeometry.anchorPlacement(offset: 600, blockHeight: 116, topInset: 24, heightIsEstimate: false), 600)
        // In the gap above the block.
        XCTAssertEqual(RowGeometry.anchorPlacement(offset: -20, blockHeight: 116, topInset: 24, heightIsEstimate: true), -20)
    }

    // MARK: - Height reports

    func testReportsMoveTheContentTopAroundTheAnchor() {
        // No anchor (the reader scrolled): blocks above the content top, the
        // straddling one included, shift it; blocks in view don't.
        XCTAssertEqual(RowGeometry.reportAction(row: 3, anchorRow: nil, blockTop: 100, contentTop: 500), .shift)
        XCTAssertEqual(RowGeometry.reportAction(row: 3, anchorRow: nil, blockTop: 480, contentTop: 500), .shift)
        XCTAssertEqual(RowGeometry.reportAction(row: 3, anchorRow: nil, blockTop: 500, contentTop: 500), .keep)
        XCTAssertEqual(RowGeometry.reportAction(row: 3, anchorRow: nil, blockTop: 620, contentTop: 500), .keep)
        // An anchor: above it shifts — in view above a jump target too —, the
        // anchored block is placed again, below it nothing.
        XCTAssertEqual(RowGeometry.reportAction(row: 3, anchorRow: 7, blockTop: 620, contentTop: 500), .shift)
        XCTAssertEqual(RowGeometry.reportAction(row: 7, anchorRow: 7, blockTop: 480, contentTop: 500), .placeAnchor)
        XCTAssertEqual(RowGeometry.reportAction(row: 8, anchorRow: 7, blockTop: 480, contentTop: 500), .keep)
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
