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
}
