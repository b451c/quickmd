import XCTest
import AppKit

/// Full-screen / Split View tabbing (opening a file used to give the tab group
/// a full-screen Space of its own, half black, without a menu bar). Headless:
/// windows are never ordered on screen; full screen, visibility and tab
/// membership are faked by a subclass. That AppKit then tabs real windows in
/// place is E2E territory; here we pin the preference AppKit reads and the
/// decisions WindowConfigurator makes once a window is on screen.
final class WindowTabbingTests: XCTestCase {

    /// NSWindow whose full-screen state, visibility and tab group are set by
    /// the test; tab merges and ordering are recorded, never performed.
    private final class FakeWindow: NSWindow {
        var fakeFullScreen = false
        var fakeVisible = false
        var fakeTabs: [NSWindow]?
        private(set) var addedTabs: [NSWindow] = []

        convenience init(width: CGFloat = 600, height: CGFloat = 400) {
            self.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            isReleasedWhenClosed = false
        }

        override var styleMask: NSWindow.StyleMask {
            get { fakeFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = newValue }
        }
        override var isVisible: Bool { fakeVisible }
        override var tabbedWindows: [NSWindow]? { fakeTabs }
        override func addTabbedWindow(_ window: NSWindow, ordered: NSWindow.OrderingMode) {
            addedTabs.append(window)
        }
        override func makeKeyAndOrderFront(_ sender: Any?) {}
    }

    private var savedArguments: [String: Any] = [:]
    private var savedSize: (Any?, Any?)
    private var savedAllowsAutomaticTabbing: Bool = true
    /// The separate-windows setting lives here, never in the test runner's
    /// saved defaults: a crash mid-test must not leave it on for later runs.
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let standard = UserDefaults.standard
        savedArguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        savedSize = (standard.object(forKey: "lastWindowFrameWidth"),
                     standard.object(forKey: "lastWindowFrameHeight"))
        savedAllowsAutomaticTabbing = NSWindow.allowsAutomaticWindowTabbing
        suiteName = "WindowTabbingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        let standard = UserDefaults.standard
        // The argument domain is process-wide (a suite writes the same one).
        standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        restore(savedSize.0, forKey: "lastWindowFrameWidth", in: standard)
        restore(savedSize.1, forKey: "lastWindowFrameHeight", in: standard)
        NSWindow.allowsAutomaticWindowTabbing = savedAllowsAutomaticTabbing
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Puts a value back, or removes the key when there was none (an explicit
    /// write would leave a value the runner never had).
    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func setSeparateWindows(_ on: Bool) {
        defaults.set(on, forKey: WindowTabbing.separateWindowsKey)
    }

    private var argumentTabbingMode: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[WindowTabbing.preferenceKey] as? String
    }

    // MARK: - Preference

    /// The root cause: with the system default ("In Full Screen") a new window
    /// arriving outside full screen, or one whose identifier no longer matched,
    /// was never tabbed by AppKit. AppKit must report "always" for QuickMD.
    func testPreferTabsAlwaysIsWhatAppKitReads() {
        WindowTabbing.preferTabsAlways()
        XCTAssertEqual(NSWindow.userTabbingPreference, .always)
    }

    func testPreferTabsAlwaysKeepsOtherLaunchArguments() {
        let defaults = UserDefaults.standard
        var arguments = savedArguments
        arguments["QuickMDTestArgument"] = "kept"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        WindowTabbing.preferTabsAlways()

        let after = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertEqual(after["QuickMDTestArgument"] as? String, "kept")
        XCTAssertEqual(after[WindowTabbing.preferenceKey] as? String, "always")
    }

