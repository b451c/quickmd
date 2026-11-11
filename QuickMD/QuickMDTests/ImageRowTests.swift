import XCTest
import SwiftUI
import AppKit

/// v1.15 item 4 — links on pictures and rows of pictures.
///
/// Expected paragraph structure from GitHub's renderer (`gh api markdown
/// -f mode=markdown`, 2026-11-11, synthetic input). A paragraph made ONLY of
/// images (plain and/or linked) is one `<p>` of inline `<img>`; a newline
/// between them stays a newline (a space when drawn), two trailing spaces or
/// a `\` give `<br>`; a blank line starts a new `<p>`.
final class ImageRowTests: XCTestCase {

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    /// A one-word picture of the parse: `img:<alt>[→link]`, `row:<alt><sep><alt>…`
    /// (sep: `_` space, `|` hard break, `+` touching), `t:<text>`, `h`, `list`, `rule`.
    private func shape(_ markdown: String) -> [String] {
        parse(markdown).map { block in
            switch block.content {
            case .image(_, let alt, _, let link):
                return "img:" + alt + (link.map { "→" + $0.absoluteString } ?? "")
            case .imageRow(let images):
                return "row:" + images.map { image -> String in
                    let separator: String
                    switch image.separator {
                    case .none: separator = image == images.first ? "" : "+"
                    case .space: separator = "_"
                    case .lineBreak: separator = "|"
                    }
                    return separator + image.alt + (image.link.map { "→" + $0.absoluteString } ?? "")
                }.joined()
            case .text(let attributed):
                return "t:" + String(attributed.characters)
            case .heading: return "h"
            default: return "other"
            }
        }
    }

    // MARK: - Paragraph structure (GitHub's, case by case)

    /// `![a](a.png)⏎![b](b.png)` → `<p><img a>⏎<img b></p>` (one paragraph).
    func testConsecutiveImageLinesAreOneRow() {
        XCTAssertEqual(shape("![a](a.png)\n![b](b.png)"), ["row:a_b"])
        // Indentation does not matter (`<p><img a>⏎<img b></p>`).
        XCTAssertEqual(shape("  ![a](a.png)\n   ![b](b.png)"), ["row:a_b"])
    }

    /// `![a](a.png)␣␣⏎![b](b.png)` and `![a](a.png)\⏎![b](b.png)` →
    /// `<p><img a><br>⏎<img b></p>`: one paragraph, a hard break.
    func testHardBreaksBreakTheRow() {
        XCTAssertEqual(shape("![a](a.png)  \n![b](b.png)"), ["row:a|b"])
        XCTAssertEqual(shape("![a](a.png)\\\n![b](b.png)"), ["row:a|b"])
        XCTAssertEqual(shape("![a](a.png) ![b](b.png)  \n![c](c.png)\n![d](d.png)"), ["row:a_b|c_d"])
        // Trailing spaces on the LAST line are no break (GitHub drops them).
        XCTAssertEqual(shape("![a](a.png)\n![b](b.png)   "), ["row:a_b"])
    }

    /// `![a](a.png)\` alone: a literal backslash after the picture — text,
    /// not a picture paragraph (`<p><img>\</p>`). Not a row either way.
    func testBackslashOnTheLastLineIsText() {
        XCTAssertFalse(shape("![a](a.png)\n![b](b.png)\\").contains { $0.hasPrefix("row:") })
    }

    /// A blank line: two paragraphs, two image blocks (unchanged).
    func testBlankLineSeparatesPictures() {
        XCTAssertEqual(shape("![a](a.png)\n\n![b](b.png)"), ["img:a", "img:b"])
    }

    /// `![a](a.png) ![b](b.png)` → `<p><img a> <img b></p>`; a tab is a
    /// space too; `![a](a.png)![b](b.png)` → `<p><img a><img b></p>` (no gap).
    func testImagesOnOneLine() {
        XCTAssertEqual(shape("![a](a.png) ![b](b.png)"), ["row:a_b"])
        XCTAssertEqual(shape("![a](a.png)\t![b](b.png)"), ["row:a_b"])
        XCTAssertEqual(shape("![a](a.png)![b](b.png)"), ["row:a+b"])
    }

