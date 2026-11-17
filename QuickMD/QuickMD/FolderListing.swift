import Foundation
import CoreServices

// MARK: - Markdown file kind

/// THE test for "is this a Markdown file", by extension, any case. Shared by
/// the folder listing (which files the Documents sidebar lists) and the link
/// handler (which local links open in QuickMD rather than in their default
/// app), so the two can never disagree about a file. The list matches the
/// document types QuickMD declares in Info.plist.
enum MarkdownFileKind {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    private static let extensionBytes: [[UInt8]] = extensions.map { Array($0.utf8) }

    /// The same test on a file NAME's UTF-8 bytes, without allocating (the
    /// folder watcher's queue): the bytes after the last "." (not a leading
    /// one), ASCII case-insensitive.
    static func isMarkdownName(utf8 name: UnsafeBufferPointer<UInt8>) -> Bool {
        var dot = name.count - 1
        while dot > 0, name[dot] != UInt8(ascii: ".") { dot -= 1 }
        guard dot > 0 else { return false }
        let length = name.count - dot - 1
        return extensionBytes.contains { candidate in
            candidate.count == length && candidate.indices.allSatisfy { index in
                var byte = name[dot + 1 + index]
                if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
                return byte == candidate[index]
            }
        }
    }
}

// MARK: - Sidebar row identity

/// The identity of every row of the Documents sidebar's lazy stack while a
/// folder is open. A file may be listed in BOTH sections (a folder file the
/// reader opened is also a recent document), and two `ForEach`es in one
/// `LazyVStack` with the same explicit id for it left the recent row blank
/// after an insert or move (1.16 GUI E2E: space reserved, nothing drawn, not
/// in the accessibility tree). Each section has its own case, so the ids are
/// disjoint by construction:
/// - `folderGroup`: a subfolder header, by its relative path;
/// - `folderFile`: a listed file, by its path — unique within a listing,
///   because the walk reads every folder once (it reaches a folder only
///   through its parent: symbolic links are never followed, volume roots
///   are skipped, and APFS has no directory hard links), so no path is
///   listed twice; two hard links to one file are two paths, two rows;
/// - `recent`: a recent document, by its URL string.
enum SidebarRowID: Hashable {
    case folderGroup(String)
    case folderFile(String)
    case recent(String)

    static func folderFile(_ url: URL) -> SidebarRowID { .folderFile(url.path) }
    static func recent(_ url: URL) -> SidebarRowID { .recent(url.absoluteString) }
}

extension URL {
    /// This URL as a row of the open folder's list (`SidebarRowID`).
    var sidebarFolderRowID: SidebarRowID { .folderFile(self) }
    /// This URL as a recent-document row (`SidebarRowID`).
    var sidebarRecentRowID: SidebarRowID { .recent(self) }
}

// MARK: - Folder listing (File ▸ Open Folder, #62)

