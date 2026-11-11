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

    func testImageScalingUsesFittedBaselineAndStaysInsideColumn() {
        let width = BlockLayout.ImageBlock.displayWidth
        XCTAssertEqual(width(1, 1200), 600)
        XCTAssertEqual(width(1.5, 1200), 900)
        XCTAssertEqual(width(0.75, 1200), 450)
        XCTAssertEqual(width(0.75, 400), 300)
        XCTAssertEqual(width(1.5, 400), 400)
    }

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
        BlockHeightMeasurer.measure(blocks: blocks, theme: theme,
                                    fontScale: fontScale, contentWidth: width,
                                    heightSeeds: seeds, math: math)
    }

    /// A pass with NO math engine — what the background task does, because
    /// SwiftMath may only be touched on main (thread rule in
    /// `BlockHeightMeasurer`'s header). Math rows come back deferred.
    private func measureWithoutMathEngine(_ blocks: [MarkdownBlock], width: CGFloat,
                                          fontScale: CGFloat = 1.0,
                                          seeds: [String: CGFloat] = [:]) -> MeasuredBlocks {
        BlockHeightMeasurer.measure(blocks: blocks, theme: theme,
                                    fontScale: fontScale, contentWidth: width,
                                    heightSeeds: seeds, math: nil)
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
                        hasInlineMath: BlockTextConverter.containsInlineMath(attributed),
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

    /// An alert with a marker but no body text skips the body and its VStack
    /// spacing. (Its body is an empty nested quote: the marker alone is a
    /// plain quote, as on GitHub.)
    func testAlertWithoutBodyHasNoBodyChrome() {
        let blocks = parse("> [!NOTE]\n> >")
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
        let fixtures: [(name: String, markdown: String, language: String, scale: CGFloat)] = [
            ("code with language", "```swift\n\(body)\n```", "swift", 1.0),
            ("code without language", "```\n\(body)\n```", "", 1.0),
            ("code 200 lines", "```swift\n" + (1...200).map { "line \($0): let x\($0) = \($0)" }.joined(separator: "\n") + "\n```", "swift", 1.0),
            // Short fences, where the copy button — not the code — is the taller
            // ZStack child. See `testShortCodeFenceIsFlooredByTheCopyButton`.
            ("empty fence", "```\n```", "", 1.0),
            ("one line, no language, 0.7 zoom", "```\nlet a = 1\n```", "", 0.7),
        ]

        for fixture in fixtures {
            let blocks = parse(fixture.markdown)
            for width in widths {
                let measured = measure(blocks, width: width, fontScale: fixture.scale)
                for (index, block) in blocks.enumerated() {
                    guard case .codeBlock(let code, let language) = block.content else { continue }
                    XCTAssertEqual(language, fixture.language, fixture.name)
                    XCTAssertEqual(measured.table.kinds[index], .exact, fixture.name)

                    // The view installs exactly this string (the async highlight
                    // only recolours it), so the test builds it the same way —
                    // through the shared converter `CodeBlockView` forwards to.
                    let ns = BlockTextConverter.plainCode(code, theme: theme, fontScale: fixture.scale)
                    let inner = liveTextHeight(ns, width: width - 2 * BlockLayout.Code.horizontalPadding)
                    let chrome = language.isEmpty
                        ? 2 * BlockLayout.Code.verticalPaddingWithoutLanguage
                        : BlockLayout.Code.languageLabelHeight(fontScale: fixture.scale)
                            + BlockLayout.Code.languageLabelTopPadding
                            + BlockLayout.Code.languageLabelBottomPadding
                            + 2 * BlockLayout.Code.verticalPaddingWithLanguage
                    // The ZStack is as tall as its taller child: the code VStack
                    // or the always-present copy button.
                    let expected = max(inner + chrome, BlockLayout.Code.copyButtonFloorHeight)
                        + 2 * BlockLayout.Document.codeOuterVerticalPadding
                    XCTAssertEqual(measured.table.heights[index], expected, accuracy: tolerance,
                                   "\(fixture.name) @\(width)")
                }
            }
        }
    }

    /// The hover-to-copy button is hidden with `.opacity(0)`, never removed, so
    /// it is a floor under a code row — and its icon font is NOT scaled by zoom,
    /// so the floor is one constant. The 0.7-zoom one-line fence is the boundary
    /// case: 11 pt of code + 24 pt of padding = 35 pt, three points under it.
    func testShortCodeFenceIsFlooredByTheCopyButton() {
        let floor = BlockLayout.Code.copyButtonFloorHeight
        let outer = 2 * BlockLayout.Document.codeOuterVerticalPadding
        let fixtures: [(name: String, markdown: String, scale: CGFloat)] = [
            ("empty fence", "```\n```", 1.0),
            ("one line at 0.7 zoom", "```\nlet a = 1\n```", 0.7),
        ]

        for fixture in fixtures {
            let blocks = parse(fixture.markdown)
            guard let index = blocks.firstIndex(where: {
                      if case .codeBlock = $0.content { return true } else { return false } }),
                  case .codeBlock(let code, _) = blocks[index].content else {
                return XCTFail("\(fixture.name) did not parse as a code block")
            }
            let ns = BlockTextConverter.plainCode(code, theme: theme, fontScale: fixture.scale)
            let stack = liveTextHeight(ns, width: 600 - 2 * BlockLayout.Code.horizontalPadding)
                + 2 * BlockLayout.Code.verticalPaddingWithoutLanguage
            XCTAssertLessThanOrEqual(stack, floor,
                                     "\(fixture.name) no longer exercises the floor (stack \(stack))")
            XCTAssertEqual(measure(blocks, width: 600, fontScale: fixture.scale).table.heights[index],
                           floor + outer, accuracy: tolerance, fixture.name)
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

    /// A whole measure pass off-main, the way `MarkdownView` will call it — with
    /// no math engine, since that is the one thing a background thread may not
    /// touch (thread rule in `BlockHeightMeasurer`'s file header).
    func testMeasureOffMainMatchesMainThread() {
        let blocks = parse(Self.mixedDocument)
        let onMain = measureWithoutMathEngine(blocks, width: 800).table
        var offMain: BlockHeightTable = .empty
        DispatchQueue.global(qos: .userInitiated).sync {
            offMain = measureWithoutMathEngine(blocks, width: 800).table
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

    ```svg
    <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20"/></svg>
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
            case .text, .blockquote, .alert, .codeBlock, .table:
                XCTAssertEqual(kind, .exact, "\(block.id) should be exact")
                seen.insert(exemplar(block))
            case .heading, .mathBlock, .image, .mermaidDiagram, .svgImage:
                XCTAssertEqual(kind, .reported, "\(block.id) should be reported")
                seen.insert(exemplar(block))
            }
        }
        // Every block kind is actually exercised by the fixture.
        XCTAssertEqual(seen, ["text", "blockquote", "alert", "codeBlock",
                              "heading", "table", "mathBlock", "image", "mermaidDiagram", "svgImage"])

        // Converted strings exist for exactly the TextBlockView-backed kinds.
        for block in blocks {
            switch block.content {
            case .text, .blockquote:
                XCTAssertNotNil(measured.converted[block.id], "missing conversion for \(block.id)")
            case .alert(_, let content) where !content.isEmpty:
                XCTAssertNotNil(measured.converted[block.id], "missing conversion for \(block.id)")
            case .heading(let level, let title, _):
                // `HeadingBlockView` hosts a `TextBlockView` too: the title as it
                // converts it, kept for copy and search.
                let shown = BlockTextConverter.makeNSAttributedString(
                    from: MarkdownRenderer(theme: theme, fontScale: 1).renderHeader(title, level: level),
                    hasInlineMath: false, theme: theme, fontScale: 1, math: .none)
                XCTAssertEqual(measured.converted[block.id], shown, "heading \(block.id)")
            default:
                XCTAssertNil(measured.converted[block.id], "unexpected conversion for \(block.id)")
            }
            // …and table strings for exactly the tables (v1.13).
            if case .table = block.content {
                XCTAssertNotNil(measured.tables[block.id], "missing table string for \(block.id)")
            } else {
                XCTAssertNil(measured.tables[block.id], "unexpected table string for \(block.id)")
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
        case .svgImage: return "svgImage"
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
        // The loading view as drawn: the 100 pt placeholder AND the caption
        // under it, each with the row's padding (`ImageBlock.rowHeight`).
        XCTAssertEqual(measured.table.heights[index],
                       BlockLayout.ImageBlock.placeholderHeight
                       + 4 * BlockLayout.Document.imageOuterVerticalPadding
                       + BlockLayout.ImageBlock.captionSpacing
                       + BlockLayout.ImageBlock.captionHeight(alt: "alt", fontScale: 1, contentWidth: 600),
                       accuracy: tolerance)
        let uncaptioned = parse("![](picture.png)")
        XCTAssertEqual(measure(uncaptioned, width: 600).table.heights[0],
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

    func testTableHeightGrowsWithRows() {
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
    ///
    /// The two rows built on it are also PINNED to it by their views
    /// (`AlertBlockView`'s title HStack, `CodeBlockView`'s language label), which
    /// is what makes those rows exact rather than estimated — asserted here too,
    /// against `NSHostingView`, which reports fitting sizes rounded up to whole
    /// points.
    func testSingleLineHeightNeverUnderestimatesSwiftUIText() {
        for scale in [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0] as [CGFloat] {
            // Alert title row.
            let titleFont = theme.fonts.appKit(size: BlockLayout.Alert.titleFontSize * scale,
                                               weight: .semibold)
            let titleRow = HStack(spacing: BlockLayout.Alert.titleRowSpacing) {
                Image(systemName: AlertKind.note.symbolName)
                    .font(.system(size: BlockLayout.Alert.iconFontSize * scale, weight: .semibold))
                Text(AlertKind.note.title)
                    .font(theme.fonts.swiftUI(size: BlockLayout.Alert.titleFontSize * scale,
                                              weight: .semibold))
            }
            let liveTitle = hostedHeight(titleRow)
            let predictedTitle = BlockLayout.Alert.titleRowHeight(theme: theme, fontScale: scale)
            XCTAssertGreaterThanOrEqual(predictedTitle, liveTitle,
                                        "alert title row underestimated at scale \(scale)")
            XCTAssertLessThanOrEqual(predictedTitle, liveTitle + 2,
                                     "alert title row overestimated at scale \(scale)")
            XCTAssertGreaterThan(BlockLayout.singleLineHeight(for: titleFont), 0)
            XCTAssertEqual(hostedHeight(titleRow.frame(height: predictedTitle)),
                           ceil(predictedTitle), accuracy: 0.01,
                           "pinned alert title row is not the predicted height at scale \(scale)")

            // Code block language label.
            let label = Text("swift")
                .font(.system(size: BlockLayout.Code.languageLabelFontSize * scale,
                              weight: .medium, design: .monospaced))
            let liveLabel = hostedHeight(label)
            let predictedLabel = BlockLayout.Code.languageLabelHeight(fontScale: scale)
            XCTAssertGreaterThanOrEqual(predictedLabel, liveLabel,
                                        "code language label underestimated at scale \(scale)")
            XCTAssertLessThanOrEqual(predictedLabel, liveLabel + 2,
                                     "code language label overestimated at scale \(scale)")
            XCTAssertEqual(hostedHeight(label.lineLimit(1).frame(height: predictedLabel)),
                           ceil(predictedLabel), accuracy: 0.01,
                           "pinned language label is not the predicted height at scale \(scale)")
        }
    }

    /// The code block's copy button, hosted the way `CodeBlockView` builds it.
    /// `.background`, `.clipShape`, `.buttonStyle(.plain)` and `.opacity` do not
    /// change its fitting size (checked while measuring the constant), so the
    /// icon font + the two paddings are the whole story.
    func testCodeCopyButtonConstantsMatchTheRealButton() {
        let button = Image(systemName: "doc.on.doc")
            .font(.system(size: BlockLayout.Code.copyButtonIconFontSize))
            .padding(BlockLayout.Code.copyButtonIconPadding)
            .padding(BlockLayout.Code.copyButtonOuterPadding)
        XCTAssertEqual(NSHostingView(rootView: button).fittingSize.height,
                       BlockLayout.Code.copyButtonFloorHeight, accuracy: 1)
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

    /// Zoom re-parses, so the measurer sees larger fonts; every row has to grow
    /// with them.
    func testHeightsGrowWithFontScale() {
        let markdown = Self.longParagraph + "\n\n> quoted body\n\n```swift\nlet a = 1\n```\n"
        let blocks = parse(markdown, fontScale: 1.0)
        let small = measure(blocks, width: 600, fontScale: 1.0)
        let large = measure(parse(markdown, fontScale: 1.5), width: 600, fontScale: 1.5)
        XCTAssertEqual(small.table.heights.count, large.table.heights.count)

        var compared = 0
        for (index, block) in blocks.enumerated() {
            XCTAssertGreaterThan(large.table.heights[index], small.table.heights[index],
                                 "row \(index) (\(block.id)) did not grow with zoom")
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 3, "fixture stopped covering text/quote/code")
    }

    // MARK: - Narrow windows (clamped widths)

    /// Every width the measurer lays out at is `contentWidth` minus chrome, and
    /// the subtraction can go negative: at 60 pt a level-5 quote body computes to
    /// 60 − 16 − 5·11 = −11. `BlockLayout.clampedWidth` floors all of them, so
    /// nothing traps and no row explodes into thousands of points.
    func testNarrowContentWidthStaysFiniteAndSane() {
        let markdown = """
        > > > > > tight

        ```swift
        let a = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        # Heading

        A short paragraph.
        """
        let blocks = parse(markdown)
        XCTAssertTrue(blocks.contains {
            if case .blockquote(_, let level) = $0.content { return level == 5 } else { return false }
        }, "fixture stopped producing a level-5 quote")
        XCTAssertGreaterThan(BlockLayout.Quote.bodyWidth(contentWidth: 60, level: 5), 0,
                             "quote body width must be clamped positive")

        let measured = measure(blocks, width: 60)
        XCTAssertEqual(measured.table.count, blocks.count)
        for (index, height) in measured.table.heights.enumerated() {
            XCTAssertTrue(height.isFinite, "row \(index) is not finite")
            XCTAssertGreaterThan(height, 0, "row \(index) measured to \(height)")
            XCTAssertLessThan(height, 2000, "row \(index) exploded to \(height)")
        }
    }

    // MARK: - No math engine off-main (thread rule)

    /// Inline math in a paragraph, a display-math block, a math-free paragraph,
    /// and a quote whose `$y$` must NOT count (quote bodies never opt into inline
    /// math, so they never need the engine).
    private static let mathDocument = """
    A paragraph with inline math $x^2$ inside it, long enough to wrap somewhere.

    A paragraph with no math at all, also long enough to wrap at four hundred points.

    $$
    x = \\frac{1}{2}
    $$

    > a quoted line mentioning $y$, typeset since 1.15

    > a quote that only costs $5 and $10

    > before
    >
    > $$
    > \\sum_{i=1}^n i
    > $$

    > [!NOTE]
    > An alert with $z$ in it

    ## Heading with $h$ math

    ## Heading without math

    | a | b |
    |---|---|
    | $t$ | plain |

    | c | d |
    |---|---|
    | no | math |
    """

    /// Rows that need the math engine: inline-math paragraphs, `$$` blocks
    /// and (v1.15) quote and alert bodies, headings and tables with a formula.
    private func mathRowIndices(in blocks: [MarkdownBlock]) -> [Int] {
        let renderer = MarkdownRenderer(theme: theme, fontScale: 1)
        return blocks.enumerated().compactMap { index, block in
            switch block.content {
            case .text(let attributed):
                return BlockTextConverter.containsInlineMath(attributed) ? index : nil
            case .mathBlock:
                return index
            case .blockquote(let content, _), .alert(_, let content):
                return BlockTextConverter.needsMath(renderer.renderQuotedBody(content)) ? index : nil
            case .heading(let level, let title, _):
                return BlockTextConverter.needsMath(renderer.renderHeader(title, level: level)) ? index : nil
            case .table(let headers, let rows, _, let style):
                return TableTextBuilder.needsMath(headers: headers, rows: rows, style: style, renderer: renderer)
                    ? index : nil
            default:
                return nil
            }
        }
    }

    func testMeasureWithoutMathEngineDefersExactlyTheMathRows() {
        let blocks = parse(Self.mathDocument)
        let expected = mathRowIndices(in: blocks)
        // Paragraph, `$$` block, quote ($y$), quote ($$ display), alert,
        // heading, table — not the "$5 and $10" quote (no formula: the
        // segmenter decides, built off-main), the plain heading or table.
        XCTAssertEqual(expected.count, 7, "fixture stopped covering every math row kind")

        let deferred = measureWithoutMathEngine(blocks, width: 600)
        XCTAssertEqual(deferred.mathPendingRows, expected)
        for index in expected {
            XCTAssertNil(deferred.converted[blocks[index].id],
                         "deferred row \(index) must not have a converted string")
            XCTAssertGreaterThan(deferred.table.heights[index], 0,
                                 "deferred row \(index) needs a placeholder height")
        }

        // Everything the engine is not needed for was measured normally, and the
        // classification of a row never depends on the engine.
        let withEngine = measure(blocks, width: 600)
        XCTAssertEqual(deferred.table.kinds, withEngine.table.kinds)
        for (index, block) in blocks.enumerated() where !expected.contains(index) {
            XCTAssertEqual(deferred.table.heights[index], withEngine.table.heights[index],
                           accuracy: tolerance, "non-math row \(index) changed")
            XCTAssertEqual(deferred.converted[block.id]?.string,
                           withEngine.converted[block.id]?.string, "row \(index)")
        }
    }

    /// Finishing the deferred rows on main has to land exactly where a one-shot
    /// measurement with the engine would have.
    @MainActor
    func testMeasureMathRowsMatchesADirectMeasurementRowForRow() {
        let blocks = parse(Self.mathDocument)
        for width in widths {
            let deferred = measureWithoutMathEngine(blocks, width: width)
            XCTAssertFalse(deferred.mathPendingRows.isEmpty, "@\(width)")

            let finished = BlockHeightMeasurer.measureMathRows(
                deferred.mathPendingRows, in: deferred, blocks: blocks, theme: theme,
                fontScale: 1.0, contentWidth: width, math: math)
            let direct = measure(blocks, width: width)

            XCTAssertEqual(finished.mathPendingRows, [], "@\(width)")
            XCTAssertEqual(finished.table, direct.table, "@\(width)")
            XCTAssertEqual(Set(finished.converted.keys), Set(direct.converted.keys), "@\(width)")
            for (id, expected) in direct.converted {
                XCTAssertEqual(finished.converted[id]?.string, expected.string, "\(id) @\(width)")
            }
        }
    }

    /// A width change re-measures the whole document, and on the main actor the
    /// expensive part of a math paragraph is rendering its `$…$` segments through
    /// SwiftMath — which a width change cannot alter. `reusing:` therefore has to
    /// hand the SAME string back (identity, not just equal contents) and only
    /// re-lay it out.
    @MainActor
    func testMeasureMathRowsReusesSuppliedStringsInsteadOfReRendering() {
        let blocks = parse(Self.mathDocument)
        guard let mathRow = mathRowIndices(in: blocks).first(where: {
            if case .text = blocks[$0].content { return true } else { return false }
        }) else {
            XCTFail("fixture stopped containing an inline-math paragraph")
            return
        }
        let mathBlockId = blocks[mathRow].id

        // First pass at 600 pt, with a live (stub) engine: this is what builds the
        // attachment-bearing string.
        let atSix = measureWithoutMathEngine(blocks, width: 600)
        let built = BlockHeightMeasurer.measureMathRows(
            atSix.mathPendingRows, in: atSix, blocks: blocks, theme: theme,
            fontScale: 1.0, contentWidth: 600, math: math)
        guard let builtString = built.converted[mathBlockId] else {
            XCTFail("no converted string for \(mathBlockId)")
            return
        }

        // Second pass at 400 pt, reusing that string. The engine here fails the
        // test if it is asked to render anything inline: reuse must make the call
        // unnecessary, not merely cheaper.
        let refusingEngine = MathRendering(
            inlineImage: { latex, _, _ in
                XCTFail("re-rendered inline math \u{201C}\(latex)\u{201D} on a width-only re-measure")
                return nil
            },
            displayHeight: { _, _, _ in 40 })
        let atFour = measureWithoutMathEngine(blocks, width: 400)
        let reused = BlockHeightMeasurer.measureMathRows(
            atFour.mathPendingRows, in: atFour, blocks: blocks, theme: theme,
            fontScale: 1.0, contentWidth: 400, math: refusingEngine,
            reusing: built.converted, reusingTables: built.tables)

        XCTAssertTrue(reused.converted[mathBlockId] === builtString,
                      "the reused row must keep the very same NSAttributedString")
        XCTAssertEqual(reused.mathPendingRows, [])
        // Reused, but re-wrapped: the height is the same string laid out at 400.
        XCTAssertEqual(reused.table.heights[mathRow],
                       BlockHeightMeasurer.exactHeight(text: builtString, width: 400),
                       accuracy: tolerance)
        // …and identical to a full rebuild at that width, which is the point.
        let rebuilt = BlockHeightMeasurer.measureMathRows(
            atFour.mathPendingRows, in: atFour, blocks: blocks, theme: theme,
            fontScale: 1.0, contentWidth: 400, math: math)
        XCTAssertEqual(reused.table, rebuilt.table)
    }

    /// Reuse is keyed per block: a row with no entry still gets built.
    @MainActor
    func testMeasureMathRowsBuildsRowsMissingFromReuse() {
        let blocks = parse(Self.mathDocument)
        let deferred = measureWithoutMathEngine(blocks, width: 600)
        let finished = BlockHeightMeasurer.measureMathRows(
            deferred.mathPendingRows, in: deferred, blocks: blocks, theme: theme,
            fontScale: 1.0, contentWidth: 600, math: math,
            reusing: ["nonexistent-block": NSAttributedString(string: "x")])
        XCTAssertEqual(finished.table, measure(blocks, width: 600).table)
    }

    /// A document with no math needs no second pass at all.
    @MainActor
    func testDocumentWithoutMathHasNothingPending() {
        let blocks = parse(Self.mixedDocumentWithoutMath)
        XCTAssertEqual(mathRowIndices(in: blocks), [], "fixture must contain no math")

        for width in widths {
            let deferred = measureWithoutMathEngine(blocks, width: width)
            XCTAssertEqual(deferred.mathPendingRows, [], "@\(width)")
            XCTAssertEqual(deferred.table, measure(blocks, width: width).table, "@\(width)")
            // …and running the second pass anyway changes nothing.
            let finished = BlockHeightMeasurer.measureMathRows(
                deferred.mathPendingRows, in: deferred, blocks: blocks, theme: theme,
                fontScale: 1.0, contentWidth: width, math: math)
            XCTAssertEqual(finished.table, deferred.table, "@\(width)")
        }
    }

    private static let mixedDocumentWithoutMath = """
    # A heading

    A paragraph with some **bold** text, long enough to wrap at four hundred points.

    - list item one
    - list item two

    > a blockquote

    > [!WARNING]
    > mind the gap

    ```swift
    let a = 1
    ```

    | a | b |
    |---|---|
    | 1 | 2 |

    ![alt text](image.png)
    """
}

// MARK: - Untypesettable display math (1.14.3): the source as a ```latex block

extension BlockHeightMeasurerTests {

    /// Stand-in for SwiftMath's parser: refuses `\not` the way the real
    /// `MTMathListBuilder` does ("Unsupported \not\le combination"), accepts
    /// everything else.
    private var refusingNot: MathRendering {
        MathRendering(inlineImage: { _, _, _ in NSImage(size: NSSize(width: 24, height: 12)) },
                      displayHeight: { _, _, _ in 40 },
                      typesets: { !$0.contains("\\not") })
    }

    private static let failingFormulaDocument = """
    Intro paragraph.

    $$
    V(e_1) \\not\\le V(e_2) \\quad \\land \\quad V(e_2) \\not\\le V(e_1)
    $$

    $$x = \\frac{1}{2}$$

    Outro paragraph.
    """

    func testUntypesettableFormulaBecomesALatexCodeBlockKeepingIdAndSourceLine() {
        let parsed = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(Self.failingFormulaDocument)
        let blocks = refusingNot.substitutingUntypesettableMath(in: parsed)

        XCTAssertEqual(blocks.count, parsed.count)
        XCTAssertEqual(blocks.map(\.id), parsed.map(\.id), "ids are positional and must not change")
        XCTAssertEqual(blocks.map(\.sourceLine), parsed.map(\.sourceLine))

        guard case .mathBlock(let failing) = parsed[1].content else {
            return XCTFail("fixture: row 1 is not display math")
        }
        guard case .codeBlock(let code, let language) = blocks[1].content else {
            return XCTFail("the untypesettable formula is still \(blocks[1].content)")
        }
        XCTAssertEqual(code, failing, "the code block shows the formula's source verbatim")
        XCTAssertEqual(language, "latex")
        XCTAssertEqual(blocks[1].sourceLine, 2, "the opening $$ line")

        guard case .mathBlock(let working) = blocks[2].content else {
            return XCTFail("a formula that typesets must stay display math")
        }
        XCTAssertEqual(working, "x = \\frac{1}{2}")
    }

    /// The default engine stubs (and `.none`) never substitute — nothing that
    /// existed before the fallback changes behaviour.
    func testEnginesWithoutATypesetCheckKeepEveryFormula() {
        let parsed = parse(Self.failingFormulaDocument)
        for engine in [math, MathRendering.none] {
            let blocks = engine.substitutingUntypesettableMath(in: parsed)
            XCTAssertEqual(blocks.filter { if case .mathBlock = $0.content { return true } else { return false } }.count, 2)
        }
    }

    /// A formula that PARSES but draws nothing — only spacing, empty groups,
    /// an accent over nothing, `\color` (which this SwiftMath parses but its
    /// typesetter declines) — took the formula path and drew an empty row. It
    /// now falls back like an unparseable one: the same substitution, which
    /// screen and print share. The production verdict
    /// (`MathInk.typesetsToSomething`, in the app target: SwiftMath loads its
    /// fonts from the main bundle, which the test runner is not) agreed with
    /// SwiftMath's own rendering on 36 formulas in a headless check; its
    /// verdicts for these drive the engine here. (`$$ $$` and `$$\n$$` never
    /// become a block at all.)
    func testAFormulaThatDrawsNothingBecomesALatexCodeBlock() {
        let drawsNothing: Set<String> = [#"\,"#, #"\color{red}{x}"#, #"{}^{}_{}"#, #"\hat{}"#]
        let engine = MathRendering(inlineImage: { _, _, _ in nil }, displayHeight: { _, _, _ in 40 },
                                   typesets: { !drawsNothing.contains($0) })
        let document = "$$\n\\,\n$$\n\n$$\\color{red}{x}$$\n\n$$\n{}^{}_{}\n$$\n\n$$\\hat{}$$\n\n$$x$$"
        let parsed = parse(document)
        let blocks = engine.substitutingUntypesettableMath(in: parsed)
        XCTAssertEqual(blocks.map(\.id), parsed.map(\.id))
        XCTAssertEqual(blocks.count, 5)
        for (index, latex) in [#"\,"#, #"\color{red}{x}"#, #"{}^{}_{}"#, #"\hat{}"#].enumerated() {
            guard case .codeBlock(let code, let language) = blocks[index].content else {
                XCTFail("\(latex) is still \(blocks[index].content)")
                continue
            }
            XCTAssertEqual(code, latex, "the source, verbatim")
            XCTAssertEqual(language, "latex")
        }
        guard case .mathBlock(let working) = blocks[4].content else {
            return XCTFail("a formula that draws stays display math")
        }
        XCTAssertEqual(working, "x")
    }

    /// A formula shown as its source copies as the formula it is when the
    /// selection covers it whole — ⌘A, a drag across it — `$$…$$`, as 1.14.2
    /// copied it; a selection inside its text copies that text, like any
    /// selection. A user's own ```latex block still copies as code, and search
    /// still counts in the same string the row shows.
    func testASubstitutedFormulaCopiesAsTheFormulaWhenCoveredWhole() {
        let blocks = refusingNot.substitutingUntypesettableMath(in: parse(Self.failingFormulaDocument)
                                                                + parse("```latex\n\\not\\le\n```"))
        guard case .codeBlock(let latex, _) = blocks[1].content, blocks[1].substitutesFormula else {
            return XCTFail("fixture: row 1 was not substituted")
        }
        XCTAssertFalse(blocks[4].substitutesFormula, "a user's own latex fence")
        func text(_ block: MarkdownBlock) -> NSAttributedString? {
            switch block.content {
            case .text(let attributed):
                return BlockTextConverter.makeNSAttributedString(from: attributed, hasInlineMath: false,
                                                                 theme: theme, fontScale: 1, math: .none)
            case .codeBlock(let code, _):
                return BlockTextConverter.plainCode(code, theme: theme, fontScale: 1)
            default:
                return nil
            }
        }
        func copy(_ anchor: SelectionPoint, _ focus: SelectionPoint) -> String {
            DocumentCopyBuilder.build(SelectionRows.pieces(of: DocumentSelection(anchor: anchor, focus: focus),
                                                           blocks: blocks, text: text, table: { _ in nil })).plain
        }
        let length = (latex as NSString).length
        let outro = text(blocks[3])!.length
        // ⌘A: intro, the formula as $$…$$, the working formula, outro, the fence.
        let all = DocumentSelection.selectAll(rowCount: blocks.count) { text(blocks[$0])?.length ?? 1 }!
        XCTAssertEqual(copy(all.anchor, all.focus),
                       "Intro paragraph.\n\n$$\n\(latex)\n$$\n\n$$\nx = \\frac{1}{2}\n$$\n\nOutro paragraph.\n\n\\not\\le")
        // A drag from the intro into the outro covers the formula whole.
        XCTAssertTrue(copy(SelectionPoint(row: 0, offset: 6), SelectionPoint(row: 3, offset: outro))
            .contains("\n\n$$\n\(latex)\n$$\n\n"))
        // The formula's own text, start to end, from inside: still whole.
        XCTAssertEqual(copy(SelectionPoint(row: 1, offset: 0), SelectionPoint(row: 1, offset: length)),
                       "$$\n\(latex)\n$$")
        // Part of it: those characters.
        XCTAssertEqual(copy(SelectionPoint(row: 1, offset: 0), SelectionPoint(row: 1, offset: 6)), "V(e_1)")
        // Search counts in what the row shows.
        XCTAssertEqual(DocumentSearch.computeMatches(in: blocks, term: "not", theme: theme).matchBlockIds.count, 3)
    }

    func testDocumentWithoutDisplayMathNeverConsultsTheEngine() {
        let parsed = parse("Text with $x$ inline only.\n\n```latex\n\\not\\le\n```")
        let engine = MathRendering(inlineImage: { _, _, _ in nil }, displayHeight: { _, _, _ in 0 },
                                   typesets: { latex in
                                       XCTFail("asked to typeset \u{201C}\(latex)\u{201D} with no display math present")
                                       return false
                                   })
        XCTAssertEqual(engine.substitutingUntypesettableMath(in: parsed).map(\.id), parsed.map(\.id))
    }

    /// The production order: the off-main pass measured the ORIGINAL blocks (the
    /// formula row deferred as math), the main actor substitutes, then
    /// `measureMathRows` finishes. The result must equal a straight measurement
    /// of the substituted blocks — the formula row an `.exact` code row whose
    /// height is what the code-block view lays out.
    @MainActor
    func testSubstitutedFormulaRowIsMeasuredAsAnExactCodeRow() {
        let engine = refusingNot
        let parsed = parse(Self.failingFormulaDocument)
        let blocks = engine.substitutingUntypesettableMath(in: parsed)
        guard case .codeBlock(let code, let language) = blocks[1].content else {
            return XCTFail("fixture: row 1 was not substituted")
        }
        for width in widths {
            let deferred = measureWithoutMathEngine(parsed, width: width)
            XCTAssertTrue(deferred.mathPendingRows.contains(1), "@\(width)")
            XCTAssertEqual(deferred.table.kinds[1], .reported)

            let finished = BlockHeightMeasurer.measureMathRows(
                deferred.mathPendingRows, in: deferred, blocks: blocks, theme: theme,
                fontScale: 1.0, contentWidth: width, math: engine)
            let direct = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1.0,
                                                     contentWidth: width, math: engine)
            XCTAssertEqual(finished.table, direct.table, "@\(width)")
            XCTAssertEqual(finished.table.kinds[1], .exact, "@\(width)")
            XCTAssertEqual(finished.table.kinds[2], .reported, "the working formula stays a math row")

            // Independent of the measurer: the string CodeBlockView installs, laid
            // out in a live text view, plus the code chrome from BlockLayout.
            let ns = BlockTextConverter.plainCode(code, theme: theme, fontScale: 1.0)
            let inner = liveTextHeight(ns, width: width - 2 * BlockLayout.Code.horizontalPadding)
            XCTAssertFalse(language.isEmpty)
            let chrome = BlockLayout.Code.languageLabelHeight(fontScale: 1.0)
                + BlockLayout.Code.languageLabelTopPadding
                + BlockLayout.Code.languageLabelBottomPadding
                + 2 * BlockLayout.Code.verticalPaddingWithLanguage
            let expected = max(inner + chrome, BlockLayout.Code.copyButtonFloorHeight)
                + 2 * BlockLayout.Document.codeOuterVerticalPadding
            XCTAssertEqual(finished.table.heights[1], expected, accuracy: tolerance, "@\(width)")
        }
    }
}
