import XCTest
import Combine
import CoreServices

/// `FolderBrowserStore` (File ▸ Open Folder, #62): open / close / persist /
/// restore, gone vs unreadable, one scan at a time with one follow-up,
/// irrelevant events dropped, equal listings unpublished, and `open`
/// waiting for ITS folder's listing. The defaults are a `TemporaryDefaults`
/// suite, the watcher a fake whose trigger the test pulls (no FSEvents), the
/// follow-up delay a recorded no-op (no clock), the scan the real
/// `FolderListing` on a temporary tree behind a probe that counts scans and
/// can hold them (work counters, never time).
@MainActor
final class FolderBrowserStoreTests: XCTestCase {

    /// A watcher token; the world sees whether it is still alive.
    private final class Token {}

    @MainActor
    private final class World {
        var restoreAnswer = true
        var restored: [String] = []
        var watched: [String] = []
        var trigger: (@MainActor () -> Void)?
        var roots: [String] = []
        /// Batches that reached the main actor.
        var hops = 0

        /// An event batch: these paths, each with `flags` (default: an item
        /// created — a change that can alter the listing), judged by the
        /// REAL batch filter the watcher runs; an empty batch stands for
        /// "something changed" and goes straight through.
        func fire(_ paths: [String], flags: UInt32 = UInt32(kFSEventStreamEventFlagItemCreated)) {
            guard !paths.isEmpty else {
                hops += 1
                trigger?()
                return
            }
            let counter = HopCounter()
            let filter = FolderEventBatchFilter(roots: roots) { counter.add() }
            let flagList = [FSEventStreamEventFlags](repeating: flags, count: paths.count)
            flagList.withUnsafeBufferPointer {
                _ = filter.handle(count: paths.count, paths: paths as CFArray, flags: $0.baseAddress!)
            }
            if counter.value > 0 {
                hops += 1
                trigger?()
            }
        }
        weak var token: Token?
        weak var earlierToken: Token?
        // Scan probe.
        var started = 0
        var running = 0
        var peak = 0
        var hold = false
        var gates: [CheckedContinuation<Void, Never>] = []
        var events: [String] = []
        /// Answers instead of the real scan when set.
        var forced: FolderListing.Outcome?
        var cancelChecks: [@Sendable () -> Bool] = []

        func begin(_ isCancelled: @escaping @Sendable () -> Bool) async {
            started += 1
            running += 1
            peak = max(peak, running)
            events.append("scan")
            cancelChecks.append(isCancelled)
            if hold { await withCheckedContinuation { gates.append($0) } }
        }

        func end() { running -= 1 }

