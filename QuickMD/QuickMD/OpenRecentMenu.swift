import AppKit
import UniformTypeIdentifiers

/// Repairs File ▸ Open Recent when SwiftUI leaves it blank.
///
/// Why this exists (measured on macOS 27.2.1 with minimal
/// `DocumentGroup(viewing:)` apps): at launch the File menu holds AppKit's
/// own Open Recent item. On SwiftUI's first lazy update of the main menu
/// (the reader opens the menu, or accessibility reads it), an app with
/// `CommandGroup(replacing: .saveItem)` — QuickMD's Close, which must stay
/// (constraint 3) — gets that item REMOVED and a bare `NSMenuItem()`
/// inserted at the same index, never configured: a grey, dead item titled
/// "NSMenuItem". Replacing `.newItem` does not help (two Open… items), and
/// `NSDocumentController.shared` must not be touched before
/// `applicationDidFinishLaunching` (SwiftUI installs its own controller in
/// its `applicationWillFinishLaunching`).
///
/// The repair: the item right after Open… (`openDocument:`) is mutated IN
/// PLACE when it is blank — title and a submenu of ours. SwiftUI keeps a
/// reference to that object, so it is never replaced, removed or
/// re-inserted; later SwiftUI updates leave it alone. Wherever the system
/// item is healthy this is a no-op. Public API only (App Store).
///
/// The submenu never touches the file system when it opens: a recent file
/// may sit on an unmounted volume. Names come from the URL, icons from the
/// extension's content type.
@MainActor
final class OpenRecentMenu: NSObject, NSMenuDelegate {
    /// What the menu does, injected so tests touch no process-wide state
    /// (the live one is `OpenRecentMenu.shared`, in `QuickMDApp.swift`).
    struct Environment {
        /// The recent list, in the order to show it.
        var recents: @MainActor () -> [URL]
        /// Opens a chosen entry; the closure receives a failure message.
        var open: @MainActor (URL, _ onFailure: @escaping (String) -> Void) -> Void
        /// Shows a failure message reported by `open`.
        var reportFailure: @MainActor (String) -> Void
        /// Clear Menu.
        var clear: @MainActor () -> Void
    }

    static let title = "Open Recent"
    static let clearTitle = "Clear Menu"
    /// Icon size of an entry, as the system menu draws it.
    static let iconSize = NSSize(width: 16, height: 16)

    private let mainMenu: @MainActor () -> NSMenu?
    private let environment: Environment
    private var isInstalled = false
    /// Set while the repair mutates the slot: setting `title` / `submenu`
    /// posts `NSMenu.didChangeItemNotification` synchronously, which would
    /// otherwise re-enter. With today's order (submenu first) a nested
    /// notification already sees a healthy slot; the flag is defence for any
    /// future order of the three assignments.
    private var isRepairing = false
    /// One icon per extension (a copy sized for the menu; NSWorkspace's
    /// image is shared and must not be resized).
    private var iconsByExtension: [String: NSImage] = [:]

    /// Submenus built by repairs so far (one per repaired slot). Tests read
    /// it to prove one event builds one submenu.
    private(set) var submenusBuilt = 0

    init(mainMenu: @escaping @MainActor () -> NSMenu?, environment: Environment) {
        self.mainMenu = mainMenu
        self.environment = environment
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Starts watching the main menu and repairs it once now. Idempotent.
    /// Call no earlier than `applicationDidFinishLaunching`.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let center = NotificationCenter.default
        // Selector-based and synchronous: the menu must be right before it
        // is drawn, so no hop to a later main-queue turn.
        center.addObserver(self, selector: #selector(menuItemsDidChange(_:)),
                           name: NSMenu.didAddItemNotification, object: nil)
        center.addObserver(self, selector: #selector(menuItemsDidChange(_:)),
                           name: NSMenu.didChangeItemNotification, object: nil)
        if let main = mainMenu() { repairTopLevelMenus(of: main) }
    }

    private func repairTopLevelMenus(of main: NSMenu) {
        for case let menu? in main.items.map(\.submenu) {
            repairIfNeeded(in: menu)
        }
    }

