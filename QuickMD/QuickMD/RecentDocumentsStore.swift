import SwiftUI
import AppKit

/// Observable store tracking the list of documents opened in this app session.
/// Seeded from `NSDocumentController.recentDocumentURLs` so the list survives
/// relaunches (the system manages sandbox access for those entries via the
/// powerbox extension that ships with each recent document).
///
/// Originally contributed by COSMAX-JYP (https://github.com/COSMAX-JYP/quickmd).
@MainActor
final class RecentDocumentsStore: ObservableObject {
    static let shared = RecentDocumentsStore()

    /// Cap to prevent unbounded growth in long-running sessions.
    /// NSDocumentController itself caps recent docs to ~10 by default; the in-session
    /// list can grow as the user opens new files but should not become a memory hog.
    static let maxEntries = 50

    @Published private(set) var documents: [URL] = []

    private init() {
        documents = NSDocumentController.shared.recentDocumentURLs
    }

    /// Record a newly opened document. Duplicates are moved to the top.
    /// The list is capped at `maxEntries`.
    func register(_ url: URL) {
        let std = url.standardizedFileURL
        documents.removeAll { $0.standardizedFileURL == std }
        documents.insert(std, at: 0)
        if documents.count > Self.maxEntries {
            documents = Array(documents.prefix(Self.maxEntries))
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(std)
    }

    func remove(_ url: URL) {
        let std = url.standardizedFileURL
        documents.removeAll { $0.standardizedFileURL == std }
    }

    func clear() {
        documents.removeAll()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