    /// `[![a](a.png)](https://e.com) [![b](b.png)](https://f.com)` → one `<p>`
    /// of two `<a href><img></a>`; badges one per line likewise.
    func testLinkedImagesAreARowOfLinks() {
        XCTAssertEqual(shape("[![a](a.png)](https://e.com) [![b](b.png)](https://f.com)"),
                       ["row:a→https://e.com_b→https://f.com"])
        XCTAssertEqual(shape("[![a](a.png)](https://e.com)\n![b](b.png)\n[![c](c.png)](https://g.com)"),
                       ["row:a→https://e.com_b_c→https://g.com"], "plain and linked mixed")
    }

    /// `[![a][r]][s]⏎![b][r]` + definitions → `<p><a href=s><img a></a>⏎<img b></p>`.
    func testReferenceFormsInARow() {
        let md = "[![a][r]][s]\n![b][r]\n\n[r]: a.png\n[s]: https://s.example"
        XCTAssertEqual(shape(md), ["row:a→https://s.example_b"])
        guard case .imageRow(let images)? = parse(md).first?.content else { return XCTFail("row") }
        XCTAssertEqual(images.map(\.url), ["a.png", "a.png"])
    }

    /// A single picture keeps the image block; linked, it keeps its link
    /// (`<p><a href="https://example.com/x"><img></a></p>`), also with a
    /// title, a space inside the link text, an in-document anchor and a
    /// relative document (`<a href="#install">`, `<a href="other.md">`).
    func testSingleLinkedPictureIsAnImageBlockWithItsLink() {
        XCTAssertEqual(shape("[![one](a.png)](https://example.com/x)"), ["img:one→https://example.com/x"])
        XCTAssertEqual(shape("[![a](a.png)](https://e.com \"Title\")"), ["img:a→https://e.com"])
        XCTAssertEqual(shape("[![a](a.png) ](https://e.com)"), ["img:a→https://e.com"])
        XCTAssertEqual(shape("[![a](a.png)](#install)"), ["img:a→#install"])
        XCTAssertEqual(shape("[![a](a.png)](other.md)"), ["img:a→other.md"])
        // `[![a](a.png)][]` with no definition is no link on GitHub
        // (`<p>[<img>][]</p>`): text here, as before.
        XCTAssertEqual(parse("[![a](a.png)][]").count, 1)
        XCTAssertTrue(shape("[![a](a.png)][]")[0].hasPrefix("t:"))
    }

    /// The single-image paragraph is EXACTLY what it was: `.image`, id
    /// `image-N`, no width, no link, its line.
    func testSinglePlainPictureIsUnchanged() {
        let blocks = parse("Intro\n\n![Logo](img/logo.png)\n\nOutro")
        XCTAssertEqual(blocks.count, 3)
        guard case .image(let url, let alt, let width, let link) = blocks[1].content else { return XCTFail("image") }
        XCTAssertEqual(url, "img/logo.png")
        XCTAssertEqual(alt, "Logo")
        XCTAssertNil(width)
        XCTAssertNil(link)
        XCTAssertTrue(blocks[1].id.hasPrefix("image-"))
        XCTAssertEqual(blocks[1].sourceLine, 2)
    }

    /// Text in the paragraph: GitHub draws the pictures inline with the text
    /// (`<p>Text <img a> <img b></p>`, `<p>Some text⏎<img a></p>`). QuickMD
    /// keeps its pre-1.15 output there — out of scope for rows: a line that
    /// is only images still becomes picture blocks under the text, a line
    /// with text and images is placeholders.
    func testParagraphsWithTextKeepTheirOldShape() {
        XCTAssertEqual(shape("Text ![a](a.png) ![b](b.png)"), ["t:Text [Image: a] [Image: b]"])
        XCTAssertEqual(shape("Some text\n![a](a.png)"), ["t:Some text", "img:a"])
        XCTAssertEqual(shape("![a](a.png)\n![b](b.png)\nsome text"), ["img:a", "img:b", "t:some text"])
        XCTAssertEqual(shape("[![a](a.png)](https://e.com)\nsome text"),
                       ["t:[Image: a] some text"])
    }

