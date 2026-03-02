import Foundation
import AppKit

// MARK: - Sandbox Access Manager

/// Manages Security-Scoped Bookmarks for granting read access to directories
/// containing local resources (images, linked files) referenced by markdown documents.
///
/// When a user opens a `.md` file, the sandbox only grants access to that specific file.
/// This manager prompts the user (once per folder) via `NSOpenPanel` to grant access
/// to the parent directory, then persists the bookmark so future launches restore
/// access silently.
@MainActor
final class SandboxAccessManager {
    static let shared = SandboxAccessManager()

    /// UserDefaults key prefix for stored bookmarks
    private static let bookmarkKeyPrefix = "SandboxBookmark_"

    /// Directories currently being accessed (need to stop on cleanup)
    private var activeAccessURLs: [URL] = []

    private init() {}

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

    /// Ensure we have access to the parent directory of a file URL.
    /// If a bookmark exists, restores it silently. Otherwise, prompts the user.
    /// Returns `true` if access is available after this call.
    @discardableResult
    func ensureAccess(forParentOf fileURL: URL) -> Bool {
        let parentDir = fileURL.deletingLastPathComponent()

        // Already have active access?
        if activeAccessURLs.contains(where: { $0.path == parentDir.path }) {
            return true
        }

        // Try restoring a saved bookmark
        if restoreAccess(for: parentDir) {
            return true
        }

        // No bookmark — prompt the user
        return promptForAccess(to: parentDir)
    }

    // MARK: - Private

    /// Present an NSOpenPanel pre-navigated to the target directory.
    /// The user must click "Grant Access" to allow the app to read from that folder.
    private func promptForAccess(to directoryURL: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directoryURL
        panel.prompt = "Grant Access"
        panel.message = "QuickMD needs access to this folder to display local images and open linked files. This is a one-time prompt per folder."

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return false
        }

        // Save the bookmark
        do {
            let bookmarkData = try selectedURL.bookmarkData(options: .withSecurityScope)
            let key = Self.bookmarkKey(for: selectedURL)
            UserDefaults.standard.set(bookmarkData, forKey: key)

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
