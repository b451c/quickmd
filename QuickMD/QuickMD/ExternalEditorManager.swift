import AppKit

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

    /// Opens the file in the configured editor. Fallback chain:
    /// selected editor → system default handler for the file → TextEdit.
    /// Never bounces back into QuickMD (a pointless loop whenever QuickMD is
    /// the default .md handler). Returns the launched app's display name for
    /// UI feedback, or nil if nothing could be launched.
    @MainActor
    @discardableResult
    static func openInEditor(_ fileURL: URL) -> String? {
        let preferred = UserDefaults.standard.string(forKey: defaultsKey) ?? ""

        var editorURL: URL? = preferred.isEmpty ? nil : appURL(for: preferred)
        if editorURL == nil {
            if let systemDefault = NSWorkspace.shared.urlForApplication(toOpen: fileURL),
               systemDefault != Bundle.main.bundleURL {
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
}
