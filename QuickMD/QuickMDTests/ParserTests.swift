import XCTest
import SwiftUI

/// Golden tests for MarkdownBlockParser. Each documented parser constraint
/// (docs/constraints.md) has a test here so regressions fail mechanically
/// instead of surfacing as user bug reports.
final class ParserTests: XCTestCase {

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    private func plainText(_ block: MarkdownBlock) -> String? {
        if case .text(let attr) = block.content { return String(attr.characters) }
        return nil
    }

    // MARK: - Headings

    func testATXHeadingLevelsAndSourceLines() {
        let md = """
        # One
        text
        ## Two
        ###### Six
        """
        let blocks = parse(md)
        let headings: [(level: Int, title: String, line: Int)] = blocks.compactMap {
            if case .heading(let level, let title, let sourceLine) = $0.content {
                return (level, title, sourceLine)
            }
            return nil
        }
        XCTAssertEqual(headings.count, 3)
        XCTAssertEqual(headings[0].level, 1)
        XCTAssertEqual(headings[0].title, "One")
        XCTAssertEqual(headings[0].line, 0)
        XCTAssertEqual(headings[1].level, 2)
        XCTAssertEqual(headings[1].line, 2)
        XCTAssertEqual(headings[2].level, 6)
        XCTAssertEqual(headings[2].line, 3)
    }