/// The Markdown files under a folder, grouped by the folder they sit in —
/// what the Documents sidebar lists after File ▸ Open Folder. A list to read
/// from, never a file manager.
///
/// Rules (and why):
/// - Recursive, but bounded in COST, not only in what is shown: at most
///   `Limits.maxDepth` folders deep, `Limits.maxFiles` files listed and
///   `Limits.maxFolders` folders read (the root is one) — someone WILL open
///   their home folder or "/", and the scan runs again on every change in
///   the tree. Either count limit makes the result `isTruncated`. Folders,
///   not entries: an entry budget let one huge `Attachments/` (20 000
///   pictures) starve its sibling `Notes/` and the vault read as "No
///   Markdown files". A folder that is read is read whole (one directory
///   read, not interruptible — accepted) and listed in Finder order; the
///   file cap cuts in display order. A TOTAL bounds the reads as well:
///   once the entries returned by all directory reads so far (the root's
///   included) pass `Limits.maxEntriesRead`, no further subfolder is read
///   and the result is truncated — without it the worst case was 2 000
///   folders × their size (photo exports, build outputs of 50–100k files),
///   re-read on every relevant event. A scan costs at most that total plus
///   one folder.
/// - Never onto another volume: a subfolder that is a volume's root, or
///   whose volume differs from the root's, is skipped ("/" must not walk
///   /Volumes or /System/Volumes/Data). Both tests are needed: measured on
///   macOS 27, `/System/Volumes/Data` reports the SAME `volumeIdentifier`
///   (and `st_dev`) as `/` — the APFS firmlink group — and only `isVolume`
///   tells it apart; a mounted disk under /Volumes differs in both.
/// - Skipped: hidden files and folders (`.git`, dot files, the Finder hidden
///   flag), packages (an `.app`, a `.textbundle` — one document to Finder),
///   `node_modules` (thousands of vendored READMEs nobody wants to read). The
///   name part of that rule is `isSkippedName`, shared with the watcher's
///   event filter (`isRelevantChange`) so the two never disagree.
/// - Symbolic links are never followed, to folders or files: a link back up
///   the tree would loop, and a link out of the folder would list (and in the
///   sandbox fail to open) files that are not in it.
/// - Order is Finder's (`localizedStandardCompare`: `file2` before `file10`;
///   ties such as `a.md` / `A.md` on a case-sensitive volume broken by the
///   code points, so two scans of one tree always agree), per path
///   component: the root's files first, then every subfolder in path order,
///   each before its own subfolders. The walk visits folders in exactly that
///   order, so the files kept under a limit are the first ones shown.
/// - Cancellable between folders (`isCancelled`): a closed or replaced
///   folder stops its scan early.
///
/// Pure (no app state), runs off the main thread; tested on temporary trees
/// (`FolderListingTests`).
enum FolderListing {
    struct Limits: Equatable, Sendable {
        /// Folders below the root that are still read (the root is 0).
        var maxDepth = 8
        /// Files listed at most; more makes the result truncated.
        var maxFiles = 2_000
        /// Folders read at most, the root included; more makes the result
        /// truncated.
        var maxFolders = 2_000
        /// Entries returned by all directory reads together (the root's
        /// included); past it no further folder is read (truncated).
        var maxEntriesRead = 200_000
    }

    /// The Markdown files directly inside one folder.
    struct Group: Equatable, Identifiable, Sendable {
        /// Path relative to the root, components joined by "/"; "" for the root.
        let relativePath: String
        let files: [URL]
        var id: String { relativePath }
        /// The subfolder header's sidebar row (`SidebarRowID`).
        var rowID: SidebarRowID { .folderGroup(relativePath) }
    }

    struct Result: Equatable, Sendable {
        /// Folders that hold Markdown files, in display order (root first).
        let groups: [Group]
        /// A limit stopped the walk: more files may exist than are listed.
        let isTruncated: Bool

        var files: [URL] { groups.flatMap(\.files) }

        /// What Open Folder opens when no document window is open: the root's
        /// README.md (any case), else the first listed file.
        var preferredFile: URL? {
            if let root = groups.first(where: { $0.relativePath.isEmpty }),
               let readme = root.files.first(where: { $0.lastPathComponent.lowercased() == "readme.md" }) {
                return readme
            }
            return groups.first?.files.first
        }
    }

    /// What a scan found: the listing, no such folder (gone — forget it), or
    /// a folder that exists but cannot be read now (keep it, try again).
    enum Outcome: Equatable, Sendable {
        case listed(Result)
        case missing
        case unreadable
        /// Stopped by `isCancelled`; nothing to publish.
        case cancelled
    }

    static let skippedFolderNames: Set<String> = ["node_modules"]

    /// The NAME part of the skip rule: hidden by a leading dot, or a folder
    /// nobody reads (`node_modules`). Shared by the scan and the watcher.
    /// Decided on the UTF-8 BYTES (a leading 0x2E; byte equality with
    /// `node_modules`), so the watcher's allocation-free byte rule
    /// (`ChangeFilter`) is exactly this rule — `String.hasPrefix` would
    /// compare graphemes (".\u{301}x" does not start with ".").
    static func isSkippedName(_ name: String) -> Bool {
        isSkippedName(utf8: name.utf8)
    }

