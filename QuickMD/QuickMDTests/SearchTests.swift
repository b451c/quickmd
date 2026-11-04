import XCTest
import SwiftUI
import AppKit

/// DocumentSearch (find-in-document) behavior tests: one match entry per
/// occurrence, all block types searched; tables counted on the string their
/// view shows and highlighted with the text rows' AppKit highlight (TS-D9).
final class SearchTests: XCTestCase {

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    func testEmptyTermYieldsNoResults() {
        let results = DocumentSearch.computeMatches(in: parse("# Hello"), term: "")
        XCTAssertTrue(results.matchBlockIds.isEmpty)
    }

    func testOneEntryPerOccurrence() {
        let blocks = parse("apple apple apple")
        let results = DocumentSearch.computeMatches(in: blocks, term: "apple")
        XCTAssertEqual(results.matchBlockIds.count, 3)
        XCTAssertEqual(Set(results.matchBlockIds).count, 1, "all in the same block")
    }

    func testCaseInsensitiveMatching() {
        let blocks = parse("Apple aPPle APPLE")
        let results = DocumentSearch.computeMatches(in: blocks, term: "apple")
        XCTAssertEqual(results.matchBlockIds.count, 3)
    }

    func testSearchCoversAllBlockTypes() {
        let md = """
        # needle in heading
        needle in text

        ```
        needle in code
        ```
        > needle in quote

        | needle |
        |--------|
        | needle |
        """
        let results = DocumentSearch.computeMatches(in: parse(md), term: "needle")
        XCTAssertEqual(results.matchBlockIds.count, 6,
            "heading + text + code + blockquote + table header + table cell")
        XCTAssertEqual(results.matchBlockIds.filter { $0.hasPrefix("table-") }.count, 2,
            results.matchBlockIds.description)
    }

    /// A definition list renders into a `.text` block, so its terms and bodies
    /// are searched through the block's plain characters like any paragraph.
    func testDefinitionListContentIsSearchable() {
        let blocks = parse("Apple\n: A pomaceous fruit")
        let results = DocumentSearch.computeMatches(in: blocks, term: "pomaceous")
        XCTAssertEqual(results.matchBlockIds.count, 1)
        XCTAssertTrue(results.matchBlockIds[0].hasPrefix("text-"), results.matchBlockIds[0])
    }

    // MARK: - Matcher (shared by the AppKit highlight and the table count)

