import XCTest

/// `FolderAccessBroker`: the sandboxed build asks for folder access at most
/// once per folder per session, for the document's folder, covers
/// subfolders, shares one panel, and the unsandboxed build never asks.
/// Panels, bookmarks and readiness are injected (a recording fake).
@MainActor
final class FolderAccessBrokerTests: XCTestCase {

    /// The fake world: which folders have saved bookmarks, what the panel
    /// answers, and what was asked.
    private final class World {
        var saved: [URL] = []
        var answer: (URL) -> URL? = { _ in nil }
        var prompts: [String] = []
        var granted: [URL] = []
        var restored: [URL] = []
        /// Panels held back until the test releases them (all of them: a
        /// broken coalescing must FAIL by its prompt count, never hang).
        var gates: [CheckedContinuation<Void, Never>] = []
        var holdPanels = false
    }

    private func broker(_ world: World, sandboxed: Bool = true) -> FolderAccessBroker {
        FolderAccessBroker(environment: .init(
            isSandboxed: sandboxed,
            savedFolders: { world.saved },
            restore: { folder in world.restored.append(folder); return true },
            waitUntilReady: {
                guard world.holdPanels else { return }
                await withCheckedContinuation { world.gates.append($0) }
            },
            prompt: { folder in
                world.prompts.append(FolderAccessBroker.canonicalPath(folder))
                return world.answer(folder)
            },
            save: { _ in true },
            didGrant: { world.granted.append($0) }))
    }