    private static let nodeModulesUTF8 = Array("node_modules".utf8)
    private static let dotByte = UInt8(ascii: ".")
    private static let slashByte = UInt8(ascii: "/")

    static func isSkippedName<Bytes: Collection>(utf8 name: Bytes) -> Bool where Bytes.Element == UInt8 {
        guard let first = name.first else { return false }
        return first == dotByte || name.elementsEqual(nodeModulesUTF8)
    }

    /// A change at `path` (as FSEvents reports it) can change the listing of
    /// `root` (both canonical paths): false only when some component of the
    /// path below the root is a skipped name (`.git/objects/ab`,
    /// `node_modules/x`). Paths outside the root (the root itself moved)
    /// count as relevant.
    /// The reference form of the watcher's path rule (Strings; the watcher
    /// itself runs `ChangeFilter`, its allocation-free twin — a test proves
    /// they agree). Byte-wise prefix, like the twin.
    static func isRelevantChange(atPath path: String, root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        var trimmed = Array(path.utf8)
        if trimmed.last == slashByte { trimmed.removeLast() }
        guard trimmed.starts(with: base.utf8) else { return true }
        return !trimmed.dropFirst(base.utf8.count).split(separator: slashByte).contains { isSkippedName(utf8: $0) }
    }

    /// The watcher's rule for one event, on the stream's own queue and
    /// without allocating: flags first (an integer test), then the path's
    /// UTF-8 bytes after each spelling of the root, component by component
    /// (a leading "." or `node_modules` → not relevant). Exactly
    /// `isRelevantChange(_:roots:)` (tested over generated paths).
    struct ChangeFilter: Sendable {
        /// Each root spelling with one trailing "/".
        let bases: [[UInt8]]

        init(roots: [String]) {
            bases = roots.map { Array(($0.hasSuffix("/") ? $0 : $0 + "/").utf8) }
        }

        func isRelevant(flags: UInt32, path: UnsafeBufferPointer<UInt8>) -> Bool {
            guard FolderListing.isRelevantEventFlags(flags) else { return false }
            if flags & FolderListing.lookAgainFlags != 0 { return true }
            var end = path.count
            if end > 0, path[end - 1] == FolderListing.slashByte { end -= 1 }
            var start = end
            while start > 0, path[start - 1] != FolderListing.slashByte { start -= 1 }
            let name = UnsafeBufferPointer(rebasing: path[start..<end])
            if FolderListing.isNonMarkdownFileEvent(flags: flags, name: name) { return false }
            return bases.allSatisfy { Self.isRelevant(path: path, base: $0) }
        }

        static func isRelevant(path: UnsafeBufferPointer<UInt8>, base: [UInt8]) -> Bool {
            var end = path.count
            if end > 0, path[end - 1] == FolderListing.slashByte { end -= 1 }
            guard end >= base.count else { return true }
            for index in 0..<base.count where path[index] != base[index] { return true }
            var index = base.count
            while index < end {
                let start = index
                while index < end, path[index] != FolderListing.slashByte { index += 1 }
                let length = index - start
                if length > 0 {
                    if path[start] == FolderListing.dotByte { return false }
                    if length == FolderListing.nodeModulesUTF8.count,
                       FolderListing.nodeModulesUTF8.indices.allSatisfy({ path[start + $0] == FolderListing.nodeModulesUTF8[$0] }) {
                        return false
                    }
                }
                index += 1
            }
            return true
        }
    }

    /// One FSEvents item event: where, and what happened (the stream's
    /// `kFSEventStreamEventFlag…` bits).
    struct Change: Equatable, Sendable {
        let path: String
        let flags: UInt32
    }

