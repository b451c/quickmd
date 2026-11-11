import XCTest
import SwiftUI
import AppKit

/// v1.15 roadmap items 2 + 3: formulas in quotes, alerts, table cells and
/// headings, typeset as in paragraphs — one string for the view, the
/// measurer, selection, copy and search.
///
/// Expected values come from GitHub's renderer (`gh api markdown -f mode=gfm`,
/// 2026-11-11); the HTML GitHub gave is quoted next to each case. SwiftMath is
/// not compiled into this target, so a recording stub engine stands in: it
/// tells what was typeset, at which size, and draws a box of a known size
/// (`tallSize` for `\frac` / `\sum`, which have limits, else `smallSize`).
///
/// Most tests use only APIs that existed before v1.15 (parse, `measure`,
/// `measureMathRows`, search, copy), so they compile and FAIL on the base —
/// the negative control.
final class MathInTextKindsTests: XCTestCase {

    private var theme: MarkdownTheme { MarkdownTheme.cached(for: .light) }

    static let smallSize = NSSize(width: 20, height: 12)
    static let tallSize = NSSize(width: 30, height: 44)
    /// Wider than any column or quote used here: a long matrix.
    static let wideSize = NSSize(width: 900, height: 60)

    /// What the stub engine was asked for.
    final class Recorder {
        var calls: [(latex: String, size: CGFloat, isDark: Bool)] = []
        var latex: [String] { calls.map(\.latex) }
    }

    private func engine(_ recorder: Recorder = Recorder(), typesets: Bool = true) -> MathRendering {
        MathRendering(inlineImage: { latex, theme, size in
            recorder.calls.append((latex, size, theme.isDark))
            guard typesets else { return nil }
            if latex.contains("matrix") { return NSImage(size: Self.wideSize) }
            let tall = latex.contains("\\frac") || latex.contains("\\sum")
            return NSImage(size: tall ? Self.tallSize : Self.smallSize)
        }, displayHeight: { _, _, _ in 40 })
    }

