import XCTest

/// `FolderListing` (File ▸ Open Folder, #62) on temporary trees: which
/// files are listed, in which order and groups, what is skipped, and the
/// depth and count limits. Plus the shared Markdown predicate.
final class FolderListingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderListingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ paths: String...) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("# x\n".utf8).write(to: url)
        }
    }

    /// The listing of a scan, nil when it did not list.
    private func listed(_ outcome: FolderListing.Outcome) -> FolderListing.Result? {
        if case .listed(let result) = outcome { return result }
        return nil
    }

    private func scan(_ limits: FolderListing.Limits = .init()) -> FolderListing.Result? {
        listed(FolderListing.scan(root, limits: limits))
    }

    /// The listing as "group: name name" lines, root group as "/".
    private func shape(_ result: FolderListing.Result?) -> [String] {
        (result?.groups ?? []).map { group in
            (group.relativePath.isEmpty ? "/" : group.relativePath) + ": "
                + group.files.map(\.lastPathComponent).joined(separator: " ")
        }
    }

    func testMarkdownPredicateTakesTheFourExtensionsInAnyCase() {
        for name in ["a.md", "b.MD", "c.markdown", "d.MarkDown", "e.mdown", "f.MDOWN", "g.mkd", "h.Mkd"] {
            XCTAssertTrue(MarkdownFileKind.isMarkdown(URL(fileURLWithPath: "/x/" + name)), name)
        }
        for name in ["a.txt", "b.mdx", "c.md.txt", "md", "d.rmd", "e.", "f"] {
            XCTAssertFalse(MarkdownFileKind.isMarkdown(URL(fileURLWithPath: "/x/" + name)), name)
        }
    }

    func testListsMarkdownFilesInAnyCaseAndNothingElse() throws {
        try make("a.md", "B.MARKDOWN", "c.Mdown", "d.mkd", "e.txt", "f.mdx", "g.html")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.md"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(shape(scan()), ["/: a.md B.MARKDOWN c.Mdown d.mkd"],
                       "a FOLDER named .md is no file")
    }

    func testFinderOrderAndGroupingByFolder() throws {
        try make("file10.md", "file2.md", "File1.md",
                 "docs/b.md", "docs/a.md", "docs/sub/z.md",
                 "Zeta/x.md", "alpha/y.md", "empty/notes.txt", "docs 2/q.md")
        XCTAssertEqual(shape(scan()), [
            "/: File1.md file2.md file10.md",
            "alpha: y.md",
            "docs: a.md b.md",
            "docs/sub: z.md",
            "docs 2: q.md",
            "Zeta: x.md",
        ], "root first; folders in Finder order, each before its own subfolders; no group without files")
    }

    func testSkipsHiddenFilesFoldersPackagesAndNodeModules() throws {
        try make("keep.md", ".hidden.md", ".git/HEAD.md", "flagged.md", "Tool.app/Contents/README.md",
                 "node_modules/pkg/README.md", "lib/node_modules/dep/README.md", "lib/real.md")
        var flagged = root.appendingPathComponent("flagged.md")
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)
        XCTAssertEqual(shape(scan()), ["/: keep.md", "lib: real.md"])
    }

    func testSymbolicLinksAreNeverFollowedSoALoopEnds() throws {
        try make("a.md", "sub/b.md")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("sub/loop"), withDestinationURL: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.md"),
                                  withDestinationURL: root.appendingPathComponent("a.md"))
        XCTAssertEqual(shape(scan()), ["/: a.md", "sub: b.md"])
    }

    func testDepthLimit() throws {
        var path = ""
        for level in 0...10 {
            try make(path + "f\(level).md")
            path += "d\(level + 1)/"
        }
        let listed = scan()?.files.map(\.lastPathComponent)
        XCTAssertEqual(listed, (0...8).map { "f\($0).md" }, "the root and 8 folders below it")
        let shallow = scan(.init(maxDepth: 2, maxFiles: 2_000))
        XCTAssertEqual(shallow?.files.map(\.lastPathComponent), ["f0.md", "f1.md", "f2.md"])
        XCTAssertEqual(shallow?.isTruncated, false, "depth is a limit of the walk, not truncation")
    }

    func testCountLimitTruncatesInDisplayOrder() throws {
        try make("a.md", "b.md", "c.md", "sub/d.md", "sub/e.md", "sub/deeper/f.md", "z/g.md")
        let limited = scan(.init(maxDepth: 8, maxFiles: 4))
        XCTAssertEqual(shape(limited), ["/: a.md b.md c.md", "sub: d.md"])
        XCTAssertEqual(limited?.isTruncated, true)
        let exact = scan(.init(maxDepth: 8, maxFiles: 7))
        XCTAssertEqual(exact?.files.count, 7)
        XCTAssertEqual(exact?.isTruncated, false, "exactly the limit is the whole folder")
        XCTAssertEqual(FolderListing.Limits().maxFiles, 2_000)
        XCTAssertEqual(FolderListing.Limits().maxDepth, 8)
    }

    func testPreferredFileIsTheRootReadmeElseTheFirstListed() throws {
        try make("guide.md", "ReadMe.md", "sub/README.md")
        XCTAssertEqual(scan()?.preferredFile?.lastPathComponent, "ReadMe.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("ReadMe.md"))
        XCTAssertEqual(scan()?.preferredFile?.lastPathComponent, "guide.md",
                       "a README in a subfolder does not count")
        try FileManager.default.removeItem(at: root.appendingPathComponent("guide.md"))
        XCTAssertEqual(scan()?.preferredFile?.lastPathComponent, "README.md",
                       "no root files: the first listed one")
        try FileManager.default.removeItem(at: root.appendingPathComponent("sub"))
        XCTAssertNil(scan()?.preferredFile)
        XCTAssertEqual(scan()?.groups, [], "an empty folder lists, with nothing in it")
    }

    func testGoneIsMissingAndAFolderThatCannotBeReadIsUnreadable() throws {
        try make("a.md", "locked/b.md")
        XCTAssertEqual(FolderListing.scan(root.appendingPathComponent("missing")), .missing)
        XCTAssertEqual(FolderListing.scan(root.appendingPathComponent("a.md")), .missing, "a file is no folder")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(FolderListing.scan(locked), .unreadable)
        XCTAssertEqual(shape(scan()), ["/: a.md"], "an unreadable subfolder is left out of the parent's listing")
    }

    func testTheEntryCapCountsEveryEntryButKeepsTheRootsFiles() throws {
        try make("r1.md", "r2.md", "r3.md", "r.txt", "a/x1.txt", "a/x2.txt", "a/m.md", "b/n.md")
        // The root's own entries are read whatever the cap; a/ (3 entries)
        // does not fit in 2, so it lists nothing and the walk stops.
        let capped = scan(.init(maxDepth: 8, maxFiles: 2_000, maxEntries: 2))
        XCTAssertEqual(shape(capped), ["/: r1.md r2.md r3.md"])
        XCTAssertEqual(capped?.isTruncated, true)
        let exact = scan(.init(maxDepth: 8, maxFiles: 2_000, maxEntries: 4))
        XCTAssertEqual(shape(exact), ["/: r1.md r2.md r3.md", "a: m.md", "b: n.md"])
        XCTAssertEqual(exact?.isTruncated, false, "3 entries in a/, 1 in b/: exactly the cap")
        let short = scan(.init(maxDepth: 8, maxFiles: 2_000, maxEntries: 3))
        XCTAssertEqual(shape(short), ["/: r1.md r2.md r3.md", "a: m.md"])
        XCTAssertEqual(short?.isTruncated, true)
        XCTAssertEqual(FolderListing.Limits().maxEntries, 20_000)
    }

    func testAScanStopsWhenCancelled() throws {
        try make("a/1.md", "b/2.md", "c/3.md", "d/4.md")
        var asked = 0
        let outcome = FolderListing.scan(root, isCancelled: {
            asked += 1
            return asked >= 2
        })
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(asked, 2, "asked between folders, stopped at the first yes")
    }

    /// Volume roots are never entered. `/System/Volumes` holds only volume
    /// roots (Data, Preboot, VM…); `Data` has the same volumeIdentifier as
    /// `/` (firmlinks), so only the `isVolume` test keeps the walk out.
    func testVolumeRootsAreNeverEntered() throws {
        let volumes = URL(fileURLWithPath: "/System/Volumes", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: volumes.appendingPathComponent("Data").path))
        var visited: [String] = []
        _ = FolderListing.scan(volumes, limits: .init(maxDepth: 1, maxFiles: 10, maxEntries: 100),
                               didVisit: { visited.append($0) })
        XCTAssertFalse(visited.contains("Data"), "\(visited)")
        XCTAssertFalse(visited.contains("Preboot"), "\(visited)")
    }

    /// Finder order is a STRICT total order on distinct names (exactly one
    /// of a<b, b<a), including names `localizedStandardCompare` might call
    /// equal (case, NFC vs NFD, widths, leading zeros): two scans of one
    /// tree sort it the same way. Equal names are not ordered.
    func testFinderOrderIsAStrictTotalOrder() {
        XCTAssertTrue(FolderListing.finderOrder("file2", "file10"))
        let names = ["a.md", "A.md", "\u{E9}.md", "e\u{301}.md", "file1.md", "file01.md", "\u{FF41}.md",
                     "a b.md", "a-b.md", "b.md"]
        for a in names {
            XCTAssertFalse(FolderListing.finderOrder(a, a), a)
            for b in names where a.unicodeScalars.elementsEqual(b.unicodeScalars) == false {
                XCTAssertNotEqual(FolderListing.finderOrder(a, b), FolderListing.finderOrder(b, a), "\(a) / \(b)")
            }
        }
    }

    /// The watcher's event filter and the scan share the name rule.
    func testIrrelevantChangesAreThoseUnderSkippedNames() {
        let base = "/r/Notes"
        for path in ["/r/Notes/.git", "/r/Notes/.git/objects/ab/", "/r/Notes/node_modules/x",
                     "/r/Notes/docs/node_modules", "/r/Notes/docs/.cache/y"] {
            XCTAssertFalse(FolderListing.isRelevantChange(atPath: path, root: base), path)
        }
        for path in ["/r/Notes", "/r/Notes/", "/r/Notes/docs", "/r/Notes/docs/sub/", "/r", "/elsewhere",
                     "/r/Notes2/.git"] {
            XCTAssertTrue(FolderListing.isRelevantChange(atPath: path, root: base), path)
        }
        XCTAssertTrue(FolderListing.isSkippedName(".git"))
        XCTAssertTrue(FolderListing.isSkippedName("node_modules"))
        XCTAssertFalse(FolderListing.isSkippedName("docs"))
    }
}
