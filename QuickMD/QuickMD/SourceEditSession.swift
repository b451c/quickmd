import AppKit
import Combine

// MARK: - Source Edit session (v1.12 S-D2, S-D3, S-D7–S-D11)
//
// One per document window: entering the editor, saving, external changes,
// leaving, and the answers the close guard needs. The view (T5b) owns it as a
// @StateObject, mounts `editor`, and feeds it an `Environment`.
//
// The invariant everything here protects (S-D2): the RENDERED text always
// equals what is on disk; unsaved text exists only in the editor's buffer.
// The session therefore never binds the buffer to the rendered text — it
// hands the view text through `commitText` only when that text is on disk.
//
// S-D1: nothing here calls `updateChangeCount`, touches `window.undoManager`
// or uses `performClose`. The window's NSDocument is SwiftUI's viewer
// document, which autosaves in place: if it ever became edited AppKit would
// write the ORIGINAL text over the file.
//
// Main-thread by convention, deliberately NOT @MainActor — the SwiftUI view
// code that creates and drives it is nonisolated on the older SDK the CI
// runner builds with (constraints "CI builds on an OLDER SDK"; same reasoning
// as `FileWatcher` and `EditCloseGuard`).

final class SourceEditSession: ObservableObject {

    /// Above this the editor refuses to open: entering at the end of a 5 MB
    /// buffer measured ~1.8 s of TextKit layout (the caret's exact line top
    /// needs everything above it laid out), and typing comforts scan lines.
    /// A file that big is not a "fix the typo you are reading" edit.
    static let maximumEditableBytes = 2 * 1024 * 1024

    // MARK: Published state

    /// The editor is showing (the view mounts it over the rendered list).
    @Published private(set) var isActive = false
    /// The buffer holds text that is not on disk. Set on the first edit and
    /// re-checked exactly (`buffer == savedText`) before every prompt or
    /// close decision, so "typed and undid" never asks.
    @Published private(set) var isDirty = false
    /// The file changed on disk while the buffer was dirty — drives the
    /// "changed on disk" banner (S-D9).
    @Published private(set) var externalChange = false
    /// Published once per leave: what the view needs for the landing scroll.
    @Published private(set) var lastLeave: LeaveInfo?

    /// The editing surface. Its text storage IS the buffer.
    let editor = SourceEditorController()

    // MARK: Environment

    /// What the view supplies. Closures, so the session holds neither the
    /// window nor the view: window → close guard → handlers → session must not
    /// lead back to the window (every closed document would stay alive).
    struct Environment {
        var documentURL: URL?
        /// The document window (weakly held by whoever provides it).
        var window: () -> NSWindow? = { nil }
        /// The text the rendered view currently shows, so entering only
        /// re-parses when the disk moved on. Nil = unknown: always commit.
        var renderedText: () -> String? = { nil }
        /// Make the rendered document show this LF text. Called only with
        /// text that is on disk.
        var commitText: (String) -> Void = { _ in }
        var toast: (String) -> Void = { _ in }
    }

    var environment = Environment()

    // MARK: Prompts

    enum ConflictChoice: Equatable { case saveAnyway, loadDiskVersion, cancel }
    enum SaveFailedChoice: Equatable { case saveCopy, ok }

    /// Every question the session asks. Injectable so the tests can answer;
    /// `.standard` shows real sheets on the window (NSAlert / NSSavePanel
    /// `beginSheetModal`), begun SYNCHRONOUSLY when called — the close guard
    /// treats "a sheet is attached" as "confirmation in progress", so each
    /// follow-up sheet must be up before the previous handler returns.
    /// A nil window (the view not in a window yet) falls back to app-modal.
    struct Prompts {
        var unsavedChanges: (_ window: NSWindow?, _ fileName: String,
                             _ completion: @escaping (UnsavedChangesAlert.Choice) -> Void) -> Void
        /// No Cancel: the window is already closing. `.save` or `.discard`.
        var unsavedChangesModal: (_ fileName: String) -> UnsavedChangesAlert.Choice
        var saveConflict: (_ window: NSWindow?, _ fileName: String,
                           _ completion: @escaping (ConflictChoice) -> Void) -> Void
        /// True = save as UTF-8.
        var encodingFallback: (_ window: NSWindow?, _ fileName: String, _ encodingName: String,
                               _ completion: @escaping (Bool) -> Void) -> Void
        var saveFailed: (_ window: NSWindow?, _ error: Error,
                         _ completion: @escaping (SaveFailedChoice) -> Void) -> Void
        /// Where to put "Save a Copy…"; nil = cancelled.
        var copyDestination: (_ window: NSWindow?, _ suggestedName: String, _ directory: URL?,
                              _ completion: @escaping (URL?) -> Void) -> Void
        /// App-modal variant for the closing-window path.
        var copyDestinationModal: (_ suggestedName: String, _ directory: URL?) -> URL?
    }

