import AppKit

// MARK: - Edit Close Guard

/// Keeps a document window that holds unsaved source edits from closing (or
/// the app from quitting) without asking the user first.
///
/// The app is `DocumentGroup(viewing:)`: the window's delegate is SwiftUI's own
/// controller and the window sits on a SwiftUI-owned NSDocument that
/// autosaves in place. That NSDocument must NEVER become edited — AppKit would
/// autosave the ORIGINAL text over the file — so the guard never touches
/// `updateChangeCount` or `window.undoManager`. Instead it sits in front of the
/// original delegate as a forwarding proxy: it answers `windowShouldClose` and
/// `windowWillClose` itself and hands every other delegate message to the
/// original (`responds(to:)` + `forwardingTarget(for:)`). Measured on macOS 27:
/// the proxy stays installed, `isDocumentEdited` sticks, and the red close
/// button, `performClose` and the tab's close button all reach
/// `windowShouldClose` before AppKit's document close machinery.
///
/// Because the NSDocument stays clean, AppKit also does not know the app holds
/// unsaved text: the guard disables automatic termination itself while dirty
/// (Info.plist has `NSSupportsAutomaticTermination`, which would otherwise let
/// the system kill a hidden app without asking `applicationShouldTerminate`).
///
/// The guard knows nothing about the editor: the edit session supplies
/// `Handlers` (dirty check, the confirmation sheet, a synchronous last resort).
///
/// Main-thread by convention, without an explicit `@MainActor` annotation — the
/// SwiftUI view code that installs and drives this is nonisolated on older
/// SDKs (CI) and an isolated call there is a hard compile error. (Newer SDKs
/// may infer main-actor isolation from the NSWindowDelegate conformance; what
/// matters is that we do not ADD one and that every call site is main-thread.)
/// Same reasoning as `FileWatcher`.
final class EditCloseGuard: NSObject, NSWindowDelegate {

    /// Supplied by the window's edit session.
    ///
    /// Contract for the session:
    /// - The closures capture the session WEAKLY, and the session does not hold
    ///   the window strongly: window → guard → handlers → session → window
    ///   would keep every closed document alive.
    /// - The guard treats "a sheet is attached" as "confirmation in progress"
    ///   and assumes nothing else. So: a sheet stays attached to the window
    ///   from the moment `confirm` is called until `completion` is called; any
    ///   follow-up sheet (save conflict, save error, save panel) is begun
    ///   synchronously inside the previous sheet's completion handler; saving
    ///   is synchronous. "Confirming but no sheet attached" is treated as a
    ///   lost confirmation and replaced by a fresh one.
    /// - `confirm` calls `completion(true)` only once `isDirty()` already
    ///   returns false — the save succeeded, or Don't Save really reverted the
    ///   buffer — in the quit path too. Debug builds assert this.
    struct Handlers {
        /// True while the session holds text that is not on disk.
        var isDirty: () -> Bool
        /// Ask the user (a sheet on the window). `completion(true)` = saved or
        /// discarded, the window may close; `false` = cancelled or the save
        /// failed. The guard never starts a second one while a sheet is up.
        var confirm: (NSWindow, @escaping (Bool) -> Void) -> Void
        /// Last resort when the window is already closing and cannot be kept:
        /// must return only after the text was saved or discarded (no Cancel).
        var resolveSynchronously: (NSWindow) -> Void
    }

    // MARK: Injection points (tests replace these; the app never does)

    /// Whether a sheet is attached to the window.
    static var hasAttachedSheet: (NSWindow) -> Bool = { $0.attachedSheet != nil }
    /// The window a sheet is attached to (nil for a normal window).
    static var sheetParent: (NSWindow) -> NSWindow? = { $0.sheetParent }
    static var disableAutomaticTermination: (String) -> Void = {
        ProcessInfo.processInfo.disableAutomaticTermination($0)
    }
    static var enableAutomaticTermination: (String) -> Void = {
        ProcessInfo.processInfo.enableAutomaticTermination($0)
    }
    static let automaticTerminationReason = "Unsaved source edits"
    #if DEBUG
    /// Reports a broken `Handlers` contract (tests record instead of trapping).
    static var contractViolation: (String) -> Void = { assertionFailure($0) }
    #endif

    // MARK: State

    /// Weak like `NSWindow.delegate` itself; the window retains the guard.
    private(set) weak var window: NSWindow?
    /// The delegate the guard replaced (SwiftUI's controller in the app).
    private(set) weak var original: NSWindowDelegate?
    private(set) var handlers: Handlers

