import Foundation
import UniformTypeIdentifiers

// MARK: - Local link targets that run something

/// Whether a link to a LOCAL file may be handed to `NSWorkspace.open`
/// straight away, or must be confirmed first — and WHAT exactly is opened.
///
/// Why: documents are untrusted input. A link — a text link or, since 1.15,
/// a linked picture such as a badge — to `tools/run.command`, an `.app`, an
/// installer or a shell script made Launch Services run it on ONE click:
/// Terminal executes a `.command`, an app launches. Before this only
/// unusual URL SCHEMES were confirmed (`MarkdownView.handleLinkActivation`).
///
/// The rule: **a file whose OPENING makes another program act on
/// instructions inside it asks first.** Apps and bundles, executables,
/// scripts (Terminal, Python Launcher, Script Editor), installer packages,
/// disk images, Automator workflows, Terminal settings and session files,
/// and every internet-location file (`.webloc`, `.inetloc`, `.fileloc`,
/// `.ftploc`, `.afploc`, `.vncloc`, `.mailloc`, `.newsloc`, Windows `.url`:
/// `public.stored-url` — each holds an arbitrary URL that opening follows,
/// a `file://` to a `.command` or a scheme our scheme prompt never sees).
///
/// Decided on the RESOLVED target: symbolic links and Finder aliases are
/// followed (Launch Services follows them too), a few levels deep; an alias
/// that does not resolve, or a chain too long, asks. Decided by TYPE
/// (`UTType` as Launch Services sees it), with the extension as a fallback
/// when the file cannot be read (sandbox) or the type is dynamic, plus the
/// POSIX executable bit on a regular file. The bit alone does not ask for a
/// type that is a plain document (a PDF or picture unpacked from a ZIP is
/// often +x; Preview opens it, it never runs) — it matters where the type
/// says nothing: an extensionless tool. Pure: no UI, unit-tested with temp
/// files (`LocalLinkSafetyTests`).
enum LocalLinkSafety {
    enum Verdict: Equatable {
        /// An ordinary document, folder, picture: open as before.
        case open
        /// A program or script: ask first.
        case confirm
    }

    /// The decision for one link target: the verdict, the file it was made
    /// for (symlinks and aliases resolved — what must be opened, and what
    /// the confirmation names), and what the file was at that moment, so a
    /// second check after the confirmation can tell whether it changed.
    struct Check: Equatable {
        let verdict: Verdict
        let target: URL
        let typeIdentifier: String?
        let isExecutable: Bool
    }

    /// Symlink / alias hops followed before giving up (and asking).
    static let maximumResolutionDepth = 8

    /// Types that run code, install something or hand a stored URL on when
    /// opened (the rule above).
    private static let programTypes: [UTType] = {
        var types: [UTType] = [.application, .applicationBundle, .applicationExtension, .executable,
                               .unixExecutable, .shellScript, .script, .appleScript, .osaScript,
                               .osaScriptBundle, .diskImage, .bundle, .pluginBundle, .systemPreferencesPane]
        for identifier in ["com.apple.installer-package-archive", "com.apple.installer-package",
                           "com.apple.automator-workflow", "com.apple.automator-action",
                           "com.apple.terminal.shell-script", "com.apple.terminal.settings",
                           "com.apple.terminal.session", "public.stored-url", "com.apple.internet-location",
                           "com.microsoft.internet-shortcut", "public.python-bytecode",
                           "com.sun.java-archive", "com.apple.applescript.script",
                           "com.apple.applescript.script-bundle"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }()

    /// The fallback when the type is unknown, dynamic (`.workflow`,
    /// `.pyw` have no declared type on a stock Mac) or the file unreadable
    /// (sandbox): extensions of things that run, lowercased.
    static let programExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "term", "sh", "bash", "zsh", "csh", "ksh", "fish",
        "py", "pyw", "pyc", "pyo", "pyz", "rb", "pl", "php", "js", "jxa",
        "scpt", "scptd", "applescript", "osascript", "workflow", "action", "jar", "class",
        "pkg", "mpkg", "dmg", "prefpane", "saver", "plugin", "bundle", "appex", "xpc", "kext", "dylib",
        "webloc", "inetloc", "fileloc", "afploc", "ftploc", "vncloc", "mailloc", "newsloc", "atloc", "url",
    ]

