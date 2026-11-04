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

    /// CommonMark: a blank line is nothing but spaces and tabs. A line of
    /// no-break spaces (U+00A0) is text — `CharacterSet.whitespaces` counted
    /// it blank. After text it continues the paragraph; alone it is a
    /// paragraph of its own, one empty-looking line (GitHub: `<p>&nbsp;</p>`).
    /// It ends no block and separates none.
    func testALineOfNoBreakSpacesIsTextNotABlankLine() {
        let nbsp = "\u{00A0}"
        let continued = parse("Para one\n\(nbsp)\nPara two")
        XCTAssertEqual(continued.count, 1)
        XCTAssertEqual(plain(continued[0]), "Para one \(nbsp) Para two")
        let alone = parse("Para one\n\n\(nbsp)\(nbsp)\n\nPara two")
        XCTAssertEqual(alone.map(plain), ["Para one", "\(nbsp)\(nbsp)", "Para two"])
        XCTAssertEqual(measure(alone).table.heights[1], measure(alone).table.heights[0], "one line")
        // No separator in a list: one tight list.
        XCTAssertEqual(parse("- a\n\(nbsp)\n- b").count, 1)
        // A quote body: one paragraph.
        guard case .blockquote(let body, _) = parse("> a\n> \(nbsp)\n> b")[0].content else {
            return XCTFail("not a quote")
        }
        XCTAssertEqual(String(MarkdownRenderer(theme: theme).renderQuotedBody(body).characters), "a \(nbsp) b")
        // Spaces and tabs are still a blank line.
        XCTAssertEqual(parse("Para one\n \t \nPara two").count, 2)
        XCTAssertTrue(MarkdownRenderer.isBlankLine(" \t "))
        XCTAssertTrue(MarkdownRenderer.isBlankLine(""))
        XCTAssertFalse(MarkdownRenderer.isBlankLine(nbsp))
        XCTAssertFalse(MarkdownRenderer.isBlankLine(" \(nbsp)\t"))
    }

    func testRowsAreCommonMarkBlocks() {
        let blocks = parse("Intro line one\nintro line two.\n- item a\n- item b\n\nOutro.\n***\nAfter the rule.")
        XCTAssertEqual(blocks.map(plain).count, 5, "\(blocks.map(plain))")
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 5, 6, 7])
        XCTAssertTrue(blocks.allSatisfy { !$0.joinsPrevious })
    }

    /// CommonMark: only a bullet, or an ordered item numbered 1 (`1.` or
    /// `1)`), interrupts a paragraph. `1984. …` after paragraph text continues
    /// the paragraph — its text, in its row, with no gap.
    func testOnlyAnItemThatMayInterruptAParagraphStartsARow() {
        for line in ["- item", "* item", "+ item", "- [ ] task", "1. first", "1) first"] {
            XCTAssertEqual(parse("Paragraph text.\n" + line).count, 2, line)
        }
        for line in ["1984. A year", "2. second", "2) second", "-", "1."] {
            XCTAssertEqual(parse("Paragraph text.\n" + line).count, 1, line)
        }
        // CommonMark: the rest of the paragraph, drawn as its text — no item
        // marker, no line of its own — and searched and copied as such.
        let blocks = parse("Paragraph text.\n1984. A year\n1985) Another")
        XCTAssertEqual(plain(blocks[0]), "Paragraph text. 1984. A year 1985) Another")
        XCTAssertEqual(DocumentSearch.computeMatches(in: blocks, term: "text. 1984. A year 1985)").matchBlockIds.count, 1)
        // After a hard break: a line of its own, still text.
        XCTAssertEqual(plain(parse("Paragraph text.  \n1984. A year")[0]), "Paragraph text.\n1984. A year")
        // A list that starts a row is still a list, whatever its number or
        // delimiter (drawn `n.`, as GitHub draws both).
        XCTAssertEqual(parse("Text.\n\n3. third\n4. fourth").count, 2)
        XCTAssertTrue(plain(parse("1984) A year")[0]).hasPrefix("1984. A year"), plain(parse("1984) A year")[0]))
        // Inside a list, an item of any number is the next item.
        XCTAssertTrue(plain(parse("1. one\n1984. two")[0]).contains("\n1984. two"))
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
        // The properties table, and the yaml code block the parser falls back
        // to when `FrontMatter` cannot read the YAML (a nested map here) —
        // on screen and in print.
        let renderer = MarkdownRenderer(colorScheme: .light)
        for markdown in ["---\ntitle: Notes\ntags: [a, b]\n---\n# Notes\n\nText.",
                         "---\nauthor:\n  name: X\n---\n# Notes\n\nText."] {
            let blocks = parse(markdown)
            XCTAssertTrue(blocks[0].isFrontMatter, markdown)
            let measured = measure(blocks)
            XCTAssertEqual(measured.rhythm.first?.role, .frontMatter, markdown)
            XCTAssertEqual(measured.rhythm.count, 3)
            XCTAssertEqual(realizedGap(measured.rhythm, measured.table.spacingAbove, 1), 1.75 * 14,
                           accuracy: tolerance, markdown)
            let printRows = blocks.map { PrintRhythm.row(for: $0, renderer: renderer, width: 532) }
            XCTAssertEqual(printRows.first?.role, .frontMatter, markdown)
            XCTAssertEqual(realizedGap(printRows, Spacing.column(printRows, fontScale: 1), 1), 1.75 * 14,
                           accuracy: tolerance, markdown)
        }
        if case .codeBlock(_, let language) = parse("---\nauthor:\n  name: X\n---\n# Notes")[0].content {
            XCTAssertEqual(language, "yaml")
        } else {
            XCTFail("the fallback is a yaml code block")
        }
    }

    func testAYamlFenceOnTheFirstLineIsAnOrdinaryCodeBlock() {
        let blocks = parse("```yaml\ntitle: Notes\n```\n# Notes")
        XCTAssertFalse(blocks[0].isFrontMatter)
        XCTAssertEqual(measure(blocks).rhythm.first?.role, .box)
        XCTAssertFalse(parse("# Notes\n\n---\ntitle: x\n---")[1...].contains { $0.isFrontMatter })
    }

    /// Where the eye sees a block start under a heading: the heading's last
    /// baseline to the next block's first ink — measured independently of
    /// the rhythm's own edges.
    private func eyeGapUnderHeading(_ follower: String, fontScale: CGFloat,
                                    firstInk: (MarkdownBlock, MeasuredBlocks) -> CGFloat) -> CGFloat {
        let blocks = parse("## Heading\n\n" + follower, fontScale: fontScale)
        let measured = measure(blocks, fontScale: fontScale)
        return measured.rhythm[0].edges.inkBelow + measured.table.spacingAbove[1] + firstInk(blocks[1], measured)
    }

    /// The owner's measurement: `## Quotes` → the quote's first line read
    /// 35 pt, `## Loose ordered list` → its first line 30.5 pt. The quote's
    /// bar starts above its text; the eye reads the text.
    func testAQuoteUnderAHeadingSitsWhereAParagraphWould() {
        for scale: CGFloat in [1, 1.5] {
            let capTop = { (block: MarkdownBlock, measured: MeasuredBlocks, padding: CGFloat, width: CGFloat) in
                let ink = BlockHeightMeasurer.textInk(text: measured.converted[block.id]!, width: width)
                return padding + ink.firstBaseline - ink.firstCapHeight
            }
            let paragraph = eyeGapUnderHeading("Some paragraph text.", fontScale: scale) {
                capTop($0, $1, 0, BlockLayout.clampedWidth(640))
            }
            let quote = eyeGapUnderHeading("> Some quoted text.", fontScale: scale) {
                capTop($0, $1, BlockLayout.Quote.verticalPadding,
                       BlockLayout.Quote.bodyWidth(contentWidth: 640, level: 1))
            }
            XCTAssertEqual(quote, paragraph, accuracy: 1, "at \(scale)")
            // …and above a heading, from the quote's last baseline.
            assertEveryGapOnTarget("> A quote.\n\n## Next", fontScale: scale)
        }
    }

    /// A diagram has no frame: the eye sees it start at its first ink,
    /// Mermaid's padding inside the picture.
    func testADiagramUnderAHeadingStartsWhereAParagraphWould() {
        for scale: CGFloat in [1, 1.5] {
            let paragraph = eyeGapUnderHeading("Some paragraph text.", fontScale: scale) { block, measured in
                let ink = BlockHeightMeasurer.textInk(text: measured.converted[block.id]!,
                                                      width: BlockLayout.clampedWidth(640))
                return ink.firstBaseline - ink.firstCapHeight
            }
            let diagram = eyeGapUnderHeading("```mermaid\ngraph TD; A-->B\n```", fontScale: scale) { _, _ in
                BlockLayout.Document.mermaidOuterVerticalPadding + BlockLayout.Mermaid.verticalPadding
                    + BlockLayout.Mermaid.inkInset * scale
            }
            XCTAssertEqual(diagram, paragraph, accuracy: 1, "at \(scale)")
        }
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
        // The empty `>` line closes the inner quote's paragraph: without it
        // `> outer again` would continue that paragraph lazily (CommonMark).
        let blocks = parse("Text.\n\n> outer\n>> inner\n>\n> outer again\n\n> separate quote")
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

    /// The paragraph head indent of every ordered item in the text rows, in
    /// reading order — where each item's text starts.
    private func orderedItemIndents(_ blocks: [MarkdownBlock]) throws -> [CGFloat] {
        var indents: [CGFloat] = []
        for block in blocks {
            guard case .text(let attributed) = block.content else { continue }
            let string = try NSAttributedString(attributed, including: \.appKit)
            let text = string.string as NSString
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) {
                paragraph, range, _, _ in
                guard let paragraph, paragraph.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil
                else { return }
                let style = string.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                indents.append((style as? NSParagraphStyle)?.headIndent ?? -1)
            }
        }
        return indents
    }

    /// A list longer than a text row may be (`textChunkLineLimit`) is cut into
    /// rows; 1.14.4 measured the widest marker per ROW, so items 1–8 above
    /// the cut hung under "8. " and items 9–12 below it under "12. " — two
    /// text edges in one list. The widest marker is the LIST's.
    func testAnOrderedListCutIntoRowsKeepsOneTextEdge() throws {
        let items = (1...12).map { n in
            "\(n). item \(n)\n   - sub a\n   - sub b\n   - sub c"
        }
        let blocks = parse(items.joined(separator: "\n"))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.joinsPrevious), [false, true])
        let indents = try orderedItemIndents(blocks)
        XCTAssertEqual(indents.count, 12)
        XCTAssertEqual(Set(indents).count, 1, "\(indents)")
    }

    /// The steps of a list whose items each hold a code block: every step is
    /// a row of its own between two code blocks, and 1.14.4 hung each under
    /// its OWN number — the digits are proportional, so "1. " to "9. " each
    /// started the text at a different x and "10. " further right still.
    func testOrderedStepsWithCodeBlocksKeepOneTextEdge() throws {
        let steps = (1...11).map { "\($0). Step \($0)\n   ```sh\n   run \($0)\n   ```" }
        let blocks = parse(steps.joined(separator: "\n"))
        XCTAssertEqual(blocks.filter { if case .codeBlock = $0.content { return true }; return false }.count, 11)
        let indents = try orderedItemIndents(blocks)
        XCTAssertEqual(indents.count, 11)
        XCTAssertEqual(Set(indents).count, 1, "\(indents)")

        // A block NOT under the list (not indented) ends it: the list after
        // it hangs on its own.
        let separate = try orderedItemIndents(parse("1. a\n2. b\n\n```\ncode\n```\n\n10. c"))
        XCTAssertEqual(separate.count, 3)
        XCTAssertEqual(separate[0], separate[1])
        XCTAssertNotEqual(separate[1], separate[2])
    }

    /// ⌘G into a block taller than the window whose view is not on display:
    /// the jump goes to the block and aims at the match when it lands. The
    /// reader scrolling inside the block during the glide used to leave the
    /// aim in place (only "is the anchor row still there" was checked, and
    /// the glide ends on it), so the view was yanked to the match. Their
    /// scroll takes the aim away now; nothing else does until it is taken.
    func testASearchJumpsAimAtItsMatchIsDroppedWhenTheReaderScrolls() {
        var aim = PendingMatchAim()
        aim.jumped(to: "code-3", needsMatch: true)
        XCTAssertEqual(aim.blockId, "code-3")   // lands untouched: aims
        aim.readerScrolled()
        XCTAssertNil(aim.blockId)               // a wheel during the glide: stays where they are
        aim.jumped(to: "code-3", needsMatch: false)
        XCTAssertNil(aim.blockId)               // the match was known: centred at once
        aim.jumped(to: "table-1", needsMatch: true)
        aim.jumped(to: "code-9", needsMatch: true)
        XCTAssertEqual(aim.blockId, "code-9")   // the latest jump's
        aim.drop()
        XCTAssertNil(aim.blockId)               // a new table
    }

    /// An alert marker is `[!KIND]` with spaces or tabs around it (GitHub,
    /// gh api markdown in gfm mode): a no-break space after it leaves a
    /// plain quote; two trailing spaces still make the alert.
    func testAnAlertMarkerTakesSpacesAndTabsOnly() throws {
        XCTAssertEqual(try quoteShape("> [!NOTE]\u{00A0}\n> body\n"), ["q1:[!NOTE]\u{00A0}\nbody"])
        XCTAssertEqual(try quoteShape("> [!NOTE]  \n> body\n"), ["alert:note:body"])
        XCTAssertEqual(try quoteShape("> [!NOTE]\t\n> body\n"), ["alert:note:body"])
        XCTAssertEqual(try quoteShape("> [!NOTE]\n> body\n"), ["alert:note:body"])
        XCTAssertNil(AlertKind(markerLine: "\u{2003}[!TIP]"))
        XCTAssertEqual(AlertKind(markerLine: " [!TIP] "), .tip)
    }

    /// Which wheel events are the reader's scroll and drop a jump's aim: the
    /// ones that move the document. Fingers resting on the trackpad
    /// (`.mayBegin`), a gesture's end and zero-delta events used to drop it
    /// too, so ⌘G with fingers on the trackpad landed on the block's centre.
    func testOnlyAWheelEventThatScrollsDropsTheAim() {
        let scrolls = PendingMatchAim.isReaderScroll
        XCTAssertFalse(scrolls([.mayBegin], [], 0))           // fingers resting
        XCTAssertFalse(scrolls([], [], 0))                    // a zero-delta event
        XCTAssertFalse(scrolls([.ended], [], 0))              // the gesture lifts
        XCTAssertFalse(scrolls([.cancelled], [], 0))
        XCTAssertFalse(scrolls([.stationary], [], 0))
        XCTAssertFalse(scrolls([], [.ended], 0))              // momentum runs out
        XCTAssertTrue(scrolls([], [], -3))                    // a mouse wheel notch
        XCTAssertTrue(scrolls([.began], [], 0))               // a gesture starts
        XCTAssertTrue(scrolls([.changed], [], 1.5))
        XCTAssertTrue(scrolls([], [.began], 0))               // momentum
        XCTAssertTrue(scrolls([], [.changed], -12))
    }

    // MARK: - Block markers: spaces and tabs only

    /// Parses on a worker thread: a parser that never returns fails the test
    /// after `seconds` instead of stalling the suite (its thread keeps
    /// spinning, so a failure here is worth stopping the run for).
    private func parseReturning(_ markdown: String, within seconds: Double = 5,
                                file: StaticString = #filePath, line: UInt = #line) -> [MarkdownBlock]? {
        final class Box: @unchecked Sendable { var blocks: [MarkdownBlock]? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let theme = self.theme
        Thread.detachNewThread {
            box.blocks = MarkdownBlockParser(theme: theme).parse(markdown)
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            XCTFail("the parser did not return within \(seconds) s", file: file, line: line)
            return nil
        }
        return box.blocks
    }

    private func plain(_ block: MarkdownBlock) -> String? {
        if case .text(let attributed) = block.content { return String(attributed.characters) }
        return nil
    }

    /// A quote marker after a no-break, em or ideographic space: the block
    /// loop entered the quote branch on a line trimmed of EVERY Unicode
    /// space, the quote's own loop (spaces and tabs only, 9bbf6ae) refused
    /// the same line without consuming it, and the branch re-entered it for
    /// ever — 100 % CPU, the document never shown. CommonMark indents with
    /// spaces and tabs only, and GitHub shows each such line as paragraph
    /// text (`gh api markdown`: `<p> &gt; quoted</p>`).
    func testAQuoteMarkerAfterAUnicodeSpaceIsTextAndTheParserReturns() throws {
        for space in ["\u{00A0}", "\u{2003}", "\u{3000}"] {
            let name = String(format: "U+%04X", space.unicodeScalars.first!.value)
            let blocks = try XCTUnwrap(parseReturning("Intro\n\n\(space)> quoted\n"), name)
            XCTAssertEqual(blocks.map(plain), ["Intro", "\(space)> quoted"], name)
            // Inside a quote run too: no marker, so the line is the quote
            // paragraph's lazy continuation, text and all (GitHub:
            // `<blockquote><p>a  &gt; b</p></blockquote>`), and the parser goes on.
            let inside = try XCTUnwrap(parseReturning("> a\n\(space)> b\n\nAfter."), name)
            if case .blockquote(let content, _) = inside.first?.content {
                XCTAssertEqual(content, "a\n\(space)> b", name)
            } else {
                XCTFail("\(name): \(String(describing: inside.first?.content))")
            }
            XCTAssertEqual(inside.last.flatMap(plain), "After.", name)
        }
        // Spaces still indent a quote marker.
        let indented = try XCTUnwrap(parseReturning("Intro\n\n   > quoted\n"))
        if case .blockquote(let content, _) = indented.last?.content {
            XCTAssertEqual(content, "quoted")
        } else {
            XCTFail("\(String(describing: indented.last?.content))")
        }
    }

    /// Every other block marker the same way, as GitHub reads them
    /// (`gh api markdown`, 2026-11-04): a no-break space before a fence,
    /// `$$`, a setext underline, a table separator, a list marker, a rule or
    /// a link definition — or after `#` — leaves the line paragraph text.
    func testBlockMarkersAfterAUnicodeSpaceAreText() throws {
        let nbsp = "\u{00A0}"
        func kinds(_ markdown: String) throws -> [String] {
            try XCTUnwrap(parseReturning(markdown)).map { block in
                switch block.content {
                case .text: return "text"
                case .codeBlock: return "code"
                case .mathBlock: return "math"
                case .heading: return "heading"
                case .table: return "table"
                case .blockquote, .alert: return "quote"
                default: return "other"
                }
            }
        }
        // A fence: `<p> ``` code</p>` then the bare ``` opens an empty one.
        XCTAssertEqual(try kinds("\(nbsp)```\ncode\n```\n"), ["text", "code"])
        // Not a closing fence: one before it, one with a no-break space after.
        let closers = try XCTUnwrap(parseReturning("```\ncode\n\(nbsp)```\nmid\n```\(nbsp)\nend\n```\n"))
        XCTAssertEqual(closers.count, 1)
        if case .codeBlock(let code, _) = closers.first?.content {
            XCTAssertEqual(code, "code\n\(nbsp)```\nmid\n```\(nbsp)\nend")
        } else {
            XCTFail("\(String(describing: closers.first?.content))")
        }
        XCTAssertFalse(try kinds("\(nbsp)$$\nx^2\n$$\n").contains("math"))
        XCTAssertEqual(try kinds("Title\n\(nbsp)===\n"), ["text"])
        XCTAssertEqual(try kinds("#\(nbsp)Title\n"), ["text"])
        XCTAssertEqual(try kinds("| a | b |\n\(nbsp)|---|---|\n| 1 | 2 |\n"), ["text"])
        // Text, not an item or a rule: the characters are drawn as written.
        let blocks = try XCTUnwrap(parseReturning("\(nbsp)- item\n\npara\n\n\(nbsp)---\n\n1.\(nbsp)one\n"))
        XCTAssertEqual(blocks.map(plain), ["\(nbsp)- item", "para", "\(nbsp)---", "1.\(nbsp)one"])
        XCTAssertFalse(MarkdownRenderer.isListItem("\(nbsp)- item"))
        XCTAssertFalse(MarkdownRenderer.isListItem("1.\(nbsp)one"))
        XCTAssertFalse(MarkdownRenderer.isThematicBreak("\(nbsp)---"))
        XCTAssertFalse(MarkdownRenderer.isThematicBreak("---\(nbsp)"))
        // A link definition is not one: it stays in the text.
        let definition = try XCTUnwrap(parseReturning("[x]\n\n\(nbsp)[x]: https://example.com\n"))
        XCTAssertEqual(definition.count, 2)
        XCTAssertEqual(definition.last.flatMap(plain), "\(nbsp)[x]: https://example.com")

        // Spaces and tabs still indent every one of them.
        XCTAssertEqual(try kinds("  ```\ncode\n  ```\n"), ["code"])
        XCTAssertEqual(try kinds("Title\n  ===\n"), ["heading"])
        XCTAssertEqual(try kinds("# Title\n"), ["heading"])
        XCTAssertEqual(try kinds("#\tTitle\n"), ["heading"])
        XCTAssertEqual(try kinds("| a | b |\n |---|---|\n| 1 | 2 |\n"), ["table"])
        XCTAssertTrue(MarkdownRenderer.isListItem(" - item"))
        XCTAssertTrue(MarkdownRenderer.isListItem("1.\tone"))
        XCTAssertTrue(MarkdownRenderer.isThematicBreak(" ---\t"))
    }

    // MARK: - Quote laziness

    /// The parse in short: `q<level>:<content>` for a quote, `alert:<kind>:<body>`,
    /// `t:<shown text>`, `c:<code>`, `h:<title>`, `img`, `table`.
    private func quoteShape(_ markdown: String, file: StaticString = #filePath,
                            line: UInt = #line) throws -> [String] {
        try XCTUnwrap(parseReturning(markdown, file: file, line: line), file: file, line: line).map { block in
            switch block.content {
            case .blockquote(let content, let level): return "q\(level):\(content)"
            case .alert(let kind, let content): return "alert:\(kind.rawValue):\(content)"
            case .text(let attributed): return "t:" + String(attributed.characters)
            case .codeBlock(let code, _): return "c:\(code)"
            case .heading(_, let title, _): return "h:\(title)"
            case .image: return "img"
            case .table: return "table"
            default: return "other"
            }
        }
    }

    /// CommonMark laziness: a line without the quote marker that would be a
    /// paragraph's continuation continues the paragraph the quote ends in —
    /// in a nested quote, a list item or an alert too, and on a line with
    /// fewer markers than the quote. Our parser ended the quote and made the
    /// line a paragraph of its own. Every expected shape is GitHub's
    /// (`gh api markdown`, scratchpad/audit/gfm/lazy_*.html).
    func testALazyLineContinuesTheParagraphAQuoteEndsIn() throws {
        // Continues: a plain line, a hard-wrapped quote, `===`, an indented
        // line, an item that may not start a list here (none may: a lazy
        // line is checked against the document, not the paragraph).
        XCTAssertEqual(try quoteShape("> a\nb\n"), ["q1:a\nb"])
        XCTAssertEqual(try quoteShape("> line one\nline two\nline three\n\nAfter\n"),
                       ["q1:line one\nline two\nline three", "t:After"])
        XCTAssertEqual(try quoteShape("> a\n===\n"), ["q1:a\n==="])
        XCTAssertEqual(try quoteShape("> a\n    b\n"), ["q1:a\n    b"])
        XCTAssertEqual(try quoteShape("> a\n<span>x</span>\n").first, "q1:a\n<span>x</span>")
        XCTAssertEqual(try quoteShape("> a\nb\n> c\n"), ["q1:a\nb\nc"])
        // In a list item, a nested quote, an alert; and with fewer markers.
        XCTAssertEqual(try quoteShape("> - a\nb\n"), ["q1:- a\nb"])
        XCTAssertEqual(try quoteShape("> > a\nb\n"), ["q2:a\nb"])
        XCTAssertEqual(try quoteShape("> > a\n> b\n"), ["q2:a\nb"])
        XCTAssertEqual(try quoteShape("> > > a\n> b\n"), ["q3:a\nb"])
        XCTAssertEqual(try quoteShape("> [!NOTE]\n> text\nlazy\n"), ["alert:note:text\nlazy"])
        XCTAssertEqual(try quoteShape("> [!NOTE]\nlazy\n"), ["alert:note:lazy"])

        // Ends the quote: a blank line, an empty quote line, a block start.
        XCTAssertEqual(try quoteShape("> a\n\nb\n"), ["q1:a", "t:b"])
        XCTAssertEqual(try quoteShape("> a\n>\nb\n"), ["q1:a", "t:b"])
        XCTAssertEqual(try quoteShape("> a\n```\ncode\n```\n"), ["q1:a", "c:code"])
        XCTAssertEqual(try quoteShape("> a\n~~~\ncode\n~~~\n"), ["q1:a", "c:code"])
        XCTAssertEqual(try quoteShape("> a\n# H\n"), ["q1:a", "h:H"])
        XCTAssertEqual(try quoteShape("> a\n---\n").count, 2)
        XCTAssertEqual(try quoteShape("> a\n***\n").count, 2)
        XCTAssertEqual(try quoteShape("> a\n- b\n"), ["q1:a", "t:• b"])
        XCTAssertEqual(try quoteShape("> a\n2. b\n").first, "q1:a")
        XCTAssertEqual(try quoteShape("> a\n2. b\n").count, 2)
        XCTAssertEqual(try quoteShape("> a\n<div>x</div>\n").first, "q1:a")
        XCTAssertEqual(try quoteShape("> a\n<!-- c -->\n").first, "q1:a")
        XCTAssertEqual(try quoteShape("> > a\n> - b\n"), ["q2:a", "q1:- b"])
        // Our own block starts end it too: a picture line, `$$` (GitHub reads
        // both as the paragraph's text; here they stay the picture and the
        // formula they are everywhere else).
        XCTAssertEqual(try quoteShape("> a\n![img](x.png)\n"), ["q1:a", "img"])
        XCTAssertEqual(try quoteShape("> a\n$$\nx\n$$\n").first, "q1:a")

        // Nothing to continue: the quote does not end in a paragraph.
        XCTAssertEqual(try quoteShape("> ```\n> code\nb\n"), ["q1:```\ncode", "t:b"])
        XCTAssertEqual(try quoteShape("> # H\nb\n"), ["q1:# H", "t:b"])
        XCTAssertEqual(try quoteShape("> a\n> ===\nb\n"), ["q1:a\n===", "t:b"])
        XCTAssertEqual(try quoteShape("> | x | y |\n> |---|---|\n> | 1 | 2 |\nlazy\n"),
                       ["q1:| x | y |\n|---|---|\n| 1 | 2 |", "t:lazy"])
    }

    /// A lazy line is paragraph text, never structure: a lazy `|---|` or
    /// `===` read as a table separator or a Setext underline closed the
    /// quote's paragraph, and the NEXT lazy line fell out of the quote.
    /// GitHub keeps every one of them in the paragraph (gfm/g5_*.html).
    func testALazyLineIsNeverReadAsStructure() throws {
        XCTAssertEqual(try quoteShape("> a\n| x | y |\n|---|---|\n| 1 | 2 |\n"),
                       ["q1:a\n| x | y |\n|---|---|\n| 1 | 2 |"])
        XCTAssertEqual(try quoteShape("> a\nb\n===\nc\n"), ["q1:a\nb\n===\nc"])
        XCTAssertEqual(try quoteShape("> > a\n> ===\n> c\n"), ["q2:a\n===\nc"])
        XCTAssertEqual(try quoteShape("> > a\n> | x |\n> |---|\n> c\n"), ["q2:a\n| x |\n|---|\nc"])
        // Marked lines still are structure: a marked table, then an
        // unmarked row, ends the quote (GitHub too).
        XCTAssertEqual(try quoteShape("> | x | y |\n> |---|---|\n> | 1 | 2 |\nlazy\n"),
                       ["q1:| x | y |\n|---|---|\n| 1 | 2 |", "t:lazy"])
        XCTAssertEqual(try quoteShape("> a\n> ===\nb\n"), ["q1:a\n===", "t:b"])
    }

    // MARK: - Link and footnote definitions

    /// A definition inside a fenced code block is the block's text: the
    /// pre-pass took it out wherever it stood, so the code block came out
    /// EMPTY and the definition linked `[x]` in the rest of the document.
    /// GitHub (gfm/def_fence*.html, def_fn_fence.html) keeps it as code —
    /// `~~~`, a longer opening fence and an unclosed one alike. A `$$` block
    /// is read the way the block loop reads it.
    func testADefinitionInsideAFencedBlockIsCode() throws {
        XCTAssertEqual(try quoteShape("```\n[x]: https://example.com\n```\n\n[x]\n"),
                       ["c:[x]: https://example.com", "t:[x]"])
        XCTAssertEqual(try quoteShape("~~~~\n[x]: https://example.com\n~~~\nstill code\n~~~~\n\n[x]\n"),
                       ["c:[x]: https://example.com\n~~~\nstill code", "t:[x]"])
        XCTAssertEqual(try quoteShape("```\n[x]: https://example.com\n\n[x]"),   // unclosed: to the end
                       ["c:[x]: https://example.com\n\n[x]"])
        XCTAssertEqual(try quoteShape("Text[^1]\n\n```\n[^1]: in code\n```\n"),
                       ["t:Text[^1]", "c:[^1]: in code"])
        // A fence inside a `$$` block is the formula's; the definition after
        // the block is one.
        XCTAssertEqual(try quoteShape("$$\n```\n$$\n\n[x]: http://e.com\n\n[x]\n"), ["other", "t:x"])
        // Outside the fence it still is one.
        XCTAssertEqual(try quoteShape("```\ncode\n```\n\n[x]: http://e.com\n\n[x]\n"), ["c:code", "t:x"])
    }

    /// A link definition cannot interrupt a paragraph (CommonMark): on a
    /// line that would continue one — plain text, a list item's, a quote's
    /// lazy line, a table's — it is that text, and `[x]` stays literal.
    /// The pre-pass took it out anywhere. A footnote definition MAY
    /// interrupt a paragraph (GitHub). Every shape: gfm/def_*.html, fn_*.html.
    func testALinkDefinitionCannotInterruptAParagraph() throws {
        XCTAssertEqual(try quoteShape("> a\n[x]: http://e.com\n\n[x]\n"), ["q1:a\n[x]: http://e.com", "t:[x]"])
        XCTAssertEqual(try quoteShape("Para\n[x]: http://e.com\n\n[x]\n"), ["t:Para [x]: http://e.com", "t:[x]"])
        XCTAssertEqual(try quoteShape("- a\n[x]: http://e.com\n\n[x]\n"), ["t:• a [x]: http://e.com", "t:[x]"])
        XCTAssertEqual(try quoteShape("| a |\n|---|\n| 1 |\n[x]: http://e.com\n\n[x]\n").last, "t:[x]")
        // Where no paragraph goes on, it is a definition.
        XCTAssertEqual(try quoteShape("Para\n\n[x]: http://e.com\n\n[x]\n"), ["t:Para", "t:x"])
        XCTAssertEqual(try quoteShape("# H\n[x]: http://e.com\n\n[x]\n"), ["h:H", "t:x"])
        XCTAssertEqual(try quoteShape("---\n[x]: http://e.com\n\n[x]\n").last, "t:x")
        XCTAssertEqual(try quoteShape("Title\n===\n[x]: http://e.com\n\n[x]\n"), ["h:Title", "t:x"])
        XCTAssertEqual(try quoteShape("```\ncode\n```\n[x]: http://e.com\n\n[x]\n"), ["c:code", "t:x"])
        XCTAssertEqual(try quoteShape("[x]: http://e.com\n[y]: http://f.com\n\n[x] [y]\n"), ["t:x y"])
        XCTAssertEqual(try quoteShape("> a\n>\n[x]: http://e.com\n\n[x]\n"), ["q1:a", "t:x"])
        XCTAssertEqual(try quoteShape("> ```\n> code\n[x]: http://e.com\n\n[x]\n"), ["q1:```\ncode", "t:x"])
        // Footnote definitions interrupt a paragraph, as before.
        XCTAssertEqual(try quoteShape("Text[^1]\n\nPara\n[^1]: note\n").prefix(2), ["t:Text¹", "t:Para"])
        XCTAssertEqual(try quoteShape("Text[^1]\n\n> a\n[^1]: note\n").prefix(2), ["t:Text¹", "q1:a"])
    }

    // MARK: - Indented fences

    /// A fence indented N spaces drops up to N spaces from each of its lines
    /// (CommonMark; GitHub, gfm/b1_*.html). It kept them: every code block
    /// of a numbered-steps list was drawn, searched and copied shifted right.
    func testAnIndentedFenceDropsItsIndentationFromItsLines() throws {
        XCTAssertEqual(try quoteShape("1. Step\n\n    ```bash\n    cmd\n      nested\n    ```\n"),
                       ["t:1. Step", "c:cmd\n  nested"])
        XCTAssertEqual(try quoteShape("  ```\n code\n   code2\nflush\n  ```\n"), ["c:code\n code2\nflush"])
        XCTAssertEqual(try quoteShape("1. Step\n   ```\n   cmd\n   ```\n"), ["t:1. Step", "c:cmd"])
        XCTAssertEqual(try quoteShape("```\n  keep\n```\n"), ["c:  keep"])
        XCTAssertEqual(try quoteShape("    ~~~\n    a\n\n    b\n    ~~~\n"), ["c:a\n\nb"])
        // Search counts, and copy reads, what is drawn.
        let blocks = try XCTUnwrap(parseReturning("1. Step\n\n    ```\n    let needle = 1\n    ```\n"))
        XCTAssertEqual(DocumentSearch.computeMatches(in: blocks, term: "    let").matchBlockIds, [])
        XCTAssertEqual(DocumentSearch.computeMatches(in: blocks, term: "let needle").matchBlockIds, [blocks[1].id])
    }

    /// Source Edit finds a selection made in such a block in the source,
    /// whose lines still carry the indentation: a multi-line selection is
    /// matched with the spaces and tabs at the start of each source line
    /// skipped (a literal match finds it no longer).
    func testASelectionInAnIndentedFenceIsFoundInTheSource() {
        let source = "1. Step\n\n    ```\n    cmd\n      nested\n    ```\n" as NSString
        let range = SourceEditSupport.sourceRange(ofSelection: "cmd\n  nested", before: "", after: "",
                                                  in: source, lines: 3..<5)
        XCTAssertEqual(range.map { source.substring(with: $0) }, "cmd\n      nested")
        // A literal match wins where there is one.
        let flat = "```\ncmd\n  nested\n```\n" as NSString
        let literal = SourceEditSupport.sourceRange(ofSelection: "cmd\n  nested", before: "", after: "",
                                                    in: flat, lines: 1..<3)
        XCTAssertEqual(literal.map { flat.substring(with: $0) }, "cmd\n  nested")
    }

    // MARK: - Setext headings over a paragraph

    /// A Setext underline makes the WHOLE paragraph above it the heading
    /// (CommonMark; GitHub, gfm/g4_*.html), its lines joined like soft
    /// breaks, on the paragraph's first line. Only the last line was the
    /// heading; the lines above stayed a paragraph. A paragraph that is a
    /// list item's is no heading (its `===` goes on as text, its `---` is a
    /// rule), and a quote's lazy lines are the quote's (F6).
    func testASetextUnderlineMakesTheWholeParagraphTheHeading() throws {
        XCTAssertEqual(try quoteShape("Para one\nline two\n===\n"), ["h:Para one line two"])
        XCTAssertEqual(try quoteShape("one\ntwo\nthree\n---\n"), ["h:one two three"])
        let markdown = "Intro\n\nPara one\nline two\n---\n\nAfter\n"
        let blocks = try XCTUnwrap(parseReturning(markdown))
        XCTAssertEqual(try quoteShape(markdown), ["t:Intro", "h:Para one line two", "t:After"])
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 6])
        if case .heading(let level, _, let line) = blocks[1].content {
            XCTAssertEqual(level, 2)
            XCTAssertEqual(line, 2)
        }
        // After blocks that close a paragraph.
        XCTAssertEqual(try quoteShape("# H\nline a\nline b\n===\n"), ["h:H", "h:line a line b"])
        XCTAssertEqual(try quoteShape("```\nx\n```\nline a\nline b\n===\n"), ["c:x", "h:line a line b"])
        XCTAssertEqual(try quoteShape("***\nline a\nline b\n===\n").last, "h:line a line b")
        // A list item's paragraph is no heading.
        XCTAssertEqual(try quoteShape("- a\nb\n===\n"), ["t:• a b ==="])
        XCTAssertEqual(try quoteShape("- a\nb\n---\n").first, "t:• a b")
        XCTAssertEqual(try quoteShape("- a\nb\n---\n").count, 2)
        XCTAssertEqual(try quoteShape("Para\n- item\nb\n===\n"), ["t:Para", "t:• item b ==="])
        XCTAssertEqual(try quoteShape("1984. A year\nline\n===\n"), ["t:1984. A year line ==="])
        XCTAssertEqual(try quoteShape("> a\nb\n===\n"), ["q1:a\nb\n==="])

        // The tint spans the paragraph and its underline; Section copy
        // starts at its first line; the anchor is the whole title's.
        let ns = markdown as NSString
        let spans = SourceTint.spans(for: blocks, lineStarts: SourceEditSupport.lineStarts(in: ns), in: ns)
        XCTAssertEqual(spans.filter { $0.kind == .heading }.map { ns.substring(with: $0.range) },
                       ["Para one\nline two\n---"])
        let entries = blocks.compactMap { block -> ToCEntry? in
            guard case .heading(let level, let title, let line) = block.content else { return nil }
            return ToCEntry(id: block.id, level: level, title: title, sourceLine: line)
        }
        XCTAssertEqual(SectionExtractor.extractSection(from: markdown, entry: entries[0], headings: entries),
                       "Para one\nline two\n---\n\nAfter")
        XCTAssertEqual(HeadingAnchors.slug(entries[0].title), "para-one-line-two")
    }

    // MARK: - Long quotes

    /// A width change lays a quote or alert body out again WITHOUT rendering
    /// it: the measurer takes the string the previous measurement of the same
    /// parse built (`reusing`, the caller's `measured.converted`), as a
    /// paragraph's string is stored in its block. It rendered the body again
    /// on every width change and reading-mode toggle — a 5,000-line quote
    /// cost ~530 ms per re-measure (-O) against ~160 ms for the same text as
    /// a paragraph. The heights and the rhythm are a fresh measurement's.
    func testAWidthChangeLaysAQuoteOutAgainWithoutRenderingIt() throws {
        let long = "words that wrap at a narrow column but not at a wide one, and a few more of them"
        let markdown = "Para\n\n> \(long)\nand a lazy line\n\n> > nested \(long)\n\n"
            + "> [!NOTE]\n> \(long)\n\n> [!TIP]\n\nEnd\n"
        let blocks = try XCTUnwrap(parseReturning(markdown))
        let theme = MarkdownTheme.cached(for: .light)
        let first = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1,
                                                contentWidth: 700, math: nil)
        let again = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1,
                                                contentWidth: 260, reusing: first.converted, math: nil)
        let fresh = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1,
                                                contentWidth: 260, math: nil)
        XCTAssertNotEqual(first.table.heights, fresh.table.heights)   // the wrap moved
        XCTAssertEqual(again.table.heights, fresh.table.heights)
        XCTAssertEqual(again.rhythm, fresh.rhythm)
        let bodies = blocks.filter { block in
            switch block.content {
            case .blockquote: return true
            case .alert(_, let content): return !content.isEmpty
            default: return false
            }
        }
        XCTAssertEqual(bodies.count, 3)
        for block in bodies {
            let reused = try XCTUnwrap(again.converted[block.id], block.id)
            XCTAssertTrue(reused === first.converted[block.id], block.id)
            XCTAssertEqual(reused, fresh.converted[block.id], block.id)
        }
        // Only those: a paragraph's string is built from its block again.
        let paragraph = try XCTUnwrap(blocks.first)
        XCTAssertFalse(again.converted[paragraph.id] === first.converted[paragraph.id])
    }

    /// The lines a quote absorbed are the quote's: its source line is its
    /// first, the next block starts after them, the tint spans them, search
    /// finds and copy reads them in the quote — and a long hard-wrapped quote
    /// with a marker on its first line only parses (the hang guard) into one
    /// quote row.
    func testTheLinesAQuoteAbsorbedAreTheQuotes() throws {
        let markdown = "Intro\n\n> Quoted start\nlazy middle word\nlazy end\n\nAfter\n"
        let blocks = try XCTUnwrap(parseReturning(markdown))
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 6])
        let ns = markdown as NSString
        let spans = SourceTint.spans(for: blocks, lineStarts: SourceEditSupport.lineStarts(in: ns), in: ns)
        XCTAssertEqual(spans.map { ns.substring(with: $0.range) }, ["> Quoted start\nlazy middle word\nlazy end"])
        XCTAssertEqual(DocumentSearch.computeMatches(in: blocks, term: "middle").matchBlockIds, [blocks[1].id])
        let measured = measure(blocks)
        XCTAssertEqual(measured.converted[blocks[1].id].map(\.string), "Quoted start lazy middle word lazy end")

        let long = "> first\n" + String(repeating: "a hard-wrapped line of the quote\n", count: 5_000) + "\nAfter\n"
        let longBlocks = try XCTUnwrap(parseReturning(long, within: 10))
        XCTAssertEqual(longBlocks.count, 2)
        if case .blockquote(let content, _) = longBlocks[0].content {
            XCTAssertEqual(content.components(separatedBy: "\n").count, 5_001)
        } else {
            XCTFail("\(longBlocks[0].content)")
        }
    }

    // MARK: - Anchor signatures

    /// The scroll anchor is found again after a reload by the block's content
    /// (`anchorSignature`). A table's was its row count and header: every
    /// header-less table (blank header cells) and the front-matter properties
    /// table (no header) of the same length had the same one, so a reload
    /// could put the reader on the wrong table.
    func testHeaderlessTablesAndFrontMatterHaveDistinctAnchorSignatures() {
        let markdown = """
        ---
        title: Notes
        author: Ann
        ---

        | | |
        |---|---|
        | alpha | 1 |
        | beta | 2 |

        Between.

        | | |
        |---|---|
        | gamma | 3 |
        | delta | 4 |
        """
        let tables = parse(markdown).filter { if case .table = $0.content { return true }; return false }
        XCTAssertEqual(tables.count, 3)
        XCTAssertEqual(Set(tables.map(\.anchorSignature)).count, 3, "\(tables.map(\.anchorSignature))")
        // Stable across a re-parse, and still distinctive with an edit above.
        let again = parse("Edited above.\n\n" + markdown)
            .filter { if case .table = $0.content { return true }; return false }
        XCTAssertEqual(again.map(\.anchorSignature).suffix(2), tables.map(\.anchorSignature).suffix(2))
        // A table with a header keeps it in front.
        let headed = parse("| Name | Value |\n|---|---|\n| a | 1 |")[0]
        XCTAssertTrue(headed.anchorSignature.hasPrefix("b|1|Name\u{1F}Value\u{1F}a"), headed.anchorSignature)
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

    /// ⌘G into a block taller than the window (a big table, a long code
    /// block) used to centre the BLOCK: a match near its end stayed below the
    /// window. The match is what is centred now; a block that fits is still
    /// centred as a whole, and a step within it does not move it.
    func testASearchJumpIntoABlockTallerThanTheWindowCentresTheMatch() throws {
        let visible: CGFloat = 800
        let tall = NSRect(x: 0, y: 1000, width: 600, height: 3016)   // block 1016...4016
        let matchMidY: CGFloat = 3700

        let jump = try XCTUnwrap(RowGeometry.searchTarget(rowRect: tall, spacingAbove: 16, visibleHeight: visible,
                                                          matchMidY: matchMidY))
        XCTAssertEqual(jump.target, 3300)
        XCTAssertFalse(jump.needsMatch)
        XCTAssertTrue((jump.target...(jump.target + visible)).contains(matchMidY))
        // The old target (the block's middle) left that match off screen.
        let blockCentre = RowGeometry.centerTarget(rowRect: tall, spacingAbove: 16, visibleHeight: visible)
        XCTAssertFalse((blockCentre...(blockCentre + visible)).contains(matchMidY))

        // Stepping to another match of the same tall block moves to it.
        let step = try XCTUnwrap(RowGeometry.searchTarget(rowRect: tall, spacingAbove: 16, visibleHeight: visible,
                                                          matchMidY: 1900, withinBlock: true))
        XCTAssertEqual(step.target, 1500)

        // The match not known yet (the block's view is not on display): the
        // block first, then the match when it lands.
        let blind = try XCTUnwrap(RowGeometry.searchTarget(rowRect: tall, spacingAbove: 16, visibleHeight: visible,
                                                           matchMidY: nil))
        XCTAssertEqual(blind.target, blockCentre)
        XCTAssertTrue(blind.needsMatch)

        // A block that fits: centred as before, the match ignored; a step
        // within it does not scroll.
        let short = NSRect(x: 0, y: 100, width: 500, height: 60)
        let fits = try XCTUnwrap(RowGeometry.searchTarget(rowRect: short, spacingAbove: 20, visibleHeight: 400,
                                                          matchMidY: 150))
        XCTAssertEqual(fits.target, -60)
        XCTAssertFalse(fits.needsMatch)
        XCTAssertNil(RowGeometry.searchTarget(rowRect: short, spacingAbove: 20, visibleHeight: 400,
                                              matchMidY: 150, withinBlock: true))
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
        /// A layout switch is under way (`isSwitchingLayout`): from the
        /// style toggle to the install of the table for the new width.
        var switching = false
        /// The style toggle pins the anchor until the install (false: the
        /// rules of 4f67351, sticky anchor without the pin).
        var pinsLayoutSwitch = true
        /// Height reports that changed a row (`reportHeight` past its 0.5 pt
        /// threshold): every one is a swing of the table.
        var reports = 0

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
            if jumpTarget != nil || switching { return anchor.row }
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
            reports += 1
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
            case .shift where jumpTarget != nil || switching, .placeAnchor:
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
            switching = false
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
            switching = current && pinsLayoutSwitch
        }
        /// Something other than the list moves the clip origin.
        mutating func clipMoved(by dy: CGFloat) { contentTop += dy }
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
                             imageEstimate: CGFloat = 116, diagram: CGFloat = 94,
                             diagramEstimate: CGFloat = 224) -> [ListModel.Row] {
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
            .reported(12 * s, diagramEstimate, real: diagram + 24),                 // the diagram
            .exact(5 * s, 79 * s),                                                  // a table
            .reported(50 * s, 39 * s, real: 39 * s),                                // # Second part
        ]
        rows += (0..<12).map { _ in paragraph(25) }
        return rows
    }
    private let image = 12, textAfterFormulas = 19, secondPart = 23

    /// The debug log of the drift (`full.log`): at 819 pt every height real,
    /// the content top 11.5 pt above "Text after the formulas"; Reading Mode
    /// re-measures at 720 (the image back at its placeholder, the diagram
    /// seeded); between leaving Reading Mode and the 819 table the clip moves
    /// by -37.5 pt without the list moving it; the 819 re-measure has the
    /// image at its placeholder again. The reader comes back to the point.
    func testReadingModeRoundTripSurvivesAClipMoveDuringTheSwitch() {
        for current in [true, false] {
            var rows = fixtureRows()
            for index in rows.indices { rows[index].height = rows[index].real }
            var list = ListModel(rows: rows, contentTop: 0, current: current)
            list.contentTop = list.blockTop(textAfterFormulas) - 11.5
            list.confirmed = Set(rows.indices)
            let seen = list.screenY(textAfterFormulas)

            list.toggleStyle(inset: 48)
            list.install(fixtureRows(wrap: 2, diagramEstimate: 118))
            list.toggleStyle(inset: 24)
            list.clipMoved(by: -37.5)
            list.install(fixtureRows(diagramEstimate: 118))

            if current {
                XCTAssertEqual(list.screenY(textAfterFormulas), seen, accuracy: 1)
                XCTAssertEqual(list.contentTop - list.blockTop(textAfterFormulas), -11.5, accuracy: 0.001)
            } else {
                // Re-anchored by geometry on the latex block: 37.5 pt off.
                XCTAssertEqual(list.screenY(textAfterFormulas) - seen, 37.5, accuracy: 1)
            }
        }
    }

    /// fixture.md row by row as the app measures it (41 rows): the measurer's
    /// table at `width` (819 = the window, 720 = Reading Mode), with the two
    /// formulas as SwiftMath and the 1.14.3 fallback leave them (65 pt; a
    /// ```latex block, 21 pt above and below) and the diagram at
    /// `diagramEstimate` (224 = the default, 94 = seeded). It reproduces the
    /// debug log of the round trip to the point: table 3452 / 3322 / 3492 pt,
    /// "Second part" at 1958 / 1828 / 1998.
    private func searchFixtureRows(width: CGFloat, diagramEstimate: CGFloat) -> [ListModel.Row] {
        let wrapped: CGFloat = width < 800 ? 34 : 17      // the ordered items
        var rows: [ListModel.Row] = [
            .reported(0, 39, real: 39),                       // 0  # Rhythm fixture
            .exact(19, 17), .exact(21, 66), .exact(21, 17),   // 1-3 intro, bash, "Features:"
            .exact(25, 34),                                   // 4  the tight list
            .reported(50, 33, real: 33),                      // 5  ## Quotes
            .exact(17, 21), .exact(0, 21), .exact(0, 21),     // 6-8
            .reported(48, 33, real: 33),                      // 9  ## Loose ordered list
            .exact(19, wrapped),                              // 10
        ]
        rows += (0..<9).map { _ in .exact(25, wrapped) }      // 11-19
        rows += [
            .reported(50, 33, real: 33),                      // 20 ## Image and caption
            .reported(16, 116, real: 655),                    // 21 the image (never on screen here)
            .exact(17, 17),                                   // 22 its caption
            .reported(50, 33, real: 33),                      // 23 ## Math
            .exact(19, 17), .exact(13, 65), .exact(13, 17),   // 24-26
            .exact(21, 66),                                   // 27 the formula SwiftMath refuses
            .exact(21, 17),                                   // 28 "Text after the formulas."
            .reported(50, 33, real: 33),                      // 29 ## Diagram
            .reported(4, diagramEstimate, real: 94),          // 30 the diagram
            .exact(0, 79),                                    // 31 the table
            .reported(50, 39, real: 39),                      // 32 # Second part
            .reported(15, 29, real: 29), .reported(16, 25, real: 25),
            .exact(19, 17),                                   // 35
            .reported(50, 33, real: 33),                      // 36 ## Long list
            .exact(19, 510), .exact(0, 510), .exact(0, 170),  // 37-39
            .exact(25, 17),                                   // 40
        ]
        return rows
    }

    // MARK: - Pictures and diagrams shown once are measured exactly

    /// The fixture's picture rows as the GUI reported them (debug logs of the
    /// zoom and Reading Mode round trips): the 1024 px icon with its "QuickMD
    /// icon" caption, and the "Start → End" flowchart — by width and zoom.
    private let guiPictureRows: [(width: CGFloat, scale: CGFloat, image: CGFloat, diagram: CGFloat)] = [
        (819, 1.0, 655, 94), (819, 1.1, 716, 101), (819, 1.25, 809, 111.5), (720, 1.0, 655, 94),
    ]
    private let fixtureDiagram = "flowchart LR\n  A[Start] --> B[End]"

    /// Once the icon has been shown (its size known) and the diagram has
    /// rendered (its geometry known), the measurer gives exactly the rows the
    /// views reported in the GUI, at every width and zoom of the round trips —
    /// so no re-measure sends them back to the 116 / 224 pt placeholders and no
    /// view reports. Before the icon is known, the row is the loading view,
    /// 155 — also what the GUI reported.
    func testPicturesShownOnceAreMeasuredAsTheirViewsReportThem() throws {
        let blocks = parse("![QuickMD icon](icon.png)\n\n```mermaid\n\(fixtureDiagram)\n```")
        guard case .mermaidDiagram(let source) = blocks[1].content else { return XCTFail("not a diagram") }
        MermaidGeometryStore.set(.init(naturalWidth: 240, naturalHeight: 70, overhead: 0),
                                 source: source, isDark: theme.isDark)
        let sizes: [NSString: CGSize] = ["icon.png": CGSize(width: 1024, height: 1024)]
        for row in guiPictureRows {
            let measured = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: row.scale,
                                                       contentWidth: row.width, imageSizes: sizes, math: math)
            XCTAssertEqual(measured.table.heights[0], row.image, "image at \(row.width) × \(row.scale)")
            XCTAssertEqual(measured.table.heights[1], row.diagram, accuracy: 0.001,
                           "diagram at \(row.width) × \(row.scale)")
        }
        let unknown = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1, contentWidth: 819,
                                                  math: math)
        XCTAssertEqual(unknown.table.heights[0], 155)
        // The cache keeps image sizes across a re-parse.
        let cache = BlockHeightCache()
        cache.setImageSize(CGSize(width: 1024, height: 1024), for: "icon.png")
        cache.set(70, for: blocks[1].id)
        cache.removeAll()
        XCTAssertNil(cache.height(for: blocks[1].id))
        XCTAssertEqual(cache.imageSizesSnapshot["icon.png"], CGSize(width: 1024, height: 1024))
    }

    /// The picture rule the views frame the picture with: the 600 pt cap ×
    /// zoom within the column, never past the picture's own width × zoom or
    /// an HTML width, at its aspect ratio, whole points.
    func testAPictureIsDrawnAtTheSizeTheMeasurerUses() {
        typealias Image = BlockLayout.ImageBlock
        let icon = CGSize(width: 1024, height: 1024)
        XCTAssertEqual(Image.pictureSize(imageSize: icon, htmlWidth: nil, fontScale: 1, contentWidth: 819),
                       CGSize(width: 600, height: 600))
        XCTAssertEqual(Image.pictureSize(imageSize: icon, htmlWidth: nil, fontScale: 1.25, contentWidth: 819),
                       CGSize(width: 750, height: 750))
        XCTAssertEqual(Image.pictureSize(imageSize: icon, htmlWidth: nil, fontScale: 1.5, contentWidth: 819),
                       CGSize(width: 819, height: 819))
        XCTAssertEqual(Image.pictureSize(imageSize: CGSize(width: 90, height: 30), htmlWidth: nil, fontScale: 1.5,
                                         contentWidth: 819), CGSize(width: 135, height: 45))
        XCTAssertEqual(Image.pictureSize(imageSize: CGSize(width: 1000, height: 333), htmlWidth: nil, fontScale: 1,
                                         contentWidth: 819).height, 200)   // 199.8
        let html = Image.pictureSize(imageSize: icon, htmlWidth: .points(200), fontScale: 1.1, contentWidth: 819)
        XCTAssertEqual(html.width, 220, accuracy: 0.001)
        XCTAssertEqual(html.height, 220)
        XCTAssertEqual(Image.pictureSize(imageSize: icon, htmlWidth: .fraction(0.5), fontScale: 1,
                                         contentWidth: 819), CGSize(width: 300, height: 300))
    }

    /// The caption as the row reporter sees it — `ImageCaption` hosted in a
    /// window, its `GeometryReader` height — is the measurer's
    /// `captionHeight`, at the zoom ladder, three widths and a caption that
    /// wraps.
    func testTheCaptionIsAsTallAsTheMeasurerSays() {
        final class Box { var height: CGFloat = -1 }
        struct Probe: View {
            let caption: ImageCaption
            let box: Box
            var body: some View {
                VStack(alignment: .leading, spacing: 0) { caption }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { box.height = proxy.size.height }
                            .onChange(of: proxy.size.height) { box.height = $0 }
                    })
            }
        }
        let captions = ["QuickMD icon",
                        String(repeating: "A longer caption that wraps onto several lines in a narrow column. ",
                               count: 4)]
        for scale: CGFloat in [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 3] {
            for width: CGFloat in [819, 720, 300] {
                for alt in captions {
                    let box = Box()
                    let caption = ImageCaption(alt: alt, color: .secondary, fontScale: scale, contentWidth: width)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let host = NSHostingView(rootView: Probe(caption: caption, box: box))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(box.height,
                                   BlockLayout.ImageBlock.captionHeight(alt: alt, fontScale: scale, contentWidth: width),
                                   "\(alt.prefix(12)) at \(width) × \(scale)")
                    window.close()
                }
            }
        }
    }

    /// An SVG's size is known from its markup: the measurer decodes it once
    /// (cached for the view, which then never shows the loading view on a
    /// re-created row) and sizes the row as the view draws it. Markup that
    /// does not decode stays at the loading view and reports.
    func testAnSVGIsMeasuredAtItsDecodedSize() {
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\"/></svg>"
        let blocks = parse("```svg\n\(markup)\n```")
        guard case .svgImage(let source) = blocks[0].content else { return XCTFail("not an SVG block") }
        let pad = 2 * BlockLayout.Document.imageOuterVerticalPadding
        for (scale, width, picture) in [(1.0, 819.0, 100.0), (1.5, 819.0, 150.0), (1.0, 150.0, 75.0)] as [(CGFloat, CGFloat, CGFloat)] {
            let measured = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: scale,
                                                       contentWidth: width, math: math)
            XCTAssertEqual(measured.table.heights[0], picture + pad, "at \(width) × \(scale)")
        }
        XCTAssertNotNil(SVGImageDecoder.cachedImage(source))
        XCTAssertEqual(SVGImageDecoder.cachedSize(source), CGSize(width: 200, height: 100))
        let broken = parse("```svg\n<svg this is not svg\n```")
        let measured = BlockHeightMeasurer.measure(blocks: broken, theme: theme, fontScale: 1, contentWidth: 819,
                                                   math: math)
        XCTAssertEqual(measured.table.heights[0], BlockLayout.ImageBlock.placeholderHeight + pad)
    }

    /// A diagram's height at any width and zoom from the geometry its web view
    /// posted — the template's own formula: × zoom while it fits, never wider
    /// than the view, plus the page's overhead. No floor (1.14.4 had 50 pt).
    func testADiagramsHeightFollowsTheTemplatesFormula() {
        typealias Mermaid = BlockLayout.Mermaid
        let small = Mermaid.Geometry(naturalWidth: 240, naturalHeight: 70, overhead: 0)
        XCTAssertEqual(Mermaid.diagramHeight(small, fontScale: 1.25, contentWidth: 819), 87.5)
        XCTAssertEqual(Mermaid.diagramHeight(small, fontScale: 0.5, contentWidth: 819), 35)
        // A flat diagram in a narrow column: fitted to 120 of 480 px.
        let flat = Mermaid.Geometry(naturalWidth: 480, naturalHeight: 100, overhead: 0)
        XCTAssertEqual(Mermaid.diagramHeight(flat, fontScale: 1, contentWidth: 120), 25)
        let wide = Mermaid.Geometry(naturalWidth: 1600, naturalHeight: 400, overhead: 4)
        XCTAssertEqual(Mermaid.diagramHeight(wide, fontScale: 1, contentWidth: 800), 204)     // fitted: 0.5
        XCTAssertEqual(Mermaid.diagramHeight(wide, fontScale: 1.5, contentWidth: 800), 204)   // still fitted
        XCTAssertEqual(Mermaid.diagramHeight(wide, fontScale: 0.5, contentWidth: 800), 104)   // 0.5 × fitted
        XCTAssertEqual(Mermaid.diagramHeight(wide, fontScale: 1, contentWidth: 800.7), 204)   // innerWidth: whole px
        // Never rendered: the measurer's default, and nothing in the store.
        XCTAssertNil(MermaidGeometryStore.geometry(source: "graph TD; Never-->Rendered", isDark: false))
    }

    /// What the row takes from the height the web view reports: a diagram
    /// that rendered is as tall as it is — the 25 pt flat one stayed 50 pt
    /// tall in 1.14.4, 25 pt of it blank, and the measurer (exact since the
    /// placeholder fix) and the view disagreed. A failed render (Mermaid's
    /// error text) keeps a minimum; a report of nothing is not taken.
    func testARenderedDiagramTakesItsReportedHeightExactly() {
        typealias Mermaid = BlockLayout.Mermaid
        XCTAssertEqual(Mermaid.acceptedHeight(reported: 25, rendered: true), 25)
        XCTAssertEqual(Mermaid.acceptedHeight(reported: 87.5, rendered: true), 87.5)
        XCTAssertNil(Mermaid.acceptedHeight(reported: 0, rendered: true))
        XCTAssertNil(Mermaid.acceptedHeight(reported: .nan, rendered: true))
        XCTAssertEqual(Mermaid.acceptedHeight(reported: 31, rendered: false), Mermaid.failedRenderMinimumHeight)
        XCTAssertEqual(Mermaid.acceptedHeight(reported: 0, rendered: false), Mermaid.failedRenderMinimumHeight)
        XCTAssertEqual(Mermaid.acceptedHeight(reported: 120, rendered: false), 120)
        // The view and the measurer agree on a flat diagram.
        let flat = Mermaid.Geometry(naturalWidth: 480, naturalHeight: 100, overhead: 0)
        XCTAssertEqual(Mermaid.acceptedHeight(reported: 25, rendered: true),
                       Mermaid.diagramHeight(flat, fontScale: 1, contentWidth: 120))
    }

    /// A diagram view without a snapshot at its zoom and width finds the
    /// latest one of the same diagram in the same theme as its stand-in, so a
    /// re-created row never shows the empty box the web view is for the half
    /// second it takes to render (seen while recording). Another diagram, or
    /// the other theme, has none; the exact key and the PDF exporter's key
    /// are untouched.
    func testADiagramWithoutASnapshotOfItsOwnFindsTheLatestOneAsAStandIn() {
        let diagram = "flowchart LR\n  Stand-->In"
        let image = NSImage(size: NSSize(width: 240, height: 70))
        MermaidSnapshotStore.set(image, source: "1.0|819.0|\(diagram)", isDark: false)
        MermaidSnapshotStore.setLatest(image, diagram: diagram, isDark: false)
        XCTAssertNil(MermaidSnapshotStore.image(source: "1.25|819.0|\(diagram)", isDark: false))
        XCTAssertTrue(MermaidSnapshotStore.latest(diagram: diagram, isDark: false) === image)
        XCTAssertNil(MermaidSnapshotStore.latest(diagram: diagram, isDark: true))
        XCTAssertNil(MermaidSnapshotStore.latest(diagram: "flowchart LR\n  Other-->Diagram", isDark: false))
        XCTAssertNil(MermaidSnapshotStore.image(source: diagram, isDark: false))
        XCTAssertTrue(MermaidSnapshotStore.image(source: "1.0|819.0|\(diagram)", isDark: false) === image)
    }

    /// The zoom round trip and the Reading Mode round trip with the reader in
    /// the image, the rows as the measurer now gives them: no height report at
    /// all (the table never swings) and the reader back on the very point. The
    /// control, with the 116 / 224 pt placeholders every re-measure used to
    /// start from, reports on every step.
    func testRoundTripsWithPicturesShownOnceNeverSwingTheTable() throws {
        let blocks = parse("![QuickMD icon](icon.png)\n\n```mermaid\n\(fixtureDiagram)\n```")
        guard case .mermaidDiagram(let source) = blocks[1].content else { return XCTFail("not a diagram") }
        MermaidGeometryStore.set(.init(naturalWidth: 240, naturalHeight: 70, overhead: 0),
                                 source: source, isDark: theme.isDark)
        let sizes: [NSString: CGSize] = ["icon.png": CGSize(width: 1024, height: 1024)]
        func rows(width: CGFloat, scale: CGFloat, measured: Bool) -> [ListModel.Row] {
            let gui = guiPictureRows.first { $0.width == width && $0.scale == scale }!
            let table = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: scale,
                                                    contentWidth: width, imageSizes: sizes, math: math).table
            return fixtureRows(scale: scale, wrap: width < 800 ? 2 : 1, imageReal: gui.image,
                               imageEstimate: measured ? table.heights[0] : 116,
                               diagram: gui.diagram - 24, diagramEstimate: measured ? table.heights[1] : 224)
        }
        for measured in [true, false] {
            var start = rows(width: 819, scale: 1, measured: true)
            for index in start.indices { start[index].height = start[index].real }
            var list = ListModel(rows: start, contentTop: 0)
            list.contentTop = list.blockTop(image) + 300
            let top = list.contentTop
            for scale: CGFloat in [1.1, 1.25, 1.1, 1] {
                list.install(rows(width: 819, scale: scale, measured: measured))
            }
            list.toggleStyle(inset: 48)
            list.install(rows(width: 720, scale: 1, measured: measured))
            list.toggleStyle(inset: 24)
            list.install(rows(width: 819, scale: 1, measured: measured))
            if measured {
                XCTAssertEqual(list.reports, 0)
                XCTAssertEqual(list.contentTop, top, accuracy: 0.001)
            } else {
                XCTAssertGreaterThanOrEqual(list.reports, 6)
            }
        }
    }

    /// The failing GUI run (f1dbg.log), step by step: ⌘F "Second part" and a
    /// zoom round trip left the anchor on the H1 at -351.5 with the diagram
    /// still at its default; it reports 94 and the content top shifts to
    /// 1476.5. Reading Mode on (1452.5), the 720 table (1622.5), Reading Mode
    /// off (1646.5) — then, before the 819 table, the latex row's text view
    /// re-lays out under the top inset and AppKit scrolls the document by
    /// -24.5 pt (now prevented: `DocumentCellTextView`). The pin must hold
    /// whatever moves the clip. The reader must come
    /// back to row 32 at -351.5, the very point it left.
    func testReadingModeRoundTripFromASearchJumpLandsWhereItLeft() {
        let secondPart = 32
        for pins in [true, false] {
            var list = ListModel(rows: searchFixtureRows(width: 819, diagramEstimate: 224), contentTop: 0)
            list.pinsLayoutSwitch = pins
            list.contentTop = list.blockTop(secondPart) - 351.5
            list.anchor = (secondPart, -351.5, -351.5)
            XCTAssertEqual(list.contentTop, 1606.5)
            list.settle()
            XCTAssertEqual(list.contentTop, 1476.5)
            let seen = list.screenY(secondPart)

            list.toggleStyle(inset: 48)
            XCTAssertEqual(list.contentTop, 1452.5)
            list.install(searchFixtureRows(width: 720, diagramEstimate: 94))
            XCTAssertEqual(list.contentTop, 1622.5)
            list.toggleStyle(inset: 24)
            XCTAssertEqual(list.contentTop, 1646.5)
            list.clipMoved(by: -24.5)
            list.install(searchFixtureRows(width: 819, diagramEstimate: 94))

            if pins {
                XCTAssertEqual(list.anchor?.row, secondPart)
                XCTAssertEqual(list.anchor?.offset, -351.5)
                XCTAssertEqual(list.contentTop, 1476.5)
                XCTAssertEqual(list.screenY(secondPart), seen, accuracy: 0.001)
            } else {
                // The log, to the point: re-captured by geometry as "row 27 +
                // 38" in the 720 table and restored at 1452.0, 24.5 pt off.
                XCTAssertEqual(list.anchor?.row, 27)
                XCTAssertEqual(list.anchor?.offset, 38)
                XCTAssertEqual(list.contentTop, 1452.0)
                XCTAssertEqual(list.screenY(secondPart) - seen, 24.5, accuracy: 0.001)
            }
        }
    }

    /// The -24.5 / -37.5 pt itself: AppKit's NSTextView keeps its visible part
    /// visible while it resizes (`_setFrameSize:forceScroll:` →
    /// `scrollRectToVisible:`), and a text view lying in the list's top content
    /// inset is visible to it but not to `scrollRectToVisible:` — every width
    /// change scrolled the document until that text sat at the content top.
    /// `DocumentCellTextView` (the base of `SelfSizingTextView`) never scrolls
    /// on a frame change; a plain NSTextView in the same place still does (the
    /// control), and an explicit request still scrolls.
    func testATextRowUnderTheTopInsetDoesNotScrollTheDocumentWhenItResizes() {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        func clipMove(_ textView: NSTextView, _ change: (NSTextView) -> Void) -> CGFloat {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 24, left: 0, bottom: 24, right: 0)
            let document = Flipped(frame: NSRect(x: 0, y: 0, width: 800, height: 5000))
            scrollView.documentView = document
            window.contentView = scrollView
            // The latex row's text: its top 0.5 pt below the clip's top edge,
            // all of it inside the 24 pt inset (content top 1067.5).
            textView.configureForSelfSizing()
            textView.frame = NSRect(x: 20, y: 1044, width: 700, height: 17)
            textView.textStorage?.setAttributedString(NSAttributedString(string: "V(e_1) \\not\\le V(e_2)"))
            document.addSubview(textView)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1043.5))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.layoutSubtreeIfNeeded()
            let before = scrollView.contentView.bounds.origin.y
            change(textView)
            scrollView.layoutSubtreeIfNeeded()
            return scrollView.contentView.bounds.origin.y - before
        }
        let wider = { (view: NSTextView) in view.setFrameSize(NSSize(width: 790, height: 17)) }
        let reframed = { (view: NSTextView) in view.frame = NSRect(x: 20, y: 1044, width: 300, height: 34) }

        XCTAssertEqual(clipMove(NSTextView(), wider), -23.5, accuracy: 0.5, "the control: AppKit scrolls")
        XCTAssertEqual(clipMove(DocumentCellTextView(), wider), 0)
        XCTAssertEqual(clipMove(DocumentCellTextView(), reframed), 0)
        XCTAssertNotEqual(clipMove(DocumentCellTextView()) { _ = $0.scrollToVisible($0.bounds) }, 0)
    }

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

    // MARK: - Reading column follows the zoom

    /// Reading mode's column is 720 pt at 100 % and scales with the text, in
    /// whole points; the window still caps it. 1.14.4 kept 720 at every zoom:
    /// ~45 characters a line at 200 %.
    func testTheReadingColumnScalesWithTheZoom() {
        typealias Document = BlockLayout.Document
        XCTAssertEqual(Document.readingColumnCap(fontScale: 1), 720)
        XCTAssertEqual(Document.readingColumnCap(fontScale: 2), 1440)
        XCTAssertEqual(Document.readingColumnCap(fontScale: 0.5), 360)
        XCTAssertEqual(Document.readingColumnCap(fontScale: 3), 2160)
        XCTAssertEqual(Document.readingColumnCap(fontScale: 1.1), 792)   // 792.0000000000001
        // 200 %: the full 1440 where the window has room, the window otherwise.
        XCTAssertEqual(Document.columnWidth(inner: 1600 - 64, cap: Document.readingColumnCap(fontScale: 2)), 1440)
        XCTAssertEqual(Document.columnWidth(inner: 1000 - 64, cap: Document.readingColumnCap(fontScale: 2)), 936)
        XCTAssertEqual(Document.columnWidth(inner: 1000 - 64, cap: Document.readingColumnCap(fontScale: 1)), 720)
        XCTAssertEqual(Document.columnWidth(inner: 935.5, cap: nil), 935.5)
        XCTAssertEqual(Document.columnWidth(inner: -10, cap: 720), 0)
    }

    /// A zoom in reading mode re-parses; the parse is measured at the column
    /// the zoom's cap gives — the width the list publishes once the parse is
    /// installed with that cap — so the zoomed text is laid out at the width
    /// its heights were measured at, measured once per zoom.
    func testAZoomInReadingModeMeasuresItsParseAtTheNewColumn() {
        typealias Document = BlockLayout.Document
        let blocks = parse(String(repeating: "A line of prose that wraps in every column it is given. ", count: 12))
        for inner: CGFloat in [1600 - 64, 1000 - 64] {
            for scale: CGFloat in [0.5, 1, 1.5, 2, 3] {
                let column = Document.columnWidth(inner: inner, cap: Document.readingColumnCap(fontScale: scale))
                let width = Document.parseWidth(contentWidth: 720, inner: inner, readingFontScale: scale)
                XCTAssertEqual(width, column, "inner \(inner) × \(scale)")
                XCTAssertEqual(measure(blocks, fontScale: scale, width: width).table.contentWidth, column)
            }
        }
        // The standard layout: the list's width, whatever the zoom.
        XCTAssertEqual(Document.parseWidth(contentWidth: 936, inner: 936, readingFontScale: nil), 936)
        // No layout yet, or the list not wired: nothing to derive from.
        XCTAssertEqual(Document.parseWidth(contentWidth: 0, inner: 1536, readingFontScale: 2), 0)
        XCTAssertEqual(Document.parseWidth(contentWidth: 720, inner: 0, readingFontScale: 2), 720)
    }

    /// ⌘+ ⌘+ ⌘− ⌘− in reading mode with the viewport top inside the image:
    /// every zoom is a style change (the cap) AND a new table, in one
    /// update — the reader comes back to the very same point, as in the
    /// standard layout.
    func testAZoomRoundTripInReadingModeKeepsAReaderInsideAnImage() {
        var rows = fixtureRows(wrap: 2, imageReal: 576)
        for index in rows.indices { rows[index].height = rows[index].real }   // every view reported
        var list = ListModel(rows: rows, contentTop: 0)
        list.inset = 48
        list.contentTop = list.blockTop(image) + 520   // its bottom 56 pt on screen
        let start = list.contentTop
        XCTAssertEqual(list.rowUnderContentTop(), image)
        for scale: CGFloat in [1.1, 1.25, 1.1, 1] {
            list.toggleStyle(inset: 48)
            list.install(fixtureRows(scale: scale, wrap: 2, imageReal: min(655, 576 * scale)))
            XCTAssertEqual(list.rowUnderContentTop(), image, "× \(scale)")
        }
        XCTAssertEqual(list.contentTop, start, accuracy: 0.001)
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
            PrintRhythm.row(for: $0.element, renderer: renderer, width: 532)
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

    private func printBlocks(_ blocks: [(CGFloat, CGFloat, Bool)]) -> [PrintRhythm.Block] {
        blocks.map { PrintRhythm.Block(height: $0.0, spacingAbove: $0.1, keepsWithNext: $0.2) }
    }
    private func placed(_ slices: [PrintRhythm.Slice]) -> [String] {
        slices.map { "\($0.block)@\($0.page):\(Int($0.y))" + ($0.offset > 0 || $0.height < 0 ? "+\(Int($0.offset))" : "") }
    }

    func testPaginationDropsTheSpaceAtAPageTop() {
        let slices = PrintRhythm.paginate(printBlocks([(100, 0, false), (50, 30, false), (600, 30, false),
                                                       (40, 30, false), (710, 30, false)]),
                                          pageHeight: 700)
        XCTAssertEqual(placed(slices), [
            "0@0:0",
            "1@0:130",
            "2@1:0",          // 180 + 30 + 600 > 700: new page, no space above
            "3@1:630",        // 600 + 30 + 40 = 670 fits
            "4@2:0",          // taller than a page: a page per slice
            "4@3:0+700",
        ])
        XCTAssertEqual(slices.map(\.height), [100, 50, 600, 40, 700, 10])
    }

    /// Orbit.md on Letter: `## Configuration` ended page 1 and its table
    /// started page 2.
    func testAHeadingMovesWithTheBlockThatStartsTheNextPage() {
        let slices = PrintRhythm.paginate(printBlocks([(600, 0, false), (30, 50, true), (79, 20, false)]),
                                          pageHeight: 700)
        XCTAssertEqual(placed(slices), ["0@0:0", "1@1:0", "2@1:50"])
    }

    func testAHeadingChainMovesTogether() {
        let slices = PrintRhythm.paginate(printBlocks([(560, 0, false), (30, 50, true), (25, 15, true),
                                                       (100, 20, false), (17, 25, false)]),
                                          pageHeight: 700)
        XCTAssertEqual(placed(slices), ["0@0:0", "1@1:0", "2@1:45", "3@1:90", "4@1:215"])
    }

    func testAHeadingStaysWhenItCannotShareAPageWithTheNextBlock() {
        // 30 + 20 + 690 > 700: moving the heading would only orphan it on
        // the next page.
        let slices = PrintRhythm.paginate(printBlocks([(600, 0, false), (30, 50, true), (690, 20, false)]),
                                          pageHeight: 700)
        XCTAssertEqual(placed(slices), ["0@0:0", "1@0:650", "2@1:0"])
        // A heading that already starts its page is never moved (no loop).
        let top = PrintRhythm.paginate(printBlocks([(30, 0, true), (690, 20, false), (17, 25, false)]),
                                       pageHeight: 700)
        XCTAssertEqual(placed(top), ["0@0:0", "1@1:0", "2@2:0"])
    }

    func testAHeadingKeepsWithTheFirstSliceOfABlockTallerThanAPage() {
        // Room below the heading: the first slice fills the rest of its page.
        let roomy = PrintRhythm.paginate(printBlocks([(300, 0, false), (30, 50, true), (1500, 20, false)]),
                                         pageHeight: 700)
        XCTAssertEqual(placed(roomy), ["0@0:0", "1@0:350", "2@0:400", "2@1:0+300", "2@2:0+1000"])
        XCTAssertEqual(roomy.map(\.height), [300, 30, 300, 700, 500])
        // No room: the heading moves, the first slice fills the rest of the
        // new page, and every slice is placed exactly once.
        let full = PrintRhythm.paginate(printBlocks([(600, 0, false), (30, 50, true), (1500, 20, false)]),
                                        pageHeight: 700)
        XCTAssertEqual(placed(full), ["0@0:0", "1@1:0", "2@1:50", "2@2:0+650", "2@3:0+1350"])
        XCTAssertEqual(full.filter { $0.block == 2 }.map(\.height).reduce(0, +), 1500)
    }

}