    func testSearchMatchRanges() {
        XCTAssertEqual(searchMatchRanges(in: "aaa", term: "a").count, 3)
        XCTAssertEqual(searchMatchRanges(in: "AaA", term: "a").count, 3)
        XCTAssertEqual(searchMatchRanges(in: "abc", term: ""), [])
        XCTAssertEqual(searchMatchRanges(in: "", term: "x"), [])
        XCTAssertEqual(searchMatchRanges(in: "aaaa", term: "aa"),
                       [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)], "non-overlapping")
        XCTAssertEqual(searchMatchRanges(in: "find the Word here", term: "word"),
                       [NSRange(location: 9, length: 4)])
    }

    func testNSHighlightMarksEveryMatchAndOnlyTheFocusedOneOrange() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 10))
        textView.textStorage?.setAttributedString(NSAttributedString(string: "one two one two one"))
        applyNSSearchHighlight(in: textView, term: "one", focusedOccurrence: 1)
        XCTAssertEqual(highlights(in: textView).map(\.range),
                       [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
                        NSRange(location: 16, length: 3)])
        XCTAssertEqual(highlights(in: textView).map(\.focused), [false, true, false])

        applyNSSearchHighlight(in: textView, term: "", focusedOccurrence: nil)
        XCTAssertTrue(highlights(in: textView).isEmpty, "an empty term clears the previous highlight")
    }

    // MARK: - Tables (TS-D9): count on the rendered string == what is highlighted

    private var theme: MarkdownTheme { MarkdownTheme.cached(for: .light) }

    private struct Table {
        let block: MarkdownBlock
        let headers: [String]
        let rows: [[String]]
        let alignments: [TextAlignment]
        var style: TableStyle = .grid
    }

    private func tables(in blocks: [MarkdownBlock]) -> [Table] {
        blocks.compactMap { block in
            guard case .table(let headers, let rows, let alignments, let style) = block.content else { return nil }
            return Table(block: block, headers: headers, rows: rows, alignments: alignments, style: style)
        }
    }

    private func onlyTable(_ markdown: String) -> Table {
        let found = tables(in: parse(markdown))
        XCTAssertEqual(found.count, 1, "fixture must hold exactly one table")
        return found[0]
    }

    private func build(_ table: Table, theme: MarkdownTheme? = nil, fontScale: CGFloat = 1) -> TableText {
        TableTextBuilder.build(headers: table.headers, rows: table.rows, alignments: table.alignments,
                               style: table.style, theme: theme ?? self.theme, fontScale: fontScale)
    }

    /// A text view set up as `TableTextRepresentable.makeNSView` sets it up,
    /// holding the builder's string (the view itself is not compiled into the
    /// test target).
    private func tableTextView(_ table: TableText) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 10))
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.textStorage?.setAttributedString(table.string)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    /// A front-matter key is secondary-colour text; the FOCUSED match on a key
    /// is drawn in the theme's text colour (on the orange focus the secondary
    /// colour read poorly), exactly what a focused value shows. Unfocused key
    /// matches and value matches keep their colours; the next call clears it.
    func testFocusedMatchOnAPropertiesKeyUsesTheTextColour() throws {
        let table = onlyTable("---\nauthor: Ann\nnote: by author\n---\n")
        XCTAssertEqual(table.style, .properties)
        let built = build(table)
        let textView = tableTextView(built)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let keys = built.layout.firstColumnRanges
        XCTAssertEqual(keys.map { (built.string.string as NSString).substring(with: $0) }, ["author", "note"])
        let textColor = NSColor(theme.textColor)
        func temporaryForeground(at index: Int) -> NSColor? {
            layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
        }
        let valueMatch = (built.string.string as NSString).range(of: "author", options: .backwards)

        applyNSSearchHighlight(in: textView, term: "author", focusedOccurrence: 0,
                               focusedText: (textColor, keys))
        XCTAssertEqual(temporaryForeground(at: keys[0].location), textColor, "focused key match")
        XCTAssertEqual(temporaryForeground(at: NSMaxRange(keys[0]) - 1), textColor)
        XCTAssertNil(temporaryForeground(at: valueMatch.location), "unfocused value match untouched")

        applyNSSearchHighlight(in: textView, term: "author", focusedOccurrence: 1,
                               focusedText: (textColor, keys))
        XCTAssertNil(temporaryForeground(at: keys[0].location), "an unfocused key keeps its secondary colour")
        XCTAssertNil(temporaryForeground(at: valueMatch.location), "a value already has the text colour")

        applyNSSearchHighlight(in: textView, term: "author", focusedOccurrence: 0,
                               focusedText: (textColor, keys))
        applyNSSearchHighlight(in: textView, term: "author", focusedOccurrence: 0)
        XCTAssertNil(temporaryForeground(at: keys[0].location), "cleared for a view reused by a grid table")
    }

    /// The temporary background runs `applyNSSearchHighlight` left, in order.
    private func highlights(in textView: NSTextView) -> [(range: NSRange, focused: Bool)] {
        guard let layoutManager = textView.layoutManager, let length = textView.textStorage?.length else { return [] }
        var result: [(range: NSRange, focused: Bool)] = []
        var index = 0
        while index < length {
            var effective = NSRange(location: 0, length: 0)
            let value = layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index,
                                                         effectiveRange: &effective)
            if let color = value as? NSColor {
                result.append((effective, color.isEqual(NSColor.systemOrange)))
            }
            index = max(NSMaxRange(effective), index + 1)
        }
        return result
    }

    private func count(_ term: String, in markdown: String) -> Int {
        DocumentSearch.computeMatches(in: parse(markdown), term: term).matchBlockIds.count
    }

    /// The off-main string (`plainString`, no NSTextTable) is the view's string,
    /// character for character — including headerless, ragged, header-only,
    /// empty cells, links, code and emphasis — and does not depend on the theme
    /// or the zoom.
    func testTablePlainStringEqualsTheViewString() {
        let fixtures = [
            "| Name | Role |\n|---|---|\n| **Ada** | `eng` |\n| [Grace](https://navy.mil) | *Admiral* |",
            "| | | |\n|---|---|---|\n| a | b |\n| one | two | three | four |\n| only |",
            "| Lonely | Header |\n|---|---|",
            "| A | | C |\n|:-|:-:|-:|\n| | x | |\n| ~~gone~~ | <https://auto.link> | 1 \\| 2 |",
        ]
        for markdown in fixtures {
            let table = onlyTable(markdown)
            let viewString = build(table).string.string
            for (theme, scale) in [(self.theme, CGFloat(1)), (MarkdownTheme.cached(for: .dark), 1.5),
                                   (self.theme, 0.75)] {
                XCTAssertEqual(TableTextBuilder.plainString(headers: table.headers, rows: table.rows,
                                                            alignments: table.alignments, style: table.style,
                                                            theme: theme, fontScale: scale),
                               viewString, markdown)
                XCTAssertEqual(build(table, theme: theme, fontScale: scale).string.string, viewString, markdown)
            }
        }
    }

    func testTableTermInsideBoldCodeAndLinkTextIsCountedOnceAndHighlighted() {
        let markdown = "| A | B | C |\n|---|---|---|\n| **needle** | `needle` | [needle](https://example.com/x) |"
        XCTAssertEqual(count("needle", in: markdown), 3)

        let textView = tableTextView(build(onlyTable(markdown)))
        applyNSSearchHighlight(in: textView, term: "needle", focusedOccurrence: nil)
        let drawn = highlights(in: textView)
        XCTAssertEqual(drawn.count, 3)
        let string = textView.string as NSString
        XCTAssertEqual(drawn.map { string.substring(with: $0.range) }, ["needle", "needle", "needle"])
    }

    /// 1.12 counted these on the cells' markdown and never drew them (and the
    /// focused occurrence drifted after such a cell).
    func testTableTermOnlyInMarkupOrURLIsNotCounted() {
        let markdown = "| Docs | Note |\n|---|---|\n| [guide](https://needle.example.org/page) | a **b** `c` |"
        XCTAssertEqual(count("needle", in: markdown), 0, "link URL")
        XCTAssertEqual(count("example.org", in: markdown), 0, "link URL")
        XCTAssertEqual(count("**", in: markdown), 0, "emphasis markers")
        XCTAssertEqual(count("`", in: markdown), 0, "code markers")
        XCTAssertEqual(count("guide", in: markdown), 1, "the link text is what shows")
        XCTAssertEqual(count("a b c", in: markdown), 1, "rendered text across styles")
    }

    /// Every focused index lands on the k-th match in reading order (header
    /// band, then rows, left to right), in the right cell, with nothing else
    /// orange — headed, headerless and ragged tables.
    func testTableFocusedOccurrenceMapsToCellAndRangeInReadingOrder() {
        let cases: [(markdown: String, expected: [(band: Int, column: Int)])] = [
            ("| x key | **x** |\n|---|---|\n| `x` and x | [x](https://x.example) |\n| none | [y](https://x.y) |",
             [(0, 0), (0, 1), (1, 0), (1, 0), (1, 1)]),
            // Headerless: band 0 is the first data row; the hidden header has
            // no cells to match.
            ("| | |\n|---|---|\n| a x | b |\n| c | **x** x |",
             [(0, 0), (1, 1), (1, 1)]),
            // Ragged: a short row is padded with empty cells, so the cells
            // after it keep their columns.
            ("| H1 | H2 | H3 |\n|---|---|---|\n| x |\n| p | q | x |\n| | x |",
             [(1, 0), (2, 2), (3, 1)]),
        ]
        for (markdown, expected) in cases {
            let table = onlyTable(markdown)
            let built = build(table)
            let results = DocumentSearch.computeMatches(in: [table.block], term: "x")
            XCTAssertEqual(results.matchBlockIds.count, expected.count, markdown)

            let textView = tableTextView(built)
            let string = textView.string as NSString
            for focused in 0..<expected.count {
                applyNSSearchHighlight(in: textView, term: "x", focusedOccurrence: focused)
                let drawn = highlights(in: textView)
                XCTAssertEqual(drawn.count, expected.count, "count == highlights: \(markdown)")
                XCTAssertEqual(drawn.filter(\.focused).count, 1, markdown)
                guard focused < drawn.count else { continue }
                XCTAssertTrue(drawn[focused].focused, "focused \(focused) is the \(focused)-th highlight: \(markdown)")
                let range = drawn[focused].range
                XCTAssertEqual(string.substring(with: range), "x", markdown)
                guard let cell = built.layout.cell(containing: range.location) else {
                    XCTFail("highlight outside every cell: \(markdown)"); continue
                }
                XCTAssertEqual(cell.band, expected[focused].band, "focused \(focused): \(markdown)")
                XCTAssertEqual(cell.column, expected[focused].column, "focused \(focused): \(markdown)")
                XCTAssertTrue(NSLocationInRange(range.location, built.layout.cellRanges[cell.band][cell.column])
                              && NSMaxRange(range) <= NSMaxRange(built.layout.cellRanges[cell.band][cell.column]),
                              "the match lies inside its cell: \(markdown)")
            }
        }
    }

    /// "İ" (U+0130) lowercases to two UTF-16 units. The ranges must still be
    /// the ORIGINAL string's — in a table one such character used to shift
    /// every later highlight by one.
    func testLengthChangingLowercaseDoesNotShiftRanges() {
        let text = "İstanbul and x, then X"
        let expected = [(text as NSString).range(of: "x"), (text as NSString).range(of: "X")]
        XCTAssertEqual(searchMatchRanges(in: text, term: "x"), expected)
        XCTAssertEqual(searchMatchRanges(in: text, term: "STANBUL"), [NSRange(location: 1, length: 7)],
                       "case-insensitive on the original string")
        XCTAssertEqual(searchMatchRanges(in: text, term: "İ"), [NSRange(location: 0, length: 1)])

        // A text row through the shared highlight.
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 10))
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))
        applyNSSearchHighlight(in: textView, term: "x", focusedOccurrence: 1)
        XCTAssertEqual(highlights(in: textView).map(\.range), expected)
        XCTAssertEqual(highlights(in: textView).map(\.focused), [false, true])

        // A table: "İstanbul" in the first cell, the term in later cells.
        let markdown = "| İstanbul | x |\n|---|---|\n| **x** İ | [x](https://x.example) |"
        let table = onlyTable(markdown)
        let built = build(table)
        let string = built.string.string as NSString
        var original: [NSRange] = []
        var location = 0
        while true {
            let found = string.range(of: "x", options: [],
                                     range: NSRange(location: location, length: string.length - location))
            if found.location == NSNotFound { break }
            original.append(found)
            location = NSMaxRange(found)
        }
        XCTAssertEqual(original.count, 3)
        XCTAssertEqual(DocumentSearch.computeMatches(in: [table.block], term: "x").matchBlockIds.count, 3)
        let tableView = tableTextView(built)
        for focused in 0..<original.count {
            applyNSSearchHighlight(in: tableView, term: "x", focusedOccurrence: focused)
            let drawn = highlights(in: tableView)
            XCTAssertEqual(drawn.map(\.range), original, "count == highlights, original coordinates")
            XCTAssertEqual(drawn.firstIndex(where: \.focused), focused)
        }
    }

    /// A text row containing "İ": its count is exactly what its view
    /// highlights, for every term (the count used the lowercased Swift
    /// `String.range` loop while the highlight used `searchMatchRanges`, which
    /// searches the original `.caseInsensitive` when lowercasing changes the
    /// length — the two disagreed, e.g. on a dotted capital next to a
    /// combining dot).
    func testTextRowWithDottedCapitalCountEqualsHighlights() throws {
        let theme = MarkdownTheme.cached(for: .light)
        let markdown = "İİi\u{307} İstanbul, istanbul and ISTANBUL; x İ x."
        let blocks = parse(markdown)
        let block = try XCTUnwrap(blocks.first)
        guard case .text(let attributed) = block.content else { return XCTFail("not a text row") }
        let shown = BlockTextConverter.makeNSAttributedString(from: attributed, hasInlineMath: false,
                                                              theme: theme, fontScale: 1, math: .none)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 10))
        textView.textStorage?.setAttributedString(shown)
        for term in ["i", "I", "İ", "stanbul", "ISTANBUL", "x", "İ\u{307}", "\u{307}", "i\u{307}"] {
            let tag = "term \(term.unicodeScalars.map { String($0.value, radix: 16) })"
            // What `applyNSSearchHighlight` draws, one range per occurrence
            // (adjacent runs of the drawn attribute would merge, so the
            // drawing is checked by total length).
            let occurrences = searchMatchRanges(in: textView.string, term: term)
            applyNSSearchHighlight(in: textView, term: term, focusedOccurrence: nil)
            XCTAssertEqual(highlights(in: textView).map(\.range.length).reduce(0, +),
                           occurrences.map(\.length).reduce(0, +), tag)
            let counted = DocumentSearch.computeMatches(in: blocks, term: term).matchBlockIds.count
            XCTAssertEqual(counted, occurrences.count, tag)
        }
    }

    /// Paragraphs and tables interleave in document order; each table counts
    /// its rendered matches only.
    func testMixedDocumentCountsParagraphsAndTablesInOrder() {
        let markdown = """
        A needle before.

        | Col | [needle](https://needle.example) |
        |---|---|
        | needle **needle** | `x` |

        Between, needle needle.

        | | |
        |---|---|
        | [text](https://needle.example) | none |

        After: needle.
        """
        let blocks = parse(markdown)
        let ids = DocumentSearch.computeMatches(in: blocks, term: "needle").matchBlockIds
        let kinds = ids.map { id -> String in
            guard let block = blocks.first(where: { $0.id == id }) else { return "?" }
            if case .table = block.content { return "table" }
            return "text"
        }
        XCTAssertEqual(kinds, ["text", "table", "table", "table", "text", "text", "text"])
        XCTAssertEqual(Set(ids.filter { $0.hasPrefix("table-") }).count, 1,
                       "the second table only has the term in a URL")
    }

    /// `MarkdownView` passes the measurer's strings; one built from THIS block
    /// is used, one left over from another parse under the same positional id
    /// is not (the view applies the same rule before installing it).
    func testMeasuredTableStringIsUsedOnlyWhenItBelongsToTheBlock() {
        let table = onlyTable("| A |\n|---|\n| needle |")
        let other = onlyTable("| A |\n|---|\n| needle needle needle |")
        let block = [table.block]

        let own = DocumentSearch.computeMatches(in: block, term: "needle",
                                                tables: [table.block.id: build(table)],
                                                theme: theme, fontScale: 1)
        XCTAssertEqual(own.matchBlockIds.count, 1)

        let stale = DocumentSearch.computeMatches(in: block, term: "needle",
                                                  tables: [table.block.id: build(other)],
                                                  theme: theme, fontScale: 1)
        XCTAssertEqual(stale.matchBlockIds.count, 1, "a TableText of another block is ignored")

        let otherScale = DocumentSearch.computeMatches(in: block, term: "needle",
                                                       tables: [table.block.id: build(other, fontScale: 1.5)],
                                                       theme: theme, fontScale: 1.5)
        XCTAssertEqual(otherScale.matchBlockIds.count, 1)
    }

    // MARK: - Text kinds (1.14.1): count on the RENDERED string == what is highlighted

    /// Stand-in for SwiftMath (not compiled into the test bundle): every
    /// formula typesets, as the real engine does for valid LaTeX.
    private let typesettingMath = MathRendering(
        inlineImage: { _, _, _ in NSImage(size: NSSize(width: 24, height: 12)) },
        displayHeight: { _, _, _ in 40 })

    /// The string `block`'s view installs, built the way the VIEW builds it —
    /// independently of `DocumentSearch`: quote and alert bodies through
    /// `renderQuotedBody`, headings through `renderHeader` (HeadingBlockView),
    /// paragraphs as parsed, all through the converter, inline math with a
    /// typesetting engine. Nil for kinds without a TextBlockView.
    private func viewString(of block: MarkdownBlock, theme: MarkdownTheme, fontScale: CGFloat = 1) -> NSAttributedString? {
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
        func convert(_ attributed: AttributedString, math hasMath: Bool) -> NSAttributedString {
            BlockTextConverter.makeNSAttributedString(from: attributed, hasInlineMath: hasMath, theme: theme,
                                                      fontScale: fontScale, math: typesettingMath)
        }
        switch block.content {
        case .text(let attributed):
            return convert(attributed, math: BlockTextConverter.containsInlineMath(String(attributed.characters)))
        case .blockquote(let content, _):
            return convert(renderer.renderQuotedBody(content), math: false)
        case .alert(_, let content):
            return content.isEmpty ? nil : convert(renderer.renderQuotedBody(content), math: false)
        case .heading(let level, let title, _):
            return convert(renderer.renderHeader(title, level: level), math: false)
        default:
            return nil
        }
    }

    private let renderedFixtures = [
        // Blockquote: emphasis, code, a link, an autolink, a footnote ref, an
        // escaped character, HTML entities, a nested quote marker.
        "> **needle** and `needle` and [needle](https://needle.example.com/x) <https://auto.example.org>"
            + " see[^1] a\\*b &amp; &copy; x\n>\n> > deeper needle",
        // Alert body with the same markup.
        "> [!NOTE]\n> **needle** `code` [link](https://needle.example.com) a\\*b &amp; ~~gone~~ needle",
        // Headings.
        "# **needle** `code` [link](https://needle.example.com) a\\*b &amp; *x*",
        "## Install with `brew` — see [the guide](https://example.com/guide#needle)",
        // Paragraph with inline math: terms inside and outside the formula.
        "x outside $x^2 + y$ and x again, $\\frac{a}{b}$ then y",
        // Paragraph: markup and a footnote ref.
        "**needle** in [text](https://needle.example) and `needle`[^n]\n\n[^n]: needle def",
    ]

    private let renderedTerms = ["needle", "**", "`", "https", "example", "auto", "*", "\\", "&amp;", "&",
                                 "©", "[^1]", "[", "]", "(", ">", "~~", "gone", "x", "x^2", "$", "y",
                                 "frac", "{", "code", "link", "guide", "1", "brew", "#"]

    /// The invariant, per block and term: `computeMatches` counts exactly the
    /// occurrences the block's highlight draws on the string its view shows —
    /// with the measurer's strings AND with the fallback (no measured
    /// strings, as before the first layout); the fallback string IS the view
    /// string; and every focused occurrence paints the k-th highlight.
    func testTextKindsCountEqualsHighlightsOnTheViewString() {
        for theme in [MarkdownTheme.cached(for: .light), MarkdownTheme.cached(for: .dark)] {
            for markdown in renderedFixtures {
                let blocks = MarkdownBlockParser(theme: theme).parse(markdown)
                let measured = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1,
                                                           contentWidth: 600, math: typesettingMath)
                let renderer = MarkdownRenderer(theme: theme, fontScale: 1)
                for block in blocks {
                    guard let shown = viewString(of: block, theme: theme) else { continue }
                    XCTAssertEqual(DocumentSearch.displayedString(of: block, converted: [:], renderer: renderer),
                                   shown.string, "fallback == view string: \(block.id) in \(markdown)")
                    XCTAssertEqual(DocumentSearch.displayedString(of: block, converted: measured.converted,
                                                                  renderer: renderer),
                                   shown.string, "measured == view string: \(block.id) in \(markdown)")

                    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 10))
                    textView.textStorage?.setAttributedString(shown)
                    for term in renderedTerms {
                        let tag = "\(block.id) term \(term) in \(markdown)"
                        let drawn = searchMatchRanges(in: textView.string, term: term)
                        for converted in [[:], measured.converted] {
                            let counted = DocumentSearch.computeMatches(in: [block], term: term, converted: converted,
                                                                        theme: theme, fontScale: 1)
                            XCTAssertEqual(counted.matchBlockIds.count, drawn.count, tag)
                        }
                        // What the highlight paints (adjacent runs merge, so
                        // compare total length) and where the orange one is.
                        for focused in 0..<drawn.count {
                            applyNSSearchHighlight(in: textView, term: term, focusedOccurrence: focused)
                            let painted = highlights(in: textView)
                            XCTAssertEqual(painted.map(\.range.length).reduce(0, +),
                                           drawn.map(\.length).reduce(0, +), tag)
                            let orange = painted.filter(\.focused).map(\.range)
                            XCTAssertEqual(orange, [drawn[focused]], "focused \(focused): \(tag)")
                        }
                    }
                }
            }
        }
    }

    /// The concrete 1.14.0 bugs: markup, URLs and LaTeX were counted although
    /// nothing is drawn there; the shown text still counts.
    func testMarkupURLsAndFormulasAreNotCountedInTextKinds() {
        let quote = "> **bold** `code` [label](https://hidden.example/path) a\\*b &amp; done"
        XCTAssertEqual(count("**", in: quote), 0, "emphasis markers")
        XCTAssertEqual(count("`", in: quote), 0, "code markers")
        XCTAssertEqual(count("hidden", in: quote), 0, "link URL")
        XCTAssertEqual(count("\\", in: quote), 0, "escape")
        XCTAssertEqual(count("bold code label a*b", in: quote), 1, "rendered text across styles")
        // Character references are drawn decoded (`HTMLEntities`, as on
        // GitHub): the drawn "&" is counted, the source "&amp;" is not.
        XCTAssertEqual(count("&amp;", in: quote), 0)
        XCTAssertEqual(count("a*b & done", in: quote), 1)

        let alert = "> [!WARNING]\n> **bold** [label](https://hidden.example)"
        XCTAssertEqual(count("**", in: alert), 0)
        XCTAssertEqual(count("hidden", in: alert), 0)
        XCTAssertEqual(count("warning", in: alert), 0, "the alert title is chrome, never highlighted")
        XCTAssertEqual(count("bold label", in: alert), 1)

        let heading = "## **Bold** and [label](https://hidden.example)"
        XCTAssertEqual(count("**", in: heading), 0)
        XCTAssertEqual(count("hidden", in: heading), 0)
        XCTAssertEqual(count("bold and label", in: heading), 1)

        let math = "x before $x^2 + y$ and x after"
        XCTAssertEqual(count("x", in: math), 2, "only the drawn x's — the formula is an attachment")
        XCTAssertEqual(count("x^2", in: math), 0)
        XCTAssertEqual(count("$", in: math), 0)
        XCTAssertEqual(count("\u{FFFC}", in: math), 1, "the attachment character the view draws")
    }

    /// The focused block occurrence after a match in markup: 1.14.0 counted
    /// the quote's URL hit first, so ⌘G's second step pointed at an
    /// occurrence the highlight does not have.
    func testFocusedOccurrenceInAQuoteFollowsTheDrawnMatches() {
        let blocks = parse("> [one](https://needle.example) needle and needle")
        let ids = DocumentSearch.computeMatches(in: blocks, term: "needle").matchBlockIds
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(DocumentSearch.focus(in: ids, at: 1)?.occurrence, 1)
        XCTAssertNil(DocumentSearch.focus(in: ids, at: 2), "no third occurrence to focus")
    }

    // MARK: - Re-run after a re-parse (1.14.1)

    func testFocusAfterRerunKeepsOrClampsAndNeverScrollsOnReparse() {
        // Typing: first match, scroll when there is one.
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .termChanged, previous: 4, matchCount: 9), 0)
        XCTAssertTrue(DocumentSearch.scrollsToFocus(after: .termChanged, matchCount: 9))
        XCTAssertFalse(DocumentSearch.scrollsToFocus(after: .termChanged, matchCount: 0))
        // Re-parse: same index while it exists, the last match otherwise, 0
        // with none — and the document never moves.
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .reparsed, previous: 4, matchCount: 9), 4)
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .reparsed, previous: 4, matchCount: 5), 4)
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .reparsed, previous: 4, matchCount: 3), 2)
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .reparsed, previous: 4, matchCount: 0), 0)
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .reparsed, previous: -1, matchCount: 3), 0)
        XCTAssertFalse(DocumentSearch.scrollsToFocus(after: .reparsed, matchCount: 9))
    }

    func testFocusMapsMatchIndexToBlockOccurrence() {
        let ids = ["a", "a", "b", "a", "b"]
        XCTAssertEqual(DocumentSearch.focus(in: ids, at: 0)?.blockId, "a")
        XCTAssertEqual(DocumentSearch.focus(in: ids, at: 0)?.occurrence, 0)
        XCTAssertEqual(DocumentSearch.focus(in: ids, at: 3)?.blockId, "a")
        XCTAssertEqual(DocumentSearch.focus(in: ids, at: 3)?.occurrence, 2)
        XCTAssertEqual(DocumentSearch.focus(in: ids, at: 4)?.blockId, "b")
        XCTAssertEqual(DocumentSearch.focus(in: ids, at: 4)?.occurrence, 1)
        XCTAssertNil(DocumentSearch.focus(in: ids, at: 5))
        XCTAssertNil(DocumentSearch.focus(in: ids, at: -1))
        XCTAssertNil(DocumentSearch.focus(in: [], at: 0))
    }

    /// A zoom re-parse renders the same characters, so a re-run finds the
    /// same matches and keeps the focus; an edit on disk that removes matches
    /// clamps it.
    func testRerunOverANewParseOfTheSameTerm() {
        let markdown = "> **needle** one\n\nneedle two needle\n\n# needle"
        let before = DocumentSearch.computeMatches(in: parse(markdown), term: "needle").matchBlockIds
        let zoomed = MarkdownBlockParser(theme: theme, fontScale: 1.5).parse(markdown)
        let after = DocumentSearch.computeMatches(in: zoomed, term: "needle", theme: theme, fontScale: 1.5).matchBlockIds
        XCTAssertEqual(after, before)
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .reparsed, previous: 3, matchCount: after.count), 3)

        let edited = DocumentSearch.computeMatches(in: parse("needle"), term: "needle").matchBlockIds
        XCTAssertEqual(DocumentSearch.focusedIndex(after: .reparsed, previous: 3, matchCount: edited.count), 0)
    }

    // MARK: - Properties tables (front matter, v1.14.2)

    /// Front matter is counted on the rendered properties string (literal
    /// keys, rendered values) — the string the view highlights — and the
    /// off-main `plainString` equals the view string for the style.
    func testPropertiesTableCountsOnTheRenderedString() throws {
        let markdown = "---\ntitle: The **needle** post\nneedle key: \"[a](https://needle.example)\"\n"
            + "tags: [needle, x]\n---\nBody needle."
        let table = try XCTUnwrap(tables(in: parse(markdown)).first)
        XCTAssertEqual(table.style, .properties)
        let viewString = build(table).string.string
        XCTAssertEqual(viewString, "title\nThe needle post\nneedle key\na\ntags\nneedle, x\n")
        XCTAssertEqual(TableTextBuilder.plainString(headers: table.headers, rows: table.rows,
                                                    alignments: table.alignments, style: .properties,
                                                    theme: theme, fontScale: 1), viewString)
        // value, key, list item + the body; not the link URL.
        XCTAssertEqual(count("needle", in: markdown), 4)
        XCTAssertEqual(count("**", in: markdown), 0, "value markup is not text")
        XCTAssertEqual(count("example", in: markdown), 0, "link URL")

        let textView = tableTextView(build(table))
        applyNSSearchHighlight(in: textView, term: "needle", focusedOccurrence: nil)
        let drawn = highlights(in: textView)
        XCTAssertEqual(drawn.count, 3, "every counted table match is drawn")
        // One of them is inside the KEY cell "needle key" (band 1, column 0).
        let built = build(table)
        let key = built.layout.cellRanges[1][0]
        XCTAssertTrue(drawn.contains { NSIntersectionRange($0.range, key).length == 6 }, "a key match is highlighted")
        XCTAssertEqual(count("key", in: markdown), 1, "a term only in a key is counted")
    }
}

