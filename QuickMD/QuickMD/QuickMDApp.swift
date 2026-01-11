import SwiftUI
import UniformTypeIdentifiers

@main
struct QuickMDApp: App {
    private let donationURL = URL(string: "https://buymeacoffee.com/bsroczynskh")!

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
                Button("Support QuickMD ☕") {
                    NSWorkspace.shared.open(donationURL)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        .defaultSize(width: 800, height: 600)
    }
}
