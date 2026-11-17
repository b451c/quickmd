import XCTest
import AppKit

/// `OpenRecentMenu`: SwiftUI's first menu update leaves a blank
/// `NSMenuItem()` where File ▸ Open Recent was (an app that replaces
/// `.saveItem`); the repair turns THAT object into Open Recent with a
/// submenu of ours and leaves every healthy shape alone. Every test builds
/// its own menu tree and its own instance with an injected main menu and
/// environment: nothing here touches `NSApp.mainMenu`,
/// `NSDocumentController.shared`, the real recent list, or opens anything.
/// The repair is synchronous, so there are no waits and no run-loop spins.
@MainActor
final class OpenRecentMenuTests: XCTestCase {

    @MainActor
    private final class World {
        var recents: [URL] = []
        var recentsReads = 0
        var opened: [URL] = []
        var pendingFailure: ((String) -> Void)?
        var failures: [String] = []
        var clears = 0

        var environment: OpenRecentMenu.Environment {
            .init(
                recents: { [unowned self] in recentsReads += 1; return recents },
                open: { [unowned self] url, onFailure in opened.append(url); pendingFailure = onFailure },
                reportFailure: { [unowned self] in failures.append($0) },
                clear: { [unowned self] in clears += 1 })
        }
    }

    private struct Tree {
        let main: NSMenu
        let file: NSMenu
    }

    private let openDocument = #selector(NSDocumentController.openDocument(_:))
    private var world: World!

    override func setUp() {
        super.setUp()
        world = World()
    }

    override func tearDown() {
        world = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func openItem() -> NSMenuItem {
        NSMenuItem(title: "Open\u{2026}", action: openDocument, keyEquivalent: "o")
    }

    private func closeItem() -> NSMenuItem {
        NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    }

    /// A healthy system Open Recent: a plain item with its own submenu.
    private func systemOpenRecent() -> NSMenuItem {
        let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "Open Recent")
        return item
    }