    func testSetextHeadings() {
        let md = """
        Title
        =====
        Subtitle
        --------
        body
        """
        let blocks = parse(md)
        guard case .heading(let l1, let t1, let s1) = blocks[0].content,
              case .heading(let l2, let t2, let s2) = blocks[1].content else {
            return XCTFail("expected two setext headings, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(l1, 1); XCTAssertEqual(t1, "Title"); XCTAssertEqual(s1, 0)
        XCTAssertEqual(l2, 2); XCTAssertEqual(t2, "Subtitle"); XCTAssertEqual(s2, 2)
    }

    func testTextDirectlyFollowedByDashesIsSetextH2() {
        // CommonMark: a paragraph line followed by 3+ dashes is a setext H2
        // (the heading wins over a thematic break). This branch was dead code
        // until the redundant isTableSeparator guard was removed.
        let blocks = parse("Subtitle\n-----")
        guard case .heading(let level, let title, _) = blocks[0].content else {
            return XCTFail("expected setext H2, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(title, "Subtitle")
    }

    // MARK: - YAML frontmatter

    func testYAMLFrontmatterRendersAsCodeBlock() {
        let md = """
        ---
        title: My Post
        date: 2026-01-01
        ---
        # Real Heading
        """
        let blocks = parse(md)
        guard case .codeBlock(let code, let language) = blocks[0].content else {
            return XCTFail("expected yaml code block first, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(language, "yaml")
        XCTAssertEqual(code, "title: My Post\ndate: 2026-01-01")
        // The first frontmatter key must NOT become a setext heading
        guard case .heading(_, let title, let sourceLine) = blocks[1].content else {
            return XCTFail("expected heading after frontmatter")
        }
        XCTAssertEqual(title, "Real Heading")
        XCTAssertEqual(sourceLine, 4)
    }

    func testUnclosedLeadingDashesAreNotFrontmatter() {
        let md = """
        ---
        just text, no closing fence
        """
        let blocks = parse(md)
        let codeBlocks = blocks.filter {
            if case .codeBlock = $0.content { return true }
            return false
        }
        XCTAssertTrue(codeBlocks.isEmpty, "unclosed --- must not be treated as frontmatter")
    }

    func testHeadingSourceLineSurvivesDefinitionFiltering() {
        // Reference-link and footnote definitions are filtered out in a pre-pass;
        // sourceLine must still point into the ORIGINAL text.
        let md = """
        [ref]: https://example.com

        # Heading
        """
        let blocks = parse(md)
        let heading = blocks.compactMap { block -> Int? in
            if case .heading(_, _, let sourceLine) = block.content { return sourceLine }
            return nil
        }.first
        XCTAssertEqual(heading, 2)
    }

    // MARK: - Code fences (constraint: code BEFORE math/headings)

    func testCodeFenceProtectsDisplayMath() {
        let md = """
        ```
        $$not math$$
        ```
        """
        let blocks = parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .codeBlock(let code, _) = blocks[0].content else {
            return XCTFail("expected code block, got \(blocks[0].id)")
        }
        XCTAssertEqual(code, "$$not math$$")
    }

    func testCodeFenceProtectsHeadings() {
        let md = """
        ```bash
        # this is a comment, not a heading
        ```
        # Real Heading
        """
        let blocks = parse(md)
        let headings = blocks.filter {
            if case .heading = $0.content { return true }
            return false
        }
        XCTAssertEqual(headings.count, 1)
        guard case .heading(_, let title, let sourceLine) = headings[0].content else { return }
        XCTAssertEqual(title, "Real Heading")
        XCTAssertEqual(sourceLine, 3)
    }

    func testTildeFenceAndLanguageTag() {
        let md = """
        ~~~python
        x = 1
        ~~~
        """
        let blocks = parse(md)
        guard case .codeBlock(let code, let language) = blocks[0].content else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(language, "python")
        XCTAssertEqual(code, "x = 1")
    }

    func testUnclosedFenceConsumesToEOF() {
        let md = """
        ```
        no closing fence
        still code
        """
        let blocks = parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .codeBlock(let code, _) = blocks[0].content else {
            return XCTFail("expected code block")
        }
        XCTAssertTrue(code.contains("still code"))
    }

    func testMermaidFenceBecomesDiagram() {
        let md = """
        ```mermaid
        graph TD
        A-->B
        ```
        """
        let blocks = parse(md)
        guard case .mermaidDiagram(let source) = blocks[0].content else {
            return XCTFail("expected mermaid diagram")
        }
        XCTAssertEqual(source, "graph TD\nA-->B")
    }

    // MARK: - Display math

    func testSingleLineDisplayMath() {
        let blocks = parse("$$x^2 + y^2$$")
        XCTAssertEqual(blocks.count, 1)
        guard case .mathBlock(let latex) = blocks[0].content else {
            return XCTFail("expected math block")
        }
        XCTAssertEqual(latex, "x^2 + y^2")
    }

    func testMultiLineDisplayMath() {
        let md = """
        $$
        \\frac{a}{b}
        $$
        after
        """
        let blocks = parse(md)
        guard case .mathBlock(let latex) = blocks[0].content else {
            return XCTFail("expected math block")
        }
        XCTAssertEqual(latex, "\\frac{a}{b}")
        XCTAssertEqual(plainText(blocks[1])?.contains("after"), true)
    }

    func testCRLFDocumentParsesAfterNormalization() {
        // End-to-end for the document boundary: CRLF input normalized, then the
        // single-line $$..$$ suffix check works (it fails on a raw "\r").
        let crlf = "$$x^2$$\r\n\r\nplain text\r\n"
        let normalized = MarkdownDocument.normalizeLineEndings(crlf)
        let blocks = parse(normalized)
        guard case .mathBlock(let latex) = blocks[0].content else {
            return XCTFail("expected math block first, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(latex, "x^2")
        XCTAssertEqual(plainText(blocks[1])?.contains("plain text"), true)
    }

    // MARK: - Footnotes before reference links (constraint)

    func testFootnoteDefinitionsBeforeReferenceLinkDefinitions() {
        let md = """
        Uses a footnote[^1] and a [link][ref].

        [^1]: The footnote text
        [ref]: https://example.com
        """
        let blocks = parse(md)
        // Footnotes are appended as a final text block
        guard let last = blocks.last, let footnotes = plainText(last) else {
            return XCTFail("expected footnote block at end")
        }
        XCTAssertTrue(footnotes.contains("The footnote text"))
        // The reference link must resolve (not be eaten by the footnote pattern)
        guard case .text(let attr) = blocks[0].content else {
            return XCTFail("expected text block first")
        }
        let links = attr.runs.compactMap(\.link)
        XCTAssertEqual(links.first?.absoluteString, "https://example.com")
    }

    // MARK: - Tables

    func testTableParsingWithAlignmentsAndNormalization() {
        let md = """
        | A | B | C |
        |:--|:-:|--:|
        | 1 | 2 |
        | 1 | 2 | 3 | 4 |
        """
        let blocks = parse(md)
        guard case .table(let headers, let rows, let alignments) = blocks[0].content else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(headers, ["A", "B", "C"])
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
        // Short row padded, long row trimmed — always exactly 3 columns
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.count == 3 })
    }

    func testHeaderlessTableKeepsColumnsFromSeparator() {
        let md = """
        | | |
        |---|---|
        | **Kettle** | Boils water in about three minutes |
        | **Toaster** | Two slots, one crumb tray |
        """
        let blocks = parse(md)
        guard case .table(let headers, let rows, let alignments) = blocks[0].content else {
            return XCTFail("expected table")
        }
        // Empty header row must not collapse the table — separator defines 2 columns
        XCTAssertEqual(headers, ["", ""])
        XCTAssertEqual(alignments.count, 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["**Kettle**", "Boils water in about three minutes"])
        XCTAssertEqual(rows[1], ["**Toaster**", "Two slots, one crumb tray"])
    }

    // MARK: - Blockquotes

    func testBlockquoteNestingLevels() {
        let md = """
        > level one
        >> level two
        """
        let blocks = parse(md)
        let quotes: [(content: String, level: Int)] = blocks.compactMap {
            if case .blockquote(let content, let level) = $0.content { return (content, level) }
            return nil
        }
        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(quotes[0].level, 1)
        XCTAssertEqual(quotes[1].level, 2)
    }

    // MARK: - Images

    func testStandaloneImageBlock() {
        let blocks = parse("![alt text](image.png)")
        guard case .image(let url, let alt) = blocks[0].content else {
            return XCTFail("expected image block")
        }
        XCTAssertEqual(url, "image.png")
        XCTAssertEqual(alt, "alt text")
    }

    // MARK: - Text chunking (constraint: ≤30 lines per text block)

    func testLongListsAreChunkedAtBlankLineBoundaries() {
        var lines: [String] = []
        for i in 1...70 {
            lines.append("- item \(i)")
            if i % 10 == 0 { lines.append("") }
        }
        let blocks = parse(lines.joined(separator: "\n"))
        let textBlocks = blocks.filter {
            if case .text = $0.content { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(textBlocks.count, 3,
            "70-line list should split into several ≤30-line text blocks")
    }

    // MARK: - Stable block identity

    func testBlockIdsAreStableAndUnique() {
        let md = """
        # H
        text

        ```
        code
        ```
        """
        let blocks = parse(md)
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count, "ids must be unique")
        let again = parse(md)
        XCTAssertEqual(blocks.map(\.id), again.map(\.id), "ids must be deterministic")
    }

    // MARK: - GFM Alerts

    func testAllFiveAlertKindsParse() {
        for (marker, expected) in [("NOTE", AlertKind.note), ("TIP", .tip), ("IMPORTANT", .important),
                                   ("WARNING", .warning), ("CAUTION", .caution)] {
            let blocks = parse("> [!\(marker)]\n> Body line.")
            guard case .alert(let kind, let content) = blocks.first?.content else {
                XCTFail("[!\(marker)] should parse as an alert"); continue
            }
            XCTAssertEqual(kind, expected)
            XCTAssertEqual(content, "Body line.")
        }
    }

    func testAlertMarkerIsCaseInsensitive() {
        let blocks = parse("> [!note]\n> body")
        guard case .alert(let kind, _) = blocks.first?.content else {
            return XCTFail("lowercase marker should parse as alert (GitHub behavior)")
        }
        XCTAssertEqual(kind, .note)
    }

    func testAlertMarkerWithTrailingTextStaysBlockquote() {
        let blocks = parse("> [!NOTE] this is not an alert")
        guard case .blockquote(let content, let level) = blocks.first?.content else {
            return XCTFail("marker with trailing text must remain a regular blockquote")
        }
        XCTAssertEqual(level, 1)
        XCTAssertTrue(content.contains("[!NOTE] this is not an alert"))
    }

    func testUnknownAlertKindStaysBlockquote() {
        let blocks = parse("> [!DANGER]\n> body")
        guard case .blockquote = blocks.first?.content else {
            return XCTFail("unknown alert kind must remain a regular blockquote")
        }
    }

    func testNestedQuoteIsNotAlert() {
        let blocks = parse("> > [!NOTE]\n> > body")
        guard case .blockquote(_, let level) = blocks.first?.content else {
            return XCTFail("nested quote must not become an alert")
        }
        XCTAssertEqual(level, 2)
    }

    func testAlertWithEmptyBodyParses() {
        let blocks = parse("> [!WARNING]")
        guard case .alert(let kind, let content) = blocks.first?.content else {
            return XCTFail("header-only alert should still parse")
        }
        XCTAssertEqual(kind, .warning)
        XCTAssertTrue(content.isEmpty)
    }

    func testAlertMultilineBodyPreserved() {
        let blocks = parse("> [!TIP]\n> First line.\n> Second **bold** line.")
        guard case .alert(_, let content) = blocks.first?.content else {
            return XCTFail("expected alert")
        }
        XCTAssertEqual(content, "First line.\nSecond **bold** line.")
    }

    func testAlertContentIsSearchable() {
        let blocks = parse("> [!NOTE]\n> findme here")
        let results = DocumentSearch.computeMatches(in: blocks, term: "findme")
        XCTAssertEqual(results.matchBlockIds.count, 1)
        XCTAssertTrue(results.matchBlockIds[0].hasPrefix("alert-"))
    }
}
