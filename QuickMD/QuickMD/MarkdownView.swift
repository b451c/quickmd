import SwiftUI

// MARK: - App URLs

#if !APPSTORE
private enum AppURLs {
    static let website = URL(string: "https://qmd.app/")!
    static let buyMeCoffee = URL(string: "https://buymeacoffee.com/bsroczynskh")!
    static let kofi = URL(string: "https://ko-fi.com/quickmd")!
}
#endif

// MARK: - Main View

/// Main Markdown document view
/// Renders parsed markdown blocks in a scrollable container with support button
struct MarkdownView: View {
    let document: MarkdownDocument
    let documentURL: URL?
    @Environment(\.colorScheme) var colorScheme
    @State private var cachedBlocks: [MarkdownBlock] = []

    /// Use cached theme instance to avoid allocations on each body evaluation
    private var theme: MarkdownTheme {
        MarkdownTheme.cached(for: colorScheme)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(cachedBlocks) { block in
                        switch block {
                        case .text(_, let attributedString):
                            Text(attributedString)
                                .textSelection(.enabled)

                        case .table(_, let headers, let rows, let alignments):
                            TableBlockView(headers: headers, rows: rows, alignments: alignments, theme: theme)
                                .padding(.vertical, 8)

                        case .codeBlock(_, let code, let language):
                            CodeBlockView(code: code, language: language, theme: theme)
                                .padding(.vertical, 4)

                        case .image(_, let url, let alt):
                            ImageBlockView(url: url, alt: alt, theme: theme, documentURL: documentURL)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }

            #if APPSTORE
            // Tip Jar button (App Store version)
            TipJarButton(theme: theme)
                .padding(16)
            #else
            // Donation button (GitHub version)
            SupportButton(theme: theme)
                .padding(16)
            #endif
        }
        .background(theme.backgroundColor)
        .frame(minWidth: 400, minHeight: 300)
        .task(id: document.text.hashValue ^ colorScheme.hashValue) {
            cachedBlocks = MarkdownBlockParser(colorScheme: colorScheme).parse(document.text)
            // Update shared state for export/print menu commands
            ExportStateManager.shared.currentBlocks = cachedBlocks
            ExportStateManager.shared.currentDocumentText = document.text
        }
    }
}

// MARK: - Tip Jar Button (App Store version)

#if APPSTORE
struct TipJarButton: View {
    let theme: MarkdownTheme
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    var body: some View {
        Button {
            openWindow(id: "tip-jar")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                if isHovered {
                    Text("Tip Jar")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundColor(.pink)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Support QuickMD")
    }
}
#endif

// MARK: - Support Button (GitHub version)

#if !APPSTORE
struct SupportButton: View {
    let theme: MarkdownTheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button {
                NSWorkspace.shared.open(AppURLs.website)
            } label: {
                Label("Visit qmd.app", systemImage: "globe")
            }
            Divider()
            Button {
                NSWorkspace.shared.open(AppURLs.buyMeCoffee)
            } label: {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
            }
            Button {
                NSWorkspace.shared.open(AppURLs.kofi)
            } label: {
                Label("Ko-fi", systemImage: "heart.fill")
            }
        } label: {
            HStack(spacing: 4) {
                Text("☕")
                    .font(.system(size: 12))
                if isHovered {
                    Text("Support")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Support QuickMD development")
    }
}
#endif

// MARK: - Preview

#Preview {
    MarkdownView(document: MarkdownDocument(text: """
    # Welcome to QuickMD

    This is a **bold** and *italic* text example with `inline code`.

    ## Task Lists

    - [x] Image rendering
    - [x] Syntax highlighting
    - [x] Task lists
    - [ ] Future feature

    ## Table Example

    | Feature | Status | Notes |
    |:--------|:------:|------:|
    | Headers | Done | Left |
    | Tables  | Done | Center |
    | Align   | Done | Right |

    ## Code with Highlighting

    ```swift
    func greet(_ name: String) -> String {
        let message = "Hello, \\(name)!"
        return message // Returns greeting
    }
    ```

    ![SwiftUI Logo](https://developer.apple.com/assets/elements/icons/swiftui/swiftui-96x96_2x.png)

    [Visit Apple](https://apple.com)
    """), documentURL: nil)
}
