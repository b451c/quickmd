import Foundation
import UniformTypeIdentifiers

// MARK: - Local link targets that run something

/// Whether a link to a LOCAL file may be handed to `NSWorkspace.open`
/// straight away, or must be confirmed first.
///
/// Why: documents are untrusted input. A link — a text link or, since 1.15,
/// a linked picture such as a badge — to `tools/run.command`, an `.app`, an
/// installer or a shell script made Launch Services run it on ONE click:
/// Terminal executes a `.command`, an app launches. Before this only
/// unusual URL SCHEMES were confirmed (`MarkdownView.handleLinkActivation`).
///
/// Decided by TYPE (`UTType` of the file as Launch Services sees it — what
/// decides which app opens it and how), with the extension as a fallback
/// when the file cannot be read, plus the POSIX executable bit on a regular
/// file. The bit alone does not ask for a type that is a plain document
/// (a PDF or picture unpacked from a ZIP is often +x; Preview opens it, it
/// never runs) — it matters where the type says nothing: an extensionless
/// tool. Pure: no UI, unit-tested with temp files (`LocalLinkSafetyTests`).
enum LocalLinkSafety {
    enum Verdict: Equatable {
        /// An ordinary document, folder, picture: open as before.
        case open
        /// A program or script: ask first.
        case confirm
    }

    /// Types that run code or install something when opened.
    private static let programTypes: [UTType] = {
        var types: [UTType] = [.application, .applicationBundle, .applicationExtension, .executable,
                               .unixExecutable, .shellScript, .script, .appleScript, .osaScript,
                               .osaScriptBundle, .diskImage, .bundle, .pluginBundle, .systemPreferencesPane]
        for identifier in ["com.apple.installer-package-archive", "com.apple.installer-package",
                           "com.apple.automator-workflow", "com.apple.automator-action",
                           "com.apple.terminal.shell-script", "com.apple.terminal.settings",
                           "com.sun.java-archive", "com.apple.applescript.script",
                           "com.apple.applescript.script-bundle"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }()

    /// The fallback when the type is unknown or the file unreadable
    /// (sandbox): extensions of things that run, lowercased.
    static let programExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "fish",
        "py", "rb", "pl", "php", "js", "jxa", "scpt", "scptd", "applescript", "osascript",
        "workflow", "action", "jar", "pkg", "mpkg", "dmg", "prefpane", "saver", "plugin",
        "bundle", "appex", "xpc", "kext", "dylib", "webloc", "inetloc", "fileloc",
    ]

    /// Types a viewer opens and that never run anything: the executable bit
    /// on one of them alone does not ask.
    private static let documentTypes: [UTType] = [.image, .pdf, .audiovisualContent, .font, .text,
                                                  .presentation, .spreadsheet, .archive]

    static func verdict(for url: URL, fileManager: FileManager = .default) -> Verdict {
        let target = url.resolvingSymlinksInPath()
        let byExtension = programExtensions.contains(target.pathExtension.lowercased())
            || programExtensions.contains(url.pathExtension.lowercased())
        let values = try? target.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        let type = values?.contentType ?? UTType(filenameExtension: target.pathExtension)
        if byExtension { return .confirm }
        if let type, programTypes.contains(where: { type.conforms(to: $0) }) { return .confirm }
        if values?.isRegularFile == true, fileManager.isExecutableFile(atPath: target.path) {
            if let type, documentTypes.contains(where: { type.conforms(to: $0) }),
               !type.conforms(to: .script) {
                return .open
            }
            return .confirm
        }
        return .open
    }
}
