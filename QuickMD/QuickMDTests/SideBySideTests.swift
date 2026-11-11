import XCTest
import AppKit

/// Source Edit side by side (#55 and its follow-up): what the preview shows
/// (`SideBySidePreview`), when it re-parses (`PreviewRefreshScheduler`), how
/// wide the window must be (`SideBySideLayout`), the menu state, section copy
/// against the preview's headings, and the session hooks that feed the
/// preview — driven through a real `SourceEditSession` on temp files with an
/// offscreen editor, as in `SourceEditSessionTests`.
final class SideBySideTests: XCTestCase {

    // MARK: - SideBySidePreview: the rule

    func testNoPreviewUnlessSideBySideAndTheBufferIsNotRead() {
        var asked = false
        let text = SideBySidePreview.text(isShowing: false, buffer: { asked = true; return "b" }, rendered: "a")
        XCTAssertNil(text)
        XCTAssertFalse(asked, "reading the buffer copies it: only while side by side")
    }

    func testNoPreviewWhenTheBufferIsTheSavedText() {
        XCTAssertNil(SideBySidePreview.text(isShowing: true, buffer: { "same\n" }, rendered: "same\n"))
        XCTAssertEqual(SideBySidePreview.text(isShowing: true, buffer: { "mine\n" }, rendered: "disk\n"), "mine\n")
    }

    func testANormalizationOnlyDifferenceIsStillPreviewed() {
        // "é" decomposed in the buffer, precomposed on disk: `==` calls them
        // equal, the session calls the buffer dirty — and so does the preview.
        let nfd = "caf\u{0065}\u{0301}\n", nfc = "caf\u{00E9}\n"
        XCTAssertEqual(nfd, nfc, "Swift's canonical equivalence")
        XCTAssertEqual(SideBySidePreview.text(isShowing: true, buffer: { nfd }, rendered: nfc)?.utf16.count,
                       nfd.utf16.count)
    }

    func testRefreshReportsOnlyRealChanges() {
        var preview = SideBySidePreview()
        XCTAssertFalse(preview.refresh(isShowing: true, buffer: { "a" }, rendered: "a"))
        XCTAssertTrue(preview.refresh(isShowing: true, buffer: { "b" }, rendered: "a"))
        XCTAssertEqual(preview.text, "b")
        XCTAssertFalse(preview.refresh(isShowing: true, buffer: { "b" }, rendered: "a"))
        XCTAssertTrue(preview.refresh(isShowing: true, buffer: { "c" }, rendered: "a"))
        XCTAssertTrue(preview.refresh(isShowing: false, buffer: { "c" }, rendered: "a"))
        XCTAssertNil(preview.text)
    }

    func testTheListIgnoresAPreviewOnceSideBySideIsGone() {
        XCTAssertEqual(SideBySidePreview.renderedSource(isShowing: true, preview: "buffer", current: "disk"), "buffer")
        XCTAssertEqual(SideBySidePreview.renderedSource(isShowing: true, preview: nil, current: "disk"), "disk")
        XCTAssertEqual(SideBySidePreview.renderedSource(isShowing: false, preview: "buffer", current: "disk"), "disk",
                       "a leftover preview never reaches the list after leaving")
    }

    // MARK: - Section copy (review finding 2)