// MARK: - Untypesettable display math (1.14.3)

extension SearchTests {
    /// A formula shown as its ```latex source is searched as that code block:
    /// each occurrence counted once (not once as math and again as code).
    func testUntypesettableFormulaIsCountedOnceAsItsCodeBlock() {
        let engine = MathRendering(inlineImage: { _, _, _ in nil }, displayHeight: { _, _, _ in 40 },
                                   typesets: { !$0.contains("\\not") })
        let markdown = "$$\nV(e_1) \\not\\le V(e_2) \\quad \\land \\quad V(e_2) \\not\\le V(e_1)\n$$\n\nAfter."
        let blocks = engine.substitutingUntypesettableMath(in: parse(markdown))
        guard case .codeBlock = blocks[0].content else { return XCTFail("formula was not substituted") }

        let results = DocumentSearch.computeMatches(in: blocks, term: "\\not\\le")
        XCTAssertEqual(results.matchBlockIds, [blocks[0].id, blocks[0].id])
        XCTAssertEqual(DocumentSearch.computeMatches(in: blocks, term: "land").matchBlockIds, [blocks[0].id])
    }

    // MARK: - ⌘G within a block

    /// A step to another match of the SAME block used to scroll nothing — in
    /// a block taller than the window the next match could be off screen.
    func testAStepToAnotherMatchOfTheSameBlockScrollsWithinIt() {
        XCTAssertEqual(DocumentSearch.stepScroll(from: "a", to: "a"), .withinBlock)
        XCTAssertEqual(DocumentSearch.stepScroll(from: "a", to: "b"), .toBlock)
        XCTAssertEqual(DocumentSearch.stepScroll(from: nil, to: "b"), .toBlock)
        XCTAssertNil(DocumentSearch.stepScroll(from: "a", to: nil))
    }

