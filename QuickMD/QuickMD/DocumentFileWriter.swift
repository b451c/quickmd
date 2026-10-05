import Foundation
import Darwin

/// Writes new bytes into an EXISTING file, in place (Source Edit, v1.12).
///
/// In place is the only strategy that keeps everything about the file except
/// its content — inode, hard links, symlinks, POSIX permissions, extended
/// attributes (Finder tags), creation date — and that refuses a read-only
/// file. `Data.write(options: .atomic)` and `replaceItemAt` both swap in a new
/// inode: the first drops xattrs, resets the creation date and overwrites a
/// 0444 file; the second leaves 0600 on APFS. Both also need a sibling temp
/// file, which the sandbox does not allow next to a user's document.
/// (Spec Evidence 2.)
///
/// Synchronous and free of AppKit / actor isolation: the caller decides where
/// it runs, and the CI SDK is older (see constraints).
enum DocumentFileWriter {

    enum WriteError: Error, LocalizedError {
        /// What became of the file's previous content after a failure.
        enum Original: Equatable {
            /// Failed before the first byte was written.
            case untouched
            /// The previous bytes were written back and read back intact.
            case restored
            /// The restore attempt failed too: the file may be damaged.
            case notRestored
        }

        case missing(URL)
        case readOnly(URL)
        /// A directory, FIFO, device… — anything but a regular file once
        /// symlinks are followed. Opening a FIFO for writing would block.
        case notRegularFile(URL)
        case writeFailed(URL, underlying: Error, original: Original)
        case verificationFailed(URL, original: Original)

        var errorDescription: String? {
            switch self {
            case .missing(let url):
                return "“\(url.lastPathComponent)” no longer exists."
            case .readOnly(let url):
                return "“\(url.lastPathComponent)” is read-only."
            case .notRegularFile(let url):
                return "“\(url.lastPathComponent)” is not a regular file and cannot be saved in place."
            case .writeFailed(let url, _, _):
                return "“\(url.lastPathComponent)” could not be saved."
            case .verificationFailed(let url, _):
                return "“\(url.lastPathComponent)” could not be saved: the file did not contain the saved text when read back."
            }
        }

        var failureReason: String? {
            switch self {
            case .missing, .readOnly, .notRegularFile:
                return nil
            case .writeFailed(_, let underlying, _):
                return underlying.localizedDescription
            case .verificationFailed:
                return nil
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .missing:
                return "Save a copy to keep your changes."
            case .readOnly:
                return "Change its permissions in the Finder, or save a copy."
            case .notRegularFile:
                return "Save a copy to keep your changes."
            case .writeFailed(_, _, let original), .verificationFailed(_, let original):
                switch original {
                case .untouched:
                    return "The file was not changed. Your edits are still in the editor."
                case .restored:
                    return "The file's previous content was restored. Your edits are still in the editor."
                case .notRestored:
                    return "The file's previous content could not be restored, so it may be damaged. Your edits are still in the editor — save a copy."
                }
            }
        }
    }

    /// Replaces the content of the file at `url` with `data`, then reads it
    /// back to verify. `original` is what the file held before (the session's
    /// `baseBytes`): if anything goes wrong once writing has started, ONE
    /// best-effort attempt puts it back, and the error says whether that worked.
    /// `restoring:` is what the CALLER last knew to be on disk: compare the
    /// disk with it immediately before calling (the conflict check), because
    /// a failed write restores exactly these bytes.
    static func write(_ data: Data, to url: URL, restoring original: Data) throws {
        try write(data, to: url, restoring: original,
                  overwrite: overwriteInPlace, readBack: readBack)
    }

    /// The in-place step: replaces the content and flips `touched` once the
    /// file may have been modified.
    typealias Overwrite = (_ url: URL, _ data: Data, _ touched: inout Bool) throws -> Void

    /// Test seam: `overwrite` and `readBack` are injectable so the rollback
    /// and verification paths can be driven without a failing disk. The
    /// public overload above always passes the real ones.
    static func write(_ data: Data, to url: URL, restoring original: Data,
                      overwrite: Overwrite, readBack: (URL) -> Data?) throws {
        let path = url.path
        // Follows symlinks, so a dangling link counts as missing.
        guard FileManager.default.fileExists(atPath: path) else {
            throw WriteError.missing(url)
        }
        // stat (not lstat): a symlink to a regular file is fine. Checked
        // before opening — `FileHandle(forWritingTo:)` on a FIFO blocks until
        // a reader appears, which would hang the main thread.
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw WriteError.notRegularFile(url)
        }
        guard FileManager.default.isWritableFile(atPath: path) else {
            throw WriteError.readOnly(url)
        }

        func restore() -> WriteError.Original {
            var ignored = false
            guard (try? overwrite(url, original, &ignored)) != nil,
                  readBack(url) == original else {
                return .notRestored
            }
            return .restored
        }

        var touched = false
        do {
            try overwrite(url, data, &touched)
        } catch {
            throw WriteError.writeFailed(url, underlying: error,
                                         original: touched ? restore() : .untouched)
        }

        guard readBack(url) == data else {
            throw WriteError.verificationFailed(url, original: restore())
        }
    }

    /// The in-place sequence. `FileHandle(forWritingTo:)` opens without
    /// O_CREAT — a file that vanished since the checks above is an error,
    /// never a new file. `touched` flips right before the first write so the
    /// caller knows whether a restore is needed.
    private static func overwriteInPlace(_ url: URL, _ data: Data, _ touched: inout Bool) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        touched = true
        try handle.write(contentsOf: data)
        // Without this a shorter text would leave the old tail behind.
        try handle.truncate(atOffset: UInt64(data.count))
        // After synchronize the bytes are on disk; a close error must not
        // turn a good save into a failure (and a restore) — the read-back
        // decides.
        try handle.synchronize()
    }

    private static func readBack(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