    /// The flags that can change the listing:
    /// - an item created, removed or renamed (files appear / vanish);
    /// - a DIRECTORY's permissions or owner (`ItemChangeOwner` + `ItemIsDir`
    ///   — what `chmod` / `chown` of a folder delivers, probed on macOS 27:
    ///   `chmod 000 sub` → `…|ChangeOwner|IsDir` on `sub`, the root
    ///   included): a folder becomes unreadable or readable again;
    /// - anything that says "events were lost / look again" (must scan,
    ///   root changed, dropped, ids wrapped, mount, unmount), and an event
    ///   with no item flags at all (unknown).
    /// Not: a content write (`ItemModified`), a FILE's permissions
    /// (`ChangeOwner` + `IsFile`), xattrs, inode metadata (mtime) or Finder
    /// info — a busy tree writes those all the time and the listing (names
    /// only) cannot change.
    static func isRelevantEventFlags(_ flags: UInt32) -> Bool {
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                    | kFSEventStreamEventFlagItemRenamed)
        if flags & (structural | lookAgainFlags) != 0 { return true }
        if flags & UInt32(kFSEventStreamEventFlagItemChangeOwner) != 0,
           flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { return true }
        return flags == 0
    }

    /// `change` can change the listing of `root` (both spellings of the
    /// root must agree that it is not under a skipped name; see
    /// `isRelevantChange(atPath:root:)`). The root's own event (its path IS
    /// the root) is judged by its flags alone.
    static func isRelevantChange(_ change: Change, roots: [String]) -> Bool {
        guard isRelevantEventFlags(change.flags) else { return false }
        if change.flags & lookAgainFlags != 0 { return true }
        var bytes = Array(change.path.utf8)
        if bytes.last == slashByte { bytes.removeLast() }
        let name = bytes.split(separator: slashByte, omittingEmptySubsequences: false).last.map(Array.init) ?? []
        if isNonMarkdownFileEvent(flags: change.flags, name: name) { return false }
        return roots.allSatisfy { isRelevantChange(atPath: change.path, root: $0) }
    }

    /// "Events were lost / look again": relevant whatever the path.
    static let lookAgainFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                                           | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                                           | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount
                                           | kFSEventStreamEventFlagUnmount)

    /// A FILE (or symlink) event whose name is not Markdown cannot change a
    /// listing of Markdown files, whatever happened to it (created,
    /// removed, renamed): a build writing thousands of `.o` / `dist/` files
    /// re-read the whole tree every second (GUI, 13 % CPU). A rename
    /// delivers one event PER NAME (probed: `x.txt → x.md` gives
    /// `Renamed|IsFile` for both paths), so `x.txt → x.md` is still seen
    /// through the `x.md` event and `x.md → x.txt` through the old name.
    /// Folders stay relevant (a folder moved in brings only its own event);
    /// an event that is neither file nor symlink stays relevant.
    static func isNonMarkdownFileEvent(flags: UInt32, name: [UInt8]) -> Bool {
        name.withUnsafeBufferPointer { isNonMarkdownFileEvent(flags: flags, name: $0) }
    }

    static func isNonMarkdownFileEvent(flags: UInt32, name: UnsafeBufferPointer<UInt8>) -> Bool {
        let fileLike = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink)
        guard flags & fileLike != 0, flags & UInt32(kFSEventStreamEventFlagItemIsDir) == 0 else { return false }
        return !MarkdownFileKind.isMarkdownName(utf8: name)
    }

    /// `realpath(3)`: the spelling FSEvents reports (`/private/var/…`, where
    /// `canonicalPath` — Foundation's `resolvingSymlinksInPath` — gives
    /// `/var/…`). `path` itself when it cannot be resolved.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                                 .isHiddenKey, .isRegularFileKey, .volumeIdentifierKey,
                                                 .isVolumeKey]

    /// The listing of `root` (see the type and `Outcome`).
    /// `didVisit` (tests) hears the relative path of every subfolder read.
    static func scan(_ root: URL, limits: Limits = Limits(),
                     isCancelled: () -> Bool = { false },
                     didVisit: ((String) -> Void)? = nil) -> Outcome {
        // Missing vs unreadable by `stat`'s error (the Local links rule):
        // only ENOENT / ENOTDIR is "missing"; EACCES / EPERM (a parent we
        // may not search) is "unreadable" — a remembered folder must not be
        // forgotten over a permission.
        switch LocalLinkOpening.existence(atPath: root.path) {
        case .missing: return .missing
        case .unknown: return .unreadable
        case .exists: break
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return .unreadable
        }
        guard isDirectory.boolValue else { return .missing }
        var entriesRead = 0
        guard let rootEntries = entries(of: root, read: &entriesRead) else { return .unreadable }
        let volume = try? root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        var groups: [Group] = []
        var count = 0
        var foldersRead = 1
        var truncated = false
        var cancelled = false

        /// Depth-first, children in Finder order: a folder's files, then its
        /// subfolders — the display order (see the type).
        func visit(_ entries: [Entry], relativePath: String, depth: Int) {
            var files: [URL] = []
            for entry in entries where entry.kind == .markdown {
                guard count < limits.maxFiles else {
                    truncated = true
                    break
                }
                files.append(entry.url)
                count += 1
            }
            if !files.isEmpty { groups.append(Group(relativePath: relativePath, files: files)) }
            guard depth < limits.maxDepth else { return }
            for entry in entries where entry.kind == .folder {
                guard !truncated, !cancelled else { return }
                if isCancelled() {
                    cancelled = true
                    return
                }
                if entry.isVolume { continue }
                if let volume, let own = entry.volume, !own.isEqual(volume) { continue }
                guard foldersRead < limits.maxFolders, entriesRead <= limits.maxEntriesRead else {
                    truncated = true
                    return
                }
                foldersRead += 1
                guard let children = Self.entries(of: entry.url, read: &entriesRead) else { continue }
                let name = entry.url.lastPathComponent
                let path = relativePath.isEmpty ? name : relativePath + "/" + name
                didVisit?(path)
                visit(children, relativePath: path, depth: depth + 1)
            }
        }
        visit(rootEntries, relativePath: "", depth: 0)
        return cancelled ? .cancelled : .listed(Result(groups: groups, isTruncated: truncated))
    }

    private struct Entry {
        enum Kind { case markdown, folder }
        let url: URL
        let kind: Kind
        let volume: (NSCopying & NSSecureCoding & NSObjectProtocol)?
        var isVolume = false
    }

    /// The listable children of `folder` in Finder order; nil when it cannot
    /// be read. The directory read prefetches exactly the keys the rules
    /// above read (kind, link, hidden, package, volume). `read` grows by the
    /// number of entries the read returned (the cost, listable or not).
    private static func entries(of folder: URL, read: inout Int) -> [Entry]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        read += urls.count
        var entries: [Entry] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isHidden == true || values.isSymbolicLink == true { continue }
            // Built on `folder`, not taken from the enumeration: Foundation
            // hands back `/private/var/…` for a root spelled `/var/…`, and
            // the listing must keep the root's (canonical) spelling.
            if values.isDirectory == true {
                if values.isPackage == true || isSkippedName(name) { continue }
                entries.append(Entry(url: folder.appendingPathComponent(name, isDirectory: true), kind: .folder,
                                     volume: values.volumeIdentifier, isVolume: values.isVolume == true))
            } else if values.isRegularFile == true, MarkdownFileKind.isMarkdown(url) {
                entries.append(Entry(url: folder.appendingPathComponent(name, isDirectory: false), kind: .markdown,
                                     volume: nil))
            }
        }
        entries.sort { finderOrder($0.url.lastPathComponent, $1.url.lastPathComponent) }
        return entries
    }

    /// Finder order with a deterministic tie-break (code points).
    static func finderOrder(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return Array(a.unicodeScalars.map(\.value)).lexicographicallyPrecedes(b.unicodeScalars.map(\.value))
        }
    }
}
