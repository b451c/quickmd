import XCTest
import SwiftUI
import AppKit

/// The document-wide selection model and its copy output (v1.11 S1).
///
/// The model is the whole truth of a selection — views only draw it — so every
/// rule the views rely on is pinned here: ordering, per-row coverage, the
/// atomic-row and multi-click drag rules, and what a copy puts on the
/// pasteboard for every kind of row.
final class DocumentSelectionTests: XCTestCase {

    private func point(_ row: Int, _ offset: Int) -> SelectionPoint {
        SelectionPoint(row: row, offset: offset)
    }

    // MARK: - Ordering / normalisation

    func testPointsOrderByRowThenOffset() {
        XCTAssertLessThan(point(0, 50), point(1, 0))
        XCTAssertLessThan(point(3, 2), point(3, 7))
        XCTAssertFalse(point(3, 7) < point(3, 7))
        XCTAssertEqual([point(2, 0), point(0, 9), point(0, 1)].sorted(),
                       [point(0, 1), point(0, 9), point(2, 0)])
    }

    func testNormalizedOrdersAnUpwardDrag() {
        let upward = DocumentSelection(anchor: point(5, 3), focus: point(2, 8))
        XCTAssertEqual(upward.normalized.start, point(2, 8))
        XCTAssertEqual(upward.normalized.end, point(5, 3))
        // The anchor itself is kept: Shift-click extends from it.
        XCTAssertEqual(upward.anchor, point(5, 3))

        let downward = DocumentSelection(anchor: point(2, 8), focus: point(5, 3))
        XCTAssertEqual(downward.normalized.start, point(2, 8))
        XCTAssertEqual(downward.normalized.end, point(5, 3))
    }

    func testCollapsedSelectionIsEmptyAndCoversNothing() {
        let collapsed = DocumentSelection(collapsedAt: point(4, 10))
        XCTAssertTrue(collapsed.isEmpty)
        XCTAssertNil(collapsed.rowSpan)
        XCTAssertNil(collapsed.range(inRow: 4, rowLength: 100))
        XCTAssertFalse(DocumentSelection(anchor: point(4, 10), focus: point(4, 11)).isEmpty)
    }

    // MARK: - Per-row ranges

    func testRangeWithinOneRow() {
        let selection = DocumentSelection(anchor: point(2, 9), focus: point(2, 4))
        XCTAssertEqual(selection.range(inRow: 2, rowLength: 20), NSRange(location: 4, length: 5))
        XCTAssertNil(selection.range(inRow: 1, rowLength: 20))
        XCTAssertNil(selection.range(inRow: 3, rowLength: 20))
        XCTAssertEqual(selection.rowSpan, 2...2)
    }

    func testRangesAcrossRows() {
        let selection = DocumentSelection(anchor: point(1, 6), focus: point(4, 3))
        XCTAssertNil(selection.range(inRow: 0, rowLength: 10))
        // First row: from the anchor to the row's end.
        XCTAssertEqual(selection.range(inRow: 1, rowLength: 10), NSRange(location: 6, length: 4))
        // Middle rows: whole.
        XCTAssertEqual(selection.range(inRow: 2, rowLength: 7), NSRange(location: 0, length: 7))
        XCTAssertEqual(selection.range(inRow: 3, rowLength: 1), NSRange(location: 0, length: 1))
        // Last row: from its start to the focus.
        XCTAssertEqual(selection.range(inRow: 4, rowLength: 10), NSRange(location: 0, length: 3))
        XCTAssertNil(selection.range(inRow: 5, rowLength: 10))
        XCTAssertEqual(selection.rowSpan, 1...4)
    }

    func testEdgeOffsetsCoverNothingOfTheirRow() {
        // Ends at the very start of row 3 / starts at the very end of row 1.
        let selection = DocumentSelection(anchor: point(1, 10), focus: point(3, 0))
        XCTAssertNil(selection.range(inRow: 1, rowLength: 10))
        XCTAssertEqual(selection.range(inRow: 2, rowLength: 5), NSRange(location: 0, length: 5))
        XCTAssertNil(selection.range(inRow: 3, rowLength: 10))
    }

