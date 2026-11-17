import Foundation
import CoreServices

// MARK: - Folder browser store (File ▸ Open Folder, #62)

/// The ONE folder the Documents sidebar lists (app-wide: Open Folder replaces
/// it, Close Folder forgets it), with its listing (`FolderListing`).
///
/// - Remembered by path under `openFolderPath` until it is closed. Creating
///   the store does no I/O; `restore()` (started once, from a task) checks
///   the folder's existence OFF the main thread — a remembered folder on a
///   disconnected share must not stall launch — and only then restores
///   access and publishes it. A folder that is gone, or whose sandbox
///   bookmark cannot be restored, is forgotten without a word.
/// - Watched with ONE `FSEventStream` over the whole tree (the listing is
///   recursive; a vnode source per folder would not be). An event batch
///   whose paths all lie under skipped names (`.git`, `node_modules`;
///   `FolderListing.isRelevantChange`, the scan's own rule) is dropped.
/// - ONE scan at a time (measured in review: ten events 100 ms apart had
///   started ten scans at once on the pool the document parse uses). Events
///   during a scan only mark the listing dirty; exactly one more scan
///   follows, no sooner than `followUpDelay` (1 s) after the previous one
///   ended. Close and a new Open cancel the running scan (it stops between
///   folders).
/// - A scan that finds the same listing publishes nothing (no
///   `objectWillChange`: the sidebar does not re-render on every save of an
///   unrelated file).
/// - Gone vs unreadable: a scan that finds no folder forgets it; one that
///   cannot read it keeps the folder and the last listing and tries again on
///   the next event (or launch).
/// - Listing URLs are built on the CANONICAL root (the disk spelling,
///   `FolderAccessBroker.canonicalPath`), so the sidebar can recognise the
///   current document however its path was spelled; `folder` stays as
///   chosen (the persisted path is the sandbox bookmark's key).
///
/// Access is NOT decided here: in the sandbox the chooser's answer is a
/// folder grant recorded by `SandboxAccessManager.registerUserChosenFolder`
/// before `open` is called, and a restore goes through
/// `Environment.restoreAccess`. Every effect (defaults, access, watcher,
/// scan, follow-up delay) is injected, so `FolderBrowserStoreTests` needs
/// neither real file events, nor the clock, nor `UserDefaults.standard`.
@MainActor
final class FolderBrowserStore: ObservableObject {
    struct Environment {
        var defaults: UserDefaults
        /// Starts access to a remembered folder (sandbox: its bookmark).
        /// False = it cannot be read this launch.
        var restoreAccess: @MainActor (URL) -> Bool
        /// Watches the tree under the (canonical) root; the token stops it
        /// when released. The closure gets the changed paths, on the main
        /// actor (empty = unknown, treated as relevant).
        var watch: @MainActor (URL, @escaping @MainActor ([String]) -> Void) -> AnyObject?
        /// Lists the root off the main thread; the closure says the scan
        /// was cancelled.
        var scan: @Sendable (URL, @escaping @Sendable () -> Bool) async -> FolderListing.Outcome = { root, cancelled in
            await Task.detached(priority: .utility) { FolderListing.scan(root, isCancelled: cancelled) }.value
        }
        /// The pause between a scan and the follow-up that events during it
        /// asked for.
        var followUpDelay: @MainActor () async -> Void = {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// How an `open` ended.
    enum OpenResult: Equatable {
        /// The folder's listing is published.
        case listed
        /// The chosen folder does not exist (forgotten).
        case missing
        /// It exists but cannot be read (kept; empty list).
        case unreadable
        /// Another Open or a Close came first.
        case superseded
    }

    static let defaultsKey = "openFolderPath"

    /// The folder as chosen (standardized) — shown, persisted.
    @Published private(set) var folder: URL?
    @Published private(set) var groups: [FolderListing.Group] = []
    @Published private(set) var isTruncated = false
    /// No listing yet for this folder.
    @Published private(set) var isLoading = false
    /// The last scan could not read the folder.
    @Published private(set) var isUnreadable = false

    /// The canonical root the listing is built on.
    private(set) var listingRoot: URL?
    /// The root as FSEvents spells it (`realpath`), for the event filter.
    private var eventRootPath: String?
    var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    private let environment: Environment
    private var watcher: AnyObject?

    /// One open folder's scans; cancelled when it is closed or replaced.
    private final class Session: @unchecked Sendable {
        /// Restored at launch, or listed once in this session: such a
        /// folder is KEPT when a scan cannot read it. An explicit Open that
        /// cannot read its folder leaves nothing behind. Main actor only.
        var keepsWhenUnreadable: Bool
        init(keepsWhenUnreadable: Bool) { self.keepsWhenUnreadable = keepsWhenUnreadable }

        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }
    }

