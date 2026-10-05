import XCTest
import AppKit
import Darwin

/// SourceEditSession (v1.12 S-D2, S-D3, S-D7–S-D11) driven headlessly: real
/// temp files, a real SourceEditorController hosted in a window that is never
/// ordered on screen, prompts injected as recorders with scripted answers (no
/// real sheet ever appears), the close guard's process hooks stubbed.
///
/// Undo: as in `SourceEditorControllerTests`, the editor's undo manager does
/// not group by event (a test has no events) and each simulated user action
/// is wrapped in its own group.
final class SourceEditSessionTests: XCTestCase {

    // MARK: - Fakes

    /// Scripted answers + a record of every question asked.
    private final class FakePrompts {
        var unsavedAnswers: [UnsavedChangesAlert.Choice] = []
        var unsavedCalls = 0
        /// Runs when the unsaved-changes prompt is asked, before it answers.
        var onUnsaved: (() -> Void)?
        /// `.discard` by default: tearDown closes windows, and a dirty session
        /// must not write into a fixture then.
        var modalAnswer: UnsavedChangesAlert.Choice = .discard
        var modalCalls = 0
        var conflictAnswer: SourceEditSession.ConflictChoice = .cancel
        var conflictCalls = 0
        var encodingAnswer = false
        var encodingNames: [String] = []
        var saveFailedAnswer: SourceEditSession.SaveFailedChoice = .ok
        var saveFailedErrors: [Error] = []
        var copyURL: URL?
        var copyCalls = 0
        var copyModalURLs: [URL?] = []
        var copyModalCalls = 0
        /// The unsaved-changes prompt stays "on screen": its completion is
        /// kept in `heldUnsaved` instead of being called.
        var holdUnsaved = false
        var heldUnsaved: ((UnsavedChangesAlert.Choice) -> Void)?
        /// Runs before each conflict answer, with the call's 1-based number
        /// (e.g. another app writes the file while the prompt is up).
        var beforeConflictAnswer: ((Int) -> Void)?
        /// Per-call conflict answers; `conflictAnswer` once they run out.
        var conflictAnswers: [SourceEditSession.ConflictChoice] = []
        /// The window every sheet-capable prompt was given, in call order.
        var windows: [NSWindow?] = []

        var prompts: SourceEditSession.Prompts {
            SourceEditSession.Prompts(
                unsavedChanges: { window, _, completion in
                    self.unsavedCalls += 1
                    self.windows.append(window)
                    self.onUnsaved?()
                    if self.holdUnsaved {
                        self.heldUnsaved = completion
                        return
                    }
                    completion(self.unsavedAnswers.isEmpty ? .cancel : self.unsavedAnswers.removeFirst())
                },
                unsavedChangesModal: { _ in
                    self.modalCalls += 1
                    return self.modalAnswer
                },
                saveConflict: { window, _, completion in
                    self.conflictCalls += 1
                    self.windows.append(window)
                    self.beforeConflictAnswer?(self.conflictCalls)
                    completion(self.conflictAnswers.isEmpty ? self.conflictAnswer : self.conflictAnswers.removeFirst())
                },
                encodingFallback: { window, _, name, completion in
                    self.encodingNames.append(name)
                    self.windows.append(window)
                    completion(self.encodingAnswer)
                },
                saveFailed: { window, error, completion in
                    self.saveFailedErrors.append(error)
                    self.windows.append(window)
                    completion(self.saveFailedAnswer)
                },
                copyDestination: { window, _, _, completion in
                    self.copyCalls += 1
                    self.windows.append(window)
                    completion(self.copyURL)
                },
                copyDestinationModal: { _, _ in
                    self.copyModalCalls += 1
                    return self.copyModalURLs.isEmpty ? nil : self.copyModalURLs.removeFirst()
                }
            )
        }
    }

    /// What the session tells the view.
    private final class ViewRecorder {
        var rendered: String?
        var commits: [String] = []
        var toasts: [String] = []
    }

    private var directory: URL!
    private var windows: [NSWindow] = []
    private var prompts = FakePrompts()
    private var view = ViewRecorder()
    private var savedHasAttachedSheet: ((NSWindow) -> Bool)!
    private var savedDisable: ((String) -> Void)!
    private var savedEnable: ((String) -> Void)!
    private var savedBeep: (() -> Void)!
    private var beeps = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceEditSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prompts = FakePrompts()
        view = ViewRecorder()
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
        if let enumerator = FileManager.default.enumerator(atPath: directory.path) {
            for case let path as String in enumerator {
                chmod(directory.appendingPathComponent(path).path, 0o644)
            }
        }
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func fixture(_ bytes: Data, name: String = "doc.md") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func fixture(_ text: String, name: String = "doc.md") throws -> URL {
        try fixture(Data(text.utf8), name: name)
    }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// A session whose editor is hosted in an offscreen window, wired to the
    /// recorders. The environment captures the window weakly, as the view's must.
    private func makeSession(_ url: URL?, rendered: String? = nil) -> (SourceEditSession, NSWindow) {
        let session = SourceEditSession()
        session.editor.undoManager.groupsByEvent = false
        let style = SourceEditorController.Style(theme: MarkdownTheme.cached(for: .light),
                                                 fontScale: 1, isReadingLayout: false)
        let scrollView = session.editor.makeScrollView(style: style)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView.frame = window.contentView!.bounds
        scrollView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(scrollView)
        window.contentView!.layoutSubtreeIfNeeded()
        windows.append(window)
        view.rendered = rendered
        let recorder = view
        session.environment = SourceEditSession.Environment(
            documentURL: url,
            window: { [weak window] in window },
            renderedText: { [weak recorder] in recorder?.rendered },
            commitText: { [weak recorder] text in
                recorder?.commits.append(text)
                recorder?.rendered = text
            },
            toast: { [weak recorder] in recorder?.toasts.append($0) }
        )
        session.prompts = prompts.prompts
        return (session, window)
    }

    private func entered(_ url: URL, line: Int? = nil, rendered: String? = nil,
                         file: StaticString = #filePath, lineNumber: UInt = #line) -> (SourceEditSession, NSWindow) {
        let (session, window) = makeSession(url, rendered: rendered)
        XCTAssertNil(session.enter(atLine: line), file: file, line: lineNumber)
        XCTAssertTrue(session.isActive, file: file, line: lineNumber)
        return (session, window)
    }

