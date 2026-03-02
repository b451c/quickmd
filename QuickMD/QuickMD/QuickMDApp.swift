import SwiftUI
import UniformTypeIdentifiers

// MARK: - App URLs

enum AppURLs {
    static let github = URL(string: "https://github.com/b451c/quickmd")!
    static let website = URL(string: "https://qmd.app/")!
    static let buyMeCoffee = URL(string: "https://buymeacoffee.com/bsroczynskh")!
    static let kofi = URL(string: "https://ko-fi.com/quickmd")!
}

@main
struct QuickMDApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            MarkdownView(document: file.document, documentURL: file.fileURL)
        }
        .commands {
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(after: .saveItem) {
                Divider()
                ExportPDFCommand()
                PrintCommand()
            }
            CommandGroup(replacing: .textEditing) {
                FindMenuCommand()
                ToggleToCCommand()
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