    private var session: Session?
    /// The scan loop of `session` (at most one).
    private(set) var scanLoop: Task<Void, Never>?
    /// An event arrived since the running scan started.
    private var dirty = false
    /// `open` calls waiting for their folder's first listing.
    private var waiters: [(session: Session, continuation: CheckedContinuation<OpenResult, Never>)] = []
    private var didRestore = false

    init(environment: Environment) {
        self.environment = environment
    }

    /// Lists `url` instead of any folder listed before and remembers it.
    /// Returns once a listing FOR THIS FOLDER is published (or it turned out
    /// missing / unreadable), or when another Open or a Close replaced it.
    func open(_ url: URL) async -> OpenResult {
        didRestore = true
        let chosen = url.standardizedFileURL
        environment.defaults.set(chosen.path, forKey: Self.defaultsKey)
        let root = URL(fileURLWithPath: FolderAccessBroker.canonicalPath(chosen), isDirectory: true)
        let opened = begin(folder: chosen, root: root, restored: false)
        return await withCheckedContinuation { continuation in
            waiters.append((opened, continuation))
        }
    }

    /// Forgets the folder: no list, no watcher, nothing remembered.
    func close() {
        endSession()
        folder = nil
        listingRoot = nil
        eventRootPath = nil
        groups = []
        isTruncated = false
        isLoading = false
        isUnreadable = false
        environment.defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// The remembered folder, once per process (later calls, and calls after
    /// an Open, do nothing). See the type for the order of the checks.
    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        guard folder == nil, let path = environment.defaults.string(forKey: Self.defaultsKey) else { return }
        let canonical = await Task.detached(priority: .utility) { Self.restorableCanonicalPath(path) }.value
        // Opened, closed or replaced while the check ran: the reader acted.
        guard folder == nil, environment.defaults.string(forKey: Self.defaultsKey) == path else { return }
        let chosen = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard let canonical, environment.restoreAccess(chosen) else {
            environment.defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        begin(folder: chosen, root: URL(fileURLWithPath: canonical, isDirectory: true), restored: true)
    }

    /// Lists the folder again — at once, or after the running scan.
    func refresh() {
        guard session != nil else { return }
        dirty = true
        startScanLoopIfNeeded()
    }

    // MARK: Private

    /// The disk spelling of a remembered `path`, or nil when it is gone
    /// (ENOENT / ENOTDIR) or not a folder. A path `stat` may not see
    /// (EACCES / EPERM) is kept — the scan will report it unreadable — so a
    /// permission never forgets a folder. I/O: call off the main thread.
    nonisolated static func restorableCanonicalPath(_ path: String) -> String? {
        switch LocalLinkOpening.existence(atPath: path) {
        case .missing:
            return nil
        case .unknown:
            return FolderAccessBroker.canonicalPath(URL(fileURLWithPath: path, isDirectory: true))
        case .exists:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return FolderAccessBroker.canonicalPath(URL(fileURLWithPath: path, isDirectory: true))
            }
            return isDirectory.boolValue
                ? FolderAccessBroker.canonicalPath(URL(fileURLWithPath: path, isDirectory: true)) : nil
        }
    }