        func release() {
            hold = false
            gates.forEach { $0.resume() }
            gates.removeAll()
        }
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
            watch: { folder, roots, onChange in
                world.watched.append(folder.path)
                world.roots = roots
                world.trigger = onChange
                let token = Token()
                world.token = token
                return token
            },
            scan: { folder, isCancelled in
                await world.begin(isCancelled)
                let forced = await MainActor.run { world.forced }
                let outcome = forced ?? FolderListing.scan(folder, isCancelled: isCancelled)
                await world.end()
                return outcome
            },
            followUpDelay: { world.events.append("delay") }))
    }

    private func folder(_ name: String, files: [String]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            let path = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("# x\n".utf8).write(to: path)
        }
        return url
    }

    private func names(_ store: FolderBrowserStore) -> [String] {
        store.groups.flatMap(\.files).map(\.lastPathComponent)
    }

    /// Spins until `condition` holds (bounded by a generous deadline, which a
    /// passing run never reaches).
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    /// The scans the store has left to run, finished.
    private func settle(_ store: FolderBrowserStore) async {
        while let loop = store.scanLoop { await loop.value; await Task.yield() }
    }

    private func path(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Open, close, persist

    func testOpenListsPersistsAndWatches() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["b.md", "a.md", "sub/c.md", "x.txt"])
        let browser = store(world)
        let result = await browser.open(notes)
        XCTAssertEqual(result, .listed)
        XCTAssertEqual(browser.folder?.path, path(notes))
        XCTAssertEqual(names(browser), ["a.md", "b.md", "c.md"])
        XCTAssertEqual(browser.fileCount, 3)
        XCTAssertFalse(browser.isLoading)
        XCTAssertFalse(browser.isTruncated)
        XCTAssertEqual(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey), path(notes))
        XCTAssertEqual(world.watched, [FolderAccessBroker.canonicalPath(notes)], "one watcher, on the canonical root")
        XCTAssertNotNil(world.token)
        XCTAssertTrue(world.restored.isEmpty, "a chosen folder is not restored: the chooser granted it")
        XCTAssertEqual(world.started, 1)
    }

    /// The listing is built on the disk spelling of the root (the temporary
    /// directory lives under the `/var` → `/private/var` symlink), while the
    /// folder stays as chosen.
    func testListingURLsAreCanonicalAndTheFolderAsChosen() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(World())
        _ = await browser.open(notes)
        let canonical = FolderAccessBroker.canonicalPath(notes)
        XCTAssertEqual(browser.listingRoot?.path, canonical)
        XCTAssertEqual(browser.groups.first?.files.first?.path, canonical + "/a.md")
        XCTAssertEqual(browser.folder?.path, path(notes))
    }

    func testOpenReplacesTheFolderAndItsWatcher() async throws {
        let world = World()
        let first = try folder("One", files: ["one.md"])
        let second = try folder("Two", files: ["two.md"])
        let browser = store(world)
        _ = await browser.open(first)
        world.earlierToken = world.token
        XCTAssertNotNil(world.earlierToken)
        _ = await browser.open(second)
        XCTAssertNil(world.earlierToken, "the first folder's watcher stopped")
        XCTAssertNotNil(world.token)
        XCTAssertEqual(names(browser), ["two.md"])
        XCTAssertEqual(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey), path(second))
    }

    func testCloseForgetsEverything() async throws {
        let world = World()
        let browser = store(world)
        _ = await browser.open(try folder("Notes", files: ["a.md"]))
        browser.close()
        XCTAssertNil(browser.folder)
        XCTAssertNil(browser.listingRoot)
        XCTAssertTrue(browser.groups.isEmpty)
        XCTAssertNil(world.token, "the watcher stopped")
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
        let next = store(World())
        await next.restore()
        XCTAssertNil(next.folder, "nothing to restore after a close")
    }

    // MARK: Restore

    func testCreatingTheStoreDoesNothingUntilRestore() async throws {
        _ = await store(World()).open(try folder("Notes", files: ["a.md"]))
        let world = World()
        let browser = store(world)
        XCTAssertNil(browser.folder, "no I/O and no publishing at creation")
        XCTAssertTrue(world.restored.isEmpty)
        XCTAssertEqual(world.started, 0)
        await browser.restore()
        await settle(browser)
        XCTAssertEqual(names(browser), ["a.md"])
        await browser.restore()
        XCTAssertEqual(world.restored.count, 1, "once per process")
    }

    func testRestoreBringsTheRememberedFolderBack() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        _ = await store(World()).open(notes)
        // Next launch: a new store over the same defaults.
        let world = World()
        let browser = store(world)
        await browser.restore()
        await settle(browser)
        XCTAssertEqual(world.restored, [path(notes)], "access restored (sandbox: its bookmark) for the chosen path")
        XCTAssertEqual(browser.folder?.path, path(notes))
        XCTAssertEqual(names(browser), ["a.md"])
        XCTAssertEqual(world.watched, [FolderAccessBroker.canonicalPath(notes)])
    }

    func testAnOpenBeforeTheRestoreWins() async throws {
        let old = try folder("Old", files: ["old.md"])
        _ = await store(World()).open(old)
        let browser = store(World())
        _ = await browser.open(try folder("New", files: ["new.md"]))
        await browser.restore()
        XCTAssertEqual(names(browser), ["new.md"])
    }

    func testAVanishedFolderIsForgottenSilently() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        _ = await store(World()).open(notes)
        try FileManager.default.removeItem(at: notes)
        let world = World()
        let browser = store(world)
        await browser.restore()
        XCTAssertNil(browser.folder)
        XCTAssertTrue(world.restored.isEmpty, "existence first: no bookmark for a folder that is gone")
        XCTAssertTrue(world.watched.isEmpty)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    func testAFolderThatCannotBeRestoredIsForgottenSilently() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        _ = await store(World()).open(notes)
        let world = World()
        world.restoreAnswer = false
        let browser = store(world)
        await browser.restore()
        XCTAssertNil(browser.folder)
        XCTAssertEqual(world.restored.count, 1)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    // MARK: Gone vs unreadable

    func testAnUnreadableFolderIsKeptWithItsLastListing() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        _ = await browser.open(notes)
        world.forced = .unreadable
        world.fire([])
        await settle(browser)
        XCTAssertEqual(browser.folder?.path, path(notes), "kept")
        XCTAssertTrue(browser.isUnreadable)
        XCTAssertEqual(names(browser), ["a.md"], "the last listing stays")
        XCTAssertNotNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
        world.forced = nil
        world.fire([])
        await settle(browser)
        XCTAssertFalse(browser.isUnreadable, "tried again on the next event")
    }

    /// An explicit Open of a folder that cannot be read leaves nothing
    /// behind (it would come back, unreadable, at every launch).
    func testAnExplicitOpenOfAnUnreadableFolderLeavesNothingBehind() async throws {
        let world = World()
        world.forced = .unreadable
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        let result = await browser.open(notes)
        XCTAssertEqual(result, .unreadable)
        XCTAssertNil(browser.folder)
        XCTAssertFalse(browser.isUnreadable)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
        XCTAssertNil(world.token, "no watcher left")
    }

    func testAnExplicitOpenOfAMissingFolderLeavesNothingBehind() async throws {
        let world = World()
        let browser = store(world)
        let result = await browser.open(root.appendingPathComponent("Nowhere", isDirectory: true))
        XCTAssertEqual(result, .missing)
        XCTAssertNil(browser.folder)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    /// Restored at launch while it cannot be read: kept, header + the
    /// "Can't read" line (isUnreadable), tried again on the next event.
    func testARestoredUnreadableFolderIsKept() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        _ = await store(World()).open(notes)
        let world = World()
        world.forced = .unreadable
        let browser = store(world)
        await browser.restore()
        await settle(browser)
        XCTAssertNotNil(browser.folder)
        XCTAssertTrue(browser.isUnreadable)
        XCTAssertTrue(browser.groups.isEmpty)
        XCTAssertFalse(browser.isLoading)
        XCTAssertNotNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
        world.forced = nil
        world.fire([])
        await settle(browser)
        XCTAssertFalse(browser.isUnreadable)
        XCTAssertEqual(names(browser), ["a.md"])
    }

    /// A remembered folder behind a parent without search permission (stat:
    /// EACCES) is not forgotten at launch: the REAL scan reports it
    /// unreadable and it stays.
    func testAPermissionErrorAtLaunchDoesNotForgetTheFolder() async throws {
        let parent = try folder("Locked", files: ["Notes/a.md"])
        let notes = parent.appendingPathComponent("Notes", isDirectory: true)
        _ = await store(World()).open(notes)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let world = World()
        let browser = store(world)
        await browser.restore()
        await settle(browser)
        XCTAssertEqual(world.restored.count, 1)
        XCTAssertEqual(browser.folder?.path, path(notes))
        XCTAssertTrue(browser.isUnreadable)
        XCTAssertNotNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    func testAMissingFolderIsForgotten() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        _ = await browser.open(notes)
        try FileManager.default.removeItem(at: notes)
        world.fire([])
        await settle(browser)
        XCTAssertNil(browser.folder)
        XCTAssertTrue(browser.groups.isEmpty)
        XCTAssertNil(suite.defaults.string(forKey: FolderBrowserStore.defaultsKey))
    }

    // MARK: One scan at a time

    func testAWatcherEventRescans() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md", "b.md"])
        let browser = store(world)
        _ = await browser.open(notes)
        try FileManager.default.createDirectory(at: notes.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("# new\n".utf8).write(to: notes.appendingPathComponent("sub/new.md"))
        try FileManager.default.removeItem(at: notes.appendingPathComponent("a.md"))
        XCTAssertEqual(names(browser), ["a.md", "b.md"], "nothing changes before the event")
        world.fire([FolderAccessBroker.canonicalPath(notes) + "/sub"])
        await settle(browser)
        XCTAssertEqual(names(browser), ["b.md", "new.md"])
        XCTAssertEqual(browser.groups.map(\.relativePath), ["", "sub"])
        XCTAssertEqual(world.events, ["scan", "scan"], "no delay before a scan nothing was waiting for")
    }

    /// Ten events during one scan: still one scan in flight, then exactly
    /// ONE follow-up, after the delay.
    func testEventsDuringAScanCauseExactlyOneFollowUp() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        world.hold = true
        let opening = Task { await browser.open(notes) }
        await until { world.started == 1 && !world.gates.isEmpty }
        for _ in 0..<10 { world.fire([FolderAccessBroker.canonicalPath(notes)]) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(world.started, 1, "events while a scan runs start nothing")
        world.release()
        let result = await opening.value
        XCTAssertEqual(result, .listed)
        await settle(browser)
        XCTAssertEqual(world.started, 2)
        XCTAssertEqual(world.peak, 1, "never two scans at once")
        XCTAssertEqual(world.events, ["scan", "delay", "scan"])
    }

    func testIrrelevantEventsStartNoScan() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        _ = await browser.open(notes)
        let canonical = FolderAccessBroker.canonicalPath(notes)
        world.fire([canonical + "/.git/objects/ab", canonical + "/node_modules/pkg"])
        await settle(browser)
        XCTAssertEqual(world.started, 1, "a batch only under skipped names is dropped")
        // FSEvents spells the temporary folder `/private/var/…`.
        let real = FolderListing.realPath(canonical)
        world.fire([real + "/.git/index", real + "/docs/node_modules"])
        await settle(browser)
        XCTAssertEqual(world.started, 1, "in the realpath spelling too")
        world.fire([canonical + "/.git", canonical + "/docs"])
        await settle(browser)
        XCTAssertEqual(world.started, 2, "one relevant path is enough")
    }

    func testAnEqualListingPublishesNothing() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        _ = await browser.open(notes)
        var changes = 0
        let subscription = browser.objectWillChange.sink { changes += 1 }
        world.fire([])
        await settle(browser)
        XCTAssertEqual(world.started, 2)
        XCTAssertEqual(changes, 0)
        try Data("# b\n".utf8).write(to: notes.appendingPathComponent("b.md"))
        world.fire([])
        await settle(browser)
        XCTAssertGreaterThan(changes, 0, "a changed listing does publish")
        subscription.cancel()
    }

    func testCloseCancelsTheRunningScan() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        world.hold = true
        let opening = Task { await browser.open(notes) }
        await until { world.started == 1 && !world.gates.isEmpty }
        XCTAssertEqual(world.cancelChecks.first?(), false)
        browser.close()
        XCTAssertEqual(world.cancelChecks.first?(), true, "the scan sees it was cancelled")
        let result = await opening.value
        XCTAssertEqual(result, .superseded)
        world.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(browser.folder)
        XCTAssertTrue(browser.groups.isEmpty, "the cancelled scan published nothing")
    }

    // MARK: open waits for its own listing

    func testASecondOpenSupersedesTheFirst() async throws {
        let world = World()
        let first = try folder("One", files: ["one.md"])
        let second = try folder("Two", files: ["two.md"])
        let browser = store(world)
        world.hold = true
        let firstOpen = Task { await browser.open(first) }
        await until { world.started == 1 && !world.gates.isEmpty }
        XCTAssertEqual(world.cancelChecks.first?(), false)
        let secondOpen = Task { await browser.open(second) }
        await until { world.started == 2 }
        world.release()
        let results = await [firstOpen.value, secondOpen.value]
        XCTAssertEqual(results, [.superseded, .listed])
        XCTAssertEqual(world.cancelChecks.first?(), true, "the first folder's scan was cancelled")
        XCTAssertEqual(names(browser), ["two.md"])
    }

    func testOpenReturnsWithItsOwnListingWhenAnEventArrivesDuringTheScan() async throws {
        let world = World()
        let notes = try folder("Notes", files: ["a.md"])
        let browser = store(world)
        world.hold = true
        let opening = Task { await browser.open(notes) }
        await until { world.started == 1 && !world.gates.isEmpty }
        world.fire([])
        world.release()
        let result = await opening.value
        XCTAssertEqual(result, .listed)
        XCTAssertEqual(names(browser), ["a.md"], "published before open returned")
        await settle(browser)
    }

    /// Restored while unreadable, then the folder's permission is fixed:
    /// the `chmod` event of the ROOT (ChangeOwner + IsDir) lists it again.
    /// A file's chmod, an xattr or a content write would not have.
    func testAPermissionChangeOfTheRootListsARestoredUnreadableFolderAgain() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        _ = await store(World()).open(notes)
        let world = World()
        world.forced = .unreadable
        let browser = store(world)
        await browser.restore()
        await settle(browser)
        XCTAssertTrue(browser.isUnreadable)
        world.forced = nil
        let real = FolderListing.realPath(FolderAccessBroker.canonicalPath(notes))
        let started = world.started
        for flags in [kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemIsFile,
                      kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsDir,
                      kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir,
                      kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile] {
            world.fire([real + "/a.md", real], flags: UInt32(flags))
            await settle(browser)
        }
        XCTAssertEqual(world.started, started, "file chmod, xattr, mtime, content write: no scan")
        XCTAssertTrue(browser.isUnreadable)
        world.fire([real], flags: UInt32(kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemIsDir))
        await settle(browser)
        XCTAssertEqual(world.started, started + 1)
        XCTAssertFalse(browser.isUnreadable)
        XCTAssertEqual(names(browser), ["a.md"])
    }

    // MARK: Batch filter (the watcher's queue)

    /// A batch of `count` changes through the real filter, with a counter
    /// for the hops it would make to the main actor.
    private func hops(paths: [String], flags: [UInt32], roots: [String]) -> Int {
        let counter = HopCounter()
        let filter = FolderEventBatchFilter(roots: roots) { counter.add() }
        flags.withUnsafeBufferPointer {
            _ = filter.handle(count: paths.count, paths: paths as CFArray, flags: $0.baseAddress!)
        }
        return counter.value
    }

    private final class HopCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add() { lock.lock(); count += 1; lock.unlock() }
    }

    /// 10 000 irrelevant changes (an `npm install` under node_modules/, a
    /// git object write, content writes, file chmods): no hop to the main
    /// actor, so no scan. One relevant change in the middle: exactly one.
    func testABatchHopsToTheMainActorOnlyForARelevantChange() async throws {
        let notes = try folder("Notes", files: ["a.md"])
        let root = FolderAccessBroker.canonicalPath(notes)
        let real = FolderListing.realPath(root)
        let roots = [root, real]
        let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        let written = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        let fileChmod = UInt32(kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemIsFile)
        var paths: [String] = []
        var flags: [UInt32] = []
        for index in 0..<10_000 {
            switch index % 4 {
            case 0: paths.append(real + "/node_modules/pkg\(index)/index.js"); flags.append(created)
            case 1: paths.append(real + "/.git/objects/\(index)"); flags.append(created)
            case 2: paths.append(real + "/notes\(index).md"); flags.append(written)
            default: paths.append(real + "/docs/n\(index).md"); flags.append(fileChmod)
            }
        }
        XCTAssertEqual(hops(paths: paths, flags: flags, roots: roots), 0)

        var oneRelevant = paths
        oneRelevant[5_000] = real + "/docs/new.md"
        var oneFlags = flags
        oneFlags[5_000] = created
        XCTAssertEqual(hops(paths: oneRelevant, flags: oneFlags, roots: roots), 1, "once per batch")

        // Through the store: the irrelevant batch starts no scan.
        let world = World()
        let browser = store(world)
        _ = await browser.open(notes)
        let started = world.started
        var hoppedBefore = world.hops
        for (path, flag) in zip(paths.prefix(200), flags.prefix(200)) { world.fire([path], flags: flag) }
        await settle(browser)
        XCTAssertEqual(world.hops, hoppedBefore)
        XCTAssertEqual(world.started, started)
        hoppedBefore = world.hops
        world.fire([real + "/docs/new.md"], flags: created)
        await settle(browser)
        XCTAssertEqual(world.hops, hoppedBefore + 1)
        XCTAssertEqual(world.started, started + 1)
    }

    /// A stopped filter (the watcher released) calls nothing.
    func testAStoppedBatchFilterCallsNothing() {
        let counter = HopCounter()
        let filter = FolderEventBatchFilter(roots: ["/r"]) { counter.add() }
        filter.stop()
        let flags = [UInt32(kFSEventStreamEventFlagItemCreated)]
        flags.withUnsafeBufferPointer {
            _ = filter.handle(count: 1, paths: ["/r/a.md"] as CFArray, flags: $0.baseAddress!)
        }
        XCTAssertEqual(counter.value, 0)
    }

    // MARK: Real watcher

    /// The real watcher starts on a folder and stops when released (no event
    /// is waited for: delivery timing is the system's).
    func testTheTreeWatcherStartsAndStops() {
        weak var released: FolderTreeWatcher?
        do {
            let watcher = FolderTreeWatcher(root: root, roots: [root.path]) {}
            XCTAssertNotNil(watcher)
            released = watcher
        }
        XCTAssertNil(released)
    }
}