    private var root: URL!
    private var document: URL { root.appendingPathComponent("docs/README.md") }
    private func file(_ path: String) -> URL { root.appendingPathComponent(path) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderAccessBrokerTests-\(UUID().uuidString)", isDirectory: true)
        for folder in ["docs/badges/deep", "docs/images", "elsewhere"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Decline once: no further panel for ten pictures in that folder and
    /// below, all denied.
    func testDeclineOnceThenNeverAgainThisSession() async {
        let world = World()
        let access = broker(world)
        var results: [Bool] = []
        for index in 0..<10 {
            let picture = index % 2 == 0 ? "docs/badges/b\(index).svg" : "docs/badges/deep/b\(index).svg"
            results.append(await access.requestAccess(forFileAt: file(picture), documentURL: document,
                                                      explicit: false))
        }
        XCTAssertEqual(results, Array(repeating: false, count: 10))
        XCTAssertEqual(world.prompts, [FolderAccessBroker.canonicalPath(file("docs"))],
                       "one panel, for the DOCUMENT's folder")
        XCTAssertEqual(access.decision(forFileAt: file("docs/images/x.png"), documentURL: document, explicit: false),
                       .declined, "a sibling subfolder of the declined document folder too")
    }

    /// Granting the document's folder covers its subfolders: no panel for them.
    func testGrantingTheDocumentFolderCoversSubfolders() async {
        let world = World()
        world.answer = { $0 }
        let access = broker(world)
        let first = await access.requestAccess(forFileAt: file("docs/badges/a.svg"), documentURL: document,
                                               explicit: false)
        XCTAssertTrue(first)
        for picture in ["docs/badges/b.svg", "docs/badges/deep/c.svg", "docs/images/d.png", "docs/e.png"] {
            let granted = await access.requestAccess(forFileAt: file(picture), documentURL: document, explicit: false)
            XCTAssertTrue(granted, picture)
        }
        XCTAssertEqual(world.prompts.count, 1)
        XCTAssertEqual(world.granted.map(FolderAccessBroker.canonicalPath), [FolderAccessBroker.canonicalPath(file("docs"))])
        // Outside the document's folder: its own folder is asked for.
        _ = await access.requestAccess(forFileAt: file("elsewhere/x.png"), documentURL: document, explicit: false)
        XCTAssertEqual(world.prompts.last, FolderAccessBroker.canonicalPath(file("elsewhere")))
    }

    /// The explicit Grant asks again after a decline, and a grant clears it.
    func testExplicitGrantAsksAgainAfterADecline() async {
        let world = World()
        let access = broker(world)
        let declined = await access.requestAccess(forFileAt: file("docs/badges/a.svg"), documentURL: document,
                                                  explicit: false)
        XCTAssertFalse(declined)
        world.answer = { $0 }
        let quiet = await access.requestAccess(forFileAt: file("docs/badges/a.svg"), documentURL: document,
                                               explicit: false)
        XCTAssertFalse(quiet, "not explicit: still declined, no panel")
        XCTAssertEqual(world.prompts.count, 1)
        let explicit = await access.requestAccess(forFileAt: file("docs/badges/a.svg"), documentURL: document,
                                                  explicit: true)
        XCTAssertTrue(explicit)
        XCTAssertEqual(world.prompts.count, 2)
        XCTAssertTrue(access.declinedFolders.isEmpty, "the grant cleared the decline it covers")
    }

    /// Two pictures asking while the panel is up share its answer.
    func testConcurrentRequestsShareOnePanel() async {
        let world = World()
        world.holdPanels = true
        world.answer = { $0 }
        let access = broker(world)
        async let first = access.requestAccess(forFileAt: file("docs/badges/a.svg"), documentURL: document,
                                               explicit: false)
        async let second = access.requestAccess(forFileAt: file("docs/images/b.png"), documentURL: document,
                                                explicit: false)
        // Let both start; then answer the panel(s).
        for _ in 0..<50 { await Task.yield() }
        world.holdPanels = false
        world.gates.forEach { $0.resume() }
        world.gates.removeAll()
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(world.prompts.count, 1)
    }

    /// A saved bookmark for an ANCESTOR serves the file, through `/tmp` vs
    /// `/private/tmp` style symlinks; no panel.
    func testSavedBookmarkOfAnAncestorIsRestoredWithoutAPanel() async {
        let world = World()
        let real = FolderAccessBroker.canonicalPath(file("docs"))
        // The temp directory lives under a symlink (`/var` → `/private/var`):
        // save the unresolved form, ask with the resolved one.
        world.saved = [file("docs")]
        let access = broker(world)
        let granted = await access.requestAccess(forFileAt: URL(fileURLWithPath: real + "/badges/deep/x.svg"),
                                                 documentURL: document, explicit: false)
        XCTAssertTrue(granted)
        XCTAssertTrue(world.prompts.isEmpty)
        XCTAssertEqual(world.restored.count, 1)
        XCTAssertTrue(access.restoreWithoutAsking(forFileAt: file("docs/images/y.png")))
        XCTAssertFalse(access.restoreWithoutAsking(forFileAt: file("elsewhere/z.png")))
        XCTAssertTrue(world.prompts.isEmpty, "print never asks")
    }

    /// The GitHub/Homebrew build (no sandbox) never asks.
    func testUnsandboxedNeverAsks() async {
        let world = World()
        world.answer = { $0 }
        let access = broker(world, sandboxed: false)
        let granted = await access.requestAccess(forFileAt: file("docs/badges/a.svg"), documentURL: document,
                                                 explicit: true)
        XCTAssertFalse(granted)
        XCTAssertTrue(world.prompts.isEmpty)
    }

    func testCoversAndFolderToAsk() {
        XCTAssertTrue(FolderAccessBroker.covers("/a/b", "/a/b/c.png"))
        XCTAssertTrue(FolderAccessBroker.covers("/a/b", "/a/b"))
        XCTAssertFalse(FolderAccessBroker.covers("/a/b", "/a/bc/x.png"), "a prefix of a NAME is not a folder")
        XCTAssertTrue(FolderAccessBroker.covers("/", "/x"))
        XCTAssertEqual(FolderAccessBroker.folderToAsk(forFileAt: file("docs/badges/a.svg"), documentURL: document)
                        .standardizedFileURL.path, file("docs").standardizedFileURL.path)
        XCTAssertEqual(FolderAccessBroker.folderToAsk(forFileAt: file("elsewhere/a.svg"), documentURL: document)
                        .standardizedFileURL.path, file("elsewhere").standardizedFileURL.path)
        XCTAssertEqual(FolderAccessBroker.folderToAsk(forFileAt: file("elsewhere/a.svg"), documentURL: nil)
                        .standardizedFileURL.path, file("elsewhere").standardizedFileURL.path)
    }
}
