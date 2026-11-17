import XCTest

/// `FolderBrowserStore` (File ▸ Open Folder, #62): open / close / persist /
/// restore, a vanished folder forgotten, and a watcher event re-scans. The
/// defaults are a `TemporaryDefaults` suite, the watcher a fake whose trigger
/// the test pulls (no real FSEvents), the access a recording closure; the
/// scan is the real `FolderListing` on a temporary tree.
@MainActor
final class FolderBrowserStoreTests: XCTestCase {

    /// A watcher token; the world sees whether it is still alive.
    private final class Token {}

    private final class World {
        var restoreAnswer = true
        var restored: [String] = []
        var watched: [String] = []
        var trigger: (@MainActor () -> Void)?
        weak var token: Token?
        weak var earlierToken: Token?
    }

    private var root: URL!
    private var suite: TemporaryDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBrowserStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = try TemporaryDefaults("FolderBrowserStore")
    }

    override func tearDownWithError() throws {
        suite.remove()
        try? FileManager.default.removeItem(at: root)
    }

    private func store(_ world: World) -> FolderBrowserStore {
        FolderBrowserStore(environment: .init(
            defaults: suite.defaults,
            restoreAccess: { folder in
                world.restored.append(folder.path)
                return world.restoreAnswer
            },
            watch: { folder, onChange in
                world.watched.append(folder.path)
                world.trigger = onChange
                let token = Token()
                world.token = token
                return token
            }))
    }

    private func folder(_ name: String, files: [String]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        for file in files {
            let path = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("# x\n".utf8).write(to: path)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func names(_ store: FolderBrowserStore) -> [String] {
        store.groups.flatMap(\.files).map(\.lastPathComponent)
    }

    func testOpenListsPersistsAndWatches() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["b.md", "a.md", "sub/c.md", "x.txt"])
        let browser = store(world)
        await browser.open(notes)
        XCTAssertEqual(browser.folder?.path, notes.standardizedFileURL.path)
        XCTAssertEqual(names(browser), ["a.md", "b.md", "c.md"])
        XCTAssertFalse(browser.isLoading)
        XCTAssertFalse(browser.isTruncated)
        XCTAssertEqual(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey), notes.standardizedFileURL.path)
        XCTAssertEqual(world.watched, [notes.standardizedFileURL.path], "one watcher, on the root")
        XCTAssertNotNil(world.token)
        XCTAssertTrue(world.restored.isEmpty, "a chosen folder is not restored: the chooser granted it")
    }

    func testOpenReplacesTheFolderAndItsWatcher() async throws {
        let world = World()
        let first = try folder("One", files: ["one.md"])
        let second = try folder("Two", files: ["two.md"])
        let browser = store(world)
        await browser.open(first)
        world.earlierToken = world.token
        XCTAssertNotNil(world.earlierToken)
        await browser.open(second)
        XCTAssertNil(world.earlierToken, "the first folder's watcher stopped")
        XCTAssertNotNil(world.token)
        XCTAssertEqual(names(browser), ["two.md"])
        XCTAssertEqual(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey), second.standardizedFileURL.path)
    }

    func testCloseForgetsEverything() async throws {
        let world = World()
        let browser = store(world)
        await browser.open(try folder("Notes", files: ["a.md"]))
        browser.close()
        XCTAssertNil(browser.folder)
        XCTAssertTrue(browser.groups.isEmpty)
        XCTAssertNil(world.token, "the watcher stopped")
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
        XCTAssertNil(store(World()).restore(), "nothing to restore after a close")
    }

    func testRestoreBringsTheRememberedFolderBack() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        await store(World()).open(notes)
        // Next launch: a new store over the same defaults.
        let world = World()
        let browser = store(world)
        let task = browser.restore()
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(world.restored, [notes.standardizedFileURL.path], "access restored (sandbox: its bookmark)")
        XCTAssertEqual(browser.folder?.path, notes.standardizedFileURL.path)
        XCTAssertEqual(names(browser), ["a.md"])
        XCTAssertEqual(world.watched.count, 1)
    }

    func testAVanishedFolderIsForgottenSilently() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        await store(World()).open(notes)
        try FileManager.default.removeItem(at: notes)
        let world = World()
        let browser = store(world)
        XCTAssertNil(browser.restore())
        XCTAssertNil(browser.folder)
        XCTAssertTrue(world.restored.isEmpty, "existence first: no bookmark for a folder that is gone")
        XCTAssertTrue(world.watched.isEmpty)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    func testAFolderThatCannotBeRestoredIsForgottenSilently() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        await store(World()).open(notes)
        let world = World()
        world.restoreAnswer = false
        let browser = store(world)
        XCTAssertNil(browser.restore())
        XCTAssertNil(browser.folder)
        XCTAssertEqual(world.restored.count, 1)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    func testAWatcherEventRescans() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md", "b.md"])
        let browser = store(world)
        await browser.open(notes)
        try Data("# new\n".utf8).write(to: notes.appendingPathComponent("sub/new.md").creatingParent())
        try FileManager.default.removeItem(at: notes.appendingPathComponent("a.md"))
        XCTAssertEqual(names(browser), ["a.md", "b.md"], "nothing changes before the event")
        world.trigger?()
        await browser.scanTask?.value
        XCTAssertEqual(names(browser), ["b.md", "new.md"])
        XCTAssertEqual(browser.groups.map(\.relativePath), ["", "sub"])
    }

    func testAWatcherEventAfterTheFolderWentAwayForgetsIt() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        await browser.open(notes)
        try FileManager.default.removeItem(at: notes)
        world.trigger?()
        await browser.scanTask?.value
        XCTAssertNil(browser.folder)
        XCTAssertTrue(browser.groups.isEmpty)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    /// The real watcher starts on a folder and stops when released (no event
    /// is waited for: delivery timing is the system's).
    func testTheTreeWatcherStartsAndStops() {
        weak var released: FolderTreeWatcher?
        do {
            let watcher = FolderTreeWatcher(root: root) {}
            XCTAssertNotNil(watcher)
            released = watcher
        }
        XCTAssertNil(released)
    }

    func testALateScanOfAClosedFolderPublishesNothing() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        await browser.open(notes)
        let pending = browser.refresh()
        browser.close()
        await pending.value
        XCTAssertNil(browser.folder)
        XCTAssertTrue(browser.groups.isEmpty, "the superseded scan dropped its result")
    }
}

private extension URL {
    /// Creates the parent folder and returns self (test trees).
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
