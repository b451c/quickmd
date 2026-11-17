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

    /// The cost cap counts FOLDERS READ (the root is one). A huge sibling
    /// never starves another: a vault whose `Attachments/` holds many
    /// pictures and whose `Notes/` holds the Markdown lists `Notes/` (under
    /// the 1.16 review's entry budget it read as "No Markdown files").
    func testTheFolderCapCountsFoldersReadAndAHugeSiblingStarvesNothing() throws {
        let fm = FileManager.default
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try fm.createDirectory(at: attachments, withIntermediateDirectories: true)
        for index in 0..<300 { fm.createFile(atPath: attachments.appendingPathComponent("p\(index).png").path, contents: nil) }
        try make("Notes/a.md", "Notes/b.md", "Zettel/c.md")
        let whole = scan(.init(maxDepth: 8, maxFiles: 2_000, maxFolders: 4))
        XCTAssertEqual(shape(whole), ["Notes: a.md b.md", "Zettel: c.md"])
        XCTAssertEqual(whole?.isTruncated, false, "root + three folders: exactly the cap")
        let capped = scan(.init(maxDepth: 8, maxFiles: 2_000, maxFolders: 3))
        XCTAssertEqual(shape(capped), ["Notes: a.md b.md"], "the folders read are listed whole")
        XCTAssertEqual(capped?.isTruncated, true)
        let starved = scan(.init(maxDepth: 8, maxFiles: 2_000, maxFolders: 2))
        XCTAssertEqual(starved?.groups, [], "only Attachments/ was read…")
        XCTAssertEqual(starved?.isTruncated, true, "…and the result says it is incomplete, never \"no files\"")
        XCTAssertEqual(FolderListing.Limits().maxFolders, 2_000)
    }

    /// The total of entries read bounds the walk: root (4 entries) + a/ (3)
    /// + b/ (3) = 10 passes a limit of 9 after the SECOND folder, so c/ is
    /// never read — the folders already read stay listed whole, truncated.
    /// The visit counter proves what was read.
    func testTheTotalOfEntriesReadStopsFurtherReads() throws {
        try make("r.md", "a/a.md", "a/x.txt", "a/y.txt", "b/b.md", "b/x.txt", "b/y.txt", "c/c.md")
        var visited: [String] = []
        let outcome = FolderListing.scan(root, limits: .init(maxDepth: 8, maxFiles: 2_000, maxFolders: 2_000,
                                                             maxEntriesRead: 9),
                                         didVisit: { visited.append($0) })
        XCTAssertEqual(visited, ["a", "b"], "c/ is not read")
        XCTAssertEqual(shape(listed(outcome)), ["/: r.md", "a: a.md", "b: b.md"])
        XCTAssertEqual(listed(outcome)?.isTruncated, true)
        // At exactly the limit after b/ the total has not passed it: c/ is read.
        visited = []
        let whole = FolderListing.scan(root, limits: .init(maxDepth: 8, maxFiles: 2_000, maxFolders: 2_000,
                                                           maxEntriesRead: 10),
                                       didVisit: { visited.append($0) })
        XCTAssertEqual(visited, ["a", "b", "c"])
        XCTAssertEqual(listed(whole)?.isTruncated, false, "nothing was left unread")
        // The root alone passing the limit: only the root is listed.
        let rootOnly = FolderListing.scan(root, limits: .init(maxDepth: 8, maxFiles: 2_000, maxFolders: 2_000,
                                                              maxEntriesRead: 3))
        XCTAssertEqual(shape(listed(rootOnly)), ["/: r.md"])
        XCTAssertEqual(listed(rootOnly)?.isTruncated, true)
        XCTAssertEqual(FolderListing.Limits().maxEntriesRead, 200_000)
    }

    /// The sidebar's lazy stack shows a file in both sections: its folder
    /// row and its recent row must never share an id, and the ids of one
    /// listing (headers and files) are unique.
    func testSidebarRowIdsAreDisjointBetweenSectionsAndUniqueInAListing() throws {
        try make("README.md", "notes.md", "docs/guide.md", "docs/a/notes.md", "docs a/guide.md",
                 "notes.md.d/x.md")
        let fm = FileManager.default
        try fm.linkItem(at: root.appendingPathComponent("notes.md"),
                        to: root.appendingPathComponent("docs/hard-link.md"))
        let listing = try XCTUnwrap(scan())
        var ids: [SidebarRowID] = []
        for group in listing.groups {
            if !group.relativePath.isEmpty { ids.append(group.rowID) }
            ids.append(contentsOf: group.files.map(\.sidebarFolderRowID))
        }
        XCTAssertEqual(Set(ids).count, ids.count, "no id twice in one listing")
        XCTAssertEqual(Set(listing.files.map(\.path)).count, listing.files.count, "no path listed twice")
        for url in listing.files {
            XCTAssertNotEqual(url.sidebarFolderRowID, url.sidebarRecentRowID, url.path)
            // A recent row's URL is the same file however it is spelled.
            XCTAssertNotEqual(url.sidebarFolderRowID, url.standardizedFileURL.sidebarRecentRowID)
        }
        // A group named like a file path is still a different case.
        XCTAssertNotEqual(SidebarRowID.folderGroup("docs"), SidebarRowID.folderFile("docs"))
        XCTAssertNotEqual(SidebarRowID.folderGroup("docs"), SidebarRowID.recent("docs"))
    }

    /// The file cap still cuts in display order.
    func testTheFileCapCutsInDisplayOrder() throws {
        try make("r1.md", "r2.md", "a/m1.md", "a/m2.md", "b/n.md")
        let capped = scan(.init(maxDepth: 8, maxFiles: 3, maxFolders: 2_000))
        XCTAssertEqual(shape(capped), ["/: r1.md r2.md", "a: m1.md"])
        XCTAssertEqual(capped?.isTruncated, true)
    }

    /// A parent without search permission: `stat` fails with EACCES — the
    /// folder is unreadable, not missing (it must not be forgotten).
    func testAFolderBehindAParentWithoutSearchPermissionIsUnreadableNotMissing() throws {
        try make("locked/inner/a.md")
        let locked = root.appendingPathComponent("locked")
        let inner = locked.appendingPathComponent("inner")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(LocalLinkOpening.existence(atPath: inner.path), .unknown, "the probe: stat says EACCES")
        XCTAssertEqual(FolderListing.scan(inner), .unreadable)
        XCTAssertEqual(FolderListing.scan(locked.appendingPathComponent("gone")), .unreadable,
                       "behind the locked parent even a missing name cannot be told missing")
        XCTAssertEqual(FolderListing.scan(root.appendingPathComponent("gone/inner")), .missing, "ENOENT")
        XCTAssertNotNil(FolderBrowserStore.restorableCanonicalPath(inner.path), "restore keeps it")
        XCTAssertNil(FolderBrowserStore.restorableCanonicalPath(root.appendingPathComponent("gone").path))
        try make("plain.md")
        XCTAssertNil(FolderBrowserStore.restorableCanonicalPath(root.appendingPathComponent("plain.md").path),
                     "a file is no folder")
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
        _ = FolderListing.scan(volumes, limits: .init(maxDepth: 1, maxFiles: 10, maxFolders: 100),
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