    private func userAction(_ session: SourceEditSession, _ body: () -> Void) {
        session.editor.undoManager.beginUndoGrouping()
        body()
        session.editor.undoManager.endUndoGrouping()
    }

    /// Types `string` at UTF-16 `offset` (default: where the caret is).
    private func type(_ session: SourceEditSession, _ string: String, at offset: Int? = nil) {
        let textView = session.editor.textView
        if let offset { textView.setSelectedRange(NSRange(location: offset, length: 0)) }
        userAction(session) { textView.insertText(string, replacementRange: textView.selectedRange()) }
    }

    private func delete(_ session: SourceEditSession, _ range: NSRange) {
        let textView = session.editor.textView
        userAction(session) { textView.insertText("", replacementRange: range) }
    }

    @discardableResult
    private func save(_ session: SourceEditSession) -> Bool? {
        var result: Bool?
        session.save { result = $0 }
        return result
    }

    private func guardHandlers(_ window: NSWindow, file: StaticString = #filePath,
                               line: UInt = #line) throws -> EditCloseGuard.Handlers {
        try XCTUnwrap(EditCloseGuard.guardFor(window), "the session installs the guard", file: file, line: line)
            .handlers
    }

    private func inode(_ url: URL) -> (ino: UInt64, mode: UInt16) {
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        return (UInt64(info.st_ino), UInt16(info.st_mode & 0o7777))
    }

    // MARK: - Entering: refusals (S-D3, S-D8)

    func testEnterWithoutAFileIsRefused() {
        let (session, _) = makeSession(nil)
        XCTAssertEqual(session.enter(atLine: 0), .noFile)
        XCTAssertFalse(session.isActive)
    }

    func testEnterMissingFileIsRefused() {
        let (session, _) = makeSession(directory.appendingPathComponent("gone.md"))
        let refusal = session.enter(atLine: 0)
        XCTAssertEqual(refusal, .missing(fileName: "gone.md"))
        XCTAssertEqual(refusal?.message, "“gone.md” no longer exists.")
        XCTAssertFalse(session.isActive)
    }

    func testEnterUnreadableIsRefused() throws {
        // A directory exists and is writable but cannot be read as data.
        let folder = directory.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let (session, _) = makeSession(folder)
        XCTAssertEqual(session.enter(atLine: 0), .unreadable(fileName: "folder.md"))
        XCTAssertFalse(session.isActive)
    }

    func testEnterReadOnlyFileIsRefused() throws {
        let url = try fixture("text\n", name: "x.md")
        chmod(url.path, 0o444)
        let (session, _) = makeSession(url)
        let refusal = session.enter(atLine: 0)
        XCTAssertEqual(refusal, .readOnly(fileName: "x.md"))
        XCTAssertEqual(refusal?.message, "“x.md” is read-only.")
        XCTAssertFalse(session.isActive)
    }

    func testEnterAboveTheSizeLimitIsRefusedAndAtTheLimitIsAllowed() throws {
        XCTAssertEqual(SourceEditSession.maximumEditableBytes, 2 * 1024 * 1024)
        let line = String(repeating: "a", count: 1023) + "\n"
        let atLimit = String(repeating: line, count: 2 * 1024)
        XCTAssertEqual(atLimit.utf8.count, SourceEditSession.maximumEditableBytes)
        let big = try fixture(atLimit + "b", name: "big.md")
        let (refused, _) = makeSession(big)
        XCTAssertEqual(refused.enter(atLine: 0), .tooLarge(fileName: "big.md"))
        XCTAssertFalse(refused.isActive)

        let ok = try fixture(atLimit, name: "ok.md")
        _ = entered(ok)
    }

    func testEnterFileTheDecoderAlteredIsRefused() throws {
        let candidates = [Data([0xFF, 0xFE, 0x61, 0x00, 0x62]),
                          Data([0xFE, 0xFF, 0x00, 0x61, 0x00]),
                          Data([0xFF, 0xFE, 0x00, 0xD8, 0x61, 0x00])]
        guard let unsafe = candidates.first(where: { data in
            guard let decoded = DocumentFileFormat.decode(data) else { return false }
            return !decoded.isLosslessDecode
        }) else {
            throw XCTSkip("this system's decoder round-trips every malformed fixture")
        }
        let url = try fixture(unsafe, name: "odd.md")
        let (session, _) = makeSession(url)
        let refusal = session.enter(atLine: 0)
        XCTAssertEqual(refusal, .unsafe(fileName: "odd.md"))
        XCTAssertEqual(refusal?.message,
                       "“odd.md” can’t be edited safely: saving would change parts of the file you did not edit.")
        XCTAssertFalse(session.isActive)
    }

    func testEnterTwiceIsRefused() throws {
        let (session, _) = entered(try fixture("a\n"))
        XCTAssertEqual(session.enter(atLine: 0), .alreadyEditing)
        XCTAssertTrue(session.isActive)
    }

    func testMixedLineEndingsMayBeEdited() throws {
        let (session, _) = entered(try fixture("a\r\nb\nc\r\n"))
        XCTAssertEqual(session.editor.text, "a\nb\nc\n")
    }

    // MARK: - Entering: success

    func testEnterReadsFreshDiskTextAndCommitsItWhenTheViewWasBehind() throws {
        let url = try fixture("new disk text\n")
        let (session, _) = entered(url, rendered: "stale rendered text\n")
        XCTAssertEqual(session.editor.text, "new disk text\n")
        XCTAssertEqual(session.savedText, "new disk text\n")
        XCTAssertEqual(session.baseBytes, bytes(url))
        XCTAssertEqual(view.commits, ["new disk text\n"])
        XCTAssertFalse(session.isDirty)
    }

    func testEnterDoesNotCommitWhenTheViewAlreadyShowsTheDiskText() throws {
        let url = try fixture("same\r\ntext\r\n")
        _ = entered(url, rendered: "same\ntext\n")
        XCTAssertEqual(view.commits, [])
    }

    func testEnterPlacesTheCaretOnTheGivenLineAndInstallsTheGuard() throws {
        let url = try fixture((0..<50).map { "line \($0)" }.joined(separator: "\n"))
        let (session, window) = entered(url, line: 20)
        XCTAssertEqual(session.editor.caretLine, 20)
        XCTAssertNotNil(EditCloseGuard.guardFor(window))
        XCTAssertTrue(window.delegate === EditCloseGuard.guardFor(window))
        XCTAssertFalse(session.editor.undoManager.canUndo)
    }