    func testPreferTabsAlwaysIsNotPersisted() {
        WindowTabbing.preferTabsAlways()
        XCTAssertNil(UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "")?[WindowTabbing.preferenceKey])
    }

    // MARK: - joinExistingTabs

    func testAlreadyTabbedByAppKitCountsAsMerged() {
        let host = FakeWindow()
        let new = FakeWindow()
        new.fakeTabs = [host, new]
        XCTAssertTrue(WindowTabbing.joinExistingTabs(new, among: [host, new], in: defaults))
    }

    func testFirstWindowIsStandalone() {
        let new = FakeWindow()
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [new], in: defaults))
    }

    func testHiddenWindowsAreNotHosts() {
        let hidden = FakeWindow()
        let new = FakeWindow()
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [hidden, new], in: defaults))
        XCTAssertTrue(hidden.addedTabs.isEmpty)
    }

    /// Hosts come from the registered document windows: the Settings or Tip
    /// Jar window is never registered, whatever identifier SwiftUI gives it.
    func testOnlyRegisteredWindowsAreDocumentWindows() {
        let document = FakeWindow()
        let settings = FakeWindow()
        WindowTabbing.registerDocumentWindow(document)
        XCTAssertTrue(WindowTabbing.documentWindows.contains { $0 === document })
        XCTAssertFalse(WindowTabbing.documentWindows.contains { $0 === settings })
    }

    /// The fallback does not depend on SwiftUI sharing one identifier across
    /// document windows (only seen on macOS 26): outside full screen a visible
    /// document window takes the new one as a tab, as before #36.
    func testVisibleDocumentHostMergesWhateverItsIdentifier() {
        let host = FakeWindow()
        host.fakeVisible = true
        host.tabbingIdentifier = "SwiftUI-1"
        let new = FakeWindow()
        new.tabbingIdentifier = "SwiftUI-2"
        XCTAssertTrue(WindowTabbing.joinExistingTabs(new, among: [host, new], in: defaults))
        XCTAssertTrue(host.addedTabs.count == 1 && host.addedTabs.first === new)
    }

    /// The black-half bug: never move a window into a full-screen (or Split
    /// View) tab group after it is already on screen.
    func testNoLateMergeIntoFullScreenHost() {
        let host = FakeWindow()
        host.fakeVisible = true
        host.fakeFullScreen = true
        let new = FakeWindow()
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [host, new], in: defaults))
        XCTAssertTrue(host.addedTabs.isEmpty)
    }

    func testNoLateMergeOfWindowThatWentFullScreenOnItsOwn() {
        let host = FakeWindow()
        host.fakeVisible = true
        let new = FakeWindow()
        new.fakeFullScreen = true
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [host, new], in: defaults))
        XCTAssertTrue(host.addedTabs.isEmpty)
    }

    // MARK: - WindowSizeMemory in full screen

    func testApplyLeavesFullScreenWindowAlone() {
        UserDefaults.standard.set(500.0, forKey: "lastWindowFrameWidth")
        UserDefaults.standard.set(350.0, forKey: "lastWindowFrameHeight")
        let window = FakeWindow(width: 900, height: 700)
        window.fakeFullScreen = true
        let before = window.frame.size
        WindowSizeMemory.apply(to: window)
        XCTAssertEqual(window.frame.size, before)
    }

    func testApplyStillResizesOrdinaryWindow() {
        UserDefaults.standard.set(500.0, forKey: "lastWindowFrameWidth")
        UserDefaults.standard.set(350.0, forKey: "lastWindowFrameHeight")
        let window = FakeWindow(width: 900, height: 700)
        WindowSizeMemory.apply(to: window)
        XCTAssertEqual(window.frame.size, NSSize(width: 500, height: 350))
    }

    /// A Split View half (1534 × 1920 on the reporter's Mac) was saved as the
    /// "last size", so later standalone windows opened screen-sized.
    func testFullScreenSizeIsNotRemembered() {
        UserDefaults.standard.set(500.0, forKey: "lastWindowFrameWidth")
        UserDefaults.standard.set(350.0, forKey: "lastWindowFrameHeight")
        let window = FakeWindow(width: 1534, height: 1200)
        window.fakeFullScreen = true
        WindowSizeMemory.track(window)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "lastWindowFrameWidth"), 500)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "lastWindowFrameHeight"), 350)
    }

    func testOrdinarySizeIsRemembered() {
        let window = FakeWindow(width: 640, height: 480)
        WindowSizeMemory.track(window)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "lastWindowFrameWidth"), window.frame.width)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "lastWindowFrameHeight"), window.frame.height)
    }

    // MARK: - Separate windows (#57)

    /// Stored value only: what `NSWindow.userTabbingPreference` then reports
    /// cannot be tested in this process — AppKit reads the preference once per
    /// process and keeps it (measured with a standalone probe; whichever test
    /// reads it first decides for the whole run).
    func testPreferTabsNeverStoresManualInTheArgumentDomain() {
        WindowTabbing.preferTabsNever(in: defaults)
        XCTAssertEqual(argumentTabbingMode, "manual")
    }

    /// Native "Never": "manual" only, automatic tabbing stays allowed so the
    /// Window menu keeps Merge All Windows / Move Tab to New Window.
    func testLaunchWithSeparateWindowsIsManualAndKeepsTabCommands() {
        setSeparateWindows(true)
        NSWindow.allowsAutomaticWindowTabbing = false
        WindowTabbing.applyWindowPreferenceAtLaunch(in: defaults)
        XCTAssertEqual(argumentTabbingMode, "manual")
        XCTAssertTrue(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testLaunchKeepsTheAlwaysPreferenceByDefault() {
        setSeparateWindows(false)
        NSWindow.allowsAutomaticWindowTabbing = false
        WindowTabbing.applyWindowPreferenceAtLaunch(in: defaults)
        XCTAssertEqual(argumentTabbingMode, "always")
        XCTAssertTrue(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testSeparateWindowsKeepsOtherLaunchArguments() {
        var arguments = savedArguments
        arguments["QuickMDTestArgument"] = "kept"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        setSeparateWindows(true)
        WindowTabbing.applyWindowPreferenceAtLaunch(in: defaults)

        let after = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertEqual(after["QuickMDTestArgument"] as? String, "kept")
        XCTAssertEqual(after[WindowTabbing.preferenceKey] as? String, "manual")
    }

    /// Launched with tabs, switched on: AppKit still holds "always" and would
    /// tab the next window before our code sees it, so automatic tabbing must
    /// go off for new windows.
    func testSwitchingOnInATabsProcessStopsAutomaticTabbing() {
        setSeparateWindows(true)
        WindowTabbing.applyWindowPreference(in: defaults, tabbingPreference: .always)
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
        XCTAssertEqual(argumentTabbingMode, "manual")
    }

    /// Launched with separate windows ("manual"): AppKit never tabs on its own,
    /// so switching on again needs no global lever and keeps the tab commands.
    func testSwitchingOnInAManualProcessKeepsTabCommands() {
        setSeparateWindows(true)
        WindowTabbing.applyWindowPreference(in: defaults, tabbingPreference: .manual)
        XCTAssertTrue(NSWindow.allowsAutomaticWindowTabbing)
    }

    /// Switched off again (either launch mode): automatic tabbing is back and
    /// the argument domain asks for tabs.
    func testSwitchingOffRestoresAutomaticTabbing() {
        for cached in [NSWindow.UserTabbingPreference.always, .manual] {
            setSeparateWindows(true)
            WindowTabbing.applyWindowPreference(in: defaults, tabbingPreference: cached)
            setSeparateWindows(false)
            WindowTabbing.applyWindowPreference(in: defaults, tabbingPreference: cached)
            XCTAssertTrue(NSWindow.allowsAutomaticWindowTabbing, "cached \(cached.rawValue)")
            XCTAssertEqual(argumentTabbingMode, "always", "cached \(cached.rawValue)")
        }
    }

    /// The manual merge is what forces a second document into the first
    /// window's tab group outside full screen — with separate windows on, it
    /// must not run. Same host as `testVisibleDocumentHostMergesWhateverItsIdentifier`.
    func testSeparateWindowsNeverMergesIntoAVisibleHost() {
        setSeparateWindows(true)
        let host = FakeWindow()
        host.fakeVisible = true
        let new = FakeWindow()
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [host, new], in: defaults))
        XCTAssertTrue(host.addedTabs.isEmpty)
    }

    /// A window that is already in a tab group (state restoration, or Merge
    /// All Windows) counts as merged with separate windows on too, so
    /// `WindowSizeMemory.apply` never resizes the group.
    func testSeparateWindowsStillCountsAnAppKitTabGroupAsMerged() {
        setSeparateWindows(true)
        let host = FakeWindow()
        let new = FakeWindow()
        new.fakeTabs = [host, new]
        XCTAssertTrue(WindowTabbing.joinExistingTabs(new, among: [host, new], in: defaults))
        XCTAssertTrue(host.addedTabs.isEmpty)
    }
}
