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

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        savedSize = (defaults.object(forKey: "lastWindowFrameWidth"),
                     defaults.object(forKey: "lastWindowFrameHeight"))
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        defaults.set(savedSize.0, forKey: "lastWindowFrameWidth")
        defaults.set(savedSize.1, forKey: "lastWindowFrameHeight")
        super.tearDown()
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
        XCTAssertTrue(WindowTabbing.joinExistingTabs(new, among: [host, new]))
    }

    func testFirstWindowIsStandalone() {
        let new = FakeWindow()
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [new]))
    }

    func testHiddenWindowsAreNotHosts() {
        let hidden = FakeWindow()
        let new = FakeWindow()
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [hidden, new]))
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
        XCTAssertTrue(WindowTabbing.joinExistingTabs(new, among: [host, new]))
        XCTAssertTrue(host.addedTabs.count == 1 && host.addedTabs.first === new)
    }

    /// The black-half bug: never move a window into a full-screen (or Split
    /// View) tab group after it is already on screen.
    func testNoLateMergeIntoFullScreenHost() {
        let host = FakeWindow()
        host.fakeVisible = true
        host.fakeFullScreen = true
        let new = FakeWindow()
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [host, new]))
        XCTAssertTrue(host.addedTabs.isEmpty)
    }

    func testNoLateMergeOfWindowThatWentFullScreenOnItsOwn() {
        let host = FakeWindow()
        host.fakeVisible = true
        let new = FakeWindow()
        new.fakeFullScreen = true
        XCTAssertFalse(WindowTabbing.joinExistingTabs(new, among: [host, new]))
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
}