    private func parse(_ markdown: String, theme: MarkdownTheme? = nil, fontScale: CGFloat = 1) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: theme ?? self.theme, fontScale: fontScale).parse(markdown)
    }

    /// The app's two-step measurement: off-main without the engine, then the
    /// deferred rows on the main actor with it.
    @MainActor
    private func measure(_ blocks: [MarkdownBlock], math: MathRendering, width: CGFloat = 600,
                         theme: MarkdownTheme? = nil, fontScale: CGFloat = 1) -> MeasuredBlocks {
        let theme = theme ?? self.theme
        let raw = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: fontScale,
                                              contentWidth: width, math: nil)
        return BlockHeightMeasurer.measureMathRows(raw.mathPendingRows, in: raw, blocks: blocks, theme: theme,
                                                   fontScale: fontScale, contentWidth: width, math: math)
    }

    private func attachments(in string: NSAttributedString) -> Int {
        var count = 0
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    // MARK: - Quotes and alerts

    /// GitHub: `<blockquote><p>Quote with <math-renderer class="js-inline-math">$x^2$</math-renderer> inline.</p>`
    @MainActor
    func testQuoteInlineFormulaIsTypesetAndCopiesAsItsSource() {
        let recorder = Recorder()
        let blocks = parse("> Quote with $x^2$ inline.")
        let measured = measure(blocks, math: engine(recorder))
        let shown = measured.converted[blocks[0].id]
        XCTAssertEqual(shown?.string, "Quote with \u{FFFC} inline.")
        XCTAssertEqual(recorder.latex, ["x^2"])
        XCTAssertEqual(recorder.calls.first?.size, 14, "body size")
        // Copy: the formula is its source, `$` delimiters included — as a paragraph copies.
        XCTAssertEqual(DocumentCopyBuilder.build([.text(shown ?? NSAttributedString())]).plain,
                       "Quote with $x^2$ inline.")
    }

    /// GitHub: `<blockquote><p><math-renderer class="js-display-math">$$\n\frac{a}{b}\n$$</math-renderer></p>`
    /// and `$$a+b$$` alone in a quote paragraph is display math too.
    @MainActor
    func testQuoteDisplayFormulaIsItsOwnCentredLine() {
        let recorder = Recorder()
        let blocks = parse("""
        > Before
        >
        > $$
        > \\frac{a}{b}
        > $$
        >
        > $$a+b$$
        """)
        let measured = measure(blocks, math: engine(recorder))
        let shown = measured.converted[blocks[0].id] ?? NSAttributedString()
        XCTAssertEqual(shown.string, "Before\n \n\u{FFFC}\n \n\u{FFFC}")
        XCTAssertEqual(recorder.latex, ["\\frac{a}{b}", "a+b"])
        XCTAssertEqual(recorder.calls.map(\.size), [20, 20], "display size, as a $$ block")
        let formula = (shown.string as NSString).range(of: "\u{FFFC}")
        let style = shown.attribute(.paragraphStyle, at: formula.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
        XCTAssertEqual(DocumentCopyBuilder.build([.text(shown)]).plain,
                       "Before\n\n$$\n\\frac{a}{b}\n$$\n\n$$\na+b\n$$")
    }

    /// GitHub keeps these as text: a `$$` that shares its paragraph with text
    /// (`<p>Before<br>$$E=mc^2$$<br>after</p>` is inline math on GitHub, see
    /// the report — the segmenter never pairs `$$`), prices, an escaped `$`.
    @MainActor
    func testDollarsThatAreNoFormulaStayTextInAQuote() {
        let recorder = Recorder()
        let cases: [(String, String)] = [
            ("> Text line\n> $$\n> \\sum_{i=1}^n i\n> $$", "Text line $$ \\sum_{i=1}^n i $$"),
            ("> $$\n> x\n> $$\n> after", "$$ x $$ after"),
            ("> price $5 and $10", "price $5 and $10"),
            ("> cost \\$y\\$ here", "cost $y$ here"),
            ("> code `$x$` span", "code $x$ span"),
        ]
        for (markdown, expected) in cases {
            let blocks = parse(markdown)
            let shown = measure(blocks, math: engine(recorder)).converted[blocks[0].id]
            XCTAssertEqual(shown?.string, expected, markdown)
            XCTAssertEqual(attachments(in: shown ?? NSAttributedString()), 0, markdown)
        }
        XCTAssertEqual(recorder.latex, [], "nothing was typeset")
    }

    /// GitHub: `<p>code <code>$x$</code> span and <math-renderer class="js-inline-math">$y$</math-renderer></p>`
    /// — the same in a quote. A code span's `$` was typeset as a formula in
    /// paragraphs before v1.15 (the segmenter reads the rendered text).
    @MainActor
    func testCodeSpanDollarsAreNoFormulaInParagraphsAndQuotes() {
        let recorder = Recorder()
        let blocks = parse("code `$x$` span and $y$\n\n> quote `$x$` and $y$")
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(measured.converted[blocks[0].id]?.string, "code $x$ span and \u{FFFC}")
        XCTAssertEqual(measured.converted[blocks[1].id]?.string, "quote $x$ and \u{FFFC}")
        XCTAssertEqual(recorder.latex, ["y", "y"])
    }

    /// GitHub: `<p>Alert <math-renderer class="js-inline-math">$\alpha$</math-renderer> and<br>$$<br>\sum…$$</p>`
    /// — inline math typeset, the `$$` lines in the same paragraph are text.
    @MainActor
    func testAlertBodyTypesetsItsFormulas() {
        let recorder = Recorder()
        let blocks = parse("""
        > [!NOTE]
        > Alert $\\alpha$ and
        > $$
        > \\sum_{i=1}^n i
        > $$
        >
        > $$\\frac{1}{2}$$
        """)
        guard case .alert = blocks[0].content else { return XCTFail("not an alert") }
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(measured.converted[blocks[0].id]?.string,
                       "Alert \u{FFFC} and $$ \\sum_{i=1}^n i $$\n \n\u{FFFC}")
        XCTAssertEqual(recorder.latex, ["\\alpha", "\\frac{1}{2}"])
    }

    /// A `$` closing a paragraph must not pair with one opening the next.
    @MainActor
    func testQuoteFormulaNeverSpansTwoParagraphs() {
        let recorder = Recorder()
        let blocks = parse("> a $b\n>\n> c$ d and $e$")
        let shown = measure(blocks, math: engine(recorder)).converted[blocks[0].id]
        XCTAssertEqual(shown?.string, "a $b\n \nc$ d and \u{FFFC}")
        XCTAssertEqual(recorder.latex, ["e"])
    }

    /// The quote row is `.exact`: its height is the converted string laid
    /// out at the body width, the tall formula included.
    @MainActor
    func testQuoteHeightIncludesTheFormula() {
        let blocks = parse("> $$\\sum_{i=1}^n i$$")
        let measured = measure(blocks, math: engine())
        let shown = measured.converted[blocks[0].id] ?? NSAttributedString()
        let width = BlockLayout.Quote.bodyWidth(contentWidth: 600, level: 1)
        XCTAssertEqual(measured.table.kinds, [.exact])
        XCTAssertEqual(measured.table.heights[0],
                       BlockHeightMeasurer.textInk(text: shown, width: width).height
                        + 2 * BlockLayout.Quote.verticalPadding, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(BlockHeightMeasurer.exactHeight(text: shown, width: width), Self.tallSize.height)
    }

    // MARK: - Headings

    /// GitHub: `<h1>Heading <math-renderer class="js-inline-math">$x^2$</math-renderer> here</h1>`,
    /// Setext too. Formulas at the heading's size.
    @MainActor
    func testHeadingFormulasAreTypesetAtTheHeadingSize() {
        let recorder = Recorder()
        let blocks = parse("""
        # Heading $x^2$ here

        Setext $\\alpha$ title
        ===

        ### Price $5 and $10
        """)
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(measured.converted[blocks[0].id]?.string, "Heading \u{FFFC} here")
        XCTAssertEqual(measured.converted[blocks[1].id]?.string, "Setext \u{FFFC} title")
        XCTAssertEqual(measured.converted[blocks[2].id]?.string, "Price $5 and $10")
        XCTAssertEqual(recorder.calls.map(\.latex), ["x^2", "\\alpha"])
        XCTAssertEqual(recorder.calls.map(\.size), [32, 32], "the H1 size")
    }

    /// Ids are GitHub's (`gh api markdown -f mode=markdown`):
    /// `id="user-content-heading-x2-here"`, `fracab-sum`, `ab-and--end`,
    /// `mixed-alpha_1-bold-end`, `price-5-and-10` — taken from the formula's
    /// SOURCE, which the Contents sidebar shows too.
    func testHeadingIdsAndContentsReadTheFormulaSource() {
        let blocks = parse("""
        # Heading $x^2$ here

        ## $\\frac{a}{b}$ sum

        #### $a\\,b$ and \\% end

        #### Mixed $\\alpha_1$ **bold** end

        ### Price $5 and $10
        """)
        let renderer = MarkdownRenderer(theme: theme, fontScale: 1)
        let headings = HeadingAnchors.headings(of: blocks, renderer: renderer)
        XCTAssertEqual(HeadingAnchors.ids(for: headings.map(\.text)),
                       ["heading-x2-here", "fracab-sum", "ab-and--end", "mixed-alpha_1-bold-end", "price-5-and-10"])
        let contents = ToCEntry.entries(of: blocks).map { $0.shownTitle(renderer: renderer) }
        XCTAssertEqual(contents.first, "Heading $x^2$ here", "the sidebar lists the source")
    }

    // MARK: - Tables

    /// GitHub: `<td><math-renderer class="js-inline-math">$a | b$</math-renderer></td>` for `$a \| b$`
    /// (the escaped pipe stays in the cell), and `$|x|$` SPLITS the cell
    /// (`<td>$</td>`, the rest beyond the column count dropped).
    @MainActor
    func testTableCellFormulasFollowGitHubsPipes() {
        let recorder = Recorder()
        let blocks = parse("""
        | A | B |
        |---|---|
        | $a \\| b$ | $|x|$ |
        | $\\frac{1}{2}$ | price $5 and $10 |
        | `$x$` | \\$y\\$ |
        """)
        let measured = measure(blocks, math: engine(recorder))
        let table = measured.tables[blocks[0].id]
        XCTAssertEqual(table?.string.string, "A\nB\n\u{FFFC}\n$\n\u{FFFC}\nprice $5 and $10\n$x$\n$y$\n")
        XCTAssertEqual(recorder.latex, ["a | b", "\\frac{1}{2}"])
        XCTAssertEqual(recorder.calls.first?.size, 14)
    }

    /// The table row is `.exact` and built on the main actor once it has a
    /// formula: measured height == the height the table takes laid out in a
    /// text view configured as `TableTextView` — and its drawn bottom — with a
    /// TALL formula (limits) making its band taller than a text line.
    @MainActor
    func testTableWithTallFormulaMeasuredHeightEqualsDrawnHeight() {
        let markdown = """
        | Name | Value |
        |---|---|
        | half | $\\frac{1}{2}$ |
        | sum | $\\sum_{i=1}^{n} i$ |
        | plain | text |
        """
        for scale in [CGFloat(1), 1.5] {
            let blocks = parse(markdown, fontScale: scale)
            for width in [CGFloat(300), 700] {
                let raw = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: scale,
                                                      contentWidth: width, math: nil)
                XCTAssertEqual(raw.mathPendingRows, [0], "a table with formulas is built on main")
                XCTAssertNil(raw.tables[blocks[0].id])
                let measured = BlockHeightMeasurer.measureMathRows(raw.mathPendingRows, in: raw, blocks: blocks,
                                                                   theme: theme, fontScale: scale,
                                                                   contentWidth: width, math: engine())
                guard let table = measured.tables[blocks[0].id] else { return XCTFail("no table") }
                XCTAssertEqual(measured.table.kinds, [.exact])
                let row = measured.table.heights[0] - 2 * BlockLayout.Document.tableOuterVerticalPadding

                let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
                textView.configureForSelfSizing()
                textView.installDocumentSelectionLayoutManager()
                textView.textStorage?.setAttributedString(table.string)
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                let live = TableTextBuilder.tableHeight(layoutManager: textView.layoutManager!,
                                                        container: textView.textContainer!)
                let tag = "@\(Int(width)) ×\(scale)"
                XCTAssertEqual(row, live, tag)
                let last = textView.tableCellBounds(band: table.layout.bandCount - 1, column: 0, layout: table.layout)
                XCTAssertEqual(live, ceil(last?.maxY ?? 0), tag)
                // The sum's band holds the 44 pt formula plus the cell padding.
                let sumBand = textView.tableCellBounds(band: 2, column: 1, layout: table.layout)
                XCTAssertGreaterThanOrEqual(sumBand?.height ?? 0,
                                            Self.tallSize.height + 2 * BlockLayout.Table.cellVerticalPadding, tag)
            }
        }
    }

    /// Whole-table and cross-cell copy: a formula is its source (`$…$`), as
    /// in a paragraph; the drawn string holds its attachment.
    @MainActor
    func testTableCopyWritesFormulaSources() {
        let blocks = parse("""
        | A | B |
        |---|---|
        | $\\frac{1}{2}$ | x $y$ z |
        """)
        guard let table = measure(blocks, math: engine()).tables[blocks[0].id] else { return XCTFail("no table") }
        XCTAssertEqual(attachments(in: table.string), 2)
        let whole = SelectionRows.tablePiece(table, covered: NSRange(location: 0, length: table.string.length))
        XCTAssertEqual(whole.map { DocumentCopyBuilder.build([$0]).plain }, "A\tB\n$\\frac{1}{2}$\tx $y$ z")
        let cells = table.layout.cellRanges
        let across = NSRange(location: cells[1][0].location, length: NSMaxRange(cells[1][1]) - cells[1][0].location)
        XCTAssertEqual(SelectionRows.tablePiece(table, covered: across).map { DocumentCopyBuilder.build([$0]).plain },
                       "$\\frac{1}{2}$\tx $y$ z")
        let inOne = NSRange(location: cells[1][1].location, length: cells[1][1].length)
        XCTAssertEqual(SelectionRows.tablePiece(table, covered: inOne).map { DocumentCopyBuilder.build([$0]).plain },
                       "x $y$ z")
    }

    // MARK: - Search

    /// The paragraphs' rule everywhere (constraints.md "Search counts what
    /// the views SHOW"): a typeset formula is one attachment character — its
    /// LaTeX is neither counted nor highlighted; the text around it is. The
    /// count is the same on the measured strings and on search's own
    /// fallback construction.
    @MainActor
    func testSearchCountsWhatTheViewsShowAroundFormulas() {
        let blocks = parse("""
        > quote $x^2$ word

        > [!TIP]
        > alert $x^2$ word

        # heading $x^2$ word

        | a |
        |---|
        | cell $x^2$ word |
        """)
        let measured = measure(blocks, math: engine())
        for term in ["x^2", "word", "$"] {
            let onMeasured = DocumentSearch.computeMatches(in: blocks, term: term, converted: measured.converted,
                                                           tables: measured.tables, theme: theme)
            let fallback = DocumentSearch.computeMatches(in: blocks, term: term)
            XCTAssertEqual(onMeasured.matchBlockIds, fallback.matchBlockIds, term)
            XCTAssertEqual(onMeasured.matchBlockIds.count, term == "word" ? 4 : 0, term)
        }
    }

    // MARK: - Fallback, zoom, theme

    /// A formula the engine cannot typeset shows its source (1.14.3): inline
    /// as the italic literal, as in a paragraph; a display formula as its
    /// LaTeX in the code font, as a `$$` block becomes a ```latex block.
    @MainActor
    func testUntypesettableFormulasShowTheirSource() {
        let blocks = parse("> inline $\\not\\le$ here\n>\n> $$\\not\\le$$\n\n# H $\\not\\le$\n\n| a |\n|---|\n| $\\not\\le$ |")
        let measured = measure(blocks, math: engine(typesets: false))
        let quote = measured.converted[blocks[0].id] ?? NSAttributedString()
        XCTAssertEqual(quote.string, "inline \\not\\le here\n \n\\not\\le")
        let display = (quote.string as NSString).range(of: "\\not\\le", options: .backwards)
        let font = quote.attribute(.font, at: display.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false, "code font")
        XCTAssertEqual(measured.converted[blocks[1].id]?.string, "H \\not\\le")
        XCTAssertEqual(measured.tables[blocks[2].id]?.string.string, "a\n\\not\\le\n")
    }

    /// Zoom scales the formulas with the text; a dark theme reaches the
    /// engine (it draws in the theme's text colour).
    @MainActor
    func testZoomAndThemeReachTheEngine() {
        let recorder = Recorder()
        let dark = MarkdownTheme.cached(for: .dark)
        let markdown = "> q $a$\n\n## h $b$\n\n| c |\n|---|\n| $d$ |"
        let blocks = parse(markdown, theme: dark, fontScale: 1.5)
        _ = measure(blocks, math: engine(recorder), theme: dark, fontScale: 1.5)
        XCTAssertEqual(recorder.calls.map(\.latex), ["a", "b", "d"])
        XCTAssertEqual(recorder.calls.map(\.size), [21, 39, 21], "14 × 1.5, H2 26 × 1.5, 14 × 1.5")
        XCTAssertEqual(recorder.calls.map(\.isDark), [true, true, true])
    }

    // MARK: - Review fixes (2026-11-11)

    /// The one segmenter follows GitHub's delimiter rules — every expected
    /// value from `gh api markdown -f mode=gfm` (scratch gh/case6-11.html):
    /// `<p>p1 $HOME/$USER end</p>`, `<p>p2 $5-$10 end</p>`,
    /// `<p>p3 $a$1 end</p>`, `<p>p13 $a$_ end</p>`, `<p>t1 $a$b c$ end</p>`,
    /// `<p>p8 x$a$ end</p>`, `<p>p15 é$a$ end</p>`, `<p>q1 -$a$ end</p>`,
    /// `<p>p21 a$$x$$b</p>`, `<p>n8 $$a$</p>` — text;
    /// `<M>$a$</M>é`, `(<M>$a$</M>)`, `<M>$a$</M>.`, `<M>$a$</M>$b$`,
    /// `$a <M>$b$</M>`, `<M>$5$</M>`, `<M>$1.5$</M>`,
    /// `text <M>$$x$$</M> more`, `$$a$$b <M>$$c$$</M>` — math.
    func testSegmenterFollowsGitHubsDelimiterRules() {
        func formulas(_ text: String) -> [String] {
            InlineMathSegmenter.split(text).compactMap { if case .math(let latex) = $0 { return latex } else { return nil } }
        }
        let text = ["$HOME/$USER end", "$5-$10 end", "$a$1 end", "$a$b end", "$a$_ end", "$\\alpha$x",
                    "$a$b c$ end", "$a$b$c$ end", "x$a$ end", "1$a$ end", "é$a$ end", "€$a$ end", "-$a$ end",
                    "\"$a$\" end", ".$a$ end", "/$a$ end", ":$a$ end", "[$a$] end", "$ a$ end", "$a $ end",
                    "a$$x$$b", "$$x$$1 end", "1$$x$$ end", "$$a$ end", "$$ x $$ mid", "$5 and $10 end",
                    "$x\ny$ end"]
        for case_ in text { XCTAssertEqual(formulas(case_), [], case_) }
        let math: [(String, [String])] = [
            ("$a$é end", ["a"]), ("($a$) end", ["a"]), ("$a$. end", ["a"]), ("$a$, end", ["a"]),
            ("$a$) end", ["a"]), ("$a$-b end", ["a"]), ("$a$'s end", ["a"]), ("$a$€ end", ["a"]),
            ("$a$$ end", ["a"]), ("$a$$b$ end", ["a"]), ("$a$$$b$$", ["a"]), ("$a $b$ end", ["b"]),
            ("$a$b $c$ end", ["c"]), ("x$a$ $b$ end", ["b"]), ("$HOME/$USER and $x$ end", ["x"]),
            ("$5-$10 and $y$", ["y"]), ("$5$ end", ["5"]), ("$1,000$ end", ["1,000"]), ("$1.5$ end", ["1.5"]),
            ("text $$x$$ more", ["x"]), ("$$x$$ more", ["x"]), ("$$a$$b $$c$$", ["c"]),
            ("$5 or $x$ end", ["x"]), ("tab\t$a$ end", ["a"]), ("$a$/b end", ["a"]), ("$a$! end", ["a"]),
        ]
        for (case_, expected) in math { XCTAssertEqual(formulas(case_), expected, case_) }
        // The "needs the engine" test is the segmenter's own answer.
        XCTAssertFalse(BlockTextConverter.containsInlineMath("$5 and $10"))
        XCTAssertFalse(BlockTextConverter.containsInlineMath("$HOME/$USER"))
        XCTAssertTrue(BlockTextConverter.containsInlineMath("a $x$ b"))
    }

    /// Prices and shell variables in a cell, quote, alert or heading are no
    /// formula on GitHub (`<td>$HOME/$USER</td><td>$5-$10</td>`,
    /// `<h1>Env $HOME/$USER and $5-$10</h1>`,
    /// `<blockquote><p>Path $HOME/$USER costs $5-$10</p>`): shown as text,
    /// and their rows are measured — tables built — off the main actor,
    /// exactly as in 1.14.4.
    @MainActor
    func testPricesAndShellVariablesAreTextAndNotDeferred() {
        let recorder = Recorder()
        let blocks = parse("""
        | A | B |
        |---|---|
        | $HOME/$USER | $5-$10 |
        | $5 and $10 | $a$1 |

        # Env $HOME/$USER and $5-$10

        > Path $HOME/$USER costs $5-$10

        > [!TIP]
        > $5 and $10
        """)
        let raw = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1, contentWidth: 600, math: nil)
        XCTAssertEqual(raw.mathPendingRows, [], "nothing to typeset, nothing deferred")
        XCTAssertEqual(raw.tables[blocks[0].id]?.string.string, "A\nB\n$HOME/$USER\n$5-$10\n$5 and $10\n$a$1\n")
        XCTAssertEqual(raw.converted[blocks[1].id]?.string, "Env $HOME/$USER and $5-$10")
        XCTAssertEqual(raw.converted[blocks[2].id]?.string, "Path $HOME/$USER costs $5-$10")
        XCTAssertEqual(raw.converted[blocks[3].id]?.string, "$5 and $10")
        _ = measure(blocks, math: engine(recorder))
        XCTAssertEqual(recorder.latex, [])
        // Paragraphs follow the same rule (they shared the defect before).
        let paragraph = parse("Set $HOME/$USER, pay $5-$10.")
        XCTAssertEqual(BlockHeightMeasurer.measure(blocks: paragraph, theme: theme, fontScale: 1,
                                                   contentWidth: 600, math: nil).mathPendingRows, [])
    }

    /// `$$…$$` that shares its paragraph with text is an INLINE formula on
    /// GitHub, in every kind: `<p>para <M>$$v$$</M> inline</p>`,
    /// `<blockquote><p>Text <M>$$x$$</M> more</p>`,
    /// `<blockquote><p><M>$$y$$</M><br>after</p>`, `<td><M>$$z$$</M></td>`,
    /// `<td>in <M>$$w$$</M> cell</td>`. It copies back with `$$`.
    @MainActor
    func testInTextDoubleDollarIsInlineMathEverywhere() {
        let recorder = Recorder()
        let blocks = parse("""
        para $$v$$ inline

        > Text $$x$$ more

        > $$y$$
        > after

        | A | B |
        |---|---|
        | $$z$$ | in $$w$$ cell |
        """)
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(measured.converted[blocks[0].id]?.string, "para \u{FFFC} inline")
        XCTAssertEqual(measured.converted[blocks[1].id]?.string, "Text \u{FFFC} more")
        XCTAssertEqual(measured.converted[blocks[2].id]?.string, "\u{FFFC} after")
        XCTAssertEqual(measured.tables[blocks[3].id]?.string.string, "A\nB\n\u{FFFC}\nin \u{FFFC} cell\n")
        XCTAssertEqual(recorder.latex, ["v", "x", "y", "z", "w"])
        XCTAssertEqual(recorder.calls.map(\.size), [14, 14, 14, 14, 14], "inline size")
        XCTAssertEqual(DocumentCopyBuilder.build([.text(measured.converted[blocks[1].id]!)]).plain, "Text $$x$$ more")
    }

    /// A display formula in a quote keeps the air a `$$` block keeps around
    /// its formula — `BlockLayout.Math.verticalPadding`, as paragraph spacing
    /// of its own line, so the measured height includes it.
    @MainActor
    func testQuoteDisplayFormulaHasTheMathBlockAir() {
        let blocks = parse("> above\n>\n> $$\\sum_{i=1}^n i$$\n>\n> below")
        let shown = measure(blocks, math: engine()).converted[blocks[0].id] ?? NSAttributedString()
        let at = (shown.string as NSString).range(of: "\u{FFFC}").location
        let style = shown.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacingBefore, BlockLayout.Math.verticalPadding)
        XCTAssertEqual(style?.paragraphSpacing, BlockLayout.Math.verticalPadding)
        let width = BlockLayout.Quote.bodyWidth(contentWidth: 600, level: 1)
        let tight = NSMutableAttributedString(attributedString: shown)
        let plain = NSMutableParagraphStyle()
        plain.alignment = .center
        tight.addAttribute(.paragraphStyle, value: plain, range: NSRange(location: at, length: 1))
        XCTAssertEqual(BlockHeightMeasurer.exactHeight(text: shown, width: width)
                        - BlockHeightMeasurer.exactHeight(text: tight, width: width),
                       2 * BlockLayout.Math.verticalPadding, accuracy: 0.5, "the air is laid out, so measured")
    }

    /// A formula wider than its line — a long matrix in a narrow table column
    /// or quote — is scaled down to the line's width (an attachment cannot
    /// wrap): it never reaches into the neighbouring cell, and the table's
    /// measured height is still its drawn height.
    @MainActor
    func testWideFormulaIsScaledToFitItsCellAndLine() {
        let blocks = parse("""
        | A | B | C |
        |---|---|---|
        | x | $\\begin{matrix} a & b \\end{matrix}$ | y |

        > $\\begin{matrix} c \\end{matrix}$
        """)
        let width: CGFloat = 400
        let measured = measure(blocks, math: engine(), width: width)
        guard let table = measured.tables[blocks[0].id] else { return XCTFail("no table") }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.textStorage?.setAttributedString(table.string)
        let layoutManager = textView.layoutManager!
        layoutManager.ensureLayout(for: textView.textContainer!)
        let cell = table.layout.cellRanges[1][1]
        let cellBounds = textView.tableCellBounds(band: 1, column: 1, layout: table.layout) ?? .zero
        let glyphs = layoutManager.glyphRange(forCharacterRange: cell, actualCharacterRange: nil)
        let drawn = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
        XCTAssertGreaterThan(drawn.width, 0)
        XCTAssertLessThanOrEqual(drawn.maxX, cellBounds.maxX + 0.5, "inside its cell: \(drawn) in \(cellBounds)")
        XCTAssertGreaterThanOrEqual(drawn.minX, cellBounds.minX - 0.5)
        XCTAssertEqual(measured.table.heights[0] - 2 * BlockLayout.Document.tableOuterVerticalPadding,
                       TableTextBuilder.tableHeight(layoutManager: layoutManager, container: textView.textContainer!))

        let quote = measured.converted[blocks[1].id] ?? NSAttributedString()
        let quoteWidth = BlockLayout.Quote.bodyWidth(contentWidth: width, level: 1)
        let storage = NSTextStorage(attributedString: quote)
        let quoteLayout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: quoteWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        quoteLayout.addTextContainer(container)
        storage.addLayoutManager(quoteLayout)
        let formula = quoteLayout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        // Scaled with its aspect to the quote's width: 900×60 → w × 60·w/900.
        XCTAssertEqual(formula.width, floor(quoteWidth), accuracy: 0.5, "fills, never exceeds, the quote's width")
        XCTAssertEqual(formula.height, 60 * floor(quoteWidth) / 900, accuracy: 0.5)
    }

    // MARK: - What a quote body is made of (new API)

    /// `quotedBodyLines` — the screen and print share it. Without `$$` it is
    /// exactly the soft-break join.
    func testQuotedBodyLines() {
        typealias Line = MarkdownRenderer.QuotedBodyLine
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines("$$\n\\frac{a}{b}\n$$"), [.displayMath(latex: "\\frac{a}{b}")])
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines("$$ a + b $$"), [.displayMath(latex: "a + b")])
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines("$$a$$\n$$b$$"),
                       [.displayMath(latex: "a"), .displayMath(latex: "b")], "GitHub: two display formulas")
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines("$$\n\\begin{matrix} a \\\\\nb \\end{matrix}\n$$"),
                       [.displayMath(latex: "\\begin{matrix} a \\\\\nb \\end{matrix}")], "a LaTeX \\\\ is no hard break")
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines("Before\n$$E=mc^2$$\nafter"), [.text("Before $$E=mc^2$$ after")])
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines("$$$$"), [.text("$$$$")])
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines("text\n\n$$\nz\n$$\n\nmore"),
                       [.text("text"), .blank, .displayMath(latex: "z"), .blank, .text("more")])
        let plain = "one\ntwo  \nthree\n\n- item\nlazy"
        XCTAssertEqual(MarkdownRenderer.quotedBodyLines(plain),
                       MarkdownRenderer.joinSoftBreaks(plain.components(separatedBy: "\n"))
                           .map { MarkdownRenderer.isBlankLine($0) ? Line.blank : Line.text($0) })
    }
}
