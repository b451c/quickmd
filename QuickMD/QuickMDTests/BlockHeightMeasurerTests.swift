import XCTest
import SwiftUI
import AppKit

/// Parity tests for `BlockHeightMeasurer` (v1.9 T2).
///
/// The virtualized block list asks the measurer for a row height BEFORE the view
/// exists, so "measured == laid out" is the acceptance criterion, not a nicety: a
/// row that is a point short clips its block, a row that is a point long leaves a
/// gap, and either one accumulates over thousands of rows into wrong scroll
/// positions.
///
/// Every test therefore compares the measurer against an INDEPENDENT live
/// measurement: the same `NSAttributedString` installed in a real `NSTextView`
/// configured with `configureForSelfSizing()` — the same call the block views
/// make — laid out through its *display* container (`widthTracksTextView`), which
/// is the container that decides where the visible text actually wraps. Chrome
/// comes from `BlockLayout`, the one place the views read it from too.
final class BlockHeightMeasurerTests: XCTestCase {

    // MARK: - Fixtures

    private let widths: [CGFloat] = [400, 600, 800, 1000]
    private let tolerance: CGFloat = 0.5

    private var theme: MarkdownTheme { MarkdownTheme.cached(for: .light) }

    /// Deterministic stand-in for SwiftMath: the real engine is not compiled into
    /// the test bundle (no font bundle either), and a fixed-size image makes the
    /// inline-math fixture reproducible. Both sides of every comparison use it.
    private let math = MathRendering(
        inlineImage: { _, _, _ in NSImage(size: NSSize(width: 24, height: 12)) },
        displayHeight: { _, _, _ in 40 }
    )