    /// Every menu in the app posts these (context menus too), so the cheap
    /// test comes first: only the main menu itself or one of its top-level
    /// submenus counts. A change ON the main menu is what attaching a File
    /// menu built while detached posts (`fileItem.submenu = newFile`) — the
    /// only notification such a rebuild would give.
    @objc private func menuItemsDidChange(_ notification: Notification) {
        guard !isRepairing, let menu = notification.object as? NSMenu else { return }
        if let main = menu.supermenu {
            guard main === mainMenu() else { return }
            repairIfNeeded(in: menu)
        } else if menu === mainMenu() {
            repairTopLevelMenus(of: menu)
        }
    }

    /// The item right after Open… when it is blank: not a separator, no
    /// submenu, no action, no view. The title is deliberately not tested —
    /// a partly reset item must still be repaired.
    ///
    /// Assumption: nothing of ours sits directly after the system's Open….
    /// A disabled SwiftUI Button there also has no action and no submenu and
    /// would be taken for the blank. There is deliberately no class check:
    /// the blank's class is known only for macOS 27.2.1, and a repair that
    /// silently stops on another macOS is worse than this rule
    /// (`CommandGroup(after: .newItem)` lands BEFORE Open…).
    static func blankSlot(in menu: NSMenu) -> NSMenuItem? {
        let openDocument = #selector(NSDocumentController.openDocument(_:))
        guard let index = menu.items.firstIndex(where: { $0.action == openDocument }),
              index + 1 < menu.numberOfItems,
              let slot = menu.item(at: index + 1) else { return nil }
        guard !slot.isSeparatorItem, slot.submenu == nil, slot.action == nil, slot.view == nil else {
            return nil
        }
        return slot
    }

    private func repairIfNeeded(in menu: NSMenu) {
        guard let slot = Self.blankSlot(in: menu) else { return }
        isRepairing = true
        defer { isRepairing = false }
        let submenu = NSMenu(title: Self.title)
        submenu.delegate = self
        // Enabled states are set per item: accessibility reads them without
        // the menu ever being validated.
        submenu.autoenablesItems = false
        // Filled before it is attached, so its own notifications come from a
        // menu that is not under the main menu yet.
        fill(submenu)
        submenusBuilt += 1
        slot.submenu = submenu
        slot.title = Self.title
        slot.isEnabled = true
    }

    // MARK: - Content

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = environment.recents()
        var nameCounts: [String: Int] = [:]
        for url in urls { nameCounts[url.lastPathComponent, default: 0] += 1 }
        for url in urls {
            let name = url.lastPathComponent
            // Two entries with one name: each says its folder, as the
            // system menu does.
            let title = (nameCounts[name] ?? 0) > 1
                ? "\(name) \u{2014} \(url.deletingLastPathComponent().lastPathComponent)"
                : name
            let item = NSMenuItem(title: title, action: #selector(openEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = icon(for: url)
            Self.requestVisibleImage(for: item)
            item.isEnabled = true
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: Self.clearTitle, action: #selector(clearMenu(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    /// The KVC key of `NSMenuItem.preferredImageVisibility` (macOS 27 SDK).
    static let imageVisibilityKey = "preferredImageVisibility"

    /// On macOS 27 and later AppKit decides whether a menu item's image is
    /// drawn and typically hides it (SDK header `NSMenuItem.h`); the
    /// system's own Open Recent shows document icons, so ours asks for
    /// them. `preferredImageVisibility` is public API of the macOS 27 SDK,
    /// called by name only because CI builds with an older SDK that lacks
    /// the symbol; 1 is `NSMenuItemImageVisibilityVisible`. On macOS 13–26
    /// the item does not respond and nothing is called (images show there).
    static func requestVisibleImage(for item: NSMenuItem) {
        guard item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        item.setValue(NSNumber(value: 1), forKey: imageVisibilityKey)
    }

    /// The content type's icon from the extension alone — no
    /// `icon(forFile:)`, which reads the file (and may wake a volume).
    private func icon(for url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        if let cached = iconsByExtension[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let image = (NSWorkspace.shared.icon(for: type).copy() as? NSImage) ?? NSImage()
        image.size = Self.iconSize
        iconsByExtension[ext] = image
        return image
    }

    // MARK: - Actions

    @objc private func openEntry(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        environment.open(url) { [weak self] message in
            self?.environment.reportFailure(message)
        }
    }

    @objc private func clearMenu(_ sender: NSMenuItem) {
        environment.clear()
        if let menu = sender.menu { fill(menu) }
    }
}
