import SwiftUI
import AppKit

// MARK: - Window Configurator

/// Bridges into AppKit to configure the host NSWindow once it's available.
///
/// Tabbing itself is AppKit's: by default (`WindowTabbing.preferTabsAlways()`
/// at launch) every new document window joins the frontmost one as a tab while
/// AppKit orders it in, in full screen and Split View too; with Settings ▸
/// "Open documents in separate windows" on, AppKit tabs nothing on its own
/// (`WindowTabbing.applyWindowPreferenceAtLaunch`). SwiftUI already gives all
/// DocumentGroup windows one shared `tabbingIdentifier`, so it must be left as
/// is. This callback can't do the tabbing: on macOS 26 it fires only after the
/// window is on screen (and, in full screen, already in a Space of its own).
/// For the same reason it never sets the window's `tabbingMode` — AppKit has
/// already decided by then (see the levers on `WindowTabbing`).
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TabAwareView()
        view.onWindowAttached = { window in
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

/// How document windows are grouped: as tabs of one window (default, PR #36)
/// or one window per document (Settings ▸ General, PR #57).
///
/// The levers. MEASURED on macOS 27.0.1 with a standalone probe (plain
/// NSWindows, invisible, ordered in outside full screen — full screen and
/// SwiftUI's own windows are not covered):
/// - `AppleWindowTabbingMode` in the argument domain becomes
///   `NSWindow.userTabbingPreference`. AppKit reads it ONCE per process and
///   keeps that value: rewriting the domain later changes neither the class
///   property nor whether a newly shown window is tabbed. So it is a
///   launch-time lever only.
/// - A window's own `tabbingMode` decides when set before `orderFront`
///   (`.disallowed` is not tabbed under "always", `.preferred` is tabbed
///   under "manual"). Set right after `orderFront` it changes nothing in
///   either direction.
/// - `NSWindow.allowsAutomaticWindowTabbing = false`, set between two
///   windows, stops the second one being tabbed.
/// - `addTabbedWindow` (our fallback merge) works whatever the global flag
///   and the windows' `tabbingMode`.
/// INFERRED, not measured: `WindowConfigurator` fires after the window is
/// ordered in (seen on macOS 26 in the #36 E2E), so a per-window mode set
/// there comes too late; and the global flag also takes the tab items out of
/// the Window menu (WWDC 2016) — the GUI E2E checks both.
enum WindowTabbing {
    /// The defaults key behind `NSWindow.userTabbingPreference` (System
    /// Settings ▸ Desktop & Dock ▸ "Prefer tabs when opening documents").
    static let preferenceKey = "AppleWindowTabbingMode"

    /// Settings ▸ General ▸ "Open documents in separate windows". Off by
    /// default: every document opens as a tab of the frontmost window.
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

    /// The opposite of `preferTabsAlways()`: AppKit never tabs a new document
    /// on its own, whatever the system-wide setting. "manual" is the value
    /// macOS's own "Never" choice writes; an unknown value (e.g. "never")
    /// reads as the system default, "In Full Screen" (measured on macOS 27.0.1).
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

    /// At launch, before the first window exists. Separate windows = macOS's
    /// native "Never": "manual" only. Automatic tabbing stays ALLOWED, so the
    /// Window menu keeps Merge All Windows, Move Tab to New Window and Show
    /// Tab Bar — a reader can still put documents together on purpose (owner
    /// decision, review of #57). Our fallback merge is skipped
    /// (`joinExistingTabs`).
    static func applyWindowPreferenceAtLaunch(in defaults: UserDefaults = .standard) {
        NSWindow.allowsAutomaticWindowTabbing = true
        if separateWindowsEnabled(in: defaults) {
            preferTabsNever(in: defaults)
        } else {
            preferTabsAlways(in: defaults)
        }
    }

    /// The setting was toggled while the app runs. Windows and tab groups
    /// already open are never touched; only documents opened from now on
    /// follow the new value.
    ///
    /// The argument domain is rewritten to match (it costs nothing and is what
    /// a reader of the defaults sees), but AppKit keeps the preference it read
    /// at launch, so the process behaves by that cached value:
    /// - Launched with tabs ("always"), switched ON: a new window would still
    ///   be tabbed as AppKit orders it in, before any of our code sees it, so
    ///   the only lever left is the global `allowsAutomaticWindowTabbing =
    ///   false` (a per-window `.disallowed` from `WindowConfigurator` lands
    ///   too late). Cost until the next launch: the Window menu's tab items
    ///   (Merge All Windows, Move Tab to New Window, Show Tab Bar) go away —
    ///   expected from the flag, confirmed only by the E2E — while existing
    ///   groups still work by dragging tabs.
    /// - Switched OFF again in that process: the flag comes back, AppKit tabs
    ///   again — in full screen too.
    /// - Launched with separate windows ("manual"), switched ON again: nothing
    ///   to do — AppKit does not tab on its own.
    /// - Launched with separate windows, switched OFF: AppKit still does not
    ///   tab. Outside full screen our fallback merge moves the new window into
    ///   the frontmost group right after it appears (a brief flash of its own
    ///   window first). In full screen the fallback must not run (black half
    ///   of a Space), so the document opens in its own window. Real tabs
    ///   everywhere need a relaunch — the Settings caption says so.
    ///
    /// `tabbingPreference` is the value AppKit cached (injected by tests).
    static func applyWindowPreference(
        in defaults: UserDefaults = .standard,
        tabbingPreference: NSWindow.UserTabbingPreference? = nil
    ) {
        let separate = separateWindowsEnabled(in: defaults)
        if separate {
            preferTabsNever(in: defaults)
        } else {
            preferTabsAlways(in: defaults)
        }
        let cached = tabbingPreference ?? NSWindow.userTabbingPreference
        NSWindow.allowsAutomaticWindowTabbing = !(separate && cached != .manual)
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
    ///
    /// A window that is already in a tab group counts as merged in BOTH modes
    /// (checked first): it must never resize the group to the remembered size
    /// — e.g. a tab group brought back by state restoration, or one the
    /// reader made with Merge All Windows. Separate windows only skip the
    /// fallback merge.
    @discardableResult
    static func joinExistingTabs(
        _ newWindow: NSWindow,
        among documentWindows: [NSWindow],
        in defaults: UserDefaults = .standard
    ) -> Bool {
        if (newWindow.tabbedWindows?.count ?? 0) > 1 { return true }
        guard !separateWindowsEnabled(in: defaults) else { return false }
        guard let host = documentWindows.first(where: { other in
            other !== newWindow && other.isVisible
        }) else { return false }
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

    /// Windows (a whole tab group: they share the frame) that side by side
    /// grew and that still have that size — `persist` remembers the size
    /// from before the growth instead (`SideBySideGrowth.sizeToPersist`).
    private static let growths = NSMapTable<NSWindow, GrowthBox>.weakToStrongObjects()
    private final class GrowthBox { let growth: SideBySideGrowth; init(_ g: SideBySideGrowth) { growth = g } }

    /// Side by side grew `windows` (nil: the growth ended).
    static func setSideBySideGrowth(_ growth: SideBySideGrowth?, for windows: [NSWindow]) {
        for window in windows {
            if let growth { growths.setObject(GrowthBox(growth), forKey: window) } else { growths.removeObject(forKey: window) }
        }
    }

    /// The size `persist` remembers for `window`, nil for none: a full-screen
    /// (or Split View) frame is the screen's size, not one the user chose —
    /// saving it would open later standalone windows screen-sized; a window
    /// side by side grew remembers its size from before.
    static func sizeToRemember(_ window: NSWindow) -> NSSize? {
        guard !window.styleMask.contains(.fullScreen) else { return nil }
        return SideBySideGrowth.sizeToPersist(current: window.frame,
                                              growth: growths.object(forKey: window)?.growth)
    }

    private static func persist(_ window: NSWindow) {
        guard let size = sizeToRemember(window) else { return }
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