    func testOffsetsAreClampedToTheRowLength() {
        let selection = DocumentSelection(anchor: point(0, 2), focus: point(0, 999))
        XCTAssertEqual(selection.range(inRow: 0, rowLength: 6), NSRange(location: 2, length: 4))
        XCTAssertNil(selection.range(inRow: 0, rowLength: 0))
        XCTAssertNil(DocumentSelection(anchor: point(0, 50), focus: point(0, 60))
            .range(inRow: 0, rowLength: 10))
    }

    func testAtomicRowIsCoveredWholeOrNotAtAll() {
        // Atomic rows have length 1: before (0) / after (1).
        let through = DocumentSelection(anchor: point(1, 3), focus: point(3, 2))
        XCTAssertEqual(through.range(inRow: 2, rowLength: 1), NSRange(location: 0, length: 1))
        let endsBefore = DocumentSelection(anchor: point(0, 3), focus: point(2, 0))
        XCTAssertNil(endsBefore.range(inRow: 2, rowLength: 1))
        let startsAfter = DocumentSelection(anchor: point(2, 1), focus: point(4, 2))
        XCTAssertNil(startsAfter.range(inRow: 2, rowLength: 1))
    }

    // MARK: - Select all

    func testSelectAllSpansTheDocumentAndAsksOnlyForTheLastRow() {
        var asked: [Int] = []
        let all = DocumentSelection.selectAll(rowCount: 4) { row in
            asked.append(row)
            return 12
        }
        XCTAssertEqual(asked, [3], "a 10K-row ⌘A must not build every row's string")
        XCTAssertEqual(all?.normalized.start, point(0, 0))
        XCTAssertEqual(all?.normalized.end, point(3, 12))
        XCTAssertEqual(all?.range(inRow: 0, rowLength: 40), NSRange(location: 0, length: 40))
        XCTAssertEqual(all?.range(inRow: 3, rowLength: 12), NSRange(location: 0, length: 12))
    }

    func testSelectAllOfAnEmptyDocumentIsNil() {
        XCTAssertNil(DocumentSelection.selectAll(rowCount: 0) { _ in 0 })
    }

    // MARK: - Drag rules

    func testDragFromATextRowIsAnchorToFocus() {
        let selection = DocumentSelection.dragging(from: point(1, 4), anchorIsAtomic: false, to: point(3, 2))
        XCTAssertEqual(selection, DocumentSelection(anchor: point(1, 4), focus: point(3, 2)))
    }

    func testDragStartingInsideAnAtomicRowSelectsItWholeOnceItLeaves() {
        // Downwards: the atomic row is included from its start.
        let down = DocumentSelection.dragging(from: point(2, 1), anchorIsAtomic: true, to: point(4, 5))
        XCTAssertEqual(down.anchor, point(2, 0))
        XCTAssertEqual(down.range(inRow: 2, rowLength: 1), NSRange(location: 0, length: 1))
        // Upwards: included up to its end.
        let up = DocumentSelection.dragging(from: point(2, 0), anchorIsAtomic: true, to: point(0, 3))
        XCTAssertEqual(up.anchor, point(2, 1))
        XCTAssertEqual(up.range(inRow: 2, rowLength: 1), NSRange(location: 0, length: 1))
        // Staying inside: nothing (no per-cell selection, S-D3).
        let inside = DocumentSelection.dragging(from: point(2, 0), anchorIsAtomic: true, to: point(2, 1))
        XCTAssertTrue(inside.isEmpty)
    }

    func testDragAfterMultiClickKeepsTheWholeUnit() {
        let word = (start: point(3, 10), end: point(3, 15))
        // Inside the word: the word.
        XCTAssertEqual(DocumentSelection.extending(unit: word, to: point(3, 12)),
                       DocumentSelection(anchor: point(3, 10), focus: point(3, 15)))
        // Forwards: from the word's start.
        XCTAssertEqual(DocumentSelection.extending(unit: word, to: point(5, 2)),
                       DocumentSelection(anchor: point(3, 10), focus: point(5, 2)))
        // Backwards: from the word's end, so the word stays whole.
        XCTAssertEqual(DocumentSelection.extending(unit: word, to: point(3, 2)),
                       DocumentSelection(anchor: point(3, 15), focus: point(3, 2)))
    }