    var prompts = Prompts.standard

    // MARK: Leaving

    /// What leaving tells the view (S-D10).
    struct LeaveInfo: Equatable {
        /// The caret's 0-based line in the saved text.
        let caretLine: Int
        /// Scroll the rendered view to the block holding `caretLine`: the
        /// session saved at least once or the caret left the entry line.
        /// Otherwise the list stays exactly where the reader left it.
        let shouldLand: Bool
        /// Distinguishes two leaves with the same values (`onChange`).
        let sequence: Int
    }

    // MARK: Entering

    /// Why `enter` did not enter. `message` is what the view toasts.
    enum EnterRefusal: Equatable {
        case alreadyEditing
        case noFile
        case missing(fileName: String)
        case unreadable(fileName: String)
        case tooLarge(fileName: String)
        case readOnly(fileName: String)
        /// Re-encoding the unchanged text would not reproduce the file's
        /// bytes (the decoder repaired something): a save would rewrite bytes
        /// the user never touched (S-D8 entry check).
        case unsafe(fileName: String)

        var message: String {
            switch self {
            case .alreadyEditing:
                return "Already editing the source."
            case .noFile:
                return "This document has no file to edit."
            case .missing(let name):
                return "“\(name)” no longer exists."
            case .unreadable(let name):
                return "“\(name)” could not be read."
            case .tooLarge(let name):
                return "“\(name)” is too large to edit here (the limit is 2 MB)."
            case .readOnly(let name):
                return "“\(name)” is read-only."
            case .unsafe(let name):
                return "“\(name)” can’t be edited safely: saving would change parts of the file you did not edit."
            }
        }
    }

    // MARK: Internal state

    /// How the file is stored; a save writes the buffer back in it.
    private(set) var format = DocumentFileFormat(encoding: .utf8, hasBOM: false, lineEnding: .lf)
    /// The file bytes the buffer is based on: as read on entry, as written by
    /// our last save, or as acknowledged by the user (Keep My Version). A disk
    /// that differs from these was changed by someone else. Moves only
    /// together with `savedText` and `format` — never ahead of a write.
    private(set) var baseBytes = Data()
    /// The LF text matching `baseBytes` — the clean state of the buffer.
    private(set) var savedText = ""
    /// A chain of prompts (unsaved changes → conflict → encoding → save
    /// failed → save panel) is on screen. While it is, nothing else may start
    /// a sheet or change the buffer: `save` / `requestLeave` / the guard's
    /// `confirm` report false at once, the banner and menu actions do nothing,
    /// and a disk change only keeps the rendered text in step with the disk.
    private(set) var isPrompting = false
    /// The caret's line right after entering (0-based).
    private var entryLine = 0
    private var hasSavedOnce = false
    /// The file had mixed line endings; the first save unifies them and says so.
    private var hasMixedLineEndings = false
    private var leaveSequence = 0
    /// Set while the session itself replaces the buffer (`replaceAll`), so
    /// the editor's `onChange` does not flip the dirty flag on and off.
    private var isApplyingOwnEdit = false
    private weak var closeGuard: EditCloseGuard?
    /// The second look at a file that became empty (see `handleDiskChange`).
    private var emptyFileRecheck: DispatchWorkItem?

    /// A file that suddenly reads EMPTY may be another program half-way
    /// through a non-atomic save (truncate, then write): adopting it at once
    /// would show a clean, empty buffer for a moment and lose the caret.
    /// Looked at again after this long.
    static let defaultEmptyFileRecheckDelay: TimeInterval = 0.3
    /// `defaultEmptyFileRecheckDelay`; tests set 0 so they do not depend on
    /// wall-clock time.
    var emptyFileRecheckDelay = SourceEditSession.defaultEmptyFileRecheckDelay

    /// What the session last asked the view to show (`commit`) — nil before
    /// the first entry. Lets a disk event that brings back the base bytes
    /// repair a rendered text that was left showing something else.
    private var lastCommittedText: String?

    /// The beep for a request that arrives while a prompt is up (a close or
    /// quit, a banner or menu action). Replaced in tests (no sound from a
    /// test run).
    static var beep: () -> Void = { NSSound.beep() }

