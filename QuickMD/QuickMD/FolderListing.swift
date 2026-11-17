import Foundation

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
///   file cap cuts in display order.
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
    }

    /// The Markdown files directly inside one folder.
    struct Group: Equatable, Identifiable, Sendable {
        /// Path relative to the root, components joined by "/"; "" for the root.
        let relativePath: String
        let files: [URL]
        var id: String { relativePath }
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
    static func isSkippedName(_ name: String) -> Bool {
        name.hasPrefix(".") || skippedFolderNames.contains(name)
    }

    /// A change at `path` (as FSEvents reports it) can change the listing of
    /// `root` (both canonical paths): false only when some component of the
    /// path below the root is a skipped name (`.git/objects/ab`,
    /// `node_modules/x`). Paths outside the root (the root itself moved)
    /// count as relevant.
    static func isRelevantChange(atPath path: String, root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.hasPrefix(base) else { return true }
        return !trimmed.dropFirst(base.count).split(separator: "/").contains { isSkippedName(String($0)) }
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
        guard let rootEntries = entries(of: root) else { return .unreadable }
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
                guard foldersRead < limits.maxFolders else {
                    truncated = true
                    return
                }
                foldersRead += 1
                guard let children = Self.entries(of: entry.url) else { continue }
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
    /// above read (kind, link, hidden, package, volume).
    private static func entries(of folder: URL) -> [Entry]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
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
