import XCTest
import SwiftUI
import AppKit

/// HTML in Markdown (`HTMLBlockSyntax`): constructs QuickMD recognises and
/// draws natively instead of showing their tags as text.
final class HTMLBlockTests: XCTestCase {

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    private func plainText(_ block: MarkdownBlock) -> String? {
        if case .text(let attr) = block.content {
            return String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func texts(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.compactMap(plainText)
    }

    // MARK: - Comments

    func testOneLineCommentDrawsNothing() {
        let blocks = parse("before\n\n<!-- a note -->\n\nafter")
        XCTAssertEqual(texts(blocks), ["before", "after"])
    }

    func testMultiLineCommentDrawsNothing() {
        let blocks = parse("before\n\n<!--\n# not a heading\n- not a list\n-->\n\nafter")
        XCTAssertEqual(texts(blocks), ["before", "after"])
        XCTAssertFalse(blocks.contains { if case .heading = $0.content { return true } else { return false } })
    }

    func testCommentInterruptsAParagraph() {
        let blocks = parse("one\n<!-- c -->\ntwo")
        XCTAssertEqual(texts(blocks), ["one", "two"])
    }

    func testEmptyCommentFormsClose() {
        XCTAssertEqual(texts(parse("<!-->\nafter")), ["after"])
        XCTAssertEqual(texts(parse("<!--->\nafter")), ["after"])
    }

    func testUnclosedCommentRunsToTheEnd() {
        XCTAssertEqual(texts(parse("before\n\n<!-- never closed\n\nstill hidden")), ["before"])
    }

    func testCommentIndentedFourSpacesIsNotAComment() {
        // Four spaces: not an HTML block start (CommonMark). This parser has no
        // top-level indented code, so the line stays visible.
        let blocks = parse("    <!-- shown -->")
        XCTAssertFalse(texts(blocks).isEmpty)
    }

    func testCommentInsideFenceIsCode() {
        let blocks = parse("```\n<!-- code -->\n```")
        guard case .codeBlock(let code, _)? = blocks.first?.content else { return XCTFail("no code block") }
        XCTAssertEqual(code, "<!-- code -->")
    }

    func testDefinitionsInsideACommentAreNotDefinitions() {
        let blocks = parse("<!--\n[^1]: commented out\n-->\n\ntext")
        XCTAssertEqual(texts(blocks), ["text"], "no footnotes section from a commented-out definition")
    }

    func testInlineCommentIsHidden() {
        XCTAssertEqual(texts(parse("a <!-- x --> b")), ["a b"])
        XCTAssertEqual(texts(parse("a<!-- x -->b")), ["ab"])
        XCTAssertEqual(texts(parse("**bold**<!-- x --> text")), ["bold text"])
    }

    func testInlineUnclosedCommentIsText() {
        XCTAssertEqual(texts(parse("a <!-- b")), ["a <!-- b"])
    }

    func testCommentInsideCodeSpanIsCode() {
        XCTAssertEqual(texts(parse("`<!-- x -->`")), ["<!-- x -->"])
    }

    func testManyUnclosedInlineCommentsStayText() {
        let line = String(repeating: "<!-- ", count: 2_000)
        XCTAssertEqual(texts(parse("x " + line)).first?.count, ("x " + line).trimmingCharacters(in: .whitespaces).count)
    }

    // MARK: - Details

    /// (summary text or nil, containers) per block, for compact assertions.
    private struct Row: Equatable {
        let text: String
        let containers: [Int]
        let opens: HTMLContainer?
    }

    private func rows(_ blocks: [MarkdownBlock]) -> [Row] {
        blocks.map { block in
            let text: String
            switch block.content {
            case .text: text = plainText(block) ?? ""
            case .heading(_, let title, _): text = "# " + title
            case .codeBlock(let code, _): text = "```" + code
            default: text = "<\(block.id)>"
            }
            return Row(text: text, containers: block.containers, opens: block.opensContainer)
        }
    }

    private func closed(_ id: Int) -> HTMLContainer { HTMLContainer(id: id, kind: .details(isOpenByDefault: false)) }
    private func open(_ id: Int) -> HTMLContainer { HTMLContainer(id: id, kind: .details(isOpenByDefault: true)) }

    func testDetailsWithSummaryAndMarkdownBody() {
        let md = """
        before

        <details>
        <summary>Click me</summary>

        Hidden **text**

        - a
        - b

        </details>

        after
        """
        // The list is drawn as the same list outside a container.
        let list = texts(parse("- a\n- b"))[0]
        XCTAssertEqual(rows(parse(md)), [
            Row(text: "before", containers: [], opens: nil),
            Row(text: "Click me", containers: [], opens: closed(0)),
            Row(text: "Hidden text", containers: [0], opens: nil),
            Row(text: list, containers: [0], opens: nil),
            Row(text: "after", containers: [], opens: nil),
        ])
    }

    func testOpenAttribute() {
        XCTAssertEqual(parse("<details open>\n<summary>S</summary>\n\nbody\n</details>").first?.opensContainer, open(0))
        XCTAssertEqual(parse("<DETAILS OPEN=\"\">\n<summary>S</summary>\n</DETAILS>").first?.opensContainer, open(0))
        XCTAssertEqual(parse("<details class=\"x\">\n<summary>S</summary>\n</details>").first?.opensContainer, closed(0))
    }

    func testOneLineOpeningAndSummary() {
        let blocks = parse("<details><summary>Title</summary>\n\nBody\n\n</details>")
        XCTAssertEqual(rows(blocks), [
            Row(text: "Title", containers: [], opens: closed(0)),
            Row(text: "Body", containers: [0], opens: nil),
        ])
    }

    func testWholeDetailsOnOneLine() {
        XCTAssertEqual(rows(parse("<details><summary>T</summary>Body text</details>\nafter")), [
            Row(text: "T", containers: [], opens: closed(0)),
            Row(text: "Body text", containers: [0], opens: nil),
            Row(text: "after", containers: [], opens: nil),
        ])
    }

    func testBodyRightAfterSummaryWithoutBlankLine() {
        XCTAssertEqual(rows(parse("<details>\n<summary>T</summary>\nline one\nline two\n</details>")), [
            Row(text: "T", containers: [], opens: closed(0)),
            Row(text: "line one line two", containers: [0], opens: nil),
        ])
    }

    func testMissingSummaryReadsDetails() {
        XCTAssertEqual(rows(parse("<details>\n\nbody\n\n</details>")), [
            Row(text: "Details", containers: [], opens: closed(0)),
            Row(text: "body", containers: [0], opens: nil),
        ])
        XCTAssertEqual(rows(parse("<details></details>")), [Row(text: "Details", containers: [], opens: closed(0))])
    }

    func testSummaryInlineTagsAndMarkdown() {
        let blocks = parse("<details>\n<summary><b>Bold</b> and `code` <span>x</span></summary>\n</details>")
        XCTAssertEqual(plainText(blocks[0]), "Bold and code x")
        guard case .text(let attr) = blocks[0].content else { return XCTFail() }
        let bold = attr.runs.contains {
            String(attr[$0.range].characters) == "Bold"
                && $0[AttributeScopes.AppKitAttributes.FontAttribute.self]?.fontDescriptor.symbolicTraits.contains(.bold) == true
        }
        XCTAssertTrue(bold, "<b> in a summary is bold")
    }

    func testSummaryOverSeveralLines() {
        XCTAssertEqual(rows(parse("<details>\n<summary>\nLong\ntitle\n</summary>\n\nbody\n</details>")), [
            Row(text: "Long title", containers: [], opens: closed(0)),
            Row(text: "body", containers: [0], opens: nil),
        ])
    }

    func testNestedDetails() {
        let md = """
        <details>
        <summary>Outer</summary>

        outer body

        <details open>
        <summary>Inner</summary>

        inner body

        </details>

        outer again

        </details>
        """
        XCTAssertEqual(rows(parse(md)), [
            Row(text: "Outer", containers: [], opens: closed(0)),
            Row(text: "outer body", containers: [0], opens: nil),
            Row(text: "Inner", containers: [0], opens: open(1)),
            Row(text: "inner body", containers: [0, 1], opens: nil),
            Row(text: "outer again", containers: [0], opens: nil),
        ])
    }

    func testUnclosedDetailsRunsToTheEnd() {
        let rows = rows(parse("<details>\n<summary>S</summary>\n\n# Heading\n\ntext"))
        XCTAssertEqual(rows.map(\.containers), [[], [0], [0]])
    }

    func testStrayClosingTagDrawsNothing() {
        XCTAssertEqual(texts(parse("a\n\n</details>\n\nb")), ["a", "b"])
    }

    func testCodeInsideDetailsKeepsItsLines() {
        let rows = rows(parse("<details>\n<summary>S</summary>\n\n```\n</details>\n```\n\n</details>"))
        XCTAssertEqual(rows, [
            Row(text: "S", containers: [], opens: closed(0)),
            Row(text: "```</details>", containers: [0], opens: nil),
        ])
    }

    func testDetailsTagInsideFenceIsCode() {
        let blocks = parse("```\n<details>\n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks[0].opensContainer)
    }

    func testDetailsEndsAParagraphAndAList() {
        XCTAssertEqual(rows(parse("text\n<details>\n<summary>S</summary>\n</details>")).map(\.text), ["text", "S"])
        let rows = rows(parse("- item\n<details>\n<summary>S</summary>\n\nbody\n</details>"))
        XCTAssertEqual(rows.map(\.containers), [[], [], [0]])
    }

    func testSummaryRowTogglesThroughItsLinkAndHasNoIndent() {
        let blocks = parse("<details>\n<summary>Click [docs](https://example.com)</summary>\n</details>")
        guard case .text(let attr) = blocks[0].content else { return XCTFail() }
        // The control is beside the text, not in it (`BlockLayout.ContainerSummary`).
        for run in attr.runs {
            let style = run[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self]
            XCTAssertEqual(style?.firstLineHeadIndent ?? 0, 0)
            XCTAssertEqual(style?.headIndent ?? 0, 0)
        }
        var links: [String: URL] = [:]
        for run in attr.runs { if let link = run.link { links[String(attr[run.range].characters), default: link] = link } }
        XCTAssertEqual(links["docs"], URL(string: "https://example.com"), "the caption's own link is kept")
        XCTAssertEqual(links["Click "].flatMap(HTMLBlockSyntax.toggledContainer), 0)
    }

    func testSummaryIsMeasuredAtTheWidthBesideItsControl() throws {
        let caption = String(repeating: "A caption long enough to wrap several times ", count: 12)
        let theme = MarkdownTheme.cached(for: .light)
        for scale: CGFloat in [1, 2] {
            let blocks = MarkdownBlockParser(theme: theme, fontScale: scale)
                .parse("<details>\n<summary>\(caption)</summary>\n</details>")
            XCTAssertEqual(blocks.count, 1)
            let measured = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: scale,
                                                       contentWidth: 300, heightSeeds: [:], math: nil)
            let ns = try XCTUnwrap(measured.converted[blocks[0].id])
            let narrow = BlockLayout.ContainerSummary.textWidth(contentWidth: 300, fontScale: scale)
            XCTAssertEqual(narrow, 300 - 18 * scale)
            XCTAssertEqual(measured.table.heights[0], BlockHeightMeasurer.textInk(text: ns, width: narrow).height)
            XCTAssertGreaterThan(measured.table.heights[0], BlockHeightMeasurer.textInk(text: ns, width: 300).height,
                                 "a caption this long wraps more beside the control")
        }
    }

    func testToggleURLRoundTrip() {
        XCTAssertEqual(HTMLBlockSyntax.toggledContainer(HTMLBlockSyntax.toggleURL(for: 12)), 12)
        XCTAssertNil(HTMLBlockSyntax.toggledContainer(URL(string: "https://example.com")!))
    }

    func testRemovingToggleLinksKeepsOtherLinks() {
        var text = AttributedString("a b")
        let a = text.range(of: "a")!, b = text.range(of: "b")!
        text[a].link = HTMLBlockSyntax.toggleURL(for: 0)
        text[b].link = URL(string: "https://example.com")
        let stripped = HTMLBlockSyntax.removingToggleLinks(text)
        XCTAssertNil(stripped[stripped.range(of: "a")!].link)
        XCTAssertNotNil(stripped[stripped.range(of: "b")!].link)
    }

    func testOtherHTMLLinesAreNotContainers() {
        for line in ["<div>", "<detailsx>", "<p>text</p>", "<img src=\"a.png\">", "< details>"] {
            XCTAssertNil(HTMLBlockSyntax.containerLine(in: [line], at: 0), line)
        }
    }

    // MARK: - Presentation

    private func table(_ count: Int, spacing: CGFloat = 7) -> BlockHeightTable {
        BlockHeightTable(heights: (0..<count).map { CGFloat(10 + $0) }, kinds: Array(repeating: .exact, count: count),
                         contentWidth: 500, spacingAbove: (0..<count).map { $0 == 0 ? 0 : spacing })
    }

    func testClosedDetailsHideTheirBlocks() {
        let blocks = parse("a\n\n<details>\n<summary>S</summary>\n\nb\n\nc\n</details>\n\nd")
        let shown = ContainerPresentation(blocks: blocks, table: table(blocks.count), rhythm: [], fontScale: 1,
                                          isOpen: { $0.kind.isOpenByDefault })
        XCTAssertEqual(shown.blocks.compactMap(plainText), ["a", "S", "d"])
        XCTAssertEqual(shown.table.count, 3)
        XCTAssertEqual(shown.table.heights, [10, 11, 14], "heights follow their blocks")
        XCTAssertEqual((0..<3).map(shown.documentRow), [0, 1, 4])
    }

    func testOpenDetailsShowEverything() {
        let blocks = parse("<details open>\n<summary>S</summary>\n\nb\n</details>")
        let shown = ContainerPresentation(blocks: blocks, table: table(blocks.count), rhythm: [], fontScale: 1,
                                          isOpen: { $0.kind.isOpenByDefault })
        XCTAssertEqual(shown.blocks.count, blocks.count)
        XCTAssertEqual(shown.documentRow(1), 1)
    }

    func testClosedOuterHidesOpenInner() {
        let blocks = parse("<details>\n<summary>O</summary>\n\n<details open>\n<summary>I</summary>\n\nx\n</details>\n</details>")
        let shown = ContainerPresentation(blocks: blocks, table: table(blocks.count), rhythm: [], fontScale: 1,
                                          isOpen: { $0.kind.isOpenByDefault })
        XCTAssertEqual(shown.blocks.compactMap(plainText), ["O"])
    }

    func testRowAfterAHiddenRunIsRespaced() {
        let blocks = parse("# H\n\n<details>\n<summary>S</summary>\n\n# Inner\n</details>\n\ntext")
        // Rhythm rows: a heading, a text row, a heading (hidden), a text row.
        let text = BlockLayout.Spacing.Row(role: .text, edges: .box(top: 0, bottom: 0), joinsPrevious: false)
        let heading = BlockLayout.Spacing.Row(role: .heading(level: 1), edges: .box(top: 0, bottom: 0),
                                              joinsPrevious: false)
        let rhythm = [heading, text, heading, text]
        XCTAssertEqual(blocks.count, 4)
        let measuredSpacing = BlockLayout.Spacing.column(rhythm, fontScale: 1)
        let full = BlockHeightTable(heights: [10, 11, 12, 13], kinds: Array(repeating: .exact, count: 4),
                                    contentWidth: 500, spacingAbove: measuredSpacing)
        let shown = ContainerPresentation(blocks: blocks, table: full, rhythm: rhythm, fontScale: 1,
                                          isOpen: { $0.kind.isOpenByDefault })
        XCTAssertEqual(shown.table.count, 3)
        XCTAssertEqual(shown.table.spacingAbove[1], measuredSpacing[1], "the summary follows its neighbour as parsed")
        XCTAssertEqual(shown.table.spacingAbove[2],
                       BlockLayout.Spacing.above(text, after: text, fontScale: 1),
                       "the text after the hidden heading is spaced as text after text")
    }
}
