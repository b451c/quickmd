import Foundation

// MARK: - Folder access decisions (sandboxed build)

/// Decides, for a local picture the sandbox will not let us read, whether
/// access is already there, was declined, or must be asked for — and asks
/// at most ONCE per folder per session, for the most useful folder.
///
/// Why (E2E, 1.15 App Store build): every picture that failed with
/// `.unreadable` ran its own `NSOpenPanel` (`runModal`, app-modal). Badge
/// rows made that N pictures; Cancel brought the panel back for the next
/// one and again on every re-layout (nine panels in a row), and a grant of
/// the document's folder did not cover `badges/` (exact-path match only).
///
/// The rules:
/// - Access to a folder covers everything below it — active grants and
///   saved bookmarks alike. Paths are compared standardized with symlinks
///   resolved (`/tmp` = `/private/tmp`).
/// - The panel asks for the DOCUMENT's folder when the picture lies in its
///   subtree (one grant covers `badges/`, `images/`…), else for the
///   picture's own folder.
/// - A declined folder (and anything below it) is not asked for again this
///   session: its pictures show the denied placeholder at once. The
///   explicit actions (the card's Grant button, the chip's menu item) always
///   ask, and a grant clears the declined marks it covers. Nothing about
///   "declined" is persisted.
/// - Requests while a panel is up wait for its answer (one panel at a time)
///   and are decided again with it — an explicit one too: a click that
///   lands while an automatic panel for the same folder is up (the app was
///   in the background, the click activated it) takes that panel's answer
///   and never raises a second one.
/// - An AUTOMATIC request (a picture loading) may be told not to ask at
///   all (`mayAsk: false`): while the window's document is in Source Edit,
///   whose preview re-renders half-typed paths every pause. The picture
///   shows its denied placeholder, nothing is marked declined, and its
///   Grant button (explicit) still asks.
/// - Not sandboxed (GitHub/Homebrew build): never asks — an unreadable file
///   there is a POSIX permission, which a folder panel cannot fix.
///
/// Every effect is injected (`Environment`), so the decisions are unit-
/// tested without panels or bookmarks (`FolderAccessBrokerTests`).
@MainActor
final class FolderAccessBroker {
    struct Environment {
        var isSandboxed: Bool
        /// Folders with a saved security-scoped bookmark.
        var savedFolders: () -> [URL]
        /// Starts access through the saved bookmark of `folder`.
        var restore: (URL) -> Bool
        /// Waits until asking is appropriate (the app is active).
        var waitUntilReady: () async -> Void
        /// The panel, opened at the folder; the folder the reader granted,
        /// or nil when they cancelled.
        var prompt: (URL) -> URL?
        /// Saves the bookmark of a granted folder and starts access.
        var save: (URL) -> Bool
        /// A folder was granted: pictures waiting for it reload.
        var didGrant: (URL) -> Void
    }

    enum Decision: Equatable {
        case granted
        case declined
        case ask(folder: URL)
    }

    private let environment: Environment
    private(set) var grantedFolders: [String] = []
    private(set) var declinedFolders: Set<String> = []
    /// The panel being shown (or about to be): requests wait for it.
    private var pending: Task<Void, Never>?
    /// The folder `pending` asks for (canonical path).
    private var pendingFolder: String?

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: Paths

