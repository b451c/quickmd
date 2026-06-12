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
/// All callbacks fire on the main queue. Changes are debounced 250 ms so an
/// editor that writes multiple times in quick succession coalesces into one
/// reload.
@MainActor
final class FileWatcher {

    /// Fired (debounced) when the file's content changed or the file was
    /// atomically replaced at the same path.
    var onChange: (() -> Void)?

    /// Fired when the file disappears from its path (moved or deleted and not
    /// re-created by an atomic save).
    var onFileMissing: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var url: URL?
    private var debounce: DispatchWorkItem?

    private static let debounceInterval: TimeInterval = 0.25

    func start(watching url: URL) {
        stop()
        self.url = url
        arm()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()  // cancel handler closes the descriptor
        source = nil
    }

    // MARK: - Private

    private func arm() {
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            onFileMissing?()
            return
        }

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
    }

    private func handle(events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            // Atomic save or a move. Drop the dead descriptor, then check the
            // path: a fresh file there means an editor save — re-arm and treat
            // as a change. An empty path means the document is really gone.
            source?.cancel()
            source = nil
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                onFileMissing?()
                return
            }
            arm()
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
