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
    /// our last save, or as acknowledged by the user (Keep My Version / Save
    /// Anyway). A disk that differs from these was changed by someone else.
    private(set) var baseBytes = Data()
    /// The LF text matching `baseBytes` — the clean state of the buffer.
    private(set) var savedText = ""
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

    init() {
        editor.onChange = { [weak self] in self?.bufferDidChange() }
        editor.onEscape = { [weak self] in self?.requestLeave() }
    }

    private var fileName: String {
        environment.documentURL?.lastPathComponent ?? "Untitled"
    }

    private var window: NSWindow? {
        environment.window() ?? editor.textView.window
    }

    /// Enters the editor with the caret at the start of 0-based `line` (nil:
    /// the top), scrolled to the top of the visible area — the view converts
    /// the reading position's 1-based `editorLine()`. Returns nil when it
    /// entered; otherwise nothing changed and the refusal says why.
    /// The view requests focus after mounting the editor (`focusEditor`).
    @discardableResult
    func enter(atLine line: Int?) -> EnterRefusal? {
        guard !isActive else { return .alreadyEditing }
        guard let url = environment.documentURL else { return .noFile }
        let name = url.lastPathComponent
        let path = url.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return .missing(fileName: name) }
        if let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           size.intValue > Self.maximumEditableBytes {
            return .tooLarge(fileName: name)
        }
        guard fileManager.isWritableFile(atPath: path) else { return .readOnly(fileName: name) }
        // Fresh from disk, not the rendered text: the watcher's debounce may lag.
        guard let data = try? Data(contentsOf: url) else { return .unreadable(fileName: name) }
        guard data.count <= Self.maximumEditableBytes else { return .tooLarge(fileName: name) }
        guard let decoded = DocumentFileFormat.decode(data) else { return .unreadable(fileName: name) }
        guard decoded.isByteExact || decoded.hasMixedLineEndings else { return .unsafe(fileName: name) }

        adopt(decoded, bytes: data)
        hasSavedOnce = false
        externalChange = false
        isDirty = false
        if environment.renderedText() != decoded.text {
            environment.commitText(decoded.text)
        }
        editor.load(decoded.text)
        installGuardIfNeeded()
        closeGuard?.setEdited(false)
        isActive = true
        editor.placeCaret(atLine: max(line ?? 0, 0))
        entryLine = editor.caretLine
        return nil
    }

    func focusEditor() {
        editor.focus()
    }

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
        guard !isApplyingOwnEdit, isActive, !isDirty else { return }
        isDirty = true
        installGuardIfNeeded()
        closeGuard?.setEdited(true)
    }

    /// The exact check: the flag only says "something was typed". Clears the
    /// flag (and the close button's dot) when the buffer is back to the saved
    /// text. Cheap while clean — the comparison runs only once flagged.
    @discardableResult
    func checkDirty() -> Bool {
        guard isActive, isDirty else { return false }
        if editor.text == savedText { setClean() }
        return isDirty
    }

    private func setClean() {
        if isDirty { isDirty = false }
        closeGuard?.setEdited(false)
    }

    /// Runs `body` (which replaces the buffer through the editor) without the
    /// edit counting as the user's, then ends clean.
    private func replaceBufferAsOwnEdit(_ body: () -> Void) {
        isApplyingOwnEdit = true
        body()
        isApplyingOwnEdit = false
    }

    // MARK: - Saving (S-D7)

    /// ⌘S. Synchronous except for prompts; `then` gets true once the buffer
    /// is on disk (or nothing needed saving) and false on cancel or failure —
    /// called after the last prompt is answered.
    func save(then completion: ((Bool) -> Void)? = nil) {
        let finish: (Bool) -> Void = { completion?($0) }
        guard isActive, environment.documentURL != nil else { return finish(false) }
        let text = editor.text
        guard text != savedText else {
            // Nothing to write: no mtime change, no watcher echo.
            setClean()
            return finish(true)
        }
        if let data = format.encode(text) {
            saveCheckingDisk(text: text, data: data, format: format, finish: finish)
            return
        }
        prompts.encodingFallback(window, fileName, Self.displayName(of: format.encoding)) { [self] useUTF8 in
            guard useUTF8 else { return finish(false) }
            let fallback = format.utf8Fallback
            // UTF-8 represents every String.
            guard let data = fallback.encode(text) else { return finish(false) }
            saveCheckingDisk(text: text, data: data, format: fallback, finish: finish)
        }
    }

    /// Step 2: the disk must still hold `baseBytes`, or the user decides.
    private func saveCheckingDisk(text: String, data: Data, format target: DocumentFileFormat,
                                  finish: @escaping (Bool) -> Void) {
        guard let url = environment.documentURL else { return finish(false) }
        // Unreadable / missing: nothing to conflict with — the write reports it.
        guard let disk = try? Data(contentsOf: url), disk != baseBytes else {
            return write(text: text, data: data, format: target, restoring: baseBytes, finish: finish)
        }
        prompts.saveConflict(window, fileName) { [self] choice in
            switch choice {
            case .saveAnyway:
                // The user saw the conflict and chose their text: what is on
                // disk now is what a failed write puts back.
                baseBytes = disk
                write(text: text, data: data, format: target, restoring: disk, finish: finish)
            case .loadDiskVersion:
                loadDiskVersion()
                finish(false)
            case .cancel:
                finish(false)
            }
        }
    }

    /// Steps 3 and 4.
    private func write(text: String, data: Data, format target: DocumentFileFormat, restoring: Data,
                       finish: @escaping (Bool) -> Void) {
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
        environment.commitText(text)
        if editor.text == text { setClean() }
        environment.toast(unified ? "Saved · line endings unified to \(Self.displayName(of: target.lineEnding))"
                                  : "Saved")
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
    /// Save leaves and drops the buffer, Cancel stays. `then(true)` = left.
    func requestLeave(then completion: ((Bool) -> Void)? = nil) {
        guard isActive else { completion?(false); return }
        guard checkDirty() else {
            leave()
            completion?(true)
            return
        }
        prompts.unsavedChanges(window, fileName) { [self] choice in
            switch choice {
            case .save:
                save { [self] saved in
                    if saved { leave() }
                    completion?(saved)
                }
            case .discard:
                leave()
                completion?(true)
            case .cancel:
                completion?(false)
            }
        }
    }

    private func leave() {
        let line = editor.caretLine
        leaveSequence += 1
        isActive = false
        externalChange = false
        if isDirty { isDirty = false }
        closeGuard?.setEdited(false)
        lastLeave = LeaveInfo(caretLine: line, shouldLand: hasSavedOnce || line != entryLine,
                              sequence: leaveSequence)
    }

    /// "Discard Changes": back to the saved text as ONE undoable edit (⌘Z
    /// brings the changes back, and with them the dirty state); stays in the mode.
    func discardChanges() {
        guard isActive else { return }
        if editor.text != savedText {
            replaceBufferAsOwnEdit { editor.replaceAll(with: savedText) }
        }
        setClean()
    }

    // MARK: - External changes (S-D9)

    /// The view's file watcher fired while the session is active.
    func diskDidChange() {
        guard isActive, let url = environment.documentURL,
              let data = try? Data(contentsOf: url) else { return }
        guard data != baseBytes else {
            // Our own save's echo, a touch — or the file went back to the
            // version the buffer is based on, after a change the banner showed.
            if externalChange {
                externalChange = false
                environment.commitText(savedText)
            }
            return
        }
        guard let decoded = DocumentFileFormat.decode(data) else { return }
        // Rendered == disk, whatever the buffer holds.
        environment.commitText(decoded.text)
        guard !checkDirty() else {
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
        adopt(decoded, bytes: data)
        editor.reload(decoded.text)
    }

    /// The entry checks that still matter for a file already open.
    private func refusal(forDisk decoded: DocumentFileFormat.Decoded, bytes: Data) -> EnterRefusal? {
        if bytes.count > Self.maximumEditableBytes { return .tooLarge(fileName: fileName) }
        if !decoded.isByteExact && !decoded.hasMixedLineEndings { return .unsafe(fileName: fileName) }
        return nil
    }

    /// Banner: "Keep My Version". The disk's current bytes become the base —
    /// acknowledged, so a later save does not ask again — and the buffer is
    /// dirty against THAT text (it is what is on disk now).
    func keepMyVersion() {
        guard isActive else { return }
        externalChange = false
        guard let url = environment.documentURL, let data = try? Data(contentsOf: url) else { return }
        baseBytes = data
        if let decoded = DocumentFileFormat.decode(data) {
            savedText = decoded.text
            hasMixedLineEndings = decoded.hasMixedLineEndings
        }
        if editor.text == savedText {
            setClean()
        } else if !isDirty {
            isDirty = true
            closeGuard?.setEdited(true)
        }
    }

    /// Banner (and conflict prompt): "Load Disk Version". Replaces the buffer
    /// as ONE undoable edit — ⌘Z brings the user's text back, dirty again —
    /// and adopts the disk as the clean state.
    func loadDiskVersion() {
        guard isActive, let url = environment.documentURL else { return }
        guard let data = try? Data(contentsOf: url), let decoded = DocumentFileFormat.decode(data) else {
            environment.toast(EnterRefusal.unreadable(fileName: fileName).message)
            return
        }
        if let refusal = refusal(forDisk: decoded, bytes: data) {
            // Keep the user's text; Keep My Version / Save still work.
            environment.toast(refusal.message)
            return
        }
        adopt(decoded, bytes: data)
        externalChange = false
        environment.commitText(decoded.text)
        if editor.text != decoded.text {
            replaceBufferAsOwnEdit { editor.replaceAll(with: decoded.text) }
        }
        setClean()
    }

    // MARK: - Close guard (S-D11)

    /// The guard's `confirm`: the unsaved-changes sheet on that window.
    /// `completion(true)` only once clean — saved, or Don't Save reverted the
    /// buffer (also when another tab then cancels the quit and this window
    /// stays open).
    private func confirmClose(on window: NSWindow, completion: @escaping (Bool) -> Void) {
        guard checkDirty() else { return completion(true) }
        prompts.unsavedChanges(window, fileName) { [self] choice in
            switch choice {
            case .save:
                save { completion($0) }
            case .discard:
                revertToSaved()
                completion(true)
            case .cancel:
                completion(false)
            }
        }
    }

    /// Don't Save on close: the buffer really goes back to the saved text
    /// (not undoable — the window is closing), the caret stays put.
    private func revertToSaved() {
        editor.reload(savedText)
        setClean()
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

    /// Real sheets on the window, app-modal without one.
    static let standard = SourceEditSession.Prompts(
        unsavedChanges: { window, fileName, completion in
            guard let window else { return completion(UnsavedChangesAlert.runModal(fileName: fileName)) }
            UnsavedChangesAlert.beginSheet(on: window, fileName: fileName, completion: completion)
        },
        unsavedChangesModal: { fileName in
            UnsavedChangesAlert.runModal(fileName: fileName)
        },
        saveConflict: { window, fileName, completion in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(fileName)” has been changed by another application."
            alert.informativeText = "Save Anyway replaces the other version with yours. Load Disk Version "
                + "shows the file as it is on disk; Undo brings your text back."
            addButton(to: alert, "Save Anyway", identifier: conflictSaveAnywayIdentifier)
            addButton(to: alert, "Load Disk Version", identifier: conflictLoadDiskIdentifier)
            addButton(to: alert, "Cancel", identifier: conflictCancelIdentifier, key: "\u{1b}")
            run(alert, on: window) { response in
                switch response {
                case .alertFirstButtonReturn: completion(.saveAnyway)
                case .alertSecondButtonReturn: completion(.loadDiskVersion)
                default: completion(.cancel)
                }
            }
        },
        encodingFallback: { window, fileName, encodingName, completion in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(fileName)” uses \(encodingName), which cannot store some of the characters you typed."
            alert.informativeText = "Saving as UTF-8 keeps every character. The line endings stay as they are."
            addButton(to: alert, "Save as UTF-8", identifier: encodingUTF8Identifier)
            addButton(to: alert, "Cancel", identifier: encodingCancelIdentifier, key: "\u{1b}")
            run(alert, on: window) { completion($0 == .alertFirstButtonReturn) }
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
