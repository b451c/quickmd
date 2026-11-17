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
        XCTAssertEqual(shape(FolderListing.scan(root)), ["/: a.md B.MARKDOWN c.Mdown d.mkd"],
                       "a FOLDER named .md is no file")
    }

    func testFinderOrderAndGroupingByFolder() throws {
        try make("file10.md", "file2.md", "File1.md",
                 "docs/b.md", "docs/a.md", "docs/sub/z.md",
                 "Zeta/x.md", "alpha/y.md", "empty/notes.txt", "docs 2/q.md")
        XCTAssertEqual(shape(FolderListing.scan(root)), [
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
        XCTAssertEqual(shape(FolderListing.scan(root)), ["/: keep.md", "lib: real.md"])
    }

    func testSymbolicLinksAreNeverFollowedSoALoopEnds() throws {
        try make("a.md", "sub/b.md")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("sub/loop"), withDestinationURL: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.md"),
                                  withDestinationURL: root.appendingPathComponent("a.md"))
        XCTAssertEqual(shape(FolderListing.scan(root)), ["/: a.md", "sub: b.md"])
    }

    func testDepthLimit() throws {
        var path = ""
        for level in 0...10 {
            try make(path + "f\(level).md")
            path += "d\(level + 1)/"
        }
        let listed = FolderListing.scan(root)?.files.map(\.lastPathComponent)
        XCTAssertEqual(listed, (0...8).map { "f\($0).md" }, "the root and 8 folders below it")
        let shallow = FolderListing.scan(root, limits: .init(maxDepth: 2, maxFiles: 2_000))
        XCTAssertEqual(shallow?.files.map(\.lastPathComponent), ["f0.md", "f1.md", "f2.md"])
        XCTAssertEqual(shallow?.isTruncated, false, "depth is a limit of the walk, not truncation")
    }

    func testCountLimitTruncatesInDisplayOrder() throws {
        try make("a.md", "b.md", "c.md", "sub/d.md", "sub/e.md", "sub/deeper/f.md", "z/g.md")
        let limited = FolderListing.scan(root, limits: .init(maxDepth: 8, maxFiles: 4))
        XCTAssertEqual(shape(limited), ["/: a.md b.md c.md", "sub: d.md"])
        XCTAssertEqual(limited?.isTruncated, true)
        let exact = FolderListing.scan(root, limits: .init(maxDepth: 8, maxFiles: 7))
        XCTAssertEqual(exact?.files.count, 7)
        XCTAssertEqual(exact?.isTruncated, false, "exactly the limit is the whole folder")
        XCTAssertEqual(FolderListing.Limits().maxFiles, 2_000)
        XCTAssertEqual(FolderListing.Limits().maxDepth, 8)
    }

    func testPreferredFileIsTheRootReadmeElseTheFirstListed() throws {
        try make("guide.md", "ReadMe.md", "sub/README.md")
        XCTAssertEqual(FolderListing.scan(root)?.preferredFile?.lastPathComponent, "ReadMe.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("ReadMe.md"))
        XCTAssertEqual(FolderListing.scan(root)?.preferredFile?.lastPathComponent, "guide.md",
                       "a README in a subfolder does not count")
        try FileManager.default.removeItem(at: root.appendingPathComponent("guide.md"))
        XCTAssertEqual(FolderListing.scan(root)?.preferredFile?.lastPathComponent, "README.md",
                       "no root files: the first listed one")
        try FileManager.default.removeItem(at: root.appendingPathComponent("sub"))
        XCTAssertNil(FolderListing.scan(root)?.preferredFile)
        XCTAssertEqual(FolderListing.scan(root)?.groups, [], "an empty folder lists, with nothing in it")
    }

    func testAFolderThatIsGoneOrAFileListsNothing() throws {
        try make("a.md")
        XCTAssertNil(FolderListing.scan(root.appendingPathComponent("missing")))
        XCTAssertNil(FolderListing.scan(root.appendingPathComponent("a.md")))
    }
}
