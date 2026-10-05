import XCTest
import SwiftUI
import AppKit

/// The source editor surface (v1.12 S-D1, S-D3–S-D6, S-D13, S-D15), headless:
/// the views are created in the test process and hosted in a window that is
/// never ordered on screen.
///
/// Undo: AppKit groups undo by run-loop event, and a test has no events — so
/// `groupsByEvent` is off and each simulated user action is wrapped in its own
/// group (`userAction`), which is exactly the group the event would open.
/// Actions that must register NOTHING run outside a group: an empty group
/// still counts as an undo step.
final class SourceEditorControllerTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private let light = MarkdownTheme.cached(for: .light)
    private let dark = MarkdownTheme.theme(named: ThemeName.dracula, colorScheme: .light)

    private func style(_ theme: MarkdownTheme? = nil, scale: Double = 1,
                       reading: Bool = false) -> SourceEditorController.Style {
        SourceEditorController.Style(theme: theme ?? light, fontScale: scale, isReadingLayout: reading)
    }

    /// A controller whose scroll view fills an offscreen window's content.
    private func makeEditor(_ text: String = "", width: CGFloat = 800, height: CGFloat = 600,
                            style editorStyle: SourceEditorController.Style? = nil)
    -> (SourceEditorController, NSScrollView, NSWindow) {
        let controller = SourceEditorController()
        let scrollView = controller.makeScrollView(style: editorStyle ?? style())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        scrollView.frame = content.bounds
        scrollView.autoresizingMask = [.width, .height]
        content.addSubview(scrollView)
        content.layoutSubtreeIfNeeded()
        windows.append(window)
        controller.load(text)
        // No events here: AppKit's per-event group would never close and
        // swallow every action of the test into one undo step.
        controller.undoManager.groupsByEvent = false
        return (controller, scrollView, window)
    }

    /// Lets the deferred exact top-line restore (100 ms after the last
    /// relayout) run.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private func userAction(_ controller: SourceEditorController, _ body: () -> Void) {
        controller.undoManager.beginUndoGrouping()
        body()
        controller.undoManager.endUndoGrouping()
    }

    private func command(_ controller: SourceEditorController, _ selector: Selector) {
        userAction(controller) { controller.textView.doCommand(by: selector) }
    }

    private func type(_ controller: SourceEditorController, _ string: String) {
        userAction(controller) {
            controller.textView.insertText(string, replacementRange: controller.textView.selectedRange())
        }
    }

    /// Top of the line fragment holding `offset`, container coordinates,
    /// measured after laying out the WHOLE text — the ground truth an
    /// estimate would miss.
    private func exactLineTop(_ controller: SourceEditorController, offset: Int) -> CGFloat {
        let layoutManager = controller.textView.layoutManager!
        layoutManager.ensureLayout(for: controller.textView.textContainer!)
        let length = controller.textView.textStorage!.length
        if offset == length, layoutManager.extraLineFragmentTextContainer != nil {
            return layoutManager.extraLineFragmentRect.minY
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(offset, max(length - 1, 0)))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    private func numberedLines(_ count: Int, width: Int = 24) -> String {
        (0..<count).map { index in
            let label = "line \(index) "
            return label + String(repeating: "x", count: max(0, width - label.count))
        }.joined(separator: "\n")
    }

    private func rgba(_ color: NSColor, in appearance: NSAppearance?) -> [CGFloat] {
        var result: [CGFloat] = []
        let resolve = {
            let c = color.usingColorSpace(.sRGB)!
            result = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(resolve) } else { resolve() }
        return result
    }

    private func assertSameColor(_ lhs: NSColor?, _ rhs: Color, appearance: NSAppearance?,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs else { return XCTFail("missing colour", file: file, line: line) }
        let a = rgba(lhs, in: appearance), b = rgba(NSColor(rhs), in: appearance)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 0.002, file: file, line: line) }
    }

    // MARK: - Configuration (S-D4, S-D15)

    func testConfigurationIsPlainTextTextKit1WithFindBar() {
        let (controller, scrollView, _) = makeEditor("hello")
        let view = controller.textView
        XCTAssertNil(view.textLayoutManager, "must never fall into TextKit 2")
        XCTAssertNotNil(view.layoutManager)
        XCTAssertTrue(view.layoutManager!.allowsNonContiguousLayout)
        XCTAssertFalse(view.textContainer!.widthTracksTextView)
        XCTAssertEqual(view.textContainer!.lineFragmentPadding, 0)
        XCTAssertTrue(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        XCTAssertTrue(view.allowsUndo)
        XCTAssertFalse(view.isRichText)
        XCTAssertFalse(view.importsGraphics)
        XCTAssertFalse(view.usesFontPanel)
        XCTAssertFalse(view.usesRuler)
        XCTAssertFalse(view.isRulerVisible)
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(view.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(view.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(view.smartInsertDeleteEnabled)
        XCTAssertFalse(view.isGrammarCheckingEnabled)
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(view.usesFindBar)
        XCTAssertTrue(view.isIncrementalSearchingEnabled)
        XCTAssertFalse(view.isHorizontallyResizable)
        XCTAssertEqual(view.accessibilityIdentifier(), "source-editor")
        XCTAssertFalse(scrollView.autohidesScrollers)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.documentView === view)
        XCTAssertTrue(controller.makeScrollView(style: style()) === scrollView, "built once")
    }

    // MARK: - Undo manager (S-D1)

    func testTextViewUsesTheControllersUndoManagerNotTheWindows() {
        let (controller, _, window) = makeEditor("abc")
        XCTAssertTrue(controller.textView.undoManager === controller.undoManager)
        XCTAssertFalse(controller.textView.undoManager === window.undoManager)
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "d")
        XCTAssertTrue(controller.undoManager.canUndo)
        XCTAssertFalse(window.undoManager?.canUndo ?? false, "nothing may land on the window's stack")
    }

    // MARK: - Buffer

    func testLoadReplacesEverythingWithoutUndoOrChange() {
        let (controller, _, _) = makeEditor("old")
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "!")
        XCTAssertEqual(changes, 1)
        controller.load("first\r\nsecond\rthird")
        XCTAssertEqual(controller.text, "first\nsecond\nthird")
        XCTAssertFalse(controller.text.unicodeScalars.contains("\r"))
        XCTAssertFalse(controller.undoManager.canUndo, "load clears the stack")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(changes, 1, "load never fires onChange")
    }

    func testReplaceAllIsOneUndoableEditAndFiresOnChange() {
        let (controller, _, _) = makeEditor("saved text\nline two")
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0))
        userAction(controller) { controller.replaceAll(with: "disk\r\nversion") }
        XCTAssertEqual(controller.text, "disk\nversion")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 5, length: 0))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "saved text\nline two")
        controller.undoManager.redo()
        XCTAssertEqual(controller.text, "disk\nversion")
    }

    func testReplaceAllWithShorterTextClampsTheCaret() {
        let (controller, _, _) = makeEditor("a long line of text")
        controller.textView.setSelectedRange(NSRange(location: 15, length: 0))
        controller.replaceAll(with: "ab")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    // MARK: - CR normalisation

    func testInsertedCarriageReturnsAreNormalizedAndUndoIsCoherent() {
        let (controller, _, _) = makeEditor("hello\n")
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        type(controller, "a\r\nb\rc")
        XCTAssertEqual(controller.text, "hello\na\nb\nc")
        XCTAssertFalse(controller.text.unicodeScalars.contains("\r"))
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 11, length: 0))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "hello\n")
        controller.undoManager.redo()
        XCTAssertEqual(controller.text, "hello\na\nb\nc")
    }

    func testReplacingASelectionWithCRLFTextNormalizes() {
        let (controller, _, _) = makeEditor("one TWO three")
        controller.textView.setSelectedRange(NSRange(location: 4, length: 3))
        type(controller, "2\r\n2")
        XCTAssertEqual(controller.text, "one 2\n2 three")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "one TWO three")
    }

    func testPastedCRLFTextIsNormalized() {
        let (controller, _, _) = makeEditor("start ")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickMDTests.SourceEditor.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x\r\ny\rz", forType: .string)
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        userAction(controller) {
            _ = controller.textView.readSelection(from: pasteboard, type: .string)
        }
        XCTAssertEqual(controller.text, "start x\ny\nz")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "start ")
    }

    // MARK: - Typing comforts (S-D5)

    func testReturnKeepsTheLinesIndentationAsOneUndo() {
        let (controller, _, _) = makeEditor("    foo")
        controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        command(controller, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(controller.text, "    foo\n    ")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 12, length: 0))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "    foo")
    }

    func testReturnAfterTypingUndoesSeparately() {
        let (controller, _, _) = makeEditor("\tx")
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        type(controller, "yz")
        command(controller, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(controller.text, "\txyz\n\t")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "\txyz", "the Return is its own undo step")
    }

    func testTabOnACaretInsertsTheDocumentsIndentUnit() {
        let (controller, _, _) = makeEditor("a")
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        command(controller, #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(controller.text, "    a")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 4, length: 0))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "a")

        controller.load("\tx\ny")
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        command(controller, #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(controller.text, "\tx\n\ty", "a tab-indented document indents with tabs")
    }

    func testIndentUnitFollowsEditsToTheBuffer() {
        let (controller, _, _) = makeEditor("x\ny")
        controller.textView.setSelectedRange(NSRange(location: 1, length: 0))
        command(controller, #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(controller.text, "x    \ny")
        // A tab-indented line appears: the cached unit must not survive it.
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        type(controller, "\t")
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        command(controller, #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(controller.text, "\tx    \n\ty")
    }

    func testTabAndShiftTabOnAMultiLineSelectionEachUndoAsOne() {
        let (controller, _, _) = makeEditor("a\nb\nc")
        controller.textView.setSelectedRange(NSRange(location: 0, length: 3))
        command(controller, #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(controller.text, "    a\n    b\nc")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 0, length: 11))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "a\nb\nc")
        controller.undoManager.redo()
        XCTAssertEqual(controller.text, "    a\n    b\nc")

        controller.textView.setSelectedRange(NSRange(location: 0, length: 11))
        command(controller, #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(controller.text, "a\nb\nc")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 0, length: 3))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "    a\n    b\nc")
    }

    func testShiftTabOnACaretOutdentsItsLine() {
        let (controller, _, _) = makeEditor("x\n      y")
        controller.textView.setSelectedRange(NSRange(location: 8, length: 0))
        command(controller, #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(controller.text, "x\n  y")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "x\n      y")
    }

    func testShiftTabWithNothingToOutdentChangesNothing() {
        let (controller, _, _) = makeEditor("plain")
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        controller.textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(controller.text, "plain")
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(controller.undoManager.canUndo)
    }

    // MARK: - Escape

    func testEscapeCallsOnEscapeAndInsertsNothing() {
        let (controller, _, _) = makeEditor("text")
        var escapes = 0, changes = 0
        controller.onEscape = { escapes += 1 }
        controller.onChange = { changes += 1 }
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        controller.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(controller.text, "text")
        XCTAssertFalse(controller.undoManager.canUndo)
    }

    // MARK: - onChange

    func testOnChangeFiresForEditsUndoAndRedoButNotForLoadOrStyle() {
        let (controller, _, _) = makeEditor("abc")
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.load("fresh")
        controller.apply(style: style(scale: 1.5))
        controller.apply(style: style(dark, scale: 1.5, reading: true))
        XCTAssertEqual(changes, 0)
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0))
        type(controller, "!")
        XCTAssertEqual(changes, 1)
        controller.undoManager.undo()
        XCTAssertEqual(changes, 2)
        controller.undoManager.redo()
        XCTAssertEqual(changes, 3)
    }

    // MARK: - Caret and scrolling (S-D3, S-D13)

    func testPlaceCaretPutsTheLineAtTheTopOfTheVisibleArea() {
        let (controller, scrollView, _) = makeEditor(numberedLines(2_000))
        let storage = controller.textView.textStorage!.mutableString
        controller.placeCaret(atLine: 1_000)
        let offset = SourceEditSupport.lineStart(1_000, in: storage)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: offset, length: 0))
        XCTAssertEqual(controller.caretLine, 1_000)
        let top = scrollView.contentView.bounds.minY
        XCTAssertEqual(top, exactLineTop(controller, offset: offset), accuracy: 0.01)
        // The line itself sits one vertical inset below the visible top —
        // the gap a `.top` jump leaves in the rendered list.
        let lineInView = exactLineTop(controller, offset: offset) + controller.textView.textContainerOrigin.y
        XCTAssertEqual(lineInView - controller.textView.visibleRect.minY,
                       BlockLayout.Document.contentVerticalPadding, accuracy: 0.01)
    }

    func testPlaceCaretOnLineZeroScrollsToTheTop() {
        let (controller, scrollView, _) = makeEditor(numberedLines(500))
        controller.scroll(toLine: 300)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
        controller.placeCaret(atLine: 0)
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0)
        XCTAssertEqual(controller.caretLine, 0)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testScrollToLineLeavesTheCaretAlone() {
        let (controller, scrollView, _) = makeEditor(numberedLines(1_000))
        controller.placeCaret(atLine: 10)
        let caret = controller.textView.selectedRange()
        controller.scroll(toLine: 700)
        XCTAssertEqual(controller.textView.selectedRange(), caret)
        let offset = SourceEditSupport.lineStart(700, in: controller.textView.textStorage!.mutableString)
        XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: offset), accuracy: 0.01)
    }

    func testCaretLineAndSelect() {
        let (controller, scrollView, _) = makeEditor(numberedLines(1_000))
        let storage = controller.textView.textStorage!.mutableString
        let range = NSRange(location: SourceEditSupport.lineStart(900, in: storage) + 2, length: 3)
        controller.select(range)
        XCTAssertEqual(controller.textView.selectedRange(), range)
        XCTAssertEqual(controller.caretLine, 900)
        let lineTop = exactLineTop(controller, offset: range.location) + controller.textView.textContainerOrigin.y
        XCTAssertTrue(scrollView.contentView.bounds.contains(NSPoint(x: 40, y: lineTop + 1)),
                      "the selection is scrolled into view")
    }

    func testPlaceCaretBeforeTheFirstLayoutScrollsOnceTheViewHasAWidth() {
        let controller = SourceEditorController()
        controller.load(numberedLines(1_000))
        let scrollView = controller.makeScrollView(style: style())
        controller.placeCaret(atLine: 600)
        XCTAssertEqual(controller.caretLine, 600)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(scrollView)
        window.contentView!.layoutSubtreeIfNeeded()
        let offset = SourceEditSupport.lineStart(600, in: controller.textView.textStorage!.mutableString)
        XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: offset), accuracy: 0.01)
    }

    /// ~5 MB / 200 000 lines — the provisional size cap. A line deep inside
    /// lands EXACTLY at the top (layout is ensured up to it, not estimated);
    /// the last line cannot reach the top, so the document's end is at the
    /// bottom with the line visible. Prints the `placeCaret` time.
    func testPlaceCaretInALargeDocumentIsExact() {
        let text = numberedLines(200_000, width: 25)
        XCTAssertGreaterThan(text.utf16.count, 5_000_000)
        let (controller, scrollView, _) = makeEditor(text)
        let storage = controller.textView.textStorage!.mutableString

        let started = Date()
        controller.placeCaret(atLine: 199_999)
        let lastLineTime = Date().timeIntervalSince(started)
        let started2 = Date()
        controller.placeCaret(atLine: 150_000)
        let deepLineTime = Date().timeIntervalSince(started2)
        print("PERF SourceEditor placeCaret: last line of 200k (cold) \(Int(lastLineTime * 1000)) ms, line 150k (warm) \(Int(deepLineTime * 1000)) ms")

        let deepOffset = SourceEditSupport.lineStart(150_000, in: storage)
        XCTAssertEqual(controller.caretLine, 150_000)
        XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: deepOffset),
                       accuracy: 0.01)

        controller.placeCaret(atLine: 199_999)
        let lastOffset = SourceEditSupport.lineStart(199_999, in: storage)
        XCTAssertEqual(controller.caretLine, 199_999)
        let clip = scrollView.contentView.bounds
        let lastTop = exactLineTop(controller, offset: lastOffset) + controller.textView.textContainerOrigin.y
        let farthest = scrollView.contentView.constrainBoundsRect(
            NSRect(x: 0, y: controller.textView.frame.maxY, width: clip.width, height: clip.height))
        XCTAssertEqual(clip.minY, farthest.minY, accuracy: 0.5, "scrolled to the end")
        XCTAssertTrue(clip.minY <= lastTop && lastTop < clip.maxY, "the last line is visible")
    }

    // MARK: - Style (zoom, theme, layout)

    func testApplyStyleChangesTheFontWithoutUndoOrChange() {
        let (controller, scrollView, _) = makeEditor(numberedLines(3_000))
        var changes = 0
        controller.onChange = { changes += 1 }
        let font = controller.textView.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, BlockLayout.Code.codeFontSize)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        controller.placeCaret(atLine: 1_200)
        let caret = controller.textView.selectedRange()

        controller.apply(style: style(scale: 1.5))
        let zoomed = controller.textView.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(zoomed?.pointSize, BlockLayout.Code.codeFontSize * 1.5)
        let last = controller.textView.textStorage!.length - 1
        let zoomedEnd = controller.textView.textStorage!.attribute(.font, at: last, effectiveRange: nil) as? NSFont
        XCTAssertEqual(zoomedEnd?.pointSize, BlockLayout.Code.codeFontSize * 1.5, "the whole buffer")
        XCTAssertEqual((controller.textView.typingAttributes[.font] as? NSFont)?.pointSize,
                       BlockLayout.Code.codeFontSize * 1.5)
        XCTAssertFalse(controller.undoManager.canUndo)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(controller.textView.selectedRange(), caret)
        // The top line stays the top line: at once within a line or two (the
        // layout manager's estimate), exactly once the relayout has settled.
        let storage = controller.textView.textStorage!.mutableString
        let estimatedLine = SourceEditSupport.line(containing: topCharacter(controller, scrollView), in: storage)
        XCTAssertLessThanOrEqual(abs(estimatedLine - 1_200), 3)
        settle()
        XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: caret.location),
                       accuracy: 0.5)
        XCTAssertFalse(controller.undoManager.canUndo)
        XCTAssertEqual(changes, 0)
    }

    func testApplyStyleKeepsAnExistingUndoStack() {
        let (controller, _, _) = makeEditor("abc")
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "d")
        controller.apply(style: style(dark, scale: 2, reading: true))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "abc")
        XCTAssertFalse(controller.undoManager.canUndo, "styling registered nothing")
    }

    /// The list's arithmetic (`VirtualBlockList.currentContentWidth()` and its
    /// centred cell column), spelled out independently.
    private func listColumn(clip: CGFloat, reading: Bool) -> (left: CGFloat, width: CGFloat) {
        let available = floor(clip)
        let inner = available - 2 * 32
        let width = reading ? max(0, floor(min(inner, 720))) : max(0, inner)
        return (32 + (inner - width) / 2, width)
    }

    func testColumnGeometryMatchesTheRenderedList() {
        for clip in [300, 640, 783.5, 800, 1000.6, 1600] as [CGFloat] {
            for reading in [false, true] {
                let geometry = SourceEditorController.columnGeometry(clipWidth: clip, isReadingLayout: reading)
                let list = listColumn(clip: clip, reading: reading)
                XCTAssertEqual(geometry.columnWidth, list.width, "clip \(clip) reading \(reading)")
                XCTAssertEqual(geometry.horizontalInset, list.left, "clip \(clip) reading \(reading)")
                XCTAssertGreaterThanOrEqual(geometry.horizontalInset, 32)
                XCTAssertEqual(geometry.verticalInset, reading ? 48 : 24)
            }
        }
        let standard = SourceEditorController.columnGeometry(clipWidth: 1000, isReadingLayout: false)
        XCTAssertEqual(standard, .init(horizontalInset: 32, columnWidth: 936, verticalInset: 24))
        let reading = SourceEditorController.columnGeometry(clipWidth: 1000, isReadingLayout: true)
        XCTAssertEqual(reading, .init(horizontalInset: 140, columnWidth: 720, verticalInset: 48))
    }

    func testTextContainerFollowsTheViewWidthAndTheLayoutStyle() {
        let (controller, scrollView, window) = makeEditor("text", width: 1000)
        let view = controller.textView
        func check(reading: Bool, line: UInt = #line) {
            let clip = scrollView.contentView.bounds.width
            let list = listColumn(clip: clip, reading: reading)
            XCTAssertEqual(view.textContainer!.size.width, list.width, line: line)
            XCTAssertEqual(view.textContainerInset.width, list.left, line: line)
            XCTAssertEqual(view.textContainerInset.height, reading ? 48 : 24, line: line)
            XCTAssertEqual(view.frame.width, clip, line: line)
        }
        check(reading: false)
        controller.apply(style: style(reading: true))
        check(reading: true)
        window.setContentSize(NSSize(width: 1400, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        check(reading: true)
        controller.apply(style: style(reading: false))
        check(reading: false)
        window.setContentSize(NSSize(width: 501, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        check(reading: false)
    }

    /// The character at the top of the visible area (container coordinates).
    private func topCharacter(_ controller: SourceEditorController, _ scrollView: NSScrollView) -> Int {
        let layoutManager = controller.textView.layoutManager!
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: scrollView.contentView.bounds.minY),
                                             in: controller.textView.textContainer!)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    func testResizingKeepsTheTopLineDeepInALongDocument() {
        var rng = SystemRandomNumberGenerator()
        let text = (0..<20_000).map { index in
            String(repeating: "word ", count: Int.random(in: 0...40, using: &rng)) + "\(index)"
        }.joined(separator: "\n")
        let (controller, scrollView, window) = makeEditor(text, width: 900)
        controller.scroll(toLine: 15_000)
        let storage = controller.textView.textStorage!.mutableString
        let target = SourceEditSupport.lineStart(15_000, in: storage)
        XCTAssertEqual(topCharacter(controller, scrollView), target)
        /// Immediately after a relayout: the estimate — the same text, give
        /// or take a line or two (of 20 000, after the whole layout moved).
        func checkTopLine(_ label: String, line: UInt = #line) {
            let top = SourceEditSupport.line(containing: topCharacter(controller, scrollView), in: storage)
            XCTAssertLessThanOrEqual(abs(top - 15_000), 3, label, line: line)
        }
        func checkExact(_ label: String, line: UInt = #line) {
            settle()
            XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: target),
                           accuracy: 0.5, label, line: line)
        }
        // Several widths in a row (a sidebar animating), then the exact landing.
        for width in [700, 1100, 640] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView!.layoutSubtreeIfNeeded()
            checkTopLine("width \(width)")
        }
        checkExact("after resizing")
        controller.apply(style: style(reading: true))
        checkTopLine("reading layout")
        checkExact("reading layout")
        controller.apply(style: style(scale: 1.3, reading: true))
        checkTopLine("zoom")
        checkExact("zoom")
    }

    func testAScrollAfterARelayoutIsNotUndoneByTheExactRestore() {
        let (controller, scrollView, window) = makeEditor(numberedLines(5_000), width: 900)
        controller.scroll(toLine: 3_000)
        window.setContentSize(NSSize(width: 400, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        controller.scroll(toLine: 100)
        settle()
        let offset = SourceEditSupport.lineStart(100, in: controller.textView.textStorage!.mutableString)
        XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: offset), accuracy: 0.5)
    }

    func testColoursAndAppearanceFollowADarkAndALightTheme() {
        let (controller, scrollView, _) = makeEditor("text", style: style(dark))
        XCTAssertEqual(scrollView.appearance?.name, .darkAqua)
        assertSameColor(controller.textView.backgroundColor, dark.backgroundColor, appearance: scrollView.appearance)
        assertSameColor(scrollView.backgroundColor, dark.backgroundColor, appearance: scrollView.appearance)
        assertSameColor(controller.textView.insertionPointColor, dark.textColor, appearance: scrollView.appearance)
        assertSameColor(controller.textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                        dark.textColor, appearance: scrollView.appearance)
        XCTAssertTrue(scrollView.drawsBackground)

        controller.apply(style: style(light))
        XCTAssertEqual(scrollView.appearance?.name, .aqua)
        assertSameColor(controller.textView.backgroundColor, light.backgroundColor, appearance: scrollView.appearance)
        assertSameColor(controller.textView.insertionPointColor, light.textColor, appearance: scrollView.appearance)
        assertSameColor(controller.textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                        light.textColor, appearance: scrollView.appearance)
        XCTAssertFalse(controller.undoManager.canUndo)
    }

    func testEqualStylesCompareEqual() {
        XCTAssertEqual(style(dark, scale: 1.25, reading: true), style(dark, scale: 1.25, reading: true))
        XCTAssertNotEqual(style(dark), style(light))
        XCTAssertNotEqual(style(scale: 1), style(scale: 1.1))
        XCTAssertNotEqual(style(reading: false), style(reading: true))
    }

    // MARK: - Find (S-D6)

    func testFindBarShowsAndHides() {
        let (controller, _, window) = makeEditor("find me, find me")
        window.makeFirstResponder(controller.textView)
        XCTAssertFalse(controller.isFindBarVisible)
        controller.showFind()
        XCTAssertTrue(controller.isFindBarVisible)
        controller.hideFind()
        XCTAssertFalse(controller.isFindBarVisible)
    }

    func testFocusMakesTheTextViewFirstResponder() {
        let (controller, _, window) = makeEditor("x")
        controller.focus()
        XCTAssertTrue(window.firstResponder === controller.textView)
    }
}