    @discardableResult
    private func begin(folder chosen: URL, root: URL, restored: Bool) -> Session {
        endSession()
        let opened = Session(keepsWhenUnreadable: restored)
        session = opened
        folder = chosen
        listingRoot = root
        eventRootPath = FolderListing.realPath(root.path)
        groups = []
        isTruncated = false
        isUnreadable = false
        isLoading = true
        watcher = environment.watch(root) { [weak self] paths in
            self?.filesChanged(atPaths: paths)
        }
        dirty = true
        startScanLoopIfNeeded()
        return opened
    }

    /// Ends the open folder's session: the scan stops early, the watcher
    /// goes, waiting `open`s learn they were superseded.
    private func endSession() {
        session?.cancel()
        scanLoop?.cancel()
        scanLoop = nil
        session = nil
        dirty = false
        watcher = nil
        resumeWaiters(.superseded) { _ in true }
    }

    private func filesChanged(atPaths paths: [String]) {
        guard let root = listingRoot?.path else { return }
        let real = eventRootPath ?? root
        // A path outside a root counts as relevant, so a path is dropped
        // when it lies under a skipped name in either spelling of the root.
        guard paths.isEmpty || paths.contains(where: {
            FolderListing.isRelevantChange(atPath: $0, root: root)
                && FolderListing.isRelevantChange(atPath: $0, root: real)
        }) else { return }
        refresh()
    }

    private func startScanLoopIfNeeded() {
        guard scanLoop == nil, let current = session else { return }
        scanLoop = Task { [weak self] in
            await self?.runScans(for: current)
        }
    }

    /// Scans while events keep the listing dirty; one at a time.
    private func runScans(for current: Session) async {
        while dirty, session === current, let root = listingRoot {
            dirty = false
            let outcome = await environment.scan(root) { current.isCancelled }
            guard session === current else { return }
            apply(outcome, for: current)
            guard session === current else { return }
            if dirty {
                await environment.followUpDelay()
            }
        }
        if session === current { scanLoop = nil }
    }

    private func apply(_ outcome: FolderListing.Outcome, for current: Session) {
        switch outcome {
        case .cancelled:
            return
        case .missing:
            resumeWaiters(.missing) { $0 === current }
            close()
        case .unreadable:
            guard current.keepsWhenUnreadable else {
                // An explicit Open of a folder that cannot be read: the
                // reader is told (alert); nothing stays behind.
                resumeWaiters(.unreadable) { $0 === current }
                close()
                return
            }
            if !isUnreadable { isUnreadable = true }
            if isLoading { isLoading = false }
            resumeWaiters(.unreadable) { $0 === current }
        case .listed(let result):
            current.keepsWhenUnreadable = true
            // Only what changed is assigned: equal listings publish nothing.
            if isUnreadable { isUnreadable = false }
            if isLoading { isLoading = false }
            if groups != result.groups { groups = result.groups }
            if isTruncated != result.isTruncated { isTruncated = result.isTruncated }
            resumeWaiters(.listed) { $0 === current }
        }
    }

    private func resumeWaiters(_ result: OpenResult, where matches: (Session) -> Bool) {
        let ready = waiters.filter { matches($0.session) }
        waiters.removeAll { matches($0.session) }
        ready.forEach { $0.continuation.resume(returning: result) }
    }
}

// MARK: - Tree watcher

/// One `FSEventStream` over a folder tree: directory-level events (no
/// per-file flags) with their paths (`UseCFTypes`), 0.5 s latency (a save
/// that touches several files is one batch), on the main queue.
/// `kFSEventStreamCreateFlagWatchRoot` also reports the root itself being
/// moved or deleted, so the re-scan can forget it. Stops when released.
final class FolderTreeWatcher {
    private final class Handler {
        let fire: ([String]) -> Void
        init(_ fire: @escaping ([String]) -> Void) { self.fire = fire }
    }

    private let handler: Handler
    private var stream: FSEventStreamRef?

    init?(root: URL, latency: TimeInterval = 0.5, onChange: @escaping ([String]) -> Void) {
        handler = Handler(onChange)
        // The stream holds the handler unretained: it is invalidated in
        // deinit, before the handler goes away.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            // UseCFTypes: the paths are a CFArray of CFString.
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().fire(paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               flags) else {
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
