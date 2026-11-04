// App Store build only: the GitHub/Homebrew build has no rating prompt, and
// none of this file is compiled into it (`OTHER_SWIFT_FLAGS="-DAPPSTORE"`).
#if APPSTORE
import SwiftUI
import AppKit
import StoreKit
#if DEBUG
import os

private let reviewLog = Logger(subsystem: "pl.falami.studio.QuickMD", category: "ReviewPrompt")
#endif

/// One rating request per app run, across every window and tab.
@MainActor
enum ReviewPromptSession {
    static var hasRequested = false
}

/// Attached to each document window's `MarkdownView`. Records the open once,
/// when the document first rendered, and — if `ReviewPrompt` says the reader
/// has settled in — asks StoreKit for a rating after 60 s of uninterrupted
/// display of this window.
///
/// "Displayed" is checked once a second: the window is visible, unoccluded,
/// key (the reader is looking at THIS tab, the app is frontmost) and has no
/// sheet or app-modal panel over it. A tick that fails any of it restarts the
/// 60 s. Source Edit stops it (the task id changes and the task returns while
/// editing; leaving starts a fresh 60 s), closing the window cancels it with
/// the view's task.
///
/// The policy is evaluated when the countdown arms AND when it completes: in
/// the usual case (thresholds not met, or this version already asked) no
/// timer runs at all.
struct ReviewPromptTrigger: ViewModifier {
    /// The document finished its first render (`contentVersion > 0`). Never
    /// goes back to false, so reloads, zoom and theme changes do not re-arm.
    let isRendered: Bool
    let isEditing: Bool
    /// The hosting window (`MarkdownView.hostWindow`), nil until attached.
    let window: NSWindow?

    static let requiredDisplay: TimeInterval = 60
    private static let tick: UInt64 = 1_000_000_000

    @Environment(\.requestReview) private var requestReview
    /// Per window: the open is recorded once even if the task re-runs
    /// (Source Edit toggles, the window object arriving, a re-appear).
    @State private var didRecordOpen = false

    private struct Arming: Equatable {
        let isRendered: Bool
        let isEditing: Bool
        let window: ObjectIdentifier?
    }

    func body(content: Content) -> some View {
        content
            .task(id: Arming(isRendered: isRendered, isEditing: isEditing,
                             window: window.map(ObjectIdentifier.init))) {
                await run()
            }
    }

    /// `@MainActor` explicitly: on the CI SDK a View's helpers are
    /// nonisolated, and this touches NSWindow / NSApp / `requestReview`.
    @MainActor
    private func run() async {
        guard isRendered else { return }
        let policy = ReviewPrompt()
        if !didRecordOpen {
            didRecordOpen = true
            policy.recordDocumentOpened(now: Date())
        }
        guard !isEditing, let window, Self.canRequest(policy) else { return }

        var countdown = ReviewPromptCountdown(required: Self.requiredDisplay)
        _ = countdown.advance(isDisplayed: Self.isDisplayed(window), now: Date())
        while true {
            try? await Task.sleep(nanoseconds: Self.tick)
            guard !Task.isCancelled else { return }
            guard countdown.advance(isDisplayed: Self.isDisplayed(window), now: Date()) else { continue }
            // Another window may have asked meanwhile, or the policy changed.
            guard Self.canRequest(policy) else { return }
            ReviewPromptSession.hasRequested = true
            #if DEBUG
            reviewLog.debug("requestReview for \(Self.appVersion, privacy: .public)")
            #endif
            requestReview()
            policy.markRequested(now: Date(), appVersion: Self.appVersion)
            return
        }
    }

    @MainActor
    private static func canRequest(_ policy: ReviewPrompt) -> Bool {
        !ReviewPromptSession.hasRequested && policy.shouldRequest(now: Date(), appVersion: appVersion)
    }

    @MainActor
    private static func isDisplayed(_ window: NSWindow) -> Bool {
        window.isVisible
            && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
            && window.isKeyWindow
            && window.attachedSheet == nil
            && NSApp.modalWindow == nil
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
#endif
