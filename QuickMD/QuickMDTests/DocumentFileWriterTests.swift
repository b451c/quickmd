import XCTest
import Darwin

/// Source Edit's in-place writer (S-D7 step 3) on real files: the content
/// changes and NOTHING else does — inode, permissions, xattrs, symlinks
/// (spec Evidence 2) — and a read-only or missing file is refused untouched.
final class DocumentFileWriterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFile(_ content: Data, named name: String = "doc.md") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url)
        return url
    }

    private func attribute(_ key: FileAttributeKey, _ url: URL) throws -> Any? {
        try FileManager.default.attributesOfItem(atPath: url.path)[key]
    }

    private func inode(_ url: URL) throws -> UInt64? {
        (try attribute(.systemFileNumber, url) as? NSNumber)?.uint64Value
    }

    // MARK: - Content

    func testLongerContentReplacesFile() throws {
        let old = Data("short\n".utf8)
        let new = Data("a much longer replacement text\n".utf8)
        let url = try makeFile(old)
        try DocumentFileWriter.write(new, to: url, restoring: old)
        XCTAssertEqual(try Data(contentsOf: url), new)
    }

    func testShorterContentLeavesNoStaleTail() throws {
        let old = Data("a much longer original text\n".utf8)
        let new = Data("short\n".utf8)
        let url = try makeFile(old)
        try DocumentFileWriter.write(new, to: url, restoring: old)
        XCTAssertEqual(try Data(contentsOf: url), new)
    }

    func testEmptyDataProducesEmptyFile() throws {
        let old = Data("content\n".utf8)
        let url = try makeFile(old)
        try DocumentFileWriter.write(Data(), to: url, restoring: old)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    // MARK: - Metadata survives

    func testInodeUnchanged() throws {
        let old = Data("one\n".utf8)
        let url = try makeFile(old)
        let before = try inode(url)
        XCTAssertNotNil(before)
        try DocumentFileWriter.write(Data("two two\n".utf8), to: url, restoring: old)
        XCTAssertEqual(try inode(url), before)
    }

    func testPermissionsUnchanged() throws {
        let old = Data("one\n".utf8)
        let url = try makeFile(old)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try DocumentFileWriter.write(Data("two\n".utf8), to: url, restoring: old)
        XCTAssertEqual((try attribute(.posixPermissions, url) as? NSNumber)?.intValue, 0o640)
    }

    func testExtendedAttributeSurvives() throws {
        let old = Data("one\n".utf8)
        let url = try makeFile(old)
        let name = "pl.falami.studio.QuickMD.test"
        let value = Array("tag-value".utf8)
        XCTAssertEqual(setxattr(url.path, name, value, value.count, 0, 0), 0)

        try DocumentFileWriter.write(Data("two\n".utf8), to: url, restoring: old)

        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(url.path, name, &buffer, buffer.count, 0, 0)
        XCTAssertEqual(length, value.count)
        XCTAssertEqual(Array(buffer.prefix(max(length, 0))), value)
    }

    func testSymlinkTargetUpdatedAndLinkKept() throws {
        let old = Data("target\n".utf8)
        let target = try makeFile(old, named: "target.md")
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let new = Data("through the link\n".utf8)
        try DocumentFileWriter.write(new, to: link, restoring: old)

        XCTAssertEqual(try Data(contentsOf: target), new)
        XCTAssertEqual(try attribute(.type, link) as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testHardLinkSeesNewContent() throws {
        let old = Data("shared\n".utf8)
        let url = try makeFile(old)
        let other = directory.appendingPathComponent("other-name.md")
        try FileManager.default.linkItem(at: url, to: other)

        let new = Data("written through the first name\n".utf8)
        try DocumentFileWriter.write(new, to: url, restoring: old)

        XCTAssertEqual(try Data(contentsOf: other), new)
        XCTAssertEqual(try inode(other), try inode(url))
        XCTAssertEqual((try attribute(.referenceCount, url) as? NSNumber)?.intValue, 2)
    }

    func testCreationDateUnchanged() throws {
        let old = Data("one\n".utf8)
        let url = try makeFile(old)
        // A date well in the past, so a replaced file could not match by accident.
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        try DocumentFileWriter.write(Data("two two\n".utf8), to: url, restoring: old)
        XCTAssertEqual(try attribute(.creationDate, url) as? Date, created)
    }

    // MARK: - Refusals

    func testReadOnlyFileRefusedAndUntouched() throws {
        let old = Data("read only\n".utf8)
        let url = try makeFile(old)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        XCTAssertThrowsError(try DocumentFileWriter.write(Data("new\n".utf8), to: url, restoring: old)) { error in
            guard case DocumentFileWriter.WriteError.readOnly = error else {
                return XCTFail("expected .readOnly, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), old)
        XCTAssertEqual((try attribute(.posixPermissions, url) as? NSNumber)?.intValue, 0o444)
    }

    func testMissingFileRefusedAndNotCreated() throws {
        let url = directory.appendingPathComponent("gone.md")
        XCTAssertThrowsError(try DocumentFileWriter.write(Data("new\n".utf8), to: url, restoring: Data())) { error in
            guard case DocumentFileWriter.WriteError.missing = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDanglingSymlinkCountsAsMissing() throws {
        let link = directory.appendingPathComponent("dangling.md")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: directory.appendingPathComponent("nowhere.md"))
        XCTAssertThrowsError(try DocumentFileWriter.write(Data("x".utf8), to: link, restoring: Data())) { error in
            guard case DocumentFileWriter.WriteError.missing = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("nowhere.md").path))
    }

    func testDirectoryRefusedAsNotRegularFile() throws {
        let url = directory.appendingPathComponent("folder.md", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let inside = url.appendingPathComponent("inside.txt")
        try Data("keep".utf8).write(to: inside)

        XCTAssertThrowsError(try DocumentFileWriter.write(Data("x".utf8), to: url, restoring: Data())) { error in
            guard case DocumentFileWriter.WriteError.notRegularFile = error else {
                return XCTFail("expected .notRegularFile, got \(error)")
            }
        }
        XCTAssertEqual(try attribute(.type, url) as? FileAttributeType, .typeDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), ["inside.txt"])
        XCTAssertEqual(try Data(contentsOf: inside), Data("keep".utf8))
    }

    /// Opening a FIFO for writing blocks until a reader appears — the type
    /// check must refuse it BEFORE any open (a regression hangs this test).
    func testFIFORefusedWithoutBlocking() throws {
        let url = directory.appendingPathComponent("pipe.md")
        XCTAssertEqual(mkfifo(url.path, 0o644), 0)
        XCTAssertThrowsError(try DocumentFileWriter.write(Data("x".utf8), to: url, restoring: Data())) { error in
            guard case DocumentFileWriter.WriteError.notRegularFile = error else {
                return XCTFail("expected .notRegularFile, got \(error)")
            }
        }
    }

    // MARK: - Rollback (through the injectable seam)

    private struct InjectedFailure: Error {}

    /// The real read-back, for seam calls that only fake one step.
    private func diskRead(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    private func original(of error: Error) -> DocumentFileWriter.WriteError.Original? {
        switch error {
        case DocumentFileWriter.WriteError.writeFailed(_, _, let original),
             DocumentFileWriter.WriteError.verificationFailed(_, let original):
            return original
        default:
            return nil
        }
    }

    func testFailureAfterFirstByteRestoresOriginal() throws {
        let old = Data("original content\n".utf8)
        let url = try makeFile(old)
        var calls = 0
        XCTAssertThrowsError(try DocumentFileWriter.write(
            Data("new".utf8), to: url, restoring: old,
            overwrite: { url, data, touched in
                calls += 1
                if calls == 1 {
                    touched = true
                    try Data("half-wri".utf8).write(to: url)   // a torn write
                    throw InjectedFailure()
                }
                try data.write(to: url)
            },
            readBack: diskRead)) { error in
            guard case DocumentFileWriter.WriteError.writeFailed(_, let underlying, _) = error else {
                return XCTFail("expected .writeFailed, got \(error)")
            }
            XCTAssertTrue(underlying is InjectedFailure)
            XCTAssertEqual(self.original(of: error), .restored)
        }
        XCTAssertEqual(calls, 2, "one write, one restore")
        XCTAssertEqual(try Data(contentsOf: url), old)
    }

    func testFailedRestoreReportsNotRestored() throws {
        let old = Data("original content\n".utf8)
        let url = try makeFile(old)
        var calls = 0
        XCTAssertThrowsError(try DocumentFileWriter.write(
            Data("new".utf8), to: url, restoring: old,
            overwrite: { url, _, touched in
                calls += 1
                touched = true
                try Data("torn".utf8).write(to: url)
                throw InjectedFailure()
            },
            readBack: diskRead)) { error in
            guard case DocumentFileWriter.WriteError.writeFailed = error else {
                return XCTFail("expected .writeFailed, got \(error)")
            }
            XCTAssertEqual(self.original(of: error), .notRestored)
        }
        XCTAssertEqual(calls, 2, "exactly one restore attempt")
    }

    func testFailureBeforeFirstByteReportsUntouched() throws {
        let old = Data("original content\n".utf8)
        let url = try makeFile(old)
        var calls = 0
        XCTAssertThrowsError(try DocumentFileWriter.write(
            Data("new".utf8), to: url, restoring: old,
            overwrite: { _, _, _ in
                calls += 1
                throw InjectedFailure()
            },
            readBack: diskRead)) { error in
            guard case DocumentFileWriter.WriteError.writeFailed = error else {
                return XCTFail("expected .writeFailed, got \(error)")
            }
            XCTAssertEqual(self.original(of: error), .untouched)
        }
        XCTAssertEqual(calls, 1, "nothing written, nothing to restore")
        XCTAssertEqual(try Data(contentsOf: url), old)
    }

    func testReadBackMismatchRestoresAndReportsVerificationFailed() throws {
        let old = Data("original content\n".utf8)
        let new = Data("new content\n".utf8)
        let url = try makeFile(old)
        var reads = 0
        XCTAssertThrowsError(try DocumentFileWriter.write(
            new, to: url, restoring: old,
            overwrite: { url, data, touched in
                touched = true
                try data.write(to: url)
            },
            readBack: { url in
                reads += 1
                return reads == 1 ? Data("garbled".utf8) : try? Data(contentsOf: url)
            })) { error in
            guard case DocumentFileWriter.WriteError.verificationFailed = error else {
                return XCTFail("expected .verificationFailed, got \(error)")
            }
            XCTAssertEqual(self.original(of: error), .restored)
        }
        XCTAssertEqual(try Data(contentsOf: url), old)
    }

    func testReadBackMismatchWithFailedRestoreReportsNotRestored() throws {
        let old = Data("original content\n".utf8)
        let url = try makeFile(old)
        XCTAssertThrowsError(try DocumentFileWriter.write(
            Data("new\n".utf8), to: url, restoring: old,
            overwrite: { url, data, touched in
                touched = true
                try data.write(to: url)
            },
            readBack: { _ in Data("garbled".utf8) })) { error in
            guard case DocumentFileWriter.WriteError.verificationFailed = error else {
                return XCTFail("expected .verificationFailed, got \(error)")
            }
            XCTAssertEqual(self.original(of: error), .notRestored)
        }
    }

    // MARK: - Error copy

    func testErrorDescriptionsNameTheFile() {
        let url = URL(fileURLWithPath: "/x/notes.md")
        typealias E = DocumentFileWriter.WriteError
        let errors: [E] = [
            .missing(url),
            .readOnly(url),
            .writeFailed(url, underlying: CocoaError(.fileWriteUnknown), original: .restored),
            .verificationFailed(url, original: .notRestored),
            .notRegularFile(url),
        ]
        for error in errors {
            XCTAssertTrue(error.localizedDescription.contains("“notes.md”"), error.localizedDescription)
        }
        XCTAssertEqual(E.readOnly(url).localizedDescription, "“notes.md” is read-only.")
    }
}
