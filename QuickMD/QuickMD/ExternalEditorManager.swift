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
        return (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.deletingPathExtension().lastPathComponent
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
    /// Returns the launched app's display name for UI feedback, or nil if the
    /// user cancelled / nothing could be launched.
    ///
    /// Main-thread by convention (invoked from button/menu actions); these
    /// helpers are not @MainActor because SwiftUI action closures are
    /// nonisolated on older SDKs (hard error on the CI toolchain otherwise).
    @discardableResult
    static func openInEditor(_ fileURL: URL) -> String? {
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

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: config,
                                completionHandler: nil)
        return (try? editorURL.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? editorURL.deletingPathExtension().lastPathComponent
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