    private func parse(_ markdown: String, fontScale: CGFloat = 1.0) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: theme, fontScale: fontScale).parse(markdown)
    }

    private func measure(_ blocks: [MarkdownBlock], width: CGFloat,
                         fontScale: CGFloat = 1.0,
                         seeds: [String: CGFloat] = [:]) -> MeasuredBlocks {
        BlockHeightMeasurer.measure(blocks: blocks, meta: [:], theme: theme,
                                    fontScale: fontScale, contentWidth: width,
                                    heightSeeds: seeds, math: math)
    }

    private static let longParagraph: String = {
        let sentence = "The measurer lays out the very same attributed string the view installs, "
            + "at the very same width, so the two cannot disagree about how tall a paragraph is. "
        return String(repeating: sentence, count: 40)
    }()

    // MARK: - Live measurement (independent of the measurer's stack)

    /// Height the text really takes in a block's text view at `width`.
    ///
    /// Uses the DISPLAY container (`widthTracksTextView = true`, driven by the
    /// frame) rather than a probe container, so this is the wrap the user sees.
    private func liveTextHeight(_ ns: NSAttributedString, width: CGFloat) -> CGFloat {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.configureForSelfSizing()
        textView.textStorage?.setAttributedString(ns)
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            XCTFail("NSTextView has no TextKit 1 stack")
            return 0
        }
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Fitting height of a SwiftUI view, for the chrome rows the measurer has to
    /// predict without SwiftUI.
    private func hostedHeight<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    // MARK: - .text parity

    func testParagraphParityAcrossWidths() {
        let fixtures: [(name: String, markdown: String)] = [
            ("short paragraph", "A single short line."),
            ("long wrapped paragraph", Self.longParagraph),
            ("bullet list", "- alpha\n- beta with a much longer item that has to wrap at least once at 400 pt\n- gamma\n  - nested delta"),
            ("ordered list", "1. first\n2. second item long enough to wrap at the narrow widths under test\n3. third"),
            ("footnote block", "Text with a ref[^a] and another[^b].\n\n[^a]: First footnote body, long enough to wrap somewhere.\n[^b]: Second footnote body."),
            ("inline math", "Einstein wrote $E = mc^2$ and also $x^2 + y^2 = z^2$ in one paragraph that wraps at the narrower widths."),
        ]

        for fixture in fixtures {
            let blocks = parse(fixture.markdown)
            for width in widths {
                let measured = measure(blocks, width: width)
                XCTAssertEqual(measured.table.count, blocks.count, fixture.name)

                for (index, block) in blocks.enumerated() {
                    guard case .text(let attributed) = block.content else { continue }
                    XCTAssertEqual(measured.table.kinds[index], .exact,
                                   "\(fixture.name): text rows must be exact")
                    guard let ns = measured.converted[block.id] else {
                        XCTFail("\(fixture.name): no converted string for \(block.id)")
                        continue
                    }
                    // The converted string must be the one the view would build.
                    let expectedNS = BlockTextConverter.makeNSAttributedString(
                        from: attributed,
                        hasInlineMath: BlockTextConverter.containsInlineMath(String(attributed.characters)),
                        theme: theme, fontScale: 1.0, math: math)
                    XCTAssertEqual(ns.string, expectedNS.string, fixture.name)

                    let live = liveTextHeight(ns, width: width)
                    XCTAssertEqual(measured.table.heights[index], live, accuracy: tolerance,
                                   "\(fixture.name) @\(width): measured \(measured.table.heights[index]) vs live \(live)")
                }
            }
        }
    }

    // MARK: - .blockquote parity

    func testBlockquoteParityAcrossLevelsAndWidths() {
        let fixtures: [(name: String, markdown: String)] = [
            ("quote level 1", "> A quoted paragraph that is long enough to wrap at four hundred points, twice even."),
            ("quote level 2", "> > A nested quote, also long enough to wrap at the narrow widths under test here."),
        ]

        for fixture in fixtures {
            let blocks = parse(fixture.markdown)
            for width in widths {
                let measured = measure(blocks, width: width)
                for (index, block) in blocks.enumerated() {
                    guard case .blockquote(let content, let level) = block.content else { continue }
                    XCTAssertEqual(measured.table.kinds[index], .exact, fixture.name)
                    guard let ns = measured.converted[block.id] else {
                        XCTFail("\(fixture.name): no converted string")
                        continue
                    }
                    // Body string identical to BlockquoteView's (no inline math —
                    // the view does not opt in).
                    let renderer = MarkdownRenderer(theme: theme, fontScale: 1.0)
                    XCTAssertEqual(ns.string,
                                   String(renderer.renderQuotedBody(content).characters),
                                   fixture.name)

                    let bodyWidth = BlockLayout.Quote.bodyWidth(contentWidth: width, level: level)
                    let expected = liveTextHeight(ns, width: bodyWidth)
                        + 2 * BlockLayout.Quote.verticalPadding
                    XCTAssertEqual(measured.table.heights[index], expected, accuracy: tolerance,
                                   "\(fixture.name) @\(width)")
                }
            }
        }
    }

    // MARK: - .alert parity

    func testAlertParityForEveryKind() {
        for kind in AlertKind.allCases {
            let markdown = "> [!\(kind.rawValue.uppercased())]\n"
                + "> An alert body long enough that it wraps at four hundred points and stays interesting."
            let blocks = parse(markdown)
            for width in widths {
                let measured = measure(blocks, width: width)
                for (index, block) in blocks.enumerated() {
                    guard case .alert(let parsedKind, let content) = block.content else { continue }
                    XCTAssertEqual(parsedKind, kind)
                    XCTAssertEqual(measured.table.kinds[index], .exact)
                    guard let ns = measured.converted[block.id] else {
                        XCTFail("\(kind.rawValue): no converted string")
                        continue
                    }
                    XCTAssertFalse(content.isEmpty)

                    let bodyWidth = width - 2 * BlockLayout.Alert.horizontalPadding
                    let expected = BlockLayout.Alert.titleRowHeight(theme: theme, fontScale: 1.0)
                        + BlockLayout.Alert.stackSpacing
                        + liveTextHeight(ns, width: bodyWidth)
                        + 2 * BlockLayout.Alert.verticalPadding
                        + 2 * BlockLayout.Document.alertOuterVerticalPadding
                    XCTAssertEqual(measured.table.heights[index], expected, accuracy: tolerance,
                                   "alert \(kind.rawValue) @\(width)")
                }
            }
        }
    }

    /// An alert with a marker but no body skips the body and its VStack spacing.
    func testAlertWithoutBodyHasNoBodyChrome() {
        let blocks = parse("> [!NOTE]")
        let measured = measure(blocks, width: 600)
        guard let index = blocks.firstIndex(where: { if case .alert = $0.content { return true } else { return false } }) else {
            return XCTFail("fixture did not parse as an alert")
        }
        let expected = BlockLayout.Alert.titleRowHeight(theme: theme, fontScale: 1.0)
            + 2 * BlockLayout.Alert.verticalPadding
            + 2 * BlockLayout.Document.alertOuterVerticalPadding
        XCTAssertEqual(measured.table.heights[index], expected, accuracy: tolerance)
    }

    // MARK: - .codeBlock parity

    func testCodeBlockParityWithAndWithoutLanguage() {
        let body = (1...12).map { "let value\($0) = compute(\($0)) // a comment that makes the line long enough to wrap" }
            .joined(separator: "\n")
        let fixtures: [(name: String, markdown: String, language: String)] = [
            ("code with language", "```swift\n\(body)\n```", "swift"),
            ("code without language", "```\n\(body)\n```", ""),
            ("code 200 lines", "```swift\n" + (1...200).map { "line \($0): let x\($0) = \($0)" }.joined(separator: "\n") + "\n```", "swift"),
        ]

        for fixture in fixtures {
            let blocks = parse(fixture.markdown)
            for width in widths {
                let measured = measure(blocks, width: width)
                for (index, block) in blocks.enumerated() {
                    guard case .codeBlock(let code, let language) = block.content else { continue }
                    XCTAssertEqual(language, fixture.language, fixture.name)
                    XCTAssertEqual(measured.table.kinds[index], .exact, fixture.name)

                    // The view installs exactly this string (the async highlight
                    // only recolours it), so the test builds it the same way —
                    // through the shared converter `CodeBlockView` forwards to.
                    let ns = BlockTextConverter.plainCode(code, theme: theme, fontScale: 1.0)
                    let inner = liveTextHeight(ns, width: width - 2 * BlockLayout.Code.horizontalPadding)
                    let chrome = language.isEmpty
                        ? 2 * BlockLayout.Code.verticalPaddingWithoutLanguage
                        : BlockLayout.Code.languageLabelHeight(fontScale: 1.0)
                            + BlockLayout.Code.languageLabelTopPadding
                            + BlockLayout.Code.languageLabelBottomPadding
                            + 2 * BlockLayout.Code.verticalPaddingWithLanguage
                    let expected = inner + chrome + 2 * BlockLayout.Document.codeOuterVerticalPadding
                    XCTAssertEqual(measured.table.heights[index], expected, accuracy: tolerance,
                                   "\(fixture.name) @\(width)")
                }
            }
        }
    }

    // MARK: - Determinism, monotonicity, off-main

    func testMeasurementIsDeterministic() {
        let blocks = parse(Self.longParagraph + "\n\n> quoted\n\n```swift\nlet a = 1\n```\n")
        for width in widths {
            let first = measure(blocks, width: width)
            let second = measure(blocks, width: width)
            XCTAssertEqual(first.table, second.table, "two measurements at \(width) disagree")
        }
    }

    func testWiderIsNeverTaller() {
        let blocks = parse(Self.longParagraph)
        var previous = CGFloat.greatestFiniteMagnitude
        for width in widths {
            let total = measure(blocks, width: width).table.heights.reduce(0, +)
            XCTAssertLessThanOrEqual(total, previous + tolerance,
                                     "height grew when the width grew to \(width)")
            previous = total
        }
    }

    /// `measure` runs inside the parse task, so the primitive has to behave
    /// identically off the main thread.
    func testExactHeightOffMainMatchesMainThread() {
        let blocks = parse(Self.longParagraph)
        guard case .text(let attributed)? = blocks.first?.content else {
            return XCTFail("fixture did not parse to a text block")
        }
        let ns = BlockTextConverter.makeNSAttributedString(
            from: attributed, hasInlineMath: false, theme: theme, fontScale: 1.0, math: math)

        for width in widths {
            let onMain = BlockHeightMeasurer.exactHeight(text: ns, width: width)
            var offMain: CGFloat = -1
            DispatchQueue.global(qos: .userInitiated).sync {
                offMain = BlockHeightMeasurer.exactHeight(text: ns, width: width)
            }
            XCTAssertEqual(onMain, offMain, accuracy: 0.0001, "off-main height differs at \(width)")
        }
    }

    /// A whole measure pass off-main, the way `MarkdownView` will call it.
    func testMeasureOffMainMatchesMainThread() {
        let blocks = parse(Self.mixedDocument)
        let onMain = measure(blocks, width: 800).table
        var offMain: BlockHeightTable = .empty
        DispatchQueue.global(qos: .userInitiated).sync {
            offMain = measure(blocks, width: 800).table
        }
        XCTAssertEqual(onMain, offMain)
    }

    // MARK: - Mixed document smoke test (row kinds per D3)

    private static let mixedDocument = """
    # A heading

    A paragraph with some **bold** text that is long enough to wrap at eight hundred points, probably.

    ## Another heading

    - list item one
    - list item two

    > a blockquote

    > [!WARNING]
    > mind the gap

    ```swift
    let a = 1
    ```

    ```
    plain code
    ```

    | a | b |
    |---|---|
    | 1 | 2 |
    | 3 | 4 |

    $$
    x = \\frac{1}{2}
    $$

    ![alt text](image.png)

    ```mermaid
    graph TD; A-->B;
    ```

    Inline math $x^2$ in a paragraph.

    [^n]: a footnote definition
    """

    func testMixedDocumentProducesOneRowPerBlockWithCorrectKinds() {
        let blocks = parse(Self.mixedDocument)
        let started = Date()
        let measured = measure(blocks, width: 800, seeds: [:])
        let elapsedMS = Date().timeIntervalSince(started) * 1000

        XCTAssertEqual(measured.table.heights.count, blocks.count)
        XCTAssertEqual(measured.table.kinds.count, blocks.count)
        XCTAssertEqual(measured.table.contentWidth, 800)

        var seen: Set<String> = []
        for (index, block) in blocks.enumerated() {
            let height = measured.table.heights[index]
            let kind = measured.table.kinds[index]
            XCTAssertGreaterThan(height, 0, "block \(block.id) measured to \(height)")

            switch block.content {
            case .text, .blockquote, .alert, .codeBlock:
                XCTAssertEqual(kind, .exact, "\(block.id) should be exact")
                seen.insert(exemplar(block))
            case .heading, .table, .mathBlock, .image, .mermaidDiagram:
                XCTAssertEqual(kind, .reported, "\(block.id) should be reported")
                seen.insert(exemplar(block))
            }
        }
        // Every block kind is actually exercised by the fixture.
        XCTAssertEqual(seen, ["text", "blockquote", "alert", "codeBlock",
                              "heading", "table", "mathBlock", "image", "mermaidDiagram"])

        // Converted strings exist for exactly the TextBlockView-backed kinds.
        for block in blocks {
            switch block.content {
            case .text, .blockquote:
                XCTAssertNotNil(measured.converted[block.id], "missing conversion for \(block.id)")
            case .alert(_, let content) where !content.isEmpty:
                XCTAssertNotNil(measured.converted[block.id], "missing conversion for \(block.id)")
            default:
                XCTAssertNil(measured.converted[block.id], "unexpected conversion for \(block.id)")
            }
        }

        // ~0.065 ms/block measured on an M-series MBP (1001 blocks in 65 ms;
        // the 21-block fixture reads higher because it pays the one-off font and
        // regex warm-up). The bound is deliberately loose — it exists to catch an
        // accidental O(n²), not to police a few milliseconds.
        XCTAssertLessThan(elapsedMS, 500, "measuring \(blocks.count) blocks took \(elapsedMS) ms")
    }

    private func exemplar(_ block: MarkdownBlock) -> String {
        switch block.content {
        case .text: return "text"
        case .table: return "table"
        case .codeBlock: return "codeBlock"
        case .image: return "image"
        case .blockquote: return "blockquote"
        case .alert: return "alert"
        case .heading: return "heading"
        case .mathBlock: return "mathBlock"
        case .mermaidDiagram: return "mermaidDiagram"
        }
    }

    // MARK: - Reported-row estimates

    /// Mermaid rows start from the `BlockHeightCache` seed when one exists.
    func testMermaidRowUsesHeightSeed() {
        let blocks = parse("```mermaid\ngraph TD; A-->B;\n```")
        guard let block = blocks.first,
              case .mermaidDiagram = block.content else {
            return XCTFail("fixture did not parse as a mermaid diagram")
        }
        let chrome = 2 * BlockLayout.Mermaid.verticalPadding
            + 2 * BlockLayout.Document.mermaidOuterVerticalPadding

        let seeded = measure(blocks, width: 600, seeds: [block.id: 333]).table.heights[0]
        XCTAssertEqual(seeded, 333 + chrome, accuracy: tolerance)

        let unseeded = measure(blocks, width: 600).table.heights[0]
        XCTAssertEqual(unseeded, BlockLayout.Mermaid.defaultHeight + chrome, accuracy: tolerance)
    }

    func testImageRowUsesPlaceholderHeight() {
        let blocks = parse("![alt](picture.png)")
        let measured = measure(blocks, width: 600)
        guard let index = blocks.firstIndex(where: { if case .image = $0.content { return true } else { return false } }) else {
            return XCTFail("fixture did not parse as an image")
        }
        XCTAssertEqual(measured.table.heights[index],
                       BlockLayout.ImageBlock.placeholderHeight
                       + 2 * BlockLayout.Document.imageOuterVerticalPadding,
                       accuracy: tolerance)
    }

    func testDisplayMathRowUsesInjectedHeight() {
        let blocks = parse("$$\nx = 1\n$$")
        let measured = measure(blocks, width: 600)
        guard let index = blocks.firstIndex(where: { if case .mathBlock = $0.content { return true } else { return false } }) else {
            return XCTFail("fixture did not parse as display math")
        }
        XCTAssertEqual(measured.table.heights[index],
                       40 + 2 * BlockLayout.Math.verticalPadding
                       + 2 * BlockLayout.Document.mathOuterVerticalPadding,
                       accuracy: tolerance)
    }

    /// Heading estimates track the TextKit height of the rendered header and never
    /// fall below the hover-to-copy button. Not a parity assertion — headings are
    /// `.reported` and the placed view corrects them.
    func testHeadingEstimateIsAtLeastTheCopyButton() {
        for level in 1...6 {
            let blocks = parse(String(repeating: "#", count: level) + " Heading text")
            let height = measure(blocks, width: 600).table.heights[0]
            XCTAssertGreaterThanOrEqual(height, BlockLayout.Heading.copyButtonHeight)
        }
        // A heading long enough to wrap must be taller than a short one.
        let short = measure(parse("# Short"), width: 400).table.heights[0]
        let long = measure(parse("# " + String(repeating: "long heading words ", count: 12)),
                           width: 400).table.heights[0]
        XCTAssertGreaterThan(long, short)
    }

    func testTableEstimateGrowsWithRows() {
        let twoRows = parse("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        let fiveRows = parse("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |\n| 7 | 8 |\n| 9 | 0 |")
        let small = measure(twoRows, width: 600).table.heights[0]
        let large = measure(fiveRows, width: 600).table.heights[0]
        XCTAssertGreaterThan(large, small)
        XCTAssertGreaterThan(small, 2 * BlockLayout.Document.tableOuterVerticalPadding)
    }

    // MARK: - Chrome the measurer predicts without SwiftUI

    /// `BlockLayout.singleLineHeight` stands in for SwiftUI's single-line `Text`
    /// height, which is not a documented function of `NSFont` metrics. It must
    /// never be SHORT (that clips the hosted view) and must stay within a point
    /// or two (a larger error would show as a visible gap).
    func testSingleLineHeightNeverUnderestimatesSwiftUIText() {
        for scale in [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0] as [CGFloat] {
            // Alert title row.
            let titleFont = theme.fonts.appKit(size: BlockLayout.Alert.titleFontSize * scale,
                                               weight: .semibold)
            let liveTitle = hostedHeight(
                HStack(spacing: BlockLayout.Alert.titleRowSpacing) {
                    Image(systemName: AlertKind.note.symbolName)
                        .font(.system(size: BlockLayout.Alert.iconFontSize * scale, weight: .semibold))
                    Text(AlertKind.note.title)
                        .font(theme.fonts.swiftUI(size: BlockLayout.Alert.titleFontSize * scale,
                                                  weight: .semibold))
                })
            let predictedTitle = BlockLayout.Alert.titleRowHeight(theme: theme, fontScale: scale)
            XCTAssertGreaterThanOrEqual(predictedTitle, liveTitle,
                                        "alert title row underestimated at scale \(scale)")
            XCTAssertLessThanOrEqual(predictedTitle, liveTitle + 2,
                                     "alert title row overestimated at scale \(scale)")
            XCTAssertGreaterThan(BlockLayout.singleLineHeight(for: titleFont), 0)

            // Code block language label.
            let liveLabel = hostedHeight(
                Text("swift").font(.system(size: BlockLayout.Code.languageLabelFontSize * scale,
                                           weight: .medium, design: .monospaced)))
            let predictedLabel = BlockLayout.Code.languageLabelHeight(fontScale: scale)
            XCTAssertGreaterThanOrEqual(predictedLabel, liveLabel,
                                        "code language label underestimated at scale \(scale)")
            XCTAssertLessThanOrEqual(predictedLabel, liveLabel + 2,
                                     "code language label overestimated at scale \(scale)")
        }
    }

    /// The hover-to-copy button's fitting size is a hard-coded constant because it
    /// is chrome, not content; if AppKit ever changes it the heading estimate has
    /// to change too.
    func testHeadingCopyButtonConstantsMatchTheRealButton() {
        let button = Image(systemName: "doc.on.doc")
            .font(.system(size: BlockLayout.Heading.copyButtonIconFontSize))
            .padding(BlockLayout.Heading.copyButtonIconPadding)
        let fitting = NSHostingView(rootView: button).fittingSize
        XCTAssertEqual(fitting.width, BlockLayout.Heading.copyButtonWidth, accuracy: 1)
        XCTAssertEqual(fitting.height, BlockLayout.Heading.copyButtonHeight, accuracy: 1)
    }

    // MARK: - Zoom

    /// Zoom re-parses, so the measurer sees larger fonts; every row with real
    /// content has to grow with them.
    ///
    /// Whitespace-only text blocks (the parser emits one per blank line between
    /// blocks) are skipped on purpose: their string carries no font attribute, so
    /// the text view lays them out in its default font and their height is the
    /// same at every zoom level. That is 1.8.0 behaviour, and the measurer
    /// reproduces it exactly — which is what parity means here.
    func testHeightsGrowWithFontScale() {
        let markdown = Self.longParagraph + "\n\n> quoted body\n\n```swift\nlet a = 1\n```\n"
        let blocks = parse(markdown, fontScale: 1.0)
        let small = measure(blocks, width: 600, fontScale: 1.0)
        let large = measure(parse(markdown, fontScale: 1.5), width: 600, fontScale: 1.5)
        XCTAssertEqual(small.table.heights.count, large.table.heights.count)

        var compared = 0
        for (index, block) in blocks.enumerated() {
            if case .text = block.content,
               let ns = small.converted[block.id],
               ns.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                XCTAssertEqual(large.table.heights[index], small.table.heights[index],
                               accuracy: tolerance,
                               "blank filler row \(block.id) should be zoom-independent")
                continue
            }
            XCTAssertGreaterThan(large.table.heights[index], small.table.heights[index],
                                 "row \(index) (\(block.id)) did not grow with zoom")
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 3, "fixture stopped covering text/quote/code")
    }
}
