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
/// - Recursive, but bounded: at most `Limits.maxDepth` folders deep and
///   `Limits.maxFiles` files (`isTruncated` beyond) — someone WILL open their
///   home folder, and the sidebar must stay a list, not a crawl.
/// - Skipped: hidden files and folders (`.git`, dot files, the Finder hidden
///   flag), packages (an `.app`, a `.textbundle` — one document to Finder),
///   `node_modules` (thousands of vendored READMEs nobody wants to read).
/// - Symbolic links are never followed, to folders or files: a link back up
///   the tree would loop, and a link out of the folder would list (and in the
///   sandbox fail to open) files that are not in it.
/// - Order is Finder's (`localizedStandardCompare`: `file2` before `file10`),
///   per path component: the root's files first, then every subfolder in
///   path order, each before its own subfolders. The walk visits folders in
///   exactly that order, so the files kept under the limit are the first ones
///   shown.
///
/// Pure (no app state), runs off the main thread; tested on temporary trees
/// (`FolderListingTests`).
enum FolderListing {
    struct Limits: Equatable, Sendable {
        /// Folders below the root that are still read (the root is 0).
        var maxDepth = 8
        /// Files listed at most; more makes the result truncated.
        var maxFiles = 2_000
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
        /// More files exist than `Limits.maxFiles`.
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

    static let skippedFolderNames: Set<String> = ["node_modules"]

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                                 .isHiddenKey, .isRegularFileKey]

    /// The listing of `root`, or nil when `root` is not a folder that can be
    /// read (gone, a file, no access).
    static func scan(_ root: URL, limits: Limits = Limits()) -> Result? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let rootEntries = entries(of: root) else { return nil }
        var groups: [Group] = []
        var count = 0
        var truncated = false

        /// Depth-first, children in Finder order: a folder's files, then its
        /// subfolders — the display order (see the type).
        func visit(_ folder: URL, entries: [Entry], relativePath: String, depth: Int) {
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
                guard !truncated else { return }
                guard let children = Self.entries(of: entry.url) else { continue }
                let name = entry.url.lastPathComponent
                visit(entry.url, entries: children,
                      relativePath: relativePath.isEmpty ? name : relativePath + "/" + name,
                      depth: depth + 1)
            }
        }
        visit(root, entries: rootEntries, relativePath: "", depth: 0)
        return Result(groups: groups, isTruncated: truncated)
    }

    private struct Entry {
        enum Kind { case markdown, folder }
        let url: URL
        let kind: Kind
    }

    /// The listable children of `folder` in Finder order; nil when it cannot
    /// be read.
    private static func entries(of folder: URL) -> [Entry]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var entries: [Entry] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isHidden == true || values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if values.isPackage == true || skippedFolderNames.contains(name) { continue }
                entries.append(Entry(url: url, kind: .folder))
            } else if values.isRegularFile == true, MarkdownFileKind.isMarkdown(url) {
                entries.append(Entry(url: url, kind: .markdown))
            }
        }
        entries.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        return entries
    }
}
