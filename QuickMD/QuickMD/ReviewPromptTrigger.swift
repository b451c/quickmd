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
/// Ticks once a second ONLY while the window is key (the reader is looking at
/// THIS tab, the app is frontmost); otherwise it waits for
/// `didBecomeKeyNotification` and costs nothing. "Displayed" per tick: visible,
/// unoccluded, key, no sheet or app-modal panel. A tick that fails it, losing
/// key, or a gap of more than 3 s between ticks (sleep, App Nap, a stalled
/// main thread — measured on the monotonic `systemUptime`) restarts the 60 s.
/// At 60 s it also needs user input within the last 60 s; an idle reader keeps
/// it waiting. Source Edit stops it (the task id changes and the task returns
/// while editing; leaving starts a fresh 60 s), closing the window cancels it
/// with the view's task.
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
        while !Task.isCancelled {
            // Another window asked: stop for good, no further ticks.
            guard !ReviewPromptSession.hasRequested else { return }
            // Not key (background tab, another app or window in front, a
            // sheet): no ticking at all — sleep until AppKit says the window
            // is key again, then count a fresh 60 s.
            if !window.isKeyWindow {
                countdown.reset()
                guard await Self.waitUntilKey(window) else { return }
                continue
            }
            let displayedLongEnough = countdown.advance(isDisplayed: Self.isDisplayed(window),
                                                        now: ProcessInfo.processInfo.systemUptime)
            if displayedLongEnough {
                // Another window may have asked meanwhile, or the policy changed.
                guard Self.canRequest(policy) else { return }
                // An unattended screen is not reading: keep waiting (the run
                // stays complete) until the reader touches the Mac again.
                if Self.userIsActive {
                    ReviewPromptSession.hasRequested = true
                    #if DEBUG
                    reviewLog.debug("requestReview for \(Self.appVersion, privacy: .public)")
                    #endif
                    requestReview()
                    policy.markRequested(now: Date(), appVersion: Self.appVersion)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: Self.tick)
        }
    }

    /// Suspends until `window` becomes key; false when the task was cancelled
    /// (window closed, view gone, Source Edit entered). The notification
    /// sequence is created BEFORE the key check, so a window that becomes key
    /// in between is not missed.
    @MainActor
    private static func waitUntilKey(_ window: NSWindow) async -> Bool {
        let becameKey = NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification,
                                                                 object: window)
        var iterator = becameKey.makeAsyncIterator()
        if window.isKeyWindow { return !Task.isCancelled }
        let arrived = await iterator.next() != nil
        return arrived && !Task.isCancelled
    }

    @MainActor
    private static func canRequest(_ policy: ReviewPrompt) -> Bool {
        !ReviewPromptSession.hasRequested && policy.shouldRequest(now: Date(), appVersion: appVersion)
    }

    /// Any keyboard / mouse / trackpad event within `maximumIdleAtRequest`.
    /// `~0` is `kCGAnyInputEventType`; an unconvertible type reads as idle.
    private static var userIsActive: Bool {
        guard let anyInput = CGEventType(rawValue: ~0) else { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return ReviewPrompt.isUserActive(secondsSinceLastInput: idle)
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
