import Foundation
import CoreServices

// MARK: - Folder browser store (File ▸ Open Folder, #62)

/// The ONE folder the Documents sidebar lists (app-wide: Open Folder replaces
/// it, Close Folder forgets it), with its listing (`FolderListing`).
///
/// - Remembered by path under `openFolderPath` until it is closed; `restore()`
///   brings it back at launch — a folder that is gone, or whose sandbox
///   bookmark cannot be restored, is forgotten without a word (the sidebar
///   simply shows no folder).
/// - Watched with ONE `FSEventStream` over the whole tree (the listing is
///   recursive; a vnode source per folder would not be), and re-scanned on
///   every change. A re-scan that finds the folder gone forgets it too.
/// - Scans run off the main thread; a newer scan (or a close) supersedes an
///   older one, whose result is dropped.
///
/// Access is NOT decided here: in the sandbox the chooser's answer is a
/// folder grant recorded by `SandboxAccessManager.registerUserChosenFolder`
/// before `open` is called, and a restore goes through
/// `Environment.restoreAccess`. Every effect (defaults, access, watcher,
/// scan) is injected, so `FolderBrowserStoreTests` needs neither real file
/// events nor `UserDefaults.standard`.
@MainActor
final class FolderBrowserStore: ObservableObject {
    struct Environment {
        var defaults: UserDefaults
        /// Starts access to a remembered folder (sandbox: its bookmark).
        /// False = it cannot be read this launch.
        var restoreAccess: @MainActor (URL) -> Bool
        /// Watches the tree under the folder; the token stops it when
        /// released. The closure is called on the main actor.
        var watch: @MainActor (URL, @escaping @MainActor () -> Void) -> AnyObject?
        var scan: @Sendable (URL) -> FolderListing.Result? = { FolderListing.scan($0) }
    }

    static let defaultsKey = "openFolderPath"

    @Published private(set) var folder: URL?
    @Published private(set) var groups: [FolderListing.Group] = []
    @Published private(set) var isTruncated = false
    @Published private(set) var isLoading = false

    private let environment: Environment
    private var watcher: AnyObject?
    /// Bumped by every scan start and every close: a scan whose number is no
    /// longer current publishes nothing.
    private var generation = 0
    /// The latest scan (tests and Open Folder wait for it).
    private(set) var scanTask: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    /// Lists `url` instead of any folder listed before, remembers it, and
    /// returns once its first listing is published.
    func open(_ url: URL) async {
        let url = url.standardizedFileURL
        environment.defaults.set(url.path, forKey: Self.defaultsKey)
        await start(url).value
    }

    /// Forgets the folder: no list, no watcher, nothing remembered.
    func close() {
        generation += 1
        scanTask = nil
        watcher = nil
        folder = nil
        groups = []
        isTruncated = false
        isLoading = false
        environment.defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// The remembered folder, if it still exists and can be read; otherwise
    /// it is forgotten silently.
    @discardableResult
    func restore() -> Task<Void, Never>? {
        guard folder == nil, let path = environment.defaults.string(forKey: Self.defaultsKey) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        // Existence first (metadata, allowed in the sandbox everywhere): a
        // folder that is gone needs no bookmark.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              environment.restoreAccess(url) else {
            environment.defaults.removeObject(forKey: Self.defaultsKey)
            return nil
        }
        return start(url)
    }

    /// Lists the folder again (the watcher calls it).
    @discardableResult
    func refresh() -> Task<Void, Never> {
        guard let root = folder else { return Task {} }
        generation += 1
        let current = generation
        isLoading = true
        let scan = environment.scan
        let task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { scan(root) }.value
            guard let self, self.generation == current else { return }
            guard let result else {
                // The folder went away (or can no longer be read).
                self.close()
                return
            }
            self.isLoading = false
            self.groups = result.groups
            self.isTruncated = result.isTruncated
        }
        scanTask = task
        return task
    }

    private func start(_ url: URL) -> Task<Void, Never> {
        watcher = nil
        folder = url
        groups = []
        isTruncated = false
        watcher = environment.watch(url) { [weak self] in
            self?.refresh()
        }
        return refresh()
    }
}

// MARK: - Tree watcher

/// One `FSEventStream` over a folder tree: directory-level events (no
/// per-file flags), 0.5 s latency (a save that touches several files is one
/// re-scan), on the main queue. `kFSEventStreamCreateFlagWatchRoot` also
/// reports the root itself being moved or deleted, so the re-scan can forget
/// it. Stops when released.
final class FolderTreeWatcher {
    private final class Handler {
        let fire: () -> Void
        init(_ fire: @escaping () -> Void) { self.fire = fire }
    }

    private let handler: Handler
    private var stream: FSEventStreamRef?

    init?(root: URL, latency: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        handler = Handler(onChange)
        // The stream holds the handler unretained: it is invalidated in
        // deinit, before the handler goes away.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
