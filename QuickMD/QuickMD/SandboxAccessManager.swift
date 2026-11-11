import Foundation
import AppKit

// MARK: - Sandbox Access Manager

/// Manages Security-Scoped Bookmarks for granting read access to directories
/// containing local resources (images, linked files) referenced by markdown documents.
///
/// When a user opens a `.md` file, the sandbox only grants access to that specific file.
/// This manager asks the user via `NSOpenPanel` to grant access to a folder,
/// then persists the bookmark so future launches restore access silently.
/// WHEN to ask, for WHICH folder, and when not to ask again is decided by
/// `FolderAccessBroker` (`broker`); this type provides its effects: the
/// panel, the bookmarks, the grant notification.
@MainActor
final class SandboxAccessManager {
    static let shared = SandboxAccessManager()

    /// UserDefaults key prefix for stored bookmarks
    private static let bookmarkKeyPrefix = "SandboxBookmark_"

    /// Posted (main thread) when the reader granted a folder; `object` is
    /// the folder URL. Pictures denied under it reload (`PictureView`), in
    /// every window.
    static let folderAccessGranted = Notification.Name("QuickMDFolderAccessGranted")

    /// The App Sandbox is on (App Store build). The GitHub/Homebrew build
    /// runs without it and never asks.
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Directories currently being accessed (need to stop on cleanup)
    private var activeAccessURLs: [URL] = []

    /// Folders with a saved bookmark, read from the defaults once.
    private lazy var savedFolders: [URL] = UserDefaults.standard.dictionaryRepresentation().keys
        .filter { $0.hasPrefix(Self.bookmarkKeyPrefix) }
        .map { URL(fileURLWithPath: String($0.dropFirst(Self.bookmarkKeyPrefix.count)), isDirectory: true) }

    /// The decisions (see `FolderAccessBroker`), with this manager's effects.
    private(set) lazy var broker = FolderAccessBroker(environment: .init(
        isSandboxed: Self.isSandboxed,
        savedFolders: { [unowned self] in self.savedFolders },
        restore: { [unowned self] in self.restoreAccess(for: $0) },
        waitUntilReady: { await Self.waitUntilAppIsActive() },
        prompt: { [unowned self] in self.promptForFolder(at: $0) },
        save: { [unowned self] in self.saveGrant($0) },
        didGrant: { NotificationCenter.default.post(name: Self.folderAccessGranted, object: $0) }))

    private init() {}

    /// A panel for a background app would pop up over whatever the reader is
    /// doing (a tab opened with `open -g`): wait until QuickMD is active.
    private static func waitUntilAppIsActive() async {
        guard !NSApp.isActive else { return }
        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
            return
        }
    }

    // MARK: - Public API

    /// Try to restore a previously saved bookmark for the given directory.
    /// Returns `true` if access was successfully restored.
    @discardableResult
    func restoreAccess(for directoryURL: URL) -> Bool {
        let key = Self.bookmarkKey(for: directoryURL)
        guard let bookmarkData = UserDefaults.standard.data(forKey: key) else {
            return false
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Bookmark is stale — re-save it
                if let newData = try? url.bookmarkData(options: .withSecurityScope) {
                    UserDefaults.standard.set(newData, forKey: key)
                }
            }

            if url.startAccessingSecurityScopedResource() {
                activeAccessURLs.append(url)
                return true
            }
        } catch {
            // Bookmark resolution failed — remove the stale entry
            UserDefaults.standard.removeObject(forKey: key)
        }

        return false
    }

    /// Access for a local picture (`file`) the sandbox would not read:
    /// granted, declined, or asked for — at most once per folder per session
    /// (`FolderAccessBroker`). `explicit`: the reader pressed a Grant
    /// button, so an earlier decline does not count.
    func requestAccess(forFileAt file: URL, documentURL: URL?, explicit: Bool) async -> Bool {
        await broker.requestAccess(forFileAt: file, documentURL: documentURL, explicit: explicit,
                                   mayAsk: explicit || !isEditing(documentURL))
    }

    // MARK: - Source Edit

    /// Documents with an active Source Edit session, by the windows editing
    /// them (`MarkdownView` reports start and end with its own token, so a
    /// repeated report is harmless). Their pictures never raise a
    /// panel by themselves: the side-by-side preview re-parses the buffer
    /// after every pause, half-typed paths included (`![l](assets/)`), and
    /// an app-modal panel would take the keyboard mid-edit. Remote pictures
    /// wait until their URL stands still (`RemoteFetchGate`). Keyed by the
    /// path at activation, ended by the token (`SourceEditRegistry`).
    private var editing = SourceEditRegistry()

    func setEditing(_ documentURL: URL?, window: UUID, _ active: Bool) {
        editing.set(documentURL, window: window, active: active)
    }

    func isEditing(_ documentURL: URL?) -> Bool {
        editing.isEditing(documentURL)
    }

    /// A saved grant covering `file`, restored silently; never a panel
    /// (print/PDF).
    @discardableResult
    func restoreSavedAccess(covering file: URL) -> Bool {
        broker.restoreWithoutAsking(forFileAt: file)
    }

    // MARK: - Private

    /// Present an NSOpenPanel pre-navigated to the target directory.
    /// The user must click "Grant Access" to allow the app to read from that
    /// folder. The folder chosen (the reader may pick another), or nil.
    private func promptForFolder(at directoryURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directoryURL
        panel.prompt = "Grant Access"
        panel.message = "QuickMD needs access to this folder to display local images and open linked files. This is a one-time prompt per folder."
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }
        return selectedURL
    }

    /// Saves the bookmark of a granted folder and starts access.
    private func saveGrant(_ selectedURL: URL) -> Bool {
        do {
            let bookmarkData = try selectedURL.bookmarkData(options: .withSecurityScope)
            let key = Self.bookmarkKey(for: selectedURL)
            UserDefaults.standard.set(bookmarkData, forKey: key)
            savedFolders.append(selectedURL)
            if selectedURL.startAccessingSecurityScopedResource() {
                activeAccessURLs.append(selectedURL)
                return true
            }
        } catch {
            // Failed to create bookmark — access denied
        }
        return false
    }

    /// Stop accessing all security-scoped resources.
    func stopAllAccess() {
        for url in activeAccessURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeAccessURLs.removeAll()
    }

    /// Generate a UserDefaults key for a directory path.
    private static func bookmarkKey(for directoryURL: URL) -> String {
        return bookmarkKeyPrefix + directoryURL.standardizedFileURL.path
    }
}
