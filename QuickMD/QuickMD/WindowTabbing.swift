import SwiftUI
import AppKit

// MARK: - Window Configurator

/// Bridges into AppKit to configure the host NSWindow once it's available.
///
/// Tabbing itself is AppKit's: `WindowTabbing.preferTabsAlways()` makes every
/// new document window join the frontmost one as a tab while AppKit orders it
/// in, in full screen and Split View too. SwiftUI already gives all
/// DocumentGroup windows one shared `tabbingIdentifier`, so it must be left as
/// is. This callback can't do the tabbing: on macOS 26 it fires only after the
/// window is on screen (and, in full screen, already in a Space of its own).
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TabAwareView()
        view.onWindowAttached = { window in
            // "Open each document in its own window": the window itself
            // refuses to join a tab group. AppKit decides when a window is
            // shown, and by then this can already be too late — the global
            // switch in WindowTabbing is what decides in practice — but it
            // keeps a window that is shown later on the right track.
            window.tabbingMode = WindowTabbing.documentTabbingMode
            configure(window)
            WindowTabbing.registerDocumentWindow(window)
            let merged = WindowTabbing.joinExistingTabs(window, among: WindowTabbing.documentWindows)
            if !merged {
                // Standalone window (first of the session, or all others closed):
                // give it the last size the user chose instead of the hardcoded
                // default. Tabs skip this — they adopt the host window's frame.
                WindowSizeMemory.apply(to: window)
                // SwiftUI applies the scene's defaultSize to the window AFTER
                // this callback (same runloop turn), clobbering the resize
                // above — verified empirically on macOS 15. Re-apply once
                // scene setup has finished; apply() is a no-op when the size
                // already matches, so this never causes a visible double-jump.
                DispatchQueue.main.async {
                    WindowSizeMemory.apply(to: window)
                }
            }
            WindowSizeMemory.track(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Window Tabbing

enum WindowTabbing {
    /// The defaults key behind `NSWindow.userTabbingPreference` (System
    /// Settings ▸ Desktop & Dock ▸ "Prefer tabs when opening documents").
    static let preferenceKey = "AppleWindowTabbingMode"

    /// Settings ▸ General ▸ Windows ▸ "Open each document in its own window".
    /// Off by default (every document shares one window, as a tab); when on,
    /// each document gets its own window and nothing is ever merged into
    /// another window's tab group.
    static let separateWindowsKey = "separateDocumentWindows"

    /// Whether each document should open in its own window.
    static func separateWindowsEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: separateWindowsKey)
    }

    /// Every QuickMD document opens as a tab, whatever the system-wide setting
    /// (default "In Full Screen" only). Set in the argument domain: it outranks
    /// the global domain, is never written to disk, and leaves the user's
    /// setting for other apps alone. Call before the first window exists.
    static func preferTabsAlways(in defaults: UserDefaults = .standard) {
        setTabbingMode("always", in: defaults)
    }

    /// The opposite of `preferTabsAlways()`: documents never join a tab group,
    /// whatever the system-wide "Prefer tabs when opening documents" setting
    /// says. Set in the argument domain too, for the same reasons.
    ///
    /// "manual" is the value AppKit reads as "never tab" — "never" is an old
    /// alias for "inFullScreen".
    static func preferTabsNever(in defaults: UserDefaults = .standard) {
        setTabbingMode("manual", in: defaults)
    }

    /// Writes the tabbing mode into the argument domain, keeping any other
    /// argument-domain value the app (or a test) put there.
    private static func setTabbingMode(_ mode: String, in defaults: UserDefaults) {
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[preferenceKey] = mode
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// The tabbing mode a document window must use.
    ///
    /// `.disallowed` is the per-window lever: it needs no global state and
    /// can be changed while the app runs. The alternative,
    /// `NSWindow.userTabbingPreference`, cannot be: AppKit reads it once per
    /// process and caches it, so changing the defaults domain after the first
    /// window exists has no effect.
    static var documentTabbingMode: NSWindow.TabbingMode {
        separateWindowsEnabled() ? .disallowed : .automatic
    }

    /// Applies the "separate windows" setting at launch, before the first
    /// window exists: the global tabbing switch, the preference AppKit reads
    /// for every window it shows, and the mode of the windows already open.
    static func applyWindowPreferenceAtLaunch(in defaults: UserDefaults = .standard) {
        let separate = separateWindowsEnabled(in: defaults)
        NSWindow.allowsAutomaticWindowTabbing = !separate
        if separate {
            preferTabsNever(in: defaults)
        } else {
            preferTabsAlways(in: defaults)
        }
        applyTabbingModeToOpenWindows()
    }

    /// Applies the "separate windows" setting while the app is running.
    ///
    /// The tabbing *preference* is not touched: AppKit reads
    /// `NSWindow.userTabbingPreference` once per process and caches it, so
    /// rewriting the defaults domain now would have no effect. The two levers
    /// that do work at runtime are `NSWindow.allowsAutomaticWindowTabbing`
    /// (global) and `NSWindow.tabbingMode` (per window, read when the window
    /// is shown).
    static func applyWindowPreference() {
        NSWindow.allowsAutomaticWindowTabbing = !separateWindowsEnabled()
        applyTabbingModeToOpenWindows()
    }

    /// Gives every open document window the tabbing mode the setting asks
    /// for. Windows that are already on screen keep the tab group they are in
    /// — a tab group is not something AppKit lets an app take apart — but a
    /// document opened from now on honours the new mode.
    private static func applyTabbingModeToOpenWindows() {
        for window in documentWindows {
            window.tabbingMode = documentTabbingMode
        }
    }

    /// Every document window, registered as it attaches (WindowConfigurator
    /// lives in MarkdownView only). The manual merge picks its host from these,
    /// not by `tabbingIdentifier`: SwiftUI chooses that value, and the Settings
    /// or Tip Jar window must never become a document's host.
    private static let registeredDocumentWindows = NSHashTable<NSWindow>.weakObjects()

    static var documentWindows: [NSWindow] { registeredDocumentWindows.allObjects }

    static func registerDocumentWindow(_ window: NSWindow) {
        registeredDocumentWindows.add(window)
    }

    /// Called once the new window is on screen. Returns true when it ended up
    /// as a tab (so it must keep the group's frame).
    ///
    /// Normally AppKit has already tabbed it. Merging by hand is a fallback for
    /// ordinary windows only: in full screen the window already has its own
    /// Space, and moving it into another window's tab group then leaves a
    /// half-empty black full-screen Space without a menu bar.
    @discardableResult
    static func joinExistingTabs(_ newWindow: NSWindow, among documentWindows: [NSWindow]) -> Bool {
        // "Open each document in its own window": never merge. The check comes
        // before the tabbed-windows test on purpose — a window that AppKit
        // already grouped must still count as standalone, so it also gets the
        // remembered size (see WindowConfigurator).
        guard !separateWindowsEnabled() else { return false }
        if (newWindow.tabbedWindows?.count ?? 0) > 1 { return true }
        let candidates = documentWindows.filter { $0 !== newWindow && $0.isVisible }
        guard let host = candidates.first else { return false }
        if host.styleMask.contains(.fullScreen) || newWindow.styleMask.contains(.fullScreen) {
            return false
        }
        host.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
        return true
    }
}

// MARK: - Window Size Memory (issue #13)

/// Remembers the most recently used document-window size and applies it to new
/// standalone windows, replacing the hardcoded 800×600 default. Size only —
/// position is left to AppKit's cascade so windows don't pile up exactly on
/// top of each other. Main-thread by convention (all callers are AppKit
/// window callbacks); deliberately not @MainActor — the CI runner's older
/// toolchain hard-errors on it (see constraints.md).
enum WindowSizeMemory {
    private static let widthKey = "lastWindowFrameWidth"
    private static let heightKey = "lastWindowFrameHeight"
    /// Floor mirrors MarkdownView's .frame(minWidth: 400, minHeight: 300).
    private static let minSize = NSSize(width: 400, height: 300)
    static let fallbackSize = NSSize(width: 800, height: 600)

    /// Launch-time size for SwiftUI's .defaultSize — saved size or the classic
    /// 800×600. New windows created mid-session are corrected by apply(to:)
    /// anyway; this just makes the very first frame land right.
    static var launchDefaultSize: NSSize {
        savedSize() ?? fallbackSize
    }

    private static func savedSize() -> NSSize? {
        let defaults = UserDefaults.standard
        let w = defaults.double(forKey: widthKey)
        let h = defaults.double(forKey: heightKey)
        guard w >= minSize.width, h >= minSize.height else { return nil }
        return NSSize(width: w, height: h)
    }

    private static func persist(_ window: NSWindow) {
        // A full-screen (or Split View) frame is the screen's size, not one the
        // user chose; saving it would open later standalone windows screen-sized.
        guard !window.styleMask.contains(.fullScreen) else { return }
        let size = window.frame.size
        guard size.width >= minSize.width, size.height >= minSize.height else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(size.width), forKey: widthKey)
        defaults.set(Double(size.height), forKey: heightKey)
    }

    /// Resizes `window` to the remembered size, clamped to the screen's visible
    /// frame, keeping the top-left corner anchored (so the title bar doesn't
    /// jump). No-op when nothing is saved or the size already matches.
    static func apply(to window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), var target = savedSize() else { return }
        if let screen = window.screen ?? NSScreen.main {
            target.width = min(target.width, screen.visibleFrame.width)
            target.height = min(target.height, screen.visibleFrame.height)
        }
        guard abs(window.frame.width - target.width) > 1
                || abs(window.frame.height - target.height) > 1 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target
        window.setFrame(frame, display: false)
    }

    /// Persists the window's size after every user resize and once more on
    /// close (catches zoom/maximize, which never fires didEndLiveResize).
    /// Observers self-remove on willClose, so closed windows leak nothing.
    static func track(_ window: NSWindow) {
        let center = NotificationCenter.default
        let resizeToken = center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow else { return }
            persist(w)
        }
        final class TokenBox { var token: NSObjectProtocol? }
        let closeBox = TokenBox()
        closeBox.token = center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { note in
            if let w = note.object as? NSWindow {
                persist(w)
            }
            center.removeObserver(resizeToken)
            if let token = closeBox.token { center.removeObserver(token) }
        }
    }
}

/// NSView subclass that fires `onWindowAttached` exactly once, when the host
/// NSWindow becomes available via `viewDidMoveToWindow`. More reliable than
/// `DispatchQueue.main.async` polling.
private final class TabAwareView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?
    private var fired = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !fired, let window = self.window else { return }
        fired = true
        onWindowAttached?(window)
    }
}