    /// Types a viewer opens and that never run anything: the executable bit
    /// on one of them alone does not ask.
    private static let documentTypes: [UTType] = [.image, .pdf, .audiovisualContent, .font, .text,
                                                  .presentation, .spreadsheet, .archive]

    static func verdict(for url: URL, fileManager: FileManager = .default) -> Verdict {
        check(url, fileManager: fileManager).verdict
    }

    /// Resolves `url` (symlinks, Finder aliases) and classifies the target.
    static func check(_ url: URL, fileManager: FileManager = .default) -> Check {
        var current = url
        for _ in 0..<maximumResolutionDepth {
            current = current.resolvingSymlinksInPath()
            let values = try? current.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
            // `isAliasFile` is also true for a symbolic link; one left after
            // `resolvingSymlinksInPath` is dangling — classified by its name.
            guard values?.isAliasFile == true, values?.isSymbolicLink != true else {
                return classify(current, linkedAs: url, fileManager: fileManager)
            }
            guard let next = try? URL(resolvingAliasFileAt: current, options: [.withoutUI, .withoutMounting]) else {
                // An alias we cannot follow: Launch Services might.
                return Check(verdict: .confirm, target: current, typeIdentifier: UTType.aliasFile.identifier,
                             isExecutable: false)
            }
            current = next
        }
        return Check(verdict: .confirm, target: current, typeIdentifier: nil, isExecutable: false)
    }

    private static func classify(_ target: URL, linkedAs link: URL, fileManager: FileManager) -> Check {
        let values = try? target.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        let type = values?.contentType ?? UTType(filenameExtension: target.pathExtension)
        let executable = values?.isRegularFile == true && fileManager.isExecutableFile(atPath: target.path)
        func result(_ verdict: Verdict) -> Check {
            Check(verdict: verdict, target: target, typeIdentifier: type?.identifier, isExecutable: executable)
        }
        if programExtensions.contains(target.pathExtension.lowercased())
            || programExtensions.contains(link.pathExtension.lowercased()) {
            return result(.confirm)
        }
        if let type, programTypes.contains(where: { type.conforms(to: $0) }) { return result(.confirm) }
        if executable {
            if let type, documentTypes.contains(where: { type.conforms(to: $0) }), !type.conforms(to: .script) {
                return result(.open)
            }
            return result(.confirm)
        }
        return result(.open)
    }

    // MARK: Names in the confirmation

    /// A file name as the confirmation may show it: no bidirectional
    /// controls (U+202E would show `a‮txt.command` as "adnammoc.txt"), no
    /// line breaks, tabs or other control characters, middle-truncated.
    static func displayName(_ name: String, maxLength: Int = 80) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C:
                continue
            case 0x0A, 0x0D, 0x09, 0x0B, 0x0C, 0x2028, 0x2029:
                scalars.append(" ")
            default:
                if scalar.properties.generalCategory == .control { continue }
                scalars.append(scalar)
            }
        }
        return DisplayString.middleTruncated(String(scalars), maxLength: maxLength)
    }

    /// The confirmation's message: what happens, and — when the link's own
    /// name is not the file it opens (a symlink, an alias) — which file.
    static func confirmationMessage(link: URL, check: Check) -> String {
        var message = "This link opens a program or script on your Mac."
        if link.lastPathComponent != check.target.lastPathComponent {
            message += "\n\u{201C}\(displayName(link.lastPathComponent))\u{201D} points to "
                + "\u{201C}\(displayName(check.target.lastPathComponent))\u{201D}."
        }
        return message
    }

    static func confirmationTitle(check: Check) -> String {
        "Open \u{201C}\(displayName(check.target.lastPathComponent))\u{201D}?"
    }
}
