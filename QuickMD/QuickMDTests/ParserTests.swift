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

    /// CommonMark's closing sequence is not heading text; the same rows on
    /// GitHub show "Install", "Issue", "", "C#", "foo ###" and "Tag #42".
    func testATXClosingSequenceIsNotPartOfTheTitle() {
        // Built line by line: the second keeps its trailing spaces
        let md = ["## Install ##", "## Issue #  ", "### ###", "# C#", "## foo \\###", "## Tag #42"]
            .joined(separator: "\n")
        let titles: [String] = parse(md).compactMap {
            if case .heading(_, let title, _) = $0.content { return title }
            return nil
        }
        XCTAssertEqual(titles, ["Install", "Issue", "", "C#", "foo \\###", "Tag #42"])
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

    /// Front matter outside `FrontMatter`'s subset (here a nested mapping)
    /// stays the yaml code block, verbatim.
    func testYAMLFrontmatterRendersAsCodeBlock() {
        let md = """
        ---
        title: My Post
        author:
          name: Ann
        ---
        # Real Heading
        """
        let blocks = parse(md)
        guard case .codeBlock(let code, let language) = blocks[0].content else {
            return XCTFail("expected yaml code block first, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(language, "yaml")
        XCTAssertEqual(code, "title: My Post\nauthor:\n  name: Ann")
        XCTAssertEqual(blocks[0].sourceLine, 0)
        // The first frontmatter key must NOT become a setext heading
        guard case .heading(_, let title, let sourceLine) = blocks[1].content else {
            return XCTFail("expected heading after frontmatter")
        }
        XCTAssertEqual(title, "Real Heading")
        XCTAssertEqual(sourceLine, 5)
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

    /// A ```svg fence is an image block (decoded natively by NSImage), not a
    /// code block — case-insensitive like the mermaid fence, markup verbatim.
    func testSvgFenceBecomesSvgImage() {
        for lang in ["svg", "SVG"] {
            let md = """
            ```\(lang)
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">
              <rect width="20" height="10"/>
            </svg>
            ```
            """
            let blocks = parse(md)
            guard case .svgImage(let source) = blocks[0].content else {
                return XCTFail("expected svg image block for ```\(lang)")
            }
            XCTAssertTrue(source.hasPrefix("<svg"))
            XCTAssertTrue(source.hasSuffix("</svg>"))
            XCTAssertEqual(blocks[0].id, "svg-0")
        }
    }

    /// The decode used on screen and in print: declared size, viewBox-only and
    /// size-less markup all yield an image; a script element is inert; text
    /// that is not SVG yields nil (the views then degrade to a notice / code).
    func testSvgDecodeAcceptsMarkupAndRejectsGarbage() {
        let sized = SVGImageDecoder.decode(#"<svg xmlns="http://www.w3.org/2000/svg" width="320" height="120"><rect width="320" height="120"/></svg>"#)
        XCTAssertEqual(sized?.size, CGSize(width: 320, height: 120))
        let viewBox = SVGImageDecoder.decode(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 50"><rect width="200" height="50"/></svg>"#)
        XCTAssertEqual(viewBox?.size, CGSize(width: 200, height: 50))
        XCTAssertNotNil(SVGImageDecoder.decode(#"<svg xmlns="http://www.w3.org/2000/svg"><circle cx="20" cy="20" r="10"/></svg>"#))
        XCTAssertNotNil(SVGImageDecoder.decode(#"<svg width="10" height="10"><script>alert(1)</script><rect width="10" height="10"/></svg>"#))
        XCTAssertNil(SVGImageDecoder.decode("not svg at all"))
        XCTAssertNil(SVGImageDecoder.decode(""))
        XCTAssertNil(SVGImageDecoder.decode("<div>html, not svg</div>"))
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

    /// The blank line keeps `[ref]:` out of the footnote: right under a
    /// `[^1]:` line it is the footnote's lazy TEXT on GitHub
    /// (`testALinkDefinitionRightUnderAFootnoteIsItsText`).
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
        guard case .table(let headers, let rows, let alignments, .grid) = blocks[0].content else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(headers, ["A", "B", "C"])
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
        // Short row padded, long row trimmed — always exactly 3 columns
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.count == 3 })
    }

    /// GFM spec (tables extension, example 204): "The remainder of the table's
    /// rows may vary in the number of cells. If a number of cells fewer than
    /// the number of cells in the header row, empty cells are inserted. If
    /// greater, the excess is ignored". Dropping the excess is by design.
    func testBodyRowCellCountFollowsGFM() {
        let md = """
        | abc | def |
        | --- | --- |
        | bar |
        | bar | baz | boo |
        """
        guard case .table(let headers, let rows, _, .grid) = parse(md)[0].content else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(headers, ["abc", "def"])
        XCTAssertEqual(rows, [["bar", ""], ["bar", "baz"]])
    }

    /// A pipe followed by a combining mark is ONE Swift Character; GFM splits on
    /// the code point, so the cell still ends there and the mark opens the next
    /// cell. Escaped pipes before a mark stay in the cell, as before.
    func testPipeBeforeCombiningMarkStillSplits() {
        let md = "| a |\u{0301}b | c |\n| --- | --- | --- |\n| x |\u{0301}y | z |\n| e \\|\u{0301} f | g |"
        guard case .table(let headers, let rows, _, .grid) = parse(md)[0].content else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(headers.map { Array($0.unicodeScalars) },
                       ["a", "\u{0301}b", "c"].map { Array($0.unicodeScalars) })
        XCTAssertEqual(rows.map { $0.map { Array($0.unicodeScalars) } },
                       [["x", "\u{0301}y", "z"], ["e |\u{0301} f", "g", ""]]
                        .map { $0.map { Array($0.unicodeScalars) } })
    }

    func testHeaderlessTableKeepsColumnsFromSeparator() {
        let md = """
        | | |
        |---|---|
        | **Kettle** | Boils water in about three minutes |
        | **Toaster** | Two slots, one crumb tray |
        """
        let blocks = parse(md)
        guard case .table(let headers, let rows, let alignments, .grid) = blocks[0].content else {
            return XCTFail("expected table")
        }
        // Empty header row must not collapse the table — separator defines 2 columns
        XCTAssertEqual(headers, ["", ""])
        XCTAssertEqual(alignments.count, 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["**Kettle**", "Boils water in about three minutes"])
        XCTAssertEqual(rows[1], ["**Toaster**", "Two slots, one crumb tray"])
    }

    func testEscapedPipeStaysInsideItsCell() {
        let md = """
        | Command | Purpose |
        | --- | --- |
        | `collect [--part 1\\|2]` | a \\| b |
        | path\\\\ | after an escaped backslash |
        | ends with pipe \\| | x |
        | path\\\\| c |
        | `p\\\\|q` | c |
        """
        let blocks = parse(md)
        guard case .table(let headers, let rows, _, .grid) = blocks[0].content else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(headers, ["Command", "Purpose"])
        // `\\|` is a literal pipe, also inside a code span (GFM)
        XCTAssertEqual(rows[0], ["`collect [--part 1|2]`", "a | b"])
        // `\\\\ |`: a space before the pipe, so it splits
        XCTAssertEqual(rows[1], ["path\\\\", "after an escaped backslash"])
        XCTAssertEqual(rows[2], ["ends with pipe |", "x"])
        // `\\\\|`: a pipe right after a backslash never splits, as on GitHub
        // (checked with its renderer: "path| c" in one cell, code `p\|q`);
        // one backslash is dropped and the inline renderer handles the rest
        XCTAssertEqual(rows[3], ["path\\| c", ""])
        XCTAssertEqual(rows[4], ["`p\\|q`", "c"])
    }

    // MARK: - A line that is only one linked image (B16)

    /// `[![alt](img)](url)` alone in its paragraph is the picture, like
    /// `![alt](img)` and `<a href><img></a>` — an `.image` block on that line
    /// (Section copy, search of the alt and copy work as for a plain image
    /// line). Since 1.15 it keeps its link (a click follows it). Text beside
    /// it stays a paragraph; two linked images are an image row (1.15).
    func testLineOfOneLinkedImageIsAnImageBlock() {
        let md = """
        # Title
        [![Logo](img/logo.png)](https://example.com)

          [![Badge][shield]][site]\u{0020}\u{0020}

        ![Plain](img/plain.png)

        text before [![a](a.png)](https://a.example)

        [![a](a.png)](https://a.example) text after

        [![a](a.png)](https://a.example) [![b](b.png)](https://b.example)

        [![a](a.png)][undefined]

        [shield]: https://img.shields.io/x.svg
        [site]: https://example.com/site
        """
        let blocks = parse(md)
        let images: [(url: String, alt: String, line: Int)] = blocks.compactMap {
            guard case .image(let url, let alt, nil, _) = $0.content else { return nil }
            return (url, alt, $0.sourceLine)
        }
        XCTAssertEqual(images.map(\.url), ["img/logo.png", "https://img.shields.io/x.svg", "img/plain.png"])
        XCTAssertEqual(images.map(\.alt), ["Logo", "Badge", "Plain"])
        XCTAssertEqual(images.map(\.line), [1, 3, 5], "each on its own source line")

        let links: [URL?] = blocks.compactMap {
            guard case .image(_, _, nil, let link) = $0.content else { return nil }
            return .some(link)
        }
        XCTAssertEqual(links, [URL(string: "https://example.com"), URL(string: "https://example.com/site"), nil])

        let paragraphs = blocks.compactMap(plainText)
        XCTAssertEqual(paragraphs.count, 3, "\(paragraphs)")
        XCTAssertTrue(paragraphs[0].hasPrefix("text before [Image: a]"))
        XCTAssertEqual(paragraphs[1], "[Image: a] text after")
        XCTAssertTrue(paragraphs[2].contains("[undefined]"), "no link → not a linked image")
        XCTAssertEqual(imageRows(blocks).map { $0.map(\.alt) }, [["a", "b"]], "a badge row is a row (1.15)")

        // Exactly what a plain `![Logo](img/logo.png)` line parses to, id and link aside.
        guard case .image(let url, let alt, let width, let plainLink) = parse("![Logo](img/logo.png)")[0].content,
              case .image(let linkedURL, let linkedAlt, let linkedWidth, let link) =
                parse("[![Logo](img/logo.png)](https://example.com)")[0].content else { return XCTFail("images") }
        XCTAssertEqual([url, alt], [linkedURL, linkedAlt])
        XCTAssertNil(width); XCTAssertNil(linkedWidth)
        XCTAssertNil(plainLink)
        XCTAssertEqual(link, URL(string: "https://example.com"))
    }

    /// After the vertical-rhythm merge (rows rendered at the end of the
    /// parse, ordered hangs over the whole document), checked against GitHub
    /// (`gh api markdown`): a linked image indented under a list stands in
    /// like a plain image and keeps the list going (`10.` hangs the items
    /// above it); a line of `&nbsp;` is a paragraph (`<p>&nbsp;</p>`), not a
    /// blank line; `&#49;. x` is paragraph text "1. x", never a list item
    /// (references are decoded after block parsing).
    func testMergedRowRenderingWithLinkedImagesAndReferences() {
        func hangs(_ md: String) -> [CGFloat] {
            parse(md).compactMap { block -> CGFloat? in
                guard case .text(let attributed) = block.content,
                      let style = attributed.runs.first?[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self]
                else { return nil }
                return style.headIndent
            }
        }
        let linked = "1. one\n2. two\n\n   [![b](b.png)](https://x)\n\n10. ten"
        let plain = "1. one\n2. two\n\n   ![b](b.png)\n\n10. ten"
        let linkedHangs = hangs(linked)
        XCTAssertEqual(linkedHangs.count, 2)
        XCTAssertEqual(linkedHangs, hangs(plain), "a linked image stands in like a plain image")
        XCTAssertEqual(linkedHangs[0], linkedHangs[1], accuracy: 0.01, "one list: 1. and 10. share the widest hang")
        let split = hangs("1. one\n2. two\n\n[![b](b.png)](https://x)\n\n10. ten")
        XCTAssertNotEqual(split[0], split[1], "control: an unindented picture ends the list")

        let blocks = parse("a\n\n&nbsp;\n\n&#49;. x")
        XCTAssertEqual(blocks.compactMap(plainText), ["a", "\u{00A0}", "1. x"])
        guard case .text(let item) = blocks[2].content else { return XCTFail("text") }
        XCTAssertNil(item.runs.first?[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self]?.headIndent
                        .nonZero, "no list hang")
    }

    /// An image line whose alt holds many inner `[a](` that never close: the
    /// bracket scan must stay linear (a depth scan per `](` to the end of the
    /// line made it quadratic, review round 7). Relative, not absolute: 8×
    /// the input may take at most ~3× the linear share.
    func testImageLineWithUnclosedInnerLinksParsesInLinearTime() {
        let parser = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light))
        func time(_ count: Int) -> TimeInterval {
            let line = "![x" + String(repeating: "[a](", count: count) + "]"
            _ = parser.parse(line)  // warm
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let start = Date()
                _ = parser.parse(line)
                best = min(best, Date().timeIntervalSince(start))
            }
            return best
        }
        let small = time(5_000)
        let large = time(40_000)
        XCTAssertLessThan(large, max(small, 0.005) * 24, "5k: \(small) s, 40k: \(large) s (quadratic would be ~64×)")
    }

    /// Badges one per line are ONE paragraph on GitHub (`gh api markdown`:
    /// `<p><a><img></a>⏎<a><img></a>…</p>`), the same as a badge row on one
    /// line: one image row since 1.15, not a column of pictures. A linked
    /// image with text on the line before or after it is a paragraph with
    /// that text (linked placeholders). One that a blank line, a block start
    /// or the document's end closes is the picture.
    func testLinkedImagesOnePerLineAreOneRow() {
        let readme = """
        [![Platform](https://img.shields.io/platform.svg)](https://www.apple.com/macos)
        [![Swift](https://img.shields.io/swift.svg)](https://swift.org)
        [![License](https://img.shields.io/license.svg)](LICENSE)

        [![Donation goal](https://qmd.app/goal.svg)](https://qmd.app/#goal)
        """
        let blocks = parse(readme)
        XCTAssertEqual(images(blocks).map(\.alt), ["Donation goal"])
        XCTAssertTrue(blocks.compactMap(plainText).isEmpty)
        let rows = imageRows(blocks)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.map(\.alt), ["Platform", "Swift", "License"])
        XCTAssertEqual(rows.first?.map { $0.link?.absoluteString }, ["https://www.apple.com/macos", "https://swift.org", "LICENSE"])
        XCTAssertEqual(rows.first?.map(\.separator), [.none, .space, .space], "soft breaks are spaces")
        XCTAssertEqual(blocks.first?.sourceLine, 0)

        // Text right before or after (no blank line): one paragraph with it.
        XCTAssertTrue(images(parse("Built with:\n[![Swift](s.svg)](https://swift.org)")).isEmpty)
        XCTAssertTrue(images(parse("[![Swift](s.svg)](https://swift.org)\nand more")).isEmpty)
        // A block that may interrupt a paragraph closes it: a heading, a
        // bullet, an item numbered 1, a fence, a quote, HTML of kinds 1-6, a
        // rule, a table (GitHub: `<p><img></p>` and then that block).
        for next in ["# Next", "- item", "1. item", "```", "> q", "<div>", "***", "| a | b |\n|---|---|\n| 1 | 2 |"] {
            XCTAssertEqual(images(parse("[![Logo](l.png)](https://x)\n\(next)")).map(\.alt), ["Logo"], next)
        }
        // Lines that cannot interrupt a paragraph go on with it (GitHub: one
        // `<p>`): an item not numbered 1, an empty item, a lone inline tag;
        // a setext underline makes the line a heading.
        for next in ["2. item", "*", "<br>", "---", "==="] {
            XCTAssertTrue(images(parse("[![Logo](l.png)](https://x)\n\(next)")).isEmpty, next)
        }
        // At the end of the document, after a blank line, a heading or a rule.
        XCTAssertEqual(images(parse("text\n\n[![Logo](l.png)](https://x)")).map(\.alt), ["Logo"])
        XCTAssertEqual(images(parse("# Title\n[![Logo](l.png)](https://x)\n\ntext")).map(\.alt), ["Logo"])
        XCTAssertEqual(images(parse("***\n[![Logo](l.png)](https://x)")).map(\.alt), ["Logo"])
        XCTAssertEqual(images(parse("text\n\n---\n[![Logo](l.png)](https://x)")).map(\.alt), ["Logo"])
    }

    // MARK: - Reference links in quotes, alerts and table cells

    /// Quotes, alerts and table cells keep their markdown and are rendered
    /// later by renderers without the document's definitions, so the parser
    /// inlines resolvable references (`ReferenceLinks`) — they used to show
    /// as `[text][id]`.
    func testReferenceLinksResolveInQuotesAlertsAndTableCells() {
        let md = """
        > See [the docs][docs], ![logo][img] and [Docs].

        > [!NOTE]
        > Read [the guide][].

        | A | B |
        |---|---|
        | [x][docs] | ![i][img] |
        | [![build][img]](https://ci.example) | |

        [docs]: https://example.com/docs_(v2)
        [img]: img/logo.png
        [the guide]: https://example.com/guide
        """
        let blocks = parse(md)
        let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))  // no definitions
        func links(_ attributed: AttributedString) -> [String] {
            attributed.runs.compactMap { $0.link?.absoluteString }
        }

        guard case .blockquote(let quote, 1) = blocks[0].content else { return XCTFail("quote") }
        XCTAssertEqual(quote, "See [the docs](<https://example.com/docs_\\(v2\\)>), ![logo](<img/logo.png>) "
                       + "and [Docs](<https://example.com/docs_\\(v2\\)>).")
        let shown = renderer.renderQuotedBody(quote)
        XCTAssertEqual(String(shown.characters), "See the docs, [Image: logo] and Docs.")
        XCTAssertEqual(links(shown).first, "https://example.com/docs_(v2)")

        guard case .alert(.note, let alert) = blocks[1].content else { return XCTFail("alert") }
        XCTAssertEqual(links(renderer.renderQuotedBody(alert)), ["https://example.com/guide"])

        guard case .table(_, let rows, _, .grid) = blocks[2].content else { return XCTFail("table") }
        XCTAssertEqual(rows[0], ["[x](<https://example.com/docs_\\(v2\\)>)", "![i](<img/logo.png>)"])
        XCTAssertEqual(links(renderer.renderInline(rows[0][0])), ["https://example.com/docs_(v2)"])
        // Review R2: the README badge — an image reference inside an INLINE link.
        let badge = renderer.renderInline(rows[1][0])
        XCTAssertEqual(String(badge.characters), "[Image: build]")
        XCTAssertEqual(links(badge), ["https://ci.example"])
    }

    /// Footnote references in quotes, alerts and table cells drew `[^note]`
    /// literally; they now draw the paragraph's superscript number — by
    /// first reference since 1.15 (GitHub: `Body{b=1}`, `Quoted{a=2}`,
    /// `Tip{b=1}`, `cell{a=2}`).
    func testFootnoteReferencesResolveInQuotesAlertsAndTableCells() {
        let md = """
        Body[^b].

        > Quoted[^a] and [^missing].

        > [!TIP]
        > Tip[^b].

        | A |
        |---|
        | cell[^a] `[^a]` |

        [^a]: First.
        [^b]: Second.
        """
        let blocks = parse(md)
        let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))  // no definitions
        guard case .text(let body) = blocks[0].content else { return XCTFail("paragraph") }
        XCTAssertEqual(String(body.characters), "Body\u{00B9}.", "numbered by first reference")
        guard case .blockquote(let quote, _) = blocks[1].content,
              case .alert(_, let alert) = blocks[2].content,
              case .table(_, let rows, _, .grid) = blocks[3].content else { return XCTFail("blocks") }
        XCTAssertEqual(String(renderer.renderQuotedBody(quote).characters), "Quoted\u{00B2} and [^missing].")
        XCTAssertEqual(String(renderer.renderQuotedBody(alert).characters), "Tip\u{00B9}.")
        XCTAssertEqual(String(renderer.renderInline(rows[0][0]).characters), "cell\u{00B2} [^a]", "code span kept")
    }

    /// Quote and alert bodies are rendered with soft breaks joined, so a code
    /// span or a link can span source lines: the rewrite scans each joined
    /// group (review R1). Code must never show rewritten Markdown, and the
    /// whole link text must be linked.
    func testQuoteBodyReferencesSpanningLinesMatchTheDefinitionAwareRenderer() {
        let theme = MarkdownTheme.cached(for: .light)
        let definitions = ["d": "https://e.x/a", "img": "img/logo.png"]
        let footnotes = [(id: "n", content: "x")]
        let aware = MarkdownRenderer(theme: theme, referenceDefinitions: definitions, footnoteDefinitions: footnotes)
        let plain = MarkdownRenderer(theme: theme)
        let bodies = [
            "Use `git log [d]\n--oneline` to list.\nRead [the\nguide][d] first.",
            "line one [d]  \nhard break [the\nguide][d]\n\nnew paragraph ![x][img][^n]",
            "- item [d]\n  continued [d]\n- second\n## heading [d]\nafter\\\nback [d]",
            "no references at all\njust text",
        ]
        for body in bodies {
            let inlined = ReferenceLinks.inlined(body, definitions: definitions, footnoteIds: ["n"], quoteBody: true)
            let expected = aware.renderQuotedBody(body)
            let actual = plain.renderQuotedBody(inlined)
            XCTAssertEqual(String(actual.characters), String(expected.characters), body)
            XCTAssertEqual(actual.runs.map { $0.link?.absoluteString }, expected.runs.map { $0.link?.absoluteString }, body)
        }
        XCTAssertEqual(ReferenceLinks.inlined(bodies[3], definitions: definitions, quoteBody: true), bodies[3],
                       "untouched groups keep their lines")

        // The parser path (the reported repro).
        let blocks = parse("> Use `git log [d]\n> --oneline` to list.\n> Read [the\n> guide][d] first.\n\n[d]: https://e.x/a")
        guard case .blockquote(let quote, _) = blocks[0].content else { return XCTFail("quote") }
        let shown = plain.renderQuotedBody(quote)
        XCTAssertEqual(String(shown.characters), "Use git log [d] --oneline to list. Read the guide first.")
        let linked = shown.runs.filter { $0.link != nil }.map { String(shown[$0.range].characters) }
        XCTAssertEqual(linked, ["the guide"])
    }

    /// Merge check (vertical-rhythm × reference inlining): a quote's lazy
    /// lines and collapsed blank runs are part of the stored body the
    /// references are resolved in; a definition taken out of a quote
    /// (`DefinitionPlacement`) has its destination's character references
    /// decoded like any other; a quote's footnote keeps the document's number.
    func testQuoteReferencesSurviveLazyLinesBlankRunsAndQuoteDefinitions() {
        let md = "> [q]: https://e.x/a&amp;b\n>\n> See [q] and\nlazy [the\n> guide][d][^b].\n>\n>\n>\n> Then [q].\n\n"
            + "Body[^a].\n\n[d]: https://e.x/d&#38;e\n[^a]: First.\n[^b]: Second.\n"
        let blocks = parse(md)
        guard case .blockquote(let quote, _) = blocks[0].content else { return XCTFail("quote") }
        let plain = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
        let shown = plain.renderQuotedBody(quote)
        let links = shown.runs.compactMap { run -> String? in
            run.link.map { "\(String(shown[run.range].characters))=\($0.absoluteString)" }
        }
        XCTAssertEqual(links, ["q=https://e.x/a&b", "the guide=https://e.x/d&e", "q=https://e.x/a&b"])
        // First reference of the document: footnote 1 (GitHub `guide{b=1}`).
        XCTAssertTrue(String(shown.characters).contains("guide\u{00B9}."), String(shown.characters))
        XCTAssertFalse(quote.contains("\n\n\n"), "one paragraph break per blank run")
    }

    /// Merge check (H8/H9 × reference inlining): footnote and link
    /// definitions taken out of a quote leave marker lines the body never
    /// sees, and a quote-level footnote is numbered with the document's
    /// (definition order) in the quote, an alert and a paragraph alike.
    func testQuoteLevelDefinitionsNumberAndResolveInEveryBody() {
        let md = """
        > [^q]: Quoted note.
        > [r]: https://e.x/r
        > Text[^q] and [r] and[^a].

        > [!TIP]
        > Tip[^a] [r].

        Body[^a][^q].

        [^a]: Second.
        """
        let blocks = parse(md)
        let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
        guard case .blockquote(let quote, _) = blocks[0].content,
              case .alert(_, let alert) = blocks[1].content,
              case .text(let body) = blocks[2].content else { return XCTFail("blocks: \(blocks.map(\.content))") }
        let shownQuote = renderer.renderQuotedBody(quote)
        XCTAssertEqual(String(shownQuote.characters), "Text\u{00B9} and r and\u{00B2}.")
        XCTAssertEqual(shownQuote.runs.compactMap { $0.link?.absoluteString }, ["https://e.x/r"])
        XCTAssertEqual(String(renderer.renderQuotedBody(alert).characters), "Tip\u{00B2} r.")
        XCTAssertEqual(String(body.characters), "Body\u{00B2}\u{00B9}.")
        guard case .text(let notes) = blocks.last?.content else { return XCTFail("footnotes block") }
        XCTAssertTrue(String(notes.characters).contains("1. Quoted note.\n2. Second."), String(notes.characters))
    }

    /// R21a: footnote labels match like link labels (`ReferenceLabel`):
    /// `[^Note]`, `[^NOTE]` and `[^note]` are all footnote 1, `[^ẞ]` finds
    /// `[^ss]:`, and of `[^dup]:` / `[^DUP]:` the first wins — the second is
    /// not listed either. GitHub (`gh api markdown`, 2026-11-04). They stayed
    /// literal (an exact `==`), and both duplicates were listed.
    func testFootnoteLabelsMatchLikeGitHub() {
        let md = """
        # H[^Note]

        A[^Note] B[^NOTE] C[^note] D[^Dup] E[^ẞ]

        > Q[^NOTE] [^DUP]

        | c |
        |---|
        | T[^NoTe] |

        [^note]: First.
        [^dup]: Dup one.
        [^DUP]: Dup two.
        [^ss]: Fold.
        """
        let blocks = parse(md)
        let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
        guard case .heading(let level, let title, _) = blocks[0].content,
              case .text(let paragraph) = blocks[1].content,
              case .blockquote(let quote, _) = blocks[2].content,
              case .table(_, let rows, _, _) = blocks[3].content,
              case .text(let notes) = blocks.last?.content else { return XCTFail("blocks: \(blocks.map(\.content))") }
        XCTAssertEqual(String(renderer.renderHeader(title, level: level).characters), "H\u{00B9}")
        XCTAssertEqual(String(paragraph.characters), "A\u{00B9} B\u{00B9} C\u{00B9} D\u{00B2} E\u{00B3}")
        XCTAssertEqual(String(renderer.renderQuotedBody(quote).characters), "Q\u{00B9} \u{00B2}")
        XCTAssertEqual(String(renderer.renderInline(rows[0][0]).characters), "T\u{00B9}")
        let listed = String(notes.characters)
        XCTAssertTrue(listed.hasSuffix("1. First.\n2. Dup one.\n3. Fold."), listed)
        XCTAssertFalse(listed.contains("Dup two"), listed)
    }

    /// R21b: a label of whitespace only (`[ ]:`, `[\t]:`) defines nothing —
    /// the line is paragraph text and `[ ]` / `[x][ ]` stay literal (GitHub,
    /// `gh api markdown`, 2026-11-04). It was taken out as a definition of "".
    func testWhitespaceOnlyLabelDefinesNothing() {
        let blocks = parse("[ ] and [x][ ] and [y][\t]\n\n[ ]: https://empty\n\n[\t]: https://tab\n")
        let texts = blocks.compactMap { block -> AttributedString? in
            guard case .text(let text) = block.content else { return nil }
            return text
        }
        XCTAssertEqual(texts.map { String($0.characters) },
                       ["[ ] and [x][ ] and [y][\t]", "[ ]: https://empty", "[\t]: https://tab"])
        // Only the bare URLs link (autolinks, as on GitHub).
        XCTAssertEqual(texts.map { text in text.runs.compactMap { $0.link?.absoluteString } },
                       [[], ["https://empty"], ["https://tab"]])
    }

    /// R21c: a label may hold backslash-escaped brackets, matched as
    /// written: `[a\]b]: url` is a definition, found by `[a\]b]`,
    /// `[y][a\]b]`, `[w][A\]B]`, `![a\]b]`, in a quote and a heading; an
    /// UNESCAPED `[` makes no label (`[a[b]:` is text, `[v][a[b]` literal).
    /// GitHub (`gh api markdown`, 2026-11-04). The definition pattern
    /// stopped at the first `]` and the full form's label too.
    func testEscapedBracketsInLabelsLikeGitHub() {
        let md = #"""
        # [w][A\]B]

        [a\]b] and [y][a\]b] and [a\[c] and [z][a\\] and [w][A\]B]

        > Quoted [q][a\]b].

        ![a\]b]

        [v][a[b]

        [a\]b]: https://esc
        [a\[c]: https://open
        [a\\]: https://bs

        [a[b]: https://ab
        """#
        let blocks = parse(md)
        let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
        // One entry per link: an escape splits a link's text into runs.
        func links(_ text: AttributedString) -> [String] {
            text.runs[\.link].compactMap { link, range in
                link.map { "\(String(text[range].characters))=\($0.absoluteString)" }
            }
        }
        guard blocks.count == 6,
              case .heading(let level, let title, _) = blocks[0].content,
              case .text(let paragraph) = blocks[1].content,
              case .blockquote(let quote, _) = blocks[2].content,
              case .image(let url, _, _, _) = blocks[3].content,
              case .text(let literal) = blocks[4].content,
              case .text(let notDefinition) = blocks[5].content else {
            return XCTFail("blocks: \(blocks.map(\.content))")
        }
        XCTAssertEqual(links(renderer.renderHeader(title, level: level)), ["w=https://esc"])
        XCTAssertEqual(links(paragraph), ["a]b=https://esc", "y=https://esc", "a[c=https://open", "z=https://bs",
                                          "w=https://esc"])
        XCTAssertEqual(links(renderer.renderQuotedBody(quote)), ["q=https://esc"])
        XCTAssertEqual(url, "https://esc")
        XCTAssertEqual(String(literal.characters), "[v][a[b]")
        XCTAssertEqual(links(literal), [])
        XCTAssertEqual(String(notDefinition.characters), "[a[b]: https://ab")
    }

    /// R19: reference labels match as CommonMark's (`ReferenceLabel`) in
    /// every lookup — whitespace runs (tab, line break) are one space, the
    /// ends trimmed, Unicode case folding (`ẞ` = `SS`, `straße` = `STRASSE`,
    /// `ΣΑΣ` = `σας`); a no-break space is no whitespace; the first
    /// definition of a label wins. Expected links from `gh api markdown`
    /// (2026-11-04). Lowercasing alone and exact whitespace left all of
    /// these but `[dup]` literal, and `[dup]` took the LAST definition.
    func testReferenceLabelsMatchLikeGitHub() {
        let md = "Use [link\ntext] shortcut\n---\n\n"
            + "[foo bar] [a\u{00A0}b] [dup] [x][ΣΑΣ] [y][a\n  B]\n\n"
            + "> [straße] and [A\tB]\n\n"
            + "| c |\n|---|\n| [a  b] |\n\n"
            + "![ẞ]\n\n"
            + "[  Foo   Bar ]: https://fb\n[a b]: https://ab\n[dup]: https://first\n[DUP]: https://second\n"
            + "[SS]: https://ss.png\n[STRASSE]: https://strasse\n[σας]: https://sas\n[link text]: https://lt\n"
        let blocks = parse(md)
        let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
        func links(_ text: AttributedString) -> [String] {
            text.runs.compactMap { run in
                run.link.map { "\(String(text[run.range].characters))=\($0.absoluteString)" }
            }
        }
        guard blocks.count == 5,
              case .heading(let level, let title, _) = blocks[0].content,
              case .text(let paragraph) = blocks[1].content,
              case .blockquote(let quote, _) = blocks[2].content,
              case .table(_, let rows, _, _) = blocks[3].content,
              case .image(let url, let alt, _, _) = blocks[4].content else {
            return XCTFail("blocks: \(blocks.map(\.content))")
        }
        XCTAssertEqual(links(renderer.renderHeader(title, level: level)), ["link text=https://lt"])
        XCTAssertEqual(links(paragraph), ["foo bar=https://fb", "dup=https://first", "x=https://sas",
                                          "y=https://ab"])
        XCTAssertTrue(String(paragraph.characters).contains("[a\u{00A0}b]"), "a no-break space is no whitespace")
        XCTAssertEqual(links(renderer.renderQuotedBody(quote)), ["straße=https://strasse", "A\tB=https://ab"])
        XCTAssertEqual(links(renderer.renderInline(rows[0][0])), ["a  b=https://ab"])
        XCTAssertEqual(url, "https://ss.png")
        XCTAssertEqual(alt, "ẞ")

        XCTAssertEqual(ReferenceLabel.normalized(" \tFoo \n\u{0C} BAR\r "), "foo bar")
        XCTAssertEqual(ReferenceLabel.normalized("ﬀ İ Ǆ"), ReferenceLabel.normalized("FF i\u{0307} ǆ"))
    }

    /// The rewrite must draw exactly what the paragraph renderer (which HAS the
    /// definitions) draws for the same line: characters and links.
    func testReferenceInliningMatchesTheDefinitionAwareRenderer() {
        let theme = MarkdownTheme.cached(for: .light)
        let definitions = ["docs": "https://example.com/docs_(v2)", "img": "img/My Pic.png",
                           "a b": "https://example.com/ab", "bad": "https://example.com/a<b>\\\\c", "paren": "https://e.x/a)b(c"]
        let footnotes = [(id: "n1", content: "x"), (id: "docs", content: "y")]
        let withDefinitions = MarkdownRenderer(theme: theme, referenceDefinitions: definitions,
                                               footnoteDefinitions: footnotes)
        let plain = MarkdownRenderer(theme: theme)
        let lines = [
            "[docs] and [Docs][] and [text][DOCS] and [A B]",
            "`[docs]` in code, ``[docs]`` too, \\[docs] escaped, \\[x\\][docs]",
            "***[docs]*** and ~~[docs]~~ stay plain, **[docs]** is a link",
            "[![badge][img]][docs] and ![img] and ![alt][]",
            "[inline](https://x.y/(a)) next to [docs]",
            "[![build][img]](https://ci.example/b) and [![x](i.png)](https://ci.example/c) and [t ![i][img]](<a b>)",
            "[unknown][nope] [unknown] [docs][nope]",
            "[bad] and [paren] escape what the <…> form needs",
            "a ` lone backtick [docs] then ``` three ``` [docs]",
            "note[^n1] and [^docs] then [^none] `[^n1]` **b[^n1]** [![x][img]][docs][^n1]",
        ]
        for line in lines {
            let inlined = ReferenceLinks.inlined(line, definitions: definitions, footnoteIds: footnotes.map(\.id))
            let expected = withDefinitions.renderInline(line)
            let actual = plain.renderInline(inlined)
            XCTAssertEqual(String(actual.characters), String(expected.characters), line)
            XCTAssertEqual(actual.runs.compactMap { $0.link?.absoluteString },
                           expected.runs.compactMap { $0.link?.absoluteString }, line)
        }
        XCTAssertEqual(ReferenceLinks.inlined("[docs]\n[img]", definitions: [:]), "[docs]\n[img]")
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
        guard case .image(let url, let alt, _, _) = blocks[0].content else {
            return XCTFail("expected image block")
        }
        XCTAssertEqual(url, "image.png")
        XCTAssertEqual(alt, "alt text")
    }

    /// The pictures of every `.imageRow` block, in order.
    private func imageRows(_ blocks: [MarkdownBlock]) -> [[RowImage]] {
        blocks.compactMap {
            if case .imageRow(let images) = $0.content { return images }
            return nil
        }
    }

    /// `(url, alt)` of every `.image` block, in order.
    private func images(_ blocks: [MarkdownBlock]) -> [(url: String, alt: String)] {
        blocks.compactMap {
            if case .image(let url, let alt, _, _) = $0.content { return (url, alt) }
            return nil
        }
    }

    /// D8 — the CommonMark destination helper shared by links, inline images
    /// and standalone image lines.
    func testLinkDestinationParsingTable() {
        let cases: [(inner: String, expected: String)] = [
            ("image.png", "image.png"),
            ("  image.png  ", "image.png"),
            ("", ""),
            ("<p q.png>", "p q.png"),                    // pointy: spaces allowed
            ("<p q.png> \"title\"", "p q.png"),
            ("<>", ""),
            ("u \"t\"", "u"),                            // three title styles, discarded
            ("u 't'", "u"),
            ("u (t)", "u"),
            ("u\t\"t\"", "u"),
            ("a\\(b\\).png", "a(b).png"),                // escapes unescaped
            ("<a\\>b.png>", "a>b.png"),
            ("snake\\_case.png", "snake_case.png"),
            ("C:\\dir\\x.png", "C:\\dir\\x.png"),        // backslash before a letter is literal
            ("https://x.org/Foo_(bar).png", "https://x.org/Foo_(bar).png"),
            ("<unterminated", "<unterminated"),          // not the pointy form
            ("u \"a\\\"b\"", "u"),                      // escaped quote inside the title
            // Lenient: not exactly one title after the space → the whole
            // trimmed text is the destination (pre-D8 behaviour).
            ("Screenshot 2024-10-01 at 10.00.00.png", "Screenshot 2024-10-01 at 10.00.00.png"),
            ("  My Notes.md ", "My Notes.md"),
            ("u \"t\" extra", "u \"t\" extra"),
            ("u \"unclosed", "u \"unclosed"),
            ("u (a(b))", "u (a(b))"),
            ("data:image/png;base64,AAAA BBBB\tCCCC", "data:image/png;base64,AAAA BBBB\tCCCC"),
        ]
        for (inner, expected) in cases {
            XCTAssertEqual(InlineSyntaxScanner.linkDestination(inner[...]), expected, "inner: \(inner)")
        }
    }

    func testStandaloneImageKeepsNestedParensInDestination() {
        XCTAssertEqual(images(parse("![a](https://x.org/Foo_(bar).png)")).map(\.url),
                       ["https://x.org/Foo_(bar).png"])
    }

    /// D9 — the old lazy regex made this ONE image with url `x.png) ![b](y.png`.
    /// Two pictures (since 1.15 in one image row: GitHub's one `<p>`).
    func testTwoImagesOnOneLineAreTwoPicturesOfOneRow() {
        let blocks = parse("Intro\n\n![a](x.png) ![b](y.png)\n\nOutro")
        let rows = imageRows(blocks)
        XCTAssertEqual(rows.first?.map(\.url), ["x.png", "y.png"])
        XCTAssertEqual(rows.first?.map(\.alt), ["a", "b"])
        let rowBlocks = blocks.filter { $0.id.hasPrefix("imagerow-") }
        XCTAssertEqual(rowBlocks.map(\.sourceLine), [2], "the row belongs to line 2")
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count, "ids stay unique")
    }

    func testAdjacentImagesWithoutSpaceAreStillAnImageLine() {
        let row = imageRows(parse("  ![a](x.png)![b](y.png)  ")).first ?? []
        XCTAssertEqual(row.map(\.url), ["x.png", "y.png"])
        XCTAssertEqual(row.map(\.separator), [.none, .none], "touching pictures: no space (GitHub)")
    }

    func testImageFollowedByTextIsNotStandalone() {
        let blocks = parse("![a](x.png) caption")
        XCTAssertTrue(images(blocks).isEmpty)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(plainText(blocks[0])?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "[Image: a] caption")
    }

    func testNestedBracketsInAltText() {
        let found = images(parse("![a [b] c](x.png)"))
        XCTAssertEqual(found.map(\.alt), ["a [b] c"])
        XCTAssertEqual(found.map(\.url), ["x.png"])
    }

    func testEscapedBracketInAltDoesNotCountTowardDepth() {
        let found = images(parse(#"![a \] b](x.png)"#))
        XCTAssertEqual(found.map(\.url), ["x.png"])
        XCTAssertEqual(found.map(\.alt), [#"a \] b"#], "alt stays raw text")
    }

    func testImageTitleIsNotPartOfTheURL() {
        XCTAssertEqual(images(parse(#"![a](u "t")"#)).map(\.url), ["u"])
        XCTAssertEqual(images(parse("![a](u 't')")).map(\.url), ["u"])
        XCTAssertEqual(images(parse("![a](u (t))")).map(\.url), ["u"])
    }

    func testScreenshotNameWithSpacesIsTheWholeDestination() {
        XCTAssertEqual(images(parse("![shot](Screenshot 2024-10-01 at 10.00.00.png)")).map(\.url),
                       ["Screenshot 2024-10-01 at 10.00.00.png"])
    }

    /// DataImageURI tolerates whitespace in the payload, so the parser must
    /// hand over all of it.
    func testDataURIWithSpacesKeepsTheWholePayload() {
        let url = "data:image/png;base64,iVBORw0K GgoAAAAN SUhEUgAA"
        XCTAssertEqual(images(parse("![a](\(url))")).map(\.url), [url])
    }

    func testUnicodeWhitespaceAroundAnImageLineIsTrimmed() {
        XCTAssertEqual(images(parse("![a](x.png)\u{00A0}")).map(\.url), ["x.png"])
        XCTAssertEqual(images(parse("\u{3000}![a](x.png) \u{00A0}")).map(\.url), ["x.png"])
    }

    func testPointyDestinationKeepsSpaces() {
        XCTAssertEqual(images(parse("![a](<p q.png>)")).map(\.url), ["p q.png"])
    }

    /// D10 — full, collapsed and shortcut reference images resolve through the
    /// document's definitions (case-insensitively, like links).
    func testReferenceImagesBecomeImageBlocks() {
        let blocks = parse("""
        [Logo]: https://x.org/logo.png

        ![The logo][logo]

        ![Logo][]

        ![logo]
        """)
        let found = images(blocks)
        XCTAssertEqual(found.map(\.url), Array(repeating: "https://x.org/logo.png", count: 3))
        XCTAssertEqual(found.map(\.alt), ["The logo", "Logo", "logo"])
        XCTAssertEqual(blocks.filter { $0.id.hasPrefix("image-") }.map(\.sourceLine), [2, 4, 6])
    }

    func testUndefinedReferenceImageIsNotAnImageBlock() {
        let blocks = parse("""
        [other]: https://x.org/o.png

        ![a][nope]

        ![nope]

        ![nope][]
        """)
        XCTAssertTrue(images(blocks).isEmpty)
        // Three paragraphs, so three text rows: since the vertical rhythm a row
        // is one block (it used to be every text line up to the 30-line cap).
        XCTAssertEqual(blocks.count, 3, "all three lines stay paragraph text")
        XCTAssertTrue(blocks.allSatisfy { $0.id.hasPrefix("text-") }, "\(blocks.map(\.id))")
    }

    func testShortcutImageWithoutAnyDefinitionsStaysText() {
        XCTAssertTrue(images(parse("![logo]")).isEmpty)
    }

    /// A multi-MB `data:` URL on one line is scanned once, linearly.
    func testHugeDataURIImageLineParsesInLinearTime() {
        let payload = String(repeating: "QUJD", count: 512 * 1024)   // 2 MiB of base64
        let url = "data:image/png;base64," + payload
        let markdown = "# Title\n\n![embedded](\(url))\n\nAfter."
        let start = Date()
        let blocks = parse(markdown)
        let elapsed = Date().timeIntervalSince(start)
        let found = images(blocks)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.url.utf8.count, url.utf8.count)
        XCTAssertEqual(found.first?.url == url, true)
        XCTAssertLessThan(elapsed, 1.0, "2 MB data: line took \(elapsed) s")
    }

    /// D11 (until 1.14) a badge line was a paragraph of linked placeholders;
    /// since 1.15 it is one image row whose pictures keep their links.
    func testBadgeLineIsAnImageRowOfLinks() {
        let blocks = parse("[![ci](https://x.org/ci.svg)](https://x.org/ci) [![v](https://x.org/v.svg)](https://x.org/rel)")
        XCTAssertTrue(images(blocks).isEmpty)
        XCTAssertEqual(blocks.count, 1)
        let row = imageRows(blocks).first ?? []
        XCTAssertEqual(row.map(\.url), ["https://x.org/ci.svg", "https://x.org/v.svg"])
        XCTAssertEqual(row.map { $0.link?.absoluteString }, ["https://x.org/ci", "https://x.org/rel"])
        XCTAssertEqual(row.map(\.separator), [.none, .space])
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

    /// An alert needs a body (GitHub): the marker alone is a plain quote; a
    /// nested quote right after it is a body, even an empty one, and the
    /// alert's own body is then empty.
    func testAlertWithEmptyBodyParses() {
        guard case .blockquote(let marker, 1) = parse("> [!WARNING]").first?.content else {
            return XCTFail("a marker alone is a plain quote")
        }
        XCTAssertEqual(marker, "[!WARNING]")
        let blocks = parse("> [!WARNING]\n> >")
        guard case .alert(let kind, let content) = blocks.first?.content else {
            return XCTFail("an alert whose body is a nested quote should still parse")
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

        // Front matter (a properties table since v1.14.2) → the line of its opening `---`
        guard case .table(_, _, _, .properties) = blocks.first?.content else {
            return XCTFail("expected the front-matter properties table first, got \(blocks.map(\.id))")
        }
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

        // The grid table, not the front matter's properties table (table-0).
        let gridTable = blocks.first { if case .table(_, _, _, .grid) = $0.content { return true } else { return false } }
        XCTAssertEqual(gridTable?.sourceLine, 14, "table starts at its header row")
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
        // Five lines, not six: a text row no longer ends in a line break (the
        // final "\n" laid out an empty line under every row).
        let raw = (plainText(blocks[0]) ?? "").components(separatedBy: "\n")
        XCTAssertEqual(raw.count, 5, "\(raw)")
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
        guard case .table(let headers, let rows, _, .grid) = blocks.first?.content else {
            return XCTFail("expected the table to survive, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(headers, ["A", "B"])
        XCTAssertEqual(rows.count, 1)
        // With no term above it the `: ` line is just paragraph text.
        XCTAssertEqual(blocks.count, 2, "\(blocks.map(\.id))")
        XCTAssertFalse(hasBoldRun(blocks[1]))
    }

    /// The term / lazy-continuation predicate uses the SAME standalone-image
    /// test as the block loop: an image line (several images, or a shortcut
    /// reference image) ends the list instead of being swallowed into it.
    func testStandaloneImageLinesEndADefinitionList() {
        let kinds: (String) -> [String] = { md in
            self.parse(md).map { String($0.id.split(separator: "-")[0]) }
        }
        XCTAssertEqual(kinds("Term\n: definition\n![a](x.png) ![b](y.png)"), ["text", "imagerow"])
        XCTAssertEqual(kinds("[logo]: https://x.org/l.png\n\nTerm\n: definition\n![logo]"), ["text", "image"])
    }

    /// Non-image lines keep their old role: text after an image is a lazy
    /// continuation, and a plain term still opens a list.
    func testDefinitionListPredicateUnchangedForNonImageLines() {
        let continued = parse("Term\n: definition\n![a](x.png) caption")
        XCTAssertEqual(continued.count, 1, "\(continued.map(\.id))")
        XCTAssertTrue(textLines(continued[0]).contains("definition [Image: a] caption"),
                      "\(textLines(continued[0]))")

        let term = parse("![a](x.png) caption\n: definition")
        XCTAssertEqual(term.count, 1, "\(term.map(\.id))")
        XCTAssertTrue(hasBoldRun(term[0]), "a line that is not ONLY images can be a term")
        XCTAssertEqual(textLines(term[0]), ["[Image: a] caption", "definition"])
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

private extension CGFloat {
    var nonZero: CGFloat? { self == 0 ? nil : self }
}
