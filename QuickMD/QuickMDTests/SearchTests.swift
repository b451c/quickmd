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
    }

    private func tables(in blocks: [MarkdownBlock]) -> [Table] {
        blocks.compactMap { block in
            guard case .table(let headers, let rows, let alignments) = block.content else { return nil }
            return Table(block: block, headers: headers, rows: rows, alignments: alignments)
        }
    }

    private func onlyTable(_ markdown: String) -> Table {
        let found = tables(in: parse(markdown))
        XCTAssertEqual(found.count, 1, "fixture must hold exactly one table")
        return found[0]
    }

    private func build(_ table: Table, theme: MarkdownTheme? = nil, fontScale: CGFloat = 1) -> TableText {
        TableTextBuilder.build(headers: table.headers, rows: table.rows, alignments: table.alignments,
                               theme: theme ?? self.theme, fontScale: fontScale)
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
                                                            alignments: table.alignments,
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
}
