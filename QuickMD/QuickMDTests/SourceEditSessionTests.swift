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

        var prompts: SourceEditSession.Prompts {
            SourceEditSession.Prompts(
                unsavedChanges: { _, _, completion in
                    self.unsavedCalls += 1
                    self.onUnsaved?()
                    completion(self.unsavedAnswers.isEmpty ? .cancel : self.unsavedAnswers.removeFirst())
                },
                unsavedChangesModal: { _ in
                    self.modalCalls += 1
                    return self.modalAnswer
                },
                saveConflict: { _, _, completion in
                    self.conflictCalls += 1
                    completion(self.conflictAnswer)
                },
                encodingFallback: { _, _, name, completion in
                    self.encodingNames.append(name)
                    completion(self.encodingAnswer)
                },
                saveFailed: { _, error, completion in
                    self.saveFailedErrors.append(error)
                    completion(self.saveFailedAnswer)
                },
                copyDestination: { _, _, _, completion in
                    self.copyCalls += 1
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
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        EditCloseGuard.hasAttachedSheet = savedHasAttachedSheet
        EditCloseGuard.disableAutomaticTermination = savedDisable
        EditCloseGuard.enableAutomaticTermination = savedEnable
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
            return !decoded.isByteExact && !decoded.hasMixedLineEndings
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
