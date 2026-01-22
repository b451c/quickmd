import SwiftUI
import UniformTypeIdentifiers

// MARK: - App URLs

private enum AppURLs {
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
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(after: .saveItem) {
                Divider()
                ExportPDFCommand()
                PrintCommand()
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

        #if APPSTORE
        Window("Tip Jar", id: "tip-jar") {
            TipJarView()
        }
        .windowResizability(.contentSize)
        #endif
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