    /// A block that may interrupt a paragraph ends the row
    /// (`<p><img a>⏎<img b></p><h1>H</h1>`, `<p><img a></p><ul>…`); a setext
    /// underline makes the paragraph a heading on GitHub — never a row here.
    func testBlockStartsEndTheRow() {
        XCTAssertEqual(shape("![a](a.png)\n![b](b.png)\n# H"), ["row:a_b", "h"])
        XCTAssertEqual(Array(shape("![a](a.png)\n![b](b.png)\n- item").prefix(1)), ["row:a_b"])
        for underline in ["===", "---"] {
            XCTAssertFalse(shape("![a](a.png)\n![b](b.png)\n\(underline)").contains { $0.hasPrefix("row:") },
                           underline)
        }
    }

    /// `<a href="https://example.com/"><img src="a.png" alt="x"></a>` →
    /// `<p><a href="https://example.com/"><img></a></p>`: the picture is the
    /// link. An `<a>` on a line of its own is not carried to the next line.
    func testHTMLLinkAroundAnImageOnOneLine() {
        XCTAssertEqual(shape("<a href=\"https://example.com/\"><img src=\"a.png\" alt=\"x\"></a>"),
                       ["img:x→https://example.com/"])
        XCTAssertEqual(shape("<p align=\"center\"><a href='https://e.com/?a=1&amp;b=2'><img src=\"a.png\" alt=\"x\"></a> <img src=\"b.png\" alt=\"y\"></p>"),
                       ["row:x→https://e.com/?a=1&b=2_y"], "only the picture inside the <a> is linked")
        XCTAssertEqual(shape("<a href=\"https://e.com\">\n<img src=\"a.png\" alt=\"x\">\n</a>"), ["img:x"])
        XCTAssertEqual(shape("<a name=\"top\"><img src=\"a.png\" alt=\"x\"></a>"), ["img:x"], "no href, no link")
    }

    /// `&amp;` in a linked picture's alt is decoded like a lone image's.
    func testAltIsDecoded() {
        XCTAssertEqual(shape("![a &amp; b](a.png) ![c](c.png)"), ["row:a & b_c"])
    }