    /// A `confirm` was started and has not completed. Only a pending
    /// confirmation with a sheet attached blocks a new one (`isConfirmationPending`).
    private(set) var isConfirming = false
    /// Identifies the current confirmation, so a completion from a confirmation
    /// that was given up on (sheet gone without completing) is ignored.
    private var confirmationGeneration = 0
    /// The user answered Save / Don't Save. Lives only for the close or quit
    /// step that follows (cleared on the next main-queue turn): a confirmed
    /// close must not trip the willClose fallback, and the immediate re-entry
    /// of a quit must not ask again — but a later close of a window that
    /// stayed open must ask again.
    private(set) var isResolved = false
    /// The window has closed; the guard is out of the delegate chain and the
    /// review registry.
    private(set) var isClosed = false
    /// Mirrors whether this guard currently holds an automatic-termination
    /// disable, so enable/disable stay strictly balanced.
    private(set) var disablesAutomaticTermination = false
    private var willCloseObserver: NSObjectProtocol?

    private static var associationKey: UInt8 = 0

    /// Every guard installed and not yet closed, held weakly — the quit review
    /// enumerates these without keeping windows (or guards) alive.
    private static var registry: [WeakGuard] = []
    private struct WeakGuard { weak var value: EditCloseGuard? }

    private init(window: NSWindow, handlers: Handlers) {
        self.window = window
        self.handlers = handlers
        super.init()
    }