    // MARK: - Copy builder: text rows

    func testTextRowLosesTheChunkPrefixAndCollapsesParagraphGaps() {
        // A renderer chunk: leading blank lines, paragraphs three newlines apart.
        let chunk = NSAttributedString(string: "\n\nFirst paragraph.\n\n\nSecond one.\n\n")
        let output = DocumentCopyBuilder.build([.text(chunk)])
        XCTAssertEqual(output.plain, "First paragraph.\n\nSecond one.")
    }

    func testTextRowKeepsIndentationAndTrailingSpaces() {
        let chunk = NSAttributedString(string: "\n   - nested item  ")
        XCTAssertEqual(DocumentCopyBuilder.build([.text(chunk)]).plain, "   - nested item  ")
    }

    func testWhitespaceOnlyTextRowContributesNothing() {
        let output = DocumentCopyBuilder.build([.text(NSAttributedString(string: "Para.")),
                                                .text(NSAttributedString(string: "\n \n\n")),
                                                .text(NSAttributedString(string: "Next."))])
        XCTAssertEqual(output.plain, "Para.\n\nNext.")
    }

    func testRealParserChunkCopiesLikeTheSource() {
        let theme = MarkdownTheme.cached(for: .light)
        let blocks = MarkdownBlockParser(theme: theme).parse("First paragraph.\n\nSecond paragraph.\n\n\nThird.")
        let pieces: [SelectionPiece] = blocks.compactMap { block in
            guard case .text(let attributed) = block.content else { return nil }
            return .text(BlockTextConverter.makeNSAttributedString(
                from: attributed, hasInlineMath: false, theme: theme, fontScale: 1, math: .none))
        }
        XCTAssertFalse(pieces.isEmpty)
        XCTAssertEqual(DocumentCopyBuilder.build(pieces).plain,
                       "First paragraph.\n\nSecond paragraph.\n\nThird.")
    }

    func testRowsAreJoinedWithOneBlankLine() {
        let output = DocumentCopyBuilder.build([.text(NSAttributedString(string: "Heading")),
                                                .text(NSAttributedString(string: "\n\nBody.\n"))])
        XCTAssertEqual(output.plain, "Heading\n\nBody.")
    }

    // MARK: - Copy builder: code and atomic rows

    func testCodeIsCopiedVerbatim() {
        let code = NSAttributedString(string: "\nlet a = 1\n\n\n\nlet b = 2\n")
        XCTAssertEqual(DocumentCopyBuilder.build([.code(code)]).plain, "\nlet a = 1\n\n\n\nlet b = 2\n")
    }

    func testTableBecomesTSV() {
        let output = DocumentCopyBuilder.build([.table(headers: ["Name", "Value"],
                                                       rows: [["alpha", "1"], ["beta", "2"]])])
        XCTAssertEqual(output.plain, "Name\tValue\nalpha\t1\nbeta\t2")
    }

    func testHeaderlessAndRaggedTables() {
        XCTAssertEqual(DocumentCopyBuilder.tsv(headers: nil, rows: [["a", "b", "c"], ["d"]]),
                       "a\tb\tc\nd\t\t")
        // A tab or line break inside a cell would split it.
        XCTAssertEqual(DocumentCopyBuilder.tsv(headers: ["H"], rows: [["x\ty\nz"]]),
                       "H\nx y z")
    }

    func testImageCopiesItsAltOrNothing() {
        let output = DocumentCopyBuilder.build([.text(NSAttributedString(string: "Before")),
                                                .image(alt: "A diagram of the pipeline"),
                                                .image(alt: ""),
                                                .text(NSAttributedString(string: "After"))])
        XCTAssertEqual(output.plain, "Before\n\nA diagram of the pipeline\n\nAfter")
    }

    func testDisplayMathAndMermaidCopyTheirSource() {
        let output = DocumentCopyBuilder.build([.displayMath(latex: "E = mc^2"),
                                                .mermaid(source: "graph TD\n  A --> B")])
        XCTAssertEqual(output.plain, "$$\nE = mc^2\n$$\n\n```mermaid\ngraph TD\n  A --> B\n```")
    }

