import XCTest
import SwiftUI
import AppKit

/// v1.11 T-C — standalone HTML `<img>` lines (`HTMLImageSyntax` + the parser
/// branch that turns them into `.image` blocks). Everything that is NOT one of
/// the recognised shapes must stay literal text, exactly as before.
final class HTMLImageTests: XCTestCase {

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    private struct Found: Equatable {
        let url: String
        let alt: String
        let width: ImageWidth?
        let line: Int
    }

    private func images(_ blocks: [MarkdownBlock]) -> [Found] {
        blocks.compactMap {
            if case .image(let url, let alt, let width) = $0.content {
                return Found(url: url, alt: alt, width: width, line: $0.sourceLine)
            }
            return nil
        }
    }

    private func kinds(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { String($0.id.split(separator: "-")[0]) }
    }

    /// The rendered characters, trimmed (the renderer may end a block with a
    /// line break).
    private func plainText(_ block: MarkdownBlock) -> String? {
        if case .text(let attr) = block.content {
            return String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func allText(_ blocks: [MarkdownBlock]) -> String {
        blocks.compactMap(plainText).joined(separator: "\n")
    }

    private func hasBoldRun(_ block: MarkdownBlock) -> Bool {
        guard case .text(let attr) = block.content else { return false }
        return attr.runs.contains {
            $0[AttributeScopes.AppKitAttributes.FontAttribute.self]?
                .fontDescriptor.symbolicTraits.contains(.bold) == true
        }
    }

    // MARK: - Fixture forms (test-files/test-images-extended.md, section 6)

    func testFixtureSectionSixForms() {
        let md = """
        ## 6. HTML img (T-C)

        <p align="center">
          <img src="images-extended/photo 800.jpg" width="200" alt="centered html photo">
        </p>

        <img src="images-extended/icon-48.png" alt="plain html icon">

        <p align="center"><img src="images-extended/badge-90.png" width="180"></p>

        <img
          src="images-extended/icon-48.png"
          width="96"
          alt="multi-line img tag">

        End of fixture.
        """
        let blocks = parse(md)
        XCTAssertEqual(kinds(blocks), ["heading", "image", "image", "image", "image", "text"])
        XCTAssertEqual(images(blocks), [
            Found(url: "images-extended/photo 800.jpg", alt: "centered html photo", width: .points(200), line: 3),
            Found(url: "images-extended/icon-48.png", alt: "plain html icon", width: nil, line: 6),
            Found(url: "images-extended/badge-90.png", alt: "", width: .points(180), line: 8),
            Found(url: "images-extended/icon-48.png", alt: "multi-line img tag", width: .points(96), line: 10),
        ])
        XCTAssertEqual(plainText(blocks.last!), "End of fixture.")
        XCTAssertFalse(allText(blocks).contains("<"), "no wrapper tag may leak as literal text")
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    // MARK: - Attributes

    func testAttributeQuotingStyles() {
        XCTAssertEqual(images(parse(#"<img src="a b.png" alt="x">"#)).map(\.url), ["a b.png"])
        XCTAssertEqual(images(parse("<img src='single.png' alt='y'>")).map(\.url), ["single.png"])
        XCTAssertEqual(images(parse("<img src=unquoted.png alt=z>")).map(\.url), ["unquoted.png"])
        XCTAssertEqual(images(parse("<img src = \"spaced.png\" >")).map(\.url), ["spaced.png"])
        XCTAssertEqual(images(parse("<img src=\"self.png\"/>")).map(\.url), ["self.png"])
        XCTAssertEqual(images(parse("<img src=\"self2.png\" />")).map(\.url), ["self2.png"])
        // `>` inside a quoted value does not end the tag.
        XCTAssertEqual(images(parse(#"<img alt="a > b" src="q.png">"#)).map(\.alt), ["a > b"])
        // First occurrence wins; unknown attributes and `height` are ignored.
        let found = images(parse(#"<img class="x" src="1.png" src="2.png" height="40" data-x loading=lazy>"#))
        XCTAssertEqual(found.map(\.url), ["1.png"])
        XCTAssertEqual(found.first?.width, nil)
    }

    func testTagAndAttributeNamesAreCaseInsensitive() {
        let found = images(parse(#"<P ALIGN="center"><IMG SRC="Up.PNG" ALT="Caps" WIDTH="50%"></P>"#))
        XCTAssertEqual(found, [Found(url: "Up.PNG", alt: "Caps", width: .fraction(0.5), line: 0)])
        XCTAssertEqual(images(parse("<Img Src=m.png>")).map(\.url), ["m.png"])
    }

    func testEntitiesAreDecodedInSrcAndAlt() {
        let found = images(parse(
            #"<img src="a.png?x=1&amp;y=2" alt="Tom &amp; Jerry &lt;3 &quot;q&quot; it&#39;s &#x263A; &#65; &apos;&nbsp;&bogus; & done">"#))
        XCTAssertEqual(found.map(\.url), ["a.png?x=1&y=2"])
        // `&nbsp;` is a U+00A0, which the whitespace collapse turns into a space.
        XCTAssertEqual(found.map(\.alt), [#"Tom & Jerry <3 "q" it's ☺ A ' &bogus; & done"#])
        XCTAssertEqual(HTMLImageSyntax.decodeEntities("&#0; &#xZZ; &#; &amp"), "&#0; &#xZZ; &#; &amp")
        XCTAssertEqual(HTMLImageSyntax.decodeEntities("no entities"), "no entities")
    }

    func testAltWhitespaceIsCollapsedAndSrcTrimmed() {
        let found = images(parse("<img\n  src=\" x.png \"\n  alt=\"two\n  lines\">"))
        XCTAssertEqual(found.map(\.url), ["x.png"])
        XCTAssertEqual(found.map(\.alt), ["two lines"])
    }

    func testWidthParsing() {
        let cases: [(String, ImageWidth?)] = [
            ("120", .points(120)),
            ("120px", .points(120)),
            ("120PX", .points(120)),
            (" 64 ", .points(64)),
            ("12.5", .points(12.5)),
            ("50%", .fraction(0.5)),
            ("100%", .fraction(1)),
            ("", nil),
            ("0", nil),
            ("-5", nil),
            ("auto", nil),
            ("10em", nil),
            ("1e3", nil),
            ("1.2.3", nil),
            ("%", nil),
            ("px", nil),
            ("0x10", nil),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(HTMLImageSyntax.width(from: raw), expected, "width=\(raw)")
        }
        // Garbage width → the attribute is ignored, the image is still an image.
        XCTAssertEqual(images(parse(#"<img src="g.png" width="wide">"#)),
                       [Found(url: "g.png", alt: "", width: nil, line: 0)])
    }

    func testImageWidthDisplayRule() {
        // Points scale with zoom and never exceed the column; a percentage is
        // a fraction of the (already zoomed) cap, clamped to 100 %.
        XCTAssertEqual(ImageWidth.points(120).displayWidth(cap: 600, fontScale: 1), 120)
        XCTAssertEqual(ImageWidth.points(120).displayWidth(cap: 600, fontScale: 2), 240)
        XCTAssertEqual(ImageWidth.points(900).displayWidth(cap: 500, fontScale: 1), 500)
        XCTAssertEqual(ImageWidth.fraction(0.5).displayWidth(cap: 600, fontScale: 1.5), 300)
        XCTAssertEqual(ImageWidth.fraction(2).displayWidth(cap: 600, fontScale: 1), 600)
    }

    func testImageWithoutSrcStaysText() {
        for line in ["<img alt=\"x\">", "<img src=\"\">", "<img src>", "<img src=\"  \">"] {
            let blocks = parse(line)
            XCTAssertTrue(images(blocks).isEmpty, line)
            XCTAssertEqual(kinds(blocks), ["text"], line)
        }
    }

    // MARK: - Lines

    func testSeveralImagesAndWrappersOnOneLine() {
        let md = #"<a href="https://x.org"><img src="1.png"></a> <img src="2.png"><br/><picture><source srcset="d.png"><img src="3.png"></picture>"#
        let found = images(parse(md))
        XCTAssertEqual(found.map(\.url), ["1.png", "2.png", "3.png"])
        XCTAssertEqual(found.map(\.line), [0, 0, 0])
    }

    func testWrapperOnlyLinesProduceNoBlocks() {
        for line in ["<p align=\"center\">", "</p>", "<div>", "<div class=\"x\">", "</div>", "<center>",
                     "</center>", "<picture>", "</picture>", "<source srcset=\"a.png\">", "<br>", "<br/>",
                     "<br />", "<a href=\"https://x.org\">", "</a>", "  <P>  </P>  ", "<CENTER><BR></CENTER>"] {
            XCTAssertTrue(parse(line).isEmpty, "\(line) → \(parse(line).map(\.id))")
        }
    }

    /// The documented choice: a wrapper-only line is a no-op that does NOT
    /// flush the text buffer, so it never splits a paragraph or a list.
    func testWrapperOnlyLineFlushesNothing() {
        let paragraph = parse("first line\n</p>\nsecond line")
        XCTAssertEqual(kinds(paragraph), ["text"])
        XCTAssertEqual(plainText(paragraph[0]), "first line second line")

        let list = parse("- one\n<br>\n- two")
        XCTAssertEqual(kinds(list), ["text"])
        XCTAssertFalse(allText(list).contains("<br>"))
        XCTAssertTrue(allText(list).contains("one") && allText(list).contains("two"))
    }

    /// GitHub renders a `<br>` line inside a paragraph as a line break: it
    /// becomes a hard break on the buffered line above (never literal text).
    func testLineBreakOnlyLineInsideAParagraphIsAHardBreak() {
        for br in ["<br>", "<br/>", "<br />", "  <BR>  ", "<br><br>"] {
            let blocks = parse("first line\n\(br)\nsecond line")
            XCTAssertEqual(kinds(blocks), ["text"], br)
            XCTAssertEqual(plainText(blocks[0]), "first line\nsecond line", br)
        }
        // The hard break survives into the soft-break join of a longer paragraph.
        XCTAssertEqual(plainText(parse("a\nb\n<br>\nc\nd")[0]), "a b\nc d")
    }

    /// At a block boundary a `<br>` line stays a no-op: no block, no break
    /// added to anything, nothing literal.
    func testLineBreakOnlyLineAtABlockBoundaryIsANoOp() {
        XCTAssertTrue(parse("<br>").isEmpty)
        XCTAssertEqual(plainText(parse("<br>\nfirst")[0]), "first")
        // Renders exactly as if the `<br>` line were not there.
        XCTAssertEqual(plainText(parse("para\n\n<br>\n\nnext")[0]), plainText(parse("para\n\n\nnext")[0]))
        let afterHeading = parse("# Title\n<br>\ntext")
        XCTAssertEqual(kinds(afterHeading), ["heading", "text"])
        XCTAssertEqual(plainText(afterHeading[1]), "text")
        // A wrapper that is not `<br>` never adds a break.
        XCTAssertEqual(plainText(parse("a\n<p>\nb")[0]), "a b")
        XCTAssertEqual(plainText(parse("a\n<br><p>\nb")[0]), "a b")
    }

    /// The README logo row: `&nbsp;` (and its numeric forms, and a literal
    /// U+00A0) between tags is a separator, not text.
    func testNoBreakSpacesBetweenTagsAreSeparators() {
        for separator in ["&nbsp;", "&#160;", "&#xA0;", "&#xa0;", "\u{00A0}", " &nbsp; &nbsp; ", "&nbsp;&nbsp;"] {
            let md = "<p align=\"center\"><img src=\"a.png\">\(separator)<img src=\"b.png\">\(separator)</p>"
            XCTAssertEqual(images(parse(md)).map(\.url), ["a.png", "b.png"], separator)
        }
        XCTAssertEqual(images(parse("<img src=a.png>&nbsp;")).map(\.url), ["a.png"])
        // Only no-break spaces: any other entity or text is still not a separator.
        for line in ["<img src=a.png>&amp;<img src=b.png>", "<img src=a.png>&nbsp<img src=b.png>",
                     "<img src=a.png>&#161;<img src=b.png>", "&nbsp;<img src=a.png>"] {
            XCTAssertTrue(images(parse(line)).isEmpty, line)
        }
    }

    func testNbspIsDecodedInAlt() {
        XCTAssertEqual(images(parse(#"<img src="a.png" alt="Build&nbsp;status&#160;badge">"#)).map(\.alt),
                       ["Build status badge"])
    }

    func testOtherHTMLStaysLiteralText() {
        for line in ["<span>x</span>", "<details>", "<summary>More</summary>", "<p>Some text</p>",
                     "<div>text</div>", "</img>", "<img src=\"a.png\"> caption", "<img src=a.png>text",
                     "<!-- comment -->", "<p", "<>", "< img src=a.png>", "<imgsrc=a.png>",
                     "<img src=\"a.png\" alt=\"x\" <b>", "<table>", "</br>", "<p align=center>![a](x.png)</p>"] {
            let blocks = parse(line)
            XCTAssertTrue(images(blocks).isEmpty, line)
            XCTAssertEqual(kinds(blocks), ["text"], line)
            XCTAssertEqual(plainText(blocks[0])?.contains("<"), true, "\(line) must stay literal")
        }
    }

    func testInlineImgInsideParagraphStaysText() {
        let blocks = parse("Look at this <img src=\"a.png\"> picture.")
        XCTAssertTrue(images(blocks).isEmpty)
        XCTAssertEqual(plainText(blocks[0]), "Look at this <img src=\"a.png\"> picture.")
    }

    func testMarkdownAndHTMLImagesAreNotMixedOnOneLine() {
        let blocks = parse("![a](x.png) <img src=\"y.png\">")
        XCTAssertTrue(images(blocks).isEmpty)
        XCTAssertEqual(kinds(blocks), ["text"])
    }

    // MARK: - Multi-line tags

    func testMultiLineImgSourceLineIsWhereTheTagStarts() {
        let md = "Intro\n\n<p align=\"center\">\n<img\nsrc=\"a.png\"\nalt=\"A\"> <img\nsrc='b.png'>\n</p>\nOutro"
        let blocks = parse(md)
        XCTAssertEqual(images(blocks).map(\.url), ["a.png", "b.png"])
        XCTAssertEqual(images(blocks).map(\.line), [3, 5])
        XCTAssertEqual(kinds(blocks), ["text", "image", "image", "text"])
        XCTAssertEqual(plainText(blocks[3]), "Outro")
    }

    func testUnterminatedMultiLineImgStaysText() {
        // No `>` within the next 10 lines → every line is ordinary text.
        let lines = ["<img src=\"a.png\""] + (1...11).map { "attr\($0)=\"v\"" }
        let blocks = parse(lines.joined(separator: "\n"))
        XCTAssertTrue(images(blocks).isEmpty)
        XCTAssertTrue(allText(blocks).contains("<img src=\"a.png\""))

        // A blank line ends the attempt too.
        let blank = parse("<img\nsrc=\"a.png\"\n\nalt=\"x\">")
        XCTAssertTrue(images(blank).isEmpty)
        XCTAssertTrue(allText(blank).contains("<img"))

        // Garbage before the `>` → text.
        let garbage = parse("<img\nsrc=\"a.png\" some, words>")
        XCTAssertTrue(images(garbage).isEmpty)
    }

    func testMultiLineImgClosingOnTheTenthLineIsAccepted() {
        let lines = ["<img src=\"a.png\""] + (1...9).map { "data-a\($0)=\"v\"" } + ["alt=\"ten\">"]
        let found = images(parse(lines.joined(separator: "\n")))
        XCTAssertEqual(found, [Found(url: "a.png", alt: "ten", width: nil, line: 0)])
    }

    func testImgInsideFencedCodeStaysCode() {
        let blocks = parse("```html\n<p align=\"center\">\n<img src=\"a.png\">\n</p>\n```")
        XCTAssertEqual(kinds(blocks), ["code"])
    }

    func testSourceLineSkipsFilteredDefinitionLines() {
        // 0 `[r]: …` (filtered by the pre-pass), 1 blank, 2 `<img …>`
        let found = images(parse("[r]: https://x.org\n\n<img src=\"a.png\">"))
        XCTAssertEqual(found.map(\.line), [2])
    }

    // MARK: - Definition lists use the SAME predicate

    func testHTMLImageLinesEndADefinitionList() {
        XCTAssertEqual(kinds(parse("Term\n: definition\n<img src=\"a.png\">")), ["text", "image"])
        XCTAssertEqual(kinds(parse("Term\n: definition\n<img\nsrc=\"a.png\">")), ["text", "image"])

        let wrapper = parse("Term\n: definition\n</p>\n\nafter")
        XCTAssertFalse(allText(wrapper).contains("</p>"), "a wrapper line is never literal text")
        XCTAssertEqual(wrapper.count, 2, "\(wrapper.map(\.id))")

        // A second group after a blank line whose "term" is an image line is not a group.
        let group = parse("Term\n: definition\n\n<img src=\"a.png\">\n: not a definition")
        XCTAssertEqual(images(group).map(\.url), ["a.png"])
    }

    /// The forward scans skip wrapper lines exactly as the block loop does:
    /// the list does not end at them and they are never literal text.
    func testWrapperLinesInsideADefinitionListAreSkipped() {
        let tight = parse("Term\n: d1\n<br>\n: d2")
        XCTAssertEqual(tight.count, 1, "\(tight.map(\.id))")
        XCTAssertTrue(hasBoldRun(tight[0]))
        XCTAssertFalse(allText(tight).contains("<br>"))
        XCTAssertTrue(allText(tight).contains("d1") && allText(tight).contains("d2"))

        // Between the term and its definition (block loop) and between a
        // second group's term and definition (forward `scanTermHead`).
        let termGap = parse("Term\n<br>\n: d1\n\nTerm2\n</p>\n: d2")
        XCTAssertEqual(termGap.count, 1, "\(termGap.map(\.id))")
        XCTAssertFalse(allText(termGap).contains("<"))
        XCTAssertTrue(allText(termGap).contains("Term2"))

        // A `<br>` inside a definition's lazy continuation is a hard break.
        let lazy = parse("Term\n: first\n<br>\nsecond")
        XCTAssertEqual(lazy.count, 1)
        let lines = allText(lazy).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("first") && lines.contains("second"), "\(lines)")

        // A `</p>` there is skipped without a break.
        let joined = parse("Term\n: first\n</p>\nsecond")
        XCTAssertEqual(joined.count, 1)
        XCTAssertTrue(allText(joined).contains("first second"), allText(joined))
    }

    func testFailedMultiLineImgCanStillBeATermOrContinuation() {
        // Unterminated → text, and text may be a term (predicate unchanged).
        let term = parse("<img src=\"a.png\"\n: definition")
        XCTAssertEqual(term.count, 1, "\(term.map(\.id))")
        XCTAssertTrue(hasBoldRun(term[0]))

        // Inline <img> with text is an ordinary term too.
        let inline = parse("An <img src=\"a.png\"> icon\n: definition")
        XCTAssertEqual(inline.count, 1)
        XCTAssertTrue(hasBoldRun(inline[0]))
    }

    // MARK: - Performance

    /// Multi-MB lines that START with `<` but are not a recognised line must
    /// be rejected in one linear pass (bounds are generous for CI runners).
    func testHugeLinesStartingWithAngleBracketAreRejectedFast() {
        let filler = String(repeating: "word ", count: 1_000_000)          // 5 MB
        let attributes = String(repeating: "a=b ", count: 1_250_000)       // 5 MB of valid attributes
        let cases = [
            "<" + filler,                       // `<word` — unknown tag name, stops at once
            "<p " + attributes,                 // scanned to the end, unterminated wrapper → nil
            "<p>" + filler,                     // text after a wrapper
            "<img src=a.png>" + filler,         // text after an image
            "<!--" + filler,
        ]
        let start = Date()
        for line in cases { XCTAssertNil(HTMLImageSyntax.scan(line[...]), String(line.prefix(16))) }
        // An unterminated `<img` with megabytes of attributes and no `>` on the
        // following lines goes through the parser's join loop and stays text.
        XCTAssertEqual(HTMLImageSyntax.scan(("<img " + attributes)[...]), .unterminatedImage)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)

        // And the cheap reject for a line that does not start with `<`.
        let rejectStart = Date()
        for _ in 0..<200 { XCTAssertNil(HTMLImageSyntax.scan(filler[...])) }
        XCTAssertLessThan(Date().timeIntervalSince(rejectStart), 2.0, "the prefix check must not scan the line")
    }

    func testHugeDataURIInImgTagParsesInLinearTime() {
        let payload = String(repeating: "QUJD", count: 512 * 1024)   // 2 MiB
        let url = "data:image/png;base64," + payload
        let start = Date()
        let blocks = parse("<p align=\"center\">\n<img src=\"\(url)\" width=\"64\">\n</p>\n\nAfter.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(images(blocks).map(\.url), [url])
        XCTAssertEqual(images(blocks).first?.width, .points(64))
        XCTAssertEqual(kinds(blocks), ["image", "text"])
    }

    /// A line that starts like a wrapper but carries text: one linear pass
    /// that stops at the first non-tag byte.
    func testHugeLineStartingWithATagIsRejectedLinearly() {
        let line = "<div>" + String(repeating: "QUJD", count: 512 * 1024)
        let start = Date()
        XCTAssertNil(HTMLImageSyntax.scan(line[...]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