    init() {
        editor.onChange = { [weak self] in self?.bufferDidChange() }
        editor.onEscape = { [weak self] in self?.escape() }
    }

    deinit {
        emptyFileRecheck?.cancel()
    }

    private var fileName: String {
        environment.documentURL?.lastPathComponent ?? "Untitled"
    }

    private var window: NSWindow? {
        environment.window() ?? editor.textView.window
    }

    /// "The buffer equals the saved text", LITERALLY: UTF-16 code units, not
    /// Swift's `==` (canonical equivalence — "é" precomposed and decomposed
    /// compare equal, and a buffer differing only in normalization would
    /// count as clean and never be saved).
    static func isSameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.count == rhs.utf16.count && lhs.utf16.elementsEqual(rhs.utf16)
    }

    private var bufferMatchesSaved: Bool { Self.isSameText(editor.text, savedText) }

    /// Every "make the rendered view show this" goes through here, so the
    /// session knows what the view shows.
    private func commit(_ text: String) {
        lastCommittedText = text
        environment.commitText(text)
    }

    /// The rendered selection, for carrying it into the editor (S-D14b): its
    /// plain text and the 0-based source lines of the blocks it touches
    /// (`DocumentReadingPosition.selectionHint`).
    struct SelectionHint: Equatable {
        let text: String
        let lines: Range<Int>
    }

    /// Enters the editor with the caret at the start of 0-based `line` (nil:
    /// the top), scrolled to the top of the visible area — the view converts
    /// the reading position's 1-based `editorLine()`. With a `selection` whose
    /// text occurs literally in its source lines, that text is selected
    /// instead, its first line at the top (select a typo, ⌥⌘E, type the fix);
    /// otherwise the caret goes to `line` as without one. Returns nil when it
    /// entered; otherwise nothing changed and the refusal says why. Checks in
    /// the spec's order: no file, missing, unreadable, read-only, too large,
    /// unsafe. The view requests focus after mounting the editor (`focusEditor`).
    @discardableResult
    func enter(atLine line: Int?, selection: SelectionHint? = nil) -> EnterRefusal? {
        guard !isActive, !isPrompting else { return .alreadyEditing }
        guard let url = environment.documentURL else { return .noFile }
        let name = url.lastPathComponent
        let path = url.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return .missing(fileName: name) }
        guard fileManager.isReadableFile(atPath: path) else { return .unreadable(fileName: name) }
        guard fileManager.isWritableFile(atPath: path) else { return .readOnly(fileName: name) }
        // Size from the attributes first: a huge file is refused unread.
        if let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           size.intValue > Self.maximumEditableBytes {
            return .tooLarge(fileName: name)
        }
        // Fresh from disk, not the rendered text: the watcher's debounce may lag.
        guard let data = try? Data(contentsOf: url) else { return .unreadable(fileName: name) }
        guard data.count <= Self.maximumEditableBytes else { return .tooLarge(fileName: name) }
        guard let decoded = DocumentFileFormat.decode(data) else { return .unreadable(fileName: name) }
        guard decoded.isLosslessDecode else { return .unsafe(fileName: name) }

        adopt(decoded, bytes: data)
        hasSavedOnce = false
        externalChange = false
        isDirty = false
        if environment.renderedText().map({ Self.isSameText($0, decoded.text) }) ?? false {
            lastCommittedText = decoded.text
        } else {
            commit(decoded.text)
        }
        editor.load(decoded.text)
        installGuardIfNeeded()
        closeGuard?.setEdited(false)
        isActive = true
        if let selection, let range = SourceEditSupport.sourceRange(ofSelection: selection.text,
                                                                    in: decoded.text, lines: selection.lines) {
            // Select, then put the first line at the top WITHOUT moving the
            // caret (`placeCaret` would collapse the selection).
            editor.select(range)
            editor.scroll(toLine: SourceEditSupport.line(containing: range.location, in: decoded.text))
        } else {
            editor.placeCaret(atLine: max(line ?? 0, 0))
        }
        entryLine = editor.caretLine
        return nil
    }

    func focusEditor() {
        editor.focus()
    }

    /// Esc while editing (S-D10): closes the find bar first, then leaves. The
    /// ONE place that decides it — reached from the text view (`onEscape`)
    /// and from the window's key monitor when the focus is elsewhere (a
    /// banner button, a sidebar control, nothing). Esc inside the find bar's
    /// own field never gets here: the bar closes itself.
    func escape() {
        guard isActive else { return }
        if editor.isFindBarVisible {
            editor.hideFind()
        } else {
            requestLeave()
        }
    }

    /// Format, base bytes and saved text always move TOGETHER — from one read
    /// of the disk, or from one successful write.
    private func adopt(_ decoded: DocumentFileFormat.Decoded, bytes: Data) {
        format = decoded.format
        baseBytes = bytes
        savedText = decoded.text
        hasMixedLineEndings = decoded.hasMixedLineEndings
    }

    /// The guard is installed once per window and stays; while the session
    /// is inactive or clean it answers "not dirty" and forwards everything.
    private func installGuardIfNeeded() {
        guard let window else { return }
        if let closeGuard, closeGuard.window === window, !closeGuard.isClosed { return }
        closeGuard = EditCloseGuard.install(on: window, handlers: EditCloseGuard.Handlers(
            isDirty: { [weak self] in self?.checkDirty() ?? false },
            confirm: { [weak self] window, completion in
                guard let self else { return completion(true) }
                self.confirmClose(on: window, completion: completion)
            },
            resolveSynchronously: { [weak self] _ in self?.resolveSynchronously() }
        ))
    }

    // MARK: - Dirty state

    private func bufferDidChange() {
        guard !isApplyingOwnEdit, isActive else { return }
        markDirty()
    }

    /// The exact check: the flag only says "something was typed". Clears the
    /// flag (and the close button's dot) when the buffer is back to the saved
    /// text. Cheap while clean — the comparison runs only once flagged.
    ///
    /// Once flagged it compares the whole buffer: up to tens of ms on a 2 MB
    /// buffer. For a user action (save, leave, close) — anything evaluated
    /// often (menu enabling, a view's `body`) must read the published
    /// `isDirty` and never call this.
    @discardableResult
    func checkDirty() -> Bool {
        guard isActive, isDirty else { return false }
        if bufferMatchesSaved { markClean() }
        return isDirty
    }

    private func markDirty() {
        guard !isDirty else { return }
        isDirty = true
        installGuardIfNeeded()
        closeGuard?.setEdited(true)
    }

    private func markClean() {
        if isDirty { isDirty = false }
        closeGuard?.setEdited(false)
    }

    /// After the session changed the buffer or the saved text: the flag
    /// follows what the buffer really holds. Never "clean" on faith — a
    /// refused `replaceAll` leaves the user's text in place, still unsaved.
    private func syncDirtyWithBuffer() {
        if bufferMatchesSaved { markClean() } else { markDirty() }
    }

    /// Runs `body` (which replaces the buffer through the editor) without the
    /// edit counting as the user's.
    private func replaceBufferAsOwnEdit(_ body: () -> Void) {
        isApplyingOwnEdit = true
        body()
        isApplyingOwnEdit = false
    }

    // MARK: - Prompt chains

    /// Runs one prompt chain unless one is already running (then `completion`
    /// gets false at once). `body` receives the chain's ONLY exit: it ends the
    /// chain and reports the result, once — every path of `body` must call it.
    private func runChain(_ completion: ((Bool) -> Void)?, _ body: (@escaping (Bool) -> Void) -> Void) {
        guard !isPrompting else {
            completion?(false)
            return
        }
        isPrompting = true
        var finished = false
        body { [weak self] result in
            guard !finished else { return }
            finished = true
            self?.isPrompting = false
            completion?(result)
        }
    }

    // MARK: - Saving (S-D7)

    /// ⌘S. Synchronous except for prompts; `then` gets true once the buffer
    /// is on disk (or nothing needed saving) and false on cancel, failure, or
    /// when another prompt is already up — called after the last prompt is
    /// answered.
    func save(then completion: ((Bool) -> Void)? = nil) {
        guard isActive else { completion?(false); return }
        runChain(completion) { finish in
            performSave(window: window, finish: finish)
        }
    }

    /// The save steps, inside a chain. `window` is where every follow-up sheet
    /// goes — the one the chain started on (the guard's `confirm` hands its
    /// own: a sheet elsewhere, or none, would look like a lost confirmation).
    private func performSave(window: NSWindow?, finish: @escaping (Bool) -> Void) {
        guard isActive, environment.documentURL != nil else { return finish(false) }
        let text = editor.text
        // Nothing to write — unless the banner is up: then the disk is not
        // what the buffer holds, and the conflict flow decides.
        if !externalChange && Self.isSameText(text, savedText) {
            markClean()
            return finish(true)
        }
        if let data = format.encode(text) {
            saveCheckingDisk(text: text, data: data, format: format, window: window, finish: finish)
            return
        }
        prompts.encodingFallback(window, fileName, Self.displayName(of: format.encoding)) { [self] useUTF8 in
            guard useUTF8 else { return finish(false) }
            let fallback = format.utf8Fallback
            // UTF-8 represents every String.
            guard let data = fallback.encode(text) else { return finish(false) }
            saveCheckingDisk(text: text, data: data, format: fallback, window: window, finish: finish)
        }
    }

    /// Step 2: the disk must still hold `baseBytes`, or the user decides —
    /// about the version they were shown. Save Anyway re-reads the disk: if
    /// it moved while the prompt was up, the user is asked again about the
    /// NEW version; nothing is ever overwritten (or "restored" over) unseen.
    private func saveCheckingDisk(text: String, data: Data, format target: DocumentFileFormat,
                                  window: NSWindow?, finish: @escaping (Bool) -> Void) {
        guard let url = environment.documentURL else { return finish(false) }
        // Unreadable / missing: nothing to conflict with — the write reports it.
        guard let disk = try? Data(contentsOf: url), disk != baseBytes else {
            return write(text: text, data: data, format: target, restoring: baseBytes,
                         window: window, finish: finish)
        }
        // The disk moved on: the rendered view shows it, the banner says so.
        noteExternalChange(disk)
        prompts.saveConflict(window, fileName) { [self] choice in
            switch choice {
            case .saveAnyway:
                if let now = try? Data(contentsOf: url), now != disk {
                    saveCheckingDisk(text: text, data: data, format: target, window: window, finish: finish)
                    return
                }
                // `baseBytes` stays until the write succeeded; a failed write
                // puts back exactly the version the user agreed to replace.
                write(text: text, data: data, format: target, restoring: disk, window: window, finish: finish)
            case .loadDiskVersion:
                applyDiskVersion()
                finish(false)
            case .cancel:
                finish(false)
            }
        }
    }

    /// Steps 3 and 4.
    private func write(text: String, data: Data, format target: DocumentFileFormat, restoring: Data,
                       window: NSWindow?, finish: @escaping (Bool) -> Void) {
        guard let url = environment.documentURL else { return finish(false) }
        do {
            try DocumentFileWriter.write(data, to: url, restoring: restoring)
        } catch {
            // The buffer stays dirty; the user can keep a copy of it.
            prompts.saveFailed(window, error) { [self] choice in
                guard choice == .saveCopy else { return finish(false) }
                prompts.copyDestination(window, Self.copyName(for: url), url.deletingLastPathComponent()) { [self] destination in
                    if let destination { writeCopy(data, to: destination) }
                    finish(false)
                }
            }
            return
        }
        didSave(text: text, data: data, format: target)
        finish(true)
    }

    private func didSave(text: String, data: Data, format target: DocumentFileFormat) {
        format = target
        baseBytes = data
        savedText = text
        hasSavedOnce = true
        externalChange = false
        let unified = hasMixedLineEndings
        hasMixedLineEndings = false
        commit(text)
        syncDirtyWithBuffer()
        environment.toast(unified ? "Saved · line endings unified to \(Self.displayName(of: target.lineEnding))"
                                  : "Saved")
    }

    /// The disk differs from `baseBytes` (seen by the save check): keep the
    /// rendered text equal to it and show the banner. Base and saved text stay.
    private func noteExternalChange(_ data: Data) {
        guard let decoded = DocumentFileFormat.decode(data) else { return }
        commit(decoded.text)
        externalChange = true
    }

    /// A copy is a new file the save panel granted: a plain (non-atomic)
    /// write. The document itself stays unsaved.
    @discardableResult
    private func writeCopy(_ data: Data, to destination: URL) -> Bool {
        do {
            try data.write(to: destination)
            environment.toast("Copy saved")
            return true
        } catch {
            environment.toast("The copy could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    static func copyName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
    }

    static func displayName(of encoding: DocumentFileFormat.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian, .utf16BigEndian: return "UTF-16"
        case .isoLatin1: return "ISO Latin 1"
        }
    }

    static func displayName(of lineEnding: DocumentFileFormat.LineEnding) -> String {
        switch lineEnding {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    // MARK: - Leaving (S-D10)

    /// Esc, Done, the toggle command. Clean → leaves at once. Dirty → the
    /// unsaved-changes sheet: Save leaves only if the save succeeded, Don't
    /// Save leaves and drops the buffer, Cancel stays. `then(true)` = left;
    /// false also when another prompt is already up.
    func requestLeave(then completion: ((Bool) -> Void)? = nil) {
        guard isActive else { completion?(false); return }
        runChain(completion) { finish in
            guard checkDirty() else {
                leave()
                return finish(true)
            }
            let window = self.window
            prompts.unsavedChanges(window, fileName) { [self] choice in
                switch choice {
                case .save:
                    performSave(window: window) { [self] saved in
                        if saved { leave() }
                        finish(saved)
                    }
                case .discard:
                    leave(discarding: true)
                    finish(true)
                case .cancel:
                    finish(false)
                }
            }
        }
    }

    /// `discarding`: Don't Save — the buffer the caret is in is thrown away,
    /// so its line means nothing for the rendered (saved) text: land only if
    /// something was saved (the list shows that text, not where the reader
    /// left it), and at most on the saved text's last line.
    private func leave(discarding: Bool = false) {
        var line = editor.caretLine
        if discarding {
            line = min(line, SourceEditSupport.lineCount(in: savedText) - 1)
        }
        leaveSequence += 1
        emptyFileRecheck?.cancel()
        emptyFileRecheck = nil
        // A finished session keeps nothing alive: a focus request that never
        // reached a window must not fire on a later mount, and the undo stack
        // (operations holding removed text) goes — the next `enter` loads
        // fresh from disk anyway.
        editor.cancelPendingFocus()
        editor.undoManager.removeAllActions()
        isActive = false
        externalChange = false
        if isDirty { isDirty = false }
        closeGuard?.setEdited(false)
        let shouldLand = discarding ? hasSavedOnce : (hasSavedOnce || line != entryLine)
        lastLeave = LeaveInfo(caretLine: max(line, 0), shouldLand: shouldLand, sequence: leaveSequence)
    }

    /// "Discard Changes": back to the saved text as ONE undoable edit (⌘Z
    /// brings the changes back, and with them the dirty state); stays in the
    /// mode. With the banner up the saved text is no longer what is on disk —
    /// "drop my edits" then means the disk version (`loadDiskVersion`).
    func discardChanges() {
        guard isActive else { return }
        guard !isPrompting else { return Self.beep() }
        if externalChange { return applyDiskVersion() }
        if !bufferMatchesSaved {
            replaceBufferAsOwnEdit { editor.replaceAll(with: savedText) }
        }
        syncDirtyWithBuffer()
    }

    // MARK: - External changes (S-D9)

    /// The view's file watcher fired while the session is active.
    func diskDidChange() {
        emptyFileRecheck?.cancel()
        emptyFileRecheck = nil
        handleDiskChange(adoptingEmpty: false)
    }

    private func handleDiskChange(adoptingEmpty: Bool) {
        guard isActive, let url = environment.documentURL,
              let data = try? Data(contentsOf: url) else { return }
        guard data != baseBytes else {
            // Our own save's echo, a touch — or the file went back to the
            // version the buffer is based on: after a change the banner
            // showed, or after a moment of emptiness (a non-atomic writer
            // re-saving the same content between truncate and write — the ""
            // was committed, the recheck is now cancelled). Either way the
            // rendered text must be the saved text again.
            externalChange = false
            if !(lastCommittedText.map { Self.isSameText($0, savedText) } ?? true) {
                commit(savedText)
            }
            return
        }
        guard let decoded = DocumentFileFormat.decode(data) else { return }
        // Rendered == disk, whatever the buffer holds.
        commit(decoded.text)
        // A prompt is up (its chain is deciding about the buffer), or the
        // buffer holds unsaved text: the banner, never a replaced buffer.
        if isPrompting || checkDirty() {
            externalChange = true
            return
        }
        if let refusal = refusal(forDisk: decoded, bytes: data) {
            // Clean, so nothing is lost; continuing would mean saving a file
            // this session could not have entered.
            leave()
            environment.toast(refusal.message)
            return
        }
        if data.isEmpty && !baseBytes.isEmpty && !adoptingEmpty {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.emptyFileRecheck = nil
                self.handleDiskChange(adoptingEmpty: true)
            }
            emptyFileRecheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + emptyFileRecheckDelay, execute: work)
            return
        }
        adopt(decoded, bytes: data)
        externalChange = false
        editor.reload(decoded.text)
    }

    /// The entry checks that still matter for a file already open.
    private func refusal(forDisk decoded: DocumentFileFormat.Decoded, bytes: Data) -> EnterRefusal? {
        if bytes.count > Self.maximumEditableBytes { return .tooLarge(fileName: fileName) }
        if !decoded.isLosslessDecode { return .unsafe(fileName: fileName) }
        return nil
    }

    /// Reads the disk for a banner action. Nil (after a toast saying why) when
    /// it cannot be read or this session could not have entered it.
    private func readDiskForAdoption() -> (decoded: DocumentFileFormat.Decoded, bytes: Data)? {
        guard let url = environment.documentURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            environment.toast(EnterRefusal.missing(fileName: fileName).message)
            return nil
        }
        guard let data = try? Data(contentsOf: url), let decoded = DocumentFileFormat.decode(data) else {
            environment.toast(EnterRefusal.unreadable(fileName: fileName).message)
            return nil
        }
        if let refusal = refusal(forDisk: decoded, bytes: data) {
            environment.toast(refusal.message)
            return nil
        }
        return (decoded, data)
    }

    /// Banner: "Keep My Version". The disk's current content — bytes, text
    /// AND format — becomes the base: acknowledged, so a later save does not
    /// ask again, and written back in the file's NEW format (a CRLF file git
    /// rewrote as LF stays LF). The buffer is dirty against that text. A disk
    /// that cannot be read or entered keeps the banner (base and saved text
    /// never get out of step).
    func keepMyVersion() {
        guard isActive else { return }
        guard !isPrompting else { return Self.beep() }
        guard let disk = readDiskForAdoption() else { return }
        adopt(disk.decoded, bytes: disk.bytes)
        externalChange = false
        syncDirtyWithBuffer()
    }

    /// Banner: "Load Disk Version". Replaces the buffer as ONE undoable edit
    /// — ⌘Z brings the user's text back, dirty again — and adopts the disk as
    /// the clean state.
    func loadDiskVersion() {
        guard isActive else { return }
        guard !isPrompting else { return Self.beep() }
        applyDiskVersion()
    }

    /// `loadDiskVersion` without the prompt check — also the conflict
    /// prompt's answer, from inside its chain.
    private func applyDiskVersion() {
        guard isActive, let disk = readDiskForAdoption() else { return }
        adopt(disk.decoded, bytes: disk.bytes)
        externalChange = false
        commit(disk.decoded.text)
        if !bufferMatchesSaved {
            replaceBufferAsOwnEdit { editor.replaceAll(with: disk.decoded.text) }
        }
        syncDirtyWithBuffer()
    }

    // MARK: - Close guard (S-D11)

    /// The guard's `confirm`: the unsaved-changes sheet on that window.
    /// `completion(true)` only once clean — saved, or Don't Save reverted the
    /// buffer (also when another tab then cancels the quit and this window
    /// stays open). A close or quit that arrives while one of our prompts is
    /// up (Esc's sheet, a save's) is cancelled with a beep, not queued.
    private func confirmClose(on window: NSWindow, completion: @escaping (Bool) -> Void) {
        guard !isPrompting else {
            Self.beep()
            return completion(false)
        }
        guard checkDirty() else { return completion(true) }
        runChain(completion) { finish in
            prompts.unsavedChanges(window, fileName) { [self] choice in
                switch choice {
                case .save:
                    performSave(window: window, finish: finish)
                case .discard:
                    revertToSaved()
                    finish(true)
                case .cancel:
                    finish(false)
                }
            }
        }
    }

    /// Don't Save on close: the buffer really goes back to the saved text
    /// (not undoable — the window is closing), the caret stays put.
    private func revertToSaved() {
        editor.reload(savedText)
        syncDirtyWithBuffer()
    }

    /// The window is already closing and cannot be kept: app-modal Save /
    /// Don't Save, and Save writes without further questions — UTF-8 if the
    /// encoding cannot hold the text, over a changed disk (the user said
    /// Save), and a copy through an app-modal panel if the write fails.
    private func resolveSynchronously() {
        guard checkDirty(), let url = environment.documentURL else { return }
        guard prompts.unsavedChangesModal(fileName) == .save else { return revertToSaved() }
        let text = editor.text
        let target = format.encode(text) != nil ? format : format.utf8Fallback
        guard let data = target.encode(text) else { return }
        let onDisk = (try? Data(contentsOf: url)) ?? baseBytes
        do {
            try DocumentFileWriter.write(data, to: url, restoring: onDisk)
            didSave(text: text, data: data, format: target)
        } catch {
            // Until a copy is written or the user gives up on the panel.
            while let destination = prompts.copyDestinationModal(Self.copyName(for: url),
                                                                 url.deletingLastPathComponent()) {
                if writeCopy(data, to: destination) { break }
            }
        }
    }
}

