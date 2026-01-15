import SwiftUI
import UniformTypeIdentifiers

@main
struct QuickMDApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            MarkdownView(document: file.document)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .help) {
                Button("QuickMD Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/b451c/quickmd")!)
                }
                Divider()
                #if APPSTORE
                Button("Visit qmd.app") {
                    NSWorkspace.shared.open(URL(string: "https://qmd.app/")!)
                }
                #else
                Button("Visit qmd.app") {
                    NSWorkspace.shared.open(URL(string: "https://qmd.app/")!)
                }
                Divider()
                Menu("Support QuickMD ☕") {
                    Button("Buy Me a Coffee") {
                        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/bsroczynskh")!)
                    }
                    Button("Ko-fi") {
                        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/quickmd")!)
                    }
                }
                #endif
            }
        }
        .defaultSize(width: 800, height: 600)
    }
}
