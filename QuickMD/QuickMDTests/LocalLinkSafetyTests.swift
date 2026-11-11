import XCTest

/// `LocalLinkSafety`: a link to a local program or script is confirmed
/// before `NSWorkspace.open` runs it; documents, folders, pictures and
/// Markdown files open as before. Real temp files: the verdict reads the
/// type Launch Services assigns and the executable bit.
final class LocalLinkSafetyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLinkSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func file(_ name: String, _ contents: String = "x", executable: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    private func directory(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDocumentsFoldersAndPicturesOpenAsBefore() throws {
        for name in ["notes.md", "README.markdown", "paper.pdf", "photo.png", "logo.svg", "data.csv",
                     "page.html", "letter.rtf", "archive.zip", "LICENSE", "plain.txt"] {
            XCTAssertEqual(LocalLinkSafety.verdict(for: try file(name)), .open, name)
        }
        XCTAssertEqual(LocalLinkSafety.verdict(for: try directory("docs")), .open, "a folder")
        // Executable bit on a plain document (unpacked from a ZIP): Preview
        // or TextEdit opens it, nothing runs.
        for name in ["scan.pdf", "shot.png", "readme.txt"] {
            XCTAssertEqual(LocalLinkSafety.verdict(for: try file(name, executable: true)), .open, "+x \(name)")
        }
        // A missing ordinary file: as before (NSWorkspace reports it).
        XCTAssertEqual(LocalLinkSafety.verdict(for: folder.appendingPathComponent("gone.pdf")), .open)
    }

    func testProgramsAndScriptsAreConfirmed() throws {
        for name in ["run.command", "setup.sh", "build.zsh", "tool.py", "Old.terminal", "Do.scpt",
                     "lib.jar", "Install.pkg", "Disk.dmg", "Run.applescript", "Name.tool"] {
            XCTAssertEqual(LocalLinkSafety.verdict(for: try file(name, "#!/bin/sh\necho hi\n")), .confirm, name)
        }
        for name in ["Calculator.app", "Steps.workflow", "Thing.action", "Pane.prefPane"] {
            XCTAssertEqual(LocalLinkSafety.verdict(for: try directory(name)), .confirm, name)
        }
        // By name even when it is not there (sandbox: unreadable).
        XCTAssertEqual(LocalLinkSafety.verdict(for: folder.appendingPathComponent("tools/run.command")), .confirm)
        // Extension case does not matter.
        XCTAssertEqual(LocalLinkSafety.verdict(for: try file("RUN.COMMAND")), .confirm)
    }

    /// The executable bit decides where the name says nothing.
    func testExtensionlessExecutableIsConfirmedAndItsSymlinkToo() throws {
        let tool = try file("deploy", "#!/bin/sh\necho hi\n", executable: true)
        XCTAssertEqual(LocalLinkSafety.verdict(for: tool), .confirm)
        XCTAssertEqual(LocalLinkSafety.verdict(for: try file("notes", "plain words")), .open, "no +x: a document")
        let link = folder.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        XCTAssertEqual(LocalLinkSafety.verdict(for: link), .confirm, "a link named like a document")
    }

    // MARK: - Review 2: aliases, stored URLs, names, re-check

    private func alias(_ name: String, to target: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let data = try target.bookmarkData(options: .suitableForBookmarkFile,
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: url)
        return url
    }

    /// A Finder alias is followed to its target, whatever it is named.
    func testAliasesAreResolvedAndJudgedByTheirTarget() throws {
        let tool = try file("deploy", "#!/bin/sh\necho hi\n", executable: true)
        let named = try alias("ReadMe.pdf", to: tool)
        XCTAssertEqual(try named.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile, true, "fixture is an alias")
        let check = LocalLinkSafety.check(named)
        XCTAssertEqual(check.verdict, .confirm)
        XCTAssertEqual(check.target.lastPathComponent, "deploy")
        let app = try directory("Tool.app")
        XCTAssertEqual(LocalLinkSafety.verdict(for: try alias("Notes", to: app)), .confirm)
        // An alias to a document opens the document, without asking.
        let pdf = try file("paper.pdf")
        let toPDF = LocalLinkSafety.check(try alias("Paper alias", to: pdf))
        XCTAssertEqual(toPDF.verdict, .open)
        XCTAssertEqual(toPDF.target.resolvingSymlinksInPath().path, pdf.resolvingSymlinksInPath().path)
    }

    /// alias → symlink → alias → tool: followed to the end.
    func testAliasSymlinkAliasChainIsFollowed() throws {
        let tool = try file("deploy", "#!/bin/sh\n", executable: true)
        let inner = try alias("inner", to: tool)
        let link = folder.appendingPathComponent("middle.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inner)
        let outer = try alias("outer.pdf", to: link)
        let check = LocalLinkSafety.check(outer)
        XCTAssertEqual(check.verdict, .confirm)
        XCTAssertEqual(check.target.lastPathComponent, "deploy")
    }

    /// An alias whose target is gone cannot be judged: ask.
    func testUnresolvableAliasAsks() throws {
        let doomed = try file("gone-soon.pdf")
        let dangling = try alias("Report.pdf", to: doomed)
        try FileManager.default.removeItem(at: doomed)
        XCTAssertEqual(LocalLinkSafety.verdict(for: dangling), .confirm)
    }

    /// Files whose opening follows a stored URL or runs a session/script.
    func testStoredURLsTerminalSessionsAndPythonLauncherFilesAsk() throws {
        for name in ["a.webloc", "a.inetloc", "a.fileloc", "a.afploc", "a.ftploc", "a.vncloc", "a.mailloc",
                     "a.newsloc", "a.url", "a.term", "a.pyw", "a.pyo", "a.pyz", "a.pyc"] {
            XCTAssertEqual(LocalLinkSafety.verdict(for: try file(name)), .confirm, name)
        }
    }

    /// The confirmation names the resolved file, says when the link's own
    /// name differs, and never shows bidi controls or line breaks.
    func testConfirmationNamesTheTargetSafely() throws {
        let tool = try file("deploy", "#!/bin/sh\n", executable: true)
        let link = folder.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        let check = LocalLinkSafety.check(link)
        XCTAssertEqual(LocalLinkSafety.confirmationTitle(check: check), "Open \u{201C}deploy\u{201D}?")
        XCTAssertEqual(LocalLinkSafety.confirmationMessage(link: link, check: check),
                       "This link opens a program or script on your Mac.\n"
                       + "\u{201C}innocent.txt\u{201D} points to \u{201C}deploy\u{201D}.")
        let direct = LocalLinkSafety.check(tool)
        XCTAssertEqual(LocalLinkSafety.confirmationMessage(link: tool, check: direct),
                       "This link opens a program or script on your Mac.")

        // RLO: `a<U+202E>txt.command` would read "adnammoc.txt".
        let spoof = try file("a\u{202E}txt.command")
        let spoofCheck = LocalLinkSafety.check(spoof)
        XCTAssertEqual(spoofCheck.verdict, .confirm)
        XCTAssertEqual(LocalLinkSafety.confirmationTitle(check: spoofCheck), "Open \u{201C}atxt.command\u{201D}?")
        XCTAssertEqual(LocalLinkSafety.displayName("x\u{2066}y\u{2069}\u{200F}z\nw\tv\u{0007}.sh"), "xyz w v.sh")
        XCTAssertEqual(LocalLinkSafety.displayName(String(repeating: "n", count: 300) + ".command").count, 80)
        XCTAssertEqual(LocalLinkSafety.displayName("👨‍👩‍👧 Report.pdf"), "👨‍👩‍👧 Report.pdf", "ZWJ emoji kept")
    }

    /// The second check after the alert sees a file that changed.
    func testCheckChangesWhenTheFileIsReplaced() throws {
        let doc = try file("report", "words")
        let before = LocalLinkSafety.check(doc)
        XCTAssertEqual(before.verdict, .open)
        XCTAssertEqual(LocalLinkSafety.check(doc), before, "stable while nothing changes")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: doc.path)
        XCTAssertNotEqual(LocalLinkSafety.check(doc), before)
    }
}