    // MARK: - Dirty state

    func testDirtyFlagMirrorsToTheWindowAndClearsOnTheExactCheck() throws {
        let (session, window) = entered(try fixture("abc\n"))
        XCTAssertFalse(window.isDocumentEdited)
        type(session, "x", at: 0)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(window.isDocumentEdited)
        XCTAssertTrue(try guardHandlers(window).isDirty())
        session.editor.undoManager.undo()
        XCTAssertEqual(session.editor.text, "abc\n")
        XCTAssertFalse(try guardHandlers(window).isDirty(), "the guard's check is exact")
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(window.isDocumentEdited)
    }

    func testNothingLandsOnTheWindowsUndoManager() throws {
        let (session, window) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        XCTAssertTrue(session.editor.undoManager.canUndo)
        XCTAssertFalse(window.undoManager?.canUndo ?? false, "S-D1: the window's stack stays empty")
    }

    // MARK: - Saving: byte-exact (S-D7, S-D8)

    private func assertByteExactSave(_ original: Data, expected: Data, insert: String = "X",
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try fixture(original, name: "fmt-\(UUID().uuidString).md")
        let (session, _) = entered(url, file: file, lineNumber: line)
        type(session, insert, at: 0)
        XCTAssertEqual(save(session), true, file: file, line: line)
        XCTAssertEqual(bytes(url), expected, "after the edit", file: file, line: line)
        XCTAssertFalse(session.isDirty, file: file, line: line)
        // Revert by a new edit (not undo) and save again: the original bytes.
        delete(session, NSRange(location: 0, length: (insert as NSString).length))
        XCTAssertEqual(save(session), true, file: file, line: line)
        XCTAssertEqual(bytes(url), original, "after reverting the edit", file: file, line: line)
    }

    func testByteExactSaveLF() throws {
        try assertByteExactSave(Data("a\nb\n".utf8), expected: Data("Xa\nb\n".utf8))
    }

    func testByteExactSaveCRLF() throws {
        try assertByteExactSave(Data("a\r\nb\r\n".utf8), expected: Data("Xa\r\nb\r\n".utf8))
    }