    deinit {
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
        }
        if disablesAutomaticTermination {
            Self.enableAutomaticTermination(Self.automaticTerminationReason)
        }
    }

    // MARK: - Installation

    /// Installs the guard as `window.delegate` (once per window; a second call
    /// replaces the handlers, resets the per-operation state and returns the
    /// same guard). The window retains the guard through an associated object,
    /// so it lives exactly as long as the window.
    ///
    /// A guard whose window already closed is out of the delegate chain for
    /// good; if the same NSWindow is shown again (`isReleasedWhenClosed ==
    /// false`), a fresh guard replaces it — reusing the closed one would make
    /// every later close silent.
    @discardableResult
    static func install(on window: NSWindow, handlers: Handlers) -> EditCloseGuard {
        if let existing = guardFor(window), !existing.isClosed {
            existing.handlers = handlers
            // A sheet on screen keeps its latch and generation: its answer
            // must still land, and ⌘W must not start a second sheet.
            if !existing.isConfirmationPending {
                existing.isResolved = false
                existing.isConfirming = false
                existing.confirmationGeneration += 1
            }
            existing.reattachIfReplaced()
            return existing
        }
        let closeGuard = EditCloseGuard(window: window, handlers: handlers)
        objc_setAssociatedObject(window, &associationKey, closeGuard, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        closeGuard.original = window.delegate
        window.delegate = closeGuard
        // Backstop for a window whose delegate was replaced behind our back:
        // the willClose fallback must still run. Synchronous (queue nil) so it
        // runs before the window is gone. It never touches the delegate — if
        // it ran before the delegate's own willClose registration, swapping the
        // delegate here would make the original miss `windowWillClose`
        // (measured: the swapped-in delegate is not called for the post in
        // flight, the swapped-out one is skipped).
        closeGuard.willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak closeGuard] _ in
            closeGuard?.windowIsClosing()
        }
        registry.removeAll { $0.value == nil }
        registry.append(WeakGuard(value: closeGuard))
        return closeGuard
    }

    static func guardFor(_ window: NSWindow) -> EditCloseGuard? {
        objc_getAssociatedObject(window, &associationKey) as? EditCloseGuard
    }

    /// Guards of open windows, in installation order.
    static func liveGuards() -> [EditCloseGuard] {
        registry.removeAll { $0.value == nil }
        return registry.compactMap(\.value).filter { $0.window != nil && !$0.isClosed }
    }

    /// Open windows whose edits are unresolved — the quit review walks this list.
    static func guardsNeedingReview() -> [EditCloseGuard] {
        liveGuards().filter(\.needsReview)
    }

    /// Unsaved edits the user has not yet answered for.
    var needsReview: Bool {
        !isClosed && !isResolved && handlers.isDirty()
    }

    /// A confirmation sheet is actually on screen for this window.
    var isConfirmationPending: Bool {
        guard isConfirming, let window else { return false }
        return Self.hasAttachedSheet(window)
    }

    /// Mirrors the session's dirty flag to the close button's dot and to the
    /// app's automatic-termination state. Nothing NSDocument-related is
    /// involved (see the type comment). Also the natural moment to check the
    /// guard is still the delegate: if something replaced it, that object
    /// becomes the new `original` and the guard re-installs.
    func setEdited(_ edited: Bool) {
        guard !isClosed else { return }
        if edited { isResolved = false }
        reattachIfReplaced()
        window?.isDocumentEdited = edited
        if edited && !disablesAutomaticTermination {
            disablesAutomaticTermination = true
            Self.disableAutomaticTermination(Self.automaticTerminationReason)
        } else if !edited && disablesAutomaticTermination {
            disablesAutomaticTermination = false
            Self.enableAutomaticTermination(Self.automaticTerminationReason)
        }
    }

    private func reattachIfReplaced() {
        guard let window, window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    // MARK: - Forwarding

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard needsReview else {
            return original?.windowShouldClose?(sender) ?? true
        }
        // After Save / Don't Save the window closes with `close()` without
        // asking `original.windowShouldClose` again — fine for SwiftUI's
        // controller, which has no veto of its own for a clean viewer document.
        beginConfirmation { [weak sender] confirmed in
            if confirmed { sender?.close() }
        }
        return false
    }

    /// Implemented here rather than only forwarded: if the original is already
    /// gone, a forwarded `windowWillClose:` has no target and AppKit raises
    /// "unrecognized selector" (measured). Resolve first (the window is still
    /// whole), then let the original clean up, then leave the delegate chain.
    func windowWillClose(_ notification: Notification) {
        windowIsClosing()
        original?.windowWillClose?(notification)
        guard let window, window.delegate === self else { return }
        // Swapping now is safe: the delegate set for this post was already
        // called (it is us), and the new one is not called for it again.
        window.delegate = original
    }

    /// What a close request (Close command, banner button) should do. A sheet
    /// window is never the target: ⌘W while the unsaved-changes sheet is up
    /// must not close the SHEET (its completion would never fire) — the
    /// request goes to the sheet's parent.
    enum CloseRequest: Equatable {
        case ignore
        /// The target's confirmation sheet is already up — beep, do nothing.
        case busy(NSWindow)
        case confirm(NSWindow)
        case close(NSWindow)
    }

    static func closeRequest(for window: NSWindow?) -> CloseRequest {
        guard let window else { return .ignore }
        let target = sheetParent(window) ?? window
        if let closeGuard = guardFor(target), closeGuard.needsReview {
            return closeGuard.isConfirmationPending ? .busy(target) : .confirm(target)
        }
        // Clean or unguarded: exactly what ⌘W did before (`close()` on the
        // key window, even if that is a foreign sheet).
        return .close(window)
    }

    /// The app's own Close command and the missing-file banner call this
    /// instead of `close()`, which never consults the delegate. A clean (or
    /// unguarded) window closes exactly as before — `close()`, not
    /// `performClose`, which needs an enabled close button and would change
    /// what a clean ⌘W does today.
    static func requestClose(_ window: NSWindow?) {
        switch closeRequest(for: window) {
        case .ignore:
            break
        case .busy:
            NSSound.beep()
        case .confirm(let target):
            guardFor(target)?.beginConfirmation { [weak target] confirmed in
                if confirmed { target?.close() }
            }
        case .close(let window):
            window.close()
        }
    }

    /// Runs `handlers.confirm` unless one is already on screen. A latch whose
    /// sheet is gone without a completion is stale: it is replaced by a fresh
    /// confirmation and the old completion, if it ever comes, is ignored.
    /// `then` receives the user's answer; a positive answer marks the edits
    /// resolved for the duration of the close/quit step it triggers.
    fileprivate func beginConfirmation(then: @escaping (Bool) -> Void) {
        guard let window, !isClosed, !isConfirmationPending else { return }
        isConfirming = true
        confirmationGeneration += 1
        let generation = confirmationGeneration
        handlers.confirm(window) { [weak self] confirmed in
            guard let self, self.isConfirming, generation == self.confirmationGeneration else { return }
            self.isConfirming = false
            guard confirmed else {
                then(false)
                return
            }
            #if DEBUG
            if self.handlers.isDirty() {
                Self.contractViolation("EditCloseGuard: confirm reported true while the session is still dirty")
            }
            #endif
            self.isResolved = true
            then(true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.isResolved = false
            }
        }
    }

    /// The window is closing (delegate callback or the notification backstop,
    /// whichever comes first; runs once). If edits are still unresolved, some
    /// path closed the window without asking the delegate (other macOS
    /// versions were not probed) — it cannot be kept, so resolve synchronously:
    /// never lose text silently. Then leave the review registry and give back
    /// the automatic-termination disable.
    private func windowIsClosing() {
        guard !isClosed else { return }
        if let window, needsReview {
            handlers.resolveSynchronously(window)
        }
        isClosed = true
        isConfirming = false
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
            self.willCloseObserver = nil
        }
        if disablesAutomaticTermination {
            disablesAutomaticTermination = false
            Self.enableAutomaticTermination(Self.automaticTerminationReason)
        }
        Self.registry.removeAll { $0.value == nil || $0.value === self }
    }
}

