import Foundation

/// Watches a single file for content changes (document auto-reload) using a
/// kqueue-backed DispatchSource — event-driven, zero CPU while idle.
///
/// Editors rarely write in place: VS Code, Zed, Sublime, vim and friends save
/// atomically (write a temp file, rename it over the original). That fires
/// .rename/.delete on the watched descriptor and leaves it pointing at the
/// dead inode. On those events the watcher re-opens the path and re-arms;
/// only when the path itself is gone does it report the file as missing.
///
/// A missing file is not the end: git checkout / stash pop, or an editor that
/// deletes and recreates after a pause, put it back at the same path later.
/// kqueue cannot watch a path that does not exist, so while the file is
/// missing a one-second main-queue timer checks whether the path exists again
/// (`access`, no descriptor); once it does, the watcher re-arms and reports a
/// (debounced) change. `onFileMissing` fires once per disappearance, never per
/// poll. Polling happens only while the path is ABSENT (ENOENT / ENOTDIR): a
/// path that exists but cannot be opened or seen (EACCES / EPERM — a sandbox
/// or permission denial) would fail the same way every second for the life of
/// the tab, so the watcher then stays missing without polling, as it always
/// did before polling existed.
///
/// All callbacks fire on the main queue (the DispatchSource and the debounce
/// both target `.main`). Changes are debounced 250 ms so an editor that
/// writes multiple times in quick succession coalesces into one reload.
///
/// Main-thread by convention, deliberately NOT @MainActor — SwiftUI view
/// callbacks that create/drive this are nonisolated on older SDKs and an
/// isolated call there is a hard compile error on the CI toolchain.
final class FileWatcher {

    /// Fired (debounced) when the file's content changed or the file was
    /// atomically replaced at the same path.
    var onChange: (() -> Void)?

    /// Fired when the file disappears from its path (moved or deleted and not
    /// re-created by an atomic save). If it comes back later, `onChange`
    /// follows.
    var onFileMissing: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var url: URL?
    private var debounce: DispatchWorkItem?
    /// Non-nil only while the file is missing (see the type comment).
    private var missingPoll: DispatchSourceTimer?

    private static let debounceInterval: TimeInterval = 0.25
    private static let missingPollInterval: TimeInterval = 1

    deinit { stop() }

    func start(watching url: URL) {
        stop()
        self.url = url
        let error = arm()
        if error != 0 { fileWentMissing(error) }
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()  // cancel handler closes the descriptor
        source = nil
        stopMissingPoll()
    }

    // MARK: - Private

    /// Opens the path and installs the kqueue source. Returns 0 when armed,
    /// otherwise `open(2)`'s errno — the caller decides what the failure means.
    private func arm() -> Int32 {
        guard let url else { return ENOENT }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return errno }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setCancelHandler { close(fd) }
        src.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            self.handle(events: current.data)
        }
        source = src
        src.resume()
        return 0
    }

    /// The path is not there (as opposed to there but off-limits).
    private static func isAbsence(_ error: Int32) -> Bool {
        error == ENOENT || error == ENOTDIR
    }

    /// Reports the disappearance ONCE; the poll that follows is silent.
    private func fileWentMissing(_ error: Int32) {
        onFileMissing?()
        if Self.isAbsence(error) { startMissingPoll() }
    }

    private func startMissingPoll() {
        stopMissingPoll()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.missingPollInterval,
                       repeating: Self.missingPollInterval,
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.pollMissingFile()
        }
        missingPoll = timer
        timer.resume()
    }

    private func stopMissingPoll() {
        missingPoll?.cancel()
        missingPoll = nil
    }

    private func pollMissingFile() {
        guard let url else { return stopMissingPoll() }
        if access(url.path, F_OK) != 0 {
            // Still absent: keep waiting. Not visible for another reason
            // (a parent folder became unreadable): give up, stay missing.
            if !Self.isAbsence(errno) { stopMissingPoll() }
            return
        }
        let error = arm()
        if error == 0 {
            stopMissingPoll()
            scheduleChange()
        } else if !Self.isAbsence(error) {
            // Back, but cannot be opened (EACCES / EPERM): retrying every
            // second would never succeed — stay missing.
            stopMissingPoll()
        }
        // Absent again between `access` and `open`: already reported, keep polling.
    }

    private func handle(events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            // Atomic save or a move. Drop the dead descriptor, then check the
            // path: a fresh file there means an editor save — re-arm and treat
            // as a change. An empty path means the document is really gone.
            source?.cancel()
            source = nil
            let error = arm()
            guard error == 0 else {
                fileWentMissing(error)
                return
            }
            scheduleChange()
        } else if events.contains(.write) || events.contains(.extend) {
            scheduleChange()
        }
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.onChange?()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}