    /// Main menu ▸ File with these items, the way the app's File menu sits.
    private func makeTree(_ fileItems: [NSMenuItem]) -> Tree {
        let main = NSMenu(title: "Main")
        main.addItem(NSMenuItem(title: "QuickMD", action: nil, keyEquivalent: ""))
        main.items[0].submenu = NSMenu(title: "QuickMD")
        let file = NSMenu(title: "File")
        for item in fileItems { file.addItem(item) }
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)
        return Tree(main: main, file: file)
    }

    /// New / Open… / <slot> / separator / Close.
    private func makeFileMenu(slot: NSMenuItem) -> Tree {
        makeTree([NSMenuItem(title: "New", action: nil, keyEquivalent: "n"),
                  openItem(), slot, .separator(), closeItem()])
    }

    private func makeRepair(for tree: Tree) -> OpenRecentMenu {
        let main = tree.main
        return OpenRecentMenu(mainMenu: { main }, environment: world.environment)
    }

    /// What SwiftUI does on its first update: the slot removed, a bare
    /// `NSMenuItem()` inserted at the same index.
    @discardableResult
    private func simulateSwiftUIRebuild(_ file: NSMenu, at index: Int = 2) -> NSMenuItem {
        file.removeItem(at: index)
        let blank = NSMenuItem()
        file.insertItem(blank, at: index)
        return blank
    }

    private func repairedSubmenu(_ tree: Tree, repair: OpenRecentMenu,
                                 file: StaticString = #filePath, line: UInt = #line) -> NSMenu? {
        let slot = tree.file.item(at: 2)
        XCTAssertEqual(slot?.title, OpenRecentMenu.title, file: file, line: line)
        XCTAssertTrue(slot?.submenu?.delegate === repair, file: file, line: line)
        return slot?.submenu
    }

    private func perform(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target as? NSObject else {
            return XCTFail("\(item.title) has no target/action")
        }
        _ = target.perform(action, with: item)
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - Detection and repair

    func testABlankSlotAfterOpenBecomesOpenRecentInPlace() {
        let blank = NSMenuItem()
        let tree = makeFileMenu(slot: blank)
        let repair = makeRepair(for: tree)
        repair.install()

        XCTAssertTrue(tree.file.item(at: 2) === blank, "the same object, never replaced")
        XCTAssertEqual(tree.file.numberOfItems, 5)
        XCTAssertEqual(blank.title, "Open Recent")
        XCTAssertNotNil(blank.submenu)
        XCTAssertTrue(blank.submenu?.delegate === repair)
        XCTAssertTrue(blank.isEnabled)
        XCTAssertEqual(repair.submenusBuilt, 1)
    }

    func testAPartlyResetSlotWithATitleIsStillRepaired() {
        let slot = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let tree = makeFileMenu(slot: slot)
        let repair = makeRepair(for: tree)
        repair.install()
        XCTAssertTrue(slot.submenu?.delegate === repair)
    }

    func testHealthyShapesAreLeftUntouched() {
        // A healthy system submenu.
        do {
            let slot = systemOpenRecent()
            let systemSubmenu = slot.submenu
            let tree = makeFileMenu(slot: slot)
            let repair = makeRepair(for: tree)
            repair.install()
            XCTAssertEqual(slot.title, "Open Recent")
            XCTAssertTrue(slot.submenu === systemSubmenu)
            XCTAssertEqual(repair.submenusBuilt, 0)
        }
        // A separator right after Open….
        do {
            let slot = NSMenuItem.separator()
            let tree = makeFileMenu(slot: slot)
            let repair = makeRepair(for: tree)
            repair.install()
            XCTAssertTrue(tree.file.item(at: 2) === slot)
            XCTAssertNil(slot.submenu)
            XCTAssertEqual(repair.submenusBuilt, 0)
        }
        // An item with an action.
        do {
            let slot = NSMenuItem(title: "Import", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "")
            let tree = makeFileMenu(slot: slot)
            let repair = makeRepair(for: tree)
            repair.install()
            XCTAssertEqual(slot.title, "Import")
            XCTAssertNil(slot.submenu)
            XCTAssertEqual(repair.submenusBuilt, 0)
        }
        // An item with a view.
        do {
            let slot = NSMenuItem()
            slot.view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            let tree = makeFileMenu(slot: slot)
            let repair = makeRepair(for: tree)
            repair.install()
            XCTAssertNil(slot.submenu)
            XCTAssertEqual(repair.submenusBuilt, 0)
        }
        // A menu without Open…: its blank item is not the slot.
        do {
            let blank = NSMenuItem()
            let title = blank.title
            let tree = makeTree([NSMenuItem(title: "New", action: nil, keyEquivalent: "n"), blank, closeItem()])
            let repair = makeRepair(for: tree)
            repair.install()
            XCTAssertEqual(blank.title, title)
            XCTAssertNil(blank.submenu)
            XCTAssertEqual(repair.submenusBuilt, 0)
        }
        // Open… as the last item: no slot.
        do {
            let tree = makeTree([NSMenuItem(title: "New", action: nil, keyEquivalent: "n"), openItem()])
            let repair = makeRepair(for: tree)
            repair.install()
            XCTAssertEqual(tree.file.numberOfItems, 2)
            XCTAssertNil(tree.file.item(at: 1)?.submenu)
            XCTAssertEqual(repair.submenusBuilt, 0)
        }
        // The blank item is BEFORE Open…, not after it.
        do {
            let blank = NSMenuItem()
            let tree = makeTree([blank, openItem(), systemOpenRecent()])
            let repair = makeRepair(for: tree)
            repair.install()
            XCTAssertNil(blank.submenu)
            XCTAssertEqual(repair.submenusBuilt, 0)
        }
    }

    func testTheSwiftUIRebuildIsRepairedByTheNotificationAlone() {
        let tree = makeFileMenu(slot: systemOpenRecent())
        let repair = makeRepair(for: tree)
        repair.install()
        XCTAssertEqual(repair.submenusBuilt, 0, "healthy at install")

        let blank = simulateSwiftUIRebuild(tree.file)

        // Synchronously, before anything else runs.
        XCTAssertTrue(tree.file.item(at: 2) === blank)
        XCTAssertEqual(blank.title, "Open Recent")
        XCTAssertTrue(blank.submenu?.delegate === repair)
        XCTAssertEqual(repair.submenusBuilt, 1)
    }

    func testAChangeThatBlanksTheSlotIsRepaired() {
        let slot = systemOpenRecent()
        let tree = makeFileMenu(slot: slot)
        let repair = makeRepair(for: tree)
        repair.install()

        // SwiftUI resetting the item in place instead of replacing it.
        slot.submenu = nil
        XCTAssertTrue(slot.submenu?.delegate === repair)
        XCTAssertEqual(repair.submenusBuilt, 1)
    }

    func testABlankItemOutsideTheMainMenuIsIgnored() {
        let tree = makeFileMenu(slot: systemOpenRecent())
        let repair = makeRepair(for: tree)
        repair.install()

        // A context menu of the same shape, attached nowhere.
        let context = NSMenu(title: "Context")
        context.addItem(openItem())
        context.addItem(systemOpenRecent())
        let contextBlank = simulateSwiftUIRebuild(context, at: 1)
        XCTAssertNil(contextBlank.submenu)

        // The same shape under ANOTHER main menu.
        let other = makeFileMenu(slot: systemOpenRecent())
        let otherBlank = simulateSwiftUIRebuild(other.file)
        XCTAssertNil(otherBlank.submenu)

        // A submenu nested one level deeper under our main menu.
        let nested = NSMenu(title: "Nested")
        nested.addItem(openItem())
        nested.addItem(systemOpenRecent())
        let holder = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        holder.submenu = nested
        tree.file.addItem(holder)
        let nestedBlank = simulateSwiftUIRebuild(nested, at: 1)
        XCTAssertNil(nestedBlank.submenu)

        XCTAssertEqual(repair.submenusBuilt, 0)
    }

    func testAFileMenuBuiltDetachedIsRepairedWhenItIsAttached() throws {
        let tree = makeFileMenu(slot: systemOpenRecent())
        let repair = makeRepair(for: tree)
        repair.install()
        let fileItem = try XCTUnwrap(tree.main.items.first { $0.submenu === tree.file })

        // A new File menu built while detached: its own notifications come
        // from a menu under nothing and are ignored.
        let blank = NSMenuItem()
        let newFile = NSMenu(title: "File")
        for item in [NSMenuItem(title: "New", action: nil, keyEquivalent: "n"), openItem(), blank, closeItem()] {
            newFile.addItem(item)
        }
        XCTAssertNil(blank.submenu)
        XCTAssertEqual(repair.submenusBuilt, 0)

        // Attaching it posts a change on the main menu only.
        fileItem.submenu = newFile

        XCTAssertTrue(newFile.item(at: 2) === blank)
        XCTAssertEqual(blank.title, OpenRecentMenu.title)
        XCTAssertTrue(blank.submenu?.delegate === repair)
        XCTAssertEqual(repair.submenusBuilt, 1)
    }

    func testOneEventBuildsOneSubmenuAndLaterChangesKeepIt() {
        let tree = makeFileMenu(slot: systemOpenRecent())
        let repair = makeRepair(for: tree)
        repair.install()

        // Proves one event builds one submenu. It does not prove the
        // `isRepairing` guard: with the submenu assigned first, a nested
        // notification already sees a healthy slot.
        let blank = simulateSwiftUIRebuild(tree.file)
        XCTAssertEqual(repair.submenusBuilt, 1, "one event, one submenu")
        let submenu = blank.submenu

        // Unrelated later changes in the File menu.
        tree.file.item(at: 4)?.title = "Close Window"
        tree.file.addItem(NSMenuItem(title: "Print", action: #selector(NSView.printView(_:)), keyEquivalent: "p"))
        blank.title = "Open Recent"
        XCTAssertTrue(blank.submenu === submenu)
        XCTAssertEqual(repair.submenusBuilt, 1)

        // Installing again adds no second set of observers.
        repair.install()
        tree.file.addItem(NSMenuItem(title: "Other", action: nil, keyEquivalent: ""))
        XCTAssertTrue(blank.submenu === submenu)
        XCTAssertEqual(repair.submenusBuilt, 1)
    }

    func testObserversGoAwayWithTheInstance() {
        let tree = makeFileMenu(slot: systemOpenRecent())
        weak var weakRepair: OpenRecentMenu?
        autoreleasepool {
            let repair = makeRepair(for: tree)
            repair.install()
            weakRepair = repair
        }
        XCTAssertNil(weakRepair, "nothing keeps the instance alive")

        let blank = simulateSwiftUIRebuild(tree.file)
        XCTAssertNil(blank.submenu, "a released instance repairs nothing")
    }

    // MARK: - Content

    func testEntriesKeepTheListOrderAndEndWithAnEnabledClearMenu() throws {
        world.recents = [url("/Notes/b.md"), url("/Notes/a.markdown"), url("/Other/c.txt")]
        let tree = makeFileMenu(slot: NSMenuItem())
        let repair = makeRepair(for: tree)
        repair.install()
        let submenu = try XCTUnwrap(repairedSubmenu(tree, repair: repair))

        XCTAssertEqual(submenu.items.map(\.title), ["b.md", "a.markdown", "c.txt", "", "Clear Menu"])
        XCTAssertEqual(submenu.items.prefix(3).compactMap { $0.representedObject as? URL }, world.recents)
        XCTAssertTrue(submenu.items[3].isSeparatorItem)
        XCTAssertFalse(submenu.autoenablesItems, "enabled states are explicit")
        XCTAssertEqual(submenu.items.filter { !$0.isSeparatorItem }.map(\.isEnabled), [true, true, true, true])
        for entry in submenu.items.prefix(3) {
            XCTAssertEqual(entry.image?.size, OpenRecentMenu.iconSize)
        }
    }

    /// Where AppKit has `preferredImageVisibility` (macOS 27+), entries ask
    /// for their icon to be drawn and Clear Menu / the separator are left at
    /// the default; elsewhere the request is a no-op. Decided by
    /// `responds(to:)`, never by the OS version.
    func testEntryIconsAskToBeVisibleWhereAppKitDecidesVisibility() throws {
        world.recents = [url("/Notes/one.md"), url("/Notes/two.txt")]
        let tree = makeFileMenu(slot: NSMenuItem())
        let repair = makeRepair(for: tree)
        repair.install()
        let submenu = try XCTUnwrap(repairedSubmenu(tree, repair: repair))
        let entries = Array(submenu.items.prefix(2))
        let clear = try XCTUnwrap(submenu.items.last)

        for entry in entries { XCTAssertEqual(entry.image?.size, OpenRecentMenu.iconSize) }
        XCTAssertNil(clear.image)

        let key = OpenRecentMenu.imageVisibilityKey
        guard NSMenuItem().responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else {
            // No such property: the request must not crash and sets nothing.
            OpenRecentMenu.requestVisibleImage(for: NSMenuItem())
            return
        }
        let defaultValue = (NSMenuItem().value(forKey: key) as? NSNumber)?.intValue
        for entry in entries {
            XCTAssertEqual((entry.value(forKey: key) as? NSNumber)?.intValue, 1, entry.title)
        }
        XCTAssertEqual((clear.value(forKey: key) as? NSNumber)?.intValue, defaultValue)
        XCTAssertEqual((submenu.items[2].value(forKey: key) as? NSNumber)?.intValue, defaultValue,
                       "the separator")
    }

    func testEntriesThatShareANameSayTheirFolder() throws {
        world.recents = [url("/A/README.md"), url("/Notes/plan.md"), url("/B/README.md")]
        let tree = makeFileMenu(slot: NSMenuItem())
        let repair = makeRepair(for: tree)
        repair.install()
        let submenu = try XCTUnwrap(repairedSubmenu(tree, repair: repair))

        XCTAssertEqual(submenu.items.prefix(3).map(\.title),
                       ["README.md \u{2014} A", "plan.md", "README.md \u{2014} B"])
    }

    func testAnEmptyListGivesOnlyADisabledClearMenu() throws {
        let tree = makeFileMenu(slot: NSMenuItem())
        let repair = makeRepair(for: tree)
        repair.install()
        let submenu = try XCTUnwrap(repairedSubmenu(tree, repair: repair))

        XCTAssertEqual(submenu.items.map(\.title), ["Clear Menu"])
        XCTAssertFalse(submenu.items[0].isSeparatorItem)
        XCTAssertFalse(submenu.items[0].isEnabled)
    }

    func testTheListIsReadAgainWhenTheMenuUpdates() throws {
        let tree = makeFileMenu(slot: NSMenuItem())
        let repair = makeRepair(for: tree)
        repair.install()
        let submenu = try XCTUnwrap(repairedSubmenu(tree, repair: repair))
        XCTAssertEqual(world.recentsReads, 1, "filled once at repair time")

        world.recents = [url("/Notes/new.md")]
        repair.menuNeedsUpdate(submenu)

        XCTAssertEqual(world.recentsReads, 2)
        XCTAssertEqual(submenu.items.map(\.title), ["new.md", "", "Clear Menu"])
        XCTAssertTrue(submenu.items[2].isEnabled)
    }

    // MARK: - Actions

    func testChoosingAnEntryOpensExactlyThatURLAndReportsAFailure() throws {
        world.recents = [url("/Notes/one.md"), url("/Notes/two.md")]
        let tree = makeFileMenu(slot: NSMenuItem())
        let repair = makeRepair(for: tree)
        repair.install()
        let submenu = try XCTUnwrap(repairedSubmenu(tree, repair: repair))

        perform(submenu.items[1])
        XCTAssertEqual(world.opened, [url("/Notes/two.md")])
        XCTAssertTrue(world.failures.isEmpty)

        world.pendingFailure?("Couldn\u{2019}t open \u{201C}two.md\u{201D}")
        XCTAssertEqual(world.failures, ["Couldn\u{2019}t open \u{201C}two.md\u{201D}"])
        XCTAssertEqual(world.clears, 0)
    }

    func testClearMenuCallsClear() throws {
        world.recents = [url("/Notes/one.md")]
        let tree = makeFileMenu(slot: NSMenuItem())
        let repair = makeRepair(for: tree)
        repair.install()
        let submenu = try XCTUnwrap(repairedSubmenu(tree, repair: repair))

        let clear = try XCTUnwrap(submenu.items.last)
        XCTAssertEqual(clear.title, "Clear Menu")
        world.recents = []
        perform(clear)

        XCTAssertEqual(world.clears, 1)
        XCTAssertTrue(world.opened.isEmpty)
        XCTAssertEqual(submenu.items.map(\.title), ["Clear Menu"], "the emptied list shows at once")
        XCTAssertFalse(submenu.items[0].isEnabled)
    }
}