    func testByteExactSaveUTF8WithBOM() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        try assertByteExactSave(bom + Data("a\nb".utf8), expected: bom + Data("Xa\nb".utf8))
    }

    func testByteExactSaveUTF16LE() throws {
        let bom = Data([0xFF, 0xFE])
        try assertByteExactSave(bom + "zażółć\r\n".data(using: .utf16LittleEndian)!,
                                expected: bom + "Xzażółć\r\n".data(using: .utf16LittleEndian)!)
    }

    func testByteExactSaveLatin1() throws {
        try assertByteExactSave("café\nb\n".data(using: .isoLatin1)!,
                                expected: "Xcafé\nb\n".data(using: .isoLatin1)!)
    }

    func testTypedAndUndoneSaveDoesNotWrite() throws {
        let url = try fixture("abc\n")
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        let (session, _) = entered(url)
        type(session, "x", at: 1)
        session.editor.undoManager.undo()
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(save(session), true, "nothing changed at all")
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime, past, "a no-op save does not touch the file")
        XCTAssertEqual(view.toasts, [])
        XCTAssertFalse(session.isDirty)
    }

    func testSaveKeepsInodeAndPermissionsAndTheUndoStack() throws {
        let url = try fixture("abc\n")
        chmod(url.path, 0o640)
        let before = inode(url)
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        XCTAssertEqual(save(session), true)
        let after = inode(url)
        XCTAssertEqual(after.ino, before.ino)
        XCTAssertEqual(after.mode, 0o640)
        XCTAssertEqual(bytes(url), Data("xabc\n".utf8))
        XCTAssertEqual(view.toasts, ["Saved"])
        XCTAssertEqual(view.commits.last, "xabc\n", "the rendered view shows the saved text")
        XCTAssertFalse(window.isDocumentEdited)
        XCTAssertTrue(session.editor.undoManager.canUndo, "the undo stack survives a save")
        session.editor.undoManager.undo()
        XCTAssertTrue(session.isDirty, "undoing past the save is an edit")
    }

    func testMixedLineEndingsToastOnlyOnTheFirstSave() throws {
        let url = try fixture("a\r\nb\nc\r\n")
        let (session, _) = entered(url)
        type(session, "1", at: 0)
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(bytes(url), Data("1a\r\nb\r\nc\r\n".utf8))
        type(session, "2", at: 0)
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(view.toasts, ["Saved · line endings unified to CRLF", "Saved"])
    }

    // MARK: - Saving: conflicts (S-D9 step 2)

    private func conflictSetup() throws -> (SourceEditSession, URL) {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other app\n".utf8).write(to: url)
        return (session, url)
    }

    func testConflictCancelLeavesEverything() throws {
        let (session, url) = try conflictSetup()
        prompts.conflictAnswer = .cancel
        XCTAssertEqual(save(session), false)
        XCTAssertEqual(prompts.conflictCalls, 1)
        XCTAssertEqual(bytes(url), Data("other app\n".utf8))
        XCTAssertEqual(session.editor.text, "mine base\n")
        XCTAssertTrue(session.isDirty)
    }

    func testConflictSaveAnywayWrites() throws {
        let (session, url) = try conflictSetup()
        prompts.conflictAnswer = .saveAnyway
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(bytes(url), Data("mine base\n".utf8))
        XCTAssertFalse(session.isDirty)
        type(session, "!", at: 0)
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(prompts.conflictCalls, 1, "our own write is the new base")
    }

    func testConflictLoadDiskVersionReplacesTheBufferUndoably() throws {
        let (session, url) = try conflictSetup()
        prompts.conflictAnswer = .loadDiskVersion
        XCTAssertEqual(save(session), false)
        XCTAssertEqual(bytes(url), Data("other app\n".utf8))
        XCTAssertEqual(session.editor.text, "other app\n")
        XCTAssertFalse(session.isDirty)
        session.editor.undoManager.undo()
        XCTAssertEqual(session.editor.text, "mine base\n")
        XCTAssertTrue(session.isDirty)
    }

    // MARK: - Saving: encoding fallback, failure

    func testLatin1WithAnUnrepresentableCharacterDeclined() throws {
        let original = "caf\u{E9}\n".data(using: .isoLatin1)!
        let url = try fixture(original)
        let (session, _) = entered(url)
        type(session, "ł", at: 0)
        prompts.encodingAnswer = false
        XCTAssertEqual(save(session), false)
        XCTAssertEqual(prompts.encodingNames, ["ISO Latin 1"])
        XCTAssertEqual(bytes(url), original)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.format.encoding, .isoLatin1)
    }

    func testLatin1WithAnUnrepresentableCharacterSavedAsUTF8() throws {
        let url = try fixture("caf\u{E9}\r\n".data(using: .isoLatin1)!)
        let (session, _) = entered(url)
        type(session, "ł", at: 0)
        prompts.encodingAnswer = true
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(bytes(url), Data("łcafé\r\n".utf8), "UTF-8, no BOM, line ending kept")
        XCTAssertEqual(session.format, DocumentFileFormat(encoding: .utf8, hasBOM: false, lineEnding: .crlf))
        XCTAssertFalse(session.isDirty)
    }

    func testWriteFailureOffersACopyAndStaysDirty() throws {
        let url = try fixture("abc\n")
        let (session, _) = entered(url)
        type(session, "x", at: 0)
        chmod(url.path, 0o444)
        let copy = directory.appendingPathComponent("copy.md")
        prompts.saveFailedAnswer = .saveCopy
        prompts.copyURL = copy
        XCTAssertEqual(save(session), false)
        XCTAssertEqual(prompts.saveFailedErrors.count, 1)
        let error = try XCTUnwrap(prompts.saveFailedErrors.first as? LocalizedError)
        XCTAssertEqual(error.errorDescription, "“doc.md” is read-only.")
        XCTAssertEqual(prompts.copyCalls, 1)
        XCTAssertEqual(bytes(copy), Data("xabc\n".utf8))
        XCTAssertEqual(bytes(url), Data("abc\n".utf8))
        XCTAssertEqual(view.toasts, ["Copy saved"])
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.isActive)
    }

    func testWriteFailureOKWritesNothing() throws {
        let url = try fixture("abc\n")
        let (session, _) = entered(url)
        type(session, "x", at: 0)
        try FileManager.default.removeItem(at: url)
        prompts.saveFailedAnswer = .ok
        XCTAssertEqual(save(session), false)
        XCTAssertEqual(prompts.copyCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "never recreated")
        XCTAssertTrue(session.isDirty)
    }

    // MARK: - External changes (S-D9)

    func testOurOwnSaveEchoIsIgnored() throws {
        let url = try fixture("abc\n")
        let (session, _) = entered(url)
        type(session, "x", at: 0)
        save(session)
        let commits = view.commits.count
        session.diskDidChange()
        XCTAssertEqual(view.commits.count, commits)
        XCTAssertEqual(session.editor.text, "xabc\n")
        XCTAssertFalse(session.externalChange)
    }

    func testCleanBufferAdoptsAnExternalChange() throws {
        let url = try fixture("one\ntwo\nthree\n")
        let (session, _) = entered(url)
        type(session, "x", at: 0)
        session.editor.undoManager.undo()
        session.editor.textView.setSelectedRange(NSRange(location: 5, length: 0))  // line 1, column 1
        try Data("ONE\r\ntwo!\r\nthree\r\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertEqual(session.editor.text, "ONE\ntwo!\nthree\n")
        XCTAssertEqual(session.savedText, "ONE\ntwo!\nthree\n")
        XCTAssertEqual(session.baseBytes, bytes(url))
        XCTAssertEqual(session.format.lineEnding, .crlf)
        XCTAssertEqual(view.commits.last, "ONE\ntwo!\nthree\n")
        XCTAssertFalse(session.editor.undoManager.canUndo, "the stack described the old text")
        XCTAssertEqual(session.editor.textView.selectedRange().location, 5, "same line and column")
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.externalChange)
    }

    func testDirtyBufferShowsTheBannerAndKeepsTheText() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertTrue(session.externalChange)
        XCTAssertEqual(view.commits.last, "other\n", "rendered == disk")
        XCTAssertEqual(session.editor.text, "mine base\n")
        XCTAssertTrue(session.isDirty)
    }

    func testKeepMyVersionThenSaveDoesNotAsk() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        session.keepMyVersion()
        XCTAssertFalse(session.externalChange)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(prompts.conflictCalls, 0)
        XCTAssertEqual(bytes(url), Data("mine base\n".utf8))
    }

    func testLoadDiskVersionIsOneUndoableReplacement() throws {
        let url = try fixture("base\n")
        let (session, window) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        session.loadDiskVersion()
        XCTAssertEqual(session.editor.text, "other\n")
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(window.isDocumentEdited)
        XCTAssertFalse(session.externalChange)
        XCTAssertEqual(session.baseBytes, Data("other\n".utf8))
        session.editor.undoManager.undo()
        XCTAssertEqual(session.editor.text, "mine base\n")
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(window.isDocumentEdited)
    }

    func testDiskBackToTheBaseClearsTheBanner() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        try Data("base\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertFalse(session.externalChange)
        XCTAssertEqual(view.commits.last, "base\n")
        XCTAssertEqual(session.editor.text, "mine base\n")
    }

    func testMissingFileLeavesEverythingAsIs() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url, rendered: "base\n")
        type(session, "x", at: 0)
        try FileManager.default.removeItem(at: url)
        session.diskDidChange()
        XCTAssertFalse(session.externalChange)
        XCTAssertEqual(session.editor.text, "xbase\n")
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(view.commits, [])
    }

    // MARK: - Leaving (S-D10)

    func testLeaveWhenCleanDoesNotAsk() throws {
        let (session, _) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        session.editor.undoManager.undo()
        var left: Bool?
        session.requestLeave { left = $0 }
        XCTAssertEqual(left, true)
        XCTAssertEqual(prompts.unsavedCalls, 0, "typed and undone never prompts")
        XCTAssertFalse(session.isActive)
    }

    func testLeaveSave() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.save]
        var left: Bool?
        session.requestLeave { left = $0 }
        XCTAssertEqual(left, true)
        XCTAssertEqual(bytes(url), Data("xabc\n".utf8))
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(window.isDocumentEdited)
    }

    func testLeaveDontSave() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.discard]
        var left: Bool?
        session.requestLeave { left = $0 }
        XCTAssertEqual(left, true)
        XCTAssertEqual(bytes(url), Data("abc\n".utf8))
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(window.isDocumentEdited)
        XCTAssertFalse(try guardHandlers(window).isDirty())
    }

    func testLeaveCancelStays() throws {
        let (session, _) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.cancel]
        var left: Bool?
        session.requestLeave { left = $0 }
        XCTAssertEqual(left, false)
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.isDirty)
        XCTAssertNil(session.lastLeave)
    }

    func testLeaveWithAFailingSaveStays() throws {
        let url = try fixture("abc\n")
        let (session, _) = entered(url)
        type(session, "x", at: 0)
        chmod(url.path, 0o444)
        prompts.unsavedAnswers = [.save]
        var left: Bool?
        session.requestLeave { left = $0 }
        XCTAssertEqual(left, false)
        XCTAssertEqual(prompts.saveFailedErrors.count, 1)
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.isDirty)
    }

    func testLeavingDropsTheUndoStackAndAPendingFocus() throws {
        let (session, window) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        XCTAssertEqual(save(session), true)
        XCTAssertTrue(session.editor.undoManager.canUndo)
        // The editor is not mounted yet when focus is asked for.
        let scrollView = try XCTUnwrap(session.editor.textView.enclosingScrollView)
        scrollView.removeFromSuperview()
        session.focusEditor()
        session.requestLeave()
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.editor.undoManager.canUndo)
        window.contentView!.addSubview(scrollView)
        XCTAssertFalse(window.firstResponder === session.editor.textView, "no focus after the mode ended")
    }

    func testEscapeRequestsLeave() throws {
        let (session, _) = entered(try fixture("abc\n"))
        session.editor.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(session.isActive)
    }

    private func numbered(_ count: Int) -> String {
        (0..<count).map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func testLandingNotNeededWhenNothingHappened() throws {
        let (session, _) = entered(try fixture(numbered(20)), line: 3)
        session.requestLeave()
        XCTAssertEqual(session.lastLeave?.caretLine, 3)
        XCTAssertEqual(session.lastLeave?.shouldLand, false)
    }

    func testLandingAfterTheCaretMoved() throws {
        let (session, _) = entered(try fixture(numbered(20)), line: 3)
        session.editor.placeCaret(atLine: 7)
        session.requestLeave()
        XCTAssertEqual(session.lastLeave?.caretLine, 7)
        XCTAssertEqual(session.lastLeave?.shouldLand, true)
    }

    func testLandingAfterASaveOnTheEntryLine() throws {
        let (session, _) = entered(try fixture(numbered(20)), line: 3)
        type(session, "x")
        XCTAssertEqual(save(session), true)
        session.requestLeave()
        XCTAssertEqual(session.lastLeave?.caretLine, 3)
        XCTAssertEqual(session.lastLeave?.shouldLand, true)
        let first = session.lastLeave
        XCTAssertNil(session.enter(atLine: 3))
        session.requestLeave()
        XCTAssertEqual(session.lastLeave?.shouldLand, false, "a new session starts unsaved")
        XCTAssertNotEqual(session.lastLeave, first, "each leave publishes a distinct value")
    }

    func testDiscardChangesIsUndoableAndStaysInTheMode() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        session.discardChanges()
        XCTAssertEqual(session.editor.text, "abc\n")
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(window.isDocumentEdited)
        session.editor.undoManager.undo()
        XCTAssertEqual(session.editor.text, "xabc\n")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(bytes(url), Data("abc\n".utf8))
    }

    // MARK: - Close guard (S-D11)

    func testGuardConfirmSave() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.save]
        var result: Bool?
        try guardHandlers(window).confirm(window) { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertEqual(bytes(url), Data("xabc\n".utf8))
        XCTAssertFalse(try guardHandlers(window).isDirty())
    }

    func testGuardConfirmDontSaveRevertsBeforeCompleting() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.discard]
        let handlers = try guardHandlers(window)
        var dirtyAtCompletion: Bool?
        var textAtCompletion: String?
        var result: Bool?
        handlers.confirm(window) { confirmed in
            result = confirmed
            dirtyAtCompletion = handlers.isDirty()
            textAtCompletion = session.editor.text
        }
        XCTAssertEqual(result, true)
        XCTAssertEqual(dirtyAtCompletion, false)
        XCTAssertEqual(textAtCompletion, "abc\n")
        XCTAssertEqual(bytes(url), Data("abc\n".utf8))
        XCTAssertFalse(window.isDocumentEdited)
    }

    func testGuardConfirmCancel() throws {
        let (session, window) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.cancel]
        var result: Bool?
        try guardHandlers(window).confirm(window) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.editor.text, "xabc\n")
    }

    func testGuardResolveSynchronouslySave() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        try Data("changed meanwhile\n".utf8).write(to: url)
        prompts.modalAnswer = .save
        try guardHandlers(window).resolveSynchronously(window)
        XCTAssertEqual(prompts.modalCalls, 1)
        XCTAssertEqual(prompts.conflictCalls, 0, "no further questions")
        XCTAssertEqual(bytes(url), Data("xabc\n".utf8))
        XCTAssertFalse(session.isDirty)
    }

    func testGuardResolveSynchronouslySaveFallsBackToUTF8AndACopy() throws {
        let url = try fixture("caf\u{E9}\n".data(using: .isoLatin1)!)
        let (session, window) = entered(url)
        type(session, "ł", at: 0)
        chmod(url.path, 0o444)
        let copy = directory.appendingPathComponent("rescued.md")
        prompts.modalAnswer = .save
        prompts.copyModalURLs = [copy]
        try guardHandlers(window).resolveSynchronously(window)
        XCTAssertEqual(prompts.encodingNames, [], "no sheet: UTF-8 without asking")
        XCTAssertEqual(prompts.copyModalCalls, 1)
        XCTAssertEqual(bytes(copy), Data("łcafé\n".utf8))
        XCTAssertEqual(bytes(url), "caf\u{E9}\n".data(using: .isoLatin1)!)
    }

    func testGuardResolveSynchronouslyDiscard() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        prompts.modalAnswer = .discard
        try guardHandlers(window).resolveSynchronously(window)
        XCTAssertEqual(bytes(url), Data("abc\n".utf8))
        XCTAssertEqual(session.editor.text, "abc\n")
        XCTAssertFalse(session.isDirty)
    }

    func testGuardIsNotDirtyAfterLeaving() throws {
        let (session, window) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.discard]
        session.requestLeave()
        XCTAssertFalse(try guardHandlers(window).isDirty())
        XCTAssertTrue(window.delegate === EditCloseGuard.guardFor(window), "installed once, stays")
    }

    // MARK: - Review round (2026-10-05)

    // 1. Save Anyway never advances the base ahead of the write.
    func testSaveAnywayThenAFailedWriteKeepsEverythingConsistent() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other app\n".utf8).write(to: url)
        prompts.conflictAnswer = .saveAnyway
        prompts.beforeConflictAnswer = { _ in chmod(url.path, 0o444) }
        prompts.saveFailedAnswer = .ok
        XCTAssertEqual(save(session), false)
        XCTAssertEqual(prompts.saveFailedErrors.count, 1)
        XCTAssertEqual(bytes(url), Data("other app\n".utf8), "the other version is still on disk")
        XCTAssertEqual(session.baseBytes, Data("base\n".utf8), "base untouched by a failed write")
        XCTAssertEqual(session.savedText, "base\n")
        XCTAssertEqual(view.rendered, "other app\n", "rendered == disk")
        XCTAssertTrue(session.externalChange, "the banner says the disk moved")
        XCTAssertTrue(session.isDirty)
        // The watcher's echo of nothing changes nothing; the next save asks again.
        session.diskDidChange()
        XCTAssertEqual(view.rendered, "other app\n")
        chmod(url.path, 0o644)
        prompts.beforeConflictAnswer = nil
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(prompts.conflictCalls, 2)
        XCTAssertEqual(bytes(url), Data("mine base\n".utf8))
        XCTAssertFalse(session.externalChange)
    }

    // 2. The disk moved while the conflict prompt was up: ask about the new version.
    func testDiskChangeWhileTheConflictPromptIsUpAsksAgain() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other 1\n".utf8).write(to: url)
        prompts.conflictAnswer = .saveAnyway
        prompts.beforeConflictAnswer = { call in
            if call == 1 { try? Data("other 2\n".utf8).write(to: url) }
        }
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(prompts.conflictCalls, 2, "the second version was shown before overwriting it")
        XCTAssertEqual(bytes(url), Data("mine base\n".utf8))
    }

    func testDiskChangeWhileTheConflictPromptIsUpThenCancelOverwritesNothing() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other 1\n".utf8).write(to: url)
        prompts.conflictAnswers = [.saveAnyway, .cancel]
        prompts.beforeConflictAnswer = { call in
            if call == 1 { try? Data("other 2\n".utf8).write(to: url) }
        }
        XCTAssertEqual(save(session), false)
        XCTAssertEqual(bytes(url), Data("other 2\n".utf8))
        XCTAssertEqual(view.rendered, "other 2\n")
    }

    // 3. Keep My Version adopts the disk's NEW format.
    func testKeepMyVersionAfterAFormatChangeSavesInTheNewFormat() throws {
        let url = try fixture("a\r\nb\r\n")
        let (session, _) = entered(url)
        type(session, "X", at: 0)
        try Data("a\nb\n".utf8).write(to: url)   // git rewrote it as LF
        session.diskDidChange()
        session.keepMyVersion()
        XCTAssertEqual(session.format.lineEnding, .lf)
        XCTAssertEqual(session.savedText, "a\nb\n")
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(prompts.conflictCalls, 0)
        XCTAssertEqual(bytes(url), Data("Xa\nb\n".utf8), "LF, only the user's edit")
    }

    func testKeepMyVersionOfAFileThatCannotBeEditedKeepsTheBanner() throws {
        let unsafe = [Data([0xFF, 0xFE, 0x61, 0x00, 0x62]), Data([0xFE, 0xFF, 0x00, 0x61, 0x00]),
                      Data([0xFF, 0xFE, 0x00, 0xD8, 0x61, 0x00])]
            .first { DocumentFileFormat.decode($0).map { !$0.isLosslessDecode } ?? false }
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try XCTUnwrap(unsafe).write(to: url)
        session.diskDidChange()
        XCTAssertTrue(session.externalChange)
        session.keepMyVersion()
        XCTAssertTrue(session.externalChange, "banner stays")
        XCTAssertEqual(session.baseBytes, Data("base\n".utf8))
        XCTAssertEqual(session.savedText, "base\n")
        XCTAssertEqual(view.toasts.last?.contains("can’t be edited safely"), true)
        try FileManager.default.removeItem(at: url)
        session.keepMyVersion()
        XCTAssertTrue(session.externalChange)
        XCTAssertEqual(view.toasts.last, "“doc.md” no longer exists.")
    }

    // 4. Re-entrancy while a prompt is up.
    func testNothingStartsWhileAPromptIsUp() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        prompts.holdUnsaved = true
        var left: Bool?
        session.requestLeave { left = $0 }
        XCTAssertNil(left)
        XCTAssertTrue(session.isPrompting)

        var saved: Bool?
        session.save { saved = $0 }
        XCTAssertEqual(saved, false)
        var leftAgain: Bool?
        session.requestLeave { leftAgain = $0 }
        XCTAssertEqual(leftAgain, false)
        var confirmed: Bool?
        try guardHandlers(window).confirm(window) { confirmed = $0 }
        XCTAssertEqual(confirmed, false, "a ⌘W / ⌘Q during the sheet is cancelled, not queued")
        XCTAssertEqual(beeps, 1)
        session.discardChanges()
        session.keepMyVersion()
        session.loadDiskVersion()
        XCTAssertEqual(session.editor.text, "xabc\n", "no banner / menu action ran")
        XCTAssertEqual(prompts.unsavedCalls, 1, "never a second sheet")
        XCTAssertEqual(bytes(url), Data("abc\n".utf8))

        // A disk change keeps rendered == disk and raises the banner, buffer untouched.
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertEqual(view.rendered, "other\n")
        XCTAssertTrue(session.externalChange)
        XCTAssertEqual(session.editor.text, "xabc\n")

        let held = try XCTUnwrap(prompts.heldUnsaved)
        held(.cancel)
        XCTAssertEqual(left, false)
        XCTAssertFalse(session.isPrompting)
        XCTAssertEqual(save(session), false, "a new chain starts (and meets the conflict, cancelled)")
        XCTAssertEqual(prompts.conflictCalls, 1)
    }

    func testAChainEndsOnEveryExit() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        prompts.unsavedAnswers = [.cancel]
        session.requestLeave()
        XCTAssertFalse(session.isPrompting)
        chmod(url.path, 0o444)
        prompts.saveFailedAnswer = .saveCopy
        prompts.copyURL = nil
        save(session)
        XCTAssertFalse(session.isPrompting, "save failed, copy panel cancelled")
        chmod(url.path, 0o644)
        prompts.unsavedAnswers = [.cancel]
        try guardHandlers(window).confirm(window) { _ in }
        XCTAssertFalse(session.isPrompting)
        XCTAssertEqual(save(session), true)
        XCTAssertFalse(session.isPrompting)
    }

    // 5. Never clean on faith.
    func testRefusedDiscardKeepsTheBufferDirty() throws {
        let (session, window) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        session.editor.textView.isEditable = false
        session.discardChanges()
        XCTAssertEqual(session.editor.text, "xabc\n")
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(window.isDocumentEdited)
        XCTAssertTrue(try guardHandlers(window).isDirty())
    }

    func testRefusedLoadDiskVersionKeepsTheBufferDirty() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        session.editor.textView.isEditable = false
        session.loadDiskVersion()
        XCTAssertEqual(session.editor.text, "xabc\n")
        XCTAssertTrue(session.isDirty, "dirty against the adopted disk text")
        XCTAssertTrue(window.isDocumentEdited)
    }

    // 6. Mixed AND repaired is refused; mixed alone is allowed (above).
    func testEntryRefusesExactlyWhenTheDecodeIsLossy() throws {
        let mixedRepaired = Data([0xFF, 0xFE]) + "a\r\nb\nc".data(using: .utf16LittleEndian)! + Data([0x64])
        let decoded = try XCTUnwrap(DocumentFileFormat.decode(mixedRepaired))
        let url = try fixture(mixedRepaired, name: "odd.md")
        let (session, _) = makeSession(url)
        let refusal = session.enter(atLine: 0)
        XCTAssertEqual(refusal == .unsafe(fileName: "odd.md"), !decoded.isLosslessDecode)
    }

    // 7. Follow-up prompts use the window confirm was given.
    func testConfirmFollowUpsUseTheConfirmWindow() throws {
        let url = try fixture("abc\n")
        let (session, window) = entered(url)
        type(session, "x", at: 0)
        // No window from the environment, and the editor unmounted, so the
        // session's own fallback finds none either.
        session.environment.window = { nil }
        session.editor.textView.enclosingScrollView?.removeFromSuperview()
        try Data("other\n".utf8).write(to: url)
        prompts.unsavedAnswers = [.save]
        prompts.conflictAnswer = .saveAnyway
        chmod(url.path, 0o444)
        prompts.saveFailedAnswer = .saveCopy
        prompts.copyURL = nil
        var result: Bool?
        try guardHandlers(window).confirm(window) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(prompts.windows.count, 4, "unsaved, conflict, save failed, copy panel")
        XCTAssertTrue(prompts.windows.allSatisfy { $0 === window })
    }

    // 8. Literal comparison: NFC vs NFD is a change.
    func testNormalizationOnlyChangeIsDirtyAndSaved() throws {
        let url = try fixture("caf\u{E9}\n")
        let (session, window) = entered(url)
        let length = (session.editor.text as NSString).length
        userAction(session) {
            session.editor.textView.insertText("cafe\u{301}\n", replacementRange: NSRange(location: 0, length: length))
        }
        XCTAssertEqual(session.editor.text, session.savedText, "Swift == says equal…")
        XCTAssertTrue(session.checkDirty(), "…the session does not")
        XCTAssertTrue(window.isDocumentEdited)
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(bytes(url), Data("cafe\u{301}\n".utf8))
        XCTAssertFalse(SourceEditSession.isSameText("\u{E9}", "e\u{301}"))
        XCTAssertTrue(SourceEditSession.isSameText("e\u{301}", "e\u{301}"))
    }

    // 9. With the banner up, ⌘S on an unchanged buffer is not a silent no-op…
    func testSaveWithTheBannerUpAndAnUnchangedBufferGoesThroughTheConflict() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "x", at: 0)
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        session.editor.undoManager.undo()
        XCTAssertEqual(session.editor.text, "base\n")
        prompts.conflictAnswer = .saveAnyway
        XCTAssertEqual(save(session), true)
        XCTAssertEqual(prompts.conflictCalls, 1)
        XCTAssertEqual(bytes(url), Data("base\n".utf8))
        XCTAssertFalse(session.externalChange)
    }

    // …and Discard Changes means the disk version.
    func testDiscardWithTheBannerUpLoadsTheDiskVersion() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "mine ", at: 0)
        try Data("other\n".utf8).write(to: url)
        session.diskDidChange()
        session.discardChanges()
        XCTAssertEqual(session.editor.text, "other\n")
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.externalChange)
        session.editor.undoManager.undo()
        XCTAssertEqual(session.editor.text, "mine base\n")
    }

    // 10. A clean adopt clears the banner.
    func testCleanAdoptClearsTheBanner() throws {
        let url = try fixture("base\n")
        let (session, _) = entered(url)
        type(session, "x", at: 0)
        try Data("other 1\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertTrue(session.externalChange)
        session.editor.undoManager.undo()
        try Data("other 2\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertEqual(session.editor.text, "other 2\n")
        XCTAssertFalse(session.externalChange)
    }

    // 11. An empty file is adopted only if it is still empty a moment later.
    /// Runs everything already queued on the main queue: the recheck is
    /// queued with delay 0 before this marker, and timers fire in deadline
    /// order — no wall-clock waiting.
    private func drainMainQueue() {
        var drained = false
        DispatchQueue.main.asyncAfter(deadline: .now()) { drained = true }
        while !drained { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func enteredWithoutRecheckDelay(_ url: URL) -> SourceEditSession {
        let (session, _) = entered(url)
        session.emptyFileRecheckDelay = 0
        return session
    }

    func testEmptyFileIsAdoptedAfterTheRecheck() throws {
        XCTAssertEqual(SourceEditSession.defaultEmptyFileRecheckDelay, 0.3)
        let url = try fixture("abc\n")
        let session = enteredWithoutRecheckDelay(url)
        try Data().write(to: url)
        session.diskDidChange()
        XCTAssertEqual(view.rendered, "", "rendered == disk at once")
        XCTAssertEqual(session.editor.text, "abc\n", "not adopted yet")
        drainMainQueue()
        XCTAssertEqual(session.editor.text, "")
        XCTAssertEqual(session.savedText, "")
    }

    func testEmptyFileFollowedByContentAdoptsTheContent() throws {
        let url = try fixture("abc\n")
        let session = enteredWithoutRecheckDelay(url)
        try Data().write(to: url)
        session.diskDidChange()
        try Data("rewritten\n".utf8).write(to: url)
        session.diskDidChange()
        XCTAssertEqual(session.editor.text, "rewritten\n")
        drainMainQueue()
        XCTAssertEqual(session.editor.text, "rewritten\n")
        XCTAssertEqual(session.savedText, "rewritten\n")
    }

    /// A slow non-atomic writer re-saving the SAME content: the watcher sees
    /// the empty file, then the base bytes again. The rendered text must end
    /// as the saved text; nothing else may change.
    func testEmptyFileThenTheSameBytesRestoresTheRenderedText() throws {
        let url = try fixture("one\ntwo\n")
        let session = enteredWithoutRecheckDelay(url)
        type(session, "x", at: 0)
        session.editor.undoManager.undo()
        session.editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        let commitsBefore = view.commits.count
        try Data().write(to: url)
        session.diskDidChange()
        XCTAssertEqual(view.rendered, "")
        try Data("one\ntwo\n".utf8).write(to: url)
        session.diskDidChange()
        drainMainQueue()
        XCTAssertEqual(view.commits.count, commitsBefore + 2, "\"\", then the saved text")
        XCTAssertEqual(view.commits.last, "one\ntwo\n")
        XCTAssertEqual(view.rendered, session.savedText)
        XCTAssertEqual(session.editor.text, "one\ntwo\n")
        XCTAssertEqual(session.baseBytes, Data("one\ntwo\n".utf8))
        XCTAssertTrue(session.editor.undoManager.canRedo, "undo stack untouched (no reload)")
        XCTAssertEqual(session.editor.textView.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertFalse(session.externalChange)
        XCTAssertFalse(session.isDirty)
        // A plain echo afterwards commits nothing more.
        session.diskDidChange()
        XCTAssertEqual(view.commits.count, commitsBefore + 2)
    }

    func testLeavingCancelsTheEmptyFileRecheck() throws {
        let url = try fixture("abc\n")
        let session = enteredWithoutRecheckDelay(url)
        try Data().write(to: url)
        session.diskDidChange()
        session.requestLeave()
        let commits = view.commits.count
        drainMainQueue()
        XCTAssertEqual(view.commits.count, commits)
        XCTAssertEqual(session.savedText, "abc\n")
    }

    func testBannerAndMenuActionsBeepWhileAPromptIsUp() throws {
        let (session, _) = entered(try fixture("abc\n"))
        type(session, "x", at: 0)
        prompts.holdUnsaved = true
        session.requestLeave()
        session.discardChanges()
        session.keepMyVersion()
        session.loadDiskVersion()
        XCTAssertEqual(beeps, 3)
        XCTAssertEqual(session.editor.text, "xabc\n")
        prompts.heldUnsaved?(.cancel)
    }

    // 12. The standard alerts, built but never shown.
    func testConflictAlertHasNoDefaultButton() {
        let alert = SourceEditSession.Prompts.makeConflictAlert(fileName: "x.md")
        XCTAssertEqual(alert.messageText, "“x.md” has been changed by another application.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Save Anyway", "Load Disk Version", "Cancel"])
        XCTAssertFalse(alert.buttons.contains { $0.keyEquivalent == "\r" }, "Return triggers nothing")
        XCTAssertEqual(alert.buttons[2].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.buttons.map { $0.accessibilityIdentifier() },
                       ["source-conflict-save-anyway", "source-conflict-load-disk", "source-conflict-cancel"])
    }

    func testEncodingAlertMakesNoClaimAboutLineEndings() {
        let alert = SourceEditSession.Prompts.makeEncodingAlert(fileName: "x.md", encodingName: "ISO Latin 1")
        XCTAssertEqual(alert.messageText,
                       "“x.md” uses ISO Latin 1, which cannot store some of the characters you typed.")
        XCTAssertFalse(alert.informativeText.lowercased().contains("line ending"))
        XCTAssertEqual(alert.buttons.map { $0.accessibilityIdentifier() },
                       ["source-encoding-utf8", "source-encoding-cancel"])
    }

    // 13. Entry-check order.
    func testEntryCheckOrder() throws {
        let big = String(repeating: "a", count: SourceEditSession.maximumEditableBytes + 1)
        let readOnlyAndBig = try fixture(big, name: "ro-big.md")
        chmod(readOnlyAndBig.path, 0o444)
        XCTAssertEqual(makeSession(readOnlyAndBig).0.enter(atLine: 0), .readOnly(fileName: "ro-big.md"))

        let writeOnly = try fixture("abc\n", name: "wo.md")
        chmod(writeOnly.path, 0o222)
        XCTAssertEqual(makeSession(writeOnly).0.enter(atLine: 0), .unreadable(fileName: "wo.md"),
                       "unreadable before read-only")

        let noAccess = try fixture(big, name: "none-big.md")
        chmod(noAccess.path, 0o000)
        XCTAssertEqual(makeSession(noAccess).0.enter(atLine: 0), .unreadable(fileName: "none-big.md"))
    }

    // MARK: - Lifetime

    func testSessionDeallocatesWithAGuardInstalled() throws {
        let url = try fixture("abc\n")
        weak var weakSession: SourceEditSession?
        var window: NSWindow?
        autoreleasepool {
            let (session, sessionWindow) = entered(url)
            type(session, "x", at: 0)
            XCTAssertNotNil(EditCloseGuard.guardFor(sessionWindow))
            weakSession = session
            window = sessionWindow
        }
        XCTAssertNil(weakSession, "window → guard → handlers must not keep the session alive")
        XCTAssertNotNil(window)
        // A gone session is clean: the window closes without a question.
        XCTAssertFalse(try guardHandlers(window!).isDirty())
    }
}