    /// The path as the disk spells it: standardized, symlinks resolved, in
    /// the on-disk CASE (`resolvingSymlinksInPath` is `realpath`, which on a
    /// case-insensitive volume returns the stored name: `../Docs/x.png` and a
    /// document in `/docs/` meet). Both need the path to EXIST — for a path
    /// that does not, Foundation returns it untouched (`/var/…` instead of
    /// `/private/var/…`, the case as written) — so the deepest existing
    /// ancestor is canonicalized and the rest appended as written. Metadata
    /// only (`stat`, `getattrlist`): the App Sandbox allows it everywhere
    /// (`application.sb`: `(allow file-read-metadata)`), so this holds for
    /// folders the app cannot read yet.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var path = existing.resolvingSymlinksInPath().path
        for component in rest { path = (path as NSString).appendingPathComponent(component) }
        return path
    }

    /// `folder` is `path` or one of its ancestors.
    nonisolated static func covers(_ folder: String, _ path: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The folder the panel asks for: the document's when the file is in
    /// its subtree, else the file's own.
    nonisolated static func folderToAsk(forFileAt file: URL, documentURL: URL?) -> URL {
        let parent = file.deletingLastPathComponent()
        guard let documentFolder = documentURL?.deletingLastPathComponent() else { return parent }
        return covers(canonicalPath(documentFolder), canonicalPath(file)) ? documentFolder : parent
    }

    // MARK: Decisions

    /// Without asking: access is there (granted, or restored from a saved
    /// bookmark that covers the file), declined, or to be asked for.
    /// `explicit` (a Grant button) ignores an earlier decline.
    func decision(forFileAt file: URL, documentURL: URL?, explicit: Bool) -> Decision {
        guard environment.isSandboxed else { return .declined }
        let path = Self.canonicalPath(file)
        if grantedFolders.contains(where: { Self.covers($0, path) }) { return .granted }
        for folder in environment.savedFolders() where Self.covers(Self.canonicalPath(folder), path) {
            if environment.restore(folder) {
                grantedFolders.append(Self.canonicalPath(folder))
                return .granted
            }
        }
        if !explicit, declinedFolders.contains(where: { Self.covers($0, path) }) { return .declined }
        return .ask(folder: Self.folderToAsk(forFileAt: file, documentURL: documentURL))
    }

    /// Restores a saved grant covering `file`, never asks (print/PDF).
    func restoreWithoutAsking(forFileAt file: URL) -> Bool {
        if case .granted = decision(forFileAt: file, documentURL: nil, explicit: false) { return true }
        return false
    }

    /// Access for `file`, asking at most once per folder (see the type).
    /// True when `file` is covered afterwards. `mayAsk: false` (an automatic
    /// request during Source Edit) never shows a panel and marks nothing.
    func requestAccess(forFileAt file: URL, documentURL: URL?, explicit: Bool, mayAsk: Bool = true) async -> Bool {
        // One panel at a time: wait for the one up, then decide again with
        // its answer.
        // A panel that asked for a folder covering this file WAS this
        // request's question: its answer stands, explicit or not (one click
        // never shows two panels).
        let path = Self.canonicalPath(file)
        var explicit = explicit
        while let pending {
            if let pendingFolder, Self.covers(pendingFolder, path) { explicit = false }
            await pending.value
        }
        guard case .ask(let folder) = decision(forFileAt: file, documentURL: documentURL, explicit: explicit) else {
            return decision(forFileAt: file, documentURL: documentURL, explicit: false) == .granted
        }
        guard explicit || mayAsk else { return false }
        let task = Task { @MainActor in
            // Cleared by the task itself, before it completes: a waiter that
            // wakes up must never find a finished task still pending.
            defer {
                pending = nil
                pendingFolder = nil
            }
            await environment.waitUntilReady()
            guard let chosen = environment.prompt(folder), environment.save(chosen) else {
                declinedFolders.insert(Self.canonicalPath(folder))
                return
            }
            let granted = Self.canonicalPath(chosen)
            grantedFolders.append(granted)
            declinedFolders = declinedFolders.filter { !Self.covers(granted, $0) }
            environment.didGrant(chosen)
        }
        pending = task
        pendingFolder = Self.canonicalPath(folder)
        await task.value
        return decision(forFileAt: file, documentURL: documentURL, explicit: false) == .granted
    }
}

/// Documents with an active Source Edit session, by the window token that
/// reported it (`SandboxAccessManager.setEditing`). The key is the document
/// path AT ACTIVATION and is removed by the token alone: a document renamed
/// or moved while editing (the view is re-created with the new URL and the
/// same token) never leaves its old path marked as editing — which would
/// keep a later document there from ever asking for folder access and make
/// its remote pictures wait. Pure, unit-tested.
struct SourceEditRegistry {
    private var documents: [UUID: String] = [:]

    mutating func set(_ documentURL: URL?, window: UUID, active: Bool) {
        guard active else {
            documents[window] = nil
            return
        }
        guard let documentURL else { return }
        documents[window] = documentURL.standardizedFileURL.path
    }

    func isEditing(_ documentURL: URL?) -> Bool {
        guard let documentURL else { return false }
        let path = documentURL.standardizedFileURL.path
        return documents.values.contains(path)
    }
}