    // MARK: - Copy builder: inline math, RTF

    func testInlineMathAttachmentCopiesAsItsSource() {
        let theme = MarkdownTheme.cached(for: .light)
        let math = MathRendering(inlineImage: { _, _, _ in NSImage(size: NSSize(width: 20, height: 10)) },
                                 displayHeight: { _, _, _ in 0 })
        let converted = BlockTextConverter.makeNSAttributedString(
            from: AttributedString("Area $\\pi r^2$ of a circle"), hasInlineMath: true,
            theme: theme, fontScale: 1, math: math)

        // The converter tags the attachment with its source…
        var tagged: [String] = []
        converted.enumerateAttribute(.qmdInlineMathSource,
                                     in: NSRange(location: 0, length: converted.length)) { value, _, _ in
            if let latex = value as? String { tagged.append(latex) }
        }
        XCTAssertEqual(tagged, ["\\pi r^2"])
        XCTAssertTrue(converted.string.contains("\u{FFFC}"))

        // …and the copy writes `$…$` instead of U+FFFC, in plain AND rich text.
        let output = DocumentCopyBuilder.build([.text(converted)])
        XCTAssertEqual(output.plain, "Area $\\pi r^2$ of a circle")
        XCTAssertEqual(output.rtf.string, output.plain)
        var attachments = 0
        output.rtf.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.rtf.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0)
    }

    func testOtherAttachmentsAreDropped() {
        let text = NSMutableAttributedString(string: "a")
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        text.append(NSAttributedString(string: "b"))
        XCTAssertEqual(DocumentCopyBuilder.build([.text(text)]).plain, "ab")
    }

    func testRTFDropsThemeColoursButKeepsFontsAndLinks() {
        let font = NSFont.boldSystemFont(ofSize: 15)
        let link = URL(string: "https://example.com")!
        let text = NSMutableAttributedString(string: "White text on dark", attributes: [
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
            .font: font,
        ])
        text.addAttribute(.link, value: link, range: NSRange(location: 0, length: 5))
        let output = DocumentCopyBuilder.build([.text(text)])
        let whole = NSRange(location: 0, length: output.rtf.length)

        var colours = 0
        output.rtf.enumerateAttributes(in: whole) { attributes, _, _ in
            if attributes[.foregroundColor] != nil || attributes[.backgroundColor] != nil { colours += 1 }
        }
        XCTAssertEqual(colours, 0, "pasting a dark-theme selection must not produce white text")
        XCTAssertEqual(output.rtf.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual(output.rtf.attribute(.link, at: 0, effectiveRange: nil) as? URL, link)
        XCTAssertEqual(output.plain, output.rtf.string)
    }

    // MARK: - Selection over opaque text backgrounds (inline code chips)

    /// Paints the document selection exactly as `SelfSizingTextView` does
    /// (that class is not compiled into this target).
    private final class SelectionDrawingTextView: NSTextView {
        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            (layoutManager as? DocumentSelectionLayoutManager)?.drawSelection(in: rect, of: self)
        }
    }

    private let chipGray = NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1)

    /// "plain CHIPCHIP tail", where CHIPCHIP has an opaque background like an
    /// inline `code` run, in a document-configured text view.
    private func chipTextView(appearance: NSAppearance.Name)
        -> (NSTextView, DocumentSelectionLayoutManager, chip: NSRange, plain: NSRange) {
        let textView = SelectionDrawingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        textView.appearance = NSAppearance(named: appearance)
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        let font = NSFont.systemFont(ofSize: 24)
        let text = NSMutableAttributedString(string: "plain ", attributes: [.font: font])
        let chip = NSRange(location: text.length, length: 8)
        text.append(NSAttributedString(string: "CHIPCHIP", attributes: [.font: font, .backgroundColor: chipGray]))
        text.append(NSAttributedString(string: " tail", attributes: [.font: font]))
        textView.textStorage?.setAttributedString(text)
        return (textView, textView.layoutManager as! DocumentSelectionLayoutManager,
                chip, NSRange(location: 0, length: 1))
    }

    /// Colour of the pixel just inside the top-left corner of `range`'s line
    /// box — background, clear of glyph ink.
    private func backgroundPixel(of range: NSRange, in textView: NSTextView) -> NSColor? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else { return nil }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        return rep.colorAt(x: Int((box.minX + 2) * scale), y: Int((box.minY + 1) * scale))?
            .usingColorSpace(.sRGB)
    }

    private func distance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
        guard let a, let b else { return .infinity }
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
    }

    func testCoveredCodeChipShowsTheSameSelectionAsPlainText() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (textView, layoutManager, chip, plain) = chipTextView(appearance: appearance)
            let uncoveredChip = backgroundPixel(of: chip, in: textView)
            XCTAssertLessThan(distance(uncoveredChip, chipGray), 0.05, "\(appearance.rawValue): chip background")

            layoutManager.selectionCoveredRange = NSRange(location: 0, length: textView.string.utf16.count)
            let selectedText = backgroundPixel(of: plain, in: textView)
            let selectedChip = backgroundPixel(of: chip, in: textView)
            XCTAssertGreaterThan(distance(selectedText, chipGray), 0.05,
                                 "\(appearance.rawValue): the selection is visible at all")
            XCTAssertLessThan(distance(selectedChip, selectedText), 0.02,
                              "\(appearance.rawValue): a selected chip looks exactly like selected text")

            // Partly covered: only the covered half of the chip changes.
            layoutManager.selectionCoveredRange = NSRange(location: chip.location + 4,
                                                          length: textView.string.utf16.count - chip.location - 4)
            XCTAssertLessThan(distance(backgroundPixel(of: NSRange(location: chip.location, length: 1), in: textView),
                                       chipGray), 0.05, "\(appearance.rawValue): uncovered half")
            XCTAssertLessThan(distance(backgroundPixel(of: NSRange(location: chip.location + 4, length: 1), in: textView),
                                       selectedText), 0.02, "\(appearance.rawValue): covered half")
        }
    }

    func testSearchHighlightStillDrawsOverASelectedChip() {
        let (textView, layoutManager, chip, _) = chipTextView(appearance: .aqua)
        layoutManager.selectionCoveredRange = NSRange(location: 0, length: textView.string.utf16.count)
        let yellow = NSColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: yellow, forCharacterRange: chip)
        XCTAssertLessThan(distance(backgroundPixel(of: chip, in: textView), yellow), 0.05)
    }

    func testLayoutManagerSwapKeepsTheReadOnlyConfiguration() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        XCTAssertTrue(textView.layoutManager is DocumentSelectionLayoutManager)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.allowsUndo)
        XCTAssertFalse(textView.usesFindBar)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertFalse(textView.isVerticallyResizable)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, 0)
        // Idempotent: a second call does not replace it again.
        let installed = textView.layoutManager
        textView.installDocumentSelectionLayoutManager()
        XCTAssertTrue(textView.layoutManager === installed)
    }

    func testSelectionLayoutManagerKeepsLayout() {
        let paragraph = NSAttributedString(string: String(repeating: "Wrapping words in a paragraph. ", count: 30),
                                           attributes: [.font: NSFont.systemFont(ofSize: 15)])
        for width in [180, 333, 640] as [CGFloat] {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
            textView.configureForSelfSizing()
            textView.installDocumentSelectionLayoutManager()
            textView.textStorage?.setAttributedString(paragraph)
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
                return XCTFail("no TextKit 1 stack")
            }
            XCTAssertTrue(layoutManager is DocumentSelectionLayoutManager)
            layoutManager.ensureLayout(for: container)
            XCTAssertEqual(ceil(layoutManager.usedRect(for: container).height),
                           BlockHeightMeasurer.exactHeight(text: paragraph, width: width),
                           "width \(width)")
        }
    }

    // MARK: - Autoscroll at the screen edge

    func testScreenEdgeZoneOnlyWhereTheClipTouchesTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Full screen: clip from y 0 to 860 (title/search bar above it).
        let fullScreenClip = NSRect(x: 0, y: 0, width: 1440, height: 860)
        XCTAssertEqual(SelectionAutoscroll.screenEdgeDirection(clipOnScreen: fullScreenClip, screenFrame: screen,
                                                               pointer: NSPoint(x: 500, y: 0)), 1)
        XCTAssertEqual(SelectionAutoscroll.screenEdgeDirection(clipOnScreen: fullScreenClip, screenFrame: screen,
                                                               pointer: NSPoint(x: 500, y: 5)), 1)
        XCTAssertNil(SelectionAutoscroll.screenEdgeDirection(clipOnScreen: fullScreenClip, screenFrame: screen,
                                                             pointer: NSPoint(x: 500, y: 7)))
        // The top of this clip is not the screen's top: no zone there.
        XCTAssertNil(SelectionAutoscroll.screenEdgeDirection(clipOnScreen: fullScreenClip, screenFrame: screen,
                                                             pointer: NSPoint(x: 500, y: 858)))
        // A clip whose top touches the screen top (within the 2 pt tolerance).
        let topClip = NSRect(x: 0, y: 200, width: 800, height: 699)
        XCTAssertEqual(SelectionAutoscroll.screenEdgeDirection(clipOnScreen: topClip, screenFrame: screen,
                                                               pointer: NSPoint(x: 10, y: 896)), -1)
        // An ordinary window in the middle of the screen: strictly-outside only.
        let floating = NSRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertNil(SelectionAutoscroll.screenEdgeDirection(clipOnScreen: floating, screenFrame: screen,
                                                             pointer: NSPoint(x: 300, y: 101)))
        XCTAssertNil(SelectionAutoscroll.screenEdgeDirection(clipOnScreen: floating, screenFrame: screen,
                                                             pointer: NSPoint(x: 300, y: 699)))
    }

    // MARK: - Clipboard + toast text

    func testSummaryCountsCharactersAndWords() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(DocumentClipboard.summary(for: "a", locale: english), "Copied 1 character")
        // One word says nothing the character count did not.
        XCTAssertEqual(DocumentClipboard.summary(for: "hello", locale: english), "Copied 5 characters")
        XCTAssertEqual(DocumentClipboard.summary(for: "hello world", locale: english),
                       "Copied 11 characters \u{00B7} 2 words")
        // Characters are Characters: "é" (e + combining accent) and a flag are one each.
        XCTAssertEqual(DocumentClipboard.summary(for: "e\u{301}\u{1F1F5}\u{1F1F1}", locale: english),
                       "Copied 2 characters")
        // Words are whitespace-separated tokens, newlines and tabs included.
        XCTAssertEqual(DocumentClipboard.summary(for: "one\ttwo\n\nthree", locale: english),
                       "Copied 14 characters \u{00B7} 3 words")
    }

    func testSummaryUsesTheLocalesGrouping() {
        let text = String(repeating: "abcd ", count: 300)  // 1 500 characters, 300 words
        XCTAssertEqual(DocumentClipboard.summary(for: text, locale: Locale(identifier: "en_US")),
                       "Copied 1,500 characters \u{00B7} 300 words")
        XCTAssertEqual(DocumentClipboard.summary(for: text, locale: Locale(identifier: "de_DE")),
                       "Copied 1.500 characters \u{00B7} 300 words")
    }

    func testClipboardWritesPlainAndRTFInOneTransaction() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pl.falami.studio.QuickMD.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let rich = NSAttributedString(string: "Copied text", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let toast = DocumentClipboard.write(plain: "Copied text", rtf: rich, to: pasteboard)
        XCTAssertEqual(toast, DocumentClipboard.summary(for: "Copied text"))
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied text")
        let rtf = pasteboard.data(forType: .rtf)
        XCTAssertNotNil(rtf)
        if let rtf {
            let decoded = NSAttributedString(rtf: rtf, documentAttributes: nil)
            XCTAssertEqual(decoded?.string, "Copied text")
        }
    }

    // MARK: - Every copy action's toast (S-D9)

    func testPlainOnlyWriteDeclaresNoRTF() {
        // Copy Markdown, Copy section and the code button write plain text only.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pl.falami.studio.QuickMD.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let source = "# Title\n\nSome **bold** text.\n"
        let toast = DocumentClipboard.write(plain: source, rtf: nil, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), source)
        XCTAssertNil(pasteboard.data(forType: .rtf))
        // (AppKit adds the legacy NSStringPboardType alias itself — only RTF matters.)
        XCTAssertFalse((pasteboard.types ?? []).contains(.rtf))
        XCTAssertEqual(toast, DocumentClipboard.summary(for: source))
    }

    func testSummaryForSourceCopies() {
        let english = Locale(identifier: "en_US")
        // A one-word code block: the word count says nothing, so it is left out.
        XCTAssertEqual(DocumentClipboard.summary(for: "ls", locale: english), "Copied 2 characters")
        // Markdown source counts its markup characters too — it is what was copied.
        XCTAssertEqual(DocumentClipboard.summary(for: "# Title\n\nSome **bold** text.", locale: english),
                       "Copied 28 characters \u{00B7} 5 words")
        XCTAssertEqual(DocumentClipboard.summary(for: "", locale: english), "Copied 0 characters")
    }

    // MARK: - Auto-copy decision (S-D10)

    private func selection(_ from: Int, _ to: Int) -> DocumentSelection {
        DocumentSelection(anchor: SelectionPoint(row: 0, offset: from), focus: SelectionPoint(row: 0, offset: to))
    }

    func testMouseGestureClassification() {
        XCTAssertEqual(SelectionChange.mouseGesture(isExtending: false, isMultiClick: false, dragged: false), .click)
        XCTAssertEqual(SelectionChange.mouseGesture(isExtending: false, isMultiClick: false, dragged: true), .drag)
        XCTAssertEqual(SelectionChange.mouseGesture(isExtending: false, isMultiClick: true, dragged: false), .multiClick)
        // A drag after a double/triple click is still that multi-click.
        XCTAssertEqual(SelectionChange.mouseGesture(isExtending: false, isMultiClick: true, dragged: true), .multiClick)
        // Shift wins: Shift-click and Shift-drag extend.
        XCTAssertEqual(SelectionChange.mouseGesture(isExtending: true, isMultiClick: false, dragged: false), .shiftClick)
        XCTAssertEqual(SelectionChange.mouseGesture(isExtending: true, isMultiClick: false, dragged: true), .shiftClick)
    }

    func testGestureEndsCopyANonEmptySelectionWhenEnabled() {
        for change in [SelectionChange.drag, .multiClick, .shiftClick, .selectAll] {
            XCTAssertTrue(SelectionAutoCopy.shouldCopy(after: change, selection: selection(0, 5), enabled: true),
                          "\(change)")
            // Backwards (upward drag) is just as non-empty.
            XCTAssertTrue(SelectionAutoCopy.shouldCopy(after: change, selection: selection(5, 0), enabled: true),
                          "\(change)")
        }
    }

    func testAutoCopyNeverFiresWhenOffEmptyOrNotAGesture() {
        let all: [SelectionChange] = [.drag, .multiClick, .shiftClick, .selectAll, .click, .programmatic]
        for change in all {
            // Off (the default).
            XCTAssertFalse(SelectionAutoCopy.shouldCopy(after: change, selection: selection(0, 5), enabled: false))
            // Nothing selected: a click in a gap, a drag that stayed inside an
            // atomic row, ⌘A on an empty document.
            XCTAssertFalse(SelectionAutoCopy.shouldCopy(after: change, selection: selection(3, 3), enabled: true))
            XCTAssertFalse(SelectionAutoCopy.shouldCopy(after: change, selection: nil, enabled: true))
        }
        // Not the reader's doing, or no selection made.
        XCTAssertFalse(SelectionAutoCopy.shouldCopy(after: .programmatic, selection: selection(0, 5), enabled: true))
        XCTAssertFalse(SelectionAutoCopy.shouldCopy(after: .click, selection: selection(0, 5), enabled: true))
    }

    func testAutoCopySettingDefaultsToOff() {
        let suite = "pl.falami.studio.QuickMD.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SelectionAutoCopy.isEnabled(in: defaults))
        defaults.set(true, forKey: SelectionAutoCopy.defaultsKey)
        XCTAssertTrue(SelectionAutoCopy.isEnabled(in: defaults))
        XCTAssertEqual(SelectionAutoCopy.defaultsKey, "autoCopySelection")
    }
}
