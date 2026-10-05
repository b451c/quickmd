import XCTest
import AppKit

/// EditCloseGuard (S-D11) driven headlessly: plain NSWindows that are never
/// ordered on screen, handlers injected as closures, no real sheet (the
/// guard's sheet / automatic-termination hooks are replaced by recorders).
/// What the real red button / tab close button / ⌘Q do with the guard is E2E
/// territory; here we pin the delegate forwarding, the confirm flow, the
/// willClose fallback, the termination bookkeeping and the quit decision.
final class EditCloseGuardTests: XCTestCase {

    /// Records what the guard forwards to the window's original delegate.
    private final class RecordingDelegate: NSObject, NSWindowDelegate {
        var shouldCloseAnswer = true
        var shouldCloseCalls = 0
        var didResizeCalls = 0
        var willCloseCalls = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldCloseCalls += 1
            return shouldCloseAnswer
        }

        func windowDidResize(_ notification: Notification) {
            didResizeCalls += 1
        }

        func windowWillClose(_ notification: Notification) {
            willCloseCalls += 1
        }
    }

    /// Windows that currently show a (fake) confirmation sheet.
    private static var sheetsUp = Set<ObjectIdentifier>()

    /// Scriptable session: dirty flag, captured confirm completions, counters.
    private final class FakeSession {
        var dirty = false
        var confirmCalls = 0
        var resolveCalls = 0
        var pendingCompletion: ((Bool) -> Void)?
        private var sheetWindow: ObjectIdentifier?

        var handlers: EditCloseGuard.Handlers {
            EditCloseGuard.Handlers(
                // Weak: a guard can outlive its test's session (another test's
                // quit review still enumerates it); a gone session is clean.
                isDirty: { [weak self] in self?.dirty ?? false },
                confirm: { [weak self] window, completion in
                    guard let self else { return }
                    self.confirmCalls += 1
                    self.pendingCompletion = completion
                    self.sheetWindow = ObjectIdentifier(window)
                    EditCloseGuardTests.sheetsUp.insert(ObjectIdentifier(window))
                },
                resolveSynchronously: { [weak self] _ in self?.resolveCalls += 1 }
            )
        }

        /// The user clicked a button: the sheet goes away, then the completion.
        func answer(_ confirmed: Bool) {
            dropSheet()
            let completion = pendingCompletion
            pendingCompletion = nil
            completion?(confirmed)
        }

        /// The sheet vanished without its completion ever firing.
        func dropSheet() {
            if let sheetWindow { EditCloseGuardTests.sheetsUp.remove(sheetWindow) }
            sheetWindow = nil
        }
    }

    /// What the injected hooks record. Owned by the test case and captured
    /// WEAKLY by the hooks: a guard from an earlier test that deinits later
    /// (and gives back its termination disable) then calls into nothing
    /// instead of into a dead or unrelated test.
    private final class Recorder {
        var disableCount = 0
        var enableCount = 0
        var contractViolations = 0
        var sheetParents: [ObjectIdentifier: NSWindow] = [:]
    }

    private var recorder = Recorder()
    private var savedHasAttachedSheet: ((NSWindow) -> Bool)!
    private var savedSheetParent: ((NSWindow) -> NSWindow?)!
    private var savedDisable: ((String) -> Void)!
    private var savedEnable: ((String) -> Void)!
    #if DEBUG
    private var savedContractViolation: ((String) -> Void)!
    #endif

    private var disableCount: Int { recorder.disableCount }
    private var enableCount: Int { recorder.enableCount }
    private var contractViolations: Int { recorder.contractViolations }
    private var sheetParents: [ObjectIdentifier: NSWindow] {
        get { recorder.sheetParents }
        set { recorder.sheetParents = newValue }
    }

    override func setUp() {
        super.setUp()
        Self.sheetsUp = []
        recorder = Recorder()
        savedHasAttachedSheet = EditCloseGuard.hasAttachedSheet
        savedSheetParent = EditCloseGuard.sheetParent
        savedDisable = EditCloseGuard.disableAutomaticTermination
        savedEnable = EditCloseGuard.enableAutomaticTermination
        let recorder = recorder
        EditCloseGuard.hasAttachedSheet = { Self.sheetsUp.contains(ObjectIdentifier($0)) }
        EditCloseGuard.sheetParent = { [weak recorder] in recorder?.sheetParents[ObjectIdentifier($0)] }
        EditCloseGuard.disableAutomaticTermination = { [weak recorder] _ in recorder?.disableCount += 1 }
        EditCloseGuard.enableAutomaticTermination = { [weak recorder] _ in recorder?.enableCount += 1 }
        #if DEBUG
        savedContractViolation = EditCloseGuard.contractViolation
        EditCloseGuard.contractViolation = { [weak recorder] _ in recorder?.contractViolations += 1 }
        #endif
    }

    override func tearDown() {
        EditCloseGuard.hasAttachedSheet = savedHasAttachedSheet
        EditCloseGuard.sheetParent = savedSheetParent
        EditCloseGuard.disableAutomaticTermination = savedDisable
        EditCloseGuard.enableAutomaticTermination = savedEnable
        #if DEBUG
        EditCloseGuard.contractViolation = savedContractViolation
        #endif
        Self.sheetsUp = []
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// `windowWillClose` is the observable sign that `close()` ran — the
    /// window is never visible, so `isVisible` cannot tell.
    private func closeCounter(for window: NSWindow) -> () -> Int {
        final class Box { var count = 0; var token: NSObjectProtocol? }
        let box = Box()
        box.token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in box.count += 1 }
        addTeardownBlock { if let token = box.token { NotificationCenter.default.removeObserver(token) } }
        return { box.count }
    }

    /// Lets the guard's next-turn work (clearing `isResolved`) run.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    // MARK: - Installation and forwarding

    func testInstallIsIdempotentAndKeepsOriginal() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let first = FakeSession(), second = FakeSession()

        let installed = EditCloseGuard.install(on: window, handlers: first.handlers)
        let again = EditCloseGuard.install(on: window, handlers: second.handlers)

        XCTAssertTrue(installed === again)
        XCTAssertTrue(EditCloseGuard.guardFor(window) === installed)
        XCTAssertTrue(window.delegate === installed)
        XCTAssertTrue(installed.original === original, "re-install must not adopt the guard itself as original")

        // The second call replaced the handlers.
        second.dirty = true
        XCTAssertFalse(installed.windowShouldClose(window))
        XCTAssertEqual(second.confirmCalls, 1)
        XCTAssertEqual(first.confirmCalls, 0)
    }

    /// Re-install with a latch but no sheet on screen (the session was rebuilt
    /// and its sheet is gone): the per-operation state is reset.
    func testReinstallResetsPendingState() {
        let window = makeWindow()
        let first = FakeSession()
        first.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: first.handlers)
        let closes = closeCounter(for: window)
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertTrue(closeGuard.isConfirming)
        let lostCompletion = first.pendingCompletion
        first.dropSheet()

        let second = FakeSession()
        second.dirty = true
        EditCloseGuard.install(on: window, handlers: second.handlers)
        XCTAssertFalse(closeGuard.isConfirming)
        XCTAssertFalse(closeGuard.isResolved)

        // The superseded confirmation's answer is ignored…
        first.dirty = false
        lostCompletion?(true)
        XCTAssertEqual(closes(), 0)
        // …and the new handlers are asked.
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertEqual(second.confirmCalls, 1)
    }

    /// Re-install while OUR sheet is up only swaps the handlers: the sheet's
    /// answer still lands and ⌘W does not start a second sheet.
    func testReinstallWhileSheetPendingKeepsTheConfirmation() {
        let window = makeWindow()
        let first = FakeSession()
        first.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: first.handlers)
        let closes = closeCounter(for: window)
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertTrue(closeGuard.isConfirmationPending)

        let second = FakeSession()
        second.dirty = true
        EditCloseGuard.install(on: window, handlers: second.handlers)
        XCTAssertTrue(closeGuard.isConfirmationPending)

        EditCloseGuard.requestClose(window)
        XCTAssertEqual(first.confirmCalls + second.confirmCalls, 1, "no second sheet")

        second.dirty = false   // the new handlers' session is the one that saved
        first.answer(true)
        XCTAssertEqual(closes(), 1, "the pending sheet's Save answer is not dropped")
    }

    /// The same NSWindow shown again after a close gets a working guard.
    func testInstallAfterCloseCreatesFreshGuard() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let first = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)
        window.close()
        XCTAssertTrue(first.isClosed)
        XCTAssertTrue(window.delegate === original)

        let session = FakeSession()
        session.dirty = true
        let fresh = EditCloseGuard.install(on: window, handlers: session.handlers)
        XCTAssertFalse(fresh === first)
        XCTAssertFalse(fresh.isClosed)
        XCTAssertTrue(EditCloseGuard.guardFor(window) === fresh)
        XCTAssertTrue(window.delegate === fresh)
        XCTAssertTrue(fresh.original === original)
        XCTAssertTrue(EditCloseGuard.guardsNeedingReview().contains { $0 === fresh })

        XCTAssertFalse(fresh.windowShouldClose(window), "a later dirty close asks")
        XCTAssertEqual(session.confirmCalls, 1)
    }

    func testForwardsUnimplementedDelegateMethodsToOriginal() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let closeGuard = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)

        let didResize = #selector(NSWindowDelegate.windowDidResize(_:))
        let didMiniaturize = #selector(NSWindowDelegate.windowDidMiniaturize(_:))
        XCTAssertTrue(closeGuard.responds(to: didResize), "only the original implements it")
        XCTAssertFalse(closeGuard.responds(to: didMiniaturize), "neither implements it")

        let delegate: NSWindowDelegate = closeGuard
        delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(original.didResizeCalls, 1)
    }

    // MARK: - windowShouldClose

    func testCleanSessionForwardsOriginalAnswer() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let session = FakeSession()
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)

        original.shouldCloseAnswer = true
        XCTAssertTrue(closeGuard.windowShouldClose(window))
        original.shouldCloseAnswer = false
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertEqual(original.shouldCloseCalls, 2)
        XCTAssertEqual(session.confirmCalls, 0)
    }

    func testCleanSessionWithoutOriginalAllowsClose() {
        let window = makeWindow()
        let session = FakeSession()
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        XCTAssertTrue(closeGuard.windowShouldClose(window))
    }

    func testDirtySessionConfirmsAndClosesOnTrue() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        let closes = closeCounter(for: window)

        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertEqual(session.confirmCalls, 1)
        XCTAssertEqual(original.shouldCloseCalls, 0, "a dirty close is not forwarded")
        XCTAssertEqual(closes(), 0)

        session.dirty = false   // the session saved
        session.answer(true)
        XCTAssertEqual(closes(), 1)
        XCTAssertEqual(session.resolveCalls, 0)
        #if DEBUG
        XCTAssertEqual(contractViolations, 0)
        #endif
    }

    func testDirtySessionCancelKeepsWindow() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        let closes = closeCounter(for: window)

        XCTAssertFalse(closeGuard.windowShouldClose(window))
        session.answer(false)
        XCTAssertEqual(closes(), 0)
        XCTAssertFalse(closeGuard.isConfirming)

        // A later request asks again.
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertEqual(session.confirmCalls, 2)
    }

    func testSecondRequestWhilePendingDoesNotConfirmAgain() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)

        XCTAssertFalse(closeGuard.windowShouldClose(window))
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        EditCloseGuard.requestClose(window)
        XCTAssertEqual(session.confirmCalls, 1)
        XCTAssertTrue(closeGuard.isConfirmationPending)
    }

    func testStaleConfirmationLatchHeals() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        let closes = closeCounter(for: window)

        XCTAssertFalse(closeGuard.windowShouldClose(window))
        let lostCompletion = session.pendingCompletion
        session.dropSheet()   // sheet gone, completion never fired
        XCTAssertTrue(closeGuard.isConfirming)
        XCTAssertFalse(closeGuard.isConfirmationPending)

        EditCloseGuard.requestClose(window)
        XCTAssertEqual(session.confirmCalls, 2, "a stale latch starts a fresh confirmation")

        session.dirty = false
        lostCompletion?(true)
        XCTAssertEqual(closes(), 0, "the abandoned confirmation's answer is ignored")
        session.answer(true)
        XCTAssertEqual(closes(), 1)
    }

    // MARK: - requestClose

    func testRequestCloseNilWindowDoesNothing() {
        XCTAssertEqual(EditCloseGuard.closeRequest(for: nil), .ignore)
        EditCloseGuard.requestClose(nil)   // must not crash
    }

    func testRequestCloseWithoutGuardCloses() {
        let window = makeWindow()
        let closes = closeCounter(for: window)
        XCTAssertEqual(EditCloseGuard.closeRequest(for: window), .close(window))
        EditCloseGuard.requestClose(window)
        XCTAssertEqual(closes(), 1)
    }

    func testRequestCloseCleanGuardCloses() {
        let window = makeWindow()
        let session = FakeSession()
        EditCloseGuard.install(on: window, handlers: session.handlers)
        let closes = closeCounter(for: window)

        EditCloseGuard.requestClose(window)
        XCTAssertEqual(closes(), 1)
        XCTAssertEqual(session.confirmCalls, 0)
        XCTAssertEqual(session.resolveCalls, 0)
    }

    func testRequestCloseDirtyGuardConfirms() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        EditCloseGuard.install(on: window, handlers: session.handlers)
        let closes = closeCounter(for: window)

        XCTAssertEqual(EditCloseGuard.closeRequest(for: window), .confirm(window))
        EditCloseGuard.requestClose(window)
        XCTAssertEqual(session.confirmCalls, 1)
        XCTAssertEqual(closes(), 0)
        XCTAssertEqual(EditCloseGuard.closeRequest(for: window), .busy(window))

        session.answer(false)
        XCTAssertEqual(closes(), 0)

        EditCloseGuard.requestClose(window)
        session.dirty = false
        session.answer(true)
        XCTAssertEqual(closes(), 1)
    }

    /// ⌘W while the sheet is up: the key window is the SHEET. The request must
    /// target the parent and never close the sheet.
    func testCloseRequestFromSheetTargetsParent() {
        let parent = makeWindow(), sheet = makeWindow()
        sheetParents[ObjectIdentifier(sheet)] = parent
        let session = FakeSession()
        session.dirty = true
        EditCloseGuard.install(on: parent, handlers: session.handlers)
        let sheetCloses = closeCounter(for: sheet)
        let parentCloses = closeCounter(for: parent)

        XCTAssertEqual(EditCloseGuard.closeRequest(for: sheet), .confirm(parent))
        EditCloseGuard.requestClose(sheet)
        XCTAssertEqual(session.confirmCalls, 1)

        XCTAssertEqual(EditCloseGuard.closeRequest(for: sheet), .busy(parent))
        EditCloseGuard.requestClose(sheet)   // beeps
        XCTAssertEqual(session.confirmCalls, 1)
        XCTAssertEqual(sheetCloses(), 0)
        XCTAssertEqual(parentCloses(), 0)

        session.dirty = false
        session.answer(true)
        XCTAssertEqual(parentCloses(), 1)
    }

    func testCloseRequestFromSheetOfCleanWindowKeepsTodaysBehaviour() {
        let parent = makeWindow(), sheet = makeWindow()
        sheetParents[ObjectIdentifier(sheet)] = parent
        EditCloseGuard.install(on: parent, handlers: FakeSession().handlers)
        XCTAssertEqual(EditCloseGuard.closeRequest(for: sheet), .close(sheet))
    }

    // MARK: - willClose fallback and leaving the chain

    func testWillCloseWhileDirtyResolvesExactlyOnce() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        EditCloseGuard.install(on: window, handlers: session.handlers)

        window.close()   // bypasses the delegate, like NSApp.keyWindow?.close() did
        XCTAssertEqual(session.resolveCalls, 1)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(session.resolveCalls, 1)
    }

    func testWillCloseAfterConfirmedCloseDoesNotResolve() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        let closes = closeCounter(for: window)

        XCTAssertFalse(closeGuard.windowShouldClose(window))
        // Even if the session (wrongly) still reports dirty after "Don't
        // Save", the confirmed close must not prompt a second time.
        session.answer(true)
        XCTAssertEqual(closes(), 1)
        XCTAssertEqual(session.resolveCalls, 0)
        #if DEBUG
        XCTAssertEqual(contractViolations, 1, "debug builds flag the broken contract")
        #endif
    }

    func testWillCloseWhileCleanDoesNotResolve() {
        let window = makeWindow()
        let session = FakeSession()
        EditCloseGuard.install(on: window, handlers: session.handlers)
        window.close()
        XCTAssertEqual(session.resolveCalls, 0)
    }

    func testCloseRestoresOriginalDelegateAndLeavesRegistry() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        XCTAssertTrue(EditCloseGuard.liveGuards().contains { $0 === closeGuard })

        window.close()

        XCTAssertTrue(window.delegate === original)
        XCTAssertEqual(original.willCloseCalls, 1, "the original still sees windowWillClose, once")
        XCTAssertTrue(closeGuard.isClosed)
        XCTAssertFalse(EditCloseGuard.liveGuards().contains { $0 === closeGuard })
        XCTAssertFalse(EditCloseGuard.guardsNeedingReview().contains { $0 === closeGuard },
                       "a closed but still alive window is never reviewed")
    }

    /// Delegate re-installed by setEdited → the delegate's notification
    /// registration now comes after the guard's backstop observer. The
    /// original must still get windowWillClose exactly once.
    func testCloseAfterReattachStillDeliversWillCloseOnce() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let closeGuard = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)
        let replacement = RecordingDelegate()
        window.delegate = replacement
        closeGuard.setEdited(false)
        XCTAssertTrue(window.delegate === closeGuard)

        window.close()
        XCTAssertEqual(replacement.willCloseCalls, 1)
        XCTAssertEqual(original.willCloseCalls, 0)
        XCTAssertTrue(window.delegate === replacement)
    }

    func testOriginalDeallocatedBeforeCloseDoesNotCrash() {
        let window = makeWindow()
        weak var weakOriginal: RecordingDelegate?
        var closeGuard: EditCloseGuard!
        autoreleasepool {
            let original = RecordingDelegate()   // implements windowWillClose
            weakOriginal = original
            window.delegate = original
            closeGuard = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)
        }
        XCTAssertNil(weakOriginal)
        XCTAssertNil(closeGuard.original)

        window.close()   // windowWillClose: must not reach a dead forwarding target
        XCTAssertNil(window.delegate)
        XCTAssertTrue(closeGuard.isClosed)
    }

    // MARK: - setEdited and automatic termination

    func testSetEditedMirrorsDocumentEdited() {
        let window = makeWindow()
        let closeGuard = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)
        closeGuard.setEdited(true)
        XCTAssertTrue(window.isDocumentEdited)
        closeGuard.setEdited(false)
        XCTAssertFalse(window.isDocumentEdited)
    }

    func testSetEditedReinstallsAfterDelegateReplaced() {
        let window = makeWindow()
        let original = RecordingDelegate()
        window.delegate = original
        let closeGuard = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)

        let replacement = RecordingDelegate()
        window.delegate = replacement
        closeGuard.setEdited(true)

        XCTAssertTrue(window.delegate === closeGuard)
        XCTAssertTrue(closeGuard.original === replacement)
        XCTAssertTrue(window.isDocumentEdited)

        let delegate: NSWindowDelegate = closeGuard
        delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(replacement.didResizeCalls, 1)
        XCTAssertEqual(original.didResizeCalls, 0)
    }

    func testAutomaticTerminationBalancedAcrossTransitionsAndClose() {
        let window = makeWindow()
        let closeGuard = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)

        closeGuard.setEdited(true)
        XCTAssertEqual(disableCount, 1)
        closeGuard.setEdited(true)
        XCTAssertEqual(disableCount, 1, "a repeated true is not a transition")
        closeGuard.setEdited(false)
        XCTAssertEqual(enableCount, 1)
        closeGuard.setEdited(false)
        XCTAssertEqual(enableCount, 1)
        closeGuard.setEdited(true)
        XCTAssertEqual(disableCount, 2)

        window.close()
        XCTAssertEqual(enableCount, 2, "closing gives the disable back")
        closeGuard.setEdited(true)
        XCTAssertEqual(disableCount, 2, "a closed guard never disables again")
        XCTAssertEqual(disableCount, enableCount)
    }

    func testAutomaticTerminationReenabledWhenDeallocatedWhileDirty() {
        weak var weakGuard: EditCloseGuard?
        autoreleasepool {
            let window = makeWindow()
            let closeGuard = EditCloseGuard.install(on: window, handlers: FakeSession().handlers)
            weakGuard = closeGuard
            closeGuard.setEdited(true)
        }
        XCTAssertNil(weakGuard)
        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(enableCount, 1)
    }

    // MARK: - Lifetime

    func testGuardDoesNotKeepWindowAlive() {
        weak var weakWindow: NSWindow?
        weak var weakGuard: EditCloseGuard?
        let session = FakeSession()
        session.dirty = true
        autoreleasepool {
            let window = makeWindow()
            weakWindow = window
            weakGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
            XCTAssertTrue(EditCloseGuard.guardsNeedingReview().contains { $0 === weakGuard })
        }
        XCTAssertNil(weakWindow)
        XCTAssertNil(weakGuard)
        XCTAssertTrue(EditCloseGuard.guardsNeedingReview().allSatisfy { $0.window != nil })
    }

    func testResolvedFlagLastsOnlyForTheConfirmedStep() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        let clean = makeWindow()
        let cleanGuard = EditCloseGuard.install(on: clean, handlers: FakeSession().handlers)

        XCTAssertTrue(EditCloseGuard.guardsNeedingReview().contains { $0 === closeGuard })
        XCTAssertFalse(EditCloseGuard.guardsNeedingReview().contains { $0 === cleanGuard })

        // Quit-path style confirmation (no close follows), session stays dirty.
        _ = QuickMDAppDelegate.reviewBeforeQuit([closeGuard], bringForward: { _ in }, terminateAgain: {})
        session.answer(true)
        XCTAssertTrue(closeGuard.isResolved)
        XCTAssertFalse(closeGuard.needsReview)

        drainMainQueue()
        XCTAssertFalse(closeGuard.isResolved, "cleared on the next main-queue turn")
        XCTAssertTrue(closeGuard.needsReview)
    }

    // MARK: - Quit decision

    func testQuitWithoutPendingGuardsTerminatesNow() {
        var terminateRequests = 0
        let reply = QuickMDAppDelegate.reviewBeforeQuit([], bringForward: { _ in XCTFail("nothing to show") },
                                                        terminateAgain: { terminateRequests += 1 })
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(terminateRequests, 0)
    }

    /// The real input of applicationShouldTerminate with open windows that are
    /// clean, or were dirty and saved: nothing is reviewed.
    func testQuitWithOnlyCleanGuardsTerminatesNow() {
        let clean = makeWindow(), saved = makeWindow()
        let cleanSession = FakeSession(), savedSession = FakeSession()
        savedSession.dirty = true
        EditCloseGuard.install(on: clean, handlers: cleanSession.handlers)
        let savedGuard = EditCloseGuard.install(on: saved, handlers: savedSession.handlers)
        savedGuard.setEdited(true)
        savedSession.dirty = false
        savedGuard.setEdited(false)

        let reply = QuickMDAppDelegate.reviewBeforeQuit(
            EditCloseGuard.guardsNeedingReview(),
            bringForward: { _ in XCTFail("nothing to show") }, terminateAgain: { XCTFail("no retry") })
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(cleanSession.confirmCalls + savedSession.confirmCalls, 0)
    }

    func testQuitWithDirtyGuardCancelsConfirmsAndRetries() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        var shown: [NSWindow] = []
        var terminateRequests = 0

        let reply = QuickMDAppDelegate.reviewBeforeQuit([closeGuard], bringForward: { shown.append($0) },
                                                        terminateAgain: { terminateRequests += 1 })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown.first === window)
        XCTAssertEqual(session.confirmCalls, 1)

        // Second ⌘Q while the sheet is up: still cancelled, no second sheet.
        let again = QuickMDAppDelegate.reviewBeforeQuit([closeGuard], bringForward: { shown.append($0) },
                                                        terminateAgain: { terminateRequests += 1 })
        XCTAssertEqual(again, .terminateCancel)
        XCTAssertEqual(session.confirmCalls, 1)
        XCTAssertEqual(shown.count, 2, "the pending sheet is brought forward again")

        session.dirty = false
        session.answer(true)
        XCTAssertEqual(terminateRequests, 1)
        XCTAssertFalse(EditCloseGuard.guardsNeedingReview().contains { $0 === closeGuard })
    }

    func testQuitCancelledStopsTerminating() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        var terminateRequests = 0

        let reply = QuickMDAppDelegate.reviewBeforeQuit([closeGuard], bringForward: { _ in },
                                                        terminateAgain: { terminateRequests += 1 })
        XCTAssertEqual(reply, .terminateCancel)
        session.answer(false)
        XCTAssertEqual(terminateRequests, 0)
        XCTAssertTrue(EditCloseGuard.guardsNeedingReview().contains { $0 === closeGuard })
    }

    /// A confirms → terminate again → B asked → terminate again → terminate now.
    func testQuitChainAcrossTwoDirtyGuards() {
        let windowA = makeWindow(), windowB = makeWindow()
        let sessionA = FakeSession(), sessionB = FakeSession()
        sessionA.dirty = true
        sessionB.dirty = true
        let guardA = EditCloseGuard.install(on: windowA, handlers: sessionA.handlers)
        let guardB = EditCloseGuard.install(on: windowB, handlers: sessionB.handlers)
        var shown: [NSWindow] = []
        var replies: [NSApplication.TerminateReply] = []

        func terminate() {
            let pending = EditCloseGuard.guardsNeedingReview().filter { $0 === guardA || $0 === guardB }
            replies.append(QuickMDAppDelegate.reviewBeforeQuit(pending, bringForward: { shown.append($0) },
                                                               terminateAgain: terminate))
        }

        terminate()
        XCTAssertEqual(replies, [.terminateCancel])
        XCTAssertTrue(shown.last === windowA)

        sessionA.dirty = false
        sessionA.answer(true)
        XCTAssertEqual(replies, [.terminateCancel, .terminateCancel])
        XCTAssertTrue(shown.last === windowB)
        XCTAssertEqual(sessionB.confirmCalls, 1)

        sessionB.dirty = false
        sessionB.answer(true)
        XCTAssertEqual(replies, [.terminateCancel, .terminateCancel, .terminateNow])
        XCTAssertEqual(sessionA.confirmCalls, 1)
    }

    /// Two dirty tabs, ⌘Q, Don't Save on A (session wrongly stays dirty),
    /// Cancel on B, the user keeps editing A and clicks its red button: A must
    /// be asked again.
    func testResolvedQuitAnswerDoesNotLeakIntoLaterClose() {
        let windowA = makeWindow(), windowB = makeWindow()
        let sessionA = FakeSession(), sessionB = FakeSession()
        sessionA.dirty = true
        sessionB.dirty = true
        let guardA = EditCloseGuard.install(on: windowA, handlers: sessionA.handlers)
        let guardB = EditCloseGuard.install(on: windowB, handlers: sessionB.handlers)
        let closesA = closeCounter(for: windowA)
        var replies: [NSApplication.TerminateReply] = []

        func terminate() {
            let pending = EditCloseGuard.guardsNeedingReview().filter { $0 === guardA || $0 === guardB }
            replies.append(QuickMDAppDelegate.reviewBeforeQuit(pending, bringForward: { _ in },
                                                               terminateAgain: terminate))
        }

        terminate()
        sessionA.answer(true)               // Don't Save on A, still dirty
        XCTAssertEqual(sessionB.confirmCalls, 1)
        sessionB.answer(false)              // Cancel on B: the quit ends
        XCTAssertEqual(replies, [.terminateCancel, .terminateCancel])

        drainMainQueue()
        XCTAssertFalse(guardA.isResolved)
        XCTAssertFalse(guardA.windowShouldClose(windowA), "A is asked again")
        XCTAssertEqual(sessionA.confirmCalls, 2)
        XCTAssertEqual(closesA(), 0)
    }

    /// ⌘Q while a close confirmation is up: cancel, show that sheet, queue nothing.
    func testQuitWhileCloseConfirmationPendingShowsThatSheet() {
        let window = makeWindow()
        let session = FakeSession()
        session.dirty = true
        let closeGuard = EditCloseGuard.install(on: window, handlers: session.handlers)
        let closes = closeCounter(for: window)
        XCTAssertFalse(closeGuard.windowShouldClose(window))

        var shown: [NSWindow] = []
        var terminateRequests = 0
        let reply = QuickMDAppDelegate.reviewBeforeQuit(EditCloseGuard.guardsNeedingReview(),
                                                        bringForward: { shown.append($0) },
                                                        terminateAgain: { terminateRequests += 1 })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertTrue(shown.first === window)
        XCTAssertEqual(session.confirmCalls, 1)

        session.dirty = false
        session.answer(true)
        XCTAssertEqual(closes(), 1)
        XCTAssertEqual(terminateRequests, 0)
    }

    // MARK: - Alert

    func testUnsavedAlertButtonsAndIdentifiers() {
        let sheet = UnsavedChangesAlert.makeAlert(fileName: "notes.md", allowsCancel: true)
        XCTAssertEqual(sheet.messageText, "Do you want to save the changes you made to “notes.md”?")
        XCTAssertEqual(sheet.informativeText, "Your changes will be lost if you don’t save them.")
        XCTAssertEqual(sheet.buttons.map(\.title), ["Save", "Don’t Save", "Cancel"])
        XCTAssertEqual(sheet.buttons.map { $0.accessibilityIdentifier() },
                       ["source-unsaved-save", "source-unsaved-discard", "source-unsaved-cancel"])
        XCTAssertEqual(sheet.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(sheet.buttons[2].keyEquivalent, "\u{1b}")

        let modal = UnsavedChangesAlert.makeAlert(fileName: "notes.md", allowsCancel: false)
        XCTAssertEqual(modal.buttons.map(\.title), ["Save", "Don’t Save"])

        XCTAssertEqual(UnsavedChangesAlert.choice(for: .alertFirstButtonReturn), .save)
        XCTAssertEqual(UnsavedChangesAlert.choice(for: .alertSecondButtonReturn), .discard)
        XCTAssertEqual(UnsavedChangesAlert.choice(for: .alertThirdButtonReturn), .cancel)
    }

    func testModalVariantNeverDiscardsWithoutExplicitClick() {
        XCTAssertEqual(UnsavedChangesAlert.modalChoice(for: .alertFirstButtonReturn), .save)
        XCTAssertEqual(UnsavedChangesAlert.modalChoice(for: .alertSecondButtonReturn), .discard)
        XCTAssertEqual(UnsavedChangesAlert.modalChoice(for: .abort), .save)
        XCTAssertEqual(UnsavedChangesAlert.modalChoice(for: .stop), .save)
        XCTAssertEqual(UnsavedChangesAlert.modalChoice(for: .cancel), .save)
    }
}
