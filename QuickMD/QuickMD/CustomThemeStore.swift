import SwiftUI
import os

// MARK: - Custom Theme Store

/// Loads user-defined themes from `~/Library/Application Support/QuickMD/Themes/*.json`
/// and exposes them to the picker. Watches the folder for changes (live reload).
///
/// Thread safety: `themes` is read from any thread (e.g. background parsers calling
/// `MarkdownTheme.theme(named:)`). Writes happen only on the main queue (the file
/// watcher uses `.main`). An NSLock guards the array.
final class CustomThemeStore: ObservableObject {
    static let shared = CustomThemeStore()

    private let lock = NSLock()
    private var _themes: [MarkdownTheme] = []
    private var _lastError: String?

    /// Snapshot of currently loaded custom themes. Safe to read from any thread.
    var themes: [MarkdownTheme] {
        lock.lock(); defer { lock.unlock() }
        return _themes
    }

    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    private let logger = Logger(subsystem: "pl.falami.studio.QuickMD", category: "CustomThemeStore")
    private var folderSource: DispatchSourceFileSystemObject?
    private var folderDescriptor: Int32 = -1

    private init() {
        ensureThemesFolderExists()
        reload()
        startWatching()
    }

    deinit {
        folderSource?.cancel()
        if folderDescriptor >= 0 {
            close(folderDescriptor)
        }
    }

    // MARK: - Public API

    func theme(named name: String) -> MarkdownTheme? {
        lock.lock(); defer { lock.unlock() }
        return _themes.first(where: { $0.name == name })
    }

    /// URL of the themes folder (created if missing).
    var themesFolderURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("QuickMD/Themes", isDirectory: true)
    }

    /// Re-read all `*.json` files from the themes folder. Safe to call repeatedly.
    /// Notifies SwiftUI subscribers from the main queue.
    func reload() {
        let folder = themesFolderURL
        var loaded: [MarkdownTheme] = []
        var errors: [String] = []

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let decoder = JSONDecoder()
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where url.pathExtension.lowercased() == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    let dto = try decoder.decode(CustomThemeDTO.self, from: data)
                    loaded.append(dto.toTheme())
                } catch {
                    let name = url.lastPathComponent
                    errors.append("\(name): \(error.localizedDescription)")
                    logger.warning("Failed to load theme \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let errorString = errors.isEmpty ? nil : errors.joined(separator: "\n")

        let publish = {
            self.lock.lock()
            self._themes = loaded
            self._lastError = errorString
            self.lock.unlock()
            self.objectWillChange.send()
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    /// Copies the given JSON file into the themes folder and reloads.
    /// Returns true on success.
    @discardableResult
    func importTheme(from sourceURL: URL) -> Bool {
        let folder = themesFolderURL
        let destination = folder.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            let data = try Data(contentsOf: sourceURL)
            _ = try JSONDecoder().decode(CustomThemeDTO.self, from: data)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            reload()
            return true
        } catch {
            let message = "Import failed: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.lock.lock()
                self._lastError = message
                self.lock.unlock()
                self.objectWillChange.send()
            }
            logger.error("Theme import failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Private

    private func ensureThemesFolderExists() {
        let folder = themesFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func startWatching() {
        let folder = themesFolderURL
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        folderDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.folderDescriptor, fd >= 0 {
                close(fd)
                self?.folderDescriptor = -1
            }
        }
        source.resume()
        folderSource = source
    }
}

// MARK: - JSON DTO

/// Disk format for a custom theme. All colors are hex strings (6 or 8 chars, optional `#`).
private struct CustomThemeDTO: Decodable {
    let name: String
    let isDark: Bool
    let textColor: String
    let secondaryTextColor: String
    let linkColor: String
    let blockquoteColor: String
    let backgroundColor: String
    let codeBackgroundColor: String
    let headerBackgroundColor: String
    let borderColor: String
    let keywordColor: String
    let stringColor: String
    let commentColor: String
    let numberColor: String
    let typeColor: String
    let checkboxColor: String

    func toTheme() -> MarkdownTheme {
        MarkdownTheme(
            name: name,
            isDark: isDark,
            textColor: Color(hex: textColor),
            secondaryTextColor: Color(hex: secondaryTextColor),
            linkColor: Color(hex: linkColor),
            blockquoteColor: Color(hex: blockquoteColor),
            backgroundColor: Color(hex: backgroundColor),
            codeBackgroundColor: Color(hex: codeBackgroundColor),
            headerBackgroundColor: Color(hex: headerBackgroundColor),
            borderColor: Color(hex: borderColor),
            keywordColor: Color(hex: keywordColor),
            stringColor: Color(hex: stringColor),
            commentColor: Color(hex: commentColor),
            numberColor: Color(hex: numberColor),
            typeColor: Color(hex: typeColor),
            checkboxColor: Color(hex: checkboxColor)
        )
    }
}
