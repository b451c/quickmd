import Foundation

// MARK: - `other.md#section` links

/// Hands the fragment of a link to ANOTHER Markdown document to the window
/// that shows that document, so it scrolls to the heading the way an
/// in-document `#section` link does (before, the fragment was dropped and the
/// other document opened at its top).
///
/// The link's view cannot reach the target: the document opens through
/// `NSWorkspace` (DocumentGroup creates the window, or brings an already open
/// one forward). So the fragment is parked here under the file's path:
/// - a NEW window takes it once its first parse is laid out (a scroll request
///   before the list has its height table finds no row and is dropped);
/// - an already open window hears `requested` and takes it at once.
/// A request is only honoured for `lifetime` seconds, so a link whose file
/// failed to open cannot move a window the user opens much later.
///
/// Locked rather than `@MainActor`: the views call it from helpers, which are
/// nonisolated on the older SDK CI builds with (constraints.md).
final class CrossDocumentAnchors: @unchecked Sendable {
    static let shared = CrossDocumentAnchors()

    /// Posted on the main thread by `request`; `object` is the target's `key`.
    static let requested = Notification.Name("QuickMDCrossDocumentAnchorRequested")

    /// Long enough for a large document's open + parse + first layout.
    static let lifetime: TimeInterval = 30

    private let lock = NSLock()
    private var pending: [String: (fragment: String, date: Date)] = [:]

    /// The identity of a document file: its path with `.`/`..` and symlinks
    /// resolved, so a link through a symlinked folder (or `/tmp` vs
    /// `/private/tmp`) reaches the window that opened the real path. The same
    /// function on both sides (park and take).
    static func key(for fileURL: URL) -> String { fileURL.standardizedFileURL.resolvingSymlinksInPath().path }

    /// The fragment of a link to another document, percent-decoded (`#Install
    /// Guide` arrives as `Install%20Guide`); nil when the link has none.
    static func fragment(of link: URL) -> String? {
        link.fragment(percentEncoded: false)
    }

    /// Parks `fragment` for `fileURL` (replacing an older one) and tells an
    /// already open window.
    func request(_ fragment: String, for fileURL: URL, now: Date = Date()) {
        let key = Self.key(for: fileURL)
        lock.lock()
        pending[key] = (fragment, now)
        lock.unlock()
        NotificationCenter.default.post(name: Self.requested, object: key)
    }

    /// The fragment parked for `fileURL`, removed — nil when there is none or
    /// it is older than `lifetime`.
    func take(for fileURL: URL?, now: Date = Date()) -> String? {
        guard let fileURL else { return nil }
        lock.lock()
        let entry = pending.removeValue(forKey: Self.key(for: fileURL))
        lock.unlock()
        guard let entry, now.timeIntervalSince(entry.date) <= Self.lifetime else { return nil }
        return entry.fragment
    }
}
