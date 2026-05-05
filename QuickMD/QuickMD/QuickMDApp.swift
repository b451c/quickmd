import SwiftUI
import UniformTypeIdentifiers

// MARK: - App URLs

enum AppURLs {
    static let github = URL(string: "https://github.com/b451c/quickmd")!
    static let website = URL(string: "https://qmd.app/")!
    static let buyMeCoffee = URL(string: "https://buymeacoffee.com/bsroczynskh")!
    static let kofi = URL(string: "https://ko-fi.com/quickmd")!
    static let latestRelease = URL(string: "https://github.com/b451c/quickmd/releases/latest")!
}

@main
struct QuickMDApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            MarkdownView(document: file.document, documentURL: file.fileURL)
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
                Divider()
                ExportPDFCommand()
                PrintCommand()
            }
            CommandGroup(replacing: .textEditing) {
                FindMenuCommand()
                ToggleToCCommand()
                ToggleDocumentListCommand()
                Divider()
                CopyMarkdownCommand()
            }
            CommandGroup(replacing: .help) {
                Button("QuickMD Help") {
                    NSWorkspace.shared.open(AppURLs.github)
                }
                Divider()
                #if APPSTORE
                TipJarMenuButton()
                #else
                UpdateMenuButton()
                Divider()
                Button("Visit qmd.app") {
                    NSWorkspace.shared.open(AppURLs.website)
                }
                Divider()
                Menu("Support QuickMD ☕") {
                    Button("Buy Me a Coffee") {
                        NSWorkspace.shared.open(AppURLs.buyMeCoffee)
                    }
                    Button("Ko-fi") {
                        NSWorkspace.shared.open(AppURLs.kofi)
                    }
                }
                #endif
            }
        }
        .defaultSize(width: 800, height: 600)

        Settings {
            ThemePickerView()
        }

        #if APPSTORE
        Window("Tip Jar", id: "tip-jar") {
            TipJarView()
        }
        .windowResizability(.contentSize)
        #endif
    }
}

struct ToggleToCCommand: View {
    @FocusedValue(\.toggleToCAction) var toggleToCAction

    var body: some View {
        Button("Table of Contents") {
            toggleToCAction?()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

struct ToggleDocumentListCommand: View {
    @FocusedValue(\.toggleDocumentListAction) var toggleDocumentListAction

    var body: some View {
        Button("Recent Documents") {
            toggleDocumentListAction?()
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

struct CopyMarkdownCommand: View {
    @FocusedValue(\.copyDocumentAction) var copyDocumentAction

    var body: some View {
        Button("Copy Markdown") {
            copyDocumentAction?()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(copyDocumentAction == nil)
    }
}

struct FindMenuCommand: View {
    @FocusedValue(\.searchAction) var searchAction

    var body: some View {
        Button("Find...") {
            searchAction?()
        }
        .keyboardShortcut("f", modifiers: .command)
    }
}

#if APPSTORE
struct TipJarMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Tip Jar 💝") {
            openWindow(id: "tip-jar")
        }
    }
}
#endif

// MARK: - Update Checker (GitHub version only)

#if !APPSTORE
struct UpdateMenuButton: View {
    @State private var latestVersion: String?

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    var body: some View {
        if updateAvailable, let latest = latestVersion {
            Button("Update Available — v\(latest)") {
                NSWorkspace.shared.open(AppURLs.latestRelease)
            }
        } else {
            Button("Check for Updates…") {
                Task { await checkForUpdate() }
            }
        }
    }

    private func checkForUpdate() async {
        latestVersion = await UpdateChecker.fetchLatestVersion()
        // If already up to date, briefly show confirmation then reset
        if !updateAvailable {
            latestVersion = currentVersion
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            latestVersion = nil
        }
    }
}

enum UpdateChecker {
    private static let releaseURL = URL(string: "https://api.github.com/repos/b451c/quickmd/releases/latest")!

    /// Fetches the latest release tag from GitHub. Returns version string (e.g. "1.3.3") or nil.
    static func fetchLatestVersion() async -> String? {
        do {
            var request = URLRequest(url: releaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return nil }
            // Strip leading "v" from tag (e.g. "v1.3.3" → "1.3.3")
            return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        } catch {
            return nil
        }
    }
}
#endif