    /// A long run of image lines that is NOT an image paragraph (text at its
    /// end) is scanned once, not once per line. Structural, not timed: ONE
    /// `imageParagraph` attempt from the first line reports the whole run
    /// as checked (`checkedUntil` = the text line), and the parser tries
    /// again only at or after that line (`imageParagraphSkip`) — so every
    /// line is scanned by at most one attempt. An attempt from inside the
    /// run reaches the same line: a skipped attempt would find nothing new.
    func testAFailedImageParagraphIsScannedOnce() {
        let parser = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light))
        let count = 2_000
        let lines = Array(repeating: "[![b](b.svg)](https://x.example)", count: count) + ["text"]
        guard case .notImages(let checkedUntil) = parser.imageParagraph(at: 0, in: lines, references: [:]) else {
            return XCTFail("text at the end: not an image paragraph")
        }
        XCTAssertEqual(checkedUntil, count, "one attempt covers the whole run")
        guard case .notImages(let fromInside) = parser.imageParagraph(at: count / 2, in: lines, references: [:]) else {
            return XCTFail("from inside")
        }
        XCTAssertEqual(fromInside, count)
        // And the parse is the pre-1.15 paragraph of linked placeholders.
        let blocks = parser.parse(lines.joined(separator: "\n"))
        XCTAssertTrue(blocks.allSatisfy { if case .text = $0.content { return true } else { return false } })
    }

    // MARK: - Line breaking and measurement

    private func sizes(_ widths: [CGFloat], height: CGFloat = 20) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    func testLinesWrapLikeWords() {
        typealias Row = BlockLayout.ImageRow
        let spaces: [RowImage.Separator] = [.none, .space, .space, .space]
        // 4 × 90 + 3 × 4 = 372: one line at 400, two at 300 (3 + 1).
        XCTAssertEqual(Row.lines(sizes: sizes([90, 90, 90, 90]), separators: spaces, width: 400, fontScale: 1)
                        .map(\.range), [0..<4])
        XCTAssertEqual(Row.lines(sizes: sizes([90, 90, 90, 90]), separators: spaces, width: 300, fontScale: 1)
                        .map(\.range), [0..<3, 3..<4])
        // Touching pictures need no gap: 4 × 100 fits 400 exactly.
        XCTAssertEqual(Row.lines(sizes: sizes([100, 100, 100, 100]), separators: [.none, .none, .none, .none],
                                 width: 400, fontScale: 1).map(\.range), [0..<4])
        XCTAssertEqual(Row.lines(sizes: sizes([100, 100, 100, 100]), separators: spaces,
                                 width: 400, fontScale: 1).map(\.range), [0..<3, 3..<4])
        // A hard break always starts a line.
        XCTAssertEqual(Row.lines(sizes: sizes([10, 10, 10]), separators: [.none, .lineBreak, .space],
                                 width: 1000, fontScale: 1).map(\.range), [0..<1, 1..<3])
        // Line height = tallest picture; lines + spacing × zoom.
        let mixed = Row.lines(sizes: [CGSize(width: 50, height: 20), CGSize(width: 50, height: 60),
                                      CGSize(width: 500, height: 30)],
                              separators: spaces, width: 400, fontScale: 1.5)
        XCTAssertEqual(mixed.map(\.height), [60, 30])
        XCTAssertEqual(Row.height(of: mixed, fontScale: 1.5), 60 + 30 + 4 * 1.5)
    }

    /// The measurer's row = the layout the view draws: `ImageFlowLayout`
    /// hosted with pictures of the known sizes, at several widths and zooms,
    /// plus the row padding. And unknown sizes start at the loading square.
    func testMeasuredRowMatchesTheHostedFlowLayout() {
        let theme = MarkdownTheme.cached(for: .light)
        let images = (0..<7).map { index in
            RowImage(url: "b\(index).svg", alt: "b\(index)", link: nil,
                     separator: index == 0 ? .none : (index == 4 ? .lineBreak : .space))
        }
        var known: [NSString: CGSize] = [:]
        for (index, image) in images.enumerated() {
            known[image.url as NSString] = CGSize(width: 60 + CGFloat(index * 17), height: index == 2 ? 28 : 20)
        }
        for (width, scale) in [(800, 1.0), (240, 1.0), (180, 1.5), (97, 2.0)] as [(CGFloat, CGFloat)] {
            let blocks = [MarkdownBlock.imageRow(index: 0, images: images, sourceLine: 0)]
            let measured = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: scale,
                                                       contentWidth: width, imageSizes: known, math: nil)
            XCTAssertEqual(measured.table.kinds, [.reported])
            let hosted = NSHostingView(rootView:
                ImageFlowLayout(separators: images.map(\.separator), fontScale: scale) {
                    ForEach(images.indices, id: \.self) { index in
                        let size = BlockLayout.ImageRow.itemSize(imageSize: known[images[index].url as NSString],
                                                                 alt: images[index].alt,
                                                                 fontScale: scale, contentWidth: width)
                        Color.red.frame(width: size.width, height: size.height)
                    }
                }
                .padding(.vertical, BlockLayout.Document.imageOuterVerticalPadding)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
            XCTAssertEqual(measured.table.heights[0], hosted.fittingSize.height, accuracy: 0.5,
                           "width \(width) × \(scale)")
        }

        // Unknown sizes: chips of the alts, badge height, one line at 800.
        let unknown = BlockHeightMeasurer.measure(
            blocks: [MarkdownBlock.imageRow(index: 0, images: Array(images.prefix(3)), sourceLine: 0)],
            theme: theme, fontScale: 1, contentWidth: 800, math: nil)
        XCTAssertEqual(unknown.table.heights[0],
                       BlockLayout.ImageRow.placeholderSide + 2 * BlockLayout.Document.imageOuterVerticalPadding)
    }

    /// A picture in a row follows the single image's size rule: natural
    /// size × zoom, never wider than the column cap.
    func testRowPicturesUseTheImageSizeRule() {
        let item = BlockLayout.ImageRow.itemSize(imageSize: CGSize(width: 2000, height: 1000), alt: "x",
                                                 fontScale: 1, contentWidth: 500)
        XCTAssertEqual(item, BlockLayout.ImageBlock.pictureSize(imageSize: CGSize(width: 2000, height: 1000),
                                                                htmlWidth: nil, fontScale: 1, contentWidth: 500))
        XCTAssertEqual(item.width, 500)
        XCTAssertEqual(BlockLayout.ImageRow.itemSize(imageSize: CGSize(width: 90, height: 20), alt: "x", fontScale: 2,
                                                     contentWidth: 800), CGSize(width: 180, height: 40))
        // An HTML `width` replaces the natural width, as for a lone `<img width>`.
        XCTAssertEqual(BlockLayout.ImageRow.itemSize(imageSize: CGSize(width: 90, height: 20), htmlWidth: .points(45),
                                                     alt: "x", fontScale: 1, contentWidth: 800),
                       CGSize(width: 45, height: 10))
    }

    /// A lone image's row height is unchanged by the row work: picture +
    /// caption, each padded (`ImageBlock.rowHeight`).
    func testSingleImageRowHeightIsUnchanged() {
        let theme = MarkdownTheme.cached(for: .light)
        for md in ["![alt](picture.png)", "[![alt](picture.png)](https://e.com)"] {
            let blocks = parse(md)
            let measured = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1, contentWidth: 600,
                                                       imageSizes: ["picture.png": CGSize(width: 300, height: 150)],
                                                       math: nil)
            XCTAssertEqual(measured.table.heights[0],
                           BlockLayout.ImageBlock.rowHeight(picture: 150, alt: "alt", fontScale: 1, contentWidth: 600),
                           md)
        }
    }

    // MARK: - Search, copy, selection, tint, rhythm

    /// A row draws no captions, so search does not count its alts (the
    /// count is what the views SHOW); a lone image still counts its caption.
    func testSearchDoesNotCountRowAlts() {
        let row = parse("[![build passing](b.svg)](https://ci) ![license MIT](l.svg) ![build](x.svg)")
        XCTAssertEqual(DocumentSearch.computeMatches(in: row, term: "build").matchBlockIds.count, 0)
        let single = parse("[![build passing](b.svg)](https://ci)")
        XCTAssertEqual(DocumentSearch.computeMatches(in: single, term: "build").matchBlockIds.count, 1)
    }

    func testRowCopiesItsAltsAndIsSelectedWhole() {
        let blocks = parse("[![a](a.png)](https://e.com) ![](x.png) ![b](b.png)  \n![c](c.png)")
        guard let row = blocks.first, case .imageRow = row.content else { return XCTFail("row") }
        XCTAssertTrue(SelectionRows.isAtomic(row))
        let pieces = SelectionRows.pieces(of: DocumentSelection(anchor: SelectionPoint(row: 0, offset: 0),
                                                                focus: SelectionPoint(row: 0, offset: 1)),
                                          blocks: blocks, text: { _ in nil }, table: { _ in nil })
        XCTAssertEqual(DocumentCopyBuilder.build(pieces).plain, "a b\nc")
        XCTAssertNil(SourceTint.kind(of: row), "no tint, as an image line")
    }

    func testRowSitsInTheRhythmAsAnImage() {
        let theme = MarkdownTheme.cached(for: .light)
        let blocks = parse("Text\n\n![a](a.png)\n\nText\n\n![a](a.png) ![b](b.png)\n\nText")
        let measured = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1, contentWidth: 600,
                                                   math: nil)
        XCTAssertEqual(measured.rhythm[1].edges, measured.rhythm[3].edges)
        XCTAssertEqual(measured.table.spacingAbove[1], measured.table.spacingAbove[3])
        XCTAssertEqual(measured.table.spacingAbove[2], measured.table.spacingAbove[4])
    }

    // MARK: - HTML image lines in a picture paragraph (review nit 8)

    /// GitHub (`mode=markdown`, 2026-11-11):
    /// - `<a href="https://e.com"><img src="a.png" alt="a"></a> <a href="https://f.com"><img …></a>`
    ///   → `<p><a href><img></a> <a href><img></a></p>`
    /// - the same two on consecutive lines → one `<p>`, a newline between
    /// - `![a](a.png)⏎<img src="b.png" alt="b">` → one `<p>` of both
    /// - `<img src="a.png"> <img src="b.png">` → one `<p>`
    /// - inside `<p align="center">` … `</p>` lines: the pictures inline in that `<p>`
    func testHTMLImageLinesJoinTheRow() {
        XCTAssertEqual(shape("<a href=\"https://e.com\"><img src=\"a.png\" alt=\"a\"></a> <a href=\"https://f.com\"><img src=\"b.png\" alt=\"b\"></a>"),
                       ["row:a→https://e.com_b→https://f.com"])
        XCTAssertEqual(shape("<a href=\"https://e.com\"><img src=\"a.png\" alt=\"a\"></a>\n<a href=\"https://f.com\"><img src=\"b.png\" alt=\"b\"></a>"),
                       ["row:a→https://e.com_b→https://f.com"])
        XCTAssertEqual(shape("![a](a.png)\n<img src=\"b.png\" alt=\"b\">"), ["row:a_b"])
        XCTAssertEqual(shape("<img src=\"a.png\" alt=\"a\"> <img src=\"b.png\" alt=\"b\">"), ["row:a_b"])
        XCTAssertEqual(shape("<p align=\"center\">\n<img src=\"a.png\" alt=\"a\"> <img src=\"b.png\" alt=\"b\">\n</p>"),
                       ["row:a_b"])
        // Widths ride along; a lone `<img width>` is still the image block.
        guard case .imageRow(let images)? = parse("![b](b.png)\n<img src=\"a.png\" width=\"50\">").first?.content
        else { return XCTFail("row") }
        XCTAssertEqual(images.map(\.width), [nil, .points(50)])
        guard case .image(_, _, let width, _)? = parse("<p align=\"center\">\n<img src=\"logo.png\" width=\"200\" alt=\"Logo\">\n</p>").first?.content
        else { return XCTFail("image") }
        XCTAssertEqual(width, .points(200))
        // A wrapper-only line in the paragraph: not a row (pre-1.15 shape).
        XCTAssertFalse(shape("![a](a.png)\n<br>\n![b](b.png)").contains { $0.hasPrefix("row:") })
    }

    // MARK: - Chips and wrapping width

    /// A chip is framed with `chipSize`: SwiftUI's own text must fit in it
    /// untruncated (short alts), and a long alt is capped.
    func testChipFitsItsLabel() {
        typealias Row = BlockLayout.ImageRow
        for scale in [1.0, 1.5, 2.0] as [CGFloat] {
            for alt in ["CI", "build passing", "Downloads per month", "", "Ünïcödé ✓ 漢字"] {
                let size = Row.chipSize(alt: alt, fontScale: scale, contentWidth: 800)
                XCTAssertEqual(size.height, Row.placeholderSide * scale)
                let text = NSHostingView(rootView: Text(Row.chipLabel(alt: alt))
                    .font(.system(size: Row.chipFontSize * scale)).lineLimit(1).fixedSize()).fittingSize.width
                XCTAssertLessThanOrEqual(text, size.width - 2 * Row.chipHorizontalPadding * scale + 0.5,
                                         "\(alt) × \(scale)")
            }
        }
        XCTAssertEqual(Row.chipLabel(alt: ""), "Image")
        XCTAssertEqual(Row.chipLabel(alt: " two\nlines "), "two lines")
        XCTAssertEqual(Row.chipSize(alt: String(repeating: "long ", count: 100), fontScale: 1, contentWidth: 800).width,
                       Row.chipMaxWidth)
        XCTAssertEqual(Row.chipSize(alt: String(repeating: "long ", count: 100), fontScale: 1, contentWidth: 100).width,
                       100)
    }

    /// The row wraps at `wrapWidth` (the measured content width), whatever
    /// width the cell proposes during a live resize.
    func testRowWrapsAtTheMeasuredWidthNotTheProposal() {
        let separators: [RowImage.Separator] = [.none, .space, .space]
        func height(proposed: CGFloat, wrap: CGFloat?) -> CGFloat {
            NSHostingView(rootView:
                ImageFlowLayout(separators: separators, fontScale: 1, wrapWidth: wrap) {
                    ForEach(0..<3, id: \.self) { _ in Color.red.frame(width: 100, height: 20) }
                }
                .frame(width: proposed)
                .fixedSize(horizontal: false, vertical: true)).fittingSize.height
        }
        XCTAssertEqual(height(proposed: 400, wrap: nil), 20, "one line at the proposal")
        XCTAssertEqual(height(proposed: 400, wrap: 250), 20 + 4 + 20, "two lines at the measured width")
        XCTAssertEqual(height(proposed: 200, wrap: 400), 20, "a narrower live cell does not rewrap")
    }
}
