import XCTest
import SwiftUI
import AppKit

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

    // MARK: - sourceLine on EVERY block (D8)

    private func firstBlock(_ idPrefix: String, in blocks: [MarkdownBlock]) -> MarkdownBlock? {
        blocks.first { $0.id.hasPrefix(idPrefix) }
    }

    /// Every line number below is the ORIGINAL 0-based one. Front matter is
    /// consumed by the pre-step and the two definition lines are filtered out of
    /// the parser's working `lines`, so each assertion fails if a block reports
    /// its index in the FILTERED array instead of the original document.
    ///
    ///  0 `---`            front matter opens        11 `let x = 1`
    ///  1 `title: Fixture`                           12 ` ``` `
    ///  2 `---`            front matter closes       13 (blank)
    ///  3 `[ref]: …`       filtered                  14 table header
    ///  4 `[^fn]: …`       filtered                  15 table separator
    ///  5 (blank)                                    16 table row
    ///  6 `# Heading`                                17 (blank)
    ///  7 (blank)                                    18 `> quoted line`
    ///  8 `Paragraph …`                              19 (blank)
    ///  9 (blank)                                    20 `> [!NOTE]`
    /// 10 ` ```swift `     fence opens               21 `> alert body`
    ///                                               22 (blank)
    /// 23 `![alt](image.png)`                        24 (blank)
    /// 25 `$$`             math opens                26 `a^2 + b^2`
    /// 27 `$$`             math closes               28 (blank)
    /// 29 ` ```mermaid `   fence opens               30-31 diagram
    /// 32 ` ``` `          last line of the document
    func testEveryBlockKindCarriesOriginalSourceLine() {
        let md = """
        ---
        title: Fixture
        ---
        [ref]: https://example.com
        [^fn]: A footnote definition

        # Heading

        Paragraph text with a [link][ref] and a note[^fn].

        ```swift
        let x = 1
        ```

        | A | B |
        |---|---|
        | 1 | 2 |

        > quoted line

        > [!NOTE]
        > alert body

        ![alt](image.png)

        $$
        a^2 + b^2
        $$

        ```mermaid
        graph TD
        A-->B
        ```
        """
        // Guard the fixture itself: if the line layout above drifts, fail here
        // rather than reporting confusing off-by-N sourceLine mismatches.
        let fixtureLines = md.components(separatedBy: "\n")
        XCTAssertEqual(fixtureLines.count, 33)
        XCTAssertEqual(fixtureLines[6], "# Heading")
        XCTAssertEqual(fixtureLines[25], "$$")

        let blocks = parse(md)

        // Front matter → the line of its opening `---`
        guard case .codeBlock(_, let frontMatterLanguage) = blocks.first?.content else {
            return XCTFail("expected the yaml front-matter block first, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(frontMatterLanguage, "yaml")
        XCTAssertEqual(blocks[0].sourceLine, 0, "front matter starts at its opening ---")

        // Heading — stored value and the associated one section copy reads
        guard let heading = firstBlock("heading-", in: blocks),
              case .heading(_, let title, let associatedLine) = heading.content else {
            return XCTFail("expected a heading, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(title, "Heading")
        XCTAssertEqual(heading.sourceLine, 6)
        XCTAssertEqual(associatedLine, heading.sourceLine,
                       "stored sourceLine must equal .heading's associated sourceLine")

        // Paragraph — the blank line at 7 was buffered with it but must not be
        // claimed as its start.
        let paragraph = blocks.first { plainText($0)?.contains("Paragraph text") == true }
        XCTAssertEqual(paragraph?.sourceLine, 8, "text block starts at its first non-blank line")

        // Fenced code — the OPENING fence, not the closing one
        let swiftFence = blocks.first {
            if case .codeBlock(_, let language) = $0.content { return language == "swift" }
            return false
        }
        XCTAssertEqual(swiftFence?.sourceLine, 10)

        XCTAssertEqual(firstBlock("table-", in: blocks)?.sourceLine, 14, "table starts at its header row")
        XCTAssertEqual(firstBlock("blockquote-", in: blocks)?.sourceLine, 18)
        XCTAssertEqual(firstBlock("alert-", in: blocks)?.sourceLine, 20)
        XCTAssertEqual(firstBlock("image-", in: blocks)?.sourceLine, 23)
        XCTAssertEqual(firstBlock("math-", in: blocks)?.sourceLine, 25, "math starts at its opening $$")
        XCTAssertEqual(firstBlock("mermaid-", in: blocks)?.sourceLine, 29)

        // The synthetic footnote block renders after everything, so it anchors to
        // the last line of the document (keeps sourceLine non-decreasing).
        guard let last = blocks.last, let footnotes = plainText(last) else {
            return XCTFail("expected the footnote block last, got \(blocks.map(\.id))")
        }
        XCTAssertTrue(footnotes.contains("A footnote definition"))
        XCTAssertEqual(last.sourceLine, 32)

        // Nothing may point past the document, and the list must never go backwards.
        XCTAssertTrue(blocks.allSatisfy { $0.sourceLine >= 0 && $0.sourceLine < fixtureLines.count })
        XCTAssertEqual(blocks.map(\.sourceLine), blocks.map(\.sourceLine).sorted(),
                       "block sourceLines must be non-decreasing in document order")
    }

    func testChunkedTextRunReportsEachChunksOwnFirstLine() {
        // 80 paragraphs, each followed by a blank line → one 160-line buffer that
        // flushTextBuffer splits at blank-line boundaries.
        var lines: [String] = []
        for n in 1...80 {
            lines.append("paragraph \(n)")
            lines.append("")
        }
        let blocks = parse(lines.joined(separator: "\n"))
        let textBlocks = blocks.filter { $0.id.hasPrefix("text-") }
        XCTAssertGreaterThan(textBlocks.count, 1, "a 160-line run must split into several blocks")

        let sourceLines = textBlocks.map(\.sourceLine)
        XCTAssertEqual(sourceLines.first, 0)
        XCTAssertEqual(sourceLines, sourceLines.sorted())
        XCTAssertEqual(Set(sourceLines).count, sourceLines.count,
                       "chunk sourceLines must be strictly increasing, not repeated")

        // Each chunk's sourceLine must be the ORIGINAL line of the first line it
        // renders — a shared buffer start (0 for every chunk) fails here.
        for block in textBlocks {
            guard let rendered = plainText(block) else {
                return XCTFail("\(block.id) is not a text block")
            }
            let firstRenderedLine = rendered.components(separatedBy: "\n").first {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            XCTAssertEqual(firstRenderedLine, lines[block.sourceLine],
                           "\(block.id) claims line \(block.sourceLine)")
        }
    }

    func testHeadingStoredSourceLineMatchesAssociatedValue() {
        // 0 `[ref]: …` (filtered), 1 blank, 2 `# ATX`, 3 `body`, 4 blank,
        // 5 `Setext`, 6 `------`
        let md = """
        [ref]: https://example.com

        # ATX
        body

        Setext
        ------
        """
        let headings = parse(md).filter { $0.id.hasPrefix("heading-") }
        XCTAssertEqual(headings.count, 2, "expected one ATX and one setext heading")
        for heading in headings {
            guard case .heading(_, let title, let associatedLine) = heading.content else {
                return XCTFail("\(heading.id) is not a heading")
            }
            XCTAssertEqual(heading.sourceLine, associatedLine, "\(title)")
        }
        XCTAssertEqual(headings[0].sourceLine, 2)
        XCTAssertEqual(headings[1].sourceLine, 5, "setext: the text line, not the ---- underline")
    }

    // MARK: - Definition lists (PHP Markdown Extra / Pandoc)

    /// Rendered lines of a `.text` block, blank ones dropped and each trimmed —
    /// the definition indent is a rendering detail (pinned in RendererTests).
    private func textLines(_ block: MarkdownBlock) -> [String] {
        (plainText(block) ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Terms are the only bold thing a definition list produces, so "no bold
    /// run" is how a test says "this stayed an ordinary paragraph".
    private func hasBoldRun(_ block: MarkdownBlock) -> Bool {
        guard case .text(let attr) = block.content else { return false }
        return attr.runs.contains {
            $0[AttributeScopes.AppKitAttributes.FontAttribute.self]?
                .fontDescriptor.symbolicTraits.contains(.bold) == true
        }
    }

    /// Same idea for the definition body's hanging indent.
    private func hasIndentedRun(_ block: MarkdownBlock) -> Bool {
        guard case .text(let attr) = block.content else { return false }
        return attr.runs.contains {
            ($0[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self]?.firstLineHeadIndent ?? 0) > 0
        }
    }

    func testTightDefinitionListIsOneTextBlock() {
        let blocks = parse("Apple\n: A fruit\n: A company")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertTrue(blocks[0].id.hasPrefix("text-"))
        XCTAssertEqual(textLines(blocks[0]), ["Apple", "A fruit", "A company"])
        XCTAssertTrue(hasBoldRun(blocks[0]), "the term must render semibold")
        XCTAssertTrue(hasIndentedRun(blocks[0]), "definitions must be indented")
    }

    func testMultipleTermsShareTheirDefinition() {
        let blocks = parse("Apple\nOrange\n: The fruit")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(textLines(blocks[0]), ["Apple", "Orange", "The fruit"])
    }

    func testLooseDefinitionsStayInOneBlock() {
        // A blank line between two `: ` lines is a loose list, not two blocks.
        let blocks = parse("Term\n: first\n\n: second")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(textLines(blocks[0]), ["Term", "first", "second"])
    }

    func testSecondTermGroupStaysInTheSameBlock() {
        let blocks = parse("Apple\n: fruit\n\nOrange\n: citrus")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(textLines(blocks[0]), ["Apple", "fruit", "Orange", "citrus"])
        // …separated by a blank line, so the groups read apart on screen and in print.
        let raw = (plainText(blocks[0]) ?? "").components(separatedBy: "\n")
        XCTAssertEqual(raw.count, 6, "\(raw)")
        XCTAssertTrue(raw[2].isEmpty, "expected a blank line between groups: \(raw)")
    }

    func testDefinitionAbsorbsLazyContinuationLines() {
        let blocks = parse("Term\n: first part\n  wrapped tail")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(plainText(blocks[0])?.contains("first part wrapped tail"), true,
                       "\(plainText(blocks[0]) ?? "")")
    }

    /// A hard break on the definition's FIRST line must survive the `: ` marker:
    /// the marker scanner may only drop the padding in front of the text.
    func testHardBreakAfterTheDefinitionMarkerSurvives() {
        let blocks = parse("Term\n: first line  \nsecond line")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(textLines(blocks[0]), ["Term", "first line", "second line"])
    }

    func testEmojiShortcodeIsNotADefinitionList() {
        // `:smile:` has no space after the colon, so it is not a marker.
        let blocks = parse("Reaction\n:smile:")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(plainText(blocks[0])?.contains(":smile:"), true)
        XCTAssertFalse(hasBoldRun(blocks[0]), "must stay an ordinary paragraph")
        XCTAssertFalse(hasIndentedRun(blocks[0]), "must stay an ordinary paragraph")
    }

    func testInlineColonIsNotADefinitionList() {
        let blocks = parse("Warning\nNote: the colon is not first")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(plainText(blocks[0])?.contains("Warning Note: the colon is not first"), true,
                       "\(plainText(blocks[0]) ?? "")")
        XCTAssertFalse(hasBoldRun(blocks[0]), "must stay an ordinary paragraph")
        XCTAssertFalse(hasIndentedRun(blocks[0]), "must stay an ordinary paragraph")
    }

    func testDefinitionListAfterAParagraphFlushesThatParagraphSeparately() {
        // 0 `Intro paragraph.`, 1 blank, 2 `Term`, 3 `: definition`
        let blocks = parse("Intro paragraph.\n\nTerm\n: definition")
        XCTAssertEqual(blocks.count, 2, "\(blocks.map(\.id))")
        XCTAssertEqual(textLines(blocks[0]), ["Intro paragraph."])
        XCTAssertFalse(hasBoldRun(blocks[0]), "the paragraph must not be swallowed as a term")
        XCTAssertEqual(textLines(blocks[1]), ["Term", "definition"])
        XCTAssertEqual(blocks[1].sourceLine, 2, "the block starts at its first term line")
    }

    /// PHP Markdown Extra reads every non-blank line directly above the first
    /// `: ` line as a term, so a prose line with no blank line under it becomes
    /// one too. Pinned deliberately: it is the price of supporting several terms
    /// per definition, which has exactly the same shape.
    func testProseLineDirectlyAboveADefinitionBecomesATerm() {
        let blocks = parse("Intro line\nTerm\n: definition")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(textLines(blocks[0]), ["Intro line", "Term", "definition"])
        XCTAssertEqual(blocks[0].sourceLine, 0)
    }

    func testDefinitionListSourceLineSurvivesDefinitionFiltering() {
        // The `[ref]:` line is dropped by the pre-pass, so a block reporting its
        // index in the FILTERED array would claim line 1 instead of 2.
        let blocks = parse("[ref]: https://example.com\n\nTerm\n: definition")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        XCTAssertEqual(blocks[0].sourceLine, 2)
    }

    func testDefinitionListEndsAtTheNextBlock() {
        let blocks = parse("Term\n: definition\n# Heading")
        XCTAssertEqual(blocks.map { String($0.id.split(separator: "-")[0]) }, ["text", "heading"])
        guard case .heading(_, let title, let line) = blocks[1].content else {
            return XCTFail("expected the heading to survive")
        }
        XCTAssertEqual(title, "Heading")
        XCTAssertEqual(line, 2)
    }

    func testParagraphAfterADefinitionListIsItsOwnBlock() {
        let blocks = parse("Term\n: definition\n\nNext paragraph.")
        XCTAssertEqual(blocks.count, 2, "\(blocks.map(\.id))")
        XCTAssertEqual(textLines(blocks[0]), ["Term", "definition"])
        XCTAssertEqual(textLines(blocks[1]), ["Next paragraph."])
        XCTAssertFalse(hasBoldRun(blocks[1]))
    }

    func testDefinitionListInsideBlockquoteIsLeftToTheBlockquote() {
        let blocks = parse("> Term\n> : definition")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        guard case .blockquote(let content, let level) = blocks[0].content else {
            return XCTFail("expected a blockquote, got \(blocks[0].id)")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(content, "Term\n: definition")
    }

    func testDefinitionMarkerInsideCodeFenceIsNotADefinitionList() {
        let blocks = parse("```\nTerm\n: definition\n```")
        XCTAssertEqual(blocks.count, 1, "\(blocks.map(\.id))")
        guard case .codeBlock(let code, _) = blocks[0].content else {
            return XCTFail("expected a code block, got \(blocks[0].id)")
        }
        XCTAssertEqual(code, "Term\n: definition")
    }

    func testDefinitionWithoutATermStaysParagraph() {
        let blocks = parse("# Heading\n: orphan definition")
        XCTAssertEqual(blocks.map { String($0.id.split(separator: "-")[0]) }, ["heading", "text"])
        XCTAssertEqual(plainText(blocks[1])?.contains(": orphan definition"), true)
        XCTAssertFalse(hasBoldRun(blocks[1]))
        XCTAssertFalse(hasIndentedRun(blocks[1]))
    }

    func testTableRowIsNotTakenAsADefinitionTerm() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |
        : definition
        """
        let blocks = parse(md)
        guard case .table(let headers, let rows, _) = blocks.first?.content else {
            return XCTFail("expected the table to survive, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(headers, ["A", "B"])
        XCTAssertEqual(rows.count, 1)
        // With no term above it the `: ` line is just paragraph text.
        XCTAssertEqual(blocks.count, 2, "\(blocks.map(\.id))")
        XCTAssertFalse(hasBoldRun(blocks[1]))
    }

    /// Blank lines between two non-text blocks used to flush an EMPTY `.text`
    /// block (rendered as a ~42 pt gap between adjacent blockquotes). The parser
    /// now drops all-blank buffers and all-blank chunks.
    func testBlankLinesBetweenBlocksDoNotProduceEmptyTextBlocks() {
        let md = """
        > first quote

        > second quote

        # Heading

        ```swift
        let x = 1
        ```
        """
        let blocks = parse(md)
        let empties = blocks.filter { plainText($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true }
        XCTAssertTrue(empties.isEmpty, "empty text blocks: \(empties.map(\.id))")
        XCTAssertEqual(blocks.map { String($0.id.split(separator: "-")[0]) }, ["blockquote", "blockquote", "heading", "code"])

        // A very long run of blank lines (longer than a text chunk) is dropped too.
        let longGap = "para one\n" + String(repeating: "\n", count: 80) + "para two"
        let gapBlocks = parse(longGap)
        XCTAssertEqual(gapBlocks.count, 2, "\(gapBlocks.map(\.id))")
        XCTAssertEqual(gapBlocks[1].sourceLine, 81)
    }
}