    private func headings(of markdown: String) -> [ToCEntry] {
        ToCEntry.entries(of: MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown))
    }

    func testSectionCopySlicesTheTextTheHeadingsCameFrom() throws {
        let disk = "# A\na\n\n## B\nb\n\n## C\nc\n"
        // Ten lines inserted above `## B`, not saved: the preview's headings
        // come from this buffer.
        let buffer = "# A\na\n" + String(repeating: "new\n", count: 10) + "\n## B\nb\n\n## C\nc\n"
        let toc = headings(of: buffer)
        let entry = try XCTUnwrap(toc.first { $0.title == "B" })
        let source = SideBySidePreview.sectionSource(isShowing: true, installed: buffer, current: disk)
        XCTAssertEqual(SectionExtractor.extractSection(from: source, entry: entry, headings: toc), "## B\nb")
        // What the merged PR did: the disk text at the buffer's line numbers.
        XCTAssertNotEqual(SectionExtractor.extractSection(from: disk, entry: entry, headings: toc), "## B\nb")
    }

    func testSectionCopyWithoutAnInstalledParseUsesTheCurrentText() {
        XCTAssertEqual(SideBySidePreview.sectionSource(isShowing: true, installed: nil, current: "disk"), "disk")
    }

    func testSectionCopyOutsideSideBySideIsTheSavedTextAsBefore() {
        // Reading and the editor alone: unchanged from 1.14.4.
        XCTAssertEqual(SideBySidePreview.sectionSource(isShowing: false, installed: "older parse", current: "disk"),
                       "disk")
    }

    // MARK: - Menu state

    func testSideBySideTitle() {
        func state(_ editing: Bool, _ sideBySide: Bool) -> SourceEditMenuState {
            SourceEditMenuState(isEditing: editing, isDirty: false, isSideBySide: sideBySide)
        }
        XCTAssertEqual(SourceEditMenuState.sideBySideTitle(for: nil), "Edit Side by Side")
        XCTAssertEqual(SourceEditMenuState.sideBySideTitle(for: state(false, false)), "Edit Side by Side")
        XCTAssertEqual(SourceEditMenuState.sideBySideTitle(for: state(false, true)), "Edit Side by Side",
                       "a flag left over from the last session does not name the reading state")
        XCTAssertEqual(SourceEditMenuState.sideBySideTitle(for: state(true, false)), "Edit Side by Side")
        XCTAssertEqual(SourceEditMenuState.sideBySideTitle(for: state(true, true)), "Editor Only")
    }

    func testSavedTextCommandsStayOffWhileEditingSideBySideToo() {
        XCTAssertTrue(SourceEditMenuState(isEditing: false, isDirty: false).allowsSavedTextCommands)
        XCTAssertFalse(SourceEditMenuState(isEditing: true, isDirty: false).allowsSavedTextCommands)
        XCTAssertFalse(SourceEditMenuState(isEditing: true, isDirty: true, isSideBySide: true).allowsSavedTextCommands,
                       "Print / Export / Copy Markdown would act on the saved text while the preview shows the buffer")
    }

    // MARK: - Window width

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testWideEnoughFits() {
        XCTAssertEqual(SideBySideLayout.fit(windowFrame: NSRect(x: 10, y: 10, width: 800, height: 600),
                                            contentWidth: 800, requiredContentWidth: 700,
                                            screenFrame: screen, isFullScreen: false), .fits)
    }

    func testNarrowWindowGrowsToTheRightKeepingItsTop() {
        let fit = SideBySideLayout.fit(windowFrame: NSRect(x: 100, y: 200, width: 500, height: 600),
                                       contentWidth: 500, requiredContentWidth: SideBySideLayout.requiredContentWidth(sidebars: 0),
                                       screenFrame: screen, isFullScreen: false)
        XCTAssertEqual(fit, .grow(to: NSRect(x: 100, y: 200, width: 700, height: 600)))
    }

    func testGrowingAtTheScreenEdgeMovesLeftOnlyAsFarAsNeeded() {
        let fit = SideBySideLayout.fit(windowFrame: NSRect(x: 1000, y: 0, width: 400, height: 600),
                                       contentWidth: 400, requiredContentWidth: 921,
                                       screenFrame: screen, isFullScreen: false)
        XCTAssertEqual(fit, .grow(to: NSRect(x: 519, y: 0, width: 921, height: 600)))
    }

    func testSidebarsAddToTheRequiredWidth() {
        XCTAssertEqual(SideBySideLayout.requiredContentWidth(sidebars: 221), 921)
        XCTAssertEqual(SideBySideLayout.requiredContentWidth(sidebars: -5), SideBySideLayout.minimumDocumentWidth)
    }

    func testAScreenTooSmallRefuses() {
        XCTAssertEqual(SideBySideLayout.fit(windowFrame: NSRect(x: 0, y: 0, width: 500, height: 600),
                                            contentWidth: 500, requiredContentWidth: 1500,
                                            screenFrame: screen, isFullScreen: false), .tooNarrow)
    }

    func testFullScreenCannotGrow() {
        XCTAssertEqual(SideBySideLayout.fit(windowFrame: NSRect(x: 0, y: 0, width: 600, height: 600),
                                            contentWidth: 600, requiredContentWidth: 700,
                                            screenFrame: screen, isFullScreen: true), .tooNarrow)
    }

    // MARK: - PreviewRefreshScheduler (fake clock)

    /// A scheduler on a fake clock: timers are recorded and fired by `advance`.
    private final class Clock {
        var time: TimeInterval = 100
        var timers: [(deadline: TimeInterval, work: DispatchWorkItem)] = []
        var published = 0
        /// Parses running at once, as the scheduler lets them start.
        var running = 0
        var maximumRunning = 0

        func make() -> PreviewRefreshScheduler {
            let scheduler = PreviewRefreshScheduler()
            scheduler.now = { [unowned self] in self.time }
            scheduler.schedule = { [unowned self] delay, work in self.timers.append((self.time + delay, work)) }
            scheduler.publish = { [unowned self] in self.published += 1 }
            return scheduler
        }

        /// Moves to `time`, firing every live timer due on the way, in order.
        func advance(to target: TimeInterval) {
            while let index = timers.indices
                    .filter({ !timers[$0].work.isCancelled && timers[$0].deadline <= target })
                    .min(by: { timers[$0].deadline < timers[$1].deadline }) {
                let timer = timers.remove(at: index)
                time = max(time, timer.deadline)
                timer.work.perform()
            }
            time = target
        }

        var liveTimers: Int { timers.filter { !$0.work.isCancelled }.count }
    }

    func testKeystrokesCoalesceIntoOnePublish() {
        let clock = Clock()
        let scheduler = clock.make()
        for step in 0..<5 {
            clock.advance(to: 100 + Double(step) * 0.1)
            scheduler.bufferChanged(length: 100)
        }
        XCTAssertEqual(clock.liveTimers, 1, "one timer, re-armed per keystroke")
        clock.advance(to: 100.69)
        XCTAssertEqual(clock.published, 0, "0.3 s after the LAST keystroke, not before")
        clock.advance(to: 100.71)
        XCTAssertEqual(clock.published, 1)
        clock.advance(to: 110)
        XCTAssertEqual(clock.published, 1)
    }

    func testCancelStopsAPendingPublish() {
        let clock = Clock()
        let scheduler = clock.make()
        scheduler.bufferChanged(length: 100)
        scheduler.cancel()
        clock.advance(to: 110)
        XCTAssertEqual(clock.published, 0)
    }

    func testContinuousTypingPublishesAfterTheMaximumWait() {
        let clock = Clock()
        let scheduler = clock.make()
        var publishedAt: [TimeInterval] = []
        scheduler.publish = { publishedAt.append(clock.time) }
        // A keystroke every 0.2 s for 2.5 s: never a 0.3 s pause.
        for step in 0...12 {
            clock.advance(to: 100 + Double(step) * 0.2)
            scheduler.bufferChanged(length: 100)
        }
        XCTAssertEqual(publishedAt.first.map { ($0 - 100).rounded() }, 1, "the first edit waited 1 s, not forever")
        XCTAssertGreaterThanOrEqual(publishedAt.count, 2)
    }

    func testNothingIsPublishedWhileAParseRunsAndTheLatestGoesOutAfterIt() {
        let clock = Clock()
        let scheduler = clock.make()
        scheduler.publish = {
            clock.published += 1
            // The view publishes → its parse task starts.
            clock.running += 1
            clock.maximumRunning = max(clock.maximumRunning, clock.running)
            scheduler.parseStarted()
        }
        func finishParse(after duration: TimeInterval) {
            clock.advance(to: clock.time + duration)
            clock.running -= 1
            scheduler.parseFinished(duration: duration)
        }
        scheduler.bufferChanged(length: 100)
        clock.advance(to: 100.3)
        XCTAssertEqual(clock.published, 1)
        // Typing on while that parse runs for 2 s: debounces and maximum
        // waits come and go, nothing is published.
        for step in 1...9 {
            clock.advance(to: 100.3 + Double(step) * 0.2)
            scheduler.bufferChanged(length: 100)
        }
        clock.advance(to: 102.29)
        XCTAssertEqual(clock.published, 1, "single flight")
        finishParse(after: 0.01)
        // Overdue: a zero-delay timer, i.e. the next turn of the main queue.
        clock.advance(to: clock.time)
        XCTAssertEqual(clock.published, 2, "the pending edits go out as soon as it landed")
        XCTAssertEqual(clock.maximumRunning, 1)
    }

    func testAFlushDuringAParseWaitsForIt() {
        let clock = Clock()
        let scheduler = clock.make()
        scheduler.parseStarted()
        scheduler.flush()
        XCTAssertEqual(clock.published, 0)
        scheduler.parseFinished(duration: 0.5)
        XCTAssertEqual(clock.published, 1, "a replacement is never dropped, only delayed")
        scheduler.flush()
        XCTAssertEqual(clock.published, 2, "idle: at once")
    }

    func testTwoOverlappingParsesBothHaveToFinish() {
        // SwiftUI starts the new parse task before the cancelled one's
        // detached parse has finished.
        let clock = Clock()
        let scheduler = clock.make()
        scheduler.parseStarted()
        scheduler.parseStarted()
        scheduler.flush()
        scheduler.parseFinished(duration: 0.1)
        XCTAssertEqual(clock.published, 0)
        scheduler.parseFinished(duration: 0.1)
        XCTAssertEqual(clock.published, 1)
    }

    func testABigDocumentWaitsAsLongAsItsLastParse() {
        let clock = Clock()
        let scheduler = clock.make()
        scheduler.parseStarted()
        scheduler.parseFinished(duration: 1.4)
        let large = PreviewRefreshScheduler.largeDocumentLength + 1
        scheduler.bufferChanged(length: large)
        clock.advance(to: 100 + 1.39)
        XCTAssertEqual(clock.published, 0, "the debounce is the last parse's duration")
        clock.advance(to: 100 + 1.41)
        XCTAssertEqual(clock.published, 1)

        // A small document keeps 0.3 s whatever the last parse took.
        let small = clock.make()
        small.parseStarted()
        small.parseFinished(duration: 1.4)
        let before = clock.published
        small.bufferChanged(length: 100)
        clock.advance(to: clock.time + 0.31)
        XCTAssertEqual(clock.published, before + 1)
    }

    // MARK: - The preview fed by a real session (review finding 1)

    private var directory: URL!
    private var windows: [NSWindow] = []
    private var savedHasAttachedSheet: ((NSWindow) -> Bool)!
    private var savedDisable: ((String) -> Void)!
    private var savedEnable: ((String) -> Void)!
    private var savedBeep: (() -> Void)!
    private var beeps = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SideBySideTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedHasAttachedSheet = EditCloseGuard.hasAttachedSheet
        savedDisable = EditCloseGuard.disableAutomaticTermination
        savedEnable = EditCloseGuard.enableAutomaticTermination
        EditCloseGuard.hasAttachedSheet = { _ in false }
        EditCloseGuard.disableAutomaticTermination = { _ in }
        EditCloseGuard.enableAutomaticTermination = { _ in }
        savedBeep = SourceEditSession.beep
        beeps = 0
        SourceEditSession.beep = { [weak self] in self?.beeps += 1 }
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        EditCloseGuard.hasAttachedSheet = savedHasAttachedSheet
        EditCloseGuard.disableAutomaticTermination = savedDisable
        EditCloseGuard.enableAutomaticTermination = savedEnable
        SourceEditSession.beep = savedBeep
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// What `MarkdownView` does with the session's hooks, minus SwiftUI: the
    /// rendered text follows `commitText`; every hook re-applies the ONE rule
    /// (the scheduler's eventual publish, at once here).
    private final class PreviewHost {
        var rendered = ""
        var isSideBySide = false
        var preview = SideBySidePreview()
        var changed = 0
        var replaced = 0
        weak var session: SourceEditSession?

        var isShowing: Bool { (session?.isActive ?? false) && isSideBySide }
        /// What the list renders.
        var listText: String {
            SideBySidePreview.renderedSource(isShowing: isShowing, preview: preview.text, current: rendered)
        }

        func refresh() {
            guard let session else { return }
            preview.refresh(isShowing: isShowing, buffer: { session.editor.text }, rendered: rendered)
        }
    }

    /// Unsaved-changes answers in order; every other prompt cancels.
    private var unsavedAnswers: [UnsavedChangesAlert.Choice] = []
    private var heldUnsaved: ((UnsavedChangesAlert.Choice) -> Void)?
    private var holdUnsaved = false

    private func prompts() -> SourceEditSession.Prompts {
        SourceEditSession.Prompts(
            unsavedChanges: { [unowned self] _, _, completion in
                if holdUnsaved { heldUnsaved = completion; return }
                completion(unsavedAnswers.isEmpty ? .cancel : unsavedAnswers.removeFirst())
            },
            unsavedChangesModal: { _ in .discard },
            saveConflict: { _, _, completion in completion(.cancel) },
            encodingFallback: { _, _, _, completion in completion(false) },
            saveFailed: { _, _, completion in completion(.ok) },
            copyDestination: { _, _, _, completion in completion(nil) },
            copyDestinationModal: { _, _ in nil }
        )
    }

    private func fixture(_ text: String) throws -> URL {
        let url = directory.appendingPathComponent("doc.md")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// An entered session (editor offscreen) wired to `host` like the view.
    private func entered(_ url: URL, host: PreviewHost) throws -> (SourceEditSession, NSWindow) {
        let session = SourceEditSession()
        session.editor.undoManager.groupsByEvent = false
        let style = SourceEditorController.Style(theme: MarkdownTheme.cached(for: .light),
                                                 fontScale: 1, isReadingLayout: false)
        let scrollView = session.editor.makeScrollView(style: style)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(scrollView)
        windows.append(window)
        host.session = session
        host.rendered = try String(contentsOf: url, encoding: .utf8)
        session.environment = SourceEditSession.Environment(
            documentURL: url,
            window: { [weak window] in window },
            renderedText: { [weak host] in host?.rendered },
            commitText: { [weak host] text in
                host?.rendered = text
                host?.refresh()
            },
            toast: { _ in },
            bufferChanged: { [weak host] in
                host?.changed += 1
                host?.refresh()
            },
            bufferReplaced: { [weak host] in
                host?.replaced += 1
                host?.refresh()
            }
        )
        session.prompts = prompts()
        XCTAssertNil(session.enter(atLine: 0))
        return (session, window)
    }

    private func type(_ session: SourceEditSession, _ string: String, at offset: Int) {
        let textView = session.editor.textView
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        session.editor.undoManager.beginUndoGrouping()
        textView.insertText(string, replacementRange: textView.selectedRange())
        session.editor.undoManager.endUndoGrouping()
    }

    private func turnOnSideBySide(_ host: PreviewHost) {
        host.isSideBySide = true
        host.refresh()
    }

    /// Review finding 1, first sequence: type B, ⌘S, another app writes C
    /// while the buffer is clean — the editor shows C, and so must the list.
    func testSaveThenACleanExternalChangeKeepsThePreviewCurrent() throws {
        let url = try fixture("A\n")
        let host = PreviewHost()
        let (session, _) = try entered(url, host: host)
        turnOnSideBySide(host)
        type(session, "B", at: 0)
        XCTAssertEqual(host.listText, "BA\n")
        var saved: Bool?
        session.save { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertNil(host.preview.text, "after Save the buffer IS the saved text")
        XCTAssertEqual(host.listText, "BA\n")

        try Data("C\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertEqual(session.editor.text, "C\n", "clean buffer: the session reloaded it")
        XCTAssertEqual(host.listText, "C\n", "the preview follows the reload")
        XCTAssertNil(host.preview.text)
    }

    /// The same with the preview still SHOWING the typed text when the save
    /// lands — a commit alone must not leave it behind.
    func testAReloadNeverLeavesTheBufferItReplacedOnTheList() throws {
        let url = try fixture("one\n")
        let host = PreviewHost()
        let (session, _) = try entered(url, host: host)
        turnOnSideBySide(host)
        type(session, "x", at: 0)
        session.editor.undoManager.undo()
        XCTAssertNil(host.preview.text)
        // A clean buffer, an external rewrite.
        try Data("two\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertEqual(host.listText, session.editor.text)
    }

    /// Review finding 1, second sequence: quit with unsaved text, Don't Save
    /// reverts the buffer, another tab cancels the quit — this window stays,
    /// the editor shows the saved text, and so must the list.
    func testDontSaveOnQuitRevertsThePreviewToo() throws {
        let url = try fixture("saved\n")
        let host = PreviewHost()
        let (session, window) = try entered(url, host: host)
        turnOnSideBySide(host)
        type(session, "discarded ", at: 0)
        XCTAssertEqual(host.listText, "discarded saved\n")
        unsavedAnswers = [.discard]
        let handlers = try XCTUnwrap(EditCloseGuard.guardFor(window)).handlers
        var confirmed: Bool?
        handlers.confirm(window) { confirmed = $0 }
        XCTAssertEqual(confirmed, true)
        // The quit was cancelled elsewhere: still editing, side by side.
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.editor.text, "saved\n")
        XCTAssertEqual(host.listText, "saved\n", "the discarded edits are gone from the preview too")
        XCTAssertEqual(bytes(url), Data("saved\n".utf8))
    }

    func testTheModalDontSaveRevertsThePreviewToo() throws {
        let url = try fixture("saved\n")
        let host = PreviewHost()
        let (session, window) = try entered(url, host: host)
        turnOnSideBySide(host)
        type(session, "gone ", at: 0)
        try XCTUnwrap(EditCloseGuard.guardFor(window)).handlers.resolveSynchronously(window)
        XCTAssertEqual(host.listText, "saved\n")
    }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: - Session hooks (spec 8)

    func testHooksForTypingAndTheSessionsOwnReplacements() throws {
        let url = try fixture("base\n")
        let host = PreviewHost()
        let (session, _) = try entered(url, host: host)
        XCTAssertEqual(host.replaced, 1, "entering loads the buffer")
        XCTAssertEqual(host.changed, 0, "a load is not an edit")

        type(session, "x", at: 0)
        XCTAssertEqual(host.changed, 1)
        session.discardChanges()  // replaceAll
        XCTAssertEqual(host.changed, 2, "Discard Changes")
        XCTAssertEqual(session.editor.text, "base\n")

        type(session, "mine ", at: 0)
        try Data("disk\n".utf8).write(to: url)
        session.diskDidChange()  // dirty: the banner, the buffer stays
        XCTAssertEqual(host.replaced, 1)
        let before = host.changed
        session.loadDiskVersion()  // replaceAll
        XCTAssertEqual(host.changed, before + 1, "Load Disk Version")
        XCTAssertEqual(session.editor.text, "disk\n")

        try Data("again\n".utf8).write(to: url)
        session.diskDidChange()  // clean: reload
        XCTAssertEqual(host.replaced, 2, "a clean external change reloads")
        XCTAssertEqual(session.editor.text, "again\n")
    }

    func testTheHooksNeitherDirtyNorWrite() throws {
        let url = try fixture("base\n")
        let host = PreviewHost()
        let (session, _) = try entered(url, host: host)
        turnOnSideBySide(host)
        // A preview refresh on every hook, and still: clean, nothing written.
        session.environment.bufferChanged()
        session.environment.bufferReplaced()
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(bytes(url), Data("base\n".utf8))
        type(session, "x", at: 0)
        session.editor.undoManager.undo()
        XCTAssertFalse(session.checkDirty())
        XCTAssertEqual(bytes(url), Data("base\n".utf8))
    }

    // MARK: - Guards

    func testTheLayoutDoesNotChangeWhileAPromptIsUp() throws {
        let url = try fixture("abc\n")
        let host = PreviewHost()
        let (session, _) = try entered(url, host: host)
        XCTAssertTrue(session.mayChangeLayout())
        XCTAssertEqual(beeps, 0)
        type(session, "x", at: 0)
        holdUnsaved = true
        session.requestLeave()
        XCTAssertTrue(session.isPrompting)
        XCTAssertFalse(session.mayChangeLayout())
        XCTAssertEqual(beeps, 1, "beeps like the other menu actions")
        try XCTUnwrap(heldUnsaved)(.cancel)
        XCTAssertTrue(session.mayChangeLayout())
    }

    func testNoLayoutChangeWhenNotEditing() {
        XCTAssertFalse(SourceEditSession().mayChangeLayout())
    }

    // MARK: - Giving the grown width back (second review, should-fix 1)

    private let before = NSRect(x: 100, y: 200, width: 800, height: 600)
    private let grown = NSRect(x: 100, y: 200, width: 1150, height: 600)

    func testUntouchedGrownWindowGetsItsFrameBack() {
        let growth = SideBySideGrowth(original: before, grown: grown)
        XCTAssertEqual(growth.frameToRestore(current: grown), before)
        XCTAssertEqual(growth.frameToRestore(current: grown.insetBy(dx: 0.2, dy: 0)), before,
                       "AppKit's sub-point rounding is not a user resize")
    }

    func testUserResizedOrMovedWindowIsLeftAlone() {
        let growth = SideBySideGrowth(original: before, grown: grown)
        var resized = grown; resized.size.width = 1000
        var moved = grown; moved.origin.x += 40
        XCTAssertNil(growth.frameToRestore(current: resized))
        XCTAssertNil(growth.frameToRestore(current: moved))
        XCTAssertEqual(SideBySideGrowth.sizeToPersist(current: resized, growth: growth), resized.size,
                       "the user's own size is remembered")
    }

    func testAGrownWindowRemembersItsSizeFromBefore() {
        let growth = SideBySideGrowth(original: before, grown: grown)
        XCTAssertEqual(SideBySideGrowth.sizeToPersist(current: grown, growth: growth), before.size)
        XCTAssertEqual(SideBySideGrowth.sizeToPersist(current: grown, growth: nil), grown.size)
    }

    func testGrowingAgainKeepsTheFirstOriginal() {
        let again = SideBySideGrowth(original: before, grown: grown).regrown(to: grown.insetBy(dx: -50, dy: 0))
        XCTAssertEqual(again.original, before)
        XCTAssertEqual(again.frameToRestore(current: grown.insetBy(dx: -50, dy: 0)), before)
    }

    /// Closed while grown (`willClose` → `persist`): the size from before.
    func testWindowSizeMemoryNeverRemembersTheGrownSize() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let growth = SideBySideGrowth(original: NSRect(x: 0, y: 0, width: 800, height: window.frame.height),
                                      grown: window.frame)
        WindowSizeMemory.setSideBySideGrowth(growth, for: [window])
        XCTAssertEqual(WindowSizeMemory.sizeToRemember(window)?.width, 800)
        WindowSizeMemory.setSideBySideGrowth(nil, for: [window])
        XCTAssertEqual(WindowSizeMemory.sizeToRemember(window)?.width, window.frame.width)
    }

    // MARK: - Minimum width (second review, finding 4)

    func testTheMinimumNeverExceedsWhatTheWindowHas() {
        // Room (or grown): what side by side needs.
        XCTAssertEqual(SideBySideLayout.minimumContentWidth(required: 921, contentWidth: 1000), 921)
        // A sidebar shown in full screen / on a small screen: no more than
        // the window has — the halves get narrower, nothing is clipped.
        XCTAssertEqual(SideBySideLayout.minimumContentWidth(required: 1427, contentWidth: 1200), 1200)
        XCTAssertEqual(SideBySideLayout.minimumContentWidth(required: 700, contentWidth: 300),
                       SideBySideLayout.standardMinimumWidth)
    }

    // MARK: - No left-over preview, one parse (second review, should-fix 3)

    /// MarkdownView's preview plumbing without SwiftUI: the list's text is
    /// `renderedSource`; when it changes, the running "task" is cancelled
    /// and a new one waits for the scheduler's idle gate, as the view's
    /// `.task(id:)` does. Parses finish when the test says so.
    private final class ListSim {
        let clock = Clock()
        let scheduler: PreviewRefreshScheduler
        var disk = "disk\n"
        var buffer = "disk\n"
        var isActive = true
        var isSideBySide = true
        var preview = SideBySidePreview()
        private var taskText: String?
        private var taskToken = 0
        /// Detached parses running: (token, text).
        var running: [(token: Int, text: String, isPreview: Bool)] = []
        var maximumRunning = 0
        /// Every text a parse INSTALLED, in order.
        var installed: [String] = []

        init() {
            scheduler = clock.make()
            scheduler.publish = { [unowned self] in
                self.preview.refresh(isShowing: self.isShowing, buffer: { self.buffer }, rendered: self.disk)
            }
        }

        var isShowing: Bool { isActive && isSideBySide }
        var listText: String {
            SideBySidePreview.renderedSource(isShowing: isShowing, preview: preview.text, current: disk)
        }

        /// The body re-evaluates: a new list text restarts the task.
        func update() {
            let text = listText
            guard text != taskText else { return }
            taskText = text
            taskToken += 1
            let token = taskToken
            let isEditing = isActive
            let start = { [unowned self] in
                guard token == self.taskToken else { return }  // superseded: cancelled
                let isPreview = self.isShowing && self.preview.text != nil
                self.scheduler.parseStarted(isPreview: isPreview)
                self.running.append((token, text, isPreview))
                self.maximumRunning = max(self.maximumRunning, self.running.count)
            }
            // As the view: wait only when `mustWait`, else start at once.
            if scheduler.mustWait(isEditing: isEditing) {
                scheduler.whenIdle(isEditing: isEditing, start)
            } else {
                start()
            }
        }

        func finishParse() {
            let parse = running.removeFirst()
            if parse.token == taskToken { installed.append(parse.text) }
            scheduler.parseFinished(duration: 1, isPreview: parse.isPreview)
            update()
        }

        func type(_ text: String) {
            buffer = text
            if isShowing { scheduler.bufferChanged(length: text.utf16.count) }
            clock.advance(to: clock.time + 2)
            update()
        }
    }

    func testTogglingOffAndOnDuringAParseNeverBringsTheOldTextBack() {
        let sim = ListSim()
        sim.update()
        sim.finishParse()                        // the disk
        sim.type("A\n")                          // published → parse of A starts
        XCTAssertEqual(sim.running.map(\.text), ["A\n"])
        // ⌥⇧⌘E: editor only — what `toggleSideBySide` does.
        sim.isSideBySide = false
        sim.scheduler.hide()
        sim.update()
        XCTAssertNil(sim.preview.text, "cleared at once, not after the parse")
        sim.type("B\n")
        // ⌥⇧⌘E again while A is still parsing.
        sim.isSideBySide = true
        sim.scheduler.flush()
        sim.update()
        XCTAssertNotEqual(sim.listText, "A\n", "the left-over text never returns")
        while !sim.running.isEmpty { sim.finishParse() }
        XCTAssertEqual(sim.listText, "B\n")
        XCTAssertEqual(sim.installed.last, "B\n")
        XCTAssertFalse(sim.installed.dropFirst().contains("A\n"), "a parse started for older text never lands")
        XCTAssertEqual(sim.maximumRunning, 1, "never two detached parses")
    }

    func testDontSaveThenReenteringDuringAParseShowsTheDisk() {
        let sim = ListSim()
        sim.update()
        sim.finishParse()
        sim.type("discarded\n")
        XCTAssertEqual(sim.running.map(\.text), ["discarded\n"])
        // Esc → Don't Save: the session leaves, the buffer is gone — what
        // `didLeaveSourceEdit` does.
        sim.isActive = false
        sim.buffer = sim.disk
        sim.scheduler.hide()
        sim.update()
        XCTAssertNil(sim.preview.text)
        // ⌥⇧⌘E while the discarded text is still parsing: the buffer is
        // loaded from disk (`bufferReplaced` → flush).
        sim.isActive = true
        sim.scheduler.flush()
        sim.update()
        XCTAssertEqual(sim.listText, "disk\n")
        while !sim.running.isEmpty { sim.finishParse() }
        XCTAssertEqual(sim.listText, "disk\n")
        XCTAssertEqual(sim.installed.last, "disk\n")
        XCTAssertFalse(sim.installed.contains("discarded\n"))
        XCTAssertEqual(sim.maximumRunning, 1)
    }

    /// Not editing: scheduling exactly as on main — a superseding parse
    /// (zoom, theme, reload, an external change) starts AT ONCE while the
    /// previous one still runs; the superseded one never lands.
    func testNotEditingASupersedingParseStartsImmediately() {
        let sim = ListSim()
        sim.isActive = false
        sim.update()
        XCTAssertEqual(sim.running.map(\.text), ["disk\n"])
        sim.disk = "changed on disk\n"
        sim.update()
        XCTAssertEqual(sim.running.map(\.text), ["disk\n", "changed on disk\n"],
                       "started immediately, next to the running one")
        XCTAssertFalse(sim.scheduler.mustWait(isEditing: false))
        sim.finishParse()
        sim.finishParse()
        XCTAssertEqual(sim.installed, ["changed on disk\n"], "the superseded parse is dropped")
    }

    func testIdleWaitersRunAfterTheLastParseAndRecheck() {
        let clock = Clock()
        let scheduler = clock.make()
        var ran: [String] = []
        scheduler.whenIdle { ran.append("now") }
        XCTAssertEqual(ran, ["now"])
        scheduler.parseStarted()
        scheduler.whenIdle {
            ran.append("first")
            scheduler.parseStarted()   // starts a parse itself
        }
        scheduler.whenIdle { ran.append("second") }
        scheduler.parseFinished(duration: 0.1)
        XCTAssertEqual(ran, ["now", "first"], "the second waits for the parse the first started")
        scheduler.parseFinished(duration: 0.1)
        XCTAssertEqual(ran, ["now", "first", "second"])
    }
}
