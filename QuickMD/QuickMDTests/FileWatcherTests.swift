import XCTest

/// FileWatcher (auto-reload) behavior tests, including the atomic-save case
/// that real editors (VS Code, Zed, vim) use: write temp file, rename over
/// the original. ExternalEditorManager detection sanity checks included.
/// (FileWatcher is main-thread-by-convention, not @MainActor; XCTest drives
/// the main run loop during wait(for:) so DispatchQueue.main callbacks fire.)
final class FileWatcherTests: XCTestCase {

    /// How long a wait may take before the test fails. Only an upper bound:
    /// a passing wait ends when its event arrives, and a "settle" wait when
    /// its own `asyncAfter` fires — a short bound only made the tests fail on
    /// a loaded machine (an expectation fulfilled 3.1 s late is no bug).
    private static let timeout: TimeInterval = 15

    private var tempDir: URL!
    private var fileURL: URL!
    private var watcher: FileWatcher!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickmd-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("watched.md")
        try "initial".write(to: fileURL, atomically: false, encoding: .utf8)
        watcher = FileWatcher()
    }

    override func tearDown() async throws {
        watcher.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInPlaceWriteFiresOnChange() throws {
        let changed = expectation(description: "onChange after in-place write")
        watcher.onChange = { changed.fulfill() }
        watcher.start(watching: fileURL)

        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data(" appended".utf8))
        try handle.close()

        wait(for: [changed], timeout: Self.timeout)
    }

    func testAtomicSaveFiresOnChangeAndKeepsWatching() throws {
        // First atomic save (temp file + rename, like real editors)
        let firstChange = expectation(description: "onChange after atomic save")
        watcher.onChange = { firstChange.fulfill() }
        watcher.onFileMissing = { XCTFail("atomic save must not be reported as missing") }
        watcher.start(watching: fileURL)

        try "replaced once".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [firstChange], timeout: Self.timeout)

        // The watcher must have re-armed on the NEW inode — a second atomic
        // save must fire again (this is where naive watchers go dead).
        let secondChange = expectation(description: "onChange after second atomic save")
        watcher.onChange = { secondChange.fulfill() }
        try "replaced twice".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [secondChange], timeout: Self.timeout)
    }

    func testRapidWritesCoalesceIntoOneCallback() throws {
        var changeCount = 0
        let changed = expectation(description: "debounced onChange")
        watcher.onChange = {
            changeCount += 1
            changed.fulfill()
        }
        watcher.start(watching: fileURL)

        // Three writes within the 250 ms debounce window
        for i in 1...3 {
            try "write \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        wait(for: [changed], timeout: Self.timeout)
        // Give the debounce window time to (incorrectly) fire again
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settle.fulfill() }
        wait(for: [settle], timeout: Self.timeout)
        XCTAssertEqual(changeCount, 1, "rapid writes must coalesce into a single reload")
    }

    func testDeleteReportsFileMissing() throws {
        let missing = expectation(description: "onFileMissing after delete")
        watcher.onChange = { XCTFail("delete must not be reported as a change") }
        watcher.onFileMissing = { missing.fulfill() }
        watcher.start(watching: fileURL)

        try FileManager.default.removeItem(at: fileURL)
        wait(for: [missing], timeout: Self.timeout)
    }

    /// git checkout / stash pop: the file is gone for a while, then back at
    /// the same path. The watcher polls once a second while missing, re-arms
    /// and reports a change — and keeps watching the new file afterwards.
    func testRecreatedFileFiresOnChangeAndRearms() throws {
        let missing = expectation(description: "onFileMissing after delete")
        watcher.onFileMissing = { missing.fulfill() }
        watcher.start(watching: fileURL)

        try FileManager.default.removeItem(at: fileURL)
        wait(for: [missing], timeout: Self.timeout)

        let back = expectation(description: "onChange after the file is recreated")
        watcher.onFileMissing = { XCTFail("recreation must not be reported as missing") }
        watcher.onChange = { back.fulfill() }
        try "recreated".write(to: fileURL, atomically: false, encoding: .utf8)
        wait(for: [back], timeout: Self.timeout)

        let again = expectation(description: "onChange after a write to the recreated file")
        watcher.onChange = { again.fulfill() }
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data(" more".utf8))
        try handle.close()
        wait(for: [again], timeout: Self.timeout)
    }

    func testStartOnMissingPathThenCreatedFiresOnChange() throws {
        let later = tempDir.appendingPathComponent("not-yet.md")
        var missingCount = 0
        watcher.onFileMissing = { missingCount += 1 }
        let created = expectation(description: "onChange once the file appears")
        watcher.onChange = { created.fulfill() }
        watcher.start(watching: later)
        XCTAssertEqual(missingCount, 1, "a path that does not exist is reported missing at start")

        try "now here".write(to: later, atomically: false, encoding: .utf8)
        wait(for: [created], timeout: Self.timeout)
        XCTAssertEqual(missingCount, 1)
    }

    /// Gone, back, gone again, back again: each disappearance is reported,
    /// each return recovers — the re-armed source is a full watcher again.
    func testSecondDisappearanceAfterRearmIsReportedAndRecovers() throws {
        var missingCount = 0
        watcher.start(watching: fileURL)

        for round in 1...2 {
            let missing = expectation(description: "onFileMissing, round \(round)")
            watcher.onFileMissing = {
                missingCount += 1
                missing.fulfill()
            }
            try FileManager.default.removeItem(at: fileURL)
            wait(for: [missing], timeout: Self.timeout)
            XCTAssertEqual(missingCount, round)

            let back = expectation(description: "recovery, round \(round)")
            watcher.onChange = { back.fulfill() }
            try "round \(round)".write(to: fileURL, atomically: false, encoding: .utf8)
            wait(for: [back], timeout: Self.timeout)
            watcher.onChange = nil
        }
        XCTAssertEqual(missingCount, 2)
    }

    func testFileMissingFiresOncePerDisappearance() throws {
        var missingCount = 0
        watcher.onFileMissing = { missingCount += 1 }
        watcher.onChange = { XCTFail("nothing came back") }
        watcher.start(watching: fileURL)

        try FileManager.default.removeItem(at: fileURL)
        // Long enough for two polls.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { settle.fulfill() }
        wait(for: [settle], timeout: Self.timeout)
        XCTAssertEqual(missingCount, 1, "the poll must not re-report the missing file")
    }

    /// The file comes back but cannot be opened (mode 000 → EACCES): the poll
    /// stops instead of failing every second and reports it unreadable, once —
    /// restoring the permissions later is NOT noticed (pre-poll behaviour).
    func testPermissionDeniedAfterReturnStopsThePoll() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        var missingCount = 0
        var unreadableCount = 0
        let denied = expectation(description: "a poll found it unreadable")
        watcher.onFileUnreadable = {
            unreadableCount += 1
            denied.fulfill()
        }
        let missing = expectation(description: "onFileMissing after delete")
        watcher.onFileMissing = {
            missingCount += 1
            missing.fulfill()
        }
        watcher.onChange = { XCTFail("an unopenable file must not be reported as changed") }
        watcher.start(watching: fileURL)

        try FileManager.default.removeItem(at: fileURL)
        wait(for: [missing], timeout: Self.timeout)
        try "locked".write(to: fileURL, atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(fileURL.path, 0), 0)
        defer { chmod(fileURL.path, 0o644) }

        // One poll sees it, fails to open it, reports it, stops.
        wait(for: [denied], timeout: Self.timeout)

        XCTAssertEqual(chmod(fileURL.path, 0o644), 0)
        let settle = expectation(description: "no poll after the denial")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settle.fulfill() }
        wait(for: [settle], timeout: Self.timeout)
        XCTAssertEqual(missingCount, 1)
        XCTAssertEqual(unreadableCount, 1, "back, but off-limits: unreadable, not missing")
    }

    /// `chmod 000` on the open document (or a sandbox denial): the file is
    /// there, so the window must not say it no longer exists.
    func testUnreadableFileIsNotReportedAsMissing() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        watcher.onFileMissing = { XCTFail("an unreadable file is not a missing one") }
        watcher.onChange = { XCTFail("nothing changed") }
        var unreadableCount = 0
        var replaced: XCTestExpectation?
        watcher.onFileUnreadable = {
            unreadableCount += 1
            replaced?.fulfill()
        }
        XCTAssertEqual(chmod(fileURL.path, 0), 0)
        defer { chmod(fileURL.path, 0o644) }

        watcher.start(watching: fileURL)
        XCTAssertEqual(unreadableCount, 1, "reported at once, synchronously")

        // An atomic replace by an unreadable file: the same answer.
        XCTAssertEqual(chmod(fileURL.path, 0o644), 0)
        watcher.start(watching: fileURL)
        XCTAssertEqual(unreadableCount, 1, "armed")
        let replacement = tempDir.appendingPathComponent("replacement.md")
        try "locked".write(to: replacement, atomically: false, encoding: .utf8)
        XCTAssertEqual(chmod(replacement.path, 0), 0)
        replaced = expectation(description: "the replace is reported unreadable")
        XCTAssertEqual(rename(replacement.path, fileURL.path), 0)
        wait(for: [replaced!], timeout: Self.timeout)
        XCTAssertEqual(unreadableCount, 2)

        XCTAssertEqual(FileWatcher.Problem.missing.bannerText(path: "/a/b.md"), "File no longer exists at /a/b.md")
        XCTAssertEqual(FileWatcher.Problem.unreadable.bannerText(path: "/a/b.md"), "File can\u{2019}t be read at /a/b.md")
        XCTAssertEqual(FileWatcher.Problem.unreadable.bannerText(path: nil), "File can\u{2019}t be read at this location")
    }

    func testStopWhileMissingCancelsThePoll() throws {
        let missing = expectation(description: "onFileMissing after delete")
        watcher.onFileMissing = { missing.fulfill() }
        watcher.start(watching: fileURL)

        try FileManager.default.removeItem(at: fileURL)
        wait(for: [missing], timeout: Self.timeout)

        watcher.stop()
        watcher.onChange = { XCTFail("a stopped watcher must not report the recreated file") }
        watcher.onFileMissing = { XCTFail("a stopped watcher must not report anything") }
        try "recreated".write(to: fileURL, atomically: false, encoding: .utf8)

        // Longer than one poll interval plus the debounce.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { settle.fulfill() }
        wait(for: [settle], timeout: Self.timeout)
    }

    // MARK: - ExternalEditorManager

    func testKnownEditorBundleIDsAreUnique() {
        let ids = ExternalEditorManager.knownEditors.map(\.bundleID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains("pl.falami.studio.QuickMD"),
            "QuickMD must never be its own external editor")
    }

    func testTextEditFallbackResolves() {
        // TextEdit ships with every macOS — the last-resort fallback must exist.
        XCTAssertNotNil(ExternalEditorManager.appURL(for: "com.apple.TextEdit"))
    }

    func testInstalledEditorsIsSubsetOfKnown() {
        let installed = ExternalEditorManager.installedKnownEditors()
        let knownIDs = Set(ExternalEditorManager.knownEditors.map(\.bundleID))
        XCTAssertTrue(installed.allSatisfy { knownIDs.contains($0.bundleID) })
    }
}
