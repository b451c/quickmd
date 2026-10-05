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

    /// Runs the main run loop until `condition` holds (or a generous timeout).
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout) s", file: file, line: line)
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Waits for the deferred exact top-line restore (100 ms after the last
    /// relayout) to have run.
    private func settle(_ controller: SourceEditorController, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil({ !controller.isRestorePending }, file: file, line: line)
    }

    /// Deterministic pseudo-random numbers (SplitMix64), so a failing
    /// layout test fails the same way every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Lines of 0–40 words (they wrap differently at every width).
    private func wrappingLines(_ count: Int, seed: UInt64 = 42) -> String {
        var rng = SeededGenerator(state: seed)
        return (0..<count).map { index in
            String(repeating: "word ", count: Int.random(in: 0...40, using: &rng)) + "\(index)"
        }.joined(separator: "\n")
    }

    /// The line fragment at the top EDGE of the visible area — its first
    /// character and how far its top is from that edge — measured the way
    /// the controller anchors a relayout (container coordinates on both sides).
    private func topLine(_ controller: SourceEditorController,
                         _ scrollView: NSScrollView) -> (character: Int, offset: CGFloat) {
        let layoutManager = controller.textView.layoutManager!
        let top = scrollView.contentView.bounds.minY - controller.textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(top, 0)),
                                             in: controller.textView.textContainer!)
        var line = NSRange()
        let lineTop = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line).minY
        return (layoutManager.characterIndexForGlyph(at: line.location), lineTop - top)
    }

    /// `topLine`'s offset for `character`'s line, from a FULL layout.
    private func exactOffset(_ controller: SourceEditorController, _ scrollView: NSScrollView,
                             character: Int) -> CGFloat {
        exactLineTop(controller, offset: character)
            - (scrollView.contentView.bounds.minY - controller.textView.textContainerOrigin.y)
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
        let before = topLine(controller, scrollView)

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
        let estimatedLine = SourceEditSupport.line(containing: topLine(controller, scrollView).character, in: storage)
        XCTAssertLessThanOrEqual(abs(estimatedLine - SourceEditSupport.line(containing: before.character, in: storage)), 3)
        settle(controller)
        XCTAssertEqual(exactOffset(controller, scrollView, character: before.character), before.offset, accuracy: 0.5)
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

    func testRelayoutsKeepTheTopLineDeepInAWrappingDocument() {
        // ~300 K UTF-16 units: the anchor stays below the exact-restore limit.
        let (controller, scrollView, window) = makeEditor(wrappingLines(3_000), width: 900)
        let storage = controller.textView.textStorage!.mutableString
        XCTAssertLessThan(storage.length, SourceEditorController.exactRestoreCharacterLimit)
        controller.scroll(toLine: 2_000)
        let anchor = topLine(controller, scrollView)
        let anchorLine = SourceEditSupport.line(containing: anchor.character, in: storage)
        /// Immediately after a relayout: the estimate — the same text, give
        /// or take a line or two.
        func checkEstimate(_ label: String, line: UInt = #line) {
            let top = SourceEditSupport.line(containing: topLine(controller, scrollView).character, in: storage)
            XCTAssertLessThanOrEqual(abs(top - anchorLine), 3, label, line: line)
        }
        /// Once settled: the anchor's line exactly where it was on screen.
        func checkExact(_ label: String, line: UInt = #line) {
            // A relayout that did nothing would pass the check below vacuously.
            XCTAssertTrue(controller.isRestorePending, "\(label): a restore is due", line: line)
            settle(controller, line: line)
            XCTAssertEqual(exactOffset(controller, scrollView, character: anchor.character), anchor.offset,
                           accuracy: 0.5, label, line: line)
        }
        // Several widths in a row (a sidebar animating), then the exact landing.
        for width in [700, 1100, 640] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView!.layoutSubtreeIfNeeded()
            checkEstimate("width \(width)")
        }
        checkExact("after resizing")
        controller.apply(style: style(reading: true))
        checkEstimate("reading layout")
        checkExact("reading layout")
        controller.apply(style: style(scale: 1.3, reading: true))
        checkEstimate("zoom")
        checkExact("zoom")
    }

    /// Reading Mode changes the vertical inset (24 -> 48 pt). In a window
    /// narrower than the 720 pt cap the column does not change, so the line
    /// at the top must not move by a single point — at once and after settling.
    func testReadingModeInsetChangeDoesNotShiftTheText() {
        let (controller, scrollView, _) = makeEditor(wrappingLines(2_000), width: 700)
        XCTAssertEqual(SourceEditorController.columnGeometry(clipWidth: scrollView.contentView.bounds.width,
                                                             isReadingLayout: true).columnWidth,
                       controller.textView.textContainer!.size.width, "same column in both layouts")
        controller.scroll(toLine: 1_200)
        let storage = controller.textView.textStorage!.mutableString
        let target = SourceEditSupport.lineStart(1_200, in: storage)
        func screenY() -> CGFloat {
            exactLineTop(controller, offset: target) + controller.textView.textContainerOrigin.y
                - scrollView.contentView.bounds.minY
        }
        let before = screenY()
        controller.apply(style: style(reading: true))
        XCTAssertEqual(controller.textView.textContainerInset.height, 48)
        XCTAssertEqual(screenY(), before, accuracy: 0.5, "at once")
        settle(controller)
        XCTAssertEqual(screenY(), before, accuracy: 0.5, "after settling")
        controller.apply(style: style(reading: false))
        settle(controller)
        XCTAssertEqual(screenY(), before, accuracy: 0.5, "and back")
    }

    /// Beyond `exactRestoreCharacterLimit` the estimate is kept: the exact
    /// pass — a layout of everything above the anchor — does not run. Seen
    /// directly: after settling, the text above the anchor is still unlaid
    /// (background layout off here, so only the controller could lay it out).
    func testExactRestoreIsSkippedBeyondTheCharacterLimit() {
        let (controller, scrollView, window) = makeEditor(numberedLines(40_000), width: 900)
        let layoutManager = controller.textView.layoutManager!
        layoutManager.backgroundLayoutEnabled = false
        controller.scroll(toLine: 30_000)
        let anchor = topLine(controller, scrollView)
        XCTAssertGreaterThan(anchor.character, SourceEditorController.exactRestoreCharacterLimit)
        window.setContentSize(NSSize(width: 700, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isRestorePending)
        settle(controller)
        XCTAssertLessThan(layoutManager.firstUnlaidCharacterIndex(), anchor.character)

        // Control: below the limit the same sequence does lay out up to it.
        controller.scroll(toLine: 5_000)
        let near = topLine(controller, scrollView)
        XCTAssertLessThan(near.character, SourceEditorController.exactRestoreCharacterLimit)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        settle(controller)
        XCTAssertGreaterThanOrEqual(layoutManager.firstUnlaidCharacterIndex(), near.character)
    }

    func testAScrollAfterARelayoutIsNotUndoneByTheExactRestore() {
        let (controller, scrollView, window) = makeEditor(numberedLines(5_000), width: 900)
        controller.scroll(toLine: 3_000)
        window.setContentSize(NSSize(width: 400, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        controller.scroll(toLine: 100)
        settle(controller)
        let offset = SourceEditSupport.lineStart(100, in: controller.textView.textStorage!.mutableString)
        XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: offset), accuracy: 0.5)
    }

    func testLiveScrollAndKeyboardCommandsCancelTheExactRestore() {
        let (controller, scrollView, window) = makeEditor(numberedLines(5_000), width: 900)
        controller.scroll(toLine: 3_000)
        window.setContentSize(NSSize(width: 600, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isRestorePending)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        XCTAssertFalse(controller.isRestorePending, "a scroller drag / trackpad scroll")

        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isRestorePending)
        controller.textView.doCommand(by: #selector(NSResponder.pageDown(_:)))
        XCTAssertFalse(controller.isRestorePending, "keyboard paging")
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

    // MARK: - Reload (S-D9 clean adopt)

    func testReloadReplacesEverythingWithoutUndoOrChange() {
        let (controller, _, _) = makeEditor("one\ntwo\n")
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "!")
        XCTAssertEqual(changes, 1)
        controller.reload("ONE\r\nTWO\r\n")
        XCTAssertEqual(controller.text, "ONE\nTWO\n")
        XCTAssertFalse(controller.undoManager.canUndo, "reload clears the stack")
        XCTAssertEqual(changes, 1, "reload never fires onChange")
        // Typing after a reload never merges with typing before it.
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "?")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "ONE\nTWO\n")
        XCTAssertFalse(controller.undoManager.canUndo)
    }

    func testReloadKeepsTheCaretsLineAndColumn() {
        let (controller, _, _) = makeEditor("first\nsecond line\nthird\n")
        // Line 1, column 4.
        controller.textView.setSelectedRange(NSRange(location: 6 + 4, length: 0))
        // Line 0 grew: the offset moves, the line and column do not.
        controller.reload("a much longer first line\nsecond line\nthird\n")
        let storage = controller.textView.textStorage!.mutableString
        XCTAssertEqual(controller.caretLine, 1)
        XCTAssertEqual(controller.textView.selectedRange(),
                       NSRange(location: SourceEditSupport.lineStart(1, in: storage) + 4, length: 0))
    }

    func testReloadClampsTheCaretToTheNewText() {
        let (controller, _, _) = makeEditor("one\ntwo\nthree is long\n")
        controller.textView.setSelectedRange(NSRange(location: 8 + 10, length: 0))  // line 2, column 10
        controller.reload("one\nx")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 5, length: 0),
                       "the last line, at its end")
        controller.reload("")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testReloadKeepsTheTopLine() {
        let (controller, scrollView, _) = makeEditor(numberedLines(2_000))
        controller.scroll(toLine: 1_200)
        let before = scrollView.contentView.bounds.minY
        XCTAssertGreaterThan(before, 0)
        let storageBefore = controller.textView.textStorage!.mutableString
        let lineBefore = SourceEditSupport.line(containing: topLine(controller, scrollView).character,
                                                in: storageBefore)
        // Same line count, one line above the top rewritten.
        let edited = numberedLines(2_000).replacingOccurrences(of: "line 5 ", with: "LINE 5 ")
        controller.reload(edited)
        let storage = controller.textView.textStorage!.mutableString
        XCTAssertEqual(SourceEditSupport.line(containing: topLine(controller, scrollView).character, in: storage),
                       lineBefore)
        XCTAssertEqual(scrollView.contentView.bounds.minY, before, accuracy: 0.5)
        XCTAssertFalse(controller.isRestorePending)
    }

    /// A reload while a relayout's exact restore is due keeps THAT top line
    /// (exactly) and leaves nothing pending that points into the old text.
    func testReloadDuringAPendingRestoreKeepsItsLineAndCancelsIt() {
        let (controller, scrollView, window) = makeEditor(wrappingLines(2_000), width: 900)
        let storage = controller.textView.textStorage!.mutableString
        controller.scroll(toLine: 1_200)
        let anchor = topLine(controller, scrollView)
        let anchorLine = SourceEditSupport.line(containing: anchor.character, in: storage)
        window.setContentSize(NSSize(width: 700, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isRestorePending)
        // A line far above the top changes; the line count does not.
        controller.reload("changed\n" + wrappingLines(2_000).split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst().joined(separator: "\n"))
        XCTAssertFalse(controller.isRestorePending, "nothing stale left to run")
        let line = SourceEditSupport.line(containing: topLine(controller, scrollView).character, in: storage)
        XCTAssertEqual(line, anchorLine)
        let character = SourceEditSupport.lineStart(anchorLine, in: storage) + anchor.character
            - SourceEditSupport.lineStart(anchorLine, in: wrappingLines(2_000) as NSString)
        XCTAssertEqual(exactOffset(controller, scrollView, character: character), anchor.offset, accuracy: 0.5)
    }

    /// Beyond the exact-restore limit a reload keeps the top line by the
    /// estimate and does not lay out everything above it.
    func testReloadBeyondTheExactLimitUsesTheEstimate() {
        let (controller, scrollView, _) = makeEditor(numberedLines(40_000), width: 900)
        let layoutManager = controller.textView.layoutManager!
        layoutManager.backgroundLayoutEnabled = false
        let storage = controller.textView.textStorage!.mutableString
        controller.scroll(toLine: 30_000)
        let anchor = topLine(controller, scrollView)
        XCTAssertGreaterThan(anchor.character, SourceEditorController.exactRestoreCharacterLimit)
        controller.reload(numberedLines(40_000).replacingOccurrences(of: "line 39999 ", with: "LINE 39999 "))
        XCTAssertLessThan(layoutManager.firstUnlaidCharacterIndex(), anchor.character)
        let top = SourceEditSupport.line(containing: topLine(controller, scrollView).character, in: storage)
        XCTAssertLessThanOrEqual(abs(top - 30_000), 3)
        XCTAssertFalse(controller.isRestorePending)
    }

    func testReloadWithShorterTextScrollsAsFarAsItCan() {
        let (controller, scrollView, _) = makeEditor(numberedLines(2_000))
        controller.scroll(toLine: 1_500)
        controller.reload(numberedLines(10))
        // Ten lines fit on screen: the clip sits at the deepest origin it
        // can reach (AppKit may keep a few points of bottom inset).
        let clip = scrollView.contentView
        var deepest = clip.bounds
        deepest.origin.y = 1_000_000
        XCTAssertEqual(clip.bounds.minY, clip.constrainBoundsRect(deepest).minY)
        XCTAssertLessThan(clip.bounds.minY, 20)
        XCTAssertEqual(controller.caretLine, 0)
    }

    func testReloadBeforeTheFirstLayoutKeepsThePendingLine() {
        let controller = SourceEditorController()
        controller.load(numberedLines(1_000))
        let scrollView = controller.makeScrollView(style: style())
        controller.placeCaret(atLine: 600)
        controller.reload("inserted\n" + numberedLines(1_000))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(scrollView)
        window.contentView!.layoutSubtreeIfNeeded()
        let offset = SourceEditSupport.lineStart(600, in: controller.textView.textStorage!.mutableString)
        XCTAssertEqual(scrollView.contentView.bounds.minY, exactLineTop(controller, offset: offset), accuracy: 0.01)
        XCTAssertEqual(controller.caretLine, 600)
    }

    func testFocusBeforeTheViewHasAWindowIsHonouredWhenItGetsOne() {
        let controller = SourceEditorController()
        let scrollView = controller.makeScrollView(style: style())
        controller.focus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView!.addSubview(scrollView)
        XCTAssertTrue(window.firstResponder === controller.textView)
    }

    func testMakeScrollViewDetachesTheViewFromAnOldHost() {
        let (controller, scrollView, window) = makeEditor("x")
        XCTAssertTrue(scrollView.superview === window.contentView)
        let again = controller.makeScrollView(style: style())
        XCTAssertTrue(again === scrollView)
        XCTAssertNil(again.superview, "never in two hosts at once")
    }

    // MARK: - Review fixes (undo, attributes, line breaks)

    func testUndoManagerDoesNotDependOnTheDelegate() {
        let (controller, _, window) = makeEditor("abc")
        controller.textView.delegate = nil
        XCTAssertTrue(controller.textView.undoManager === controller.undoManager)
        XCTAssertFalse(controller.textView.undoManager === window.undoManager)
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "d")
        XCTAssertTrue(controller.undoManager.canUndo)
        XCTAssertFalse(window.undoManager?.canUndo ?? false)
    }

    func testPastedCRLFTextIsItsOwnUndoStepBetweenTyping() {
        let (controller, _, _) = makeEditor("")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickMDTests.SourceEditor.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x\r\ny", forType: .string)
        type(controller, "abc")
        userAction(controller) { _ = controller.textView.readSelection(from: pasteboard, type: .string) }
        type(controller, "def")
        XCTAssertEqual(controller.text, "abcx\nydef")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "abcx\ny", "only the last typing goes")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "abc", "then the paste")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "")
    }

    func testUndoAfterARestyleRestoresTextInTheCurrentStyle() {
        let (controller, _, _) = makeEditor("hello world")
        controller.textView.setSelectedRange(NSRange(location: 6, length: 5))
        userAction(controller) { controller.textView.delete(nil) }
        XCTAssertEqual(controller.text, "hello ")
        controller.apply(style: style(dark, scale: 2))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "hello world")
        let storage = controller.textView.textStorage!
        var run = NSRange()
        let font = storage.attribute(.font, at: 6, longestEffectiveRange: &run,
                                     in: NSRange(location: 0, length: storage.length)) as? NSFont
        XCTAssertEqual(font?.pointSize, BlockLayout.Code.codeFontSize * 2)
        XCTAssertEqual(run, NSRange(location: 0, length: storage.length), "one run: a plain buffer")
        assertSameColor(storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor,
                        dark.textColor, appearance: NSAppearance(named: .darkAqua))
    }

    func testShiftReturnAndOptionReturnInsertAPlainNewline() {
        for selector in [#selector(NSResponder.insertLineBreak(_:)),
                         #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))] {
            let (controller, _, _) = makeEditor("  item")
            controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
            command(controller, selector)
            XCTAssertEqual(controller.text, "  item\n  ", "\(selector)")
            XCTAssertFalse(controller.text.unicodeScalars.contains("\u{2028}"))
            controller.undoManager.undo()
            XCTAssertEqual(controller.text, "  item")
        }
    }

    func testLoadBreaksTypingCoalescing() {
        let (controller, _, _) = makeEditor("")
        type(controller, "old")
        controller.load("new")
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "er")
        XCTAssertEqual(controller.text, "newer")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "new")
    }

    // MARK: - Second review round

    /// The base font and colour are ADDED to an edited range: another
    /// attribute placed in the same edit (as NSTextView does for marked text
    /// while an input method composes) survives.
    func testEditStampsBaseAttributesWithoutStrippingOthers() {
        let (controller, _, _) = makeEditor("ab", style: style(dark, scale: 2))
        let storage = controller.textView.textStorage!
        let foreign = NSAttributedString.Key("QuickMDTests.foreign")
        storage.replaceCharacters(in: NSRange(location: 1, length: 0), with: NSAttributedString(
            string: "XY",
            attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.red,
                         .underlineStyle: NSUnderlineStyle.single.rawValue, foreign: true]))
        XCTAssertEqual(controller.text, "aXYb")
        for index in [1, 2] {
            XCTAssertEqual(storage.attribute(foreign, at: index, effectiveRange: nil) as? Bool, true)
            XCTAssertEqual(storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                           NSUnderlineStyle.single.rawValue)
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            XCTAssertEqual(font?.pointSize, BlockLayout.Code.codeFontSize * 2)
            assertSameColor(storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                            dark.textColor, appearance: NSAppearance(named: .darkAqua))
        }
    }

    func testPastedCRTextUndoIsNamedPaste() {
        let (controller, _, _) = makeEditor("start ")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickMDTests.SourceEditor.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x\r\ny", forType: .string)
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        userAction(controller) { _ = controller.textView.readSelection(from: pasteboard, type: .string) }
        XCTAssertEqual(controller.text, "start x\ny")
        XCTAssertEqual(controller.undoManager.undoActionName, "Paste")
    }

    /// Replace All with a replacement containing CR (multi-range change):
    /// every replacement is normalised, and the whole change undoes as one.
    func testMultiRangeReplacementWithCRIsNormalizedAsOneUndo() {
        let (controller, _, _) = makeEditor("a-b-c")
        let ranges = [NSRange(location: 1, length: 1), NSRange(location: 3, length: 1)].map { NSValue(range: $0) }
        var allowed = true
        userAction(controller) {
            allowed = controller.textView.shouldChangeText(inRanges: ranges, replacementStrings: ["\r\n", "\r"])
        }
        XCTAssertFalse(allowed, "the CR version is refused and replaced")
        XCTAssertEqual(controller.text, "a\nb\nc")
        XCTAssertFalse(controller.text.unicodeScalars.contains("\r"))
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "a-b-c")
        controller.undoManager.redo()
        XCTAssertEqual(controller.text, "a\nb\nc")
    }

    func testMultiRangeReplacementWithoutCRIsLeftToAppKit() {
        let (controller, _, _) = makeEditor("a-b-c")
        let ranges = [NSRange(location: 1, length: 1), NSRange(location: 3, length: 1)].map { NSValue(range: $0) }
        XCTAssertTrue(controller.textView.delegate!.textView!(controller.textView, shouldChangeTextInRanges: ranges,
                                                              replacementStrings: ["+", "+"]))
        XCTAssertEqual(controller.text, "a-b-c", "nothing done by the delegate itself")
    }

    /// Short lines: under the character limit but beyond the line limit, the
    /// exact pass does not run (layout above the anchor stays undone).
    func testExactRestoreIsSkippedBeyondTheLineLimit() {
        let (controller, scrollView, window) = makeEditor(numberedLines(20_000, width: 12), width: 900)
        let layoutManager = controller.textView.layoutManager!
        layoutManager.backgroundLayoutEnabled = false
        let storage = controller.textView.textStorage!.mutableString
        controller.scroll(toLine: 18_000)
        let anchor = topLine(controller, scrollView)
        XCTAssertLessThan(anchor.character, SourceEditorController.exactRestoreCharacterLimit)
        XCTAssertGreaterThan(SourceEditSupport.line(containing: anchor.character, in: storage),
                             SourceEditorController.exactRestoreLineLimit)
        window.setContentSize(NSSize(width: 700, height: 600))
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isRestorePending)
        settle(controller)
        XCTAssertLessThan(layoutManager.firstUnlaidCharacterIndex(), anchor.character)
    }

    func testCancelPendingFocus() {
        let controller = SourceEditorController()
        let scrollView = controller.makeScrollView(style: style())
        controller.focus()
        controller.cancelPendingFocus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView!.addSubview(scrollView)
        XCTAssertFalse(window.firstResponder === controller.textView)
    }

    // MARK: - Tint (S-D14a)

    /// The temporary foreground colour at `index` and the whole run it covers.
    private func tint(_ controller: SourceEditorController, at index: Int) -> (color: NSColor?, range: NSRange) {
        var range = NSRange()
        let whole = NSRange(location: 0, length: controller.textView.textStorage!.length)
        let color = controller.textView.layoutManager!.temporaryAttribute(
            .foregroundColor, atCharacterIndex: index, longestEffectiveRange: &range, in: whole) as? NSColor
        return (color, range)
    }

    /// Runs the run loop for `seconds` — long enough for a debounce or a
    /// stale parse to have landed if it were going to.
    private func idle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testTintArrivesAfterLoadAsTemporaryAttributes() {
        let (controller, _, _) = makeEditor("# Heading\n\nBody text\n\n> quote\n")
        waitUntil { controller.tintApplyCount == 1 }
        let heading = tint(controller, at: 0)
        assertSameColor(heading.color, light.keywordColor, appearance: nil)
        XCTAssertEqual(heading.range, NSRange(location: 0, length: 9))
        XCTAssertNil(tint(controller, at: 12).color, "a paragraph is not tinted")
        assertSameColor(tint(controller, at: 22).color, light.blockquoteColor, appearance: nil)
        // The storage still holds one plain run in the text colour.
        let storage = controller.textView.textStorage!
        var run = NSRange()
        let stored = storage.attribute(.foregroundColor, at: 0, effectiveRange: &run) as? NSColor
        assertSameColor(stored, light.textColor, appearance: nil)
        XCTAssertEqual(run, NSRange(location: 0, length: storage.length))
    }

    func testEditReTintsAfterTheDebounce() {
        let (controller, _, _) = makeEditor("# Top\n\nBody\n")
        waitUntil { controller.tintApplyCount == 1 }
        controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        type(controller, "## ")
        // Nothing is parsed on the keystroke; the old tint stays put meanwhile
        // (the storage delegate's attribute stamping does not touch it).
        XCTAssertEqual(controller.tintApplyCount, 1)
        assertSameColor(tint(controller, at: 0).color, light.keywordColor, appearance: nil)
        idle(SourceEditorController.tintDebounce / 2)
        XCTAssertEqual(controller.tintApplyCount, 1, "still inside the debounce")
        waitUntil { controller.tintApplyCount == 2 }
        let heading = tint(controller, at: 7)
        assertSameColor(heading.color, light.keywordColor, appearance: nil)
        XCTAssertEqual(heading.range, NSRange(location: 7, length: 7))
    }

    func testTintAddsNoUndoEntryAndNoChange() {
        var changes = 0
        let (controller, _, _) = makeEditor("Body\n")
        controller.onChange = { changes += 1 }
        waitUntil { controller.tintApplyCount == 1 }
        XCTAssertFalse(controller.undoManager.canUndo)
        XCTAssertEqual(changes, 0)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type(controller, "# ")
        XCTAssertEqual(changes, 1)
        waitUntil { controller.tintApplyCount == 2 }
        XCTAssertEqual(changes, 1, "the tint fires no onChange")
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "Body\n")
        XCTAssertFalse(controller.undoManager.canUndo, "the typing was the only undo step")
    }

    func testStyleChangeRecoloursWithoutParsing() {
        let (controller, _, _) = makeEditor("# Heading\n\n```\ncode\n```\n")
        waitUntil { controller.tintApplyCount == 1 }
        XCTAssertNotEqual(NSColor(light.keywordColor), NSColor(dark.keywordColor))
        controller.apply(style: style(dark))
        assertSameColor(tint(controller, at: 0).color, dark.keywordColor, appearance: nil)
        assertSameColor(tint(controller, at: 12).color, dark.secondaryTextColor, appearance: nil)
        // A zoom restyles the storage; the tint survives it.
        controller.apply(style: style(dark, scale: 1.5))
        assertSameColor(tint(controller, at: 0).color, dark.keywordColor, appearance: nil)
        idle(0.3)
        XCTAssertEqual(controller.tintApplyCount, 1, "re-coloured, not re-parsed")
    }

    func testTintOffSwitchLeavesNoTemporaryColour() {
        let (controller, _, _) = makeEditor("# Heading\n\n> quote\n")
        waitUntil { controller.tintApplyCount == 1 }
        controller.isTintEnabled = false
        let length = controller.textView.textStorage!.length
        let whole = tint(controller, at: 0)
        XCTAssertNil(whole.color)
        XCTAssertEqual(whole.range, NSRange(location: 0, length: length))
        controller.load("## Other\n")
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        type(controller, "x")
        idle(SourceEditorController.tintDebounce + 0.3)
        XCTAssertEqual(controller.tintApplyCount, 1, "nothing parsed while off")
        XCTAssertNil(tint(controller, at: 4).color)
        controller.isTintEnabled = true
        waitUntil { controller.tintApplyCount == 2 }
        XCTAssertNotNil(tint(controller, at: 4).color)
    }

    func testStaleParseResultIsDropped() {
        let (controller, _, _) = makeEditor("")
        waitUntil { controller.tintApplyCount == 1 }
        // A's parse is held at its start until B is loaded, so it provably
        // finishes AFTER the buffer changed: only the generation check can
        // keep its result out (B's parse waits behind it on the serial queue).
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        controller.tintParseWillStart = {
            started.signal()
            release.wait()
        }
        controller.load("# A heading\n")
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        controller.tintParseWillStart = nil
        controller.load("Plain\n\n> quote\n")
        release.signal()
        waitUntil { controller.tintApplyCount == 2 }
        idle(0.5)
        XCTAssertEqual(controller.tintApplyCount, 2, "A's result was dropped")
        XCTAssertNil(tint(controller, at: 0).color)
        assertSameColor(tint(controller, at: 7).color, light.blockquoteColor, appearance: nil)
    }

    func testTintIsSkippedAboveTheSizeLimit() {
        let line = String(repeating: "x", count: 99) + "\n"
        let big = "# Heading\n" + String(repeating: line, count: SourceEditorController.tintCharacterLimit / 100 + 1)
        let (controller, _, _) = makeEditor("# Small\n")
        waitUntil { controller.tintApplyCount == 1 }
        controller.load(big)
        idle(0.5)
        XCTAssertEqual(controller.tintApplyCount, 1)
        XCTAssertNil(tint(controller, at: 0).color)
    }

    /// A buffer of exactly `length` UTF-16 units that starts with a heading.
    private func headingText(length: Int) -> String {
        let head = "# Heading\n"
        let body = length - (head as NSString).length
        let line = String(repeating: "x", count: 99) + "\n"
        let text = head + String(repeating: line, count: body / 100) + String(repeating: "x", count: body % 100)
        precondition((text as NSString).length == length)
        return text
    }

    func testSizeLimitBoundary() {
        let limit = SourceEditorController.tintCharacterLimit
        let (controller, _, _) = makeEditor("")
        waitUntil { controller.tintApplyCount == 1 }
        controller.load(headingText(length: limit))
        waitUntil { controller.tintApplyCount == 2 }
        assertSameColor(tint(controller, at: 0).color, light.keywordColor, appearance: nil)
        controller.load(headingText(length: limit + 1))
        idle(0.5)
        XCTAssertEqual(controller.tintApplyCount, 2, "one unit over the limit is not parsed")
        XCTAssertNil(tint(controller, at: 0).color)
    }

    func testGrowingPastTheLimitClearsTheTintAndShrinkingRestoresIt() {
        let limit = SourceEditorController.tintCharacterLimit
        let (controller, _, _) = makeEditor(headingText(length: limit))
        waitUntil { controller.tintApplyCount == 1 }
        XCTAssertNotNil(tint(controller, at: 0).color)
        controller.textView.setSelectedRange(NSRange(location: limit, length: 0))
        type(controller, "y")
        waitUntil { tint(controller, at: 0).color == nil }
        command(controller, #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(controller.textView.textStorage!.length, limit)
        waitUntil { tint(controller, at: 0).color != nil }
        assertSameColor(tint(controller, at: 0).color, light.keywordColor, appearance: nil)
    }

    func testTextTypedOnANewLineAfterATintedLineIsNotTinted() {
        let (controller, _, _) = makeEditor("# Title\n\n```\ncode\n```")
        waitUntil { controller.tintApplyCount == 1 }
        // Return at the end of the heading, then a paragraph without a pause.
        controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        command(controller, #selector(NSResponder.insertNewline(_:)))
        type(controller, "Para")
        XCTAssertEqual(controller.text, "# Title\nPara\n\n```\ncode\n```")
        XCTAssertEqual(controller.tintApplyCount, 1, "no re-tint yet")
        XCTAssertNil(tint(controller, at: 8).color)
        XCTAssertNil(tint(controller, at: 11).color)
        assertSameColor(tint(controller, at: 0).color, light.keywordColor, appearance: nil)
        // Typing inside a tinted line keeps the colour of the rest of it (the
        // typed character itself waits for the re-tint).
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(controller, "x")
        assertSameColor(tint(controller, at: 2).color, light.keywordColor, appearance: nil)
        assertSameColor(tint(controller, at: 4).color, light.keywordColor, appearance: nil)
        assertSameColor(tint(controller, at: 7).color, light.keywordColor, appearance: nil)
        // The same after a closing fence.
        let end = controller.textView.textStorage!.length
        controller.textView.setSelectedRange(NSRange(location: end, length: 0))
        command(controller, #selector(NSResponder.insertNewline(_:)))
        type(controller, "after")
        XCTAssertEqual(controller.tintApplyCount, 1, "no re-tint yet")
        XCTAssertNil(tint(controller, at: end + 1).color)
        XCTAssertNil(tint(controller, at: end + 5).color)
    }

    func testContinuousTypingIsReTintedAfterTheMaximumWait() {
        let (controller, _, _) = makeEditor("Body\n")
        waitUntil { controller.tintApplyCount == 1 }
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0))
        // Keystrokes closer together than the debounce, for longer than the
        // maximum wait: the debounce alone would never fire. The assertion is
        // that a parse STARTS while the typing continues. Whether its result
        // is still current when it lands depends on the machine (a keystroke
        // during the parse makes it stale, and there is one attempt per
        // maximum wait) — asserting "a tint was applied" failed on a loaded
        // CI runner.
        let parses = ParseCounter()
        controller.tintParseWillStart = { parses.increment() }
        let start = Date()
        while parses.value == 0, Date().timeIntervalSince(start) < SourceEditorController.tintMaximumWait + 8 {
            type(controller, "x")
            idle(SourceEditorController.tintDebounce / 4)
        }
        controller.tintParseWillStart = nil
        XCTAssertGreaterThan(parses.value, 0, "no parse started while typing continuously")
    }

    func testUndoAndRedoReTint() {
        let (controller, _, _) = makeEditor("Body\n")
        waitUntil { controller.tintApplyCount == 1 }
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type(controller, "# ")
        waitUntil { controller.tintApplyCount == 2 }
        assertSameColor(tint(controller, at: 0).color, light.keywordColor, appearance: nil)
        controller.undoManager.undo()
        XCTAssertEqual(controller.text, "Body\n")
        waitUntil { controller.tintApplyCount == 3 }
        XCTAssertNil(tint(controller, at: 0).color)
        controller.undoManager.redo()
        XCTAssertEqual(controller.text, "# Body\n")
        waitUntil { controller.tintApplyCount == 4 }
        assertSameColor(tint(controller, at: 0).color, light.keywordColor, appearance: nil)
    }
}


/// Counts tint parses from the tint queue (`tintParseWillStart` is `@Sendable`).
private final class ParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