// MARK: - Standard prompts

extension SourceEditSession.Prompts {

    static let conflictSaveAnywayIdentifier = "source-conflict-save-anyway"
    static let conflictLoadDiskIdentifier = "source-conflict-load-disk"
    static let conflictCancelIdentifier = "source-conflict-cancel"
    static let encodingUTF8Identifier = "source-encoding-utf8"
    static let encodingCancelIdentifier = "source-encoding-cancel"
    static let saveFailedCopyIdentifier = "source-savefail-copy"
    static let saveFailedOKIdentifier = "source-savefail-ok"
    static let copyPanelIdentifier = "source-copy-panel"

    /// Real sheets on the window, app-modal without one — with the same
    /// buttons either way (the unsaved-changes prompt keeps its Cancel).
    static let standard = SourceEditSession.Prompts(
        unsavedChanges: { window, fileName, completion in
            guard let window else {
                let alert = UnsavedChangesAlert.makeAlert(fileName: fileName, allowsCancel: true)
                return completion(UnsavedChangesAlert.choice(for: alert.runModal()))
            }
            UnsavedChangesAlert.beginSheet(on: window, fileName: fileName, completion: completion)
        },
        unsavedChangesModal: { fileName in
            UnsavedChangesAlert.runModal(fileName: fileName)
        },
        saveConflict: { window, fileName, completion in
            run(makeConflictAlert(fileName: fileName), on: window) { response in
                switch response {
                case .alertFirstButtonReturn: completion(.saveAnyway)
                case .alertSecondButtonReturn: completion(.loadDiskVersion)
                default: completion(.cancel)
                }
            }
        },
        encodingFallback: { window, fileName, encodingName, completion in
            run(makeEncodingAlert(fileName: fileName, encodingName: encodingName), on: window) {
                completion($0 == .alertFirstButtonReturn)
            }
        },
        saveFailed: { window, error, completion in
            let alert = NSAlert()
            alert.alertStyle = .critical
            let localized = error as? LocalizedError
            alert.messageText = localized?.errorDescription ?? error.localizedDescription
            alert.informativeText = [localized?.failureReason, localized?.recoverySuggestion]
                .compactMap { $0 }.joined(separator: "\n\n")
            addButton(to: alert, "Save a Copy…", identifier: saveFailedCopyIdentifier)
            addButton(to: alert, "OK", identifier: saveFailedOKIdentifier, key: "\u{1b}")
            run(alert, on: window) { completion($0 == .alertFirstButtonReturn ? .saveCopy : .ok) }
        },
        copyDestination: { window, suggestedName, directory, completion in
            let panel = copyPanel(suggestedName: suggestedName, directory: directory)
            guard let window else {
                return completion(panel.runModal() == .OK ? panel.url : nil)
            }
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        },
        copyDestinationModal: { suggestedName, directory in
            let panel = copyPanel(suggestedName: suggestedName, directory: directory)
            return panel.runModal() == .OK ? panel.url : nil
        }
    )