// MARK: - Unsaved Changes Alert

/// The standard macOS unsaved-changes prompt, built once so the edit session
/// only wires callbacks. The sheet has Save (default, Return), Don't Save,
/// Cancel (Escape); the app-modal variant — used when the window is already
/// closing and cannot be kept — has no Cancel.
enum UnsavedChangesAlert {

    enum Choice: Equatable {
        case save, discard, cancel
    }

    static let saveIdentifier = "source-unsaved-save"
    static let discardIdentifier = "source-unsaved-discard"
    static let cancelIdentifier = "source-unsaved-cancel"

    static func makeAlert(fileName: String, allowsCancel: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to “\(fileName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."

        let save = alert.addButton(withTitle: "Save")
        save.keyEquivalent = "\r"
        save.setAccessibilityIdentifier(saveIdentifier)

        let discard = alert.addButton(withTitle: "Don’t Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = [.command]
        discard.setAccessibilityIdentifier(discardIdentifier)

        if allowsCancel {
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\u{1b}"
            cancel.setAccessibilityIdentifier(cancelIdentifier)
        }
        return alert
    }

    /// Maps the button order of `makeAlert` (Save, Don't Save, Cancel).
    static func choice(for response: NSApplication.ModalResponse) -> Choice {
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// The no-Cancel variant: only an explicit Don't Save click discards. Any
    /// other response (abort / stop from outside the alert) saves — text is
    /// never thrown away without the user asking for it.
    static func modalChoice(for response: NSApplication.ModalResponse) -> Choice {
        response == .alertSecondButtonReturn ? .discard : .save
    }

    /// Window-modal sheet with Cancel.
    static func beginSheet(on window: NSWindow, fileName: String,
                           completion: @escaping (Choice) -> Void) {
        let alert = makeAlert(fileName: fileName, allowsCancel: true)
        alert.beginSheetModal(for: window) { response in
            completion(choice(for: response))
        }
    }

    /// App-modal, Save / Don't Save only — for the willClose fallback, where
    /// the window is going away regardless. Returns `.save` or `.discard`.
    static func runModal(fileName: String) -> Choice {
        let alert = makeAlert(fileName: fileName, allowsCancel: false)
        return modalChoice(for: alert.runModal())
    }
}

// MARK: - App Delegate

/// `@NSApplicationDelegateAdaptor` target: reviews unsaved source edits before
/// the app quits. One dirty window at a time — cancel the quit, bring the
/// window forward, show its sheet, and ask to terminate again once the user
/// answered; the next round handles the next window or quits. Cancel (or a
/// failed save) ends the quit.
///
/// `.terminateCancel` + terminate-again rather than `.terminateLater`: the
/// prototype verified this flow, while `.terminateLater` runs the app in the
/// modal-panel run-loop mode until `reply(toApplicationShouldTerminate:)`,
/// which has not been tested with the save flow. Known cost: a logout or
/// restart that asked us to quit is interrupted (the user starts it again)
/// instead of resumed.
final class QuickMDAppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.reviewBeforeQuit(
            EditCloseGuard.guardsNeedingReview(),
            bringForward: Self.present,
            terminateAgain: { NSApp.terminate(nil) }
        )
    }

    /// The quit decision, separated from NSApp so it can be tested without
    /// terminating anything.
    static func reviewBeforeQuit(_ pending: [EditCloseGuard],
                                 bringForward: (NSWindow) -> Void,
                                 terminateAgain: @escaping () -> Void) -> NSApplication.TerminateReply {
        // Intended: a quit that arrives while a close confirmation is already
        // on screen only cancels and shows that sheet. Its answer closes the
        // window; nothing is queued to resume the quit.
        if let busy = pending.first(where: \.isConfirmationPending), let window = busy.window {
            bringForward(window)
            return .terminateCancel
        }
        guard let first = pending.first, let window = first.window else { return .terminateNow }
        bringForward(window)
        first.beginConfirmation { confirmed in
            if confirmed { terminateAgain() }
        }
        return .terminateCancel
    }

    /// The window may be minimised, the app hidden or in the background (quit
    /// from the Dock or a logout): the sheet must be where the user looks.
    static func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
