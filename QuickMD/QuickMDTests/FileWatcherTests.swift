import XCTest

/// FileWatcher (auto-reload) behavior tests, including the atomic-save case
/// that real editors (VS Code, Zed, vim) use: write temp file, rename over
/// the original. ExternalEditorManager detection sanity checks included.
/// (FileWatcher is main-thread-by-convention, not @MainActor; XCTest drives
/// the main run loop during wait(for:) so DispatchQueue.main callbacks fire.)
final class FileWatcherTests: XCTestCase {

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

        wait(for: [changed], timeout: 3)
    }

    func testAtomicSaveFiresOnChangeAndKeepsWatching() throws {
        // First atomic save (temp file + rename, like real editors)
        let firstChange = expectation(description: "onChange after atomic save")
        watcher.onChange = { firstChange.fulfill() }
        watcher.onFileMissing = { XCTFail("atomic save must not be reported as missing") }
        watcher.start(watching: fileURL)

        try "replaced once".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [firstChange], timeout: 3)

        // The watcher must have re-armed on the NEW inode — a second atomic
        // save must fire again (this is where naive watchers go dead).
        let secondChange = expectation(description: "onChange after second atomic save")
        watcher.onChange = { secondChange.fulfill() }
        try "replaced twice".write(to: fileURL, atomically: true, encoding: .utf8)
        wait(for: [secondChange], timeout: 3)
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

        wait(for: [changed], timeout: 3)
        // Give the debounce window time to (incorrectly) fire again
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(changeCount, 1, "rapid writes must coalesce into a single reload")
    }

    func testDeleteReportsFileMissing() throws {
        let missing = expectation(description: "onFileMissing after delete")
        watcher.onChange = { XCTFail("delete must not be reported as a change") }
        watcher.onFileMissing = { missing.fulfill() }
        watcher.start(watching: fileURL)

        try FileManager.default.removeItem(at: fileURL)
        wait(for: [missing], timeout: 3)
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