    /// Built separately so the tests can check the buttons without a sheet.
    static func makeConflictAlert(fileName: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(fileName)” has been changed by another application."
        alert.informativeText = "Save Anyway replaces the other version with yours. Load Disk Version "
            + "shows the file as it is on disk; Undo brings your text back."
        // No default button: Return must not overwrite another application's
        // changes on reflex. Escape cancels.
        addButton(to: alert, "Save Anyway", identifier: conflictSaveAnywayIdentifier, key: "")
        addButton(to: alert, "Load Disk Version", identifier: conflictLoadDiskIdentifier)
        addButton(to: alert, "Cancel", identifier: conflictCancelIdentifier, key: "\u{1b}")
        return alert
    }

    /// Says nothing about line endings: a mixed file has them unified by the
    /// same save, a uniform one keeps them — one sentence true for both is
    /// the one about the characters.
    static func makeEncodingAlert(fileName: String, encodingName: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(fileName)” uses \(encodingName), which cannot store some of the characters you typed."
        alert.informativeText = "Saving as UTF-8 keeps every character you typed."
        addButton(to: alert, "Save as UTF-8", identifier: encodingUTF8Identifier)
        addButton(to: alert, "Cancel", identifier: encodingCancelIdentifier, key: "\u{1b}")
        return alert
    }

    private static func addButton(to alert: NSAlert, _ title: String, identifier: String, key: String? = nil) {
        let button = alert.addButton(withTitle: title)
        if let key { button.keyEquivalent = key }
        button.setAccessibilityIdentifier(identifier)
    }

    private static func run(_ alert: NSAlert, on window: NSWindow?,
                            completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else { return completion(alert.runModal()) }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    private static func copyPanel(suggestedName: String, directory: URL?) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.identifier = NSUserInterfaceItemIdentifier(copyPanelIdentifier)
        return panel
    }
}