    /// Where the list centres a match: the rect of the occurrence the
    /// highlight paints orange, in the text view's coordinates (its container
    /// inset included).
    func testTheMatchRectIsWhereTheFocusedHighlightIs() throws {
        let lines = (0..<120).map { $0 == 3 || $0 == 100 ? "row \($0) needle here" : "row \($0) filler text" }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        textView.textContainerInset = NSSize(width: 7, height: 11)
        textView.isVerticallyResizable = true
        textView.string = lines.joined(separator: "\n")
        textView.sizeToFit()

        let first = try XCTUnwrap(textView.searchMatchRect(term: "NEEDLE", occurrence: 0))
        let second = try XCTUnwrap(textView.searchMatchRect(term: "NEEDLE", occurrence: 1))
        XCTAssertNil(textView.searchMatchRect(term: "needle", occurrence: 2))
        XCTAssertNil(textView.searchMatchRect(term: "absent", occurrence: 0))

        let ranges = searchMatchRanges(in: textView.string, term: "needle")
        for (rect, range) in zip([first, second], ranges) {
            XCTAssertGreaterThan(rect.width, 0)
            let index = textView.characterIndexForInsertion(at: NSPoint(x: rect.midX, y: rect.midY))
            XCTAssertTrue(NSLocationInRange(index, NSRange(location: range.location, length: range.length + 1)),
                          "\(index) not in \(range)")
        }
        XCTAssertGreaterThan(second.midY - first.midY, 90 * 12)
        XCTAssertGreaterThanOrEqual(first.minY, 11)
    }
}
