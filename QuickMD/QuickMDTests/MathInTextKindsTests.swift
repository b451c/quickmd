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
    /// Wider than a ~370 pt line, but not twice as wide.
    static let longSize = NSSize(width: 500, height: 40)

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
            if latex.contains("long") { return NSImage(size: Self.longSize) }
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
    /// paragraphs before v1.15 (the segmenter read the rendered text).
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

    /// The one segmenter (v1.15, the owner's rule set): the OPENING side as
    /// in 1.14.4 (any unescaped `$` may open), the CLOSING side as GitHub
    /// (the next `$`; a letter, digit or `_` right after it in the source
    /// means no formula). GitHub's output from `gh api markdown -f mode=gfm`
    /// (scratch gh/case6-13.html).
    ///
    /// TEXT (GitHub agrees): `<p>u1 US$5 and US$6</p>`, `<p>u2 cost:$5, tax:$2</p>`,
    /// `<p>u3 "$FOO" "$BAR"</p>`, `<p>u4 '$1' '$2'</p>`, `<p>u5 echo "$a" "$b"</p>`,
    /// `<p>u6 :$PATH:$HOME:</p>`, `<p>u7 =$A$1</p>`, `<p>u8 ($5)($6)</p>`,
    /// `<p>u9 $5/$6</p>`, `<p>u10 $5–$6</p>`, `<p>u11 |$5|$6|</p>`,
    /// `<p>u12 a$b$c</p>`, `<p>u13 Prices: $5; $6.</p>`,
    /// `<p>u14 PS1="$USER@$HOST"</p>`, `<p>u16 $1 $2 $3</p>`,
    /// `<p>u17 price is $5.</p>`, `<p>p1 $HOME/$USER end</p>`, `<p>p2 $5-$10 end</p>`,
    /// `<p>m9 a $x$s and $n$th</p>`, `<p>t1 $a$b c$ end</p>`, `<p>n8 $$a$</p>`.
    /// `${VAR} and $(cmd) $(cmd2)` is text here; GitHub typesets
    /// `<M>${VAR} and $</M>` — its own false positive, not followed.
    ///
    /// MATH as in 1.14.4, TEXT on GitHub (its opener must follow white space
    /// or `(`; the owner keeps 1.14.4's opener): `<p>m1 中文$x$中文</p>`,
    /// `<p>m2 —$x$</p>`, `<p>m3 :$x$</p>`, `<p>m4 =$x$</p>`, `<p>m5 "$x$"</p>`,
    /// `<p>m6 '$x$'</p>`, `<p>m7 [$x$]</p>`, `<p>m8 |$x$|</p>`, NBSP / U+3000
    /// before the `$`.
    ///
    /// MATH (GitHub agrees): `<M>$a$</M>é`, `(<M>$a$</M>)`, `<M>$a$</M>.`,
    /// `<M>$5$</M>`, `<M>$1.5$</M>`, `text <M>$$x$$</M> more`,
    /// `$a <M>$b$</M>`, `$HOME/$USER and <M>$x$</M>`.
    func testSegmenterKeeps1144OpenersAndGitHubsClosers() {
        func formulas(_ text: String) -> [String] {
            InlineMathSegmenter.split(text).compactMap { if case .math(let latex) = $0 { return latex } else { return nil } }
        }
        let text = ["$HOME/$USER", "$5-$10", "$5 and $10", "US$5 and US$6", "cost:$5, tax:$2",
                    "\"$FOO\" \"$BAR\"", "'$1' '$2'", "echo \"$a\" \"$b\"", ":$PATH:$HOME:", "=$A$1",
                    "($5)($6)", "$5/$6", "$5–$6", "|$5|$6|", "a$b$c", "Prices: $5; $6.", "PS1=\"$USER@$HOST\"",
                    "${VAR}", "$(cmd) $(cmd2)", "${VAR} and $(cmd) $(cmd2)", "$1 $2 $3", "price is $5.",
                    "$a$1 end", "$a$_ end", "$a$b c$ end", "a $x$s and $n$th", "$ a$ end",
                    "$a $ end", "$$a$ end", "$$ x $$ mid", "$x\ny$ end", "$$x$$1 end",
                    "x $$a$b$$ y", "$$$x$$$", "and $$$x$$$ end"]
        for case_ in text { XCTAssertEqual(formulas(case_), [], case_) }
        let math: [(String, [String])] = [
            // 1.14.4's openers.
            ("中文$x$中文", ["x"]), ("—$x$", ["x"]), (":$x$", ["x"]), ("=$x$", ["x"]), ("\"$x$\"", ["x"]),
            ("'$x$'", ["x"]), ("[$x$]", ["x"]), ("|$x$|", ["x"]), ("a\u{00A0}$x$", ["x"]),
            ("a\u{3000}$x$", ["x"]), ("x$a$ end", ["a"]), ("é$a$ end", ["a"]),
            // GitHub and 1.14.4 agree.
            ("$a$é end", ["a"]), ("($a$) end", ["a"]), ("$a$. end", ["a"]), ("$a$, end", ["a"]),
            ("$a$) end", ["a"]), ("$a$-b end", ["a"]), ("$a$'s end", ["a"]), ("$a$$ end", ["a"]),
            ("$a$$b$ end", ["a", "b"]), ("$a $b$ end", ["b"]), ("$HOME/$USER and $x$ end", ["x"]),
            ("$5-$10 and $y$", ["y"]), ("$5 or $x$ end", ["x"]), ("$5$ end", ["5"]), ("$1.5$ end", ["1.5"]),
            ("text $$x$$ more", ["x"]), ("$$x$$ more", ["x"]), ("tab\t$a$ end", ["a"]),
        ]
        for (case_, expected) in math { XCTAssertEqual(formulas(case_), expected, case_) }
        // Scientific notation glued to words (the owner's call): a formula
        // that can only be LaTeX closes before a letter or digit — 1.14.4
        // typeset these; GitHub shows them as text (case17.html). Shell and
        // Makefile variables stay text.
        let scientific: [(String, [String])] = [
            ("H$_2$O", ["_2"]), ("CO$_2$", ["_2"]), ("x$^2$y", ["^2"]), ("10$^{-3}$m", ["^{-3}"]),
            ("2$\\times$3", ["\\times"]), ("$\\alpha$1", ["\\alpha"]), ("$\\alpha$x", ["\\alpha"]),
            ("echo $_ and $x", []), ("$^ $@", []), ("$_FOO$BAR", []), ("$^FOO$BAR", []), ("$_$x", []),
            ("$_{a}b$c", []), ("$\\$x", []), ("$5$th", []),
        ]
        for (case_, expected) in scientific { XCTAssertEqual(formulas(case_), expected, case_) }
        // The same through the renderer (run boundaries from real rendering):
        // plain text renders as ONE run, so nothing above changes.
        let renderer = MarkdownRenderer(theme: theme, fontScale: 1)
        func rendered(_ text: String) -> [String] {
            InlineMathSegmenter.pieces(of: renderer.renderInline(text)).compactMap {
                if case .math(let latex) = $0.segment { return latex } else { return nil }
            }
        }
        for case_ in text where !case_.contains("\\") && !case_.contains("\n") {
            XCTAssertEqual(rendered(case_), [], "rendered: " + case_)
        }
        for (case_, expected) in math { XCTAssertEqual(rendered(case_), expected, "rendered: " + case_) }
        // The "needs the engine" test is the segmenter's own answer.
        XCTAssertFalse(BlockTextConverter.containsInlineMath("$5 and $10"))
        XCTAssertFalse(BlockTextConverter.containsInlineMath("$HOME/$USER"))
        XCTAssertTrue(BlockTextConverter.containsInlineMath("a $x$ b"))
    }

    /// Markup after a closer is no letter (formulas are found on the
    /// source, where the markup still is): GitHub
    /// (`gh api`, case12) `<M>$x$</M><strong>bold</strong>`,
    /// `<M>$x$</M><a href="https://e.com">l</a>`, `<M>$x$</M><sup>2</sup>`,
    /// `<M>$x$</M><code>c</code>` — all formulas (and in 1.14.4). A formula
    /// never spans a link's edge: `<a>$a</a> b$`, `$q <a>b$</a>` are text.
    /// Emphasis around a formula: GitHub `<strong><M>$b$</M></strong>`,
    /// `<strong><M>$d$</M></strong>` (math), `<em>$a$</em>`, `<em>$c$</em>`
    /// (TEXT: GitHub's opener rule sees the `*`/`_`); QuickMD keeps all four
    /// as formulas (1.14.4's opener).
    @MainActor
    func testMarkupBoundariesAndLinkEdges() {
        let recorder = Recorder()
        let blocks = parse("""
        $x$**bold** $y$[l](https://e.com) $z$<sup>2</sup> $w$`c`

        [$a](https://e.com) b$ and $q [b$](https://e.com)

        *$e$* and **$f$** and _$g$_ and __$h$__ and [$i$](https://e.com)
        """)
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(recorder.latex, ["x", "y", "z", "w", "e", "f", "g", "h", "i"])
        XCTAssertEqual(measured.converted[blocks[1].id]?.string, "$a b$ and $q b$")
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

    /// Lays `string` out in a TextKit 1 stack `width` wide, as the views do.
    private func layout(_ string: NSAttributedString,
                        width: CGFloat) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) {
        let storage = NSTextStorage(attributedString: string)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return (storage, layoutManager, container)
    }

    private func glyphRect(of character: String, in string: NSAttributedString,
                           _ stack: (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer)) -> CGRect {
        let range = (string.string as NSString).range(of: character)
        let glyphs = stack.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return withExtendedLifetime(stack.storage) { stack.manager.boundingRect(forGlyphRange: glyphs, in: stack.container) }
    }

    /// A formula wider than its line (an attachment cannot wrap) is scaled
    /// down to the line — the line minus the paragraph's indents — but never
    /// below 50 %: then it shows its SOURCE (as an untypesettable formula of
    /// its kind does), wrapped to the line, as one box. Never past the line,
    /// never into the neighbouring cell; measured height == drawn height.
    @MainActor
    func testWideFormulaFitsItsLineOrShowsItsSource() {
        let width: CGFloat = 400
        let blocks = parse("""
        | A | B | C |
        |---|---|---|
        | x | $\\begin{matrix} a & b \\end{matrix}$ | y |

        > $\\long\\sum_{i=1}^n i$

        - item
          - nested $\\long x$ here
        """)
        let measured = measure(blocks, math: engine(), width: width)

        // Table: 900 pt in a ~130 pt cell is under 50 % → the source, in the cell.
        guard let table = measured.tables[blocks[0].id] else { return XCTFail("no table") }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.textStorage?.setAttributedString(table.string)
        let layoutManager = textView.layoutManager!
        layoutManager.ensureLayout(for: textView.textContainer!)
        let cell = table.layout.cellRanges[1][1]
        let cellBounds = textView.tableCellBounds(band: 1, column: 1, layout: table.layout) ?? .zero
        let drawn = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: cell,
                                                                                      actualCharacterRange: nil),
                                               in: textView.textContainer!)
        XCTAssertGreaterThan(drawn.width, 0)
        XCTAssertLessThanOrEqual(drawn.maxX, cellBounds.maxX + 0.5, "inside its cell: \(drawn) in \(cellBounds)")
        XCTAssertGreaterThanOrEqual(drawn.minX, cellBounds.minX - 0.5)
        XCTAssertGreaterThanOrEqual(drawn.height, 2 * 17, "the source wraps onto several lines in a narrow cell")
        XCTAssertEqual(measured.table.heights[0] - 2 * BlockLayout.Document.tableOuterVerticalPadding,
                       TableTextBuilder.tableHeight(layoutManager: layoutManager, container: textView.textContainer!))

        // Quote: 500 pt on a ~373 pt line is ≥ 50 % → scaled to the line exactly.
        let quote = measured.converted[blocks[1].id] ?? NSAttributedString()
        let quoteWidth = BlockLayout.Quote.bodyWidth(contentWidth: width, level: 1)
        let formula = glyphRect(of: "\u{FFFC}", in: quote, layout(quote, width: quoteWidth))
        XCTAssertEqual(formula.width, floor(quoteWidth), accuracy: 0.5)
        XCTAssertEqual(formula.height, 40 * floor(quoteWidth) / 500, accuracy: 0.5, "aspect kept")

        // Nested list item: the line is the column minus the item's indent.
        guard case .text(let attributed) = blocks[2].content else { return XCTFail("list") }
        let list = measured.converted[blocks[2].id] ?? NSAttributedString()
        XCTAssertNotNil(attributed)
        let inList = glyphRect(of: "\u{FFFC}", in: list, layout(list, width: width))
        XCTAssertGreaterThan(inList.minX, 0, "indented")
        XCTAssertLessThanOrEqual(inList.maxX, width + 0.5, "ends at the right edge: \(inList)")
        XCTAssertGreaterThan(inList.width, 0.5 * Self.longSize.width - 1, "scaled, not replaced")
    }

    /// The 50 % floor itself.
    func testFittingFloorIsHalfTheNaturalSize() {
        XCTAssertFalse(FittingMathAttachment.showsSource(width: 300, availableWidth: 300))
        XCTAssertFalse(FittingMathAttachment.showsSource(width: 600, availableWidth: 300))
        XCTAssertTrue(FittingMathAttachment.showsSource(width: 601, availableWidth: 300))
        XCTAssertEqual(FittingMathAttachment.bounds(for: NSSize(width: 600, height: 40), capHeight: 10,
                                                    availableWidth: 300).size, NSSize(width: 300, height: 20))
    }

    /// Two display formulas in a row inside a quote are ONE padding apart
    /// (the first's spacing after), not two.
    @MainActor
    func testConsecutiveDisplayFormulasShareTheirAir() {
        let blocks = parse("> $$a$$\n> $$b$$")
        let shown = measure(blocks, math: engine()).converted[blocks[0].id] ?? NSAttributedString()
        XCTAssertEqual(shown.string, "\u{FFFC}\n\u{FFFC}")
        let first = shown.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let second = shown.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(first?.paragraphSpacingBefore, BlockLayout.Math.verticalPadding)
        XCTAssertEqual(second?.paragraphSpacingBefore, 0)
        XCTAssertEqual(second?.paragraphSpacing, BlockLayout.Math.verticalPadding)
    }

    /// `# H $a\$b$`: an escaped dollar inside a heading formula stays in its
    /// LaTeX (as in a paragraph) — the title is split twice (renderHeader,
    /// then the view), so the escape must survive the first split.
    @MainActor
    func testHeadingFormulaKeepsAnEscapedDollar() {
        let recorder = Recorder()
        let blocks = parse("# H $a\\$b$ end\n\nPara $a\\$b$ end")
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(measured.converted[blocks[0].id]?.string, "H \u{FFFC} end")
        XCTAssertEqual(recorder.latex, ["a\\$b", "a\\$b"])
    }

    /// The parser: a line that STARTS with `$$x$$` and goes on with text is a
    /// paragraph with an inline formula (GitHub, case12:
    /// `<p><M>$$x$$</M> text after</p>`) — until v1.15 it opened a `$$`
    /// block that swallowed every line up to the next lone `$$`. Neighbours
    /// unchanged: `$$y$$` alone is a display block (`<D>$$y$$</D>`), `$$` ⏎
    /// `z` ⏎ `$$` too; an opening `$$u` closed by `v$$ more` is text
    /// (`<p>$$u<br>v$$ more</p>`); `text $$w$$` is a paragraph
    /// (`<p>text <M>$$w$$</M></p>`); an unclosed `$$` no longer swallows the
    /// rest of the document.
    func testDoubleDollarLineWithTextAfterIsAParagraph() {
        let blocks = parse("""
        Intro.

        $$x$$ text after

        Next para.

        $$y$$

        $$
        z
        $$

        $$u
        v$$ more

        Last.

        text $$w$$

        $$p
        q$$

        $$
        never closed

        End.
        """)
        func describe(_ block: MarkdownBlock) -> String {
            switch block.content {
            case .text(let attributed): return "text:" + String(attributed.characters)
            case .mathBlock(let latex): return "math:" + latex
            default: return "other"
            }
        }
        XCTAssertEqual(blocks.map(describe), [
            "text:Intro.", "text:$$x$$ text after", "text:Next para.", "math:y", "math:z",
            "text:$$u v$$ more", "text:Last.", "text:text $$w$$", "math:p\nq", "text:$$ never closed",
            "text:End.",
        ])
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 4, 6, 8, 12, 15, 17, 19, 22, 25])
    }

    // MARK: - Final review (2026-11-11)

    /// An unclosed `$$` above a fence whose code holds `$$` (`kill $$`): the
    /// look-ahead stops at the fence. GitHub (case15):
    /// `<p>$$<br>x</p><pre><code>code $$</code></pre><p>rest</p>`.
    func testUnclosedDoubleDollarStopsAtAFence() {
        for fence in ["```", "~~~"] {
            let blocks = parse("$$\nx\n\(fence)\ncode $$\n\(fence)\n\nrest")
            let shape = blocks.map { block -> String in
                switch block.content {
                case .text(let attributed): return "text:" + String(attributed.characters)
                case .codeBlock(let code, _): return "code:" + code
                case .mathBlock(let latex): return "math:" + latex
                default: return "other"
                }
            }
            XCTAssertEqual(shape, ["text:$$ x", "code:code $$", "text:rest"], fence)
        }
    }

    /// `# T $x$**b**`: the heading look gives the formula and the bold run
    /// the same font, yet the boundary after the closer is kept — the title
    /// typesets `x` as the paragraph does (GitHub: `<M>$x$</M><strong>b</strong>`).
    @MainActor
    func testHeadingFormulaBeforeMarkupStaysAFormula() {
        let recorder = Recorder()
        let blocks = parse("# T $x$**b** and $y$[l](https://e.com)\n\nT $x$**b** and $y$[l](https://e.com)")
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(measured.converted[blocks[0].id]?.string, "T \u{FFFC}b and \u{FFFC}l")
        XCTAssertEqual(recorder.latex, ["x", "y", "x", "y"])
    }

    /// The source box is at most `maximumSourceLines` lines tall: a long
    /// matrix in a narrow cell no longer makes a row of dozens of lines.
    @MainActor
    func testSourceFallbackIsCappedAtEightLines() {
        let blocks = parse("""
        | A | B | C | D | E |
        |---|---|---|---|---|
        | x | $\\begin{matrix} \(String(repeating: "a_{1} & ", count: 40)) z \\end{matrix}$ | y | z | w |
        """)
        let measured = measure(blocks, math: engine(), width: 400)
        guard let table = measured.tables[blocks[0].id] else { return XCTFail("no table") }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.textStorage?.setAttributedString(table.string)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let cell = textView.tableCellBounds(band: 1, column: 1, layout: table.layout) ?? .zero
        let font = NSFont.systemFont(ofSize: 14)
        let line = ceil(font.ascender - font.descender + font.leading) + 1
        XCTAssertGreaterThan(cell.height, 4 * line, "wraps")
        XCTAssertLessThanOrEqual(cell.height, CGFloat(FittingMathAttachment.maximumSourceLines) * line
                                    + 2 * BlockLayout.Table.cellVerticalPadding + 4, "capped")
        // The whole source still copies.
        let whole = SelectionRows.tablePiece(table, covered: NSRange(location: 0, length: table.string.length))
        XCTAssertTrue(whole.map { DocumentCopyBuilder.build([$0]).plain }?.contains("a_{1} & a_{1}") ?? false)
    }

    // MARK: - Formulas before the inline pass (seam review S2)

    /// The cases, as written, with the LaTeX each formula must reach the
    /// engine with and the text shown (U+FFFC per formula).
    private static let atomCases: [(source: String, latex: [String], shown: String)] = [
        ("$f^*$ and $g^*$", ["f^*", "g^*"], "\u{FFFC} and \u{FFFC}"),
        ("$a*b$ and $c*d$", ["a*b", "c*d"], "\u{FFFC} and \u{FFFC}"),
        ("$(a)_n + x_{i}$", ["(a)_n + x_{i}"], "\u{FFFC}"),
        ("$x_1$ and $y_2$", ["x_1", "y_2"], "\u{FFFC} and \u{FFFC}"),
        ("$\\mathbf{A}^* \\cdot \\mathbf{B}^*$", ["\\mathbf{A}^* \\cdot \\mathbf{B}^*"], "\u{FFFC}"),
        ("$a < b$ and $c > d$", ["a < b", "c > d"], "\u{FFFC} and \u{FFFC}"),
        ("$[a,b]$ and $[c,d](u)$", ["[a,b]", "[c,d](u)"], "\u{FFFC} and \u{FFFC}"),
        ("$a ~ b$ and $c ~ d$", ["a ~ b", "c ~ d"], "\u{FFFC} and \u{FFFC}"),
    ]

    /// A formula is decided on the SOURCE line and drawn as one atom, before
    /// emphasis, strikethrough, brackets and autolinks can take its
    /// characters — in a paragraph, a quote, a table cell and a heading.
    ///
    /// GitHub (`gh api markdown -f mode=gfm`, 2026-11-11; `<M>` is
    /// `<math-renderer class="js-inline-math">`), the same in `<p>`,
    /// `<blockquote><p>`, `<td>` and `<h1>`:
    /// - `$f^<em>$ and $g^</em>$`, `$a<em>b$ and $c</em>d$`,
    ///   `$(a)<em>n + x</em>{i}$`, `<M>$[a,b]$</M> and $<a href="u">c,d</a>$`
    ///   — GitHub finds math AFTER its inline pass, so emphasis and the link
    ///   break these; QuickMD typesets them (a formula beats emphasis and
    ///   links — the owner's rule: no defect kept for GitHub's sake);
    /// - `<M>$x_1$</M> and <M>$y_2$</M>`,
    ///   `<M>$\mathbf{A}^* \cdot \mathbf{B}^*$</M>`,
    ///   `<M>$a &lt; b$</M> and <M>$c &gt; d$</M>`,
    ///   `<M>$a ~ b$</M> and <M>$c ~ d$</M>` — formulas, as here.
    /// Before the fix the first case was "f^" + italic + "g^" in every kind.
    @MainActor
    func testFormulasAreAtomsBeforeEmphasisLinksAndAutolinks() {
        for kind in ["paragraph", "quote", "cell", "heading"] {
            for (source, latex, shown) in Self.atomCases {
                let markdown: String
                switch kind {
                case "quote": markdown = "> " + source
                case "cell": markdown = "| A |\n|---|\n| \(source) |"
                case "heading": markdown = "# " + source
                default: markdown = source
                }
                let recorder = Recorder()
                let blocks = parse(markdown)
                let measured = measure(blocks, math: engine(recorder))
                XCTAssertEqual(recorder.latex, latex, "\(kind): \(source)")
                let string = kind == "cell" ? measured.tables[blocks[0].id]?.string.string
                                            : measured.converted[blocks[0].id]?.string
                XCTAssertEqual(string, kind == "cell" ? "A\n\(shown)\n" : shown, "\(kind): \(source)")
            }
        }
    }

    /// What stays as before around the atoms — the negative control: text
    /// with dollars that are no formula keeps its emphasis and links
    /// (`*a* $5 and $10 **b**`), a code span beats a formula (GitHub:
    /// `<code>$x$</code>`, `$a <code>x</code> b$`), a formula never cuts a
    /// link in two (GitHub: `<a href="u">a $b</a>$ and $q <a href="u">r$</a>`),
    /// brackets inside one are LaTeX (`<M>$(a,b]$</M> and <M>$[a,b)$</M>`),
    /// a closer glued to `_` closes only an emphasis opened before the
    /// formula (GitHub: `$x$_ end`, `$a$_b` text; `_$g$_` is
    /// `<em>$g$</em>` there, a formula here as in 1.14.4).
    @MainActor
    func testWhatIsNoFormulaKeepsItsMarkup() {
        let recorder = Recorder()
        let blocks = parse("""
        *a* $5 and $10 **b** [l](https://e.com)

        `$x$` and $a `x` b$

        [a $b](https://e.com)$ and $q [r$](https://e.com) and $(a,b]$ and $[a,b)$

        $x$_ end and _$g$_ and $a$_b
        """)
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(recorder.latex, ["(a,b]", "[a,b)", "g"])
        guard case .text(let first) = blocks[0].content else { return XCTFail("paragraph") }
        XCTAssertEqual(String(first.characters), "a $5 and $10 b l")
        let looks = first.runs.map { run -> String in
            let traits = run[AttributeScopes.AppKitAttributes.FontAttribute.self]?.fontDescriptor.symbolicTraits ?? []
            return (traits.contains(.italic) ? "i" : "") + (traits.contains(.bold) ? "b" : "")
                + (run.link != nil ? "l" : "")
        }
        XCTAssertEqual(looks.filter { !$0.isEmpty }, ["i", "b", "l"])
        XCTAssertEqual(measured.converted[blocks[1].id]?.string, "$x$ and $a x b$")
        XCTAssertEqual(measured.converted[blocks[2].id]?.string,
                       "a $b$ and $q r$ and \u{FFFC} and \u{FFFC}")
        XCTAssertEqual(measured.converted[blocks[3].id]?.string, "$x$_ end and \u{FFFC} and $a$_b")
        XCTAssertFalse(BlockTextConverter.containsInlineMath(first))
    }

    /// The formula atom's characters are its source: LaTeX escapes and
    /// character references inside reach the engine as written
    /// (GitHub: `<M>$a &amp;amp; b$</M>` — the reference is not decoded), a
    /// `&#36;` delimiter is a dollar (`<M>$x^2$</M>`), and an escaped dollar
    /// stays in the LaTeX.
    @MainActor
    func testFormulaCharactersAreItsSource() {
        let recorder = Recorder()
        let blocks = parse("$50\\%$ and $a\\,b$ and $a &amp; b$ and &#36;x^2&#36; and $a\\$b$ and \\$5")
        let measured = measure(blocks, math: engine(recorder))
        XCTAssertEqual(recorder.latex, ["50\\%", "a\\,b", "a &amp; b", "x^2", "a\\$b"])
        XCTAssertEqual(measured.converted[blocks[0].id]?.string,
                       "\u{FFFC} and \u{FFFC} and \u{FFFC} and \u{FFFC} and \u{FFFC} and $5")
        guard case .text(let attributed) = blocks[0].content else { return XCTFail("paragraph") }
        XCTAssertEqual(InlineMathSegmenter.pieces(of: attributed).compactMap { piece -> String? in
            if case .math = piece.segment { return String(repeating: "x", count: piece.length) } else { return nil }
        }.map(\.count), [6, 6, 11, 5, 6], "the rendered atoms: the source, a `&#36;` delimiter as `$`")
    }

    /// A heading's id is GitHub's, which reads the title after its inline
    /// pass, with no math (`gh api markdown -f mode=markdown`):
    /// `# $f^*$ and $g^*$` → `f-and-g`, `# $(a)_n + x_{i}$` → `an--xi`,
    /// `# $x_1$ and $y_2$` → `x_1-and-y_2`. Contents lists the source.
    func testHeadingIdsStayGitHubsWhenFormulasAreAtoms() {
        let blocks = parse("# $f^*$ and $g^*$\n\n# $(a)_n + x_{i}$\n\n# $x_1$ and $y_2$")
        let renderer = MarkdownRenderer(theme: theme, fontScale: 1)
        let headings = HeadingAnchors.headings(of: blocks, renderer: renderer)
        XCTAssertEqual(HeadingAnchors.ids(for: headings.map(\.text)), ["f-and-g", "an--xi", "x_1-and-y_2"])
        XCTAssertEqual(ToCEntry.entries(of: blocks).map { $0.shownTitle(renderer: renderer) },
                       ["$f^*$ and $g^*$", "$(a)_n + x_{i}$", "$x_1$ and $y_2$"])
    }

    // MARK: - A formula in link text (seam review N2)

    /// GitHub: `See <a href="https://e.com">$x$</a> here` in `<p>`, `<h1>`,
    /// `<blockquote><p>` and `<td>` (GitHub does not typeset it; QuickMD
    /// does, as 1.14.4 did in paragraphs): the attachment is part of the
    /// link — clickable and underlined — and so is the source shown when
    /// the formula does not typeset, in the link colour.
    @MainActor
    func testFormulaInLinkTextKeepsTheLink() {
        let markdown = """
        See [$x$](https://e.com) here

        # See [$x$](https://e.com) here

        > See [$x$](https://e.com) here

        | A |
        |---|
        | See [$x$](https://e.com) here |
        """
        let linkColor = NSColor(theme.linkColor).usingColorSpace(.sRGB)
        for typesets in [true, false] {
            let blocks = parse(markdown)
            let measured = measure(blocks, math: engine(typesets: typesets))
            let strings = [measured.converted[blocks[0].id], measured.converted[blocks[1].id],
                           measured.converted[blocks[2].id], measured.tables[blocks[3].id]?.string]
            for (kind, string) in zip(["paragraph", "heading", "quote", "cell"], strings) {
                guard let string else { XCTFail(kind); continue }
                let formula = (string.string as NSString).range(of: typesets ? "\u{FFFC}" : " x ")
                XCTAssertNotEqual(formula.location, NSNotFound, kind)
                let at = typesets ? formula.location : formula.location + 1
                XCTAssertEqual((string.attribute(.link, at: at, effectiveRange: nil) as? URL)?.absoluteString,
                               "https://e.com", "\(kind) typesets=\(typesets)")
                XCTAssertNotNil(string.attribute(.underlineStyle, at: at, effectiveRange: nil), kind)
                if !typesets {
                    let color = (string.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor)?
                        .usingColorSpace(.sRGB)
                    XCTAssertEqual(color, linkColor, "\(kind): the fallback in the link colour")
                }
            }
        }
    }

    // MARK: - Heading baseline with a tall formula (seam review N1)

    /// `# $\frac{a}{b}$ Title`: the formula is taller than the heading's
    /// text, so TextKit sets the first baseline at its top — the copy button
    /// follows (`titleFirstBaseline(of:headerFont:shown:)`, the view's and
    /// the measurer's one call), equal to the laid-out baseline; the row's
    /// title inset uses it.
    @MainActor
    func testHeadingBaselineIncludesATallFormula() {
        for level in [1, 3, 6] {
            let renderer = MarkdownRenderer(theme: theme, fontScale: 1)
            let attributed = renderer.renderHeader("$\\frac{a}{b}$ Title", level: level)
            let ns = BlockTextConverter.headingTitle(attributed, level: level, renderer: renderer, math: engine())
            let storage = NSTextStorage(attributedString: ns)
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: 2000, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            // The baseline of the line's TEXT (an attachment glyph's own
            // location is its image's bottom, not the baseline).
            let text = layoutManager.glyphIndexForCharacter(at: (ns.string as NSString).range(of: "Title").location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: text, effectiveRange: nil)
            let laidOut = fragment.minY + layoutManager.location(forGlyphAt: text).y
            let headerFont = renderer.headerAppKitFont(level: level)
            let computed = BlockLayout.Heading.titleFirstBaseline(of: attributed, headerFont: headerFont,
                                                                  shown: { ns })
            XCTAssertEqual(computed, laidOut, accuracy: 0.01, "H\(level)")
            XCTAssertGreaterThan(computed, BlockLayout.Heading.titleFirstBaseline(of: attributed,
                                                                                  headerFont: headerFont),
                                 "H\(level): the formula is taller than the text")
            // A title without a formula never builds the shown string.
            let plain = renderer.renderHeader("Title", level: level)
            XCTAssertEqual(BlockLayout.Heading.titleFirstBaseline(of: plain, headerFont: headerFont,
                                                                  shown: { XCTFail("built"); return ns }),
                           BlockLayout.Heading.titleFirstBaseline(of: plain, headerFont: headerFont))
        }
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
