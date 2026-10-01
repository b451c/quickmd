import AppKit
import UniformTypeIdentifiers

/// Detection and launch logic for "Open in External Editor" (⌘E).
/// QuickMD is a viewer by design — editing is delegated to the user's editor,
/// and this is the one-click handoff half of that roundtrip (the other half
/// is FileWatcher's auto-reload when the editor saves).
enum ExternalEditorManager {

    struct Editor: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Known markdown-capable editors, in Settings picker display order.
    static let knownEditors: [Editor] = [
        Editor(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        Editor(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        Editor(bundleID: "com.sublimetext.4", name: "Sublime Text"),
        Editor(bundleID: "dev.zed.Zed", name: "Zed"),
        Editor(bundleID: "abnerworks.Typora", name: "Typora"),
        Editor(bundleID: "md.obsidian", name: "Obsidian"),
        Editor(bundleID: "com.panic.Nova", name: "Nova"),
        Editor(bundleID: "com.barebones.bbedit", name: "BBEdit"),
        Editor(bundleID: "com.uranusjr.macdown", name: "MacDown"),
        Editor(bundleID: "pro.writer.mac", name: "iA Writer"),
    ]

    /// UserDefaults key. Empty string = "System Default".
    static let defaultsKey = "externalEditorBundleID"

    // MARK: - Line links (v1.11 E-D2)

    /// How an editor's documented URL scheme encodes "open this file at line N".
    enum LineLinkStyle: Equatable {
        /// `<scheme>://file/<absolute path>:<line>:<column>` (VS Code family).
        case vscode(scheme: String)
        /// `x-bbedit://open?url=<file URL>&line=<line>`.
        case bbedit
        /// `txmt://open/?url=<file URL>&line=<line>`.
        case textmate
        /// `nova://open?path=<absolute path>&line=<line>`.
        case nova
    }

    struct LineLinkEditor: Equatable {
        let bundleID: String
        /// Name used in the Settings explanation (the toast uses the app's own
        /// localized name).
        let name: String
        let style: LineLinkStyle
    }

    /// Editors whose vendor DOCUMENTS a URL scheme that opens a file at a line —
    /// only those, each with its source. Verified 2026-10-01 against the pages
    /// cited. Not here, on purpose: Cursor (its docs document only
    /// `cursor://anysphere.cursor-deeplink/{prompt,command,rule}`), Zed (line
    /// numbers documented for the `zed` CLI only, not for `zed://` URLs) and
    /// Sublime Text (no URL scheme documented; `:line` is CLI-only). Every
    /// editor outside this table keeps the plain file open.
    static let lineLinkEditors: [LineLinkEditor] = [
        // https://code.visualstudio.com/docs/configure/command-line#_opening-vs-code-with-urls
        // "vscode://file/{full path to file}:line:column"
        LineLinkEditor(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code",
                       style: .vscode(scheme: "vscode")),
        // Same page: "If you are using VS Code Insiders builds, the URL prefix is vscode-insiders://."
        LineLinkEditor(bundleID: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders",
                       style: .vscode(scheme: "vscode-insiders")),
        // https://www.barebones.com/support/bbedit/notes-12.1.4.html
        // "x-bbedit://open?url=file:///path/to/some/file&line=5"
        LineLinkEditor(bundleID: "com.barebones.bbedit", name: "BBEdit", style: .bbedit),
        // https://macromates.com/manual/en/using_textmate_from_terminal
        // "txmt://open/?url=file://~/.bash_profile&line=11&column=2"
        LineLinkEditor(bundleID: "com.macromates.TextMate", name: "TextMate", style: .textmate),
        // https://help.nova.app/projects/url-schema/
        // "nova://open?path=/example/file.html&line=1:5" (path = absolute path)
        LineLinkEditor(bundleID: "com.panic.Nova", name: "Nova", style: .nova),
    ]

    /// The Settings → Editor explanation (E-D4), built from the table so the
    /// two can never disagree.
    static var lineLinkExplanation: String {
        "\u{2318}E opens the document at the line you are reading ("
            + lineLinkEditors.map(\.name).joined(separator: ", ") + ")."
    }

    /// The URL that opens `fileURL` at `line` (1-based) in the editor with
    /// `bundleID`, or nil when that editor has no documented line link — the
    /// caller then opens the file plainly.
    ///
    /// Encoding: a path goes into a URL PATH (VS Code) or a query VALUE (Nova)
    /// with everything outside RFC 3986 "unreserved" + `/` percent-encoded as
    /// UTF-8 — so spaces, `#`, `?`, `%`, `&` and non-ASCII names survive. BBEdit
    /// and TextMate take a FILE URL as the value; that URL is already
    /// percent-encoded (`file:///a%20b.md`) and is encoded once more as a query
    /// value (`%2520`), because the receiver decodes the query value first and
    /// then parses what is left as a URL.
    static func lineLinkURL(bundleID: String, fileURL: URL, line: Int) -> URL? {
        guard let editor = lineLinkEditors.first(where: { $0.bundleID == bundleID }) else { return nil }
        let line = max(1, line)
        let path = fileURL.path
        let string: String
        switch editor.style {
        case .vscode(let scheme):
            // Column 1: the line is the target, not a position inside it.
            string = "\(scheme)://file\(percentEncoded(path, keeping: "/")):\(line):1"
        case .bbedit:
            let fileURLString = URL(fileURLWithPath: path).absoluteString
            string = "x-bbedit://open?url=\(percentEncoded(fileURLString, keeping: "/:"))&line=\(line)"
        case .textmate:
            let fileURLString = URL(fileURLWithPath: path).absoluteString
            string = "txmt://open/?url=\(percentEncoded(fileURLString, keeping: "/:"))&line=\(line)"
        case .nova:
            string = "nova://open?path=\(percentEncoded(path, keeping: "/"))&line=\(line)"
        }
        return URL(string: string)
    }

    /// RFC 3986 unreserved characters, spelled out: `CharacterSet.alphanumerics`
    /// includes every Unicode letter, which would leave "ł" or "日" unencoded.
    private static let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    private static func percentEncoded(_ string: String, keeping extra: String) -> String {
        let allowed = CharacterSet(charactersIn: unreserved + extra)
        // Cannot fail for a valid Swift String (UTF-8 is always representable).
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: - Opening

    /// What `openInEditor` launched, for the toast.
    struct OpenResult: Equatable {
        let appName: String
        /// The 1-based line the editor was sent to; nil = plain file open.
        let line: Int?
    }

    /// E-D4 toast copy.
    static func toastText(for result: OpenResult) -> String {
        if let line = result.line {
            return "Opened in \(result.appName) at line \(line)"
        }
        return "Opened in \(result.appName)"
    }

    static func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Known editors actually installed on this machine.
    static func installedKnownEditors() -> [Editor] {
        knownEditors.filter { appURL(for: $0.bundleID) != nil }
    }

    /// Display name for an arbitrary selected bundle id (used when the user
    /// picked an app outside the known list via "Other…").
    static func displayName(for bundleID: String) -> String? {
        guard let url = appURL(for: bundleID) else { return nil }
        return appDisplayName(at: url)
    }

    /// The app's own name ("Visual Studio Code"), never the bundle's file name:
    /// `localizedNameKey` keeps the ".app" extension when Finder is set to show
    /// all filename extensions ("Opened in Visual Studio Code.app").
    static func appDisplayName(at appURL: URL) -> String {
        let bundle = Bundle(url: appURL)
        let declared = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        if let declared, !declared.isEmpty { return declared }
        return appURL.deletingPathExtension().lastPathComponent
    }

    /// Opens the file in the configured editor.
    ///
    /// First use (no preference stored yet): asks ONCE which editor to use —
    /// the choice is saved and changeable anytime in Settings → Editor.
    ///
    /// Resolution chain: selected editor → system default handler → TextEdit.
    /// QuickMD is excluded by BUNDLE IDENTITY, not by path — the system
    /// default may be a different copy of QuickMD (e.g. /Applications vs a
    /// dev build) and handing the file back to ourselves is a pointless loop.
    ///
    /// `line` (1-based, the reading position) is used only when the RESOLVED
    /// editor is in `lineLinkEditors`; everything above stays as it was. If the
    /// line link cannot be opened, the file is opened plainly instead.
    ///
    /// Returns the launched app's display name (and the line, when a line link
    /// was used) for UI feedback, or nil if the user cancelled / nothing could
    /// be launched.
    ///
    /// Main-thread by convention (invoked from button/menu actions); these
    /// helpers are not @MainActor because SwiftUI action closures are
    /// nonisolated on older SDKs (hard error on the CI toolchain otherwise).
    @discardableResult
    static func openInEditor(_ fileURL: URL, line: Int? = nil) -> OpenResult? {
        var preferred = UserDefaults.standard.string(forKey: defaultsKey)

        if preferred == nil {
            preferred = promptForEditorChoice()
            guard preferred != nil else { return nil }  // user cancelled the one-time prompt
        }

        var editorURL: URL?
        if let preferred, !preferred.isEmpty, preferred != Bundle.main.bundleIdentifier {
            editorURL = appURL(for: preferred)
        }
        if editorURL == nil {
            if let systemDefault = NSWorkspace.shared.urlForApplication(toOpen: fileURL),
               Bundle(url: systemDefault)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                editorURL = systemDefault
            }
        }
        if editorURL == nil {
            editorURL = appURL(for: "com.apple.TextEdit")
        }
        guard let editorURL else { return nil }
        let appName = appDisplayName(at: editorURL)

        if let line, let bundleID = Bundle(url: editorURL)?.bundleIdentifier,
           openLineLink(bundleID: bundleID, fileURL: fileURL, line: line) {
            return OpenResult(appName: appName, line: max(1, line))
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: config,
                                completionHandler: nil)
        return OpenResult(appName: appName, line: nil)
    }

    /// Opens the line link for the resolved editor; false = not applicable or
    /// failed, and the caller falls back to the plain file open (E-D3).
    ///
    /// `NSWorkspace.open(_:)` hands a URL to the scheme's DEFAULT handler, which
    /// is not necessarily the editor we resolved (several apps can claim one
    /// scheme — VS Code forks register `vscode://`). The handler is checked
    /// first, so a line link never opens an app other than the one the user
    /// chose; a missing handler is the "no handler" case of the fallback.
    /// URL opening is a plain Launch Services request — allowed in the sandbox,
    /// no `Process`, no CLI.
    private static func openLineLink(bundleID: String, fileURL: URL, line: Int) -> Bool {
        guard let linkURL = lineLinkURL(bundleID: bundleID, fileURL: fileURL, line: line),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: linkURL),
              Bundle(url: handler)?.bundleIdentifier == bundleID else { return false }
        return NSWorkspace.shared.open(linkURL)
    }

    /// One-time editor chooser shown on the first ⌘E: a popup with all
    /// detected editors (+ TextEdit + Other…). Stores and returns the chosen
    /// bundle id, or nil when cancelled.
    static func promptForEditorChoice() -> String? {
        var options: [(title: String, bundleID: String)] =
            installedKnownEditors().map { ($0.name, $0.bundleID) }
        options.append(("TextEdit", "com.apple.TextEdit"))

        let alert = NSAlert()
        alert.messageText = "Choose Your External Editor"
        alert.informativeText = "QuickMD will open documents in this app when you press \u{2318}E.\nYou can change it anytime in Settings \u{2192} Editor."
        alert.addButton(withTitle: "Use This Editor")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 25), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.title)
        }
        popup.addItem(withTitle: "Other\u{2026}")
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let chosen: String?
        if popup.indexOfSelectedItem == options.count {
            chosen = chooseApplicationBundleID()  // Other…
        } else {
            chosen = options[popup.indexOfSelectedItem].bundleID
        }
        guard let chosen else { return nil }
        UserDefaults.standard.set(chosen, forKey: defaultsKey)
        return chosen
    }

    /// NSOpenPanel for picking an arbitrary .app; returns its bundle id.
    /// Shared by the first-run prompt and the Settings "Other…" button.
    static func chooseApplicationBundleID() -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the application \u{2318}E should open documents in."
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return nil }
        return bundleID
    }
}
